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
)

// jwksMaxBytes bounds a JWKS response body. 51200 is Nimbus's RemoteJWKSet.DEFAULT_HTTP_SIZE_LIMIT
// — the only value in this stack with an external justification, and the same bound the JVM SDKs
// lose when they call the two-arg DefaultResourceRetriever constructor.
const jwksMaxBytes = 51200

// jwtMaxBytes bounds the length of a token handed to Validate — an access token, or the id_token ExchangeCode checks —
// and is checked before anything else touches it: before go-jose splits or decodes it and before the JWKS is loaded.
// jwt.ParseSigned decodes the protected header (unknown members into interface{}) up to three times before any key
// is looked up, so a forged token made the validator allocate about 54 bytes per input byte (measured), and
// net/http accepts a 1 MiB request header by default. 256,000 is Microsoft.IdentityModel's
// DefaultMaximumTokenSizeInBytes and about 3.9 times the longest bearer Keycloak 26.6 accepts with default
// settings (65,459 bytes), so no token that server accepts is refused. ⚠️ Do not borrow tokenResponseMaxBytes:
// that cap bounds a body read, and this one bounds a decode that costs tens of bytes per input byte.
//
// ⚠️ A plain decimal literal on purpose — the nine SDKs share this value and a cross-language guard reads it.
const jwtMaxBytes = 256000

// jwksMaxAgeSeconds is how long a key set obtained by a successful JWKS fetch is used, counted from the moment that
// fetch completed on the gate clock (opts.now — time.Now, monotonic). Once that age is reached the cache is treated
// exactly like a cold one: the next lookup misses, and fetchFor starts the cold load — the same flight, the same
// failure backoff, no forced-refetch window. If that fetch fails the validation fails: the expired keys are never used
// again, not even during an IdP outage. A successful forced refetch replaces the set and restarts the age too.
//
// ⚠️ A plain decimal literal on purpose — the nine SDKs share this value and a cross-language guard reads it.
const jwksMaxAgeSeconds = 300

// Backoff for *failed* JWKS fetches — a different axis from minRefetch.
//
// minRefetch (30s) caps a flood of unresolved kids *after the cache is populated*. The two below
// cap the case where the cache is **empty (or expired) and the fetch keeps failing**: nothing gated that path,
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
	// now is a clock seam for tests. Nil means time.Now. It exists so the failure-backoff and
	// forced-refetch (minRefetch) tests can cross their windows deterministically instead of
	// sleeping — this repo already tracks wall-clock-dependent tests as a defect class.
	now func() time.Time
	// jitter is the failure backoff's jitter source, a factor in [0.5, 1.0) — a seam for tests. Nil means clockJitter.
	jitter func() float64
}

// Validator performs hardened JWT verification: it does not trust library
// defaults. Algorithm pinning (header alg not trusted, "none" rejected), exact
// issuer match, audience membership (multi-valued aud accepted), exp/nbf with
// clock skew, and DoS-safe JWKS refetch (a fetched key set is used for 300
// seconds; within them a forged signature never triggers a refetch, only an
// unresolved kid does, rate-limited).
type Validator struct {
	opts validatorOptions
	*jwksState
}

// jwksState is the key store: the cached JWKS and every gate on refetching it. It sits behind a
// pointer so that withAudience's siblings share it — one cache, one forced-refetch window, one
// failure backoff and one fetch in flight per Client, whichever audience a caller checks.
type jwksState struct {
	mu          sync.Mutex
	jwks        *jose.JSONWebKeySet
	loadedAt    time.Time     // when the fetch that obtained jwks completed; jwks is used until jwksMaxAgeSeconds after it
	forcedAt    time.Time     // when the last *forced* refetch (rotation) started; zero until the first one
	failures    int           // consecutive fetch failures; reset to 0 on success
	lastFailure time.Time     // when the last fetch failed; zero when healthy
	backoff     time.Duration // the window that failure opened — its jitter drawn once, when it was recorded
	flight      *jwksFlight   // the fetch in progress, which concurrent misses wait on; nil when none is
}

// jwksFlight is one JWKS fetch in progress. No caller owns it: it runs detached from every caller's
// cancellation, bounded only by the JWKS HTTP client's timeout (Config.ReadTimeout), and its result fills the
// cache whoever is still waiting. A caller that gives up therefore returns at once without stopping the fetch,
// without failing the others waiting on it, and without counting as an IdP failure — and a forced refetch
// whose window is already stamped is never wasted. Measured before: a validation cancelled mid-flight spent the
// 30s window without updating the cache, so the rotated key was refused for the rest of it.
type jwksFlight struct {
	done chan struct{} // closed once the fetch has finished and its outcome is recorded
	err  error         // the fetch's outcome; written before done is closed
}

// wait blocks until the fetch has finished or ctx is done. A caller that stops waiting gets its own
// context's error — unless the fetch has finished by then, whose outcome wins (awaitShared); the fetch carries on
// for the others and for the cache.
func (f *jwksFlight) wait(ctx context.Context) error {
	if _, err := awaitShared(ctx, f.done); err != nil {
		return err
	}
	return f.err
}

// backoffRemaining reports how long the caller must wait before another fetch is allowed.
// Zero means "go ahead". Callers hold v.mu.
func (v *Validator) backoffRemaining(now time.Time) time.Duration {
	if v.lastFailure.IsZero() {
		return 0
	}
	if r := v.backoff - now.Sub(v.lastFailure); r > 0 {
		return r
	}
	return 0
}

// backoffDelay grows exponentially and is capped, with jitter in [0.5, 1.0). The jitter spreads
// instances that failed at the same instant so their recovery attempts do not knock the IdP over
// again (thundering herd). Callers hold v.mu.
//
// runFetch calls it once, when it records a failure, and keeps the window in v.backoff. Drawn on every check instead,
// the window's end moved between checks, so one failure refused a lookup and let the next one at the same instant
// through to the IdP (measured — TestJWKSBackoffJitterIsDrawnOnceWhenTheFailureIsRecorded).
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
	return time.Duration(float64(d) * v.opts.jitter())
}

// clockJitter is the default jitter source: a factor in [0.5, 1.0) taken from wall-clock nanoseconds (see backoffDelay).
func clockJitter() float64 {
	return 0.5 + float64(time.Now().UnixNano()%1_000_000)/2_000_000.0
}

func newValidator(opts validatorOptions) *Validator {
	if opts.httpClient == nil {
		opts.httpClient = http.DefaultClient
	}
	if opts.now == nil {
		opts.now = time.Now
	}
	if opts.jitter == nil {
		opts.jitter = clockJitter
	}
	if opts.minRefetch == 0 {
		opts.minRefetch = time.Duration(defaultJwksMinRefetchSecs) * time.Second
	}
	return &Validator{opts: opts, jwksState: &jwksState{}}
}

// withAudience returns a Validator that requires audience in aud and shares this one's key store.
// Only the audience differs: issuer, algorithm pin, skew and the refetch gates are this Validator's.
// ExchangeCode uses it for the id_token, whose aud is the client id (OIDC Core §2, §3.1.3.7) while
// Config.ExpectedAudience names the access-token audience.
func (v *Validator) withAudience(audience string) *Validator {
	o := v.opts
	o.audience = audience
	return &Validator{opts: o, jwksState: v.jwksState}
}

func (v *Validator) Validate(ctx context.Context, token string) (*ValidatedToken, error) {
	// Length first (jwtMaxBytes). len counts bytes; a genuine JWT is ASCII, so bytes, code points and UTF-16 units
	// agree on it.
	if len(token) > jwtMaxBytes {
		return nil, &TokenValidationError{Msg: fmt.Sprintf("token exceeds %d bytes", jwtMaxBytes)}
	}
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
// A cached set is used for jwksMaxAgeSeconds after the fetch that obtained it; from then on the lookup misses as on
// a cold cache, whatever the kid, and the cold-load fetch replaces the set (or the validation fails).
//
// DoS-safety: a forged signature carries a cached (valid) kid, so it resolves
// from cache and fails at signature verification — never a refetch. Only an
// unresolved kid (key rotation) triggers a refetch, and forced refetches are
// rate-limited by minRefetch so a token with a random kid cannot flood the IdP.
// The initial load is not "forced" and does not consume the rate limit — the
// first rotation refetch is always allowed (matching the Python/Java SDKs).
// Concurrent misses wait on the one fetch in flight (jwksFlight).
func (v *Validator) resolveKey(ctx context.Context, kid string) (any, error) {
	if k := v.lookup(kid); k != nil {
		return k, nil
	}
	// A caller that has already given up starts nothing: no stamp on the window, no request to the IdP.
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	f, err := v.fetchFor(ctx, kid)
	if err != nil {
		return nil, err
	}
	if f != nil { // nil: the kid was cached by the time fetchFor looked again — nothing to wait for
		if err := f.wait(ctx); err != nil {
			return nil, err
		}
	}
	if k := v.lookup(kid); k != nil {
		return k, nil
	}
	return nil, fmt.Errorf("no key for kid %q", kid)
}

// fetchFor decides, under one lock, which fetch serves a cache miss for kid. A fetch in flight is joined — its
// result may carry the kid, and joining costs the IdP nothing, whichever window started it. Otherwise a cold
// cache — or one past jwksMaxAgeSeconds, which is treated exactly as cold — starts the initial load, which does not
// stamp the window, and a warm one starts a forced refetch unless the window is still open, in which case the miss
// is refused without touching the IdP.
//
// The window is stamped only by the forced refetch that starts in it. A miss that joins a fetch, or that the
// failure backoff refuses, leaves the window as it was: stamping first spent a window on no request of its own,
// and the rotated key was then refused for the rest of it (measured — a backoff refusal right after a refetch
// that failed at the window's end, and a join of the previous window's fetch still in flight when that window
// ended; the default Config.ReadTimeout equals the default window, so a timed-out refetch fails right there).
//
// It first looks the kid up again, under the lock that decides: the caller's own lookup ran outside it, and a
// fetch that finished in between may have brought the kid. Deciding on that stale miss refused a key the window's
// own fetch had just cached, and on a cold cache started a second, forced fetch that stamped the window — so the
// first rotation after the load was refused (measured; the initial load must not use the window). A nil flight
// with a nil error means the kid is cached now.
func (v *Validator) fetchFor(ctx context.Context, kid string) (*jwksFlight, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	// One reading of the clock seam serves the age, the window, the backoff and the stamp. With the default (time.Now)
	// it carries a monotonic reading, so Sub is monotonic exactly as time.Since was.
	now := v.opts.now()
	fresh := v.freshLocked(now)
	if fresh && len(v.jwks.Key(kid)) > 0 {
		return nil, nil
	}
	if v.flight != nil {
		return v.flight, nil
	}
	if !fresh {
		return v.startFetchLocked(ctx, now)
	}
	// Cached JWKS lacks the kid → possible rotation → forced refetch, rate-limited.
	if !v.forcedAt.IsZero() && now.Sub(v.forcedAt) < v.opts.minRefetch {
		return nil, fmt.Errorf("no key for kid %q (refetch rate-limited)", kid)
	}
	f, err := v.startFetchLocked(ctx, now)
	if err == nil {
		v.forcedAt = now
	}
	return f, err
}

// startFetchLocked starts a fetch unless the failure backoff forbids it. Callers hold v.mu and have found no
// fetch in flight.
//
// The backoff sits *before* the request and *after* the 30s forced-refetch gate. On a cold (or expired) cache that
// gate is skipped entirely, so without this every lookup goes out to the IdP — that is the original defect.
func (v *Validator) startFetchLocked(ctx context.Context, now time.Time) (*jwksFlight, error) {
	if r := v.backoffRemaining(now); r > 0 {
		return nil, &TransportError{Msg: fmt.Sprintf(
			"JWKS fetch backing off after %d consecutive failures (retry in %.2fs)", v.failures, r.Seconds())}
	}
	f := &jwksFlight{done: make(chan struct{})}
	v.flight = f
	go v.runFetch(context.WithoutCancel(ctx), f)
	return f, nil
}

// runFetch performs the fetch and records its outcome. Only a fetch that failed counts toward the backoff —
// the context is detached, so no caller's cancellation can make it fail — and a success resets it.
func (v *Validator) runFetch(ctx context.Context, f *jwksFlight) {
	err := v.fetch(ctx)
	v.mu.Lock()
	if err != nil {
		v.failures++
		v.lastFailure = v.opts.now()
		v.backoff = v.backoffDelay()
	} else {
		v.failures = 0
		v.lastFailure = time.Time{}
		v.backoff = 0
	}
	v.flight = nil
	v.mu.Unlock()
	f.err = err
	close(f.done)
}

func (v *Validator) lookup(kid string) any {
	v.mu.Lock()
	defer v.mu.Unlock()
	if !v.freshLocked(v.opts.now()) {
		return nil
	}
	if keys := v.jwks.Key(kid); len(keys) > 0 {
		return keys[0].Key
	}
	return nil
}

// freshLocked reports whether the cached key set may be used at now: there is one, younger than jwksMaxAgeSeconds.
// Callers hold v.mu.
func (v *Validator) freshLocked(now time.Time) bool {
	return v.jwks != nil && now.Sub(v.loadedAt) < jwksMaxAgeSeconds*time.Second
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
	v.jwks, v.loadedAt = &ks, v.opts.now()
	v.mu.Unlock()
	return nil
}
