package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// JWKS 키셋의 수명 — 성공한 조회가 받은 키셋은 그 조회가 끝난 때부터 300 초만 쓴다(아홉 언어 공통, 판정 2026-10-29 ·
// 등록부 jwks-cache-lifetime-divergent). 그 나이에 이르면 캐시는 콜드와 똑같다: 다음 조회가 콜드 적재의 길(같은
// 비행 · 같은 실패 백오프)로 다시 받고, 그 조회가 실패하면 검증이 실패한다 — 낡은 키로 물러서지 않는다.
//
// ⚠️ 게이트 시계(opts.now)만 옮긴다 — 토큰의 exp 는 벽시계로 검사하므로 시계가 몇 분을 건너도 토큰은 유효하다.
// 시각은 리터럴로 적는다 — 상수에서 끌어 쓰면 상수가 바뀔 때 이 시험도 함께 움직인다.

// maxAgeIdP 는 키셋을 바꿔 낼 수 있고 장애(비-200)를 켤 수 있는 /certs 다. 요청을 센다.
type maxAgeIdP struct {
	srv    *httptest.Server
	k1, k2 *rsa.PrivateKey
	mu     sync.Mutex
	set    []byte
	status int
	certs  atomic.Int32
}

func newMaxAgeIdP(t *testing.T) *maxAgeIdP {
	t.Helper()
	p := &maxAgeIdP{status: http.StatusOK}
	var err error
	if p.k1, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
		t.Fatal(err)
	}
	if p.k2, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
		t.Fatal(err)
	}
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		p.certs.Add(1)
		p.mu.Lock()
		status, set := p.status, p.set
		p.mu.Unlock()
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(set)
	}))
	t.Cleanup(p.srv.Close)
	return p
}

// serve 는 이제부터 낼 키셋을 kid 로 고른다(k1 · k2).
func (p *maxAgeIdP) serve(t *testing.T, kids ...string) {
	t.Helper()
	var ks jose.JSONWebKeySet
	for _, kid := range kids {
		key := p.k1
		if kid == "k2" {
			key = p.k2
		}
		ks.Keys = append(ks.Keys, jose.JSONWebKey{Key: &key.PublicKey, KeyID: kid, Algorithm: "RS256", Use: "sig"})
	}
	b, err := json.Marshal(ks)
	if err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	p.set = b
	p.mu.Unlock()
}

func (p *maxAgeIdP) setStatus(status int) {
	p.mu.Lock()
	p.status = status
	p.mu.Unlock()
}

func (p *maxAgeIdP) validator(now func() time.Time) *Validator {
	return newValidator(validatorOptions{
		jwksURI: p.srv.URL, issuer: testISS, audience: "my-client",
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256}, clockSkewSec: 30,
		minRefetch: 30 * time.Second, now: now,
	})
}

func (p *maxAgeIdP) token(t *testing.T, kid string) string {
	t.Helper()
	key := p.k1
	if kid == "k2" {
		key = p.k2
	}
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid))
	if err != nil {
		t.Fatal(err)
	}
	s, err := jwt.Signed(sig).Claims(claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(10*time.Minute))).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// expect 는 kid 토큰 하나를 검증하고, 기대한 결과(wantErr 가 빈 문자열이면 통과, 아니면 그 문구를 담은 거부)와
// 그 뒤의 /certs 요청 수를 단언한다.
func (p *maxAgeIdP) expect(t *testing.T, v *Validator, kid, wantErr string, wantCerts int32, why string) {
	t.Helper()
	_, err := v.Validate(context.Background(), p.token(t, kid))
	switch {
	case wantErr == "" && err != nil:
		t.Fatalf("%s: %s must validate, got %v", why, kid, err)
	case wantErr != "" && (err == nil || !strings.Contains(err.Error(), wantErr)):
		t.Fatalf("%s: %s must be rejected with %q, got %v", why, kid, wantErr, err)
	}
	if n := p.certs.Load(); n != wantCerts {
		t.Fatalf("%s: /certs=%d, want %d (%v)", why, n, wantCerts, err)
	}
}

// TestJWKSKeySetIsUsedFor300SecondsThenFetchedAgain (T1 정상 만료) — 299 초에는 조회 없이 통과하고, 301 초에는 정확히
// 한 번 조회하고 통과한다(방금 받은 키셋의 나이는 0 이라 그다음은 조회하지 않는다).
func TestJWKSKeySetIsUsedFor300SecondsThenFetchedAgain(t *testing.T) {
	p := newMaxAgeIdP(t)
	p.serve(t, "k1")
	t0 := time.Now()
	clk := &stepClock{t: t0}
	v := p.validator(clk.now)
	p.expect(t, v, "k1", "", 1, "warm load at t0")
	clk.set(t0.Add(299 * time.Second))
	p.expect(t, v, "k1", "", 1, "299 s — the cached set still answers")
	clk.set(t0.Add(301 * time.Second))
	p.expect(t, v, "k1", "", 2, "301 s — the set has expired and is fetched once")
	p.expect(t, v, "k1", "", 2, "right after — the set just fetched is new")
}

// TestJWKSExpiredKeySetIsNotUsedDuringAnOutage (T2 만료 뒤 장애) — 301 초의 검증은 한 번 조회하고 IdP 의 503 으로
// 거부되며(캐시된 kid 라도 — 낡은 키로 물러서지 않는다), 백오프 창 안은 조회 없이 거부되고, IdP 가 회복하고 창이
// 지나면 한 번 조회하고 통과한다. 창의 탐침은 jitter 와 무관하다 — 첫 창은 0.2초 × [0.5, 1.0) = [100ms, 200ms) 다.
func TestJWKSExpiredKeySetIsNotUsedDuringAnOutage(t *testing.T) {
	p := newMaxAgeIdP(t)
	p.serve(t, "k1")
	t0 := time.Now()
	clk := &stepClock{t: t0}
	v := p.validator(clk.now)
	p.expect(t, v, "k1", "", 1, "warm load at t0")
	p.setStatus(http.StatusServiceUnavailable)
	t1 := t0.Add(301 * time.Second)
	clk.set(t1)
	p.expect(t, v, "k1", "HTTP 503", 2, "301 s, IdP down — the expired set must not be used")
	for range 5 {
		p.expect(t, v, "k1", "backing off", 2, "inside the backoff window")
	}
	clk.set(t1.Add(100*time.Millisecond - time.Nanosecond))
	p.expect(t, v, "k1", "backing off", 2, "still inside the shortest first window")
	p.setStatus(http.StatusOK)
	clk.set(t1.Add(200 * time.Millisecond))
	p.expect(t, v, "k1", "", 3, "IdP recovered and the window has passed")
}

// TestJWKSKeyRemovedFromTheSetIsRejectedOnceTheSetExpires (T3 지운 키) — k1·k2 로 적재, IdP 가 이제 k2 만 낸다:
// 299 초에는 캐시가 답하고(대조), 301 초에 k1 토큰은 재조회 뒤 거부되며 k2 토큰은 그 키셋으로 통과한다.
func TestJWKSKeyRemovedFromTheSetIsRejectedOnceTheSetExpires(t *testing.T) {
	p := newMaxAgeIdP(t)
	p.serve(t, "k1", "k2")
	t0 := time.Now()
	clk := &stepClock{t: t0}
	v := p.validator(clk.now)
	p.expect(t, v, "k1", "", 1, "warm load at t0 (k1 and k2)")
	p.serve(t, "k2")
	clk.set(t0.Add(299 * time.Second))
	p.expect(t, v, "k1", "", 1, "299 s — control: within its age the cached set answers")
	clk.set(t0.Add(301 * time.Second))
	p.expect(t, v, "k1", `no key for kid "k1"`, 2, "301 s — refetched, k1 is gone")
	p.expect(t, v, "k2", "", 2, "k2 validates from the set just fetched")
}

// TestJWKSForcedRefetchRestartsTheAge (T4) — 100 초의 미해결 kid 강제 재조회(회전한 k2)가 성공하면 키셋을 바꾸고
// 나이를 다시 센다: 350 초(그 재조회로부터 250 초)에는 조회가 없고, 401 초(301 초)에는 한 번 있다.
func TestJWKSForcedRefetchRestartsTheAge(t *testing.T) {
	p := newMaxAgeIdP(t)
	p.serve(t, "k1")
	t0 := time.Now()
	clk := &stepClock{t: t0}
	v := p.validator(clk.now)
	p.expect(t, v, "k1", "", 1, "warm load at t0")
	p.serve(t, "k1", "k2")
	clk.set(t0.Add(100 * time.Second))
	p.expect(t, v, "k2", "", 2, "100 s — an unknown kid forces a refetch")
	clk.set(t0.Add(350 * time.Second))
	p.expect(t, v, "k1", "", 2, "350 s — 250 s after the refetch, no fetch")
	clk.set(t0.Add(401 * time.Second))
	p.expect(t, v, "k1", "", 3, "401 s — 301 s after the refetch, the restarted age has run out")
}

// TestJWKSExpiredSetReloadIsOneSharedFlight — 나이가 찬 키셋의 재적재도 콜드 적재와 같은 비행이다: IdP 가 그 조회를
// 붙잡아 둔 동안 들어온 검증 스물은 그 하나를 기다리고, 풀리면 모두 그 키셋으로 통과한다(/certs 는 적재와 재적재
// 둘). 비행에 합류하지 않고 각자 다시 받으면 여기서 21 이 된다.
func TestJWKSExpiredSetReloadIsOneSharedFlight(t *testing.T) {
	p := newFlightIdP(t)
	c := p.client(t)
	t0 := time.Now()
	clk := &stepClock{t: t0}
	c.Auth.val.opts.now = clk.now
	p.warm(t, c)
	clk.set(t0.Add(301 * time.Second))
	release := p.hold(t)
	tok := p.token(t, p.k1, "k1")
	results := make(chan error, 20)
	for range 20 {
		go func() { _, err := c.Auth.Validate(context.Background(), tok); results <- err }()
	}
	p.waitArrived(t, "/certs")
	mustStillWait(t, results, "a validation on the expired set")
	release()
	for i := range 20 {
		if err := mustReturn(t, results, "a validation on the expired set"); err != nil {
			t.Fatalf("validation %d: %v", i, err)
		}
	}
	if n := p.certs.Load(); n != 2 {
		t.Fatalf("/certs=%d, want 2 — twenty misses on an expired set must share one reload", n)
	}
}

// TestJWKSBackoffJitterIsDrawnOnceWhenTheFailureIsRecorded (등록부 backoff-jitter-redrawn-per-check) — 실패 하나 뒤
// 같은 순간의 거듭된 검사는 같은 답이고, 창의 끝은 검사 사이에 움직이지 않는다. jitter 이음매는 뽑을 때마다 0.95 와
// 0.5 를 번갈아 낸다: 실패를 기록할 때 한 번 뽑으면 첫 창은 0.2초 × 0.95 = 190ms 다. 검사마다 뽑으면 둘째 검사가
// 0.5(창 100ms)를 받아 150ms 에 IdP 로 나가고, 같은 실패가 한 번은 거부하고 한 번은 통과시킨다.
func TestJWKSBackoffJitterIsDrawnOnceWhenTheFailureIsRecorded(t *testing.T) {
	srv, hits := failingJWKS(t)
	var draws atomic.Int32
	start := time.Now()
	clk := &stepClock{t: start}
	v := newValidator(validatorOptions{jwksURI: srv.URL, issuer: testISS, audience: "my-client",
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256}, clockSkewSec: 30, minRefetch: 30 * time.Second,
		now: clk.now, jitter: func() float64 {
			if draws.Add(1)%2 == 1 {
				return 0.95
			}
			return 0.5
		}})
	lookup := func() string {
		t.Helper()
		_, err := v.resolveKey(context.Background(), "k1")
		if err == nil {
			t.Fatal("the lookup must fail while the IdP is down")
		}
		return err.Error()
	}

	lookup() // 실패 1(콜드 캐시)
	clk.set(start.Add(150 * time.Millisecond))
	const inWindow = "keycloak: transport: JWKS fetch backing off after 1 consecutive failures (retry in 0.04s)"
	for i := range 6 {
		if got := lookup(); got != inWindow {
			t.Fatalf("check %d at the same instant: got %q, want %q", i, got, inWindow)
		}
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("checks inside the window reached the IdP: %d requests, want 1", n)
	}
	clk.set(start.Add(190*time.Millisecond - time.Nanosecond))
	if got := lookup(); !strings.Contains(got, "backing off") {
		t.Fatalf("1ns before the window's end the check must still refuse (the end did not move earlier), got %q", got)
	}
	clk.set(start.Add(190 * time.Millisecond))
	if got := lookup(); strings.Contains(got, "backing off") {
		t.Fatalf("at the window's end the check must let the fetch go (the end did not move later), got %q", got)
	}
	if n := atomic.LoadInt32(hits); n != 2 {
		t.Fatalf("IdP requests %d, want 2", n)
	}
	if n := draws.Load(); n != 2 {
		t.Fatalf("jitter drawn %d times, want 2 — once per recorded failure, never per check", n)
	}
}
