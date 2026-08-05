# 가상사용자 실측 테스트 하네스 — 설계 문서 (Design Spec)

> <!-- doc-status: complete -->
> **✅ 완료 — 이 설계는 구현됐다. 기록으로 읽어라.** 여기 적힌 "할 것"은 이미 한 것이고, 결정의
> *근거*가 이 문서의 가치다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [문서 지도](../../README.md)에 있다.

- **작성일**: 2026-07-05
- **대상**: 크로스커팅 딜리버러블 — `harness/`(5개 언어 SDK 공통)
- **관련**: 5개 언어 SDK(`java/`·`python/`·`node/`·`go/`·`dotnet/`) — 각 SDK의 Testcontainers E2E를 보완(대체 아님)
- **라이선스**: Apache-2.0

---

## 1. 개요 (Overview)

Keycloak 폴리글랏 SDK는 5개 언어 모두 완료됐으나 **실레지스트리 배포는 사람 게이트(계정 없음)** 로 미실행이다. 이 하네스는 실배포 대신 **프로덕션-유사 환경에서 각 언어 SDK의 실동작을 실측 검증**한다.

**핵심 아이디어**: 각 언어 SDK의 **빌드 산출물(패키지)** 을 소비하는 **HTTP 리소스서버 샘플 앱**을 Docker Compose(실제 Keycloak) 환경에 배포하고, **공통 외부 가상사용자 드라이버(k6)** 가 동일 HTTP 계약을 동시 호출해 **(a) 기능 정확성 PASS/FAIL 게이트** + **(b) 성능 실측(언어간 비교)** 를 산출한다.

**기존 Testcontainers E2E와의 차이**(왜 별도 딜리버러블인가):
| | 기존 SDK E2E | 이 하네스 |
|---|---|---|
| 소비 대상 | 소스(프로젝트 참조) | **빌드 산출물(패키지)** — 배포가능성 검증 |
| 실행 형태 | 테스트 프로세스 내부 | **컨테이너 배포 + 외부 HTTP 트래픽** |
| 부하 | 순차 단일 흐름 | **동시 가상사용자(부하)** |
| 관점 | 언어별 개별 | **언어간 대조(동형 동작 + 성능 비교)** |
| 측정 | 통과/실패 | 통과/실패 + **p50/p95/p99·RPS·오류율 실측** |

### 확정 결정 (브레인스토밍 승인)
- **인프라**: Docker Compose(로컬/CI 친화, 프로덕션-유사에 충분).
- **앱 형태**: 언어별 HTTP 리소스서버 + 공통 외부 드라이버(k6).
- **측정**: 기능 정확성 = PASS/FAIL 게이트, 성능 = 실측·리포트(언어간 비교).
- **단계화**: MVP 1언어(**Go**) → 확장(C# → Node → Python → Java).
- **소비**: **빌드 패키지**(로컬 피드) — 소스 참조 아님.
- **드라이버**: **k6**(언어-불가지, 내장 지연 백분위·체크·임계값).

---

## 2. 범위 (Scope) & 비목표

### 범위
- Docker Compose 프로덕션-유사 환경(실제 Keycloak 26.6 + 임포트 realm).
- 언어별 샘플 앱(공통 HTTP 계약 구현, **빌드 패키지 소비**) — MVP는 Go 1개, 이후 4개.
- k6 가상사용자 드라이버(기능 체크 + 동시 부하).
- 측정/리포트(언어간 성능 비교표 + 정확성 매트릭스).
- 단일 명령 오케스트레이션(`run.sh`) + CI 잡.

### 비목표
- 실레지스트리 배포(계정 게이트, 별도).
- SDK 코드 변경(하네스는 소비자 관점 — SDK는 있는 그대로 사용). 하네스가 SDK 버그를 발견하면 보고하되 SDK 수정은 별도 사이클.
- 완전한 K8s 프로덕션 배포(향후 별도 사이클 — 동일 앱/드라이버 재사용).
- 성능 임계값 강제(성능은 실측·리포트만; 정확성만 게이트).
- Keycloak 자체 튜닝/HA(단일 인스턴스로 충분).

---

## 3. 아키텍처 (유닛 경계)

```
harness/
├─ docker-compose.yml           # keycloak(+선택 postgres) + N개 app 서비스
├─ keycloak/harness-realm.json  # 임포트 realm(it-client/it-secret + 서비스계정 manage-users + it-client aud 매퍼)
├─ contract/CONTRACT.md         # 공통 HTTP 계약(진실 원천) — 5개 앱 동일 노출
├─ apps/
│  ├─ go/       { Dockerfile, main.go, go.mod }   # MVP 참조
│  ├─ dotnet/   (확장)
│  ├─ node/  python/  java/     (확장)
├─ driver/
│  └─ scenarios.js              # k6 스크립트(기능 체크 + 부하) — 모든 앱 재사용
├─ report/
│  └─ aggregate.mjs (또는 .py)  # k6 요약 JSON 취합 → 비교표(md) + 정확성 매트릭스
├─ run.sh                       # build pkg → build image → compose up → k6(앱별) → report → down
└─ README.md
```

**유닛별 책임/인터페이스/의존**:
- **contract**: 5개 앱이 지켜야 할 HTTP 계약(§4). 진실 원천. 의존 없음.
- **apps/&lt;lang&gt;**: SDK로 계약 구현하는 최소 HTTP 서버. 입력=환경변수(Keycloak URL·realm·clientId·secret·PORT). 의존=해당 언어 SDK **빌드 패키지** + Keycloak. 서로 독립(같은 계약만 지킴).
- **driver(k6)**: 계약을 호출하는 가상사용자. 입력=대상 앱 base URL + Keycloak URL. 출력=요약 JSON + 종료코드(체크 실패 시 비0). 앱 언어에 불가지.
- **report**: driver 출력(앱별 JSON) 취합 → 비교표. 입력=k6 요약들, 출력=마크다운.
- **run.sh**: 위를 순서대로 엮는 오케스트레이터.

---

## 4. 공통 HTTP 계약 (`contract/CONTRACT.md` — 진실 원천)

모든 언어 앱이 **동일하게** 노출한다. 요청/응답 JSON 형태를 고정해 드라이버가 언어-불가지로 단언한다. (인증: admin 엔드포인트는 앱이 SDK client-credentials로 자체 인증 — 호출자 토큰 불요; `/validate`·`/introspect`는 호출자가 body로 토큰 전달.)

| 메서드·경로 | 요청 | 응답(200) | SDK 사용 |
|---|---|---|---|
| `GET /healthz` | — | `{"status":"ok"}` | 앱 기동 + SDK 초기화 확인 |
| `POST /token` | — | `{"tokenType":"Bearer","expiresIn":<int>}`(토큰 원문 미포함) | `auth.clientCredentialsToken` |
| `POST /validate` | `{"token":"<jwt>"}` | `{"subject":"..","audience":[".."],"issuer":"..","expiresAt":<int>}` / 실패 시 **401** `{"error":".."}` | `auth.validate`(JwtValidator 강화) |
| `POST /introspect` | `{"token":"<jwt>"}` | `{"active":true,"username":"..","clientId":".."}` | `auth.introspect` |
| `POST /admin/users` | `{"username":"..","email":".."}` | **201** `{"id":".."}` | `admin.users.create` |
| `GET /admin/users/{id}` | — | `{"id":"..","username":".."}` / 부재 시 **404** | `admin.users.get`(부재→NotFound→404) |
| `GET /admin/users?username=` | — | `[{"id":"..","username":".."}]` | `admin.users.search` |
| `DELETE /admin/users/{id}` | — | **204** | `admin.users.delete` |

- **오류 매핑 규약**: SDK `KeycloakNotFoundException`류 → HTTP 404, `KeycloakTokenValidationException` → 401, 기타 → 500 `{"error":".."}`. 5개 언어가 동일 매핑(동형성 축).
- **마스킹 불변식**: `/token`은 토큰 원문을 반환하지 않는다(메타만). 앱 로그에도 토큰/시크릿 미노출(SDK 마스킹 위임).

---

## 5. 언어별 샘플 앱 (빌드 패키지 소비 — 배포가능성 검증)

각 앱은 최소 의존의 HTTP 서버로, **SDK를 빌드 산출물로 소비**한다(소스 참조 아님). Dockerfile 멀티스테이지: (1) SDK 패키지 빌드 → 로컬 피드, (2) 앱이 그 피드에서 설치, (3) 런타임 이미지.

| 언어 | HTTP | 패키지 소비(배포가능성 검증) |
|---|---|---|
| **Go**(MVP) | `net/http` | `go.mod`의 `replace github.com/xzawed/KeyCloakSDK/go => /sdk`(로컬 모듈) — 모듈 임포트가능성 검증 |
| C# | ASP.NET minimal API | `dotnet pack` → 로컬 NuGet 폴더피드 → 앱이 `Xzawed.Keycloak.Sdk` 참조 |
| Node | `http`/express-min | `npm pack` → tarball → 앱 `npm i ./xzawed-keycloak-sdk-*.tgz` |
| Python | `http.server`/Flask-min | `python -m build` → wheel → 앱 `pip install <wheel>` |
| Java | 내장 `com.sun.net.httpserver` 또는 최소 Javalin | `mvn install`(로컬 repo) → 앱이 `io.github.xzawed:keycloak-sdk` 의존 |

- 앱 설정은 환경변수: `KC_SERVER_URL`·`KC_REALM`·`KC_CLIENT_ID`·`KC_CLIENT_SECRET`·`APP_PORT`(compose가 주입).
- 앱은 **얇게** 유지(계약 매핑 + SDK 호출 + 오류→HTTP 변환만). 프레임워크 최소화로 SDK 동작이 측정에 그대로 드러나게.

---

## 6. 가상사용자 드라이버 (k6)

`driver/scenarios.js` 하나가 모든 앱에 재사용(대상 URL만 파라미터). 1 반복(가상사용자 여정):
1. **인증**: Keycloak 토큰 엔드포인트 직접 호출(client-credentials `it-client`/`it-secret`) → 토큰 획득(aud 매퍼로 aud에 `it-client` 포함). (setup 단계에서 1회 + 만료 전 갱신.)
2. `POST /validate {token}` → `check`: 200 · subject 존재 · audience에 `it-client` 포함 · issuer가 realm으로 끝남.
3. `POST /introspect {token}` → `check`: 200 · `active===true`.
4. `POST /token` → `check`: 200 · `expiresIn>0`.
5. **admin 여정**: `POST /admin/users {username: unique}` → 201·id → `GET /admin/users/{id}` → username 일치 → `DELETE` → 204 → `GET /admin/users/{id}` → **404**(삭제 후 부재 확인).

- **기능 정확성 게이트**: k6 `thresholds: { checks: ['rate==1.00'] }` — 체크 하나라도 실패 시 k6 종료코드 비0 → `run.sh`가 전파 → CI FAIL.
- **성능 실측**: k6 내장 `http_req_duration`(p50/p95/p99)·`http_reqs`(RPS)·`http_req_failed`(오류율)를 엔드포인트 태그별 수집. `--summary-export=<lang>.json`.
- 부하 프로파일: 짧은 램프업 + 고정 VU(예: 10 VU × 30s) — 프로덕션-유사 동시성. (수치는 착수 시 조정.)

---

## 7. 측정 / 리포트

`report/aggregate.*`가 앱별 k6 요약 JSON을 읽어 산출:
- **정확성 매트릭스**: | 언어 | validate | introspect | token | admin CRUD | 종합 | (각 PASS/FAIL)
- **성능 비교표**: | 언어 | validate p95(ms) | admin-create p95(ms) | RPS | 오류율 | (실측)
- 마크다운 `report/RESULTS.md` + 콘솔 요약. CI 아티팩트로 업로드.

---

## 8. 오케스트레이션 & 실행

`run.sh`(단일 명령):
1. 각 언어 SDK 패키지 빌드(앱 Dockerfile 내부 멀티스테이지에서 수행 — 호스트 툴체인 불요).
2. `docker compose build`(앱 이미지 — 패키지 소비 포함).
3. `docker compose up -d keycloak`(+선택 postgres) → healthy 대기(realm import 완료).
4. 앱별: `docker compose up -d app-<lang>` → `/healthz` 대기 → `k6 run --summary-export report/<lang>.json driver/scenarios.js`(대상 URL 주입).
5. `report/aggregate` → `RESULTS.md`.
6. `docker compose down -v`.
- 종료코드: 어느 언어든 체크 실패 시 비0.
- **Keycloak 모드**: MVP는 `start-dev --import-realm`(H2, E2E와 동일 — SDK 검증은 DB 백엔드 불의존). **프로덕션-유사 상향(선택·문서화)**: `postgres` + `start` + 호스트네임/TLS — 향후.

---

## 9. 단계화 (MVP → 확장)

- **MVP**: 전체 하네스(compose·realm·contract·k6 드라이버·정확성 게이트·리포트·run.sh) + **Go 앱 1개**. Go 선택 근거: 초소형 정적 바이너리·빠른 기동·최소 이미지·`replace`로 로컬 모듈 소비가 가장 단순 → 하네스 아키텍처 리스크를 먼저 제거. MVP 성공 = Go 앱이 compose에서 기동 + k6 정확성 전부 PASS + RESULTS.md 산출.
- **확장**: 동일 계약으로 C# → Node → Python → Java 앱 추가(각 Dockerfile 패키지소비 + 계약 구현 + compose 서비스 + `run.sh` 목록 추가). 드라이버·리포트·인프라 재사용 → 언어당 증분 작음.

---

## 10. 성공 기준 & 테스트

- 5개 앱 전부 `docker compose up`에서 기동 + `/healthz` OK.
- k6 정확성 체크 5개 앱 모두 PASS(동형 동작); FAIL 시 CI 비0.
- 언어간 성능 비교표 + 정확성 매트릭스(`RESULTS.md`) 산출.
- `run.sh` 단일 명령 재현. 각 앱은 **빌드 패키지** 소비(배포가능성 검증).
- **하네스 자체 테스트**: 계약 스모크(앱 없이 계약 문서 유효성) + 각 앱의 `/healthz` 기동 확인은 run.sh에 내장. k6 스크립트의 체크가 곧 기능 검증.
- CI: `.github/workflows/harness.yml`(Docker 필요, paths `harness/**`) — MVP는 Go 앱 게이트, 확장 시 매트릭스.

---

## 11. 결정 · 열린 항목

- **결정됨**: `harness/` 배치 · Docker Compose · HTTP 리소스서버 + k6 외부 드라이버 · 기능 게이트 + 성능 실측 · 빌드 패키지 소비 · MVP=Go → 확장 · realm은 it-client/it-secret 재사용 계열.
- **착수 시 확정**: harness-realm.json 정확한 구성(기존 it-realm-realm.json 재사용 가능 여부 — 서비스계정 manage-users + it-client aud 매퍼 확인) · k6 부하 프로파일 수치(VU·duration) · 각 언어 최소 HTTP 프레임워크 선택 · 포트 할당 · report 취합 스크립트 언어(Node `.mjs` 권장 — k6와 근접).
- **비목표 재확인**: K8s·실레지스트리 배포·성능 임계값 강제·SDK 수정은 범위 밖.
