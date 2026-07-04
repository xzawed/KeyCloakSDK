package keycloak

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"golang.org/x/sync/singleflight"
)

type validatorOptions struct {
	jwksURI      string
	issuer       string
	audience     string
	allowedAlgs  []jose.SignatureAlgorithm
	clockSkewSec int64
	httpClient   *http.Client
	minRefetch   time.Duration // DoS 증폭 상한(강제 재조회 최소 간격)
}

// Validator performs hardened JWT verification: it does not trust library
// defaults. Algorithm pinning (header alg not trusted, "none" rejected), exact
// issuer match, audience membership (multi-valued aud accepted), exp/nbf with
// clock skew, and DoS-safe JWKS refetch (a forged signature never triggers a
// refetch; only an unresolved kid does, rate-limited).
type Validator struct {
	opts validatorOptions

	mu       sync.Mutex
	jwks     *jose.JSONWebKeySet
	forcedAt time.Time          // last *forced* refetch (rotation); zero until the first one
	group    singleflight.Group // collapses concurrent JWKS fetches
}

func newValidator(opts validatorOptions) *Validator {
	if opts.httpClient == nil {
		opts.httpClient = http.DefaultClient
	}
	if opts.minRefetch == 0 {
		opts.minRefetch = 60 * time.Second
	}
	return &Validator{opts: opts}
}

func (v *Validator) Validate(ctx context.Context, token string) (*ValidatedToken, error) {
	// Algorithm pinning: only allowedAlgs accepted; unsigned/"none" rejected.
	parsed, err := jwt.ParseSigned(token, v.opts.allowedAlgs)
	if err != nil {
		return nil, &TokenValidationError{Msg: "parse: " + err.Error(), Cause: err}
	}
	if len(parsed.Headers) == 0 {
		return nil, &TokenValidationError{Msg: "missing JWS header"}
	}
	kid := parsed.Headers[0].KeyID

	key, err := v.resolveKey(ctx, kid)
	if err != nil {
		return nil, &TokenValidationError{Msg: "key: " + err.Error(), Cause: err}
	}

	var claims jwt.Claims
	all := map[string]any{}
	// Verifies the signature (a forgery fails here, without any refetch).
	if err := parsed.Claims(key, &claims, &all); err != nil {
		return nil, &TokenValidationError{Msg: "signature: " + err.Error(), Cause: err}
	}
	// go-jose only enforces expiry when exp is present; Keycloak always issues it,
	// so require it (defense-in-depth, matching Java/Python — a token without exp
	// must not be treated as non-expiring).
	if claims.Expiry == nil {
		return nil, &TokenValidationError{Msg: "claims: missing required exp claim"}
	}
	// Exact issuer + audience membership + exp/nbf/iat with clock skew.
	if err := claims.ValidateWithLeeway(jwt.Expected{
		Issuer:      v.opts.issuer,
		AnyAudience: jwt.Audience{v.opts.audience},
		Time:        time.Now(),
	}, time.Duration(v.opts.clockSkewSec)*time.Second); err != nil {
		return nil, &TokenValidationError{Msg: "claims: " + err.Error(), Cause: err}
	}

	vt := &ValidatedToken{
		Subject:  claims.Subject,
		Audience: []string(claims.Audience),
		Issuer:   claims.Issuer,
		Claims:   all,
	}
	if claims.Expiry != nil {
		vt.ExpiresAt = int64(*claims.Expiry)
	}
	if claims.IssuedAt != nil {
		vt.IssuedAt = int64(*claims.IssuedAt)
	}
	return vt, nil
}

// resolveKey returns the verification key for kid from the cached JWKS.
//
// DoS-safety: a forged signature carries a cached (valid) kid, so it resolves
// from cache and fails at signature verification — never a refetch. Only an
// unresolved kid (key rotation) triggers a refetch, and forced refetches are
// rate-limited by minRefetch so a token with a random kid cannot flood the IdP.
// The initial load is not "forced" and does not consume the rate limit — the
// first rotation refetch is always allowed (matching the Python/Java SDKs).
// Concurrent misses collapse to a single fetch via single-flight.
func (v *Validator) resolveKey(ctx context.Context, kid string) (any, error) {
	if k := v.lookup(kid); k != nil {
		return k, nil
	}

	v.mu.Lock()
	fresh := v.jwks == nil
	v.mu.Unlock()
	if fresh {
		// Initial (non-forced) load; if the kid is still absent it is genuinely unknown.
		if err := v.singleFetch(ctx); err != nil {
			return nil, err
		}
		if k := v.lookup(kid); k != nil {
			return k, nil
		}
		return nil, fmt.Errorf("no key for kid %q", kid)
	}

	// Cached JWKS lacks the kid → possible rotation → forced refetch, rate-limited.
	v.mu.Lock()
	if !v.forcedAt.IsZero() && time.Since(v.forcedAt) < v.opts.minRefetch {
		v.mu.Unlock()
		return nil, fmt.Errorf("no key for kid %q (refetch rate-limited)", kid)
	}
	v.forcedAt = time.Now()
	v.mu.Unlock()

	if err := v.singleFetch(ctx); err != nil {
		return nil, err
	}
	if k := v.lookup(kid); k != nil {
		return k, nil
	}
	return nil, fmt.Errorf("no key for kid %q", kid)
}

// singleFetch fetches the JWKS, collapsing concurrent callers into one request.
func (v *Validator) singleFetch(ctx context.Context) error {
	_, err, _ := v.group.Do("fetch", func() (any, error) { return nil, v.fetch(ctx) })
	return err
}

func (v *Validator) lookup(kid string) any {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.jwks == nil {
		return nil
	}
	if keys := v.jwks.Key(kid); len(keys) > 0 {
		return keys[0].Key
	}
	return nil
}

func (v *Validator) fetch(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.opts.jwksURI, nil)
	if err != nil {
		return err
	}
	resp, err := v.opts.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	var ks jose.JSONWebKeySet
	if err := json.Unmarshal(body, &ks); err != nil {
		return err
	}
	v.mu.Lock()
	v.jwks = &ks
	v.mu.Unlock()
	return nil
}
