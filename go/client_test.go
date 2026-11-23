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

// TestAdminReturnsTheCachedClient pins the cache hit in Client.Admin: after a
// successful creation, a second call returns the same *AdminClient and does not
// ask the token endpoint again. The third call, with a context already cancelled,
// still returns that client and a nil error: the outer hit runs before ctx.Err
// is checked, so a cancelled caller is not abandoned and starts no new token request.
func TestAdminReturnsTheCachedClient(t *testing.T) {
	p := newFlightIdP(t)
	c := p.client(t)
	ctx := context.Background()
	first, err := c.Admin(ctx)
	if err != nil {
		t.Fatalf("first Admin: %v", err)
	}
	second, err := c.Admin(ctx)
	if err != nil {
		t.Fatalf("second Admin: %v", err)
	}
	if first != second {
		t.Fatalf("second Admin = %p, want the cached client %p", second, first)
	}
	cancelledCtx, cancel := context.WithCancel(context.Background())
	cancel()
	third, err := c.Admin(cancelledCtx)
	if err != nil {
		t.Fatalf("cancelled Admin: %v", err)
	}
	if first != third {
		t.Fatalf("cancelled Admin = %p, want the cached client %p", third, first)
	}
	if n := p.tokens.Load(); n != 1 {
		t.Fatalf("token requests = %d, want 1", n)
	}
}
