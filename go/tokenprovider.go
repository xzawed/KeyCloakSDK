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
type TokenSource func(ctx context.Context) (*TokenSet, error)

type clientCredentialsProvider struct {
	src     TokenSource
	skewSec int64
	group   singleflight.Group

	mu       sync.Mutex
	token    string
	expireAt int64 // epoch sec, skew-adjusted
}

// NewClientCredentialsTokenProvider caches a token and refreshes it before
// expiry, collapsing concurrent refreshes via single-flight.
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

	v, err, _ := p.group.Do("token", func() (any, error) {
		ts, err := p.src(ctx)
		if err != nil {
			return nil, err
		}
		p.mu.Lock()
		p.token = ts.AccessToken
		p.expireAt = time.Now().Unix() + max64(0, ts.ExpiresIn-p.skewSec)
		p.mu.Unlock()
		return ts.AccessToken, nil
	})
	if err != nil {
		return "", err
	}
	return v.(string), nil
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
