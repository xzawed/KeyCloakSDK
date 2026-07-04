package keycloak

import (
	"context"
	"errors"
	"testing"

	"github.com/Nerzal/gocloak/v13"
)

func TestNewAdminClientRequiresSecret(t *testing.T) {
	_, err := newAdminClient(context.Background(),
		Config{ServerURL: "https://kc", Realm: "r", ClientID: "c"}.withDefaults())
	var ce *ConfigError
	if !errors.As(err, &ce) {
		t.Fatalf("missing clientSecret must yield *ConfigError, got %v", err)
	}
}

func TestToSDKError(t *testing.T) {
	// *gocloak.APIError → *AdminError, matching sentinels.
	for status, sentinel := range map[int]error{404: ErrNotFound, 409: ErrConflict, 403: ErrForbidden} {
		err := toSDKError(&gocloak.APIError{Code: status, Message: "x"})
		if !errors.Is(err, sentinel) {
			t.Errorf("status %d must match its sentinel", status)
		}
		var ae *AdminError
		if !errors.As(err, &ae) || ae.StatusCode != status {
			t.Errorf("status %d: errors.As → *AdminError{%d}", status, status)
		}
	}
	// non-APIError → *TransportError.
	var te *TransportError
	if !errors.As(toSDKError(errors.New("boom")), &te) {
		t.Fatal("non-API error must become *TransportError")
	}
	// gocloak wraps network failures in *APIError with Code 0 → *TransportError, not AdminError.
	err := toSDKError(&gocloak.APIError{Code: 0, Message: "dial tcp: connection refused"})
	var te2 *TransportError
	if !errors.As(err, &te2) {
		t.Fatalf("Code-0 APIError (no HTTP response) must become *TransportError, got %T", err)
	}
	var ae *AdminError
	if errors.As(err, &ae) {
		t.Fatal("Code-0 APIError must NOT be an *AdminError (HTTP 0 is nonsensical)")
	}
}

func TestCallRunWrapErrors(t *testing.T) {
	_, err := call(func() (int, error) { return 0, &gocloak.APIError{Code: 404} })
	if !errors.Is(err, ErrNotFound) {
		t.Fatal("call must convert APIError via toSDKError")
	}
	if err := run(func() error { return &gocloak.APIError{Code: 409} }); !errors.Is(err, ErrConflict) {
		t.Fatal("run must convert APIError via toSDKError")
	}
	if _, err := call(func() (int, error) { return 5, nil }); err != nil {
		t.Fatal("call must pass through success")
	}
}
