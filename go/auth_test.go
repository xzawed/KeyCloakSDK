package keycloak

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
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

func TestExchangeCodeAndRefresh(t *testing.T) {
	f := newAuthFixture(t, "sekret")
	var form url.Values
	f.lastFn = func(path string, fm url.Values) {
		if path == "token" {
			form = fm
		}
	}

	ts, err := f.auth.ExchangeCode(context.Background(), "the-code", "https://app/cb", "verifier")
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
