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
	s, err := jwt.Signed(sig).Claims(std).Claims(map[string]any{"nonce": nonce}).Serialize()
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
	mux := http.NewServeMux()
	mux.HandleFunc(base+"/token", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if includeIDToken {
			idt := signIDToken(t, priv, "k1", issuer, "app", "server-nonce")
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
