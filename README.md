# KeyCloak SDK (다국어)

Keycloak을 위한 **다국어 SDK**. **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** 를 모두 다루며, 언어마다 관용적이면서도 개념·계층·흐름이 동형인 SDK를 제공합니다.

- **기준 언어 (진행 중)**: Java 17 · Maven
- **향후**: Python
- **라이선스**: Apache-2.0

## 전략

> 언어마다 **가장 좋은 기반**을 사용 — 공식 클라이언트가 있으면 감싸고(Java: `keycloak-admin-client`), 없으면 OpenAPI 명세에서 코드 생성(Python) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다.

- **Admin API**: Java는 공식 `org.keycloak:keycloak-admin-client` 래핑.
- **인증**: 프로토콜 재구현 없이 Java는 Nimbus OAuth2/OIDC SDK 래핑 (Authorization Code+PKCE, Client Credentials, 토큰 검증/갱신).

## 현재 상태

**설계 단계** — Java 코드는 아직 스캐폴딩되지 않았습니다.

- 📄 설계 스펙: [docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md)
- 🗂️ 구현 계획(WBS): [docs/superpowers/plans/](docs/superpowers/plans/)

## 개발자 안내

프로젝트 구조·아키텍처·게이트/게차(gotchas)는 [CLAUDE.md](CLAUDE.md)를 참고하세요.
