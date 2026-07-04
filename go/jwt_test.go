package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
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
