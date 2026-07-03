"""컨테이너 부팅 스모크 테스트 (WBS 6.1)."""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.integration


def test_container_starts(keycloak_url: str) -> None:
    assert keycloak_url
    assert keycloak_url.startswith("http")
