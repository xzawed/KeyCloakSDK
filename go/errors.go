package keycloak

import (
	"errors"
	"fmt"
)

// Sentinel errors for admin HTTP outcomes. Match with errors.Is; the concrete
// *AdminError (with StatusCode) is available via errors.As.
var (
	ErrNotFound  = errors.New("keycloak: not found")
	ErrConflict  = errors.New("keycloak: conflict")
	ErrForbidden = errors.New("keycloak: forbidden")
)

// ConfigError signals invalid configuration (e.g. a missing required field).
type ConfigError struct{ Msg string }

func (e *ConfigError) Error() string { return "keycloak: " + e.Msg }

// AuthError signals an authentication / token-exchange failure. OAuthError
// preserves the OAuth2 "error" code when present.
type AuthError struct {
	Msg        string
	OAuthError string
	Cause      error
}

func (e *AuthError) Error() string { return "keycloak: auth: " + e.Msg }
func (e *AuthError) Unwrap() error { return e.Cause }

// TokenValidationError signals a JWT signature/issuer/audience/expiry failure.
type TokenValidationError struct {
	Msg   string
	Cause error
}

func (e *TokenValidationError) Error() string { return "keycloak: token validation: " + e.Msg }
func (e *TokenValidationError) Unwrap() error { return e.Cause }

// AdminError signals an Admin API failure and preserves the HTTP status code.
// It matches the ErrNotFound/ErrConflict/ErrForbidden sentinels via Is.
type AdminError struct {
	StatusCode int
	Msg        string
	Cause      error
}

func (e *AdminError) Error() string {
	return fmt.Sprintf("keycloak: admin: HTTP %d: %s", e.StatusCode, e.Msg)
}
func (e *AdminError) Unwrap() error { return e.Cause }
func (e *AdminError) Is(target error) bool {
	switch target {
	case ErrNotFound:
		return e.StatusCode == 404
	case ErrConflict:
		return e.StatusCode == 409
	case ErrForbidden:
		return e.StatusCode == 403
	}
	return false
}

// TransportError signals a network/transport failure (no HTTP response).
type TransportError struct {
	Msg   string
	Cause error
}

func (e *TransportError) Error() string { return "keycloak: transport: " + e.Msg }
func (e *TransportError) Unwrap() error { return e.Cause }
