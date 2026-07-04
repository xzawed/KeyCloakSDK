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

func TestErrorMessagesAndUnwrap(t *testing.T) {
	cause := errors.New("boom")
	msgs := []error{
		&ConfigError{Msg: "c"},
		&AuthError{Msg: "a", Cause: cause},
		&TokenValidationError{Msg: "t", Cause: cause},
		&AdminError{StatusCode: 500, Msg: "m", Cause: cause},
		&TransportError{Msg: "x", Cause: cause},
	}
	for _, e := range msgs {
		if e.Error() == "" {
			t.Errorf("%T: Error() must be non-empty", e)
		}
	}
	// Unwrap exposes the cause chain for the wrapping error types.
	for _, e := range []error{
		&AuthError{Cause: cause}, &TokenValidationError{Cause: cause},
		&AdminError{Cause: cause}, &TransportError{Cause: cause},
	} {
		if !errors.Is(e, cause) {
			t.Errorf("%T: Unwrap must expose the cause", e)
		}
	}
	// AdminError.Is returns false for a non-sentinel target.
	if errors.Is(&AdminError{StatusCode: 404}, errors.New("other")) {
		t.Error("AdminError.Is must not match an arbitrary target")
	}
}
