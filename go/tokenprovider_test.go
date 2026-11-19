package keycloak

import (
	"context"
	"errors"
	"strconv"
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

// A source that breaks its contract with (nil, nil) used to crash the process: the nil *TokenSet was dereferenced
// inside the shared flight, and singleflight's DoChan re-panics a panicking function on a fresh goroutine, where no
// caller can recover it. It is now an *AuthError, nothing is cached, and the next call asks the source again.
func TestProviderNilTokenSetIsAnErrorNotAPanic(t *testing.T) {
	var calls int32
	p := NewClientCredentialsTokenProvider(func(context.Context) (*TokenSet, error) {
		atomic.AddInt32(&calls, 1)
		return nil, nil
	}, 30)
	for i := 0; i < 2; i++ {
		tok, err := p.Token(context.Background())
		var ae *AuthError
		if tok != "" || !errors.As(err, &ae) {
			t.Fatalf("Token() = %q, %v; want \"\" and *AuthError", tok, err)
		}
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("source called %d times, want 2 (nothing cached)", got)
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

// A caller that missed the cache just before a refresh stored its token, and asked for the shared refresh just after
// that refresh had left the single-flight group, started a refresh of its own: the source was asked again and a second
// token issued although a fresh one was cached (registry token-provider-cache-invariants). afterMiss holds that caller
// between its miss and the group while the refresh runs to its end — no sleep sets the order.
func TestProviderMissAsRefreshEndsReusesCachedToken(t *testing.T) {
	var calls atomic.Int32
	p := NewClientCredentialsTokenProvider(func(context.Context) (*TokenSet, error) {
		n := calls.Add(1)
		return &TokenSet{AccessToken: "AT" + strconv.Itoa(int(n)), ExpiresIn: 300}, nil
	}, 30).(*clientCredentialsProvider)
	held, release := make(chan struct{}), make(chan struct{})
	var misses atomic.Int32
	p.afterMiss = func() {
		if misses.Add(1) == 1 { // the late caller: it has missed the cache and not yet asked for the refresh
			close(held)
			<-release
		}
	}
	var late string
	lateDone := async(func() error { tok, err := p.Token(context.Background()); late = tok; return err })
	select {
	case <-held:
	case err := <-lateDone:
		t.Fatalf("the late caller returned (%q, %v) without stopping after its cache miss", late, err)
	}
	// The refresh: its Token returns only once singleflight has dropped the key and handed out the result, so the late
	// caller finds no refresh in flight to join.
	tok, err := p.Token(context.Background())
	if err != nil || tok != "AT1" {
		t.Fatalf("the refresh: Token() = %q, %v", tok, err)
	}
	close(release)
	if err := mustReturn(t, lateDone, "the late caller"); err != nil {
		t.Fatalf("the late caller: %v", err)
	}
	if n := calls.Load(); n != 1 {
		t.Errorf("the source was asked %d times, want 1 — the late caller started a second refresh although %q was cached", n, tok)
	}
	if late != tok {
		t.Errorf("the late caller got %q, want the cached %q", late, tok)
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
