"""Install-smoke(b1) — python/examples/quickstart.py의 env-driven 등가물.

consume/python.Dockerfile이 pypiserver에서 설치한 `keycloak-sdk==0.1.0`(소스 트리 접근 없음)를 실
Keycloak에 대해 최소 흐름(client-credentials 발급 → 자체 강화 validate)으로 구동해 "설치 후 첫
프로그램이 실제로 동작한다"를 증명한다. python/examples/quickstart.py는 하드코딩된
https://keycloak.example.com을 쓰지만(정적 임포트/타입체크만 목표), 이 파일은 install-net에서
실 Keycloak(KC_SERVER_URL=http://keycloak:8080)을 향하도록 env로 구동한다는 점만 다르다 — SDK
소비 형태(공개 API·mask() 사용)는 동일하게 재사용한다. node/quickstart.mjs와 동형 구조.

SDK 소스 트리가 아니라 harness/install/ 아래 하네스 전용 파일이다(python/ 패키지 배포 아티팩트에는
포함되지 않는다).
"""

from __future__ import annotations

import os

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk._internal.secrets import mask


def env(k: str, d: str) -> str:
    v = os.environ.get(k)
    return v if v else d


def main() -> None:
    config = KeycloakConfig(
        server_url=env("KC_SERVER_URL", "http://localhost:8080"),
        realm=env("KC_REALM", "it-realm"),
        client_id=env("KC_CLIENT_ID", "it-client"),
        client_secret=env("KC_CLIENT_SECRET", "it-secret"),
    )

    with KeycloakClient.create(config) as kc:
        # 1) client-credentials 토큰 발급 — 토큰 원문은 절대 로그에 남기지 않는다(mask()).
        token = kc.auth.client_credentials_token()
        if not token.access_token:
            raise RuntimeError("quickstart-smoke: no access token issued")

        # 2) 발급받은 토큰을 자체 강화 검증(alg 핀·iss 정확일치·aud 포함검사·클록 스큐).
        validated = kc.auth.validate(token.access_token)
        if not validated.subject:
            raise RuntimeError("quickstart-smoke: validate produced no subject")

        print(
            f"quickstart-smoke OK: access_token={mask(token.access_token)} "
            f"tokenType={token.token_type} subject={validated.subject} "
            f"audience={','.join(validated.audience)}"
        )


if __name__ == "__main__":
    main()
