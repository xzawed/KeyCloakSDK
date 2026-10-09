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
	"sync/atomic"
	"testing"

	"github.com/Nerzal/gocloak/v13"
)

// An access token an HTTP header cannot carry (wave4-hardening-go (3)).
//
// net/http refuses a control character other than HTAB — CR, LF and NUL among them — and DEL in a header value, before
// anything is sent. Before this file existed the SDK cached such a token from its own token request and every admin
// call then failed with an opaque *TransportError ("… message withheld (detail withheld: it can quote the IdP's
// response)"), naming the IdP's response as the cause when the cause was the token (measured: Client.Admin succeeded,
// four admin calls of four failed, 0 requests reached the admin server, 1 token request). The SDK now refuses it with
// an *AuthError that quotes nothing of the token: when its own token request returns one — and caches nothing — and
// when any TokenProvider hands one to an admin request. .NET, node and ruby refuse it before sending (wave 4); node and
// ruby with their auth error, which is the one chosen here.
//
// ⚠️ The set of refused bytes is asked of the transport, not transcribed here (bearerRefusedByTransport) — the tests
// below fail if the SDK refuses a byte net/http would carry, or carries one it would refuse.

const (
	unsendableLoginMsg = "keycloak: auth: client-credentials login returned an access token an HTTP header cannot carry (it holds a control character such as CR, LF or NUL)"
	unsendableSendMsg  = "keycloak: auth: admin request not sent: an HTTP header cannot carry the access token (it holds a control character such as CR, LF or NUL)"
)

// bearerRow is the token of row b: one byte between two halves no header rule touches.
func bearerRow(b byte) string { return "tok-" + string([]byte{b}) + "-end" }

// bearerRefusedByTransport sends "Bearer "+bearerRow(b) for every byte b through the SDK's own transport to a local
// server and reports which ones net/http refused. A refusal must mean "not sent" and a send must mean "no error" —
// otherwise the oracle cannot tell the two apart and the test stops.
func bearerRefusedByTransport(t *testing.T) [256]bool {
	t.Helper()
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	tr := Config{ServerURL: srv.URL}.withDefaults().transport()
	defer tr.CloseIdleConnections()
	var refused [256]bool
	for b := 0; b < 256; b++ {
		req, err := http.NewRequest(http.MethodGet, srv.URL, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+bearerRow(byte(b)))
		before := hits.Load()
		resp, err := tr.RoundTrip(req)
		if err == nil {
			_ = resp.Body.Close()
		}
		if sent := hits.Load() > before; sent == (err != nil) {
			t.Fatalf("byte %#02x: transport error %v, server reached %v — the oracle cannot tell refused from sent", b, err, sent)
		}
		refused[b] = err != nil
	}
	// The oracle's own known answers: the item's three bytes are refused; a letter, HTAB, a space and a byte past ASCII
	// are carried.
	for _, b := range []byte{'\r', '\n', 0x00} {
		if !refused[b] {
			t.Fatalf("oracle: the transport carried byte %#02x — expected a refusal", b)
		}
	}
	for _, b := range []byte{'a', '\t', ' ', 0x80} {
		if refused[b] {
			t.Fatalf("oracle: the transport refused byte %#02x — expected it carried", b)
		}
	}
	return refused
}

// The rows the facade flows run: each class of byte the transport refuses (NUL, SOH, LF, CR, US, DEL) and each class it
// carries next to them (HTAB, space, a letter, '~'), so an SDK rule that is too narrow or too wide fails a flow. Every
// byte is compared with the transport once, by bearer_sendable_test.go. A flow per byte opened a client per row — the
// test servers accepted 359 connections per run, against 23 with these rows (counted with http.Server.ConnState).
var bearerFlowBytes = []byte{0x00, 0x01, '\t', '\n', '\r', 0x1f, ' ', 'a', '~', 0x7f}

// tokenGrant is one token response of a fake IdP.
type tokenGrant struct {
	token     string
	expiresIn int
}

// bearerIdP answers the token endpoint with its grants in order (the last one repeats) and every admin request with
// 204, recording the Authorization header each admin request carried.
type bearerIdP struct {
	srv                  *httptest.Server
	tokenHits, adminHits atomic.Int32
	mu                   sync.Mutex
	grants               []tokenGrant
	auths                []string
}

func newBearerIdP(t *testing.T, grants ...tokenGrant) *bearerIdP {
	t.Helper()
	p := &bearerIdP{grants: grants}
	mux := http.NewServeMux()
	mux.HandleFunc("/realms/r/protocol/openid-connect/token", func(w http.ResponseWriter, _ *http.Request) {
		n := int(p.tokenHits.Add(1)) - 1
		g := p.grants[min(n, len(p.grants)-1)]
		body, err := json.Marshal(map[string]any{"access_token": g.token, "token_type": "Bearer", "expires_in": g.expiresIn})
		if err != nil {
			t.Error(err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/admin/", func(w http.ResponseWriter, r *http.Request) {
		p.adminHits.Add(1)
		p.mu.Lock()
		p.auths = append(p.auths, r.Header.Get("Authorization"))
		p.mu.Unlock()
		if r.Method == http.MethodGet {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte("[]"))
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	p.srv = httptest.NewServer(mux)
	t.Cleanup(p.srv.Close)
	return p
}

func (p *bearerIdP) lastAuth() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.auths) == 0 {
		return ""
	}
	return p.auths[len(p.auths)-1]
}

// requireUnsendable checks a refusal: an *AuthError with exactly the SDK's words, no cause (nothing below failed — no
// request was made), and none of the token in any rendering.
func requireUnsendable(t *testing.T, label string, err error, want string) {
	t.Helper()
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Errorf("%s: want *AuthError %q, got %T: %v", label, want, err, err)
		return
	}
	if got := err.Error(); got != want {
		t.Errorf("%s: message %q, want %q", label, got, want)
	}
	if ae.Cause != nil {
		t.Errorf("%s: Cause = %T %v, want none — no request was made", label, ae.Cause, ae.Cause)
	}
	for _, verb := range []string{"%v", "%+v", "%#v", "%s"} {
		if out := fmt.Sprintf(verb, err); strings.Contains(out, "tok-") {
			t.Errorf("%s: %s quotes the token: %q", label, verb, out)
		}
	}
}

// The SDK's own token request — the case the item names. (JSON cannot carry a raw byte past ASCII: encoding/json decodes
// it to U+FFFD, which the transport carries. The injected path below covers those bytes.)
func TestAdminLoginRefusesAnAccessTokenAHeaderCannotCarry(t *testing.T) {
	refused := bearerRefusedByTransport(t)
	ctx := context.Background()
	for _, b := range bearerFlowBytes {
		tok := bearerRow(b)
		label := fmt.Sprintf("byte %#02x", b)
		p := newBearerIdP(t, tokenGrant{tok, 300})
		c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"})
		if err != nil {
			t.Fatal(err)
		}
		a, err := c.Admin(ctx)
		switch {
		case refused[b]:
			requireUnsendable(t, label+" · Client.Admin", err, unsendableLoginMsg)
		case err != nil:
			t.Errorf("%s: Client.Admin failed on a token the transport carries: %v", label, err)
		default:
			if err := a.Groups.Delete(ctx, "gid"); err != nil {
				t.Errorf("%s: Groups.Delete failed on a token the transport carries: %v", label, err)
			}
			if got, want := p.lastAuth(), "Bearer "+tok; got != want {
				t.Errorf("%s: the admin server received Authorization %q, want %q", label, got, want)
			}
		}
		if refused[b] && p.adminHits.Load() != 0 {
			t.Errorf("%s: %d admin requests reached the server with a token a header cannot carry", label, p.adminHits.Load())
		}
		_ = c.Close()
	}
}

// The unusable token is not cached: the refresh that returned it fails, and the next call asks the IdP again. The first
// grant expires inside the clock skew, so every call after Client.Admin refreshes.
func TestAdminDoesNotCacheAnAccessTokenAHeaderCannotCarry(t *testing.T) {
	ctx := context.Background()
	for _, bad := range []string{"tok-\r-cr", "tok-\n-lf", "tok-\r\n-crlf", "tok-\x00-nul"} {
		label := fmt.Sprintf("%q", bad)
		p := newBearerIdP(t, tokenGrant{"tok-first", 1}, tokenGrant{bad, 300}, tokenGrant{"tok-third", 300})
		c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"})
		if err != nil {
			t.Fatal(err)
		}
		a, err := c.Admin(ctx)
		if err != nil {
			t.Fatalf("%s: Client.Admin on a usable first token: %v", label, err)
		}
		requireUnsendable(t, label+" · the refresh that returned it", a.Groups.Delete(ctx, "gid"), unsendableLoginMsg)
		if n := p.adminHits.Load(); n != 0 {
			t.Errorf("%s: %d admin requests reached the server with the unusable token", label, n)
		}
		if err := a.Groups.Delete(ctx, "gid"); err != nil {
			t.Errorf("%s: the next call failed — the unusable token was cached: %v", label, err)
		}
		if got := p.lastAuth(); got != "Bearer tok-third" {
			t.Errorf("%s: the next call carried Authorization %q, want the next grant's token", label, got)
		}
		if n := p.tokenHits.Load(); n != 3 {
			t.Errorf("%s: %d token requests, want 3 (login · the refused refresh · the next refresh)", label, n)
		}
		_ = c.Close()
	}
}

// flipToken is a TokenProvider that returns first once and later after that.
type flipToken struct {
	first, later string
	n            atomic.Int32
}

func (f *flipToken) Token(context.Context) (string, error) {
	if f.n.Add(1) == 1 {
		return f.first, nil
	}
	return f.later, nil
}

// A consumer's TokenProvider hands the token to the same header, so the same refusal applies — at construction (the
// eager token) and on every facade call, including Realms.Update's hand-rolled request. Raw bytes past ASCII too.
func TestAdminRequestRefusesAnInjectedTokenAHeaderCannotCarry(t *testing.T) {
	refused := bearerRefusedByTransport(t)
	p := newBearerIdP(t, tokenGrant{"unused", 300})
	cfg := Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c"}
	for _, b := range append(append([]byte{}, bearerFlowBytes...), 0x80, 0xff) {
		label := fmt.Sprintf("byte %#02x", b)
		before := p.adminHits.Load()
		injectedAtConstruction(t, label, cfg, bearerRow(b), refused[b])
		injectedOnCalls(t, label, p, cfg, b, refused[b])
		if refused[b] && p.adminHits.Load() != before {
			t.Errorf("%s: %d admin requests reached the server with a token a header cannot carry", label, p.adminHits.Load()-before)
		}
	}
}

// injectedAtConstruction: the eager token is the injected one.
func injectedAtConstruction(t *testing.T, label string, cfg Config, tok string, refused bool) {
	t.Helper()
	a, err := NewAdminClient(context.Background(), cfg, staticToken(tok))
	switch {
	case refused:
		requireUnsendable(t, label+" · NewAdminClient", err, unsendableSendMsg)
	case err != nil:
		t.Errorf("%s: NewAdminClient failed on a token the transport carries: %v", label, err)
	default:
		_ = a.Close()
	}
}

// injectedOnCalls: the provider turns unusable after construction — every facade call refuses it.
func injectedOnCalls(t *testing.T, label string, p *bearerIdP, cfg Config, b byte, refused bool) {
	t.Helper()
	ctx := context.Background()
	tok := bearerRow(b)
	a, err := NewAdminClient(ctx, cfg, &flipToken{first: "tok-usable", later: tok})
	if err != nil {
		t.Fatalf("%s: NewAdminClient on a usable eager token: %v", label, err)
	}
	defer func() { _ = a.Close() }()
	err = a.Groups.Delete(ctx, "gid")
	switch {
	case refused:
		requireUnsendable(t, label+" · Groups.Delete", err, unsendableSendMsg)
	case err != nil:
		t.Errorf("%s: Groups.Delete failed on a token the transport carries: %v", label, err)
	case p.lastAuth() != "Bearer "+tok:
		t.Errorf("%s: the admin server received Authorization %q, want %q", label, p.lastAuth(), "Bearer "+tok)
	}
	if refused && (b == '\r' || b == '\n' || b == 0x00) {
		_, err := a.Users.Search(ctx, "", 0, 10)
		requireUnsendable(t, label+" · Users.Search", err, unsendableSendMsg)
		requireUnsendable(t, label+" · Realms.Update", a.Realms.Update(ctx, "r", gocloak.RealmRepresentation{}), unsendableSendMsg)
	}
}
