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

// jwksMaxBytes bounds a JWKS response body. 51200 is Nimbus's RemoteJWKSet.DEFAULT_HTTP_SIZE_LIMIT
// — the only value in this stack with an external justification, and the same bound the JVM SDKs
// lose when they call the two-arg DefaultResourceRetriever constructor.
const jwksMaxBytes = 51200

// Backoff for *failed* JWKS fetches — a different axis from minRefetch.
//
// minRefetch (30s) caps a flood of unresolved kids *after the cache is populated*. The two below
// cap the case where the cache is **empty and the fetch keeps failing**: nothing gated that path,
// and 20 lookups produced 20 outbound requests (measured 2026-09-04, identical in 7 languages).
//
// Do NOT reuse minRefetch here — one transient 503 would then mean "no token validates for 30
// seconds", which is worse than the defect. Start short, grow exponentially, cap.
//
// This never sleeps: inside the window the lookup fails immediately without touching the IdP
// (negative cache). Pacing retries is the caller's job, not a library's.
const (
	jwksFailureBackoffBase = 200 * time.Millisecond
	jwksFailureBackoffCap  = 5 * time.Second
)

type validatorOptions struct {
	jwksURI      string
	issuer       string
	audience     string
	allowedAlgs  []jose.SignatureAlgorithm
	clockSkewSec int64
	httpClient   *http.Client
	minRefetch   time.Duration // DoS 증폭 상한(강제 재조회 최소 간격)
	// now is a clock seam for tests. Nil means time.Now. It exists so the failure-backoff tests
	// can cross the window deterministically instead of sleeping — this repo already tracks
	// wall-clock-dependent tests as a defect class.
	now func() time.Time
}

// Validator performs hardened JWT verification: it does not trust library
// defaults. Algorithm pinning (header alg not trusted, "none" rejected), exact
// issuer match, audience membership (multi-valued aud accepted), exp/nbf with
// clock skew, and DoS-safe JWKS refetch (a forged signature never triggers a
// refetch; only an unresolved kid does, rate-limited).
type Validator struct {
	opts validatorOptions

	mu          sync.Mutex
	jwks        *jose.JSONWebKeySet
	forcedAt    time.Time          // last *forced* refetch (rotation); zero until the first one
	failures    int                // consecutive fetch failures; reset to 0 on success
	lastFailure time.Time          // when the last fetch failed; zero when healthy
	group       singleflight.Group // collapses concurrent JWKS fetches
}

// backoffRemaining reports how long the caller must wait before another fetch is allowed.
// Zero means "go ahead". Callers hold v.mu.
func (v *Validator) backoffRemaining(now time.Time) time.Duration {
	if v.lastFailure.IsZero() {
		return 0
	}
	if r := v.backoffDelay() - now.Sub(v.lastFailure); r > 0 {
		return r
	}
	return 0
}

// backoffDelay grows exponentially and is capped, with jitter in [0.5, 1.0). The jitter spreads
// instances that failed at the same instant so their recovery attempts do not knock the IdP over
// again (thundering herd). Callers hold v.mu.
//
// The jitter source is wall-clock nanoseconds rather than math/rand: this value spreads a herd, it
// is not a secret, and gosec rightly rejects math/rand (G404) in a security-sensitive package. The
// sister Rust implementation derives it the same way, for the same reason.
func (v *Validator) backoffDelay() time.Duration {
	shift := v.failures - 1
	if shift < 0 {
		shift = 0
	}
	if shift > 62 {
		shift = 62
	}
	d := jwksFailureBackoffBase << uint(shift)
	if d > jwksFailureBackoffCap || d <= 0 {
		d = jwksFailureBackoffCap
	}
	jitter := 0.5 + float64(time.Now().UnixNano()%1_000_000)/2_000_000.0
	return time.Duration(float64(d) * jitter)
}

func newValidator(opts validatorOptions) *Validator {
	if opts.httpClient == nil {
		opts.httpClient = http.DefaultClient
	}
	if opts.now == nil {
		opts.now = time.Now
	}
	if opts.minRefetch == 0 {
		opts.minRefetch = time.Duration(defaultJwksMinRefetchSecs) * time.Second
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
//
// The failure backoff is checked here rather than in fetch() so that it sits behind the
// singleflight barrier: callers coalesced into one in-flight fetch share its outcome, and only the
// leader consults the gate. Checking it in fetch() would be equivalent, but this keeps the "one
// decision per outbound request" property visible in one place.
func (v *Validator) singleFetch(ctx context.Context) error {
	_, err, _ := v.group.Do("fetch", func() (any, error) {
		// The backoff sits *before* the request and *after* the 30s forced-refetch gate. On a
		// cold cache the branch above is skipped entirely, so without this every lookup goes out
		// to the IdP — that is the original defect.
		v.mu.Lock()
		if r := v.backoffRemaining(v.opts.now()); r > 0 {
			failures := v.failures
			v.mu.Unlock()
			return nil, &TransportError{Msg: fmt.Sprintf(
				"JWKS fetch backing off after %d consecutive failures (retry in %.2fs)",
				failures, r.Seconds())}
		}
		v.mu.Unlock()

		err := v.fetch(ctx)
		v.mu.Lock()
		if err != nil {
			v.failures++
			v.lastFailure = v.opts.now()
		} else {
			v.failures = 0
			v.lastFailure = time.Time{}
		}
		v.mu.Unlock()
		return nil, err
	})
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
	// A non-2xx body is not a key set. jose.JSONWebKeySet unmarshals **any** JSON object lacking a
	// `keys` member into an empty set with no error, so an IdP/gateway error body ({"error":...})
	// used to replace the live trust store — after which every previously valid token was rejected
	// (measured: `no key for kid "k1"` right after a 503 refetch).
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &TransportError{Msg: fmt.Sprintf("JWKS fetch failed (HTTP %d)", resp.StatusCode)}
	}
	// Bound the body: an unbounded ReadAll on an attacker-influenced endpoint is a memory DoS.
	body, err := io.ReadAll(io.LimitReader(resp.Body, jwksMaxBytes+1))
	if err != nil {
		return err
	}
	if len(body) > jwksMaxBytes {
		return &TransportError{Msg: fmt.Sprintf("JWKS response exceeds %d bytes", jwksMaxBytes)}
	}
	var ks jose.JSONWebKeySet
	if err := json.Unmarshal(body, &ks); err != nil {
		return err
	}
	// An empty set is never a legitimate answer, and installing it would blind the validator.
	if len(ks.Keys) == 0 {
		return &TransportError{Msg: "JWKS response contains no keys"}
	}
	v.mu.Lock()
	v.jwks = &ks
	v.mu.Unlock()
	return nil
}
