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
	echoToken    = "walrustokenpx" // the token Introspect asks about
)

// echoIdP answers every token and introspection POST with status (400 unless set) {"error": …} — error is fixed, or
// built by echo from what the request sent (the form, with the client secret from Basic when it came that way).
type echoIdP struct {
	srv      *httptest.Server
	mu       sync.Mutex
	fixed    any
	echo     func(sent map[string]string) any
	status   int
	location string // a Location header on the answer, when set
	raw      string // the whole answer body instead of {"error": …}, when set
	sent     []map[string]string
	requests []string // every request as "METHOD /path" — the 3xx cells read which method reached redirectTarget
}

// redirectTarget is where the 3xx cells point Location (this server, same origin) — a client that follows it shows up in
// requests.
const redirectTarget = "/redirect-target"

func newEchoIdP(t *testing.T) *echoIdP {
	t.Helper()
	p := &echoIdP{}
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.mu.Lock()
		p.requests = append(p.requests, r.Method+" "+r.URL.Path)
		p.mu.Unlock()
		if r.URL.Path == redirectTarget {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"redirect_target_reached"}`))
			return
		}
		if !strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token") &&
			!strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token/introspect") {
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
		status, location, raw := p.status, p.location, p.raw
		p.mu.Unlock()
		body, _ := json.Marshal(map[string]any{"error": value})
		if raw != "" {
			body = []byte(raw)
		}
		w.Header().Set("Content-Type", "application/json")
		if location != "" {
			w.Header().Set("Location", location)
		}
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
	p.status, p.fixed, p.echo, p.sent, p.location, p.raw, p.requests = status, fixed, echo, nil, "", "", nil
}

// answerRaw answers every token and introspection POST at status with body as it is, and a Location header when location
// is set.
func (p *echoIdP) answerRaw(status int, body, location string) {
	p.answerWith(status, nil, nil)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.raw, p.location = body, location
}

// redirectWith answers as answerWith does, with a Location header — a redirect net/http would follow.
func (p *echoIdP) redirectWith(status int, fixed any, location string) {
	p.answerWith(status, fixed, nil)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.location = location
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
	{"Introspect", []string{"token"}, func(ctx context.Context, c *Client) error {
		_, err := c.Auth.Introspect(ctx, echoToken)
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

// The rows all nine languages share: the overlap ignores ASCII case (an IdP or proxy that echoes the secret lowercased),
// and the shape is exactly [a-z_]{1,64}.
func TestOAuthErrorCodeSharedRows(t *testing.T) {
	// V5: U+212A KELVIN SIGN, then "ey" — built from the code point. The fold is ASCII so the nine agree; a secret's
	// non-ASCII letter is compared as itself.
	kelvinEy := string(rune(0x212A)) + "ey"
	for _, c := range []struct {
		row, s string
		sent   []string
		want   string
	}{
		{"V1 a lowercased echo", "mysecret", []string{"MySecret"}, ""},
		{"V2 a truncated lowercased echo", "mysec", []string{"MySecret"}, ""},
		{"V3 an extended lowercased echo", "invalid_mysecret_x", []string{"MySecret"}, ""},
		{"V4 control", "invalid_grant", []string{"MySecret"}, "invalid_grant"},
		{"V5 the fold is ASCII only", "key", []string{kelvinEy}, "key"},
		{"V6 the shape", "invalid__grant", nil, "invalid__grant"},
		{"V6 the shape", "_", nil, "_"},
	} {
		t.Run(c.row+" "+c.s, func(t *testing.T) {
			if got := oauthErrorCode(c.s, c.sent...); got != c.want {
				t.Errorf("oauthErrorCode(%q, %q) = %q, want %q", c.s, c.sent, got, c.want)
			}
		})
	}
}

// An IdP or proxy that echoes the secret lowercased — the overlap ignores ASCII case.
func TestALowercasedEchoOfTheClientSecretIsNeverCarried(t *testing.T) {
	p := newEchoIdP(t)
	for _, s := range echoSurfaces {
		p.answer(nil, func(sent map[string]string) any { return strings.ToLower(sent["client_secret"]) })
		err := s.run(context.Background(), echoClient(t, p, "EchoMixedCase"))
		if got := p.firstSent(t)["client_secret"]; got != "EchoMixedCase" {
			t.Fatalf("%s: the request sent client_secret %q", s.name, got)
		}
		checkWithheld(t, s.name+" · lowercased", err, "echomixedcase")
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

// OAuthError is set on every surface — the admin login (gocloak's LoginClient) and Introspect too, which left it empty at
// an error status (registry oauth-error-code-surface-divergent). The admin login's Msg still ends in the code (loginError).
func TestACodeThatOverlapsNothingSentIsCarried(t *testing.T) {
	p := newEchoIdP(t)
	for _, s := range echoSurfaces {
		for _, code := range []string{"invalid_client", "invalid_grant", "slow_down", strings.Repeat("a", 64)} {
			p.answer(code, nil)
			err := s.run(context.Background(), echoClient(t, p, echoSecret))
			ae := authErrorOf(t, s.name+" · "+code, err)
			if s.name == "admin" && !strings.HasSuffix(ae.Msg, ": "+code) {
				t.Errorf("admin · %s: Msg = %q, want it to end in the code", code, ae.Msg)
			}
			if ae.OAuthError != code {
				t.Errorf("%s · %s: OAuthError = %q", s.name, code, ae.OAuthError)
			}
		}
	}
}

// The two error statuses the nine languages were measured with (registry oauth-error-code-surface-divergent): A is 400
// {"error":"invalid_grant"}, B is 401 {"error":"invalid_client"}. Every surface carries the code in OAuthError, as every one
// does at 200 (#1184). Before: the admin login (Client.Admin) and Introspect left it empty for both.
func TestAnErrorStatusCarriesTheCodeOnEverySurface(t *testing.T) {
	p := newEchoIdP(t)
	for _, cell := range []struct {
		name   string
		status int
		code   string
	}{{"A", http.StatusBadRequest, "invalid_grant"}, {"B", http.StatusUnauthorized, "invalid_client"}} {
		for _, s := range echoSurfaces {
			p.answerWith(cell.status, cell.code, nil)
			err := s.run(context.Background(), echoClient(t, p, echoSecret))
			label := cell.name + " · " + s.name
			if ae := authErrorOf(t, label, err); ae.OAuthError != cell.code {
				t.Errorf("%s: OAuthError = %q, want %q — %v", label, ae.OAuthError, cell.code, err)
			}
		}
	}
}

// A 3xx is an error status too: one net/http does not follow (302 without a Location) and one this SDK refuses to follow
// (307 with one — the admin lane's errOnRedirect, the auth lane's noFollowRedirect) carry the code as a 4xx does.
func TestARedirectStatusCarriesTheCodeOnEverySurface(t *testing.T) {
	p := newEchoIdP(t)
	for _, cell := range []struct {
		name     string
		status   int
		location string
	}{{"302 without a Location", http.StatusFound, ""}, {"307 with a Location", http.StatusTemporaryRedirect, "/elsewhere"}} {
		for _, s := range echoSurfaces {
			p.redirectWith(cell.status, "invalid_grant", cell.location)
			err := s.run(context.Background(), echoClient(t, p, echoSecret))
			label := cell.name + " · " + s.name
			if ae := authErrorOf(t, label, err); ae.OAuthError != "invalid_grant" {
				t.Errorf("%s: OAuthError = %q, want invalid_grant — %v", label, ae.OAuthError, err)
			}
		}
	}
}

func TestThePriceASecretThatIsAPieceOfTheCodeWithholdsIt(t *testing.T) {
	p := newEchoIdP(t)
	p.answer("invalid_client", nil)
	for _, s := range []int{0, 3, 4, 5} {
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

// The OAuth `error` at a 3xx and a 5xx (registry node-5xx-oauth-error-code-empty). The contract puts it in the code field
// "at any status"; that was measured at 400 · 401 (#1199) and the other 2xx (#1207) only. 5xx: pinned as the contract reads.
// 302 (Location on this server): recorded, not pinned — the 3xx contract is open; only "never followed" is asserted.
const (
	echoB5      = `{"error":"temporarily_unavailable","error_description":"down"}`
	echoNoError = `{"message":"down"}`
)

// errorStatusCell is one surface's outcome: OAuthError ("" when none or not an *AuthError), one line, every request seen.
type errorStatusCell struct {
	code     string
	line     string
	requests []string
}

func runErrorStatusCell(t *testing.T, p *echoIdP, surface int, status int, body, location string) errorStatusCell {
	t.Helper()
	s := echoSurfaces[surface]
	p.answerRaw(status, body, location)
	err := s.run(context.Background(), echoClient(t, p, echoSecret))
	p.mu.Lock()
	seen := append([]string(nil), p.requests...)
	p.mu.Unlock()
	code, outcome := "", "success"
	if err != nil {
		var ae *AuthError
		shown := "-"
		if errors.As(err, &ae) {
			code, shown = ae.OAuthError, fmt.Sprintf("%q", ae.OAuthError)
		}
		outcome = fmt.Sprintf("%T(%v) code=%s", err, err, shown)
	}
	return errorStatusCell{code, fmt.Sprintf("%d %s → %s requests=%q", status, s.name, outcome, seen), seen}
}

func TestAServerErrorStatusCarriesTheOAuthErrorOnEverySurface(t *testing.T) {
	p := newEchoIdP(t)
	for _, status := range []int{http.StatusInternalServerError, http.StatusServiceUnavailable} {
		for i := range echoSurfaces {
			c := runErrorStatusCell(t, p, i, status, echoB5, "")
			t.Log(c.line)
			if c.code != "temporarily_unavailable" {
				t.Errorf("%s: OAuthError = %q, want temporarily_unavailable", c.line, c.code)
			}
		}
	}
}

// Controls: the same body at 400 carries it; a 503 whose body names no `error` carries none.
func TestTheErrorStatusControlsCarryItAt400AndNoneWithoutOne(t *testing.T) {
	p := newEchoIdP(t)
	for i := range echoSurfaces {
		at400 := runErrorStatusCell(t, p, i, http.StatusBadRequest, echoB5, "")
		none := runErrorStatusCell(t, p, i, http.StatusServiceUnavailable, echoNoError, "")
		t.Log(at400.line)
		t.Log(none.line)
		if at400.code != "temporarily_unavailable" {
			t.Errorf("%s: OAuthError = %q, want temporarily_unavailable", at400.line, at400.code)
		}
		if none.code != "" {
			t.Errorf("%s: OAuthError = %q, want none", none.line, none.code)
		}
	}
}

func TestARedirectErrorStatusToThisServerIsRecordedAndNeverFollowed(t *testing.T) {
	p := newEchoIdP(t)
	for i := range echoSurfaces {
		c := runErrorStatusCell(t, p, i, http.StatusFound, echoB5, p.srv.URL+redirectTarget)
		t.Log(c.line)
		for _, r := range c.requests {
			if strings.HasSuffix(r, " "+redirectTarget) {
				t.Errorf("%s: the redirect was followed", c.line)
			}
		}
	}
}
