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
	fail     int // 다음 n 번의 /certs 를 503 으로(붙잡혀 있었다면 풀린 뒤에)
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
		// 붙잡기가 먼저다 — 붙잡힌 요청도 503 으로 끝날 수 있다(창 끝까지 끌다 실패한 조회의 모양).
		if !p.wait(r) {
			return
		}
		p.mu.Lock()
		fail := p.fail > 0
		if fail {
			p.fail--
		}
		set := p.set
		p.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
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

// TestTokenProviderSharedRefreshIsBounded — 형제(PM 리뷰 실측, 위 수정이 낳은 것): 갱신을 어느 호출자의 취소에도 묶지
// 않자, 자기 시간 제한 없이 ctx 로만 끝나는 소비자 TokenSource(예: 기본 http.Client 로 clientcredentials.Config.Token(ctx)
// 를 부르는 함수)는 IdP 가 멈추면 끝나지 않았다. 이후의 Token 은 전부 그 비행에 합류해 자기 기한에야 돌아오고 새 갱신은
// 시작되지 않아, admin 레인이 프로세스 재시작까지 막혔다(실측: 200ms 기한의 호출 넷이 전부 시간 초과, 소스 호출 1 그대로 —
// origin/main 은 첫 호출자의 기한이 소스를 끝내 호출마다 새 갱신, 소스 호출 1→4). 공유 갱신에는 자기 기한이 있다: 지나면
// 소스의 ctx 가 끝나고, 기다리던 호출자는 소스가 돌려준 오류를 받으며, 다음 Token 은 새 갱신을 시작한다.
func TestTokenProviderSharedRefreshIsBounded(t *testing.T) {
	var calls atomic.Int32
	tp := NewClientCredentialsTokenProvider(func(ctx context.Context) (*TokenSet, error) {
		if calls.Add(1) == 1 { // 첫 요청은 멈춘 IdP 에 걸린다 — 자기 시간 제한이 없어 ctx 만이 끝낸다
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return &TokenSet{AccessToken: "AT", ExpiresIn: 300}, nil // IdP 가 회복된 뒤의 요청
	}, 30).(*clientCredentialsProvider)
	tp.timeout = 50 * time.Millisecond // 60초를 시험 시간으로 줄일 뿐이다 — 기한을 만드는 길은 그대로다

	// 기다리는 호출자에게는 기한이 없다 — 그를 놓아줄 수 있는 것은 갱신 자신의 기한뿐이다. 그래서 그가 돌아오면 그
	// 비행은 끝났고(singleflight 는 결과를 보내기 전에 키를 놓는다) 다음 호출은 새 갱신을 시작한다 — 순서는 시계가 아니라
	// 이 인과가 정한다.
	err := mustReturn(t, async(func() error { _, err := tp.Token(context.Background()); return err }),
		"a caller waiting on a refresh whose IdP never answers")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("the refresh's own deadline must end it and hand the source's error to the waiter, got %v", err)
	}
	if n := calls.Load(); n != 1 {
		t.Fatalf("the source ran %d times, want 1", n)
	}
	tok, err := tp.Token(context.Background())
	if err != nil || tok != "AT" {
		t.Fatalf("the next call must start a new refresh and get its token, got %q, %v", tok, err)
	}
	if n := calls.Load(); n != 2 {
		t.Fatalf("the source ran %d times, want 2 (the stuck refresh, then a new one)", n)
	}
}

// TestTokenProviderRefreshDeadlineIsItsOwn — 끝나는 소스에는 바뀌는 것이 없다: 소스는 갱신을 시작한 호출자의 값을 받되
// 그 호출자의 기한·취소는 받지 않고, 기한은 갱신이 시작된 지 tokenRefreshTimeout(60초) 하나다. 소스가 돌아오면 그 ctx 는
// 풀린다 — 기한의 타이머가 갱신마다 60초씩 남지 않는다.
func TestTokenProviderRefreshDeadlineIsItsOwn(t *testing.T) {
	type key struct{}
	var (
		srcCtx      context.Context
		errInside   error
		deadline    time.Time
		hasDeadline bool
	)
	tp := NewClientCredentialsTokenProvider(func(ctx context.Context) (*TokenSet, error) {
		srcCtx, errInside = ctx, ctx.Err()
		deadline, hasDeadline = ctx.Deadline()
		return &TokenSet{AccessToken: "AT", ExpiresIn: 300}, nil
	}, 30)
	ctx, cancel := context.WithTimeout(context.WithValue(context.Background(), key{}, "caller"), 10*time.Second)
	defer cancel()
	before := time.Now()
	tok, err := tp.Token(ctx)
	after := time.Now()
	if err != nil || tok != "AT" {
		t.Fatalf("Token() = %q, %v", tok, err)
	}
	if got := srcCtx.Value(key{}); got != "caller" {
		t.Fatalf("the source must get the values of the caller that started the refresh, got %v", got)
	}
	if !hasDeadline {
		t.Fatalf("the source's ctx must carry the refresh's own deadline (%v), it has none", tokenRefreshTimeout)
	}
	if deadline.Before(before.Add(tokenRefreshTimeout)) || deadline.After(after.Add(tokenRefreshTimeout)) {
		t.Fatalf("the source's one deadline must be %v after the refresh starts, not the caller's 10s: got %v after the call",
			tokenRefreshTimeout, deadline.Sub(before).Round(time.Millisecond))
	}
	if errInside != nil {
		t.Fatalf("the source's ctx was done while it ran: %v", errInside)
	}
	if !errors.Is(srcCtx.Err(), context.Canceled) {
		t.Fatalf("the refresh's ctx must be released once the source returns, got %v", srcCtx.Err())
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

// stepClock 은 시험이 한 걸음씩 옮기는 게이트 시계다(창·백오프 판정만 이것을 읽는다 — 토큰의 exp 는 벽시계다).
type stepClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *stepClock) now() time.Time  { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *stepClock) set(t time.Time) { c.mu.Lock(); c.t = t; c.mu.Unlock() }

// TestJWKSWindowIsStampedOnlyByTheFetchThatStartsInIt — 같은 부류(검증 레그 실측, 수정 전 이 트리와 origin/main
// 둘 다): 창이 지난 뒤의 miss 가 먼저 창 도장을 찍고 나서 (a) 실패 백오프에 거부되거나 (b) 이전 창의 아직 비행 중인
// 조회에 합류했다. 어느 쪽도 IdP 에 새 요청을 보내지 않았는데 새 창이 서서, 백오프가 끝나고 IdP 가 회복된 뒤에도
// 회전된 키가 그 창 내내 「(refetch rate-limited)」로 거부됐다(/certs 2 그대로). 기본값에서 닿는다 —
// Config.ReadTimeout(30초)이 창(30초)과 같아 시간 초과로 끝나는 강제 재조회는 창 끝에서 실패한다. 창은 그 창에서
// **시작한** 조회만 찍는다: 거부도 합류도 찍지 않는다(창마다 새 조회 하나라는 상한은 그대로다).
func TestJWKSWindowIsStampedOnlyByTheFetchThatStartsInIt(t *testing.T) {
	for _, joined := range []bool{false, true} {
		name := "refused by the failure backoff"
		if joined {
			name = "joined the previous window's fetch"
		}
		t.Run(name, func(t *testing.T) {
			p := newFlightIdP(t)
			c := p.client(t)
			t0 := time.Now()
			clk := &stepClock{t: t0}
			c.Auth.val.opts.now = clk.now
			p.warm(t, c)
			p.rotate(t)
			p.mu.Lock()
			p.fail = 1 // 창을 연 강제 재조회는 붙잡혔다가 503 으로 끝난다
			p.mu.Unlock()
			release := p.hold(t)
			k2 := func() error { _, err := c.Auth.Validate(context.Background(), p.token(t, p.k2, "k2")); return err }
			first := async(k2)
			p.waitArrived(t, "/certs")
			var second <-chan error
			if joined {
				// 창(t0 에 찍힘)이 그 조회가 아직 비행 중일 때 지난다 — 이때의 miss 는 그 조회에 합류한다.
				clk.set(t0.Add(30010 * time.Millisecond))
				second = async(k2)
				mustStillWait(t, second, "a miss after the window, while the previous window's fetch is in flight")
			} else {
				clk.set(t0.Add(29950 * time.Millisecond)) // 조회가 창 끝 직전에 실패한다(ReadTimeout 의 모양)
			}
			release()
			if err := mustReturn(t, first, "#1"); err == nil || !strings.Contains(err.Error(), "HTTP 503") {
				t.Fatalf("#1 must fail with the IdP's 503, got %v", err)
			}
			if joined {
				if err := mustReturn(t, second, "#2"); err == nil || !strings.Contains(err.Error(), "HTTP 503") {
					t.Fatalf("#2 joined the failed fetch and must get its 503, got %v", err)
				}
			} else {
				// 창은 지났고 실패 백오프(실패 한 번 뒤 100–200ms)는 아직이다.
				clk.set(t0.Add(30010 * time.Millisecond))
				if err := k2(); err == nil || !strings.Contains(err.Error(), "backing off") {
					t.Fatalf("#2 inside the failure backoff must be refused by it, got %v", err)
				}
			}
			if n := p.certs.Load(); n != 2 {
				t.Fatalf("/certs=%d, want 2 — neither a refusal nor a join may send a request", n)
			}
			clk.set(t0.Add(30500 * time.Millisecond)) // 모든 백오프가 끝났고(실패 뒤 200ms 이내) IdP 는 회복됐다
			if err := k2(); err != nil {
				t.Fatalf("after the backoff the rotated key must be fetched and accepted (no fetch started in a window "+
					"the refusal or the join could have stamped), got %v", err)
			}
			if n := p.certs.Load(); n != 3 {
				t.Fatalf("/certs=%d, want 3 (cold load, the failed refetch, the recovery)", n)
			}
		})
	}
}

// pauseCtx 는 호출자를 캐시 조회와 조회 결정 사이에 세운다 — resolveKey 는 그 사이에서 ctx.Err() 를 한 번 묻는다.
// 첫 Err() 가 paused 를 닫고 resume 이 닫힐 때까지 기다린다: 스케줄러가 그 자리에서 고루틴을 내려놓은 것과 같다.
// ⚠️ 그 ctx.Err() 가 조회 앞으로 옮겨지면 이 시험은 그 자리에 서지 못한다 — 옮길 때 이 시험의 세울 자리도 옮겨라.
type pauseCtx struct {
	context.Context
	once           sync.Once
	paused, resume chan struct{}
}

func (c *pauseCtx) Err() error {
	c.once.Do(func() { close(c.paused); <-c.resume })
	return c.Context.Err()
}

// TestJWKSMissRechecksTheCacheBeforeDeciding — 같은 부류(검증 레그 실측): 캐시 조회는 잠금 밖이고 조회 결정은
// 잠금 안이라, 그 사이에 비행이 끝나 캐시가 kid 를 갖게 되면 낡은 miss 로 결정했다. 콜드 적재에서는 둘째 호출자가
// 강제 재조회를 하나 더 띄우고 창을 찍어(/certs 2) 첫 키 회전이 「(refetch rate-limited)」로 거부됐고 — 첫 적재는
// 창을 쓰지 않는다는 불변식이 깨졌다 — 창 안에서는 그 창의 조회가 **가져온** 키를 가진 토큰이 거부됐다. 세운 자리
// 없이 공개 API 로만 재도 닿는다(실측: 회전 40 번에 1 번, k2 토큰 하나가 거부됨). 결정은 잠금 아래에서 캐시를 다시 본다.
func TestJWKSMissRechecksTheCacheBeforeDeciding(t *testing.T) {
	for _, warmFirst := range []bool{false, true} {
		name := "cold load"
		if warmFirst {
			name = "forced refetch inside the window"
		}
		t.Run(name, func(t *testing.T) {
			p := newFlightIdP(t)
			c := p.client(t)
			kid, key := "k1", p.k1
			if warmFirst {
				p.warm(t, c)
				p.rotate(t)
				kid, key = "k2", p.k2
			}
			release := p.hold(t)
			first := async(func() error { _, err := c.Auth.Validate(context.Background(), p.token(t, key, kid)); return err })
			p.waitArrived(t, "/certs")
			pc := &pauseCtx{Context: context.Background(), paused: make(chan struct{}), resume: make(chan struct{})}
			var resumeOnce sync.Once
			resume := func() { resumeOnce.Do(func() { close(pc.resume) }) }
			t.Cleanup(resume)
			second := async(func() error { _, err := c.Auth.Validate(pc, p.token(t, key, kid)); return err })
			select {
			case <-pc.paused: // 둘째의 조회는 비었다 — kid 를 가져올 조회는 아직 붙잡혀 있다
			case <-time.After(5 * time.Second):
				t.Fatal("the second caller never stopped between its cache lookup and the fetch decision")
			}
			release()
			if err := mustReturn(t, first, "the caller whose fetch brings the kid"); err != nil {
				t.Fatalf("the first caller: %v", err)
			}
			resume() // 이제 결정한다 — 조회는 끝났고 캐시가 kid 를 갖는다
			if err := mustReturn(t, second, "the caller that missed before the fill"); err != nil {
				t.Fatalf("a miss decided after the fill must find the cached key, got %v", err)
			}
			want := int32(1) // 콜드: 적재 하나 · 따뜻함: 적재와 강제 재조회 하나
			if warmFirst {
				want = 2
			}
			if n := p.certs.Load(); n != want {
				t.Fatalf("/certs=%d, want %d — a miss whose kid is cached must not fetch", n, want)
			}
			// 결정 자체가, 자기 잠금 아래에서, 캐시된 kid 를 봐야 한다 — 호출자가 잠그기 전에 한 번 더 찾는 것으로는
			// 같은 틈이 한 걸음 뒤로 갈 뿐이다(그 변형은 위의 세운 자리를 지나간다).
			v := c.Auth.val
			v.mu.Lock()
			stamp := v.forcedAt
			v.mu.Unlock()
			if f, err := v.fetchFor(context.Background(), kid); f != nil || err != nil {
				t.Fatalf("deciding for a cached kid must start, join and refuse nothing: flight %v, err %v", f != nil, err)
			}
			v.mu.Lock()
			restamped := !v.forcedAt.Equal(stamp)
			v.mu.Unlock()
			if restamped || p.certs.Load() != want {
				t.Fatalf("deciding for a cached kid touched the window (%v) or the IdP (/certs=%d)", restamped, p.certs.Load())
			}
			if !warmFirst {
				p.rotate(t)
				if _, err := c.Auth.Validate(context.Background(), p.token(t, p.k2, "k2")); err != nil {
					t.Fatalf("the first rotation after the cold load must be fetched (the load does not use the window), got %v", err)
				}
				if n := p.certs.Load(); n != 2 {
					t.Fatalf("/certs=%d, want 2 (cold load, the first rotation)", n)
				}
			}
		})
	}
}
