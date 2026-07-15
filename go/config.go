package keycloak

import (
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	jose "github.com/go-jose/go-jose/v4"
)

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
	// JwksMinRefetch is the minimum interval (seconds; default 60) between JWKS
	// refetches triggered by an unresolved kid (key rotation) — a DoS-amplification
	// cap. A forged random kid cannot flood the IdP faster than this.
	JwksMinRefetch int64
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
		c.JwksMinRefetch = 60
	}
	if len(c.SignatureAlgorithms) == 0 {
		c.SignatureAlgorithms = []string{"RS256"}
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
