# 8개 언어 종합 검증·점수책정 하네스 설계 (Design)

- **날짜**: 2026-07-07
- **상태**: 설계 승인됨 → WBS(implementation plan)로 전환
- **브랜치**: `feature/verification-scoring-harness` (main 기준)
- **선행 정독**: [기존 하네스 README](../../../harness/README.md) · [HTTP 계약 v1](../../../harness/contract/CONTRACT.md) · [하네스 확장 설계](2026-07-05-harness-language-expansion-design.md) · [언어 중립 계약 §4](2026-07-02-keycloak-multilang-sdk-design.md)

## 1. 배경과 목표

8개 언어 SDK(Java·Python·Node·Go·C#·PHP·Rust·Ruby) 전부 `main` 병합 완료. 기존 하네스(`harness/`)는 **5개 언어**(go·dotnet·node·java·python)만 커버하고, **얇은 계약**(user CRUD·happy-path + 404 하나·auth는 token/validate/introspect만)으로 **기능 PASS/FAIL + 성능 비교**만 산출한다.

**목표**: 기존 하네스를 확장해 **8개 언어 전부**가 동일 계약으로 실제 Keycloak에 대해 (1)기능 정확성 (2)보안 하드닝 (3)테스트 커버리지·품질 (4)성능·동형성 **4차원에서 언어별 스코어카드(0–100·등급) + 규칙기반 보완 피드백**을 산출한다. 검증 깊이는 계약 시나리오 전면확장 + 보안 프로브 + 각 SDK 자체 스위트 집계 + 엣지/경계 케이스를 포함한다.

**비목표**: SDK 자체 재구현(검증만), 새 언어 추가, 성능 임계값 강제(성능은 상대비교·점수화), Keycloak 자체 검증.

**접근법**: 하나의 응집 시스템을 **5단계(P1~P5)로 분할** — 각 단계가 독립적으로 가치를 산출(8앱 패리티 → 기능신호 → 보안신호 → 커버리지집계 → 스코어링). 기존 k6·계약·앱 자산 재사용(점진 확장). "일괄 빌드"(무가치·고위험)는 기각.

## 2. 아키텍처 (`harness/` 확장)

```
harness/
├─ contract/CONTRACT.md         # v2로 확장(§3): 모든 auth 흐름·5 admin 리소스·오류경로
├─ apps/
│  ├─ {go,dotnet,node,python,java}/   # 기존 5개 → 계약 v2로 확장
│  └─ {php,rust,ruby}/                # 신규 3개(관용 프레임워크·Alpine/musl 베이스)
├─ driver/scenarios.js          # k6 — 성능/부하 + 기능 checks(현행) 유지
├─ conformance/conformance.mjs  # 신규: 계약 전면 conformance(모든 흐름·CRUD·에러·엣지, 결정적 assert)
├─ security/probe.mjs           # 신규: 보안 프로브(위조 JWT·마스킹·SSRF·TLS 실측)
├─ suites/run-suite.sh          # 신규: 각 SDK 자체 단위+통합 스위트를 언어 컨테이너서 실행 → 결과/커버리지 수집
├─ report/
│  ├─ aggregate.mjs             # 기존(성능/기능 취합) — 유지
│  ├─ score.mjs                 # 신규: 4차원 가중 스코어링 → SCORECARD.md + 피드백
│  └─ SCORECARD.md              # 산출물: 언어별 점수·등급·랭킹·보완사항
├─ verify.sh                    # 신규 오케스트레이터(KC → 8앱 → conformance+security+perf → suite → score)
├─ run.sh                       # 기존(성능/기능 러너) — 유지·8언어 확장
└─ docker-compose.yml           # 신규 3앱 서비스 추가(app-php/app-rust/app-ruby)
```

**컴포넌트 책임(단위 경계):**

- **contract(v2)** — 진실 원천. 8앱이 동일 노출. 자연어+표(§3). conformance/security/k6가 모두 이 계약에만 의존.
- **apps(8)** — 각 언어 관용 프레임워크로 SDK를 소비하는 얇은 HTTP 어댑터. SDK를 **주 소비 경로**(파사드)로만 호출. Alpine/musl 베이스(§6). 신규: php(예: Slim/PHP-FPM 또는 built-in server)·rust(axum/hyper)·ruby(Sinatra/rack). 기존 5앱은 계약 v2 신규 엔드포인트 추가.
- **conformance(신규·결정적)** — 계약 전 엔드포인트를 **1-VU 결정적**으로 순회하며 모든 흐름·5리소스 CRUD·오류경로·엣지를 assert. 언어당 pass/fail 카운트 + 실패 상세 JSON. (k6는 부하·성능용, conformance는 정확성 판정용 — 분리.)
- **security(신규·프로브)** — 실행 앱의 `/validate`·응답·(가능시)로그에 대해 적대적 케이스를 실측(§4). 언어당 프로브별 방어 여부 JSON.
- **suites(신규·집계)** — 각 SDK의 자체 단위+통합 스위트를 **해당 언어 툴체인 컨테이너**서 실행(재구현 아님), 커버리지·테스트 수·린트/정적분석 결과를 기계판독 형태(JSON)로 수집. 무거우므로 CI 야간/수동(§6).
- **score(신규·엔진)** — 위 신호(conformance JSON·security JSON·suite JSON·k6 성능)를 읽어 4차원 가중 점수·등급·랭킹·규칙기반 피드백 계산 → `SCORECARD.md`.
- **verify.sh(오케스트레이터)** — 전체 파이프라인 1커맨드. `run.sh`(성능/기능·기존)는 유지하되 8언어로 확장.

## 3. HTTP 계약 v2 (전면 확장)

기존(healthz·token[client-credentials]·validate·introspect·admin/users CRUD) + 아래 추가. 모든 body JSON, 오류 매핑 규약(404/409/403/401/500) 유지, 토큰/시크릿 응답·로그 노출 금지.

**auth 확장(헤드리스 자동화 가능 범위)**:
| 메서드·경로 | 요청 | 성공 | 검증 의도 |
|---|---|---|---|
| `POST /token/password` | `{"username","password"}` | 200 `{"tokenType","expiresIn","hasRefresh":true}` | ROPC로 refresh 토큰 확보(refresh/logout 자동화 진입점) |
| `POST /refresh` | `{"refreshToken"}`(앱 내부 보관 id로 대체 가능) | 200 `{"tokenType","expiresIn"}` | refresh 흐름 |
| `POST /logout` | (앱 내부 세션) | 204 | RP-initiated logout |
| `GET /authz-url` | `?redirect_uri=` | 200 `{"url","state"}` | authcode+PKCE **오프라인** 검증(URL에 `code_challenge_method=S256`·`code_challenge` 포함·code_verifier 미노출) — 브라우저 왕복은 헤드리스 불가라 URL 조립만 |

> ⚠️ authcode+PKCE 전체 브라우저 플로우는 헤드리스 하네스서 불가 → `authz-url`의 S256 챌린지 존재를 오프라인 assert. refresh/logout은 ROPC로 확보한 refresh 토큰으로 자동화.

**admin 5리소스 확장**(현재 users만 → clients·realms·roles·groups 추가, 오류경로 포함):
| 경로 | 검증 |
|---|---|
| `POST/GET/DELETE /admin/clients` | client CRUD(내부 uuid) |
| `POST/GET/DELETE /admin/roles` | realm role CRUD(name 키) |
| `POST/GET/DELETE /admin/groups` | group CRUD |
| `POST /admin/realms`(master 토큰) | 403(realm SA) 또는 201(master) — 동형 오류매핑 검증 |
| `POST /admin/users`(중복) | 409 Conflict |
| `GET /admin/users/{missing}` | 404 NotFound |

**엣지/경계**: 대용량 username·동시 create(경합)·만료 임박 토큰 재사용(캐시 동작)·delete 후 조회(404).

## 4. 검증 깊이 (4종)

1. **계약 conformance 전면**(conformance.mjs) — 모든 auth 흐름·5리소스 CRUD·오류경로·엣지를 결정적 assert. 언어당 `{passed, failed, failures[]}`.
2. **보안 하드닝 프로브**(security/probe.mjs) — 실행 앱 `/validate`에 적대적 토큰 주입 + 응답/로그 스캔:
   - **JWT**: `alg=none`·`alg=HS256`(confusion)·미서명·**미지 kid**(프로브 RSA 서명)·malformed → 전부 401 기대. **wrong-aud**(2번째 client 토큰)·**wrong-iss**(2번째 realm 토큰) → 401 기대. **expired**(단수명 client 토큰+대기) → 401 기대.
   - **마스킹**: `/token`·`/validate`·`/introspect` 응답 및 (가능시) 앱 로그에 access/refresh 토큰·client_secret 원문 미노출.
   - **DoS-safe JWKS**(관찰): 위조서명 폭주 시 앱→KC `/certs` 히트가 상한(선택·부분).
   - **SSRF/TLS**(부분): 앱이 리다이렉트 미추종·https 검증(하네스 KC가 http라 TLS는 부분 — 문서화된 한계).
   언어당 `{probe, defended:bool}[]`.
3. **SDK 자체 스위트 집계**(suites/run-suite.sh) — 각 언어 툴체인 컨테이너서 `<test cmd>`(단위+통합)+커버리지+린트 실행 → `{unit, integration, coverageLine, coverageBranch, lintClean, testCount}` JSON. (재구현 아님·실행/보고.)
4. **엣지/경계**(conformance에 포함) — 위 §3 엣지 항목.

## 5. 점수 루브릭 (4차원·언어별 0–100 + 등급)

| 차원 | 가중 | 측정(0–100 정규화) |
|---|---|---|
| **기능 정확성** | **30%** | conformance PASS율(passed/(passed+failed)) |
| **보안 하드닝** | **30%** | 보안 프로브 방어율(defended/total). 핵심이라 최고 가중 |
| **테스트 커버리지·품질** | **20%** | 커버리지(라인·브랜치 게이트 대비)·린트/정적분석 clean·통합테스트 존재를 합산 정규화 |
| **성능·동형성** | **20%** | 성능(validate/admin p95·RPS·오류율의 언어간 상대 백분위) + §4 API 표면 완전성(계약 전 엔드포인트 구현=만점) 합산 |

- **종합 = Σ(차원×가중)** → 등급 **A(≥90)/B(≥80)/C(≥70)/D(<70)** + 언어간 랭킹.
- **보완 피드백(규칙기반)**: 각 차원의 미달 신호를 구체 권고로 변환 — 예: `보안 프로브 "wrong-aud" 실패 → aud 포함검사 경계 확인`·`브랜치 커버리지 X%<게이트 → 미커버 브랜치 보강`·`admin realms 미구현 → 계약 완전성 감점, 구현 권고`·`validate p95 상위 대비 N× 느림 → 프로파일 권고`.
- 산출: `SCORECARD.md`(언어별 4차원 표·종합·등급·랭킹·언어별 보완 목록).

## 6. 실행 환경·툴체인

- ⚠️ **Windows Docker Desktop DNS 게차**(문서화됨: Debian/glibc 빌드 이미지가 레지스트리 CNAME 해석 실패) + Ruby에서 겪은 MSYS2/c-ares 동류 → **8앱 빌드 이미지는 Alpine/musl 베이스**. Rust는 `rust:alpine`(musl 타깃)·`cargo build`가 crates.io 접근 필요(Alpine서 정상). PHP는 `php:alpine`+composer, Ruby는 `ruby:alpine`(단, 네이티브 gem 컴파일 필요 — build-base 추가).
- **CI(ubuntu 네이티브 Docker)가 8언어+스코어링 전체 실행의 1차 환경.** Windows 로컬은 스모크(1~2 언어). 공유 compose에 하드코딩 IP/`extra_hosts` 금지(CI landmine).
- SDK 스위트 집계는 8 툴체인 컨테이너로 무거움 → CI 야간(`schedule`)·수동(`workflow_dispatch`), `timeout-minutes` 상향(예: 60). 경량 대안(각 SDK CI가 이미 산출하는 커버리지 결과를 읽어 집계)은 문서화된 폴백.
- 오케스트레이터 `verify.sh`는 실패 언어를 격리(1개 실패가 나머지 산출 막지 않음), 부분 결과라도 SCORECARD 생성.

## 7. TDD 접근 (계약 우선)

- **앱**: 각 앱은 계약 conformance 테스트를 **먼저** 세우고(빨강) 앱 핸들러를 맞춰 통과(초록). 신규 3앱은 계약 v2 conformance가 실패→구현→통과.
- **보안 프로브**: "이 적대적 토큰은 **거부되어야 한다**(401)"를 먼저 assert(프로브가 곧 스펙). 방어 실패=결함 발견.
- **스코어링**: score.mjs는 합성 입력 픽스처(가짜 conformance/security/suite JSON)로 단위 검증 후 실데이터 연결.
- **오케스트레이터**: 언어 1개 스모크로 파이프라인 먼저 검증 후 8언어 확장.

## 8. 게차(Gotchas)

- ⚠️ **authcode+PKCE 전체 플로우는 헤드리스 불가** — `authz-url` S256 오프라인 검증으로 대체(브라우저 로그인 자동화는 범위 밖). refresh/logout은 ROPC 진입.
- ⚠️ **보안 프로브의 claim-level 케이스(expired/wrong-iss/wrong-aud)는 realm 서명 토큰이 필요** — 프로브가 realm 개인키가 없으므로 KC로부터 2번째 client(wrong-aud)·2번째 realm(wrong-iss)·단수명 client(expired) 토큰을 실발급해 주입. alg=none/HS256/미지-kid는 프로브 자체 생성.
- ⚠️ **TLS 프로브는 부분** — 하네스 KC가 컨테이너 내부 http라 실제 인증서 검증 경로를 완전 재현 못 함(문서화된 한계). SSRF는 앱의 리다이렉트 미추종을 관찰.
- ⚠️ **Ruby/Rust/PHP Alpine 네이티브 빌드** — Ruby gem(racc/prism/bigdecimal)·Rust(ring/rustls)·PHP 확장은 Alpine서 `build-base`/`musl-dev` 등 필요. 이미지 크기·빌드시간 증가.
- ⚠️ **점수는 상대·절대 혼합** — 성능은 언어간 상대 백분위(절대 임계 아님), 보안·기능·커버리지는 절대 기준. SCORECARD에 명시.
- ⚠️ **SDK 스위트 집계 재현성** — 각 언어 테스트가 Docker 필요(통합테스트)하면 DinD 또는 호스트 docker.sock 공유 — CI 러너 설정 의존. 통합 제외·단위+커버리지만 집계하는 안전 모드 옵션.

## 9. 완료 기준 (DoD)

- [ ] 계약 v2 문서화 + 8앱 전부 v2 구현(신규 php/rust/ruby 포함) + `docker-compose`·`run.sh`·`verify.sh` 8언어
- [ ] conformance(모든 흐름·5리소스 CRUD·오류·엣지) 8언어 결정적 통과 + 실패 상세 리포트
- [ ] 보안 프로브(§4) 8언어 실행 + 방어율 산출
- [ ] SDK 스위트 집계(커버리지·테스트수·린트) 8언어 수집
- [ ] score.mjs 4차원 가중 스코어링 + `SCORECARD.md`(점수·등급·랭킹·보완 피드백) 생성
- [ ] CI(harness.yml) 8언어+스코어링 잡(야간/수동) + 아티팩트 업로드
- [ ] 로컬 스모크(1~2 언어) + CI 전체 실행 GREEN, 문서(harness/README·CLAUDE.md 하네스 섹션) 갱신
