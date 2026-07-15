package keycloak

import (
	"context"
	"sync"

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
		httpClient: cfg.httpClient(),
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
	// singleflight는 Do가 반환되면 키를 즉시 해제하므로, 첫 배치 완료 직후 c.admin 세팅 전에 도착한
	// 호출이 두 번째 배치를 시작해 admin 클라이언트를 중복 생성(로그인·커넥션풀 누출)할 수 있다.
	// 캐시를 플라이트 '안에서' 다시 확인(double-checked)해 중복 생성을 막고 c.admin도 여기서 세팅한다.
	v, err, _ := c.group.Do("admin", func() (any, error) {
		c.mu.Lock()
		existing := c.admin
		c.mu.Unlock()
		if existing != nil {
			return existing, nil
		}
		created, cerr := newAdminClient(ctx, c.cfg)
		if cerr != nil {
			return nil, cerr
		}
		c.mu.Lock()
		c.admin = created
		c.mu.Unlock()
		return created, nil
	})
	if err != nil {
		return nil, err
	}
	return v.(*AdminClient), nil
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
