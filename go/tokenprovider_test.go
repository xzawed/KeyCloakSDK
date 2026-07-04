package keycloak

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestProviderCachesBeforeExpiry(t *testing.T) {
	var calls int32
	p := NewClientCredentialsTokenProvider(func(context.Context) (*TokenSet, error) {
		atomic.AddInt32(&calls, 1)
		return &TokenSet{AccessToken: "AT", ExpiresIn: 300}, nil
	}, 30)

	for i := 0; i < 3; i++ {
		tok, err := p.Token(context.Background())
		if err != nil || tok != "AT" {
			t.Fatalf("Token() = %q, %v", tok, err)
		}
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("source called %d times, want 1 (cached)", got)
	}
}

func TestProviderSingleFlight(t *testing.T) {
	var calls int32
	p := NewClientCredentialsTokenProvider(func(context.Context) (*TokenSet, error) {
		atomic.AddInt32(&calls, 1)
		time.Sleep(50 * time.Millisecond) // hold the flight so goroutines pile up
		return &TokenSet{AccessToken: "AT", ExpiresIn: 300}, nil
	}, 30)

	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = p.Token(context.Background()) }()
	}
	wg.Wait()
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("source called %d times under concurrency, want 1 (single-flight)", got)
	}
}

func TestProviderRefreshesOnExpiry(t *testing.T) {
	var calls int32
	p := NewClientCredentialsTokenProvider(func(context.Context) (*TokenSet, error) {
		n := atomic.AddInt32(&calls, 1)
		return &TokenSet{AccessToken: string(rune('A' - 1 + n)), ExpiresIn: 0}, nil // ExpiresIn 0 → 즉시 만료
	}, 30)

	a, _ := p.Token(context.Background())
	b, _ := p.Token(context.Background())
	if a == b {
		t.Fatalf("expired token must be refreshed: %q == %q", a, b)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("source called %d times, want 2 (refreshed)", got)
	}
}
