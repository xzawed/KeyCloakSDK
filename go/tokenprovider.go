package keycloak

import (
	"context"
	"regexp"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

// TokenProvider supplies access tokens to the admin facade — the only glue
// between auth and admin. Consumers may inject a custom implementation.
//
// The admin facade trims SP, HTAB, CR and LF from both ends of the token it gets and sends the rest only when it is an
// RFC 6750 bearer token (b64token); any other token fails the admin call with *AuthError before a request is made.
type TokenProvider interface {
	Token(ctx context.Context) (string, error)
}

// TokenSource obtains a fresh token set (e.g. via client-credentials).
//
// Under NewClientCredentialsTokenProvider one refresh serves every caller waiting for it, so no single caller may
// stop it: the ctx it receives carries the values of the caller that started the refresh but none of any caller's
// cancellation or deadline. Its one deadline is 60 seconds after the refresh starts, when it is done with
// context.DeadlineExceeded; the callers still waiting get what the source then returns, and once it has returned
// the next Token call starts a new refresh. A source that ignores its ctx holds the refresh until it returns. The
// ctx is cancelled once the source returns. Bound the source's own I/O well inside 60 seconds; the SDK's admin
// source is bounded by Config.ReadTimeout.
type TokenSource func(ctx context.Context) (*TokenSet, error)

// tokenRefreshTimeout is the deadline of one shared refresh. The refresh runs detached from every caller's
// cancellation (see Token), so a TokenSource with no timeout of its own — one that ends only through its ctx, such
// as clientcredentials.Config.Token(ctx) on the default http.Client — never ended once its IdP stalled: every later
// Token call joined that refresh, none started a new one, and the admin lane stayed stuck until the process
// restarted (measured). A refresh through the SDK's own source is already bounded by its HTTP client —
// Config.ReadTimeout (default 30 s) for the whole request, Config.ConnectTimeout (default 10 s) for the dial
// inside it — so at the defaults 60 s only stops a consumer source that has no timeout of its own (a
// Config.ReadTimeout above 60 s is cut to 60 s here).
const tokenRefreshTimeout = 60 * time.Second

type clientCredentialsProvider struct {
	src     TokenSource
	skewSec int64
	timeout time.Duration // the deadline of one shared refresh: tokenRefreshTimeout (tests shorten it)
	group   singleflight.Group

	mu       sync.Mutex
	token    string
	expireAt int64 // epoch sec, skew-adjusted
}

// String keeps the cached access token out of fmt — NewClientCredentialsTokenProvider hands this type
// out as a TokenProvider, and printing that interface dumped the token field under every verb
// (measured 2026-09-26). It does not read the token, so it needs no lock. Pointer receiver: the type
// holds a mutex.
func (p *clientCredentialsProvider) String() string {
	return "ClientCredentialsTokenProvider{token:***}"
}

// GoString is the `%#v` hook — `%#v` does not use Stringer.
func (p *clientCredentialsProvider) GoString() string { return p.String() }

// NewClientCredentialsTokenProvider caches a token and refreshes it before
// expiry, collapsing concurrent refreshes via single-flight. A caller whose ctx
// ends while it waits returns at once — with the refresh's result if that is already there, else with the
// context's error — and the refresh goes on for the others (see TokenSource).
//
// It caches what the admin facade would send (see TokenProvider): the source's token with SP, HTAB, CR and LF trimmed
// from its ends. A token that is not then an RFC 6750 bearer token is not cached — the refresh fails with *AuthError and
// the next call asks the source again.
func NewClientCredentialsTokenProvider(src TokenSource, skewSec int64) TokenProvider {
	return &clientCredentialsProvider{src: src, skewSec: skewSec, timeout: tokenRefreshTimeout}
}

func (p *clientCredentialsProvider) Token(ctx context.Context) (string, error) {
	p.mu.Lock()
	if p.token != "" && time.Now().Unix() < p.expireAt {
		tok := p.token
		p.mu.Unlock()
		return tok, nil
	}
	p.mu.Unlock()
	if err := ctx.Err(); err != nil { // a caller that has already given up starts nothing
		return "", abandoned(err)
	}

	// The refresh runs detached from every caller's cancellation. It used to run on the first caller's ctx, so
	// that caller giving up failed everyone coalesced into the same refresh (measured: a live waiter got
	// "context canceled" 200ms in). Each caller now waits on its own ctx instead, and the refresh carries a
	// deadline of its own (tokenRefreshTimeout). Both are made inside the flight, from the values of the caller
	// that starts it, so a caller that joins a refresh in flight allocates no timer.
	ch := p.group.DoChan("token", func() (any, error) {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), p.timeout)
		defer cancel()
		ts, err := p.src(rctx)
		if err != nil {
			return nil, err
		}
		// Asked before caching, so an unusable token is not served until it expires: every admin call would refuse it.
		tok, ok := sendableBearer(ts.AccessToken)
		if !ok {
			return nil, &AuthError{Msg: "token source returned an access token that is not an RFC 6750 bearer token (b64token)"}
		}
		p.mu.Lock()
		p.token = tok
		p.expireAt = time.Now().Unix() + max64(0, ts.ExpiresIn-p.skewSec)
		p.mu.Unlock()
		return tok, nil
	})
	r, err := awaitShared(ctx, ch)
	if err != nil {
		return "", abandoned(err)
	}
	if r.Err != nil {
		return "", r.Err
	}
	return r.Val.(string), nil
}

// b64token is RFC 6750's bearer token: ALPHA, DIGIT, "-", ".", "_", "~", "+" and "/", then "=" padding only at the end.
// ASCII only. In Go's syntax "$" is the end of the text, not of a line.
var b64token = regexp.MustCompile(`^[A-Za-z0-9._~+/-]+=*$`)

// sendableBearer is the bearer token grammar of all nine SDKs (registry bearer-token-grammar-divergent): SP, HTAB, CR
// and LF are trimmed from both ends — nothing else is, not NBSP, U+3000, VT or FF — and what is left must be a non-empty
// b64token. It returns the value "Bearer " is followed by, and whether there is one. AdminClient.token asks it before any
// admin request is built, and clientCredentialsProvider.Token before it caches a token.
//
// It is narrower than the transport's rule (httpguts.ValidHeaderFieldValue), never wider. Before it, the admin lane sent
// HTAB, SP and bytes past ASCII as they were, net/http trimmed a trailing SP or HTAB, and an empty token went out with no
// Authorization header at all — resty drops a blank one (IsStringEmpty) — measured by bearer_grammar_test.go's rows.
// bearer_sendable_test.go keeps every accepted byte inside the transport's rule — a token net/http refuses used to come
// back from every admin call as an opaque *TransportError (admin_bearer_header_test.go).
func sendableBearer(token string) (string, bool) {
	if t := strings.Trim(token, " \t\r\n"); b64token.MatchString(t) {
		return t, true
	}
	return "", false
}

// awaitShared waits for a shared flight's result on ch, or for ctx to end. When both are ready Go's select picks
// either at random, so the ctx branch looks at ch once more without blocking: a result that is already there wins —
// the caller gets it as it would from the cache, which never looks at ctx — and ctx's error comes back only while
// there is none. The flight goes on for the others either way. Every wait on a shared flight goes through here
// (Client.Admin, clientCredentialsProvider.Token, jwksFlight.wait); the *WinsTheTie tests force the tie at each.
func awaitShared[T any](ctx context.Context, ch <-chan T) (T, error) {
	select {
	case r := <-ch:
		return r, nil
	case <-ctx.Done():
		select {
		case r := <-ch:
			return r, nil
		default:
			var zero T
			return zero, ctx.Err()
		}
	}
}

// abandoned is what a caller gets when its ctx ends while it waits on a shared token fetch or admin client
// creation that has not finished (awaitShared): the admin lane's transport error for a request that did not complete,
// wrapping the context's error so that errors.Is(err, context.Canceled) and errors.Is(err, context.DeadlineExceeded) hold.
func abandoned(ctxErr error) error {
	return &TransportError{Msg: "could not get token: " + ctxErr.Error(), Cause: ctxErr}
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
