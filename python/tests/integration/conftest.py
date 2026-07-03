"""세션 스코프 Keycloak 컨테이너 하네스 (WBS 6.1).

`testcontainers[keycloak]`의 `KeycloakContainer`로 실제 Keycloak을 기동하고
`it-realm-realm.json`(Java SDK의 통합 테스트 realm 재사용)을 임포트한다. 모든
`integration` 마커 테스트가 세션 동안 컨테이너 1개를 공유한다.
"""
from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest
from testcontainers.keycloak import KeycloakContainer

_REALM_IMPORT_FILE = Path(__file__).parent / "it-realm-realm.json"


@pytest.fixture(scope="session")
def keycloak_url() -> Iterator[str]:
    """`it-realm`을 임포트한 Keycloak 26.6 컨테이너를 세션 동안 1회 기동하고
    base auth-server URL(예: `http://localhost:32819`)을 반환한다."""
    container = KeycloakContainer("quay.io/keycloak/keycloak:26.6").with_realm_import_file(
        str(_REALM_IMPORT_FILE)
    )
    with container as started:
        yield started.get_url()
