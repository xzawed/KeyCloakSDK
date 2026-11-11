package keycloak

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// The OAuth `error` code an SDK error carries is a code, never a value the request sent (registry
// token-error-code-secret-echo · oauth-error-field-echo-unmasked).
//
// The IdP's `error` is response body too. An endpoint (or a proxy) that echoes what the request sent puts the client
// secret, the refresh token or the code there. OAuthError took any value in the RFC 6749 grammar — a Keycloak-style
// secret and a JWT are — and a lowercase-only secret has the code shape itself, so it also reached %#v, the cause's text
// and the admin login's Msg (measured on main a7d0fdf3). One rule now (oauthErrorCode): shaped like a code
// ([a-z_]{1,64}) and overlapping no non-empty secret the request sent — neither contains the other, so a truncated or
// extended echo is withheld too. The price is pinned below: a secret that is a piece of a registered code ("client")
// withholds that code.

// Code-shaped on purpose (the shape alone cannot withhold them), and no two share a piece — an echo of one value must
// be withheld by comparing against THAT value, not a sibling's prefix.
const (
	echoSecret   = "zebrasecretjk"
	echoRefresh  = "yakrefreshvq"
	echoCode     = "vulturecodeby"
	echoVerifier = "ocelotverifierocelotverifierocelotverifierxx"
)

// echoIdP answers every token POST with status (400 unless set) {"error": …} — error is fixed, or built by echo from
// what the request sent (the form, with the client secret from Basic when it came that way).
type echoIdP struct {
	srv    *httptest.Server
	mu     sync.Mutex
	fixed  any
	echo   func(sent map[string]string) any
	status int
	sent   []map[string]string
}

func newEchoIdP(t *testing.T) *echoIdP {
	t.Helper()
	p := &echoIdP{}
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token") {
			http.NotFound(w, r)
			return
		}
		_ = r.ParseForm()
		sent := map[string]string{}
		for k := range r.PostForm {
			sent[k] = r.PostForm.Get(k)
		}
		if _, pw, ok := r.BasicAuth(); ok {
			sent["client_secret"] = pw
		}
		p.mu.Lock()
		p.sent = append(p.sent, sent)
		value := p.fixed
		if p.echo != nil {
			value = p.echo(sent)
		}
		status := p.status
		p.mu.Unlock()
		body, _ := json.Marshal(map[string]any{"error": value})
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write(body)
	}))
	t.Cleanup(p.srv.Close)
	return p
}

func (p *echoIdP) answer(fixed any, echo func(map[string]string) any) {
	p.answerWith(http.StatusBadRequest, fixed, echo)
}

func (p *echoIdP) answerWith(status int, fixed any, echo func(map[string]string) any) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.status, p.fixed, p.echo, p.sent = status, fixed, echo, nil
}

func (p *echoIdP) firstSent(t *testing.T) map[string]string {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.sent) == 0 {
		t.Fatal("no token request reached the IdP")
	}
	return p.sent[0]
}

var echoSurfaces = []struct {
	name   string
	params []string // the secret form fields this surface sends besides the client secret
	run    func(context.Context, *Client) error
}{
	{"ClientCredentialsToken", nil, func(ctx context.Context, c *Client) error {
		_, err := c.Auth.ClientCredentialsToken(ctx)
		return err
	}},
	{"Refresh", []string{"refresh_token"}, func(ctx context.Context, c *Client) error {
		_, err := c.Auth.Refresh(ctx, echoRefresh)
		return err
	}},
	{"ExchangeCode", []string{"code", "code_verifier"}, func(ctx context.Context, c *Client) error {
		_, err := c.Auth.ExchangeCode(ctx, echoCode, "https://app/cb", echoVerifier, "")
		return err
	}},
	{"provider", nil, func(ctx context.Context, c *Client) error {
		_, err := NewClientCredentialsTokenProvider(c.Auth.ClientCredentialsToken, 30).Token(ctx)
		return err
	}},
	{"admin", nil, func(ctx context.Context, c *Client) error {
		a, err := c.Admin(ctx)
		if err != nil {
			return err
		}
		_, err = a.Users.Get(ctx, "u1")
		return err
	}},
}

func echoClient(t *testing.T, p *echoIdP, secret string) *Client {
	t.Helper()
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: secret})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// renderings is every text a log line could take of err and its chain.
func renderings(err error) []string {
	out := []string{fmt.Sprintf("%v", err), fmt.Sprintf("%+v", err), fmt.Sprintf("%#v", err)}
	for e, i := errors.Unwrap(err), 0; e != nil && i < 10; e, i = errors.Unwrap(e), i+1 {
		out = append(out, e.Error(), fmt.Sprintf("%#v", e))
	}
	return out
}

func authErrorOf(t *testing.T, label string, err error) *AuthError {
	t.Helper()
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Fatalf("%s: want *AuthError, got %T: %v", label, err, err)
	}
	return ae
}

func checkWithheld(t *testing.T, label string, err error, value string) {
	t.Helper()
	if ae := authErrorOf(t, label, err); ae.OAuthError != "" {
		t.Errorf("%s: OAuthError = %q, want none", label, ae.OAuthError)
	}
	for i, text := range renderings(err) {
		if strings.Contains(text, value) {
			t.Errorf("%s: rendering #%d shows the echoed %q: %s", label, i, value, text)
		}
	}
}

// Every piece and every padding, so each direction of the overlap is pinned (the code inside the value · the value
// inside the code).
var echoForms = map[string]func(string) string{
	"whole":    func(v string) string { return v },
	"prefix":   func(v string) string { return v[:11] },
	"suffix":   func(v string) string { return v[len(v)-11:] },
	"middle":   func(v string) string { return v[2:11] },
	"extended": func(v string) string { return v + "_x" },
	"prefixed": func(v string) string { return "x_" + v },
	"wrapped":  func(v string) string { return "x_" + v + "_x" },
}

// Keycloak answers a bad client with 401, not 400 — an error status other than 400 takes the same rule.
func TestAnEchoOnA401IsNeverCarried(t *testing.T) {
	p := newEchoIdP(t)
	for _, s := range echoSurfaces {
		for _, param := range append([]string{"client_secret"}, s.params...) {
			p.answerWith(http.StatusUnauthorized, nil, func(sent map[string]string) any { return sent[param] })
			err := s.run(context.Background(), echoClient(t, p, echoSecret))
			checkWithheld(t, s.name+" · 401 · "+param, err, p.firstSent(t)[param])
		}
	}
}

// oauthErrorCode itself — each direction of the overlap, every position in sent, and the empty secret that must not be
// compared (it is a piece of every code).
func TestOAuthErrorCodeOverlap(t *testing.T) {
	for _, c := range []struct {
		s    string
		sent []string
		want string
	}{
		{"invalid_grant", []string{"s3cret-Value"}, "invalid_grant"},
		{"mysecret", []string{"mysecret"}, ""},
		{"mysecret_x", []string{"mysecret"}, ""},
		{"x_mysecret", []string{"mysecret"}, ""},
		{"x_mysecret_x", []string{"mysecret"}, ""},
		{"mysec", []string{"mysecret"}, ""},
		{"secret", []string{"mysecret"}, ""},
		{"yse", []string{"mysecret"}, ""},
		{"fresh", []string{"zzz", "myrefresh"}, ""},
		{"x_myrefresh", []string{"zzz", "myrefresh"}, ""},
		{"invalid_grant", []string{"", ""}, "invalid_grant"},
		{"invalid_client", []string{"client"}, ""},
	} {
		if got := oauthErrorCode(c.s, c.sent...); got != c.want {
			t.Errorf("oauthErrorCode(%q, %q) = %q, want %q", c.s, c.sent, got, c.want)
		}
	}
}

func TestAnEchoedClientSecretIsNeverCarried(t *testing.T) {
	p := newEchoIdP(t)
	for _, s := range echoSurfaces {
		for form, shape := range echoForms {
			p.answer(nil, func(sent map[string]string) any { return shape(sent["client_secret"]) })
			err := s.run(context.Background(), echoClient(t, p, echoSecret))
			if got := p.firstSent(t)["client_secret"]; got != echoSecret {
				t.Fatalf("%s: the request sent client_secret %q", s.name, got)
			}
			checkWithheld(t, s.name+" · "+form, err, shape(echoSecret))
		}
	}
}

func TestAnEchoedGrantValueIsNeverCarried(t *testing.T) {
	p := newEchoIdP(t)
	for _, s := range echoSurfaces {
		for _, param := range s.params {
			for form, shape := range echoForms {
				p.answer(nil, func(sent map[string]string) any { return shape(sent[param]) })
				err := s.run(context.Background(), echoClient(t, p, echoSecret))
				checkWithheld(t, s.name+" · "+param+" · "+form, err, shape(p.firstSent(t)[param]))
			}
		}
	}
}

func TestAPublicClientWithholdsItsEchoedRefreshTokenAndStillGetsACode(t *testing.T) {
	p := newEchoIdP(t)
	refresh := echoSurfaces[1]
	p.answer(nil, func(sent map[string]string) any { return sent["refresh_token"] })
	checkWithheld(t, "public · echo", refresh.run(context.Background(), echoClient(t, p, "")), echoRefresh)
	if got := p.firstSent(t)["client_secret"]; got != "" {
		t.Fatalf("a public client sent client_secret %q", got)
	}
	p.answer("invalid_grant", nil)
	if ae := authErrorOf(t, "public · code", refresh.run(context.Background(), echoClient(t, p, ""))); ae.OAuthError != "invalid_grant" {
		t.Errorf("public client: OAuthError = %q, want invalid_grant", ae.OAuthError)
	}
}

func TestAValueThatIsNotACodeIsNeverCarried(t *testing.T) {
	p := newEchoIdP(t)
	values := map[string]any{
		"keycloak-style secret": "Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5",
		"jwt":                   "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl",
		"capital letter":        "Invalid_client",
		"space":                 "invalid client",
		"digit":                 "invalid_client2",
		"65 characters":         strings.Repeat("a", 65),
		"array":                 []string{"invalid_client"},
		"number":                400,
	}
	for _, s := range echoSurfaces {
		for name, value := range values {
			p.answer(value, nil)
			err := s.run(context.Background(), echoClient(t, p, echoSecret))
			label := s.name + " · " + name
			if ae := authErrorOf(t, label, err); ae.OAuthError != "" {
				t.Errorf("%s: OAuthError = %q, want none", label, ae.OAuthError)
			}
			if str, ok := value.(string); ok {
				for i, text := range renderings(err) {
					if strings.Contains(text, str) {
						t.Errorf("%s: rendering #%d shows %q", label, i, str)
					}
				}
			}
		}
	}
}

// OAuthError is set by the grants and the provider; the admin login keeps the code in Msg only (loginError).
func TestACodeThatOverlapsNothingSentIsCarried(t *testing.T) {
	p := newEchoIdP(t)
	for _, s := range echoSurfaces {
		for _, code := range []string{"invalid_client", "invalid_grant", "slow_down", strings.Repeat("a", 64)} {
			p.answer(code, nil)
			err := s.run(context.Background(), echoClient(t, p, echoSecret))
			ae := authErrorOf(t, s.name+" · "+code, err)
			if s.name == "admin" {
				if !strings.HasSuffix(ae.Msg, ": "+code) {
					t.Errorf("admin · %s: Msg = %q, want it to end in the code", code, ae.Msg)
				}
				continue
			}
			if ae.OAuthError != code {
				t.Errorf("%s · %s: OAuthError = %q", s.name, code, ae.OAuthError)
			}
		}
	}
}

func TestThePriceASecretThatIsAPieceOfTheCodeWithholdsIt(t *testing.T) {
	p := newEchoIdP(t)
	p.answer("invalid_client", nil)
	for _, s := range []int{0, 3} {
		err := echoSurfaces[s].run(context.Background(), echoClient(t, p, "client"))
		if ae := authErrorOf(t, echoSurfaces[s].name, err); ae.OAuthError != "" {
			t.Errorf("%s: OAuthError = %q, want none", echoSurfaces[s].name, ae.OAuthError)
		}
	}
	err := echoSurfaces[4].run(context.Background(), echoClient(t, p, "client"))
	if ae := authErrorOf(t, "admin", err); strings.Contains(ae.Msg, "invalid_client") {
		t.Errorf("admin: Msg = %q, want no code", ae.Msg)
	}
}
