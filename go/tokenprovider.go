package keycloak

import (
	"context"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

// TokenProvider supplies access tokens to the admin facade — the only glue
// between auth and admin. Consumers may inject a custom implementation.
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
// ends while it waits returns at once; the refresh goes on for the others (see TokenSource).
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
		p.mu.Lock()
		p.token = ts.AccessToken
		p.expireAt = time.Now().Unix() + max64(0, ts.ExpiresIn-p.skewSec)
		p.mu.Unlock()
		return ts.AccessToken, nil
	})
	select {
	case r := <-ch:
		if r.Err != nil {
			return "", r.Err
		}
		return r.Val.(string), nil
	case <-ctx.Done():
		return "", abandoned(ctx.Err())
	}
}

// abandoned is what a caller gets when its ctx ends while it waits on a shared token fetch or admin client
// creation: the admin lane's transport error for a request that did not complete, wrapping the context's
// error so that errors.Is(err, context.Canceled) and errors.Is(err, context.DeadlineExceeded) hold.
func abandoned(ctxErr error) error {
	return &TransportError{Msg: "could not get token: " + ctxErr.Error(), Cause: ctxErr}
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
