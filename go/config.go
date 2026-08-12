package keycloak

import (
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	jose "github.com/go-jose/go-jose/v4"
)

// DefaultJwksMinRefetchSecs is the single definition of the JWKS
// minimum-refetch default. It is a DoS-amplification cap, and all nine language
// SDKs are aligned on the same value — `scripts/test/test-security-defaults.sh`
// asserts that alignment across the nine and against the consumer docs.
//
// ⚠️ Do not restate this number anywhere else in the package. It used to be
// written twice with two different values (30 here, 60 in jwt.go's fallback);
// the fallback was unreachable from outside the package so nothing broke, but
// "one value, two literals" is exactly how the other languages' consumer-facing
// copies drifted (Ruby shipped 10.0 while its docs said 30).
const DefaultJwksMinRefetchSecs int64 = 30

// Config is immutable SDK configuration. Build it as a struct literal and pass
// it to New, which validates it and fills defaults.
type Config struct {
	ServerURL    string
	Realm        string
	ClientID     string
	ClientSecret string
	Scopes       []string
	// SignatureAlgorithms pins the JWT signature algorithms accepted during
	// validation (default ["RS256"]). Set it for ES256/PS256-signed realms — a
	// hardcoded RS256 would reject every otherwise-valid token there.
	SignatureAlgorithms []string
	ConnectTimeout      int64 // ms; default 10000
	ReadTimeout         int64 // ms; default 30000
	ClockSkew           int64 // seconds; default 30
	// JwksMinRefetch is the minimum interval (seconds; default 30) between JWKS
	// refetches triggered by an unresolved kid (key rotation) — a DoS-amplification
	// cap. A forged random kid cannot flood the IdP faster than this.
	JwksMinRefetch int64
	// ExpectedAudience is the value Validate looks for in the token's aud claim.
	// Unset, it defaults to ClientID (the previous behaviour). A stock realm does
	// not put the client id in a client-credentials token's aud unless an audience
	// mapper is configured, so set this to the API/resource name when the token is
	// audienced at a resource server instead. It applies to the id_token check in
	// ExchangeCode too, which uses the same Validator.
	ExpectedAudience string
}

func (c Config) validate() error {
	for _, f := range []struct{ name, val string }{
		{"ServerURL", c.ServerURL}, {"Realm", c.Realm}, {"ClientID", c.ClientID},
	} {
		if strings.TrimSpace(f.val) == "" {
			return &ConfigError{Msg: "missing required config: " + f.name}
		}
	}
	// Negative timeouts/skew are silently accepted by withDefaults (it only replaces
	// zero), yielding a client that never dials — reject them up front.
	for _, f := range []struct {
		name string
		val  int64
	}{
		{"ConnectTimeout", c.ConnectTimeout}, {"ReadTimeout", c.ReadTimeout}, {"ClockSkew", c.ClockSkew},
		{"JwksMinRefetch", c.JwksMinRefetch},
	} {
		if f.val < 0 {
			return &ConfigError{Msg: "negative config value: " + f.name}
		}
	}
	return nil
}

func (c Config) withDefaults() Config {
	c.ServerURL = strings.TrimRight(c.ServerURL, "/")
	if c.ConnectTimeout == 0 {
		c.ConnectTimeout = 10000
	}
	if c.ReadTimeout == 0 {
		c.ReadTimeout = 30000
	}
	if c.ClockSkew == 0 {
		c.ClockSkew = 30
	}
	if c.JwksMinRefetch == 0 {
		c.JwksMinRefetch = DefaultJwksMinRefetchSecs
	}
	if len(c.SignatureAlgorithms) == 0 {
		c.SignatureAlgorithms = []string{"RS256"}
	}
	if c.ExpectedAudience == "" {
		c.ExpectedAudience = c.ClientID
	}
	return c
}

// signatureAlgorithms converts the configured algorithm names to go-jose types
// for the validator's algorithm pin. (jose.SignatureAlgorithm is a string type.)
func (c Config) signatureAlgorithms() []jose.SignatureAlgorithm {
	algs := make([]jose.SignatureAlgorithm, len(c.SignatureAlgorithms))
	for i, name := range c.SignatureAlgorithms {
		algs[i] = jose.SignatureAlgorithm(name)
	}
	return algs
}

// httpClient builds an *http.Client honoring BOTH ConnectTimeout (dial + TLS
// handshake) and ReadTimeout (the overall request deadline). Previously only
// ReadTimeout was wired (as http.Client.Timeout) and ConnectTimeout was a silent
// no-op. Used by auth, the JWKS validator, and (via transport) the admin client.
func (c Config) httpClient() *http.Client {
	return &http.Client{
		Timeout:   time.Duration(c.ReadTimeout) * time.Millisecond,
		Transport: c.transport(),
		// SSRF hardening: never follow redirects on back-channel requests. Go's default follows up
		// to 10 hops, so an unexpected 3xx from a token/JWKS/admin endpoint would make the SDK fetch
		// an attacker-chosen URL — possibly on the internal network — while carrying our headers.
		// ErrUseLastResponse surfaces the 3xx to the caller instead of erroring, so a legitimate
		// redirect stays observable rather than being silently swallowed.
		// Isomorphic with Rust (`redirect::Policy::none()`) and Ruby (no follow_redirects middleware).
		// ⚠️ This governs requests the SDK itself makes. The OIDC authorization-code `redirect_uri`
		// is a browser front-channel concern and is unaffected.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// transport mirrors http.DefaultTransport's defaults but injects ConnectTimeout
// into the dial and TLS-handshake deadlines.
func (c Config) transport() *http.Transport {
	connect := time.Duration(c.ConnectTimeout) * time.Millisecond
	return &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: connect}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   connect,
		ExpectContinueTimeout: time.Second,
	}
}

// String masks the client secret so a config is never logged in plaintext.
func (c Config) String() string {
	return fmt.Sprintf("Config{ServerURL:%q, Realm:%q, ClientID:%q, ClientSecret:%s, Scopes:%v}",
		c.ServerURL, c.Realm, c.ClientID, mask(c.ClientSecret), c.Scopes)
}
