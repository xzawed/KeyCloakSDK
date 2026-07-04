package keycloak

import (
	"context"
	"errors"
	"testing"
)

func TestNewValidatesAndAssemblesAuth(t *testing.T) {
	c, err := New(Config{ServerURL: "https://kc.example.com", Realm: "demo", ClientID: "app"})
	if err != nil {
		t.Fatalf("valid config: %v", err)
	}
	if c.Auth == nil {
		t.Fatal("Auth must be assembled immediately")
	}
}

func TestNewRejectsInvalidConfig(t *testing.T) {
	_, err := New(Config{ServerURL: "", Realm: "r", ClientID: "c"})
	var ce *ConfigError
	if !errors.As(err, &ce) {
		t.Fatalf("invalid config must yield *ConfigError, got %v", err)
	}
}

func TestAdminRequiresSecret(t *testing.T) {
	c, err := New(Config{ServerURL: "https://kc", Realm: "r", ClientID: "c"}) // no secret
	if err != nil {
		t.Fatalf("New must succeed without secret (Auth-only use): %v", err)
	}
	_, err = c.Admin(context.Background())
	var ce *ConfigError
	if !errors.As(err, &ce) {
		t.Fatalf("Admin without secret must yield *ConfigError, got %v", err)
	}
}

func TestCloseWithoutAdmin(t *testing.T) {
	c, _ := New(Config{ServerURL: "https://kc", Realm: "r", ClientID: "c"})
	if err := c.Close(); err != nil {
		t.Fatalf("Close without admin must be a no-op, got %v", err)
	}
}
