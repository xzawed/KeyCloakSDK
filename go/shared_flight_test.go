package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// 공유 비행(single-flight)이 첫 호출자의 ctx 를 잡는 부류(등록부 jwks-forced-refetch-window-burned).
//
// 수정 전 실측(2026-10-05, 이 트리 — 따뜻한 k1 → IdP 가 k2 로 회전, 창은 기본 30초):
//   A 미리 취소된 #1: /certs 1→1, 이어 산 ctx 의 #2 「(refetch rate-limited)」 — IdP 에 안 닿은 취소가 창을 썼다
//   B 비행 중 취소된 #1: /certs 1→2, #2 같은 거부
//   D 강제 경로의 둘째 호출자: 비행 중인 재조회를 기다리지 않고 즉시 「(refetch rate-limited)」
//   E 콜드 경로: 취소된 첫 호출자가 같이 기다리던 산 호출자를 「context canceled」로 실패시키고 백오프를 올렸다
//   F admin 토큰 공급자·Client.Admin: 첫 호출자의 취소가 산 대기자를 TransportError 로 실패시켰다
//
// ⚠️ 시험은 IdP 를 채널로 붙잡아 순서를 정한다(잠을 재지 않는다). 「아직 안 돌아왔다」를 보는 200ms 는 관찰
// 창일 뿐이다 — 고친 코드에서 대기자는 풀어 주기 전에 돌아올 수 없으므로 그 창이 판정을 바꾸지 못한다.

const flightObserve = 200 * time.Millisecond

// flightIdP 는 붙잡을 수 있는 realm 이다: /certs 는 지금 키셋을 내고, /token 은 토큰을 낸다. hold 가 켜져 있으면
// 두 엔드포인트의 요청은 풀릴 때까지(또는 클라이언트가 끊을 때까지) 기다리고, 도착을 arrived 로 알린다.
type flightIdP struct {
	srv      *httptest.Server
	k1, k2   *rsa.PrivateKey
	mu       sync.Mutex
	set      []byte
	held     chan struct{}
	fail     int // 다음 n 번의 /certs 를 503 으로
	expires  int // 토큰 응답의 expires_in
	certs    atomic.Int32
	tokens   atomic.Int32
	adminReq atomic.Int32
	arrived  chan string
}

func newFlightIdP(t *testing.T) *flightIdP {
	t.Helper()
	p := &flightIdP{arrived: make(chan string, 16), expires: 300}
	var err error
	if p.k1, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
		t.Fatal(err)
	}
	if p.k2, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
		t.Fatal(err)
	}
	p.set = flightKeySet(t, &p.k1.PublicKey, "k1")
	base := "/realms/r/protocol/openid-connect"
	mux := http.NewServeMux()
	mux.HandleFunc(base+"/certs", func(w http.ResponseWriter, r *http.Request) {
		p.certs.Add(1)
		p.mu.Lock()
		fail := p.fail > 0
		if fail {
			p.fail--
		}
		p.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if !p.wait(r) {
			return
		}
		p.mu.Lock()
		set := p.set
		p.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(set)
	})
	mux.HandleFunc(base+"/token", func(w http.ResponseWriter, r *http.Request) {
		p.tokens.Add(1)
		if !p.wait(r) {
			return
		}
		p.mu.Lock()
		exp := p.expires
		p.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"access_token":"flight-at","token_type":"Bearer","expires_in":`+strconv.Itoa(exp)+`}`)
	})
	mux.HandleFunc("/admin/realms/r/users", func(w http.ResponseWriter, _ *http.Request) {
		p.adminReq.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, "[]")
	})
	p.srv = httptest.NewServer(mux)
	t.Cleanup(p.srv.Close)
	return p
}

func flightKeySet(t *testing.T, pub *rsa.PublicKey, kid string) []byte {
	t.Helper()
	b, err := json.Marshal(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: pub, KeyID: kid, Algorithm: "RS256", Use: "sig"}}})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// wait 는 붙잡힌 동안 요청을 세운다. 클라이언트가 끊으면 false 다.
func (p *flightIdP) wait(r *http.Request) bool {
	p.mu.Lock()
	held := p.held
	p.mu.Unlock()
	if held == nil {
		return true
	}
	select {
	case p.arrived <- r.URL.Path:
	default:
	}
	select {
	case <-held:
		return true
	case <-r.Context().Done():
		return false
	}
}

// hold 는 이제부터 오는 요청을 붙잡고, 풀어 주는 함수를 돌려준다(시험이 끝날 때도 푼다).
func (p *flightIdP) hold(t *testing.T) func() {
	t.Helper()
	ch := make(chan struct{})
	p.mu.Lock()
	p.held = ch
	p.mu.Unlock()
	var once sync.Once
	release := func() {
		once.Do(func() {
			p.mu.Lock()
			p.held = nil
			p.mu.Unlock()
			close(ch)
		})
	}
	t.Cleanup(release)
	return release
}

func (p *flightIdP) waitArrived(t *testing.T, path string) {
	t.Helper()
	select {
	case got := <-p.arrived:
		if !strings.HasSuffix(got, path) {
			t.Fatalf("held request on %s, want %s", got, path)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("no request reached %s — the fetch never started", path)
	}
}

func (p *flightIdP) rotate(t *testing.T) {
	t.Helper()
	set := flightKeySet(t, &p.k2.PublicKey, "k2")
	p.mu.Lock()
	p.set = set
	p.mu.Unlock()
}

// client 는 New 로 만들고(배선이 시험 대상이다), 게이트 시계를 얼린다 — 창(30초)이 시험 도중 지나지 않는다.
func (p *flightIdP) client(t *testing.T) *Client {
	t.Helper()
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "cs-in"})
	if err != nil {
		t.Fatal(err)
	}
	frozen := time.Now()
	c.Auth.val.opts.now = func() time.Time { return frozen }
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func (p *flightIdP) token(t *testing.T, key *rsa.PrivateKey, kid string) string {
	t.Helper()
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid))
	if err != nil {
		t.Fatal(err)
	}
	s, err := jwt.Signed(sig).Claims(jwt.Claims{Subject: "u1", Issuer: p.srv.URL + "/realms/r", Audience: jwt.Audience{"c"},
		Expiry: jwt.NewNumericDate(time.Now().Add(5 * time.Minute)), IssuedAt: jwt.NewNumericDate(time.Now())}).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func async(fn func() error) <-chan error {
	ch := make(chan error, 1)
	go func() { ch <- fn() }()
	return ch
}

// returned 는 ch 가 d 안에 결과를 내면 그것을, 아니면 ok=false 를 돌려준다.
func returned(ch <-chan error, d time.Duration) (error, bool) {
	select {
	case err := <-ch:
		return err, true
	case <-time.After(d):
		return nil, false
	}
}

func mustReturn(t *testing.T, ch <-chan error, what string) error {
	t.Helper()
	err, ok := returned(ch, 5*time.Second)
	if !ok {
		t.Fatalf("%s did not return", what)
	}
	return err
}

func mustStillWait(t *testing.T, ch <-chan error, what string) {
	t.Helper()
	if err, done := returned(ch, flightObserve); done {
		t.Fatalf("%s returned (%v) before the fetch it shares had finished", what, err)
	}
}

// requireCancelled 는 취소된 호출자의 결과가 그 레인의 SDK 오류 타입이고 errors.Is(context.Canceled) 인지 본다.
func requireCancelled[T error](t *testing.T, err error, what string) {
	t.Helper()
	var target T
	if !errors.As(err, &target) || !errors.Is(err, context.Canceled) {
		t.Fatalf("%s: want %T wrapping context.Canceled, got %T %v", what, target, err, err)
	}
}

func (p *flightIdP) warm(t *testing.T, c *Client) {
	t.Helper()
	if _, err := c.Auth.Validate(context.Background(), p.token(t, p.k1, "k1")); err != nil {
		t.Fatalf("warm k1: %v", err)
	}
	if n := p.certs.Load(); n != 1 {
		t.Fatalf("warm: /certs=%d, want 1", n)
	}
}

// TestJWKSForcedRefetchSurvivesCallerCancellation 은 이 항목의 계약이다: 따뜻한 k1 → 회전 → 취소된 #1(비행 전·비행
// 중) → 창 안의 #2(k2)는 **수락**되고 그 창의 /certs 요청은 정확히 하나다. 취소된 #1 은 곧바로 취소로 돌아온다.
func TestJWKSForcedRefetchSurvivesCallerCancellation(t *testing.T) {
	t.Run("cancelled before the fetch", func(t *testing.T) {
		p := newFlightIdP(t)
		c := p.client(t)
		p.warm(t, c)
		p.rotate(t)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := c.Auth.Validate(ctx, p.token(t, p.k2, "k2"))
		requireCancelled[*TokenValidationError](t, err, "#1 cancelled before the call")
		if _, err := c.Auth.Validate(context.Background(), p.token(t, p.k2, "k2")); err != nil {
			t.Fatalf("#2 inside the window must be accepted, got %v", err)
		}
		if n := p.certs.Load(); n != 2 {
			t.Fatalf("the window must cost exactly one /certs request: /certs=%d, want 2", n)
		}
	})
	t.Run("cancelled mid-flight", func(t *testing.T) {
		p := newFlightIdP(t)
		c := p.client(t)
		p.warm(t, c)
		p.rotate(t)
		release := p.hold(t)
		ctx, cancel := context.WithCancel(context.Background())
		first := async(func() error { _, err := c.Auth.Validate(ctx, p.token(t, p.k2, "k2")); return err })
		p.waitArrived(t, "/certs")
		cancel()
		requireCancelled[*TokenValidationError](t, mustReturn(t, first, "#1 cancelled mid-flight"), "#1 cancelled mid-flight")
		second := async(func() error { _, err := c.Auth.Validate(context.Background(), p.token(t, p.k2, "k2")); return err })
		mustStillWait(t, second, "#2 inside the window")
		release()
		if err := mustReturn(t, second, "#2"); err != nil {
			t.Fatalf("#2 inside the window must be accepted, got %v", err)
		}
		if n := p.certs.Load(); n != 2 {
			t.Fatalf("the window must cost exactly one /certs request: /certs=%d, want 2", n)
		}
	})
}

// TestJWKSCancelledForgedKidFloodCostsOneRequestPerWindow 는 취소를 「창 되돌리기」로 고치면 안 되는 이유를
// 고정한다(python 실측: 되돌리면 취소된 위조 kid 검증 열 번이 IdP 요청 열 건, 떼어 내면 한 건). 위조 kid 열 개를
// 차례로 — 닿으면 비행 중에 취소한다 — 보내도 그 창의 /certs 요청은 하나다.
func TestJWKSCancelledForgedKidFloodCostsOneRequestPerWindow(t *testing.T) {
	p := newFlightIdP(t)
	c := p.client(t)
	p.warm(t, c)
	for i := range 10 {
		release := p.hold(t)
		ctx, cancel := context.WithCancel(context.Background())
		forged := p.token(t, p.k2, "forged-"+strconv.Itoa(i))
		res := async(func() error { _, err := c.Auth.Validate(ctx, forged); return err })
		select {
		case <-p.arrived: // 이 검증이 IdP 에 닿았다 — 비행 중에 취소한다
			cancel()
			requireCancelled[*TokenValidationError](t, mustReturn(t, res, "a cancelled forged-kid validation"), "forged")
		case err := <-res: // 요청 없이 거부됐다(창 안) — 아니면 비행 중인 창의 조회를 기다렸다가 거부됐다
			if err == nil {
				t.Fatalf("forged kid %d was accepted", i)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("forged kid %d neither reached the IdP nor returned", i)
		}
		cancel()
		release()
	}
	if n := p.certs.Load(); n != 2 {
		t.Fatalf("ten forged kids cancelled mid-flight cost %d /certs requests, want 2 (cold load + one per window)", n)
	}
}

// TestJWKSForcedRefetchThatFailsStillUsesTheWindow — 의도된 실패 의미론은 그대로다: IdP 가 503 으로 답한 강제
// 재조회도 창을 쓴다(장애 중 위조 kid 의 상한). 취소와 갈리는 것은 「요청이 끝까지 가서 실패했다」는 점이다.
func TestJWKSForcedRefetchThatFailsStillUsesTheWindow(t *testing.T) {
	p := newFlightIdP(t)
	c := p.client(t)
	p.warm(t, c)
	p.rotate(t)
	p.mu.Lock()
	p.fail = 1
	p.mu.Unlock()
	if _, err := c.Auth.Validate(context.Background(), p.token(t, p.k2, "k2")); err == nil || !strings.Contains(err.Error(), "HTTP 503") {
		t.Fatalf("#1 must fail with the IdP's 503, got %v", err)
	}
	_, err := c.Auth.Validate(context.Background(), p.token(t, p.k2, "k2"))
	if err == nil || !strings.Contains(err.Error(), "rate-limited") {
		t.Fatalf("#2 inside the window of a failed fetch must be refused, got %v", err)
	}
	if n := p.certs.Load(); n != 2 {
		t.Fatalf("/certs=%d, want 2", n)
	}
}

// TestJWKSForcedRefetchSecondCallerWaitsForTheFetchInFlight — 같은 부류의 형제(실측 D): 창을 연 재조회가 아직
// 비행 중이면 둘째 호출자는 거부되지 않고 그 결과를 기다린다. 요청은 늘지 않는다. 첫 호출자가 취소돼도 같다.
func TestJWKSForcedRefetchSecondCallerWaitsForTheFetchInFlight(t *testing.T) {
	for _, cancelLeader := range []bool{false, true} {
		name := "leader live"
		if cancelLeader {
			name = "leader cancelled"
		}
		t.Run(name, func(t *testing.T) {
			p := newFlightIdP(t)
			c := p.client(t)
			p.warm(t, c)
			p.rotate(t)
			release := p.hold(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			leader := async(func() error { _, err := c.Auth.Validate(ctx, p.token(t, p.k2, "k2")); return err })
			p.waitArrived(t, "/certs")
			waiter := async(func() error { _, err := c.Auth.Validate(context.Background(), p.token(t, p.k2, "k2")); return err })
			mustStillWait(t, waiter, "the second caller")
			if cancelLeader {
				cancel()
				leaderErr := mustReturn(t, leader, "the cancelled leader")
				mustStillWait(t, waiter, "the second caller after the leader gave up")
				requireCancelled[*TokenValidationError](t, leaderErr, "leader")
			}
			release()
			if err := mustReturn(t, waiter, "the second caller"); err != nil {
				t.Fatalf("the second caller must get the in-flight fetch's key, got %v", err)
			}
			if !cancelLeader {
				if err := mustReturn(t, leader, "the leader"); err != nil {
					t.Fatalf("leader: %v", err)
				}
			}
			if _, err := c.Auth.Validate(context.Background(), p.token(t, p.k2, "k2")); err != nil {
				t.Fatalf("after the fetch k2 is cached: %v", err)
			}
			if n := p.certs.Load(); n != 2 {
				t.Fatalf("/certs=%d, want 2 (one cold load, one forced refetch)", n)
			}
		})
	}
}

// TestJWKSColdLoadLeaderCancellationFailsNeitherWaiterNorBackoff — 형제(실측 E): 콜드 캐시에서 첫 호출자가 취소돼도
// 같이 기다리던 산 호출자는 그 취소로 실패하지 않고, 취소는 IdP 장애가 아니므로 실패 백오프를 올리지 않는다.
func TestJWKSColdLoadLeaderCancellationFailsNeitherWaiterNorBackoff(t *testing.T) {
	p := newFlightIdP(t)
	c := p.client(t)
	release := p.hold(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	leader := async(func() error { _, err := c.Auth.Validate(ctx, p.token(t, p.k1, "k1")); return err })
	p.waitArrived(t, "/certs")
	waiter := async(func() error { _, err := c.Auth.Validate(context.Background(), p.token(t, p.k1, "k1")); return err })
	mustStillWait(t, waiter, "the live waiter")
	cancel()
	leaderErr := mustReturn(t, leader, "the cancelled leader")
	mustStillWait(t, waiter, "the live waiter after the leader gave up")
	requireCancelled[*TokenValidationError](t, leaderErr, "leader")
	release()
	if err := mustReturn(t, waiter, "the live waiter"); err != nil {
		t.Fatalf("the live waiter must get the cold load's key, got %v", err)
	}
	c.Auth.val.mu.Lock()
	failures := c.Auth.val.failures
	c.Auth.val.mu.Unlock()
	if failures != 0 {
		t.Fatalf("a caller's cancellation is not an IdP failure, yet the backoff counts %d", failures)
	}
	if _, err := c.Auth.Validate(context.Background(), p.token(t, p.k1, "k1")); err != nil {
		t.Fatalf("right after: %v", err)
	}
	if n := p.certs.Load(); n != 1 {
		t.Fatalf("/certs=%d, want 1", n)
	}
}

// TestAlreadyCancelledCallerStartsNothing — 이미 포기한 호출자는 아무것도 시작하지 않는다: JWKS 를 조회하지도
// (그래서 실패 백오프도 오르지 않는다), 토큰 갱신·admin 생성을 시작하지도 않으며, 어느 요청도 IdP 에 닿지 않는다.
// 돌려받는 것은 그 레인의 SDK 오류 타입으로 감싼 context.Canceled 다.
func TestAlreadyCancelledCallerStartsNothing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	// ⚠️ 시작된 일은 고루틴에서 돈다 — 호출이 돌아온 직후의 계수는 「아직 안 닿음」과 「안 시작함」을 못 가른다.
	// 그래서 소스는 시작되면 알리고, IdP 는 붙잡혀 있어 닿은 요청이 arrived 로 알린다 — 관찰 창 안에 아무것도
	// 오지 않아야 한다(고친 코드에서는 시작된 것이 없으니 창이 판정을 바꾸지 못한다).
	started := make(chan struct{}, 1)
	tp := NewClientCredentialsTokenProvider(func(context.Context) (*TokenSet, error) {
		started <- struct{}{}
		return &TokenSet{AccessToken: "AT", ExpiresIn: 300}, nil
	}, 30)
	_, err := tp.Token(ctx)
	requireCancelled[*TransportError](t, err, "provider")

	p := newFlightIdP(t)
	c := p.client(t)
	p.hold(t)
	_, err = c.Admin(ctx)
	requireCancelled[*TransportError](t, err, "Client.Admin")
	_, err = c.Auth.Validate(ctx, p.token(t, p.k1, "k1"))
	requireCancelled[*TokenValidationError](t, err, "Validate on a cold cache")
	select {
	case <-started:
		t.Fatal("a cancelled caller started the token source")
	case path := <-p.arrived:
		t.Fatalf("a cancelled caller reached the IdP at %s", path)
	case <-time.After(flightObserve):
	}
	v := c.Auth.val
	v.mu.Lock()
	cached, stamped, failures := v.jwks != nil, !v.forcedAt.IsZero(), v.failures
	v.mu.Unlock()
	if cached || stamped || failures != 0 {
		t.Fatalf("a cancelled Validate left a trace: key set cached %v, window stamped %v, failures %d", cached, stamped, failures)
	}
	if tok, certs := p.tokens.Load(), p.certs.Load(); tok != 0 || certs != 0 {
		t.Fatalf("cancelled callers reached the IdP: token requests %d, /certs %d", tok, certs)
	}
}

// TestTokenProviderLeaderCancellationDoesNotFailWaiter — 형제(실측 F1, 공급자 단위): 갱신을 이끈 호출자가 취소돼도
// 같이 기다리던 호출자는 그 갱신의 토큰을 받는다. 취소된 호출자는 곧바로 *TransportError(context.Canceled)다.
func TestTokenProviderLeaderCancellationDoesNotFailWaiter(t *testing.T) {
	var calls atomic.Int32
	gate := make(chan struct{})
	t.Cleanup(func() {
		select {
		case <-gate:
		default:
			close(gate)
		}
	})
	started := make(chan struct{}, 4)
	tp := NewClientCredentialsTokenProvider(func(ctx context.Context) (*TokenSet, error) {
		calls.Add(1)
		started <- struct{}{}
		select { // 이 소스는 ctx 를 존중한다 — SDK 의 소스(gocloak→resty)도 그렇다
		case <-gate:
			return &TokenSet{AccessToken: "AT", ExpiresIn: 300}, nil
		case <-ctx.Done():
			return nil, &TransportError{Msg: "could not get token: " + ctx.Err().Error(), Cause: ctx.Err()}
		}
	}, 30)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	leader := async(func() error { _, err := tp.Token(ctx); return err })
	<-started
	var got string
	waiter := async(func() error { tok, err := tp.Token(context.Background()); got = tok; return err })
	mustStillWait(t, waiter, "the waiting caller")
	cancel()
	leaderErr := mustReturn(t, leader, "the cancelled leader")
	mustStillWait(t, waiter, "the waiting caller after the leader gave up")
	requireCancelled[*TransportError](t, leaderErr, "leader")
	close(gate)
	if err := mustReturn(t, waiter, "the waiting caller"); err != nil || got != "AT" {
		t.Fatalf("the waiting caller must get the refreshed token, got %q, %v", got, err)
	}
	if n := calls.Load(); n != 1 {
		t.Fatalf("one refresh must serve both callers, the source ran %d times", n)
	}
}

// TestAdminLeaderCancellationDoesNotFailWaiter — 형제(실측 F1·F2, 공개 API): admin 레인의 두 공유 비행 —
// Client.Admin 의 생성과, 만료된 토큰을 다시 받는 admin 호출 — 에서 첫 호출자의 취소가 산 대기자를 실패시키지
// 않고, 토큰 요청은 한 번이다.
func TestAdminLeaderCancellationDoesNotFailWaiter(t *testing.T) {
	t.Run("Client.Admin", func(t *testing.T) {
		p := newFlightIdP(t)
		c := p.client(t)
		release := p.hold(t)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		leader := async(func() error { _, err := c.Admin(ctx); return err })
		p.waitArrived(t, "/token")
		var admin *AdminClient
		waiter := async(func() error { a, err := c.Admin(context.Background()); admin = a; return err })
		mustStillWait(t, waiter, "the waiting Admin call")
		cancel()
		leaderErr := mustReturn(t, leader, "the cancelled Admin call")
		mustStillWait(t, waiter, "the waiting Admin call after the leader gave up")
		requireCancelled[*TransportError](t, leaderErr, "Admin leader")
		release()
		if err := mustReturn(t, waiter, "the waiting Admin call"); err != nil {
			t.Fatalf("the waiting Admin call must get the admin client, got %v", err)
		}
		if _, err := admin.Users.Search(context.Background(), "", 0, 1); err != nil {
			t.Fatalf("admin call: %v", err)
		}
		if n := p.tokens.Load(); n != 1 {
			t.Fatalf("token requests=%d, want 1", n)
		}
	})
	t.Run("token refresh on an admin call", func(t *testing.T) {
		p := newFlightIdP(t)
		p.mu.Lock()
		p.expires = 1 // 기본 skew 30초 안 — 공급자가 즉시 만료로 보고 admin 호출마다 다시 받는다
		p.mu.Unlock()
		c := p.client(t)
		a, err := c.Admin(context.Background())
		if err != nil {
			t.Fatalf("admin: %v", err)
		}
		release := p.hold(t)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		leader := async(func() error { _, err := a.Users.Search(ctx, "", 0, 1); return err })
		p.waitArrived(t, "/token")
		waiter := async(func() error { _, err := a.Users.Search(context.Background(), "", 0, 1); return err })
		mustStillWait(t, waiter, "the waiting admin call")
		cancel()
		leaderErr := mustReturn(t, leader, "the cancelled admin call")
		mustStillWait(t, waiter, "the waiting admin call after the leader gave up")
		requireCancelled[*TransportError](t, leaderErr, "admin leader")
		release()
		if err := mustReturn(t, waiter, "the waiting admin call"); err != nil {
			t.Fatalf("the waiting admin call must succeed with the refreshed token, got %v", err)
		}
		if n := p.tokens.Load(); n != 2 {
			t.Fatalf("token requests=%d, want 2 (creation + one shared refresh)", n)
		}
		if n := p.adminReq.Load(); n != 1 {
			t.Fatalf("admin requests=%d, want 1 (only the live waiter's)", n)
		}
	})
}
