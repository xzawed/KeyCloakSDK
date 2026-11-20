package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
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
// ExchangeCode nonce-replay tests. Its payload typ is "ID", as on every id_token
// Keycloak issues — the id_token check refuses any other.
func signIDToken(t *testing.T, key *rsa.PrivateKey, kid, iss, aud, nonce string) string {
	t.Helper()
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid))
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	std := jwt.Claims{Subject: "user1", Issuer: iss, Audience: jwt.Audience{aud},
		Expiry: jwt.NewNumericDate(time.Now().Add(5 * time.Minute)), IssuedAt: jwt.NewNumericDate(time.Now())}
	b := jwt.Signed(sig).Claims(std).Claims(map[string]any{"typ": "ID"})
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

// sign serialises cl signed by key under alg with header kid; an empty nonce leaves the claim out. It is an access
// token: typ "Bearer", as Keycloak writes it (Validate accepts only Bearer or DPoP); an id_token is signID.
func (p *audIdP) sign(t *testing.T, key *rsa.PrivateKey, alg jose.SignatureAlgorithm, kid string, cl jwt.Claims, nonce string) string {
	t.Helper()
	return p.signTyped(t, key, alg, kid, cl, nonce, "Bearer")
}

// signID is sign for an id_token: its payload typ is "ID", as on every id_token Keycloak issues — the id_token check
// (ValidateIDToken, and the exchange through it) refuses any other typ.
func (p *audIdP) signID(t *testing.T, key *rsa.PrivateKey, alg jose.SignatureAlgorithm, kid string, cl jwt.Claims, nonce string) string {
	t.Helper()
	return p.signTyped(t, key, alg, kid, cl, nonce, "ID")
}

// signTyped is sign and signID: an empty nonce leaves that claim out.
func (p *audIdP) signTyped(t *testing.T, key *rsa.PrivateKey, alg jose.SignatureAlgorithm, kid string, cl jwt.Claims, nonce, typ string) string {
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
	if typ != "" {
		b = b.Claims(map[string]any{"typ": typ})
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
	return p.signID(t, p.priv, jose.RS256, "k1", p.claims(aud...), "n")
}

// signWith signs cl with the realm key under kid k1, extra merged into the payload (nonce, typ, azp …).
func (p *audIdP) signWith(t *testing.T, cl jwt.Claims, extra map[string]any) string {
	t.Helper()
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: p.priv},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "k1"))
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	s, err := jwt.Signed(sig).Claims(cl).Claims(extra).Serialize()
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	return s
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

	// A1: the id_token names the client, alone or beside other audiences — the exchange passes. Its azp is the client,
	// as on a Keycloak id_token; with several audiences OIDC Core §3.1.3.7 step 4 requires one.
	for _, aud := range [][]string{{audClientID}, {audOverride, audClientID}} {
		idt := p.signWith(t, p.claims(aud...), map[string]any{"nonce": "n", "azp": audClientID, "typ": "ID"})
		if err := p.exchange(c, idt, "n"); err != nil {
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
		return p.signID(t, p.priv, jose.RS256, "k1", cl, "n")
	}

	// iss: exact match.
	err := p.exchange(c, withClaims(func(cl *jwt.Claims) { cl.Issuer = "https://evil.example/realms/test" }), "n")
	requireIDTokenRefused(t, err, "claims: ", "foreign iss")
	if !errors.Is(err, jwt.ErrInvalidIssuer) {
		t.Fatalf("foreign iss: want the issuer check, got %v", err)
	}

	// Algorithm pin: RS512 by the realm's own key is a valid signature, but not a pinned algorithm.
	requireIDTokenRefused(t, p.exchange(c, p.signID(t, p.priv, jose.RS512, "k1", p.claims(audClientID), "n"), "n"),
		"parse: ", "RS512 id_token")

	// Signature: a key outside the JWKS under the realm's kid.
	requireIDTokenRefused(t, p.exchange(c, p.signID(t, p.other, jose.RS256, "k1", p.claims(audClientID), "n"), "n"),
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
		"absent nonce":     p.signID(t, p.priv, jose.RS256, "k1", p.claims(audClientID), ""),
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

// TestExchangeCodeRefusesOverCapIDTokenBeforeAnyWork pins the inbound length cap (jwtMaxBytes) on the id_token the
// exchange validates: it is refused by the cap before anything decodes it — the garbage would otherwise fail as
// malformed — and, on a client built by New that has not loaded its key set yet, without a JWKS request.
func TestExchangeCodeRefusesOverCapIDTokenBeforeAnyWork(t *testing.T) {
	p := newAudIdP(t)
	c := p.client(t)
	err := p.exchange(c, strings.Repeat("a", jwtMaxBytes-1)+"..", "n")
	requireIDTokenRefused(t, err, "token exceeds 256000 bytes", "over-cap id_token")
	if n := p.certs.Load(); n != 0 {
		t.Fatalf("an id_token refused by the cap must not reach the IdP: /certs=%d, want 0", n)
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
		opts.audience, opts.kind = audClientID, kindIDToken
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
		idt := p.signID(t, p.priv, jose.RS256, "rotated-too", p.claims(audClientID), "n")
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

	// The public id_token check is the exchange's, so it shares the same store: no second cold load and no window of
	// its own. ControlASecondStoreIsCounted above is what proves the count sees a second store.
	t.Run("ValidateIDTokenSharesTheColdLoad", func(t *testing.T) {
		p := newAudIdP(t)
		c := p.client(t)
		if _, err := c.Auth.ValidateIDToken(ctx, p.idToken(t, audClientID)); err != nil {
			t.Fatalf("ValidateIDToken: %v", err)
		}
		if _, err := c.Auth.Validate(ctx, access(p, "k1")); err != nil {
			t.Fatalf("validate: %v", err)
		}
		if n := p.certs.Load(); n != 1 {
			t.Fatalf("ValidateIDToken followed by Validate must cost one JWKS fetch, got /certs=%d", n)
		}
	})

	t.Run("ValidateIDTokenSharesTheForcedRefetchWindow", func(t *testing.T) {
		p := newAudIdP(t)
		c := p.client(t)
		if _, err := c.Auth.Validate(ctx, access(p, "k1")); err != nil { // cold load: 1
			t.Fatalf("validate: %v", err)
		}
		if _, err := c.Auth.Validate(ctx, access(p, "rotated")); err == nil { // forced refetch: 2
			t.Fatal("an unknown kid must not validate")
		}
		_, err := c.Auth.ValidateIDToken(ctx, p.signID(t, p.priv, jose.RS256, "rotated-too", p.claims(audClientID), "n"))
		var tve *TokenValidationError
		if !errors.As(err, &tve) || !strings.HasPrefix(tve.Msg, "key: ") || !strings.Contains(tve.Msg, "rate-limited") {
			t.Fatalf("ValidateIDToken's unknown kid must hit Validate's window, got %v", err)
		}
		if n := p.certs.Load(); n != 2 {
			t.Fatalf("ValidateIDToken must share Validate's forced-refetch window, got /certs=%d", n)
		}
	})
}

// ── typ and azp: the two checks that differ between the paths (facade wiring) ──
//
// (A) Validate refuses a Keycloak token that is not an access token (typ ID, Refresh, Offline, Logout, Serialized-ID).
// (B) The id_token of ValidateIDToken — and so of a nonce-checked ExchangeCode — meets OIDC Core §3.1.3.7 steps 4–5:
// with several audiences azp must be present, and a present azp is the client id. Neither check applies on the other
// path; the id_token path has its own typ rule instead (exactly "ID" — the ValidateIDToken tests below). The validator
// cells (all five types, edge values) are in jwt_test.go. The client is built by New with ExpectedAudience overridden,
// so a check against the client id and one against the override are told apart.

// TestAuthValidateJudgesTypNotAzp pins (A) on the facade: an id_token, a back-channel logout token and a refresh
// token are refused by Validate even with the access-token audience — and (B) stays off Validate.
func TestAuthValidateJudgesTypNotAzp(t *testing.T) {
	ctx := context.Background()
	p := newAudIdP(t)
	c := p.client(t)
	for _, typ := range []string{"ID", "Logout", "Refresh"} {
		_, err := c.Auth.Validate(ctx, p.signWith(t, p.claims(audOverride), map[string]any{"typ": typ}))
		var tve *TokenValidationError
		if !errors.As(err, &tve) || tve.Msg != "claims: not an access token (typ "+typ+")" {
			t.Fatalf("typ %q: want the not-an-access-token refusal, got %v", typ, err)
		}
	}
	// Control: an access token's typ passes — Bearer or DPoP, in Keycloak's case or lower-cased.
	for _, typ := range []string{"Bearer", "bearer", "DPoP", "dpop"} {
		if _, err := c.Auth.Validate(ctx, p.signWith(t, p.claims(audOverride), map[string]any{"typ": typ})); err != nil {
			t.Fatalf("typ %q: an access token must pass Validate: %v", typ, err)
		}
	}
	// (B) is not Validate's: several audiences without azp, or with another client's, pass (access tokens: typ Bearer).
	for _, extra := range []map[string]any{{"typ": "Bearer"}, {"typ": "Bearer", "azp": "frontend"}} {
		if _, err := c.Auth.Validate(ctx, p.signWith(t, p.claims(audOverride, "other"), extra)); err != nil {
			t.Fatalf("azp %v: an access token's azp is not judged: %v", extra["azp"], err)
		}
	}
}

// TestAuthValidateAcceptsOnlyBearerOrDPoP pins the access path's allow-list on the facade: Validate takes a token only
// when its payload typ is Bearer or DPoP ignoring ASCII case (Keycloak's own TokenVerifier.TokenTypeCheck). The first
// refusal is the hole the rule closes — Keycloak's JARM authorization response JWT (response_mode=query.jwt): signed by
// the realm, iss the realm, aud the client id (ExpectedAudience's default), exp present, and no typ. The constant
// message never quotes the token's typ.
func TestAuthValidateAcceptsOnlyBearerOrDPoP(t *testing.T) {
	ctx := context.Background()
	p := newAudIdP(t)
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "test", ClientID: audClientID, ClientSecret: "s"}) // default aud
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	const canary = "x-canary-typ-8R4T"
	for name, extra := range map[string]map[string]any{
		"JARM response (no typ)": {"code": "c0de", "state": "st4te"},
		"no typ":                 {},
		"typ a number":           {"typ": 1},
		"typ null":               {"typ": nil},
		"typ an array":           {"typ": []string{"Bearer"}},
		"typ at+jwt":             {"typ": "at+jwt"},
		"typ an arbitrary value": {"typ": canary},
	} {
		_, err := c.Auth.Validate(ctx, p.signWith(t, p.claims(audClientID), extra))
		var tve *TokenValidationError
		if !errors.As(err, &tve) || tve.Msg != msgNotBearerOrDPoP || tve.Cause != nil {
			t.Errorf("%s: want Msg=%q and no cause, got %v", name, msgNotBearerOrDPoP, err)
			continue
		}
		if strings.Contains(fmt.Sprintf("%v %+v %#v", err, err, err), canary) {
			t.Errorf("%s: the refusal quotes the token's typ", name)
		}
	}
	for _, typ := range []string{"Bearer", "bearer", "DPoP", "dpop"} {
		if _, err := c.Auth.Validate(ctx, p.signWith(t, p.claims(audClientID), map[string]any{"typ": typ})); err != nil {
			t.Errorf("typ %q: an access token must pass Validate: %v", typ, err)
		}
	}
	if n := p.certs.Load(); n != 1 {
		t.Fatalf("a claims refusal must not refetch the JWKS: /certs=%d, want 1", n)
	}
}

// TestExchangeCodeAcceptsAnIDTokenTypedID: (A) never applies to the exchange's id_token — Keycloak types it "ID", which
// is exactly what the id_token path requires.
func TestExchangeCodeAcceptsAnIDTokenTypedID(t *testing.T) {
	p := newAudIdP(t)
	c := p.client(t)
	idt := p.signWith(t, p.claims(audClientID), map[string]any{"nonce": "n", "typ": "ID", "azp": audClientID})
	if err := p.exchange(c, idt, "n"); err != nil {
		t.Fatalf("an id_token typed ID must pass the exchange: %v", err)
	}
}

// TestExchangeCodeAppliesOIDCAzpRulesToTheIDToken pins (B) on the facade, through both entry points: the exchange and
// ValidateIDToken run the one check. An exchange refusal has the shape of every other id_token refusal: the
// invalid-id_token AuthError, caused by a TokenValidationError from the claims stage — ValidateIDToken returns that
// TokenValidationError itself.
func TestExchangeCodeAppliesOIDCAzpRulesToTheIDToken(t *testing.T) {
	p := newAudIdP(t)
	c := p.client(t)
	const mismatch, missing = "claims: authorized party (azp) mismatch", "claims: missing azp claim for multiple audiences"
	for _, tc := range []struct {
		name  string
		aud   []string
		extra map[string]any
		want  string // "" = accepted
	}{
		{"single aud, no azp", []string{audClientID}, map[string]any{}, ""},
		{"several auds, azp is the client", []string{audClientID, "other"}, map[string]any{"azp": audClientID}, ""},
		{"single aud, foreign azp", []string{audClientID}, map[string]any{"azp": "evil"}, mismatch},
		{"several auds, no azp", []string{audClientID, "evil"}, map[string]any{}, missing},
		{"several auds, foreign azp", []string{audClientID, "evil"}, map[string]any{"azp": "evil"}, mismatch},
		// The client id, not ExpectedAudience: azp naming the override is another client.
		{"azp is the override", []string{audClientID, audOverride}, map[string]any{"azp": audOverride}, mismatch},
	} {
		tc.extra["nonce"], tc.extra["typ"] = "n", "ID" // a Keycloak id_token — the typ rule has its own tests below
		idt := p.signWith(t, p.claims(tc.aud...), tc.extra)
		err := p.exchange(c, idt, "n")
		_, direct := c.Auth.ValidateIDToken(context.Background(), idt)
		if tc.want == "" {
			if err != nil || direct != nil {
				t.Fatalf("%s: the exchange and ValidateIDToken must pass, got %v / %v", tc.name, err, direct)
			}
			continue
		}
		if tve := requireIDTokenRefused(t, err, "claims: ", tc.name); tve.Msg != tc.want {
			t.Fatalf("%s: got Msg=%q, want %q", tc.name, tve.Msg, tc.want)
		}
		var tve *TokenValidationError
		if !errors.As(direct, &tve) || tve.Msg != tc.want || tve.Cause != nil {
			t.Fatalf("%s: ValidateIDToken: want Msg=%q and no cause, got %v", tc.name, tc.want, direct)
		}
	}
}

// ── ValidateIDToken: the id_token check, public (registry id-token-validator-not-public) ──
//
// The exchange's id_token check used to be reachable only through a nonce-checked ExchangeCode (forIDToken is
// unexported), and Validate refuses typ "ID" — so a consumer holding an id_token had no way to verify it with this
// SDK. ValidateIDToken is that check: the exchange calls it before it compares the nonce. It takes no nonce, and it
// accepts only typ "ID" (the validator cells are TestIDTokenValidatorAcceptsOnlyTypID in jwt_test.go).

// TestValidateIDTokenAcceptsAKeycloakIDToken: an id_token as Keycloak issues it — typ "ID", aud and azp the client id —
// passes under an ExpectedAudience override it does not carry, and comes back with its claims.
func TestValidateIDTokenAcceptsAKeycloakIDToken(t *testing.T) {
	p := newAudIdP(t)
	c := p.client(t)
	extra := map[string]any{"typ": "ID", "azp": audClientID, "nonce": "n", "sid": "s1"}
	vt, err := c.Auth.ValidateIDToken(context.Background(), p.signWith(t, p.claims(audClientID), extra))
	if err != nil {
		t.Fatalf("a Keycloak id_token must pass ValidateIDToken: %v", err)
	}
	if vt.Subject != "user1" || vt.Issuer != p.srv.URL+"/realms/test" || !slices.Equal(vt.Audience, []string{audClientID}) ||
		vt.ExpiresAt == 0 || vt.IssuedAt == 0 {
		t.Fatalf("validated id_token: %+v", vt)
	}
	for k, want := range extra {
		if vt.Claims[k] != want {
			t.Errorf("claim %s = %v, want %v", k, vt.Claims[k], want)
		}
	}
}

// TestValidateIDTokenRefusesATokenNotTypedID: a token whose payload typ is not exactly "ID" is refused with the constant
// message however right the rest of it is. The first row is the hole the rule closes — an access token Keycloak issued
// to this very client (an audience mapper puts the client id in aud, azp is the client) passes every other id_token
// check. The last is a back-channel logout token: aud the client id, no azp, exp present.
func TestValidateIDTokenRefusesATokenNotTypedID(t *testing.T) {
	ctx := context.Background()
	p := newAudIdP(t)
	c := p.client(t)
	logout := map[string]any{"http://schemas.openid.net/event/backchannel-logout": map[string]any{}}
	for name, extra := range map[string]map[string]any{
		"access token, typ Bearer": {"typ": "Bearer", "azp": audClientID, "scope": "openid"},
		"no typ":                   {"azp": audClientID, "nonce": "n"},
		"typ bearer (lowercase)":   {"typ": "bearer", "azp": audClientID},
		"typ a number":             {"typ": 1, "azp": audClientID},
		"typ null":                 {"typ": nil, "azp": audClientID},
		"typ an array":             {"typ": []string{"ID"}, "azp": audClientID},
		"logout token":             {"typ": "Logout", "sid": "s1", "events": logout},
	} {
		_, err := c.Auth.ValidateIDToken(ctx, p.signWith(t, p.claims(audClientID), extra))
		var tve *TokenValidationError
		if !errors.As(err, &tve) || tve.Msg != msgNotAnIDToken || tve.Cause != nil {
			t.Errorf("%s: want Msg=%q and no cause, got %v", name, msgNotAnIDToken, err)
		}
	}
	if n := p.certs.Load(); n != 1 {
		t.Fatalf("a claims refusal must not refetch the JWKS: /certs=%d, want 1", n)
	}
}

// TestValidateIDTokenAudienceIsTheClientIDUnderAnOverride: aud must name the client id. An id_token whose aud holds only
// Config.ExpectedAudience — the audience Validate looks for — is refused by the audience check.
func TestValidateIDTokenAudienceIsTheClientIDUnderAnOverride(t *testing.T) {
	p := newAudIdP(t)
	c := p.client(t)
	_, err := c.Auth.ValidateIDToken(context.Background(),
		p.signWith(t, p.claims(audOverride), map[string]any{"typ": "ID", "azp": audClientID}))
	var tve *TokenValidationError
	if !errors.As(err, &tve) || !strings.HasPrefix(tve.Msg, "claims: ") || !errors.Is(err, jwt.ErrInvalidAudience) {
		t.Fatalf("aud = the ExpectedAudience override only: want the audience refusal, got %v", err)
	}
}

// TestExchangeCodeRefusesAnIDTokenNotTypedID: the exchange checks its id_token with ValidateIDToken, so the typ rule holds
// there too — refused before the nonce is compared, with the exchange's own invalid-id_token refusal.
func TestExchangeCodeRefusesAnIDTokenNotTypedID(t *testing.T) {
	p := newAudIdP(t)
	c := p.client(t)
	for name, extra := range map[string]map[string]any{
		"no typ":     {"nonce": "n", "azp": audClientID},
		"typ Bearer": {"nonce": "n", "azp": audClientID, "typ": "Bearer"},
	} {
		tve := requireIDTokenRefused(t, p.exchange(c, p.signWith(t, p.claims(audClientID), extra), "n"), "claims: ", name)
		if tve.Msg != msgNotAnIDToken || tve.Cause != nil {
			t.Fatalf("%s: want Msg=%q and no cause, got Msg=%q Cause=%v", name, msgNotAnIDToken, tve.Msg, tve.Cause)
		}
	}
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

// TestLogoutSucceedsOn204Only — Keycloak 은 백채널 logout 의 성공을 204 로만 답한다. 2xx 를 모두 성공으로 보면
// 가로챈 200 페이지(프록시의 로그인 폼)도 성공이라 세션이 살아 있는데 nil 이었다(등록부 logout-2xx-html-false-success ·
// 판정 2026-11-12: 204 밖은 전부 *AuthError, 상태를 메시지에). 본문은 판정에 쓰지 않는다.
func TestLogoutSucceedsOn204Only(t *testing.T) {
	cells := []struct {
		name   string
		status int
		ctype  string
		body   string
	}{
		{"204", http.StatusNoContent, "", ""},
		{"200 empty", http.StatusOK, "", ""},
		{"200 {}", http.StatusOK, "application/json", "{}"},
		{"200 html login page", http.StatusOK, "text/html", `<html><body><form action="/login"></form></body></html>`},
		{"200 error json", http.StatusOK, "application/json", `{"error":"invalid_grant"}`},
		{"201", http.StatusCreated, "", ""},
		{"202", http.StatusAccepted, "", ""},
		// 205 · 206 · 4xx · 5xx — 실행 레그가 살린 편집(205 수용 · 504 를 *TransportError 로)을 잡는다. 3xx 는
		// TestPostFormRejectsNon2xx.
		{"205", http.StatusResetContent, "", ""},
		{"206", http.StatusPartialContent, "", ""},
		{"400", http.StatusBadRequest, "application/json", `{"error":"invalid_grant"}`},
		{"401", http.StatusUnauthorized, "application/json", `{"error":"invalid_client"}`},
		{"404", http.StatusNotFound, "text/html", "<html>Not Found</html>"},
		{"500", http.StatusInternalServerError, "", ""},
		{"502", http.StatusBadGateway, "text/html", "<html>Bad Gateway</html>"},
		{"503", http.StatusServiceUnavailable, "", ""},
		{"504", http.StatusGatewayTimeout, "text/html", "<html>Gateway Timeout</html>"},
	}
	for _, c := range cells {
		t.Run(c.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if c.ctype != "" {
					w.Header().Set("Content-Type", c.ctype)
				}
				w.WriteHeader(c.status)
				_, _ = w.Write([]byte(c.body))
			}))
			t.Cleanup(srv.Close)
			cfg := Config{ServerURL: srv.URL, Realm: "test", ClientID: "app", ClientSecret: "sekret-canary"}.withDefaults()
			err := newAuthClient(cfg, nil).Logout(context.Background(), "RT-canary")
			if c.status == http.StatusNoContent {
				if err != nil {
					t.Fatalf("204 is Keycloak's success: %v", err)
				}
				return
			}
			var ae *AuthError
			if !errors.As(err, &ae) || !strings.Contains(err.Error(), "failed (HTTP "+strconv.Itoa(c.status)+")") {
				t.Fatalf("HTTP %d must be *AuthError naming the status, got %T %v", c.status, err, err)
			}
			if s := fmt.Sprintf("%+v %#v", err, err); strings.Contains(s, "canary") {
				t.Fatalf("the error quotes a sent secret: %s", s)
			}
		})
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
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(code)
				// 리다이렉트가 활성 토큰처럼 읽히는 본문을 실었다 — introspect 가 3xx 를 성공으로 읽으면 이것이 판정이 된다.
				_, _ = w.Write([]byte(`{"active":true,"username":"u","client_id":"app"}`))
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
			// introspect 도 같다 — 실행 레그가 살린 편집 「statusIs2xx 를 400 미만으로」는 이 본문을 활성 토큰으로 받았다.
			r, err := a.Introspect(context.Background(), "tok")
			var ae *AuthError
			if !errors.As(err, &ae) || !strings.Contains(err.Error(), "HTTP "+strconv.Itoa(code)) {
				t.Fatalf("Introspect 가 HTTP %d 를 상태를 실은 *AuthError 로 거부해야 한다: %+v %T %v", code, r, err, err)
			}
		})
	}
}

// TestIntrospectAcceptsAny2xx — introspection 의 성공은 그대로 2xx 다(statusIs2xx — RFC 7662 §2.2 는 200 으로 답한다).
// logout 이 성공 술어를 받게 되면서 introspect 의 술어가 따로 섰다 — 실행 레그가 살린 편집 「200 만」을 201 칸이 잡는다.
func TestIntrospectAcceptsAny2xx(t *testing.T) {
	for _, code := range []int{http.StatusOK, http.StatusCreated} {
		t.Run(http.StatusText(code), func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(code)
				_, _ = w.Write([]byte(`{"active":true,"username":"u","client_id":"app"}`))
			}))
			t.Cleanup(srv.Close)
			cfg := Config{ServerURL: srv.URL, Realm: "test", ClientID: "app", ClientSecret: "x"}.withDefaults()
			r, err := newAuthClient(cfg, nil).Introspect(context.Background(), "tok")
			if err != nil || !r.Active || r.Username != "u" {
				t.Fatalf("HTTP %d introspection must be read: %+v %v", code, r, err)
			}
		})
	}
}

// The success-status OAuth error (registry auth-2xx-error-code-divergent). A token or introspection response whose status
// the lane takes as success, and whose body is a JSON object carrying a non-empty string `error`, fails as that lane's
// OAuth error — the code through oauthErrorCode — and nothing else in the body is used: no token is returned or cached, no
// admin request goes out with it, and introspection does not report active. Measured on main 350836b9: the three grants
// and a provider over them already failed with the code (x/oauth2 refuses a 2xx that carries `error`); Introspect said "no
// boolean active" without a code for B1 and read B2 as active, and the admin login said "returned no access token"
// without a code for B1 and sent its admin request with B2's token.
const (
	successStatusToken  = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl" // B2's access token
	successStatusFresh  = "fresh-token-value"                                         // the usable answer's
	successStatusUsable = `{"access_token":"` + successStatusFresh + `","token_type":"Bearer","expires_in":300}`
)

// successStatusBodies are the bodies at status 200: B1 carries only the error, B2 the error and a token (introspection:
// active true).
var successStatusBodies = []struct{ name, token, introspect string }{
	{"B1", `{"error":"invalid_grant","error_description":"d"}`, `{"error":"invalid_token"}`},
	{"B2", `{"error":"invalid_grant","access_token":"` + successStatusToken + `","token_type":"Bearer","expires_in":300}`,
		`{"error":"invalid_token","active":true}`},
}

// successStatusIdP answers the token and introspection endpoints with 200 and the body last set for each, serves
// /admin/realms/r/users/{id}, and counts token and admin requests (keeping the last admin request's Authorization).
type successStatusIdP struct {
	srv                  *httptest.Server
	token, introspect    atomic.Value
	bearer               atomic.Value
	tokenHits, adminHits atomic.Int32
}

func newSuccessStatusIdP(t *testing.T) *successStatusIdP {
	t.Helper()
	p := &successStatusIdP{}
	p.token.Store(successStatusUsable)
	p.introspect.Store(`{"active":true}`)
	p.bearer.Store("")
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token/introspect"):
			_, _ = w.Write([]byte(p.introspect.Load().(string)))
		case strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token"):
			p.tokenHits.Add(1)
			_, _ = w.Write([]byte(p.token.Load().(string)))
		case strings.HasPrefix(r.URL.Path, "/admin/realms/r/users/"):
			p.adminHits.Add(1)
			p.bearer.Store(r.Header.Get("Authorization"))
			_, _ = w.Write([]byte(`{"id":"u1","username":"alice"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(p.srv.Close)
	return p
}

func (p *successStatusIdP) client(t *testing.T, secret string) *Client {
	t.Helper()
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: secret})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// successStatusRefused asserts that err is *AuthError carrying code.
func successStatusRefused(t *testing.T, label string, err error, code string) {
	t.Helper()
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Fatalf("%s: want *AuthError, got %T: %v", label, err, err)
	}
	if ae.OAuthError != code {
		t.Errorf("%s: OAuthError = %q, want %q — %v", label, ae.OAuthError, code, err)
	}
}

// handedOut is what a grant handed out: "" when it returned no TokenSet.
func handedOut(ts *TokenSet, err error) (string, error) {
	if ts != nil {
		return "a TokenSet with access token " + ts.AccessToken, err
	}
	return "", err
}

// TestSuccessStatusOAuthErrorFailsTheAuthLanes — the three grants and Introspect: B1 and B2 at 200 fail with *AuthError
// carrying the code and hand out nothing (B2's token is not returned, B2's active true is not reported).
func TestSuccessStatusOAuthErrorFailsTheAuthLanes(t *testing.T) {
	p := newSuccessStatusIdP(t)
	c := p.client(t, "sekret")
	lanes := []struct {
		name, code string
		run        func(context.Context, *AuthClient) (string, error)
	}{
		{"ClientCredentialsToken", "invalid_grant", func(ctx context.Context, a *AuthClient) (string, error) {
			return handedOut(a.ClientCredentialsToken(ctx))
		}},
		{"Refresh", "invalid_grant", func(ctx context.Context, a *AuthClient) (string, error) {
			return handedOut(a.Refresh(ctx, "rt-in"))
		}},
		{"ExchangeCode", "invalid_grant", func(ctx context.Context, a *AuthClient) (string, error) {
			return handedOut(a.ExchangeCode(ctx, "code-in", "https://app/cb", "verifier-in", ""))
		}},
		{"Introspect", "invalid_token", func(ctx context.Context, a *AuthClient) (string, error) {
			r, err := a.Introspect(ctx, "tok-in")
			if r != nil {
				return fmt.Sprintf("an introspection result with active=%v", r.Active), err
			}
			return "", err
		}},
	}
	for _, b := range successStatusBodies {
		for _, l := range lanes {
			t.Run(b.name+"/"+l.name, func(t *testing.T) {
				p.token.Store(b.token)
				p.introspect.Store(b.introspect)
				got, err := l.run(context.Background(), c.Auth)
				if got != "" {
					t.Errorf("handed out %s", got)
				}
				successStatusRefused(t, b.name+" "+l.name, err, l.code)
			})
		}
	}
}

// TestSuccessStatusOAuthErrorIgnoresAnErrorThatIsNotANonEmptyString — an `error` member that is not a JSON string of at
// least one character is ignored, as it was: Introspect still reads active, and the admin login still uses the token. (The
// three grants' handling of such a member is x/oauth2's and unchanged — a number or an object fails its decode.)
func TestSuccessStatusOAuthErrorIgnoresAnErrorThatIsNotANonEmptyString(t *testing.T) {
	for _, v := range []string{`5`, `{}`, `[]`, `true`, `null`, `""`} {
		t.Run(v, func(t *testing.T) {
			ctx := context.Background()
			p := newSuccessStatusIdP(t)
			c := p.client(t, "sekret")
			p.token.Store(`{"error":` + v + `,"access_token":"` + successStatusFresh + `","token_type":"Bearer","expires_in":300}`)
			p.introspect.Store(`{"error":` + v + `,"active":true}`)
			if r, err := c.Auth.Introspect(ctx, "tok-in"); err != nil || !r.Active {
				t.Errorf("Introspect: %+v, %v — want active as before", r, err)
			}
			a, err := c.Admin(ctx)
			if err != nil {
				t.Fatalf("admin: %v — want the token used as before", err)
			}
			if _, err := a.Users.Get(ctx, "u1"); err != nil || p.bearer.Load() != "Bearer "+successStatusFresh {
				t.Errorf("admin call: %v, bearer %q — want the token used as before", err, p.bearer.Load())
			}
		})
	}
}

// TestSuccessStatusOAuthErrorWithholdsALowercasedSecretEcho — at 200 too, an `error` that is the client secret lowercased
// is no code: the lane fails as it does for B1, without a code, and no rendering shows the echo. ClientCredentialsToken is
// the nine languages' vector; Introspect, the provider and the admin login read their code through this fix's paths.
func TestSuccessStatusOAuthErrorWithholdsALowercasedSecretEcho(t *testing.T) {
	const secret = "EchoedSecret" // letters only: lowercased, it has the code shape
	p := newSuccessStatusIdP(t)
	p.token.Store(`{"error":"echoedsecret","error_description":"d"}`)
	p.introspect.Store(`{"error":"echoedsecret"}`)
	for _, l := range []struct {
		name string
		run  func(context.Context, *Client) error
	}{
		{"ClientCredentialsToken", func(ctx context.Context, c *Client) error {
			_, err := c.Auth.ClientCredentialsToken(ctx)
			return err
		}},
		{"Introspect", func(ctx context.Context, c *Client) error {
			_, err := c.Auth.Introspect(ctx, "tok-in")
			return err
		}},
		{"provider", func(ctx context.Context, c *Client) error {
			_, err := NewClientCredentialsTokenProvider(c.Auth.ClientCredentialsToken, 30).Token(ctx)
			return err
		}},
		{"admin", func(ctx context.Context, c *Client) error {
			_, err := c.Admin(ctx)
			return err
		}},
	} {
		t.Run(l.name, func(t *testing.T) {
			err := l.run(context.Background(), p.client(t, secret))
			successStatusRefused(t, l.name, err, "")
			for i, text := range renderings(err) {
				if strings.Contains(strings.ToLower(text), "echoedsecret") {
					t.Errorf("%s: rendering #%d shows the echoed secret: %s", l.name, i, text)
				}
			}
		})
	}
}
