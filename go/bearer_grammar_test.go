package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Nerzal/gocloak/v13"
	"github.com/go-jose/go-jose/v4/jwt"
)

// The bearer token grammar, identical in the nine SDKs (registry bearer-token-grammar-divergent, decision 2026-10-29).
//
// SP, HTAB, CR and LF are trimmed from both ends of the token, and nothing else is (not NBSP, U+3000, VT or FF). What is
// left must be a non-empty RFC 6750 b64token — `^[A-Za-z0-9\-._~+/]+=*$`, ASCII only, `=` only as trailing padding. Such
// a token goes out trimmed. Any other is never sent: the admin request fails before a byte reaches the server, with the
// *AuthError the admin lane gives a bearer it cannot send, quoting none of the token. The SDK's own grant and the public
// NewClientCredentialsTokenProvider refuse it the same way and do not cache it.
//
// Every row runs through every lane the SDK supplies the bearer on: (a) a facade call, (b) the hand-rolled request
// (Realms.Update's raw PUT) and the injected constructor's eager token, (c) the SDK's own grant and the public provider.

const (
	grammarSendMsg  = "keycloak: auth: admin request not sent: the access token is not an RFC 6750 bearer token (b64token)"
	grammarGrantMsg = "keycloak: auth: token source returned an access token that is not an RFC 6750 bearer token (b64token)"
	// The SDK's own login answers an empty access_token before the grammar is asked (admin.go — gocloak reads a non-2xx
	// it can unmarshal as a JWT without one).
	grammarNoTokenMsg = "keycloak: auth: client-credentials login returned no access token"
)

// grammarCase is one row: want is the token the Authorization header carries, "" when the request must not be sent.
type grammarCase struct{ id, in, want string }

// grammarCases is the table every SDK carries, plus Go's byte-string extra.
func grammarCases(t *testing.T) []grammarCase {
	t.Helper()
	jws := grammarJWS(t)
	return []grammarCase{
		{"plain", "abc.DEF-ghi_jkl~mno+pqr/stu", "abc.DEF-ghi_jkl~mno+pqr/stu"},
		{"pad", "abc==", "abc=="},
		{"jwt", jws, jws},
		{"lf", "abc\n", "abc"},
		{"crlf", "abc\r\n", "abc"},
		{"lead-tab", " \tabc\t ", "abc"},
		{"inner-sp", "a bc", ""},
		{"inner-tab", "a\tbc", ""},
		{"inner-crlf", "a\r\nX-Evil: 1", ""},
		{"mid-pad", "a=bc", ""},
		{"empty", "", ""},
		{"blank", " \t\r\n", ""},
		{"latin1", "abcé", ""},
		{"above-ff", "abcĀ", ""},
		{"c1", "abc\u0085", ""},
		{"nul", "abc\x00", ""},
		{"del", "abc\x7f", ""},
		{"nbsp", "abc ", ""},
		{"ideographic", "　abc", ""},
		{"vt", "abc\v", ""},
		{"invalid-utf8", "abc\xff", ""},
	}
}

// grammarJWS is a real three-segment JWS: an RS256 signature over a claims set, from a key made for the test.
func grammarJWS(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return (&jwtFixture{}).sign(t, key, "k1", claims(jwt.Audience{"c"}, testISS, time.Now().Add(time.Hour)))
}

// grammarAuthError checks a refusal: the lane's *AuthError with exactly its words, no cause (nothing below failed), and
// none of the token in any rendering.
func grammarAuthError(t *testing.T, err error, want string) {
	t.Helper()
	var ae *AuthError
	if !errors.As(err, &ae) {
		t.Fatalf("got %T %v — want *AuthError %q", err, err, want)
	}
	if got := err.Error(); got != want {
		t.Errorf("message %q, want %q", got, want)
	}
	if ae.Cause != nil {
		t.Errorf("Cause = %T %v, want none — no request was made", ae.Cause, ae.Cause)
	}
	for _, verb := range []string{"%v", "%+v", "%#v", "%s", "%q"} {
		out := fmt.Sprintf(verb, err)
		for _, part := range []string{"bc", "X-Evil"} {
			if strings.Contains(out, part) {
				t.Errorf("%s quotes the token (%q): %s", verb, part, out)
			}
		}
	}
}

// grammarRefused checks a refused admin call: the refusal, and no request on the path since before.
func grammarRefused(t *testing.T, err error, want string, p *bearerIdP, before int32) {
	t.Helper()
	requests := p.adminHits.Load() - before
	if err == nil {
		t.Fatalf("sent — %d admin requests, the last carrying Authorization %q; want it refused with %q",
			requests, p.lastAuth(), want)
	}
	grammarAuthError(t, err, want)
	if requests != 0 {
		t.Errorf("%d admin requests reached the server", requests)
	}
}

// grammarSent checks a sent row: one request, carrying exactly "Bearer " and the trimmed token.
func grammarSent(t *testing.T, err error, p *bearerIdP, want string, requests int32) {
	t.Helper()
	if err != nil {
		t.Fatalf("refused (%v) — want it sent as %q", err, want)
	}
	if requests != 1 {
		t.Errorf("%d admin requests, want 1", requests)
	}
	if got := p.lastAuth(); got != "Bearer "+want {
		t.Errorf("the server received Authorization %q, want %q", got, "Bearer "+want)
	}
}

// grammarInjected runs one admin call on a client whose injected provider hands out a usable token for the eager
// authentication and the row's token afterwards.
func grammarInjected(t *testing.T, call func(context.Context, *AdminClient) error) {
	t.Helper()
	ctx := context.Background()
	p := newBearerIdP(t, tokenGrant{"unused", 300})
	cfg := Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c"}
	for _, c := range grammarCases(t) {
		t.Run(c.id, func(t *testing.T) {
			a, err := NewAdminClient(ctx, cfg, &flipToken{first: "tok-usable", later: c.in})
			if err != nil {
				t.Fatalf("NewAdminClient on a usable eager token: %v", err)
			}
			defer func() { _ = a.Close() }()
			before := p.adminHits.Load()
			err = call(ctx, a)
			if c.want == "" {
				grammarRefused(t, err, grammarSendMsg, p, before)
				return
			}
			grammarSent(t, err, p, c.want, p.adminHits.Load()-before)
		})
	}
}

// (a) A facade call — every one takes its bearer from AdminClient.token, as this one does.
func TestBearerGrammarOnAFacadeCall(t *testing.T) {
	grammarInjected(t, func(ctx context.Context, a *AdminClient) error { return a.Groups.Delete(ctx, "gid") })
}

// (b) Realms.Update builds its request by hand (gocloak's UpdateRealm cannot rename) — the other path a bearer takes.
func TestBearerGrammarOnTheRawPut(t *testing.T) {
	grammarInjected(t, func(ctx context.Context, a *AdminClient) error {
		return a.Realms.Update(ctx, "r", gocloak.RealmRepresentation{})
	})
}

// (b) The injected constructor asks its provider for the eager token and refuses it there; a token it accepts is the one
// every later call carries (a GET here, where the facade call above is a DELETE).
func TestBearerGrammarAtInjectedConstruction(t *testing.T) {
	ctx := context.Background()
	p := newBearerIdP(t, tokenGrant{"unused", 300})
	cfg := Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c"}
	for _, c := range grammarCases(t) {
		t.Run(c.id, func(t *testing.T) {
			before := p.adminHits.Load()
			a, err := NewAdminClient(ctx, cfg, staticToken(c.in))
			if c.want == "" {
				if err == nil {
					_ = a.Close()
					t.Fatalf("NewAdminClient accepted %q — want it refused with %q", c.in, grammarSendMsg)
				}
				grammarRefused(t, err, grammarSendMsg, p, before)
				return
			}
			if err != nil {
				t.Fatalf("NewAdminClient refused (%v) — want it to accept %q", err, c.in)
			}
			defer func() { _ = a.Close() }()
			_, err = a.Users.Search(ctx, "", 0, 10)
			grammarSent(t, err, p, c.want, p.adminHits.Load()-before)
		})
	}
}

// (c) The SDK's own grant: the token endpoint returns the row's token on a refresh. A refused token is not cached — the
// next call asks the IdP again; a sent one is cached as it was sent — the next call asks the IdP nothing. The first grant
// expires inside the clock skew, so the call after Client.Admin refreshes. (JSON carries no raw byte past ASCII:
// encoding/json turns 0xff into U+FFFD, which is refused just the same.)
func TestBearerGrammarOnTheSDKGrant(t *testing.T) {
	ctx := context.Background()
	for _, c := range grammarCases(t) {
		t.Run(c.id, func(t *testing.T) {
			p := newBearerIdP(t, tokenGrant{"tok-first", 1}, tokenGrant{c.in, 300}, tokenGrant{"tok-third", 300})
			cl, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = cl.Close() }()
			a, err := cl.Admin(ctx)
			if err != nil {
				t.Fatalf("Client.Admin on a usable first token: %v", err)
			}
			err = a.Groups.Delete(ctx, "gid")
			if c.want == "" {
				want := grammarGrantMsg
				if c.in == "" {
					want = grammarNoTokenMsg
				}
				grammarRefused(t, err, want, p, 0)
				if err := a.Groups.Delete(ctx, "gid"); err != nil {
					t.Errorf("the next call failed — the refused token was cached: %v", err)
				}
				if got := p.lastAuth(); got != "Bearer tok-third" {
					t.Errorf("the next call carried Authorization %q, want the next grant's token", got)
				}
				if n := p.tokenHits.Load(); n != 3 {
					t.Errorf("%d token requests, want 3 (login · the refused refresh · the next refresh)", n)
				}
				return
			}
			grammarSent(t, err, p, c.want, p.adminHits.Load())
			if err := a.Groups.Delete(ctx, "gid"); err != nil {
				t.Errorf("the next call failed: %v", err)
			}
			if got := p.lastAuth(); got != "Bearer "+c.want {
				t.Errorf("the next call carried Authorization %q, want the cached %q", got, "Bearer "+c.want)
			}
			if n := p.tokenHits.Load(); n != 2 {
				t.Errorf("%d token requests, want 2 (login · the refresh whose token is cached)", n)
			}
		})
	}
}

// (c) The public provider around a consumer's TokenSource: a refused token is not cached — every call asks the source
// again and fails the same way; an accepted one is cached trimmed, and handed out as it will be sent.
func TestBearerGrammarOnThePublicProvider(t *testing.T) {
	ctx := context.Background()
	for _, c := range grammarCases(t) {
		t.Run(c.id, func(t *testing.T) {
			var calls atomic.Int32
			p := NewClientCredentialsTokenProvider(func(context.Context) (*TokenSet, error) {
				calls.Add(1)
				return &TokenSet{AccessToken: c.in, ExpiresIn: 300}, nil
			}, 30)
			for i := int32(1); i <= 2; i++ {
				tok, err := p.Token(ctx)
				if c.want == "" {
					if err == nil {
						t.Fatalf("call %d: Token() = %q, nil — want it refused with %q", i, tok, grammarGrantMsg)
					}
					grammarAuthError(t, err, grammarGrantMsg)
					if tok != "" {
						t.Errorf("call %d handed out %q with the error", i, tok)
					}
					if n := calls.Load(); n != i {
						t.Errorf("call %d: the source was asked %d times, want %d — the refused token was cached", i, n, i)
					}
					continue
				}
				if err != nil || tok != c.want {
					t.Fatalf("call %d: Token() = %q, %v — want %q", i, tok, err, c.want)
				}
				if n := calls.Load(); n != 1 {
					t.Errorf("call %d: the source was asked %d times, want 1 (cached)", i, n)
				}
			}
		})
	}
}
