//go:build integration

package keycloak

// Authorization-code exchange E2E — codes and id_tokens a real Keycloak issued and signed.
//
// ExchangeCode's nonce check and id_token signature verification had only ever run against tokens a
// test minted (auth_test.go). Here browserLogin performs a real login, the code is exchanged, and the
// rejection paths run against tokens the SERVER signed. A forged RS256 id_token (a key outside the JWKS,
// matching nonce) is the one case a real server cannot mint — the unit suite pins it
// (hostile_path_matrix_test.go, W3b rows "key≠·kid=k1" and "key≠·kid=k2").

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/url"
	"os"
	"strings"
	"testing"
)

const (
	itRedirectURI   = "http://localhost/it-callback"
	itAlice         = "alice"
	itAlicePassword = "alice-password"
	msgBadNonce     = "authorization code exchange failed: unexpected nonce"
	msgBadIDToken   = "authorization code exchange failed: invalid id_token"
	msgNoIDToken    = "authorization code exchange failed: missing id_token for nonce validation"
)

// itWebSecrets pairs with testdata/it-realm-realm.json: it-web (standard flow · PKCE S256 enforced ·
// audience mapper) and it-web-hs256 (its id_token is HS256-signed with the realm's HMAC key, which no
// JWKS publishes). ⚠️ it-web's audience mapper is for introspection — Keycloak 26.6 answers
// {"active": false} for an access token without aud even to the client that obtained it (python pilot).
var itWebSecrets = map[string]string{"it-web": "it-web-secret", "it-web-hs256": "it-web-hs256-secret"}

// webClient builds a client for clientID; tune (optional) adjusts the config before New.
func webClient(t *testing.T, serverURL, clientID string, tune func(*Config)) *Client {
	t.Helper()
	cfg := Config{ServerURL: serverURL, Realm: "it-realm", ClientID: clientID, ClientSecret: itWebSecrets[clientID]}
	if tune != nil {
		tune(&cfg)
	}
	kc, err := New(cfg)
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	t.Cleanup(func() { _ = kc.Close() })
	return kc
}

func aliceLogin(t *testing.T, kc *Client) (AuthorizationRequest, string) {
	t.Helper()
	req := kc.Auth.CreateAuthorizationRequest(itRedirectURI)
	return req, browserLogin(t, req, itRedirectURI, itAlice, itAlicePassword)
}

// stripNonce drops only the nonce parameter from the authorization URL, so the server signs an id_token
// that carries NO nonce claim.
func stripNonce(t *testing.T, req AuthorizationRequest) AuthorizationRequest {
	t.Helper()
	u, err := url.Parse(req.URL)
	if err != nil {
		t.Fatalf("authorization URL: %v", err)
	}
	q := u.Query()
	if !q.Has("nonce") {
		t.Fatalf("the SDK's authorization URL carries no nonce to strip: %s", req.URL)
	}
	q.Del("nonce")
	u.RawQuery = q.Encode()
	req.URL = u.String()
	return req
}

// aliceID reads alice's user id from a source independent of the token (the admin API, as it-client),
// to compare with the id_token's sub.
func aliceID(ctx context.Context, t *testing.T, serverURL string) string {
	t.Helper()
	kc, err := New(Config{ServerURL: serverURL, Realm: "it-realm", ClientID: "it-client", ClientSecret: "it-secret"})
	if err != nil {
		t.Fatalf("new admin client: %v", err)
	}
	defer func() { _ = kc.Close() }()
	admin, err := kc.Admin(ctx)
	if err != nil {
		t.Fatalf("admin: %v", err)
	}
	users, err := admin.Users.Search(ctx, itAlice, 0, 10)
	if err != nil {
		t.Fatalf("search alice: %v", err)
	}
	var ids []string
	for _, u := range users {
		if u != nil && u.Username != nil && *u.Username == itAlice && u.ID != nil {
			ids = append(ids, *u.ID)
		}
	}
	if len(ids) != 1 || ids[0] == "" {
		t.Fatalf("want exactly one user %q, got ids %v", itAlice, ids)
	}
	return ids[0]
}

func requireAuthError(t *testing.T, err error, what string) *AuthError {
	t.Helper()
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Fatalf("%s: want *AuthError, got %T: %v", what, err, err)
	}
	return ae
}

// unverifiedPayload reads a JWT's claims WITHOUT verifying anything — only for test preconditions about
// what the server put in a token the SDK is about to refuse.
func unverifiedPayload(t *testing.T, token string) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("not a JWS: %d parts", len(parts))
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatalf("JWS payload: %v", err)
	}
	claims := map[string]any{}
	if err := json.Unmarshal(raw, &claims); err != nil {
		t.Fatalf("JWS payload: %v", err)
	}
	return claims
}

type secret struct{ name, value string }

// requireHidden fails when any secret appears in rendered. An empty secret fails too — the check would
// be vacuous.
func requireHidden(t *testing.T, rendered, where string, secrets ...secret) {
	t.Helper()
	for _, s := range secrets {
		if s.value == "" {
			t.Fatalf("%s is empty — the leak check would be vacuous", s.name)
		}
		if strings.Contains(rendered, s.value) {
			t.Errorf("the %s leaks through %s", s.name, where)
		}
	}
}

// renderedError is every way a caller can print err: each link of the cause chain (Unwrap, including
// the multi-error form) under %v · %+v · %s · %q · %#v, plus a structured slog record of the top error.
func renderedError(err error) string {
	var b strings.Builder
	chain := []error{err}
	for len(chain) > 0 {
		e := chain[0]
		chain = chain[1:]
		if e == nil {
			continue
		}
		fmt.Fprintf(&b, "%v\n%+v\n%s\n%q\n%#v\n", e, e, e, e, e)
		switch u := e.(type) {
		case interface{ Unwrap() error }:
			chain = append(chain, u.Unwrap())
		case interface{ Unwrap() []error }:
			chain = append(chain, u.Unwrap()...)
		}
	}
	slog.New(slog.NewJSONHandler(&b, nil)).Error("code exchange failed", "err", err)
	return b.String()
}

// captureProcessOutput runs fn with the process-wide log sinks and stdout/stderr redirected, and returns
// what reached them — the SDK must not print or log what it exchanged, at any level.
func captureProcessOutput(t *testing.T, fn func()) string {
	t.Helper()
	var logs bytes.Buffer
	savedSlog, savedLogOut, savedLogFlags := slog.Default(), log.Writer(), log.Flags()
	// A non-default slog handler also takes over the log package's default logger.
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	savedOut, savedErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = w, w
	printed := make(chan string)
	go func() {
		all, _ := io.ReadAll(r)
		printed <- string(all)
	}()
	restore := func() {
		os.Stdout, os.Stderr = savedOut, savedErr
		slog.SetDefault(savedSlog)
		log.SetOutput(savedLogOut)
		log.SetFlags(savedLogFlags)
		_ = w.Close() // ends the reader; a second call (the deferred one) is a no-op error
	}
	defer restore() // fn may t.Fatal — the sinks must come back either way
	fn()
	restore()
	out := <-printed
	_ = r.Close()
	return logs.String() + out
}

func TestE2ECodeExchange(t *testing.T) {
	ctx := context.Background()
	serverURL := keycloakURL(t)
	kc := webClient(t, serverURL, "it-web", nil)

	t.Run("BindsTokensToTheNonceAndUser", func(t *testing.T) {
		req, code := aliceLogin(t, kc)
		alice := aliceID(ctx, t, serverURL)
		var tokens, refreshed *TokenSet
		var afterLogout error
		// Every SDK call of the flow runs with the process output captured — none may print or log a secret.
		printed := captureProcessOutput(t, func() {
			var err error
			tokens, err = kc.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, req.Nonce)
			if err != nil {
				t.Fatalf("exchange: %v", err)
			}
			if tokens.AccessToken == "" || tokens.RefreshToken == "" || tokens.IDToken == "" {
				t.Fatalf("exchange must return access, refresh and id tokens: %v", tokens)
			}
			idToken, err := kc.Auth.Validate(ctx, tokens.IDToken)
			if err != nil {
				t.Fatalf("validate the id_token: %v", err)
			}
			if got := idToken.Claims["nonce"]; got != req.Nonce {
				t.Fatalf("id_token nonce: got %v, want the one the SDK issued", got)
			}
			if idToken.Subject != alice {
				t.Fatalf("id_token sub: got %q, want alice %q", idToken.Subject, alice)
			}

			// refresh: a new access token, active for the same user.
			refreshed, err = kc.Auth.Refresh(ctx, tokens.RefreshToken)
			if err != nil {
				t.Fatalf("refresh: %v", err)
			}
			if refreshed.AccessToken == "" || refreshed.AccessToken == tokens.AccessToken || refreshed.RefreshToken == "" {
				t.Fatalf("refresh must return a new access token and a refresh token: %v", refreshed)
			}
			active, err := kc.Auth.Introspect(ctx, refreshed.AccessToken)
			if err != nil {
				t.Fatalf("introspect: %v", err)
			}
			if !active.Active || active.Username != itAlice {
				t.Fatalf("introspect after refresh: want active alice, got active=%v username=%q", active.Active, active.Username)
			}

			// logout ends the session: that refresh token no longer refreshes and the access token goes inactive.
			if err := kc.Auth.Logout(ctx, refreshed.RefreshToken); err != nil {
				t.Fatalf("logout: %v", err)
			}
			_, afterLogout = kc.Auth.Refresh(ctx, refreshed.RefreshToken)
			if ae := requireAuthError(t, afterLogout, "refresh after logout"); ae.OAuthError != "invalid_grant" {
				t.Fatalf("refresh after logout: want invalid_grant, got %q (%v)", ae.OAuthError, afterLogout)
			}
			ended, err := kc.Auth.Introspect(ctx, refreshed.AccessToken)
			if err != nil {
				t.Fatalf("introspect after logout: %v", err)
			}
			if ended.Active {
				t.Fatal("introspect after logout: the access token is still active")
			}
		})
		requireHidden(t, renderedError(afterLogout)+printed, "the refused refresh's error, its cause chain or process output",
			secret{"code", code}, secret{"code_verifier", req.CodeVerifier}, secret{"client secret", itWebSecrets["it-web"]},
			secret{"access token", tokens.AccessToken}, secret{"refresh token", tokens.RefreshToken},
			secret{"id_token", tokens.IDToken}, secret{"refreshed access token", refreshed.AccessToken},
			secret{"refreshed refresh token", refreshed.RefreshToken})
	})

	t.Run("RefusesANonceTheServerDidNotSign", func(t *testing.T) {
		req, code := aliceLogin(t, kc)
		tokens, err := kc.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, "x"+req.Nonce)
		ae := requireAuthError(t, err, "wrong nonce")
		if ae.Msg != msgBadNonce || ae.OAuthError != "" { // the SDK refused, not the server
			t.Fatalf("wrong nonce: got Msg=%q OAuthError=%q", ae.Msg, ae.OAuthError)
		}
		if tokens != nil {
			t.Fatalf("a refused exchange must not hand out tokens: %v", tokens)
		}
	})

	t.Run("RefusesAnIDTokenThatCarriesNoNonce", func(t *testing.T) {
		req := stripNonce(t, kc.Auth.CreateAuthorizationRequest(itRedirectURI))
		// Precondition: the server really signs without a nonce (else the refusal below measures a
		// mismatch, not an absence). An empty expectedNonce skips the id_token check by contract.
		code := browserLogin(t, req, itRedirectURI, itAlice, itAlicePassword)
		unchecked, err := kc.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, "")
		if err != nil || unchecked.IDToken == "" {
			t.Fatalf("precondition exchange: %v %v", unchecked, err)
		}
		claims, err := kc.Auth.Validate(ctx, unchecked.IDToken)
		if err != nil {
			t.Fatalf("precondition validate: %v", err)
		}
		if n, has := claims.Claims["nonce"]; has {
			t.Fatalf("precondition: the server signed a nonce (%v) although none was sent", n)
		}

		code = browserLogin(t, req, itRedirectURI, itAlice, itAlicePassword)
		_, err = kc.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, req.Nonce)
		if ae := requireAuthError(t, err, "absent nonce"); ae.Msg != msgBadNonce {
			t.Fatalf("absent nonce: got Msg=%q", ae.Msg)
		}
	})

	t.Run("ReusedCodeIsRefusedWithoutLeakingIt", func(t *testing.T) {
		req, code := aliceLogin(t, kc)
		// The login itself (the callback URL carries the code) is not the SDK's leak — measure from here.
		var tokens *TokenSet
		var reused error
		printed := captureProcessOutput(t, func() {
			var err error
			tokens, err = kc.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, req.Nonce)
			if err != nil {
				t.Fatalf("first exchange: %v", err)
			}
			_, reused = kc.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, req.Nonce)
		})
		if ae := requireAuthError(t, reused, "reused code"); ae.OAuthError != "invalid_grant" {
			t.Fatalf("reused code: want invalid_grant, got %q (%v)", ae.OAuthError, reused)
		}
		requireHidden(t, renderedError(reused)+printed, "the reused-code error, its cause chain or process output",
			secret{"code", code}, secret{"code_verifier", req.CodeVerifier}, secret{"client secret", itWebSecrets["it-web"]},
			secret{"access token", tokens.AccessToken}, secret{"refresh token", tokens.RefreshToken},
			secret{"id_token", tokens.IDToken})
	})

	// The exchange path checks the id_token's claims, not only its signature: a client that expects another
	// audience refuses Keycloak's genuine id_token (aud = it-web). ⚠️ Config.ExpectedAudience governs this
	// check as well as Validate (config.go) — so a consumer who points it at a resource server can no longer
	// exchange a code with a nonce.
	t.Run("RefusesAnIDTokenForAnotherAudience", func(t *testing.T) {
		other := webClient(t, serverURL, "it-web", func(c *Config) { c.ExpectedAudience = "not-it-web" })
		req, code := aliceLogin(t, other)
		_, err := other.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, req.Nonce)
		if ae := requireAuthError(t, err, "foreign audience"); ae.Msg != msgBadIDToken {
			t.Fatalf("foreign audience: got Msg=%q", ae.Msg)
		}
		var tve *TokenValidationError
		if !errors.As(err, &tve) || !strings.HasPrefix(tve.Msg, "claims: ") {
			t.Fatalf("foreign audience: want a TokenValidationError from the claims check, got %v", err)
		}
	})

	// The issuer check, against a real id_token. Keycloak 26.6 binds iss to the host the AUTHORIZATION
	// request used (measured: authorized through 127.0.0.1, exchanged through localhost → iss names
	// 127.0.0.1), so logging in through the other spelling of the loopback host yields a genuinely signed
	// id_token whose iss the SDK, configured with serverURL, must refuse.
	t.Run("RefusesAnIDTokenFromAnotherIssuer", func(t *testing.T) {
		u, err := url.Parse(serverURL)
		if err != nil {
			t.Fatalf("server URL: %v", err)
		}
		alias := map[string]string{"localhost": "127.0.0.1", "127.0.0.1": "localhost"}[u.Hostname()]
		if alias == "" {
			t.Skipf("the daemon host %q has no second loopback spelling to authorize through", u.Hostname())
		}
		viaAlias := func() (AuthorizationRequest, string) {
			req := kc.Auth.CreateAuthorizationRequest(itRedirectURI)
			req.URL = strings.Replace(req.URL, "://"+u.Host+"/", "://"+alias+":"+u.Port()+"/", 1)
			return req, browserLogin(t, req, itRedirectURI, itAlice, itAlicePassword)
		}
		// Precondition: the server really puts the alias in iss (an empty nonce skips the SDK's check).
		req, code := viaAlias()
		unchecked, err := kc.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, "")
		if err != nil || unchecked.IDToken == "" {
			t.Fatalf("precondition exchange: %v %v", unchecked, err)
		}
		if iss, _ := unverifiedPayload(t, unchecked.IDToken)["iss"].(string); !strings.Contains(iss, "://"+alias+":") {
			t.Fatalf("precondition: want an iss on %s, got %q", alias, iss)
		}

		req, code = viaAlias()
		_, err = kc.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, req.Nonce)
		if ae := requireAuthError(t, err, "foreign issuer"); ae.Msg != msgBadIDToken {
			t.Fatalf("foreign issuer: got Msg=%q", ae.Msg)
		}
		var tve *TokenValidationError
		if !errors.As(err, &tve) || !strings.HasPrefix(tve.Msg, "claims: ") {
			t.Fatalf("foreign issuer: want a TokenValidationError from the claims check, got %v", err)
		}
	})

	// Without the openid scope Keycloak issues no id_token at all — with a nonce expected, that fails closed.
	t.Run("RefusesAnExchangeThatReturnsNoIDToken", func(t *testing.T) {
		plain := webClient(t, serverURL, "it-web", func(c *Config) { c.Scopes = []string{"profile"} })
		req, code := aliceLogin(t, plain)
		// Precondition: the server really omits the id_token (else the refusal below measures something else).
		unchecked, err := plain.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, "")
		if err != nil || unchecked.AccessToken == "" || unchecked.IDToken != "" {
			t.Fatalf("precondition: want an access token and no id_token, got %v %v", unchecked, err)
		}
		req, code = aliceLogin(t, plain)
		_, err = plain.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, req.Nonce)
		if ae := requireAuthError(t, err, "no id_token"); ae.Msg != msgNoIDToken {
			t.Fatalf("no id_token: got Msg=%q", ae.Msg)
		}
	})

	// it-web-hs256's id_token is signed with the realm's HMAC key — a symmetric key is never in the JWKS.
	for _, tc := range []struct {
		name       string
		algorithms []string
		layer      string // the TokenValidationError.Msg prefix — which check refused
	}{
		{"PinnedRS256", []string{"RS256"}, "parse: "},         // the algorithm pin refuses first
		{"HS256Allowed", []string{"RS256", "HS256"}, "key: "}, // opening the pin does not help: no such key in the JWKS
	} {
		t.Run("IDTokenSignedOutsideTheJWKSIsRefused/"+tc.name, func(t *testing.T) {
			hs := webClient(t, serverURL, "it-web-hs256", func(c *Config) { c.SignatureAlgorithms = tc.algorithms })
			req, code := aliceLogin(t, hs)
			_, err := hs.Auth.ExchangeCode(ctx, code, itRedirectURI, req.CodeVerifier, req.Nonce)
			if ae := requireAuthError(t, err, "HS256 id_token"); ae.Msg != msgBadIDToken {
				t.Fatalf("HS256 id_token: got Msg=%q", ae.Msg)
			}
			var tve *TokenValidationError
			if !errors.As(err, &tve) || !strings.HasPrefix(tve.Msg, tc.layer) {
				t.Fatalf("HS256 id_token: want a TokenValidationError from %q, got %v", tc.layer, err)
			}
		})
	}
}
