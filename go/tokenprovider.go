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
// Under NewClientCredentialsTokenProvider the ctx it receives carries the values of the caller that started the
// refresh but is never cancelled: one refresh serves every caller waiting for it, so no single caller's
// cancellation may stop it. Bound the source's own I/O — the SDK's admin source is bounded by Config.ReadTimeout.
type TokenSource func(ctx context.Context) (*TokenSet, error)

type clientCredentialsProvider struct {
	src     TokenSource
	skewSec int64
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
	return &clientCredentialsProvider{src: src, skewSec: skewSec}
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
	// "context canceled" 200ms in). Each caller now waits on its own ctx instead.
	detached := context.WithoutCancel(ctx)
	ch := p.group.DoChan("token", func() (any, error) {
		ts, err := p.src(detached)
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
