package keycloak

import (
	"fmt"
	"strings"
)

// Config is immutable SDK configuration. Build it as a struct literal and pass
// it to New, which validates it and fills defaults.
type Config struct {
	ServerURL      string
	Realm          string
	ClientID       string
	ClientSecret   string
	Scopes         []string
	ConnectTimeout int64 // ms; default 10000
	ReadTimeout    int64 // ms; default 30000
	ClockSkew      int64 // seconds; default 30
}

func (c Config) validate() error {
	for _, f := range []struct{ name, val string }{
		{"ServerURL", c.ServerURL}, {"Realm", c.Realm}, {"ClientID", c.ClientID},
	} {
		if strings.TrimSpace(f.val) == "" {
			return &ConfigError{Msg: "missing required config: " + f.name}
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
	return c
}

// String masks the client secret so a config is never logged in plaintext.
func (c Config) String() string {
	return fmt.Sprintf("Config{ServerURL:%q, Realm:%q, ClientID:%q, ClientSecret:%s, Scopes:%v}",
		c.ServerURL, c.Realm, c.ClientID, mask(c.ClientSecret), c.Scopes)
}
