package keycloak

import (
	"errors"
	"testing"
)

func TestAdminErrorSentinels(t *testing.T) {
	if err := error(&AdminError{StatusCode: 404}); !errors.Is(err, ErrNotFound) {
		t.Fatal("404 must match ErrNotFound")
	}
	if err := error(&AdminError{StatusCode: 409}); !errors.Is(err, ErrConflict) {
		t.Fatal("409 must match ErrConflict")
	}
	if err := error(&AdminError{StatusCode: 403}); !errors.Is(err, ErrForbidden) {
		t.Fatal("403 must match ErrForbidden")
	}
	if err := error(&AdminError{StatusCode: 500}); errors.Is(err, ErrNotFound) {
		t.Fatal("500 must not match ErrNotFound")
	}
}

func TestAdminErrorAs(t *testing.T) {
	var ae *AdminError
	err := error(&AdminError{StatusCode: 404, Msg: "gone"})
	if !errors.As(err, &ae) || ae.StatusCode != 404 {
		t.Fatalf("errors.As must yield *AdminError{404}, got %+v", ae)
	}
}

func TestErrorUnwrap(t *testing.T) {
	cause := errors.New("boom")
	err := &AuthError{Msg: "x", Cause: cause}
	if !errors.Is(err, cause) {
		t.Fatal("Unwrap must expose the cause chain")
	}
}
