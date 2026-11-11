package keycloak

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
)

// AuthError.OAuthError carries the token endpoint's `error` value only when it is shaped like an OAuth error code —
// [a-z_]{1,64}, the shape of every registered code — unchanged; anything else is no code (""). It is never trimmed into
// one: "invalid_client\r\n" is not "invalid_client". (wave4-hardening-go (4) and .NET #710 first took the RFC 6749 §5.2
// grammar, 1*NQSCHAR; a Keycloak-style secret, a JWT and a form-encoded secret are all in it, and an endpoint that echoes
// what it got put them in the field — token-error-code-secret-echo, oauth_error_code_echo_test.go.)
//
// Before #764: every value reached the field verbatim — CR/LF/CRLF, NUL, DEL, 0x1F, HTAB, U+00E9, U+2028, '"', '\' — in
// all three grants (ExchangeCode with and without a nonce), for 400, 401 and an error-carrying 200, JSON or form-encoded
// (measured on cfb3b29 through the public API) — the field itself is what a caller logs or compares.

// grammarSecret has no lowercase letter, so no row here overlaps it — the overlap rule is oauth_error_code_echo_test.go's.
const grammarSecret = "S3CR3T-9"

// codeShaped is the rule, written from the rule — the expectation, not the implementation.
func codeShaped(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; (c < 'a' || c > 'z') && c != '_' {
			return false
		}
	}
	return true
}

type oauthErrRow struct{ name, val string }

// The .NET #710 rows, plus HTAB and values the RFC grammar admits but the code shape does not.
func oauthErrRows() []oauthErrRow {
	return []oauthErrRow{
		{"clean", "invalid_client"},
		{"trailing LF", "invalid_client\n"},
		{"trailing CR", "invalid_client\r"},
		{"trailing CRLF", "invalid_client\r\n"},
		{"LF inside", "invalid\nclient"},
		{"NUL", "invalid_client\x00"},
		{"DEL", "invalid_client\x7f"},
		{"0x1F", "invalid_client\x1f"},
		{"HTAB", "invalid\tclient"},
		{"U+00E9", "invalid_cliént"},
		{"U+2028", "invalid client"},
		{"double quote", `invalid"client`},
		{"backslash", `invalid\client`},
		{"empty", ""},
		{"space only", " "},
		{"spaces only", "   "},
		{"grammar edges", "!#[]~"},
		{"in grammar, not code-shaped", "Invalid-Client 2"},
		{"long, in grammar", strings.Repeat("a", 100000)},
		{"longest code", strings.Repeat("a", 64)},
		{"one past the longest", strings.Repeat("a", 65)},
	}
}

// oauthErrIdP answers every request with the current payload — set before each call; the calls run one at a time.
type oauthErrIdP struct {
	srv     *httptest.Server
	status  atomic.Int32
	ctype   atomic.Value
	payload atomic.Value
}

func newOAuthErrIdP(t *testing.T) *oauthErrIdP {
	t.Helper()
	p := &oauthErrIdP{}
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", p.ctype.Load().(string))
		w.WriteHeader(int(p.status.Load()))
		_, _ = w.Write([]byte(p.payload.Load().(string)))
	}))
	t.Cleanup(p.srv.Close)
	return p
}

// serve sets the response: val as the `error` value of a JSON or form-encoded body.
func (p *oauthErrIdP) serve(t *testing.T, status int, form bool, val string) {
	t.Helper()
	body := "error=" + url.QueryEscape(val) + "&error_description=desc"
	ctype := "application/x-www-form-urlencoded"
	if !form {
		v, err := json.Marshal(val)
		if err != nil {
			t.Fatal(err)
		}
		body, ctype = `{"error":`+string(v)+`,"error_description":"desc"}`, "application/json"
	}
	p.status.Store(int32(status))
	p.ctype.Store(ctype)
	p.payload.Store(body)
}

var oauthErrCalls = []struct {
	name string
	run  func(context.Context, *AuthClient) error
}{
	{"ClientCredentialsToken", func(ctx context.Context, a *AuthClient) error {
		_, err := a.ClientCredentialsToken(ctx)
		return err
	}},
	{"Refresh", func(ctx context.Context, a *AuthClient) error {
		_, err := a.Refresh(ctx, "rt-in")
		return err
	}},
	{"ExchangeCode", func(ctx context.Context, a *AuthClient) error {
		_, err := a.ExchangeCode(ctx, "code-in", "https://app/cb", "verifier-in", "")
		return err
	}},
	{"ExchangeCode(nonce)", func(ctx context.Context, a *AuthClient) error {
		_, err := a.ExchangeCode(ctx, "code-in", "https://app/cb", "verifier-in", "nonce-in")
		return err
	}},
}

// checkOAuthError runs one grant and compares what OAuthError carries with what the rule admits.
func checkOAuthError(t *testing.T, label string, c *Client, call func(context.Context, *AuthClient) error, val string) {
	t.Helper()
	want := ""
	if codeShaped(val) {
		want = val
	}
	err := call(context.Background(), c.Auth)
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Errorf("%s: want *AuthError, got %T: %v", label, err, err)
		return
	}
	if ae.OAuthError != want {
		t.Errorf("%s: OAuthError = %.60q, want %.60q", label, ae.OAuthError, want)
	}
}

// Every row, through every grant, for 400, 401 and an error-carrying 200 (x/oauth2 fails a 2xx that carries an error),
// JSON and form-encoded.
func TestOAuthErrorCarriesOnlyACodeShapedValue(t *testing.T) {
	p := newOAuthErrIdP(t)
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: grammarSecret})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	for _, form := range []bool{false, true} {
		for _, status := range []int{400, 401, 200} {
			for _, r := range oauthErrRows() {
				p.serve(t, status, form, r.val)
				for _, call := range oauthErrCalls {
					label := fmt.Sprintf("%s · HTTP %d · form=%v · %s", r.name, status, form, call.name)
					checkOAuthError(t, label, c, call.run, r.val)
				}
			}
		}
	}
}

// Every byte between two letters, so each edge of the shape is a row of its own. A form-encoded body delivers each byte
// as it is — JSON cannot carry a raw byte past ASCII (encoding/json decodes it to U+FFFD).
func TestOAuthErrorShapeByteByByte(t *testing.T) {
	p := newOAuthErrIdP(t)
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: grammarSecret})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	kept := 0
	for b := 0; b < 256; b++ {
		val := "a" + string([]byte{byte(b)}) + "b"
		p.serve(t, 400, true, val)
		checkOAuthError(t, fmt.Sprintf("byte %#02x", b), c, oauthErrCalls[0].run, val)
		if codeShaped(val) {
			kept++
		}
	}
	// The expectation's own known answer: a-z and '_' — 27 bytes.
	if kept != 27 {
		t.Fatalf("the expectation admits %d bytes, want 27", kept)
	}
}
