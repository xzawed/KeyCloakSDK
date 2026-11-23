"""Integration drive — the lane's unit command (`pytest -m "not integration"`) leaves it out."""

import pytest

from keycloak_sdk.auth_client import AuthClient

pytestmark = pytest.mark.integration


def test_logout_url() -> None:
    assert AuthClient("demo").logout_url() == "/realms/demo/logout"
