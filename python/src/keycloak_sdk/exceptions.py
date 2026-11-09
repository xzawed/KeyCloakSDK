"""SDK exception hierarchy. python-keycloak exception types are not exposed in the public API."""

from __future__ import annotations


class KeycloakSdkError(Exception):
    """The base of all SDK exceptions."""


class KeycloakConfigError(KeycloakSdkError):
    """Invalid configuration."""


class KeycloakAuthError(KeycloakSdkError):
    """Authentication/token exchange failure. Keeps the OAuth error code."""

    def __init__(self, message: str, error: str | None = None) -> None:
        super().__init__(message)
        self.error = error


class TokenValidationError(KeycloakSdkError):
    """JWT signature/claim validation failure."""


class TokenSignatureError(TokenValidationError):
    """Signature/algorithm validation failure (a parent type distinct from claim failures).

    It denotes failures that **a refetch would not help**, such as a signature mismatch · a
    disallowed algorithm · unsigned (`none`). Only a key (kid) resolution failure is split off
    separately, into the subtype `TokenKeyError`."""


class TokenKeyError(TokenSignatureError):
    """The signing key (kid) could not be resolved in the current JWKS — possibly a key rotation.

    It is a subtype of `TokenSignatureError`, so existing consumers that caught signature
    failures as a whole keep working as before. `AuthClient` refetches the JWKS and retries
    **only for this type** — a plain forged signature (`BadSignatureError` →
    `TokenSignatureError`) is not refetched, because a refetch would not help and it would
    become an unauthenticated DoS amplification that triggers `certs()` for every forged token.
    The refetch itself is also rate-limited to a minimum interval, so kid-tampering attacks
    have an upper bound."""


class KeycloakTransportError(KeycloakSdkError):
    """Network/transport error."""


class KeycloakAdminError(KeycloakSdkError):
    """Admin API error. Keeps the HTTP status + the Keycloak error body.

    A failure of the admin client's own token grant is not this class — it is `KeycloakAuthError`,
    as the same response is on the auth client, and it carries nothing from the token endpoint's
    body, which can echo back the client secret and refresh token that were sent."""

    def __init__(self, status_code: int, keycloak_error: str | None = None) -> None:
        super().__init__(f"Keycloak admin error (HTTP {status_code})")
        self.status_code = status_code
        self.keycloak_error = keycloak_error


class KeycloakNotFoundError(KeycloakAdminError):
    """404."""


class KeycloakConflictError(KeycloakAdminError):
    """409."""


class KeycloakForbiddenError(KeycloakAdminError):
    """403."""
