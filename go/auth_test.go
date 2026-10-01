package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// authFixture spins up an httptest server standing in for a realm's OIDC
// endpoints and returns an AuthClient pointed at it.
type authFixture struct {
	srv    *httptest.Server
	auth   *AuthClient
	lastFn func(path string, form url.Values)
}

func newAuthFixture(t *testing.T, secret string) *authFixture {
	t.Helper()
	f := &authFixture{}
	mux := http.NewServeMux()
	base := "/realms/test/protocol/openid-connect"
	mux.HandleFunc(base+"/token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if f.lastFn != nil {
			f.lastFn("token", r.Form)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"AT","token_type":"Bearer","expires_in":300,` +
			`"refresh_token":"RT","scope":"openid","id_token":"IDT"}`))
	})
	mux.HandleFunc(base+"/token/introspect", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if f.lastFn != nil {
			f.lastFn("introspect", r.Form)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"active":true,"username":"svc","client_id":"it-client","sub":"u1"}`))
	})
	mux.HandleFunc(base+"/logout", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if f.lastFn != nil {
			f.lastFn("logout", r.Form)
		}
		w.WriteHeader(http.StatusNoContent)
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	cfg := Config{ServerURL: f.srv.URL, Realm: "test", ClientID: "app", ClientSecret: secret,
		ReadTimeout: 30000}.withDefaults()
	f.auth = newAuthClient(cfg, nil)
	return f
}

func TestCreateAuthorizationRequest(t *testing.T) {
	cfg := Config{ServerURL: "https://kc.example.com", Realm: "demo", ClientID: "app"}.withDefaults()
	a := newAuthClient(cfg, nil)
	req := a.CreateAuthorizationRequest("https://app/cb")
	u, err := url.Parse(req.URL)
	if err != nil {
		t.Fatalf("bad URL: %v", err)
	}
	q := u.Query()
	if u.Scheme+"://"+u.Host+u.Path != "https://kc.example.com/realms/demo/protocol/openid-connect/auth" {
		t.Fatalf("endpoint: %s", u.String())
	}
	for k, want := range map[string]string{
		"response_type": "code", "client_id": "app", "redirect_uri": "https://app/cb",
		"scope": "openid", "code_challenge_method": "S256", "state": req.State, "nonce": req.Nonce,
	} {
		if q.Get(k) != want {
			t.Errorf("%s = %q, want %q", k, q.Get(k), want)
		}
	}
	sum := sha256.Sum256([]byte(req.CodeVerifier))
	if q.Get("code_challenge") != base64.RawURLEncoding.EncodeToString(sum[:]) {
		t.Errorf("code_challenge must be base64url(sha256(verifier))")
	}
	// Distinct per call.
	b := a.CreateAuthorizationRequest("https://app/cb")
	if req.CodeVerifier == b.CodeVerifier || req.State == b.State || req.Nonce == b.Nonce {
		t.Error("verifier/state/nonce must differ per call")
	}
}

func TestClientCredentialsToken(t *testing.T) {
	f := newAuthFixture(t, "sekret")
	ts, err := f.auth.ClientCredentialsToken(context.Background())
	if err != nil {
		t.Fatalf("client credentials: %v", err)
	}
	if ts.AccessToken != "AT" || ts.RefreshToken != "RT" || ts.IDToken != "IDT" {
		t.Fatalf("token mapping: access=%q refresh=%q id=%q", ts.AccessToken, ts.RefreshToken, ts.IDToken)
	}
	if ts.ExpiresIn <= 0 || ts.ExpiresAt <= 0 {
		t.Fatalf("expiry mapping: ExpiresIn=%d ExpiresAt=%d", ts.ExpiresIn, ts.ExpiresAt)
	}
}

// ccAccessTokenCases is the access_token table the test below pins. It is package-level because
// hostile_path_matrix_test.go attaches every non-string row to every token-grant and code-exchange
// path it derives (Admin and the admin resources included), so the two cannot drift apart.
var ccAccessTokenCases = []struct {
	name        string
	raw         string
	accessToken string
}{
	{name: "number", raw: "12345"},
	{name: "object", raw: `{"a":1}`},
	{name: "array", raw: "[]"},
	{name: "boolean", raw: "true"},
	{name: "null", raw: "null"},
	{name: "empty string", raw: `""`},
	{name: "string", raw: `"AT"`, accessToken: "AT"},
}

// TestClientCredentialsRejectsNonStringAccessToken pins the client-credentials
// lane: token-endpoint access_token must be a non-empty JSON string. The
// "string" subtest is the positive control (raw value "AT").
//
// The rejection is golang.org/x/oauth2's, not ours (non-strings fail its JSON
// unmarshal; null and "" hit "server response missing access_token"). Nothing
// pinned that until now, so a more lenient oauth2 release would have let an
// unusable token out as success — .NET's Duende did exactly that. Measured on
// 2026-09-25: all six are *AuthError, so that is what this pins.
func TestClientCredentialsRejectsNonStringAccessToken(t *testing.T) {
	for _, tt := range ccAccessTokenCases {
		t.Run(tt.name, func(t *testing.T) {
			body := `{"access_token":` + tt.raw + `,"token_type":"Bearer","expires_in":300}`
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(body))
			}))
			t.Cleanup(srv.Close)
			cfg := Config{ServerURL: srv.URL, Realm: "test", ClientID: "app", ClientSecret: "sekret",
				ReadTimeout: 30000}.withDefaults()
			a := newAuthClient(cfg, nil)

			ts, err := a.ClientCredentialsToken(context.Background())
			if tt.accessToken != "" {
				if err != nil {
					t.Fatalf("string access_token: %v", err)
				}
				if ts == nil || ts.AccessToken != tt.accessToken {
					t.Fatalf("AccessToken = %+v, want %q", ts, tt.accessToken)
				}
				return
			}
			if err == nil || ts != nil {
				t.Fatalf("access_token %s must be rejected with a nil TokenSet; ts=%+v err=%v", tt.raw, ts, err)
			}
			var ae *AuthError
			if !errors.As(err, &ae) {
				t.Fatalf("want *AuthError, got %T: %v", err, err)
			}
		})
	}
}

func TestExchangeCodeAndRefresh(t *testing.T) {
	f := newAuthFixture(t, "sekret")
	var form url.Values
	f.lastFn = func(path string, fm url.Values) {
		if path == "token" {
			form = fm
		}
	}

	ts, err := f.auth.ExchangeCode(context.Background(), "the-code", "https://app/cb", "verifier", "")
	if err != nil || ts.AccessToken != "AT" {
		t.Fatalf("exchange: %+v %v", ts, err)
	}
	if form.Get("grant_type") != "authorization_code" || form.Get("code") != "the-code" ||
		form.Get("code_verifier") != "verifier" || form.Get("redirect_uri") != "https://app/cb" {
		t.Fatalf("exchange must send authorization_code + code + PKCE verifier + redirect_uri: %v", form)
	}

	ts2, err := f.auth.Refresh(context.Background(), "old-rt")
	if err != nil || ts2.AccessToken != "AT" {
		t.Fatalf("refresh: %+v %v", ts2, err)
	}
	if form.Get("grant_type") != "refresh_token" || form.Get("refresh_token") != "old-rt" {
		t.Fatalf("refresh must send refresh_token grant: %v", form)
	}
}

// signIDToken produces an RS256-signed id_token carrying a nonce claim, for the
// ExchangeCode nonce-replay tests.
func signIDToken(t *testing.T, key *rsa.PrivateKey, kid, iss, aud, nonce string) string {
	t.Helper()
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid))
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	std := jwt.Claims{Subject: "user1", Issuer: iss, Audience: jwt.Audience{aud},
		Expiry: jwt.NewNumericDate(time.Now().Add(5 * time.Minute)), IssuedAt: jwt.NewNumericDate(time.Now())}
	b := jwt.Signed(sig).Claims(std)
	if nonce != "" { // "" means the token carries no nonce claim at all
		b = b.Claims(map[string]any{"nonce": nonce})
	}
	s, err := b.Serialize()
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	return s
}

// TestExchangeCodeNonceValidation proves that when an expectedNonce is supplied,
// ExchangeCode fully signature-validates the returned id_token and rejects a
// mismatched / missing nonce (OIDC nonce replay protection). Empty nonce skips it.
func TestExchangeCodeNonceValidation(t *testing.T) {
	priv, _ := rsa.GenerateKey(rand.Reader, 2048)
	jwks := jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
		{Key: &priv.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"},
	}}
	base := "/realms/test/protocol/openid-connect"
	var issuer string
	includeIDToken := true
	serverNonce := "server-nonce"
	mux := http.NewServeMux()
	mux.HandleFunc(base+"/token", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if includeIDToken {
			idt := signIDToken(t, priv, "k1", issuer, "app", serverNonce)
			_, _ = w.Write([]byte(`{"access_token":"AT","token_type":"Bearer","expires_in":300,"id_token":"` + idt + `"}`))
		} else {
			_, _ = w.Write([]byte(`{"access_token":"AT","token_type":"Bearer","expires_in":300}`))
		}
	})
	mux.HandleFunc(base+"/certs", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(jwks)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	issuer = srv.URL + "/realms/test"

	v := newValidator(validatorOptions{
		jwksURI: srv.URL + base + "/certs", issuer: issuer, audience: "app",
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256}, clockSkewSec: 30, minRefetch: time.Minute,
	})
	cfg := Config{ServerURL: srv.URL, Realm: "test", ClientID: "app", ClientSecret: "sekret",
		ReadTimeout: 30000}.withDefaults()
	auth := newAuthClient(cfg, v)
	ctx := context.Background()

	// Matching nonce → accepted.
	ts, err := auth.ExchangeCode(ctx, "code", srv.URL+"/cb", "verifier", "server-nonce")
	if err != nil || ts.AccessToken != "AT" {
		t.Fatalf("matching nonce must pass: %+v %v", ts, err)
	}

	// Mismatched nonce → rejected as *AuthError.
	_, err = auth.ExchangeCode(ctx, "code", srv.URL+"/cb", "verifier", "attacker-nonce")
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Fatalf("mismatched nonce must yield *AuthError, got %v", err)
	}

	// Missing id_token while a nonce is expected → rejected (fail-closed).
	includeIDToken = false
	_, err = auth.ExchangeCode(ctx, "code", srv.URL+"/cb", "verifier", "server-nonce")
	if !errors.As(err, &ae) {
		t.Fatalf("missing id_token with expected nonce must yield *AuthError, got %v", err)
	}

	// A validly signed id_token with no nonce claim while a nonce is expected → rejected. Java pins
	// the same (exchangeCode_rejectsIdTokenWithoutNonceClaim). Without this case, reading the claim
	// as `n, ok := …; ok && n != expected` left the whole Go suite green (measured 2026-09-27).
	includeIDToken, serverNonce = true, ""
	_, err = auth.ExchangeCode(ctx, "code", srv.URL+"/cb", "verifier", "server-nonce")
	if !errors.As(err, &ae) {
		t.Fatalf("id_token without a nonce claim must yield *AuthError, got %v", err)
	}
}

// audIdP stands in for a realm in the id_token audience tests: the token endpoint answers with the
// id_token stored in idTok, and /certs counts every JWKS request (answering 503 while down is set).
type audIdP struct {
	srv   *httptest.Server
	priv  *rsa.PrivateKey
	other *rsa.PrivateKey // not in the JWKS
	certs atomic.Int32
	down  atomic.Bool
	idTok atomic.Value // string
}

const (
	audClientID = "app"
	audOverride = "api://orders" // Config.ExpectedAudience: a resource server, not the client
)

func newAudIdP(t *testing.T) *audIdP {
	t.Helper()
	p := &audIdP{}
	var err error
	if p.priv, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
		t.Fatal(err)
	}
	if p.other, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
		t.Fatal(err)
	}
	jwks := jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
		{Key: &p.priv.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"},
	}}
	base := "/realms/test/protocol/openid-connect"
	mux := http.NewServeMux()
	mux.HandleFunc(base+"/token", func(w http.ResponseWriter, _ *http.Request) {
		idt, _ := p.idTok.Load().(string)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"AT","token_type":"Bearer","expires_in":300,"id_token":"` + idt + `"}`))
	})
	mux.HandleFunc(base+"/certs", func(w http.ResponseWriter, _ *http.Request) {
		p.certs.Add(1)
		if p.down.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_ = json.NewEncoder(w).Encode(jwks)
	})
	p.srv = httptest.NewServer(mux)
	t.Cleanup(p.srv.Close)
	return p
}

// client is built by New — New's wiring is what is under test — with ExpectedAudience overridden.
func (p *audIdP) client(t *testing.T) *Client {
	t.Helper()
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "test", ClientID: audClientID, ClientSecret: "s",
		ExpectedAudience: audOverride})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// claims is a well-formed claim set from this realm for the given audiences.
func (p *audIdP) claims(aud ...string) jwt.Claims {
	return jwt.Claims{Subject: "user1", Issuer: p.srv.URL + "/realms/test", Audience: jwt.Audience(aud),
		Expiry: jwt.NewNumericDate(time.Now().Add(5 * time.Minute)), IssuedAt: jwt.NewNumericDate(time.Now())}
}

// sign serialises cl signed by key under alg with header kid; an empty nonce leaves the claim out.
func (p *audIdP) sign(t *testing.T, key *rsa.PrivateKey, alg jose.SignatureAlgorithm, kid string, cl jwt.Claims, nonce string) string {
	t.Helper()
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: alg, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid))
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	b := jwt.Signed(sig).Claims(cl)
	if nonce != "" {
		b = b.Claims(map[string]any{"nonce": nonce})
	}
	s, err := b.Serialize()
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	return s
}

// idToken is a genuine id_token for the given audiences, carrying nonce "n".
func (p *audIdP) idToken(t *testing.T, aud ...string) string {
	t.Helper()
	return p.sign(t, p.priv, jose.RS256, "k1", p.claims(aud...), "n")
}

// exchange makes the token endpoint return idToken and runs ExchangeCode expecting nonce.
func (p *audIdP) exchange(c *Client, idToken, nonce string) error {
	p.idTok.Store(idToken)
	_, err := c.Auth.ExchangeCode(context.Background(), "code", p.srv.URL+"/cb", "verifier", nonce)
	return err
}

// requireIDTokenRefused asserts that err is the exchange's invalid-id_token refusal and that the cause is a
// TokenValidationError from the named stage ("claims: ", "parse: ", "signature: ").
func requireIDTokenRefused(t *testing.T, err error, stage, what string) *TokenValidationError {
	t.Helper()
	var ae *AuthError
	if !errors.As(err, &ae) || ae.Msg != "authorization code exchange failed: invalid id_token" {
		t.Fatalf("%s: want the invalid-id_token AuthError, got %v", what, err)
	}
	var tve *TokenValidationError
	if !errors.As(err, &tve) || !strings.HasPrefix(tve.Msg, stage) {
		t.Fatalf("%s: want a TokenValidationError from %q, got %v", what, stage, err)
	}
	return tve
}

// TestExchangeCodeIDTokenAudienceIsTheClientIDUnderAnOverride pins the audience contract of the code exchange
// when Config.ExpectedAudience names a resource server. OIDC Core §2 and §3.1.3.7: an id_token's aud MUST
// contain the client_id, and the client MUST reject one that does not list it. ExpectedAudience is the
// access-token audience (RFC 9700 §2.3), so it keeps governing Validate and nothing else.
func TestExchangeCodeIDTokenAudienceIsTheClientIDUnderAnOverride(t *testing.T) {
	ctx := context.Background()
	p := newAudIdP(t)
	c := p.client(t)

	// A1: the id_token names the client, alone or beside other audiences — the exchange passes.
	for _, aud := range [][]string{{audClientID}, {audOverride, audClientID}} {
		if err := p.exchange(c, p.idToken(t, aud...), "n"); err != nil {
			t.Fatalf("A1: id_token aud=%v must pass under ExpectedAudience=%q: %v", aud, audOverride, err)
		}
	}

	// A2: an id_token that does not name the client is refused by the audience check — also when its aud is
	// exactly the override, which is what the access-token validator would have accepted.
	for _, aud := range [][]string{{audOverride}, {"someone-else"}} {
		err := p.exchange(c, p.idToken(t, aud...), "n")
		requireIDTokenRefused(t, err, "claims: ", "A2 aud="+strings.Join(aud, ","))
		if !errors.Is(err, jwt.ErrInvalidAudience) {
			t.Fatalf("A2: id_token aud=%v must fail the audience check, got %v", aud, err)
		}
	}

	// A3: Validate still looks for the override — and only the override.
	access := func(aud string) string { return p.sign(t, p.priv, jose.RS256, "k1", p.claims(aud), "") }
	if _, err := c.Auth.Validate(ctx, access(audOverride)); err != nil {
		t.Fatalf("A3: an access token for the override must pass Validate: %v", err)
	}
	_, err := c.Auth.Validate(ctx, access(audClientID))
	if !errors.Is(err, jwt.ErrInvalidAudience) {
		t.Fatalf("A3: under the override Validate must refuse aud=%q, got %v", audClientID, err)
	}
}

// TestExchangeCodeIDTokenChecksUnchangedUnderAnOverride pins A4: moving the id_token onto the client id changed
// only its audience. iss, the algorithm pin, the signature, exp with its skew and the nonce comparison are
// still enforced on the exchange, under the same override.
func TestExchangeCodeIDTokenChecksUnchangedUnderAnOverride(t *testing.T) {
	p := newAudIdP(t)
	c := p.client(t)
	withClaims := func(edit func(*jwt.Claims)) string {
		cl := p.claims(audClientID)
		edit(&cl)
		return p.sign(t, p.priv, jose.RS256, "k1", cl, "n")
	}

	// iss: exact match.
	err := p.exchange(c, withClaims(func(cl *jwt.Claims) { cl.Issuer = "https://evil.example/realms/test" }), "n")
	requireIDTokenRefused(t, err, "claims: ", "foreign iss")
	if !errors.Is(err, jwt.ErrInvalidIssuer) {
		t.Fatalf("foreign iss: want the issuer check, got %v", err)
	}

	// Algorithm pin: RS512 by the realm's own key is a valid signature, but not a pinned algorithm.
	requireIDTokenRefused(t, p.exchange(c, p.sign(t, p.priv, jose.RS512, "k1", p.claims(audClientID), "n"), "n"),
		"parse: ", "RS512 id_token")

	// Signature: a key outside the JWKS under the realm's kid.
	requireIDTokenRefused(t, p.exchange(c, p.sign(t, p.other, jose.RS256, "k1", p.claims(audClientID), "n"), "n"),
		"signature: ", "foreign key")

	// exp and its 30s skew: inside the skew passes, past it and absent are refused.
	if err := p.exchange(c, withClaims(func(cl *jwt.Claims) {
		cl.Expiry = jwt.NewNumericDate(time.Now().Add(-10 * time.Second))
	}), "n"); err != nil {
		t.Fatalf("exp 10s ago is inside the 30s skew and must pass: %v", err)
	}
	err = p.exchange(c, withClaims(func(cl *jwt.Claims) {
		cl.Expiry = jwt.NewNumericDate(time.Now().Add(-2 * time.Minute))
	}), "n")
	requireIDTokenRefused(t, err, "claims: ", "expired")
	if !errors.Is(err, jwt.ErrExpired) {
		t.Fatalf("expired: want the expiry check, got %v", err)
	}
	requireIDTokenRefused(t, p.exchange(c, withClaims(func(cl *jwt.Claims) { cl.Expiry = nil }), "n"),
		"claims: missing required exp", "no exp")

	// Nonce: compared after validation — a mismatch and an absent claim are both refused.
	for what, idt := range map[string]string{
		"mismatched nonce": p.idToken(t, audClientID),
		"absent nonce":     p.sign(t, p.priv, jose.RS256, "k1", p.claims(audClientID), ""),
	} {
		var ae *AuthError
		if err := p.exchange(c, idt, "m"); !errors.As(err, &ae) || ae.Msg != "authorization code exchange failed: unexpected nonce" {
			t.Fatalf("%s: want the unexpected-nonce AuthError, got %v", what, err)
		}
	}
	if n := p.certs.Load(); n != 1 {
		t.Fatalf("every id_token above resolves kid k1 from the one cached JWKS: /certs=%d, want 1", n)
	}
}

// TestExchangeCodeAndValidateShareOneKeyStore pins A5: the id_token check has no key store of its own. The JWKS
// cache, the forced-refetch window (JwksMinRefetch) and the cold-cache failure backoff are the SAME state for
// the exchange and for Validate — a second store would double the cold load on the IdP and let one path fetch
// while the other is inside its window. The control subtest proves the count sees a second store.
func TestExchangeCodeAndValidateShareOneKeyStore(t *testing.T) {
	ctx := context.Background()
	access := func(p *audIdP, kid string) string {
		return p.sign(t, p.priv, jose.RS256, kid, p.claims(audOverride), "")
	}

	t.Run("OneColdLoadForBoth", func(t *testing.T) {
		p := newAudIdP(t)
		c := p.client(t)
		if err := p.exchange(c, p.idToken(t, audClientID), "n"); err != nil {
			t.Fatalf("exchange: %v", err)
		}
		if _, err := c.Auth.Validate(ctx, access(p, "k1")); err != nil {
			t.Fatalf("validate: %v", err)
		}
		if n := p.certs.Load(); n != 1 {
			t.Fatalf("an exchange followed by Validate must cost one JWKS fetch, got /certs=%d", n)
		}
	})

	t.Run("ControlASecondStoreIsCounted", func(t *testing.T) {
		// What a separate id_token validator would be: same options, its own store.
		p := newAudIdP(t)
		c := p.client(t)
		opts := c.Auth.val.opts
		opts.audience = audClientID
		if _, err := newValidator(opts).Validate(ctx, p.idToken(t, audClientID)); err != nil {
			t.Fatalf("control id_token: %v", err)
		}
		if _, err := c.Auth.Validate(ctx, access(p, "k1")); err != nil {
			t.Fatalf("control validate: %v", err)
		}
		if n := p.certs.Load(); n != 2 {
			t.Fatalf("control: a second store must cost a second cold load, got /certs=%d — the count above is blind", n)
		}
	})

	t.Run("OneForcedRefetchWindow", func(t *testing.T) {
		p := newAudIdP(t)
		c := p.client(t)
		if err := p.exchange(c, p.idToken(t, audClientID), "n"); err != nil { // cold load: 1
			t.Fatalf("exchange: %v", err)
		}
		if _, err := c.Auth.Validate(ctx, access(p, "rotated")); err == nil { // forced refetch: 2
			t.Fatal("an unknown kid must not validate")
		}
		if n := p.certs.Load(); n != 2 {
			t.Fatalf("Validate's unknown kid must force one refetch, got /certs=%d", n)
		}
		idt := p.sign(t, p.priv, jose.RS256, "rotated-too", p.claims(audClientID), "n")
		tve := requireIDTokenRefused(t, p.exchange(c, idt, "n"), "key: ", "unknown kid inside the window")
		if !strings.Contains(tve.Msg, "rate-limited") {
			t.Fatalf("the exchange's unknown kid must hit Validate's window, got %v", tve)
		}
		if n := p.certs.Load(); n != 2 {
			t.Fatalf("the exchange must share Validate's forced-refetch window, got /certs=%d", n)
		}
	})

	t.Run("OneColdCacheBackoff", func(t *testing.T) {
		p := newAudIdP(t)
		c := p.client(t)
		frozen := time.Now()
		c.Auth.val.opts.now = func() time.Time { return frozen } // the backoff window never elapses
		p.down.Store(true)
		requireIDTokenRefused(t, p.exchange(c, p.idToken(t, audClientID), "n"), "key: ", "cold JWKS outage")
		if n := p.certs.Load(); n != 1 {
			t.Fatalf("the failed exchange must cost one JWKS fetch, got /certs=%d", n)
		}
		_, err := c.Auth.Validate(ctx, access(p, "k1"))
		if err == nil || !strings.Contains(err.Error(), "backing off") {
			t.Fatalf("Validate after the failed exchange must sit in the shared backoff, got %v", err)
		}
		if n := p.certs.Load(); n != 1 {
			t.Fatalf("Validate inside the exchange's backoff must not fetch, got /certs=%d", n)
		}
	})
}

func TestIntrospect(t *testing.T) {
	f := newAuthFixture(t, "sekret")
	r, err := f.auth.Introspect(context.Background(), "tok")
	if err != nil {
		t.Fatalf("introspect: %v", err)
	}
	if !r.Active || r.Username != "svc" || r.ClientID != "it-client" || r.Claims["sub"] != "u1" {
		t.Fatalf("introspection result: %+v", r)
	}
}

func TestLogoutPostsCredentials(t *testing.T) {
	f := newAuthFixture(t, "sekret")
	var got url.Values
	f.lastFn = func(path string, form url.Values) {
		if path == "logout" {
			got = form
		}
	}
	if err := f.auth.Logout(context.Background(), "RT"); err != nil {
		t.Fatalf("logout: %v", err)
	}
	if got.Get("refresh_token") != "RT" || got.Get("client_id") != "app" || got.Get("client_secret") != "sekret" {
		t.Fatalf("logout form: %v", got)
	}
}

func TestClientCredentialsErrorMapping(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_client","error_description":"bad"}`))
	}))
	t.Cleanup(srv.Close)
	// The server has no realm path; point token URL straight at it via a realm that maps to "/".
	cfg := Config{ServerURL: srv.URL, Realm: "test", ClientID: "app", ClientSecret: "x"}.withDefaults()
	a := newAuthClient(cfg, nil)
	_, err := a.ClientCredentialsToken(context.Background())
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Fatalf("expected *AuthError, got %v", err)
	}
	if ae.OAuthError != "invalid_client" {
		t.Fatalf("OAuthError = %q, want invalid_client", ae.OAuthError)
	}
}

func TestLogoutErrorStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
	}))
	t.Cleanup(srv.Close)
	cfg := Config{ServerURL: srv.URL, Realm: "test", ClientID: "app", ClientSecret: "x"}.withDefaults()
	a := newAuthClient(cfg, nil)
	if err := a.Logout(context.Background(), "RT"); err == nil || !strings.Contains(err.Error(), "HTTP 400") {
		t.Fatalf("logout must surface HTTP 400: %v", err)
	}
}

// postForm 은 `>= 400` 만 실패로 봤다. SDK 는 리다이렉트를 일부러 따라가지 않고
// (`noFollowRedirect`) 3xx 를 **호출자에게 그대로 올리므로**, 그 판정은 302 를 성공으로 읽는다.
// 결과: 세션이 살아 있는데 Logout 이 nil 을 돌려주고, Introspect 는 빈 본문을 파싱한다.
// 성공은 2xx 다 — 그 밖은 전부 오류로 닫는다.
func TestPostFormRejectsNon2xx(t *testing.T) {
	// ⚠️ 1xx 는 넣지 않는다 — net/http 를 통해서는 도달할 수 없다. 실측(probe): 핸들러가
	// `WriteHeader(100)` 을 써도 전송 계층이 informational 응답을 소비하고 클라이언트가 보는
	// 최종 상태는 **200** 이다. 넣으면 코드가 아니라 테스트가 틀린 채로 빨개진다.
	for _, code := range []int{
		http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther,
		http.StatusTemporaryRedirect, http.StatusPermanentRedirect,
	} {
		t.Run(http.StatusText(code), func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Location", "/elsewhere")
				w.WriteHeader(code)
			}))
			t.Cleanup(srv.Close)
			cfg := Config{ServerURL: srv.URL, Realm: "test", ClientID: "app", ClientSecret: "x"}.withDefaults()
			a := newAuthClient(cfg, nil)

			err := a.Logout(context.Background(), "RT")
			if err == nil {
				t.Fatalf("Logout 이 HTTP %d 를 성공으로 읽었다 — 세션이 살아 있는데 nil 을 돌려준다", code)
			}
			if !strings.Contains(err.Error(), "HTTP "+strconv.Itoa(code)) {
				t.Fatalf("오류는 실제 상태코드를 담아야 한다(HTTP %d): %v", code, err)
			}
		})
	}
}
