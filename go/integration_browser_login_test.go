//go:build integration

package keycloak

// Browserless login — fills the real Keycloak login form over HTTP to obtain an authorization code.
// Three steps, the same shape as python/tests/integration/browser_login.py:
//
//  1. GET the authorization URL the SDK built (login page + auth-session cookies; step 2 replays them).
//  2. POST username/password to the action of <form id="kc-form-login"> WITHOUT following the redirect —
//     nothing listens on redirect_uri; the 302's Location is the callback.
//  3. Take code and state from Location, and check that state is the one the SDK issued.
//
// A missing form or a wrong status fails with the head of the HTML, so a theme change shows its cause.

import (
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"
)

const loginFormID = "kc-form-login"

var (
	htmlFormTag  = regexp.MustCompile(`(?is)<form\b[^>]*>`)
	htmlTagAttrs = regexp.MustCompile(`(?is)([a-z][a-z0-9_:.-]*)\s*=\s*"([^"]*)"`)
)

// loginFormAction returns the entity-decoded action of <form id="kc-form-login"> ("" when absent).
// No HTML parser: the module does not import one and the form tag is all we need.
func loginFormAction(page string) string {
	for _, tag := range htmlFormTag.FindAllString(page, -1) {
		attrs := map[string]string{}
		for _, m := range htmlTagAttrs.FindAllStringSubmatch(tag, -1) {
			attrs[strings.ToLower(m[1])] = html.UnescapeString(m[2])
		}
		if attrs["id"] == loginFormID {
			return attrs["action"]
		}
	}
	return ""
}

func loginSnippet(resp *http.Response, body string) string {
	if len(body) > 1500 {
		body = body[:1500]
	}
	return "HTTP " + resp.Status + " " + resp.Request.URL.String() + "\n" + body
}

func loginRoundTrip(t *testing.T, browser *http.Client, req *http.Request) (*http.Response, string) {
	t.Helper()
	resp, err := browser.Do(req)
	if err != nil {
		t.Fatalf("browser %s %s: %v", req.Method, req.URL.Redacted(), err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("browser %s read: %v", req.Method, err)
	}
	return resp, string(body)
}

// browserLogin logs username in through req (the SDK's CreateAuthorizationRequest result) and returns
// the authorization code the server issued.
func browserLogin(t *testing.T, req AuthorizationRequest, redirectURI, username, password string) string {
	t.Helper()
	// No cookie jar and no redirect following — both on purpose (see the cookie note below).
	browser := &http.Client{
		Timeout:       30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	get, err := http.NewRequest(http.MethodGet, req.URL, nil)
	if err != nil {
		t.Fatalf("authorization URL: %v", err)
	}
	page, body := loginRoundTrip(t, browser, get)
	if page.StatusCode != http.StatusOK {
		t.Fatalf("login page did not render:\n%s", loginSnippet(page, body))
	}
	action := loginFormAction(body)
	if action == "" {
		t.Fatalf("no <form id=%q> in the login page:\n%s", loginFormID, loginSnippet(page, body))
	}

	form := url.Values{"username": {username}, "password": {password}}
	post, err := http.NewRequest(http.MethodPost, action, strings.NewReader(form.Encode()))
	if err != nil {
		t.Fatalf("login form action %q: %v", action, err)
	}
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// ⚠️ Replay the cookies by hand. Keycloak 26.6 marks its login cookies Secure over plain http when the
	// host is localhost or 127.0.0.1 (measured: AUTH_SESSION_ID, KC_AUTH_SESSION_HASH, KC_RESTART — the same
	// cookies are plain for a LAN IP). A store that follows RFC 6265 to the letter then does not send them,
	// and the POST ends in 400 "Restart login cookie not found" (python pilot). Go's cookiejar treats
	// localhost and loopback IPs as secure and does work here (measured) — replaying by hand keeps the
	// helper independent of any store's policy.
	var cookies []string
	for _, c := range page.Cookies() {
		cookies = append(cookies, c.Name+"="+c.Value)
	}
	post.Header.Set("Cookie", strings.Join(cookies, "; "))
	answer, answerBody := loginRoundTrip(t, browser, post)
	if answer.StatusCode != http.StatusFound {
		t.Fatalf("login POST did not redirect:\n%s", loginSnippet(answer, answerBody))
	}

	location := answer.Header.Get("Location")
	callback, err := url.Parse(location)
	if err != nil {
		t.Fatalf("callback %q: %v", location, err)
	}
	if got := callback.Scheme + "://" + callback.Host + callback.Path; got != redirectURI {
		t.Fatalf("login redirected somewhere else: %s", location)
	}
	query := callback.Query()
	// state is the CSRF value the SDK put in the authorization URL — the server must hand it back as is.
	if got := query["state"]; len(got) != 1 || got[0] != req.State {
		t.Fatalf("state mismatch: sent %q, got %q", req.State, got)
	}
	codes := query["code"]
	if len(codes) != 1 || codes[0] == "" {
		t.Fatalf("no single authorization code in the callback: %s", location)
	}
	return codes[0]
}
