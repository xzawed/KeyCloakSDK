package keycloak

import (
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
)

func TestConfigValidateMissing(t *testing.T) {
	for _, c := range []Config{
		{ServerURL: "", Realm: "r", ClientID: "c"},
		{ServerURL: "https://kc", Realm: "  ", ClientID: "c"},
		{ServerURL: "https://kc", Realm: "r", ClientID: ""},
	} {
		var ce *ConfigError
		if err := c.validate(); !errors.As(err, &ce) {
			t.Fatalf("expected *ConfigError for %+v, got %v", c, err)
		}
	}
	if err := (Config{ServerURL: "https://kc", Realm: "r", ClientID: "c"}).validate(); err != nil {
		t.Fatalf("valid config must pass: %v", err)
	}
}

func TestConfigSignatureAlgorithms(t *testing.T) {
	def := Config{ServerURL: "https://kc", Realm: "r", ClientID: "c"}.withDefaults()
	if len(def.SignatureAlgorithms) != 1 || def.SignatureAlgorithms[0] != "RS256" {
		t.Fatalf("default signature algorithms: %v", def.SignatureAlgorithms)
	}
	custom := Config{ServerURL: "https://kc", Realm: "r", ClientID: "c",
		SignatureAlgorithms: []string{"ES256", "RS256"}}.withDefaults()
	algs := custom.signatureAlgorithms()
	if len(algs) != 2 || algs[0] != jose.ES256 || algs[1] != jose.RS256 {
		t.Fatalf("conversion to jose types: %v", algs)
	}
}

func TestConfigHttpClientWiresConnectAndReadTimeouts(t *testing.T) {
	cfg := Config{ServerURL: "https://kc", Realm: "r", ClientID: "c",
		ConnectTimeout: 3000, ReadTimeout: 7000}.withDefaults()
	c := cfg.httpClient()
	if c.Timeout != 7000*time.Millisecond {
		t.Fatalf("total (read) timeout: %v", c.Timeout)
	}
	tr, ok := c.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type: %T", c.Transport)
	}
	// ConnectTimeout is wired to the TLS handshake deadline (the dial deadline is
	// captured in the DialContext closure and not directly inspectable).
	if tr.TLSHandshakeTimeout != 3000*time.Millisecond {
		t.Fatalf("connect timeout not wired to TLSHandshakeTimeout: %v", tr.TLSHandshakeTimeout)
	}
}

func TestConfigRejectsNegativeTimeouts(t *testing.T) {
	for _, c := range []Config{
		{ServerURL: "https://kc", Realm: "r", ClientID: "c", ConnectTimeout: -1},
		{ServerURL: "https://kc", Realm: "r", ClientID: "c", ReadTimeout: -1},
		{ServerURL: "https://kc", Realm: "r", ClientID: "c", ClockSkew: -1},
		{ServerURL: "https://kc", Realm: "r", ClientID: "c", JwksMinRefetch: -1},
	} {
		var ce *ConfigError
		if err := c.validate(); !errors.As(err, &ce) {
			t.Fatalf("expected *ConfigError for negative timeout %+v, got %v", c, err)
		}
	}
}

func TestConfigDefaultsAndTrim(t *testing.T) {
	c := Config{ServerURL: "https://kc.example.com/", Realm: "r", ClientID: "c"}.withDefaults()
	if c.ServerURL != "https://kc.example.com" {
		t.Fatalf("trailing slash not stripped: %q", c.ServerURL)
	}
	if c.ConnectTimeout != 10000 || c.ReadTimeout != 30000 || c.ClockSkew != 30 {
		t.Fatalf("defaults: %+v", c)
	}
	if c.JwksMinRefetch != 30 {
		t.Fatalf("JwksMinRefetch default: %d", c.JwksMinRefetch)
	}
}

func TestConfigExpectedAudienceDefaultsToClientID(t *testing.T) {
	def := Config{ServerURL: "https://kc", Realm: "r", ClientID: "c"}.withDefaults()
	if def.ExpectedAudience != "c" {
		t.Fatalf("unset ExpectedAudience must default to ClientID, got %q", def.ExpectedAudience)
	}
	custom := Config{ServerURL: "https://kc", Realm: "r", ClientID: "c",
		ExpectedAudience: "api://orders"}.withDefaults()
	if custom.ExpectedAudience != "api://orders" {
		t.Fatalf("explicit ExpectedAudience must be kept, got %q", custom.ExpectedAudience)
	}
}

func TestConfigStringMasksSecret(t *testing.T) {
	s := Config{ServerURL: "https://kc", Realm: "r", ClientID: "c", ClientSecret: "supersecret"}.String()
	if strings.Contains(s, "supersecret") || !strings.Contains(s, "***") {
		t.Fatalf("String must mask clientSecret: %q", s)
	}
}
