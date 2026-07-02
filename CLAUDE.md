# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

Keycloak을 위한 **다국어 SDK**. Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다룬다. 언어마다 관용적이되 개념·계층·흐름은 **동형(isomorphic)** 이도록 설계한다.

- **기준 언어**: Java 17 · Maven (첫 구현)
- **향후 언어**: Python (OpenAPI 코드 생성 + Authlib 래퍼)
- **라이선스**: Apache-2.0 · **groupId**: `io.github.xzawed`

**핵심 전략**: 언어마다 가장 좋은 기반을 사용한다 — 공식 클라이언트가 있으면 감싸고(Java는 `keycloak-admin-client`), 없으면 OpenAPI에서 코드 생성(Python) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다.

## 현재 상태 ⚠️

**설계 단계 — Java 코드/Maven 모듈은 아직 스캐폴딩되지 않았다.** 빌드/테스트 명령은 `java/` 모듈이 생성된 후 이 문서에 추가한다.

- 설계 스펙: [docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) — **구현 전 반드시 정독**
- 구현 계획(WBS): [docs/superpowers/plans/](docs/superpowers/plans/)

## 계획된 아키텍처

폴리글랏 모노레포. MVP 구현은 `java/`에 집중한다.

```
java/                          # Maven 멀티모듈 reactor
├─ keycloak-sdk-bom/           # 의존성 버전 고정 BOM (배포)
├─ keycloak-sdk-core/          # KeycloakConfig, TokenProvider, 예외 계층, 보안 정책 (외부만 의존)
├─ keycloak-sdk-auth/          # 인증 래퍼 — Nimbus OAuth2/OIDC SDK 감쌈 (core 의존)
├─ keycloak-sdk-admin/         # 관리 파사드 — 공식 keycloak-admin-client 감쌈 (core 의존)
├─ keycloak-sdk/               # 통합 진입점 KeycloakClient (core+auth+admin)
└─ keycloak-sdk-examples/      # 실행 예제 (배포 제외)
spec/                          # 버전 고정 Keycloak Admin OpenAPI (Python 코드생성 소스)
```

**결합 규칙**: `admin`은 `auth`를 직접 알지 못한다. 둘을 잇는 유일한 접착제는 `core`의 `TokenProvider` 인터페이스다 — auth 없이도 admin을 자체 토큰 소스로 쓸 수 있고, 내부 라이브러리 교체가 소비자에게 파급되지 않는다.

**언어 중립 계약(§4)**: Java(손수 래핑)와 Python(OpenAPI 생성)의 출발점이 다르므로, 언어 중립 API 계약을 진실 원천으로 두고 각 언어가 구현한다. Python은 생성된 저수준 클라이언트를 **파사드 뒤에 숨기고** 공개 API로 노출하지 않는다.

## 핵심 게차 (Gotchas) — 2026-07-02 검증

- ⚠️ **admin-client 버전 ≠ 서버 버전.** Keycloak 서버는 26.6.4지만 `keycloak-admin-client`는 독립 트랙 **26.0.10**이다("26.6.x admin-client"는 존재하지 않음). 하나의 클라이언트가 여러 서버 버전을 지원한다. `representation` 필드가 서버와 완전히 일치하지 않을 수 있으니 의존 필드는 실제 서버로 검증한다.
- ⚠️ **Maven Central은 Central Portal 경로만.** 구 OSSRH는 2025-06-30 종료. `central-publishing-maven-plugin:0.11.0` 사용(공식 문서 예제의 0.9.0은 낡음).
- ⚠️ **Testcontainers 2.0 모듈명 변경.** JUnit5 확장 모듈은 `org.testcontainers:testcontainers-junit-jupiter`(구 `junit-jupiter` 아님). `testcontainers-keycloak:4.2.1`은 KC 26.6 기본.
- ⚠️ **JWT 검증 강화 필수(CVE-2026-11800).** 알고리즘 핀닝(`none` 거부·헤더 신뢰 금지), iss/aud 검증, 클록 스큐 제한. Nimbus는 building block만 제공하고 안전한 기본값은 주지 않는다.
- ⚠️ **보안**: 토큰/시크릿 로깅 금지·마스킹, TLS 검증 기본 on, 기본 인메모리 토큰 저장 + 교체 가능한 `TokenStore` SPI.
- ⚠️ **어떤 Java OIDC 라이브러리도 자체 "certified" 아님.** 완성 제품을 필요 시 OIDF에 인증한다.

## 확정 의존성 (BOM으로 고정)

| 의존성 | 좌표 | 버전 |
|---|---|---|
| Keycloak admin-client | `org.keycloak:keycloak-admin-client` | 26.0.10 |
| OAuth2/OIDC SDK | `com.nimbusds:oauth2-oidc-sdk` | 11.37.2 |
| JOSE/JWT | `com.nimbusds:nimbus-jose-jwt` | 10.9.1 |
| 통합 테스트 | `com.github.dasniko:testcontainers-keycloak` | 4.2.1 |
| Testcontainers | `org.testcontainers:testcontainers` (+ `-junit-jupiter`) | 2.0.5 |
| 단위 테스트 | JUnit 6.1.1 · Mockito 5.23.0 | — |

## 문서 유지 규칙

작업 완료(머지/main 반영) 후 프로젝트 전체 문서(`CLAUDE.md`, `docs/`, `README.md`)를 최신화·최적화하고 커밋한다. 특히 `java/` 모듈이 생성되면 빌드/테스트 명령(단일 테스트 실행 포함)을 이 문서에 추가한다.
