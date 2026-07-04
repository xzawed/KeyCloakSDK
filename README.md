# KeyCloak SDK — polyglot (여러 프로그래밍 언어)

Keycloak을 위한 **여러 프로그래밍 언어용 SDK**(polyglot). Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다루며, 언어마다 관용적이면서도 개념·계층·흐름이 **동형(isomorphic)** 인 SDK를 제공합니다.

> ℹ️ 여기서 "다국어/polyglot"은 **프로그래밍 언어**(Java·Python·향후 확장)를 의미합니다. 자연어 현지화(i18n)와는 무관합니다.

| 언어 | 상태 | 기반 | 배포 |
|---|---|---|---|
| **Java 21** (Maven) | ✅ 완료 · `main` 병합 (PR #1) | 공식 `keycloak-admin-client` + Nimbus OAuth2/OIDC SDK 래핑 | Maven Central `io.github.xzawed:keycloak-sdk` (human-gated) |
| **Python 3.10+** | ✅ 완료 · `main` 병합 (PR #2 sync, PR #4 async) | `python-keycloak`(admin+OIDC) 래핑 + `joserfc` 자체 JWT 검증 | PyPI `keycloak-sdk` (human-gated) |
| **Node.js 20+** (ESM) | ✅ 완료 · `feature/node-sdk` | 공식 `@keycloak/keycloak-admin-client` + `openid-client` v6 래핑 + `jose` 자체 JWT 검증 | npm `@xzawed/keycloak-sdk` (human-gated) |

- **라이선스**: Apache-2.0

## 전략

> 언어마다 **가장 좋은 기반**을 사용 — 공식/성숙 클라이언트가 있으면 감싼다 — 그 위에 **일관된 파사드 + 강화된 JWT 검증**을 언어 공통 설계로 얹는다. 하위 라이브러리 타입은 파사드 뒤에 숨겨 공개 API로 노출하지 않는다.

- **Java**: 공식 `org.keycloak:keycloak-admin-client`(Admin) + Nimbus OAuth2/OIDC SDK(인증) 래핑.
- **Python**: 성숙한 `python-keycloak`의 `KeycloakAdmin`(Admin) + `KeycloakOpenID`(인증) 래핑. sync + **async(`keycloak_sdk.aio`)** 모두 제공.
- **Node.js**: 공식 `@keycloak/keycloak-admin-client`(Admin) + `openid-client` v6 함수형 API(인증) 래핑. ESM 전용·async-only.
- **JWT 검증은 세 언어 모두 자체 강화 구현** — 알고리즘 핀닝(`none`/미서명 거부·헤더 불신), `iss` 정확일치, **`aud` 포함검사**(실제 Keycloak 토큰의 다중 aud 대응), 클록 스큐, DoS-안전 JWKS 재조회. (Java: Nimbus JOSE, Python: joserfc, Node: jose)

## 설치 & 시작

> 🚀 **전체 설치·시작 가이드 → [docs/guides/getting-started.md](docs/guides/getting-started.md)** — 언어별 요구 런타임 · 로컬/배포후 설치 · 최소 사용 예(토큰 발급 → JWT 검증 → admin CRUD)를 한곳에 정리했습니다. 아래는 요약입니다.

**요구 런타임**: Java **JDK 21+**(`--release 21` 컴파일 — 이전 JDK는 `UnsupportedClassVersionError`) · Python **3.10+** · Node.js **20+**(ESM).

### Java (Maven)
> ⚠️ `0.1.0-SNAPSHOT`은 아직 Maven Central 미배포(human-gated). 배포 전에는 `mvn -f java/pom.xml install -DskipITs=true`로 로컬 `~/.m2`에 설치해 사용하세요(Docker 불필요). 배포 절차는 [DEPLOY.md](DEPLOY.md) 참고.

파사드 아티팩트 하나만 추가하면 `core`/`auth`/`admin`이 따라옵니다(전이 버전 정합이 필요하면 BOM 임포트):
```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0-SNAPSHOT</version>
</dependency>
```

### Python (pip)
> ⚠️ `keycloak-sdk` `0.1.0`은 아직 PyPI 미배포(human-gated, PyPI Trusted Publisher). 배포 절차는 [DEPLOY.md](DEPLOY.md) 참고.
```bash
pip install -e python        # 현재(미배포) — 로컬 editable 설치
# pip install keycloak-sdk   # 배포 후
```

### Node.js (npm)
> ⚠️ `@xzawed/keycloak-sdk` `0.1.0`은 아직 npm 미배포(human-gated, npm Trusted Publishing / OIDC + provenance).
```bash
cd node && npm ci && npm run build   # 현재(미배포) — 로컬 빌드 후 npm link/파일 참조
# npm install @xzawed/keycloak-sdk    # 배포 후
```

### 최소 사용 예

토큰 발급 → JWT 검증 → admin CRUD의 **언어별 최소 예제와 async 사용법**은 시작 가이드에 있습니다: **[getting-started](docs/guides/getting-started.md)**. 실행 예제는 [`java/keycloak-sdk-examples`](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java) · [`python/examples/quickstart.py`](python/examples/quickstart.py)(+[async](python/examples/async_quickstart.py)) · [`node/examples/quickstart.ts`](node/examples/quickstart.ts) 참고.

## 호환성

| SDK | 대상 Keycloak 서버 | 기반 라이브러리 |
|---|---|---|
| Java `0.1.0-SNAPSHOT` | 26.6.x (통합테스트: 실제 **26.6.4**) | `keycloak-admin-client` **26.0.10** (서버와 독립 버전 트랙 — "26.6.x admin-client"는 없음) · Nimbus `oauth2-oidc-sdk` 11.37.2 |
| Python `0.1.0` | 26.6.x (통합테스트: 실제 **26.6.4**) | `python-keycloak` **7.1.x** · `joserfc` 1.7.x · Python 3.10+ |
| Node `0.1.0` | 26.6.x (통합테스트: 실제 **26.6**) | `@keycloak/keycloak-admin-client` **26.6.4** · `openid-client` **6.8.4** · `jose` **5.10.0** · Node 20+ |

SDK 자체 SemVer는 Keycloak/하위 라이브러리 버전과 분리됩니다. 지원 서버 범위는 이 표로 안내합니다.

## 현재 상태

**Java · Python SDK 완료 · `main` 병합. Node.js SDK 완료 · `feature/node-sdk`(PR 예정).** 각 언어 전 Phase(기반→core→auth→admin→facade→통합테스트→배포&문서) 구현, **실제 Keycloak 26.6(.4) Testcontainers 통합테스트 GREEN**, 로직 커버리지 게이트(라인 ≥90%/브랜치 ≥85%) 통과. Python은 sync + async(`keycloak_sdk.aio`) 모두 제공. Node는 ESM·async-only. **남은 것은 실배포뿐**(Maven Central·PyPI·npm, 사람 계정/키/토큰 필요 — [DEPLOY.md](DEPLOY.md)).

- 📄 설계 스펙: [Java·Python 멀티랭 설계](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) · [Python](docs/superpowers/specs/2026-07-03-keycloak-python-sdk-design.md) · [Python async](docs/superpowers/specs/2026-07-03-keycloak-python-async-design.md)
- 🗂️ 구현 계획(WBS): [docs/superpowers/plans/](docs/superpowers/plans/)
- 📝 검증 로그: [Java](docs/governance/verification-log.md) · [Python](docs/governance/verification-log-python.md) · [Node](docs/governance/verification-log-node.md)

## 개발자 안내

기여·테스트·검증 게이트(머지 전 통과 항목·로컬 명령·PR 체크리스트)는 [CONTRIBUTING.md](CONTRIBUTING.md), 프로젝트 구조·아키텍처·빌드 명령·게차(gotchas)는 [CLAUDE.md](CLAUDE.md), 배포 절차는 [DEPLOY.md](DEPLOY.md)를 참고하세요.

- 🚀 **설치·시작**: [docs/guides/getting-started.md](docs/guides/getting-started.md)
- 🖥️ **Keycloak *서버* 배포**(SDK가 붙을 서버 — 단일 VM + Docker Compose 프로덕션): [docs/guides/deploying-keycloak-server.md](docs/guides/deploying-keycloak-server.md)
- 🗺️ **지원 언어·확장 로드맵**(depth-first · TS/Node → Go → C# → PHP → Rust → Ruby): [docs/roadmap/language-support.md](docs/roadmap/language-support.md)
- 🧩 **새 언어 추가 플레이북**(Java/Python 품질로 반복): [docs/guides/add-a-language-playbook.md](docs/guides/add-a-language-playbook.md)
