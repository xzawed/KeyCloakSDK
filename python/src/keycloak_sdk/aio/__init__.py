"""``keycloak_sdk.aio`` — the async mirror of sync ``keycloak_sdk`` (python-keycloak `a_*`)."""

from __future__ import annotations

from .client import AsyncKeycloakClient

__all__ = ["AsyncKeycloakClient"]
