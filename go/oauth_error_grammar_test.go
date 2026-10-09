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

// AuthError.OAuthError carries the token endpoint's `error` value only when it is an RFC 6749 §5.2 error code
// (wave4-hardening-go (4)) — error = 1*NQSCHAR, NQSCHAR = %x20-21 / %x23-5B / %x5D-7E — unchanged; anything else is no
// code (""). It is never trimmed into one: "invalid_client\r\n" is not "invalid_client". The rule and the rows follow
// .NET #710 (OAuthErrorCodeGrammarTests): a space-only value is a code (%x20 is NQSCHAR), and the grammar sets no length
// — the token-response cap (1 MiB) bounds it.
//
// Before: every value reached the field verbatim — CR/LF/CRLF, NUL, DEL, 0x1F, HTAB, U+00E9, U+2028, '"', '\' — in all
// four grants, for 400, 401 and an error-carrying 200, JSON or form-encoded (measured on cfb3b29 through the public
// API). Error() never carried it, and %#v already withheld a value not shaped like a code (errors.go) — the field
// itself is what a caller logs or compares.

// nqschar is the RFC's character class, written from the RFC — the expectation, not the implementation.
func nqschar(b byte) bool { return b >= 0x20 && b <= 0x7e && b != '"' && b != '\\' }

func inGrammar(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !nqschar(s[i]) {
			return false
		}
	}
	return true
}

type oauthErrRow struct{ name, val string }

// The .NET #710 rows, plus HTAB and two in-grammar values that are not shaped like a code (kept: the field is the
// grammar's, %#v keeps its stricter shape filter).
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

// checkOAuthError runs one grant and compares what OAuthError carries with what the grammar admits.
func checkOAuthError(t *testing.T, label string, c *Client, call func(context.Context, *AuthClient) error, val string) {
	t.Helper()
	want := ""
	if inGrammar(val) {
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
func TestOAuthErrorCarriesOnlyAnRFC6749ErrorCode(t *testing.T) {
	p := newOAuthErrIdP(t)
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"})
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

// Every byte between two letters, so each edge of each NQSCHAR range is a row of its own. A form-encoded body
// delivers each byte as it is — JSON cannot carry a raw byte past ASCII (encoding/json decodes it to U+FFFD).
func TestOAuthErrorGrammarByteByByte(t *testing.T) {
	p := newOAuthErrIdP(t)
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	kept := 0
	for b := 0; b < 256; b++ {
		val := "a" + string([]byte{byte(b)}) + "b"
		p.serve(t, 400, true, val)
		checkOAuthError(t, fmt.Sprintf("byte %#02x", b), c, oauthErrCalls[0].run, val)
		if inGrammar(val) {
			kept++
		}
	}
	// The expectation's own known answer: NQSCHAR is 0x20-0x7E without '"' and '\' — 93 bytes.
	if kept != 93 {
		t.Fatalf("the expectation admits %d bytes, want 93", kept)
	}
}
