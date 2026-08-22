package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

const testISS = "https://kc.example.com/realms/test"

type jwtFixture struct {
	priv     *rsa.PrivateKey
	other    *rsa.PrivateKey // signs "forged" tokens (not in the JWKS)
	jwksSrv  *httptest.Server
	fetches  *int32
	rotateTo func() // swaps the served JWKS to a new key for rotation tests
}

func newJWTFixture(t *testing.T) *jwtFixture {
	t.Helper()
	priv, _ := rsa.GenerateKey(rand.Reader, 2048)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	var fetches int32
	current := jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
		{Key: &priv.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"},
	}}
	f := &jwtFixture{priv: priv, other: other, fetches: &fetches}
	f.jwksSrv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&fetches, 1)
		_ = json.NewEncoder(w).Encode(current)
	}))
	f.rotateTo = func() {
		current = jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
			{Key: &other.PublicKey, KeyID: "k2", Algorithm: "RS256", Use: "sig"},
		}}
	}
	t.Cleanup(f.jwksSrv.Close)
	return f
}

func (f *jwtFixture) validator(t *testing.T, minRefetch time.Duration) *Validator {
	t.Helper()
	return newValidator(validatorOptions{
		jwksURI: f.jwksSrv.URL, issuer: testISS, audience: "my-client",
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256}, clockSkewSec: 30, minRefetch: minRefetch,
	})
}

func (f *jwtFixture) sign(t *testing.T, key *rsa.PrivateKey, kid string, cl jwt.Claims) string {
	t.Helper()
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid))
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	s, err := jwt.Signed(sig).Claims(cl).Serialize()
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	return s
}

func claims(aud jwt.Audience, iss string, exp time.Time) jwt.Claims {
	return jwt.Claims{Subject: "user1", Issuer: iss, Audience: aud,
		Expiry: jwt.NewNumericDate(exp), IssuedAt: jwt.NewNumericDate(time.Now())}
}

func TestValidateValidToken(t *testing.T) {
	f := newJWTFixture(t)
	tok := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	vt, err := f.validator(t, time.Minute).Validate(context.Background(), tok)
	if err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if vt.Subject != "user1" || vt.Issuer != testISS || vt.ExpiresAt == 0 || vt.IssuedAt == 0 {
		t.Fatalf("validated token: %+v", vt)
	}
}

func TestValidateMultiAudienceMembership(t *testing.T) {
	f := newJWTFixture(t)
	tok := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client", "realm-management"}, testISS, time.Now().Add(5*time.Minute)))
	vt, err := f.validator(t, time.Minute).Validate(context.Background(), tok)
	if err != nil {
		t.Fatalf("multi-aud membership must pass: %v", err)
	}
	if len(vt.Audience) != 2 {
		t.Fatalf("audience: %v", vt.Audience)
	}
}

// TestExpectedAudienceWiring proves Config.ExpectedAudience reaches the Validator
// built by New: unset it still expects ClientID (unchanged behaviour), set it
// replaces that expectation — the resource-server case, where aud carries an API
// name rather than the client that asked for the token.
func TestExpectedAudienceWiring(t *testing.T) {
	f := newJWTFixture(t) // its handler serves the JWKS on every path, incl. /realms/test/…/certs
	iss := f.jwksSrv.URL + "/realms/test"
	token := func(aud string) string {
		return f.sign(t, f.priv, "k1", claims(jwt.Audience{aud}, iss, time.Now().Add(5*time.Minute)))
	}
	ctx := context.Background()
	cfg := Config{ServerURL: f.jwksSrv.URL, Realm: "test", ClientID: "my-client"}

	// (1) unset → ClientID is expected, exactly as before.
	c, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := c.Auth.Validate(ctx, token("my-client")); err != nil {
		t.Fatalf("unset ExpectedAudience must still accept aud=ClientID: %v", err)
	}
	if _, err := c.Auth.Validate(ctx, token("api://orders")); err == nil {
		t.Fatal("unset ExpectedAudience must still reject an aud without ClientID")
	}

	// (2) set → the configured value is expected instead of ClientID.
	cfg.ExpectedAudience = "api://orders"
	c, err = New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := c.Auth.Validate(ctx, token("api://orders")); err != nil {
		t.Fatalf("ExpectedAudience must be accepted: %v", err)
	}
	if _, err := c.Auth.Validate(ctx, token("my-client")); err == nil {
		t.Fatal("ExpectedAudience must replace ClientID, not be added to it")
	}
}

func TestValidateRejects(t *testing.T) {
	f := newJWTFixture(t)
	now := time.Now()
	cases := map[string]string{
		"wrong issuer": f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, "https://evil/realms/test", now.Add(5*time.Minute))),
		"missing aud":  f.sign(t, f.priv, "k1", claims(jwt.Audience{"other-client"}, testISS, now.Add(5*time.Minute))),
		"expired":      f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, now.Add(-5*time.Minute))),
	}
	for name, tok := range cases {
		if _, err := f.validator(t, time.Minute).Validate(context.Background(), tok); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

// TestValidateConfiguredClockSkewBoundary proves clockSkewSec=30 is wired into
// ValidateWithLeeway — not ignored and not relying on go-jose's zero-leeway default
// alone. Far-past expiry (e.g. now-5min) rejects under any reasonable skew and does
// not prove the configured value is applied. The pair below does: exp=now-10s must
// PASS (20s margin inside the 30s window) and exp=now-60s must fail with
// *TokenValidationError (30s margin past it). If skew were 0 (unwired) the first half
// fails; if a larger default were used instead of 30 the second half fails.
func TestValidateConfiguredClockSkewBoundary(t *testing.T) {
	f := newJWTFixture(t)
	now := time.Now()
	const skewSec int64 = 30
	v := newValidator(validatorOptions{
		jwksURI: f.jwksSrv.URL, issuer: testISS, audience: "my-client",
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256}, clockSkewSec: skewSec,
		minRefetch: time.Minute,
	})
	ctx := context.Background()

	within := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, now.Add(-10*time.Second)))
	if _, err := v.Validate(ctx, within); err != nil {
		t.Fatalf("exp 10s in the past MUST pass under configured clockSkewSec=30: %v", err)
	}

	beyond := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, now.Add(-60*time.Second)))
	_, err := v.Validate(ctx, beyond)
	if err == nil {
		t.Fatal("exp 60s in the past MUST be rejected under configured clockSkewSec=30")
	}
	var tve *TokenValidationError
	if !errors.As(err, &tve) {
		t.Fatalf("beyond-skew rejection must be *TokenValidationError, got %T: %v", err, err)
	}
}

func TestValidateRejectsAlgPinViolation(t *testing.T) {
	f := newJWTFixture(t)
	tok := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	v := newValidator(validatorOptions{jwksURI: f.jwksSrv.URL, issuer: testISS, audience: "my-client",
		allowedAlgs: []jose.SignatureAlgorithm{jose.ES256}, clockSkewSec: 30}) // RS256 not allowed
	if _, err := v.Validate(context.Background(), tok); err == nil {
		t.Fatal("RS256 token must be rejected when only ES256 is pinned")
	}
}

func TestValidateRejectsNoneAlg(t *testing.T) {
	f := newJWTFixture(t)
	// Hand-craft an unsigned ("alg":"none") token.
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT","kid":"k1"}`))
	pay := base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"u","iss":"` + testISS + `","aud":"my-client"}`))
	none := hdr + "." + pay + "."
	if _, err := f.validator(t, time.Minute).Validate(context.Background(), none); err == nil {
		t.Fatal("alg=none must be rejected")
	}
}

// Classic HS/RS confusion: the attacker signs HS256 using the *public* key bytes as the HMAC
// secret. If a validator trusted the header's alg to choose a key, "knows the public key" would
// become "can mint tokens".
//
// ⚠️ Mutation-verified: widening the pin to allow HS256 does NOT make this test pass — the
// rejection comes from the key source, not the algorithm pin. The JWKS yields an RSA key and
// go-jose will not verify an HMAC signature with it. So this test guards the key-selection
// boundary specifically; TestValidateRejectsAlgPinViolation is what guards the pin. Keep both:
// each covers a layer the other does not, and a future refactor could break either alone.
func TestValidateRejectsHS256ForgedWithRSAPublicKey(t *testing.T) {
	f := newJWTFixture(t)
	pubDER, err := x509.MarshalPKIXPublicKey(&f.priv.PublicKey)
	if err != nil {
		t.Fatalf("marshal public key: %v", err)
	}
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.HS256, Key: pubDER},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "k1"))
	if err != nil {
		t.Fatalf("hmac signer: %v", err)
	}
	forged, err := jwt.Signed(sig).
		Claims(claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute))).
		Serialize()
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if _, err := f.validator(t, time.Minute).Validate(context.Background(), forged); err == nil {
		t.Fatal("HS256 token forged with the RSA public key as the HMAC secret must be rejected")
	}
}

func TestValidateForgedSignatureNoRefetch(t *testing.T) {
	f := newJWTFixture(t)
	v := f.validator(t, time.Minute)
	good := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), good); err != nil {
		t.Fatalf("valid token: %v", err)
	}
	before := atomic.LoadInt32(f.fetches) // 1 (initial JWKS load)
	// Forged: signed by a key NOT in the JWKS but claiming kid=k1.
	forged := f.sign(t, f.other, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), forged); err == nil {
		t.Fatal("forged signature must be rejected")
	}
	if got := atomic.LoadInt32(f.fetches); got != before {
		t.Fatalf("forged signature triggered a JWKS refetch (%d → %d) — DoS amplification", before, got)
	}
}

func TestValidateUnknownKidRefetchOnceThenRateLimited(t *testing.T) {
	f := newJWTFixture(t)
	v := f.validator(t, time.Hour) // large window
	good := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), good); err != nil {
		t.Fatalf("initial: %v", err)
	}
	base := atomic.LoadInt32(f.fetches) // 1 — initial (non-forced) load; forcedAt not set

	// First unknown kid → forced refetch ALLOWED (key-rotation recovery, like Python/Java).
	unknown1 := f.sign(t, f.priv, "kX", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), unknown1); err == nil {
		t.Fatal("unknown kid must be rejected")
	}
	if got := atomic.LoadInt32(f.fetches); got != base+1 {
		t.Fatalf("first unknown kid (rotation) must refetch once: %d → %d", base, got)
	}

	// Second unknown kid within the window → rate-limited (no refetch — DoS bound).
	unknown2 := f.sign(t, f.priv, "kY", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), unknown2); err == nil {
		t.Fatal("unknown kid must be rejected")
	}
	if got := atomic.LoadInt32(f.fetches); got != base+1 {
		t.Fatalf("second unknown kid within window must be rate-limited: got %d, want %d", got, base+1)
	}
}

// ⚠️ **rate-limit 은 걸리는 쪽만 테스트돼 있었다.** 위 테스트는 (1) 첫 미상 kid → 재조회 허용,
// (2) 창 안의 두 번째 → 차단 을 본다. 그런데 **창이 지나 다시 허용되는 쪽**은 아무도 안 봤다.
// 조건 커버리지로 실측해서 나온 것이다(gobco):
//
//	jwt.go:133:29: condition "time.Since(v.forcedAt) < v.opts.minRefetch"
//	               was once true but never false
//
// 이쪽이 깨지면 rate-limit 이 **영구 잠금**이 된다 — 키 로테이션이 일어나도 SDK 가 새 JWKS 를
// 영원히 못 가져오고, 증상은 "특정 시점 이후 모든 토큰이 no key for kid" 다. DoS 상한을 지키는
// 것과 복구를 막는 것은 한 줄 차이이고, 그 한 줄이 여기다.
func TestValidateRefetchAllowedAgainAfterRateLimitWindowElapses(t *testing.T) {
	f := newJWTFixture(t)
	const window = 40 * time.Millisecond
	v := f.validator(t, window) // 실제로 만료시킬 수 있을 만큼 짧은 창

	good := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), good); err != nil {
		t.Fatalf("initial: %v", err)
	}
	base := atomic.LoadInt32(f.fetches)

	unknownKid := func(kid string) string {
		return f.sign(t, f.priv, kid, claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	}

	// 창 안 — 첫 번째는 허용(forcedAt 이 찍힌다), 두 번째는 차단.
	if _, err := v.Validate(context.Background(), unknownKid("kX")); err == nil {
		t.Fatal("unknown kid must be rejected")
	}
	if _, err := v.Validate(context.Background(), unknownKid("kY")); err == nil {
		t.Fatal("unknown kid must be rejected")
	}
	if got := atomic.LoadInt32(f.fetches); got != base+1 {
		t.Fatalf("창 안에서는 재조회가 한 번뿐이어야 한다: %d → %d", base, got)
	}

	// 창을 넉넉히 넘긴다(경계에 걸치지 않도록 2.5배).
	time.Sleep(window * 5 / 2)

	// 창이 지났으므로 재조회가 **다시 허용**돼야 한다 — 이것이 위 조건의 false 갈래다.
	if _, err := v.Validate(context.Background(), unknownKid("kZ")); err == nil {
		t.Fatal("unknown kid must be rejected")
	}
	if got := atomic.LoadInt32(f.fetches); got != base+2 {
		t.Fatalf("창이 지나면 재조회가 다시 허용돼야 한다(영구 잠금이면 키 로테이션에서 복구 불가): "+
			"got %d, want %d", got, base+2)
	}
}

func TestValidateRejectsMissingExp(t *testing.T) {
	f := newJWTFixture(t)
	// A validly-signed token with no exp claim must be rejected (not treated as non-expiring).
	tok := f.sign(t, f.priv, "k1", jwt.Claims{Subject: "u", Issuer: testISS,
		Audience: jwt.Audience{"my-client"}, IssuedAt: jwt.NewNumericDate(time.Now())})
	if _, err := f.validator(t, time.Minute).Validate(context.Background(), tok); err == nil {
		t.Fatal("token without exp must be rejected")
	}
}

func TestValidateFetchError(t *testing.T) {
	f := newJWTFixture(t)
	closed := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	closed.Close() // connection refused → fetch error
	v := newValidator(validatorOptions{jwksURI: closed.URL, issuer: testISS, audience: "my-client",
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256}, clockSkewSec: 30})
	tok := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), tok); err == nil {
		t.Fatal("JWKS fetch failure must surface as a validation error")
	}
}

func TestValidateInvalidJWKSJSON(t *testing.T) {
	f := newJWTFixture(t)
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("not-json"))
	}))
	t.Cleanup(bad.Close)
	v := newValidator(validatorOptions{jwksURI: bad.URL, issuer: testISS, audience: "my-client",
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256}, clockSkewSec: 30})
	tok := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), tok); err == nil {
		t.Fatal("malformed JWKS body must surface as a validation error")
	}
}

func TestValidateRefetchStillUnknownKid(t *testing.T) {
	f := newJWTFixture(t)
	v := f.validator(t, time.Millisecond) // tiny window → refetch allowed
	good := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), good); err != nil {
		t.Fatalf("initial: %v", err)
	}
	before := atomic.LoadInt32(f.fetches)
	time.Sleep(3 * time.Millisecond)
	unknown := f.sign(t, f.priv, "kZ", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), unknown); err == nil {
		t.Fatal("unknown kid absent after refetch must be rejected")
	}
	if got := atomic.LoadInt32(f.fetches); got <= before {
		t.Fatalf("expected a refetch (window elapsed): %d → %d", before, got)
	}
}

func TestValidateKeyRotationRecovery(t *testing.T) {
	f := newJWTFixture(t)
	v := f.validator(t, time.Millisecond) // tiny window → rotation refetch allowed
	good := f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), good); err != nil {
		t.Fatalf("initial: %v", err)
	}
	f.rotateTo() // JWKS now serves k2 (signed by f.other)
	time.Sleep(3 * time.Millisecond)
	rotated := f.sign(t, f.other, "k2", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
	if _, err := v.Validate(context.Background(), rotated); err != nil {
		t.Fatalf("key rotation must be recovered via refetch: %v", err)
	}
}
