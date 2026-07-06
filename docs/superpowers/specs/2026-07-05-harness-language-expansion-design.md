# 가상사용자 테스트 하네스 — 5개 언어 확장 설계 (Design)

- **날짜**: 2026-07-05
- **상태**: 설계 승인 대기 → 확정 시 WBS(implementation plan)로 전환
- **선행**: [가상사용자 테스트 하네스 MVP 설계](2026-07-05-virtual-user-test-harness-design.md) · [MVP WBS](../plans/2026-07-05-virtual-user-test-harness-mvp.md)
- **관련**: [언어 지원 로드맵](../../roadmap/language-support.md) · [멀티랭 SDK 설계 §4](2026-07-02-keycloak-multilang-sdk-design.md)

## 1. 배경과 목표

하네스 MVP(PR #15)는 **Go 샘플 앱 하나**로 전체 파이프라인을 실증했다 — 실제 Keycloak 26.6(Docker Compose, `it-realm`) → SDK를 소비하는 샘플 앱 → k6 가상사용자 부하 → 리포트 취합 → CI 게이트(harness.yml, GREEN). 계약(`contract/CONTRACT.md`)·드라이버(`driver/scenarios.js`)·리포트(`report/aggregate.mjs`)·오케스트레이터(`run.sh`)는 처음부터 **언어-무관**하게 설계돼, `run.sh`는 이미 `./run.sh go dotnet node python java`를 지원한다(존재하지 않는 앱은 빌드 실패로 스킵).

**목표**: 나머지 4개 언어(C#/.NET · Node · Python · Java)의 샘플 앱을 동일 계약으로 추가해, `./run.sh go dotnet node python java` 한 줄로 **5개 SDK가 실제 Keycloak에 대해 동형(isomorphic) 동작하는지 기능 정확성을 강제하고, 언어간 성능을 실측 비교**한다. 이로써 다섯 SDK 모두 §4 언어중립 계약을 실환경에서 준수함을 자동 회귀로 보장한다.

**비목표**: SDK 코드 변경(하네스는 소비자일 뿐), 계약 확장(8엔드포인트 고정), 드라이버/리포트 로직 변경(이미 언어-무관), 실배포.

## 2. 범위

### 2.1 재사용 (수정하지 않음)

| 자산 | 이유 |
|---|---|
| `harness/contract/CONTRACT.md` | 8엔드포인트 계약 = 진실 원천. 모든 언어 앱이 동일 구현 |
| `harness/driver/scenarios.js` | `LANG`/`BASE_URL`/`KC_URL` env로 구동, `report/<lang>.json` 출력 — 언어-무관 |
| `harness/report/aggregate.mjs` | `argv`의 언어 목록 순회, 언어별 JSON→RESULTS.md — 언어-무관 |
| `harness/run.sh` | 이미 `"${@:-go}"` 루프로 5언어 순차 실행 지원. **수정 불필요** |
| `harness/keycloak/harness-realm.json` | 5언어 공용 realm import |

### 2.2 신규 추가

- `harness/apps/dotnet/` · `harness/apps/node/` · `harness/apps/python/` · `harness/apps/java/` — 각 앱 소스 + Dockerfile + 빌드 매니페스트
- `harness/docker-compose.yml` — `app-dotnet`·`app-node`·`app-python`·`app-java` 서비스 4종(profile `apps`)
- `.github/workflows/harness.yml` — 5언어 전체를 도는 잡(안 A, §5)

### 2.3 문서 갱신 (작업 완료 후)

`harness/README.md` · 루트 `README.md` · `docs/roadmap/language-support.md`(마지막 문단의 "C#/Node/Python/Java 확장은 계획 단계" → 완료) · `CLAUDE.md`(하네스 언급 갱신) · 자동 메모리.

## 3. 아키텍처

각 언어 앱은 Go 앱과 **동형**이다: 계약의 8엔드포인트를 그 언어의 관용 웹 프레임워크로 노출하고, **로컬 SDK를 소비**(빌드가 곧 배포가능성 스모크테스트 — Go `replace` 선례)하며, 멀티스테이지 Dockerfile로 패키징하고, 컨테이너 **내부 포트 8090**을 연다.

```
harness/apps/
├─ go/       # (기존) net/http stdlib · replace 로 go/ SDK 소비
├─ dotnet/   # ASP.NET Core Minimal API · ProjectReference 로 SDK 소비
├─ node/     # Express 5 (ESM) · file: 로 빌드된 dist 소비
├─ python/   # FastAPI + uvicorn (ASGI) · pip install ../python · keycloak_sdk.aio
└─ java/     # Spring Boot 3 (Spring MVC) · mvn install 후 aggregate 의존
```

**설계 원칙(HTTP 레이어)**: 사용자 선택에 따라 각 앱은 **언어별 관용 프레임워크**를 사용한다(최경량 stdlib이 아니라). 따라서 성능 실측은 "SDK를 관용적 실사용 앱에 넣었을 때"의 수치이며, **프레임워크 오버헤드가 측정에 포함**된다. 리포트(RESULTS.md)와 문서는 이 해석을 명시한다("pure SDK cost"가 아니라 "SDK-in-idiomatic-app"). 기능 정확성 게이트(checks==1.00)는 프레임워크와 무관하게 계약 준수만 판정하므로 이 선택에 영향받지 않는다.

## 4. 언어별 앱 설계

### 4.1 공통 계약 (모든 앱 동일)

`contract/CONTRACT.md`의 8엔드포인트를 그대로 구현한다. 엔드포인트 → SDK 개념 매핑(정확한 관용 메서드명은 구현 시 각 SDK 공개 API를 읽어 확정):

| 엔드포인트 | SDK 호출(개념) | 응답 매핑 |
|---|---|---|
| `GET /healthz` | — | `{"status":"ok"}` |
| `POST /token` | 인증 파사드 client-credentials 토큰 | `{"tokenType","expiresIn"}` (토큰값 미노출) |
| `POST /validate` | 인증 파사드 JWT 자체검증 | `{"subject","audience","issuer","expiresAt"}` / 실패 401 |
| `POST /introspect` | 인증 파사드 introspection | `{"active","username","clientId"}` |
| `POST /admin/users` | admin Users 생성 | 201 `{"id"}` / 중복 409 |
| `GET /admin/users/{id}` | admin Users 단건 조회 | 200 `{"id","username"}` / 부재 404 |
| `GET /admin/users?username=` | admin Users 검색 | 200 `[{"id","username"}]` |
| `DELETE /admin/users/{id}` | admin Users 삭제 | 204 / 부재 404 |

**오류 매핑(동형성)**: SDK NotFound류 → 404 · SDK Conflict류 → 409 · JWT 검증 실패 → 401 · 기타 → 500 `{"error":"<msg>"}`. 각 언어는 자신의 SDK 오류 타입(예외 계급 / Go 센티넬)을 경계에서 HTTP 상태로 변환한다. 토큰/시크릿은 응답·로그에 절대 노출하지 않는다.

### 4.2 언어별 상세

| 언어 | 프레임워크 | 동시성 모델 | SDK 소비 | 빌드/런타임 이미지 | 좌표 |
|---|---|---|---|---|---|
| **C#/.NET** | ASP.NET Core Minimal API (Kestrel) | async (`Task<T>`) | `ProjectReference` → `dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj` (소스 참조) | build `sdk:8.0` → runtime `aspnet:8.0` | `Xzawed.Keycloak.Sdk` 0.1.0, ns `Xzawed.Keycloak` |
| **Node** | Express 5 (ESM) | 이벤트 루프 | 스테이지1 `npm ci && npm run build`(→`dist/`) 후 앱이 `"@xzawed/keycloak-sdk":"file:../<sdk>"` 설치 | `node:22-alpine` | `@xzawed/keycloak-sdk` 0.1.0, `"type":"module"`, `files:["dist"]` |
| **Python** | FastAPI + uvicorn (ASGI) | async (`keycloak_sdk.aio`) | `pip install ./<sdk>` (hatchling 휠) | `python:3.12-slim` | `keycloak-sdk` 0.1.0, 패키지 `keycloak_sdk`, async 미러 `keycloak_sdk.aio` |
| **Java** | Spring Boot 3 (Spring MVC, sync) | 서블릿 스레드풀 | 스테이지1 `mvn -f java/pom.xml install -DskipTests -DskipITs`(로컬 `.m2`) 후 앱 pom이 aggregate 의존 | build `maven:3.9-eclipse-temurin-21` → runtime `eclipse-temurin:21-jre` | `io.github.xzawed:keycloak-sdk:0.1.0-SNAPSHOT` (core+auth+admin 집약) |

**Dockerfile 골격(공통)**: `context: ..`(리포지토리 루트 — SDK 소스 접근). 멀티스테이지: 빌드 스테이지에서 SDK + 앱 소스를 복사·빌드, 런타임 스테이지에 산출물만 복사, 비-root 사용자, `EXPOSE 8090`. 환경변수는 Go 앱과 동일(`KC_SERVER_URL`/`KC_REALM`/`KC_CLIENT_ID`/`KC_CLIENT_SECRET`/`APP_PORT`).

**언어별 주의(gotcha, 구현 시 반영):**

- **C#/.NET**: `WebApplication.CreateBuilder` + Minimal API로 8엔드포인트를 `MapGet`/`MapPost`/`MapDelete`. 파사드는 `AddKeycloak(config)` DI 또는 `KeycloakClient` 직접 구성. admin은 지연 초기화(`AdminAsync`) — 요청마다 재획득하지 말고 앱 수명 동안 재사용. 오류 → HTTP 변환은 SDK 예외 계급(`KeycloakNotFoundException`/`Conflict` 등) catch.
- **Node(Express 5, ESM)**: SDK는 ESM 전용이고 `prepare` 스크립트가 없으므로 Dockerfile이 **SDK dist를 명시 빌드**해야 `file:` 설치가 실제 배포 형상(`dist/index.js`, exports 맵)을 소비한다. Express 5는 async 핸들러의 rejected promise를 전파하므로 각 핸들러에서 SDK 오류를 잡아 상태코드로 매핑. admin `findOne`이 404에서 `null` 반환(선언 타입 `undefined`) — SDK가 이미 NotFound로 변환하므로 앱은 SDK 오류만 처리.
- **Python(FastAPI + aio)**: `keycloak_sdk.aio`의 `AsyncKeycloakClient`/`AsyncAuthClient`/`AsyncAdminClient` 사용. FastAPI 핸들러는 `async def`, uvicorn ASGI. SDK 예외를 `HTTPException`(또는 exception handler)으로 매핑. 앱 수명주기(`lifespan`)에서 클라이언트 생성/정리(`aclose`).
- **Java(Spring Boot 3)**: `@RestController` + `@SpringBootApplication`. sync Java SDK(`KeycloakClient.auth()`/`.admin()`) 사용, Spring MVC(WebFlux 아님)로 동기 모델 정합. `mvn install`이 aggregate `keycloak-sdk`를 로컬 `.m2`에 올려야 앱이 의존 해석. `@ControllerAdvice`로 SDK 예외 → HTTP 상태 변환. **가장 무거운 빌드**(풀 리액터 install + Spring Boot fat jar) — 이미지/CI 시간 비용을 문서화. 콜드 스타트 5~15초는 `run.sh` healthz 90초 대기가 커버.

## 5. Compose · run 통합

`docker-compose.yml`에 4개 서비스 추가(`app-go` 골격 복제):

```yaml
app-<lang>:
  build: { context: .., dockerfile: harness/apps/<lang>/Dockerfile }
  environment:
    KC_SERVER_URL: http://keycloak:8080
    KC_REALM: it-realm
    KC_CLIENT_ID: it-client
    KC_CLIENT_SECRET: it-secret
    APP_PORT: "8090"
  ports: ["<hostPort>:8090"]   # go=8090 · dotnet=8091 · node=8092 · python=8093 · java=8094
  depends_on: { keycloak: { condition: service_healthy } }
  profiles: ["apps"]
```

- **내부 포트는 전부 8090**(계약 단순화, `run.sh`의 `app_port()` 고정) — k6는 compose 네트워크에서 `app-<lang>:8090` 직결.
- **호스트 포트만 8090~8094로 상이** — `run.sh`가 healthz 확인용으로 `docker compose port`로 발견. `run.sh`는 앱을 한 번에 하나씩 기동·정지하므로 실행 중 충돌은 없으나, 수동 전체 기동(`--profile apps up`) 편의를 위해 분리.
- `run.sh` 수정 불필요.

## 6. CI 범위 — 안 A

현재 `harness.yml`은 Go만 게이트(~2분). 5언어(특히 Java Spring Boot 빌드)를 매 PR에 강제하면 CI가 크게 늘어난다. **채택: 안 A**.

- **PR 게이트(기존 유지)**: `push`/`pull_request` 트리거 → Go 앱만 전체 파이프라인(~2분 빠른 스모크). SDK가 안정돼 5언어 앱의 매 PR 회귀 위험은 낮으므로 PR 속도를 보존한다.
- **5언어 전체 잡(신규)**: `workflow_dispatch`(수동) + `schedule`(야간 cron) 트리거 → `./run.sh go dotnet node python java` 실행. 기능 게이트(checks==1.00)를 5언어 모두에 적용, 실패 시 비0 종료, `report/RESULTS.md`를 아티팩트로 업로드(언어간 비교표).
- **로컬**: 항상 `./run.sh go dotnet node python java`로 전체 실행 가능(트리거 무관).

## 7. 검증 전략

- **기능 정확성 오라클(자동)**: k6 `checks: rate==1.00` 게이트가 각 앱의 계약 준수를 강제 — validate(subject/aud-포함/issuer-접미), introspect(active), admin 여정(create 201+id → get 200 → delete 204 → get-after-delete 404). 하나라도 어긋나면 `run.sh`/CI 비0. 이것이 "각 앱이 올바른가"의 판정.
- **로컬 스모크(구현 중, 태스크별)**: 각 앱을 개별 기동(`docker compose --profile apps up -d --build app-<lang>`) 후 `curl`로 8엔드포인트 수동 확인 → 계약 스키마·상태코드 일치 검증.
- **성능 실측(비강제)**: validate p95 · admin CRUD p95 · RPS · 오류율을 언어간 비교표로. 임계값 강제는 아님(기능 게이트만 PASS/FAIL).

## 8. 리스크와 완화

| 리스크 | 완화 |
|---|---|
| Java Spring Boot 빌드가 무겁다(이미지·CI 시간) | 안 A로 매 PR 부담 회피(야간/수동). Dockerfile 레이어 캐시. jre 런타임 이미지로 최종 크기 축소 |
| Node ESM `file:` 소비 시 dist 누락 | Dockerfile 빌드 스테이지에서 SDK `npm run build` 명시 — 실제 `files:["dist"]` 형상 검증 |
| 프레임워크 오버헤드가 성능 비교를 흐림 | 의도된 선택(관용 프레임워크). RESULTS.md·문서에 "SDK-in-idiomatic-app" 해석 명시. 기능 게이트는 영향 없음 |
| strict issuer 불일치(SDK가 iss 정확일치 요구) | 모든 앱 `KC_SERVER_URL`과 드라이버 `KC_URL`이 동일 오리진(`http://keycloak:8080`) — MVP 게차 그대로 준수 |
| realm import 파일명 요구(`<realm>-realm.json`) | 기존 compose 마운트(`harness-realm.json` → `it-realm-realm.json`) 재사용, 변경 없음 |
| 언어별 앱 오류→HTTP 매핑 누락 | 계약의 오류 매핑 규약(404/409/401/500)을 각 앱 경계에서 SDK 오류 타입 기준으로 구현, k6 게이트가 회귀 포착 |

## 9. 완료 기준 (DoD)

- [ ] `apps/dotnet`·`apps/node`·`apps/python`·`apps/java` 4개 앱이 8엔드포인트 계약을 구현하고 각자 로컬 SDK를 소비
- [ ] `docker-compose.yml`에 4개 서비스 추가(profile `apps`, 내부 8090, 호스트 8091~8094)
- [ ] `./run.sh go dotnet node python java`가 5언어 모두 **checks==1.00**로 GREEN, `report/RESULTS.md`에 5행 비교표 생성
- [ ] `harness.yml`이 안 A 구조(Go PR 게이트 + 5언어 `workflow_dispatch`/`schedule` 잡)로 갱신, CI GREEN
- [ ] 문서 일괄 갱신(harness/README·루트 README·roadmap·CLAUDE·메모리), 로드맵 매트릭스에 5언어 하네스 완료 반영
