import math

import pytest

from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakConfigError


def test_defaults():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app")
    assert c.clock_skew == 30.0
    assert c.scopes == ("openid",)
    assert c.jwks_min_refetch_seconds == 30.0
    assert c.expected_audience is None


def test_expected_audience_is_kept_when_set():
    c = KeycloakConfig(
        server_url="https://kc", realm="r", client_id="app", expected_audience="some-api"
    )
    assert c.expected_audience == "some-api"


def test_jwks_min_refetch_custom_and_negative():
    c = KeycloakConfig(
        server_url="https://kc", realm="r", client_id="app", jwks_min_refetch_seconds=120.0
    )
    assert c.jwks_min_refetch_seconds == 120.0
    with pytest.raises(KeycloakConfigError) as exc:
        KeycloakConfig(
            server_url="https://kc", realm="r", client_id="app", jwks_min_refetch_seconds=-1
        )
    assert str(exc.value) == "jwks_min_refetch_seconds must be >= 0"


@pytest.mark.parametrize("value", [0, 0.0, -1.0, math.nan, math.inf, -math.inf])
def test_read_timeout_rejects_non_positive_and_non_finite(value: float) -> None:
    with pytest.raises(KeycloakConfigError) as exc:
        KeycloakConfig(server_url="https://kc", realm="r", client_id="app", read_timeout=value)
    assert str(exc.value) == "read_timeout must be > 0"


@pytest.mark.parametrize("value", [0.001, 30.0])
def test_read_timeout_accepts_positive_boundary(value: float) -> None:
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app", read_timeout=value)
    assert c.read_timeout == value


@pytest.mark.parametrize("value", [-1.0, math.nan, math.inf, -math.inf])
def test_clock_skew_rejects_negative_and_non_finite(value: float) -> None:
    with pytest.raises(KeycloakConfigError) as exc:
        KeycloakConfig(server_url="https://kc", realm="r", client_id="app", clock_skew=value)
    assert str(exc.value) == "clock_skew must be >= 0"


@pytest.mark.parametrize("value", [0, 30.0])
def test_clock_skew_accepts_non_negative_boundary(value: float) -> None:
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app", clock_skew=value)
    assert c.clock_skew == value


@pytest.mark.parametrize("value", [math.nan, math.inf, -math.inf])
def test_jwks_min_refetch_rejects_non_finite(value: float) -> None:
    with pytest.raises(KeycloakConfigError) as exc:
        KeycloakConfig(
            server_url="https://kc", realm="r", client_id="app", jwks_min_refetch_seconds=value
        )
    assert str(exc.value) == "jwks_min_refetch_seconds must be >= 0"


def test_jwks_min_refetch_accepts_zero():
    c = KeycloakConfig(
        server_url="https://kc", realm="r", client_id="app", jwks_min_refetch_seconds=0
    )
    assert c.jwks_min_refetch_seconds == 0


def test_missing_realm_raises():
    with pytest.raises(KeycloakConfigError):
        KeycloakConfig(server_url="https://kc", realm="", client_id="app")


def test_empty_signature_algorithms_raises():
    with pytest.raises(KeycloakConfigError):
        KeycloakConfig(server_url="https://kc", realm="r", client_id="app", signature_algorithms=())


def test_signature_algorithms_default_is_rs256():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app")
    assert c.signature_algorithms == ("RS256",)


def test_repr_masks_secret():
    c = KeycloakConfig(
        server_url="https://kc", realm="r", client_id="app", client_secret="supersecret"
    )
    assert "supersecret" not in repr(c)
