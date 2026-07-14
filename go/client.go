package keycloak

import (
	"context"
	"net/http"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

// Client is the unified SDK entry point. New assembles Auth immediately; Admin
// is created lazily on first Admin call (it requires clientSecret). Close
// releases created sub-resources.
type Client struct {
	cfg  Config
	Auth *AuthClient

	mu    sync.Mutex
	admin *AdminClient
	group singleflight.Group
}

// New validates the config and assembles the auth facade. Admin is deferred, so
// a public/PKCE client without a secret can still use Auth.
func New(cfg Config) (*Client, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	cfg = cfg.withDefaults()
	ep := oidcEndpoints(cfg)
	v := newValidator(validatorOptions{
		jwksURI: ep.jwks, issuer: ep.issuer, audience: cfg.ClientID,
		allowedAlgs: cfg.signatureAlgorithms(), clockSkewSec: cfg.ClockSkew,
		// Bound the JWKS fetch by the configured read timeout (a hung IdP must not
		// block Validate forever — the same invariant as the admin/auth clients).
		httpClient: &http.Client{Timeout: time.Duration(cfg.ReadTimeout) * time.Millisecond},
	})
	return &Client{cfg: cfg, Auth: newAuthClient(cfg, v)}, nil
}

// Admin returns the admin facade, creating and authenticating it on first call
// and caching it thereafter. Concurrent first calls collapse via single-flight;
// a failed creation is not cached (retryable). Requires clientSecret.
func (c *Client) Admin(ctx context.Context) (*AdminClient, error) {
	c.mu.Lock()
	a := c.admin
	c.mu.Unlock()
	if a != nil {
		return a, nil
	}
	v, err, _ := c.group.Do("admin", func() (any, error) { return newAdminClient(ctx, c.cfg) })
	if err != nil {
		return nil, err
	}
	a = v.(*AdminClient)
	c.mu.Lock()
	c.admin = a
	c.mu.Unlock()
	return a, nil
}

// Close releases created sub-resources — admin only if it was created, auth always.
func (c *Client) Close() error {
	c.mu.Lock()
	a := c.admin
	c.mu.Unlock()
	if a != nil {
		_ = a.Close()
	}
	return c.Auth.Close()
}
