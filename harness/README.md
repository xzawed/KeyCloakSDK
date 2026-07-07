# Virtual-User Test Harness

폴리글랏 Keycloak SDK(Go/C#/Node/Python/Java/PHP/Rust/Ruby — 8개 언어)를 위한 **가상 사용자(virtual-user) 부하·회귀 테스트 + 종합 검증·스코어링 하네스**. 실제 Keycloak 26.6(`it-realm` — 언어별 통합테스트와 동일 realm)을 Docker Compose로 띄우고, 각 언어 SDK로 작성된 동일 스펙의 샘플 앱(8개 언어 모두 완료, [`contract/CONTRACT.md`](contract/CONTRACT.md) v2)을 공통 HTTP 계약으로 노출시켜 두 축으로 검증한다: (1) k6 기반 드라이버로 동형(isomorphic) 부하 시나리오를 실측·비교(레거시 `run.sh`), (2) 계약 conformance·보안 하드닝 프로브·SDK 자체 스위트(단위+커버리지+린트)를 언어별로 실행해 4차원 점수로 집계(`verify.sh` → `report/SCORECARD.md` — 아래 "검증·스코어링" 절 참고).

각 앱은 그 언어의 **관용 프레임워크**로 SDK를 소비한다 — 따라서 성능 실측은 순수 SDK 비용이 아니라 "SDK-in-idiomatic-app"(프레임워크 오버헤드 포함) 실측이다.

| 언어 | 프레임워크 | 앱 디렉터리 | 호스트 포트 |
|---|---|---|---|
| go | net/http | [`apps/go/`](apps/go/) | 8090 |
| dotnet | ASP.NET Core | [`apps/dotnet/`](apps/dotnet/) | 8091 |
| node | Express 5 | [`apps/node/`](apps/node/) | 8092 |
| python | FastAPI | [`apps/python/`](apps/python/) | 8093 |
| java | Spring Boot | [`apps/java/`](apps/java/) | 8094 |
| php | Slim 4 | [`apps/php/`](apps/php/) | 8095 |
| rust | axum | [`apps/rust/`](apps/rust/) | 8096 |
| ruby | Rack(Puma) | [`apps/ruby/`](apps/ruby/) | 8097 |

모든 앱은 컨테이너 **내부 8090**을 사용하고(계약 단순화), 호스트로만 8090~8097로 다르게 매핑한다.

> ⚠️ **앱 빌드 이미지는 Alpine(musl) 베이스를 쓴다.** Debian/glibc 빌드 이미지는 Docker Desktop(Windows) 내장 DNS 프록시가 패키지 레지스트리(nuget/pypi/maven·npm의 Fastly CNAME 체인)를 glibc 리졸버에 실패로 돌려줘 `dotnet restore`/`pip install`/Maven 다운로드가 DNS 오류로 막힌다. musl 리졸버는 동일 환경에서 정상 동작하고 Linux 네이티브 Docker(CI)에서도 문제없어, 호스트별 `extra_hosts`/IP 고정 없이 이식성 있게 동작하는 근본 해결책이다(공유 compose 파일엔 하드코딩 IP가 없다).

## 구성

```
harness/
├─ docker-compose.yml     # keycloak(기본) + app-{go,dotnet,node,python,java,php,rust,ruby}(profile: apps)
├─ keycloak/
│  └─ harness-realm.json  # go/testdata/it-realm-realm.json 재사용(realm import)
├─ contract/
│  └─ CONTRACT.md         # 공통 HTTP 계약(진실 원천, v2) — 모든 언어 앱이 동일 구현
├─ apps/
│  ├─ go/                 # Go 샘플 앱(net/http)
│  ├─ dotnet/             # C# 샘플 앱(ASP.NET Core)
│  ├─ node/               # Node 샘플 앱(Express 5)
│  ├─ python/             # Python 샘플 앱(FastAPI)
│  ├─ java/               # Java 샘플 앱(Spring Boot)
│  ├─ php/                # PHP 샘플 앱(Slim 4)
│  ├─ rust/               # Rust 샘플 앱(axum)
│  └─ ruby/               # Ruby 샘플 앱(Rack/Puma)
├─ driver/                # k6 부하 드라이버(scenarios.js)
├─ conformance/
│  └─ conformance.mjs     # 계약 준수 검사(CONTRACT.md 엔드포인트별 assert) → signals/<lang>.conformance.json
├─ security/
│  └─ probe.mjs           # JWT 검증 하드닝 공격 프로브(alg=none·HS/RS confusion·flood 등) → signals/<lang>.security.json
├─ suites/
│  ├─ run-suite.sh        # 언어별 suites/<lang>.sh 실행 오케스트레이터
│  └─ <lang>.sh           # 각 SDK 자체 단위테스트+커버리지+린트를 툴체인 이미지에서 실행 → signals/<lang>.suite.json
├─ report/
│  ├─ score.mjs           # 4차원 가중 스코어링 → SCORECARD.md
│  ├─ aggregate.mjs       # (레거시 run.sh용) k6 결과 → RESULTS.md
│  └─ signals/            # conformance/security/suite 신호 JSON(생성물, 미커밋)
├─ run.sh                 # 레거시: k6 성능비교만(원커맨드) → report/RESULTS.md
└─ verify.sh              # 종합 파이프라인: KC→앱→conformance+security+k6→suites→score → report/SCORECARD.md
```

## 사용법 (레거시 — k6 성능비교만)

원커맨드 파이프라인 — `run.sh`가 Keycloak 기동(health 대기) → 각 언어 앱 빌드·기동(healthz 대기) → k6 부하(compose 네트워크 내부 컨테이너) → 리포트 취합 → compose down을 순서대로 수행하고, 기능 게이트(checks 100%) 실패 시 비0 종료한다. **k6 성능 실측·비교만 필요할 때** 쓴다 — conformance/security/suite/스코어링까지 포함한 종합 검증은 아래 `verify.sh`를 쓴다.

```bash
cd harness
./run.sh go                                    # Go 앱만 실행 → report/RESULTS.md (기본값도 go)
./run.sh go dotnet node python java            # 5개 언어(레거시 대상)를 순차 실행·비교 — 인자로 8개 아무 언어나 가능
cat report/RESULTS.md                          # 기능 정확성 게이트 + 언어간 성능 실측표
```

`report/RESULTS.md`는 (1) **기능 정확성 게이트**(각 언어 checks PASS율 — 100% 요구, 미달 시 비0 종료)와 (2) **성능 실측 비교표**(validate p95·admin CRUD p95·RPS·오류율)를 함께 산출한다. 성능 수치는 실측·비교용(임계값 강제 아님)이며 앞서 언급한 대로 프레임워크 오버헤드를 포함한다 — 호스트/부하에 따라 달라지는 상대 비교값이다.

결과 `report/RESULTS.md`(및 `report/<lang>.json` k6 요약)는 생성 아티팩트라 커밋하지 않는다(`report/.gitignore`).

수동 단계 실행(디버깅용):

```bash
docker compose up -d keycloak                  # Keycloak만 기동(realm import 포함)
docker compose --profile apps up -d --build    # 언어 샘플 앱까지 기동
docker compose down -v
```

## 검증·스코어링 (verify.sh)

`verify.sh`는 k6 성능비교를 포함하되 그보다 넓은 **종합 검증·점수책정 파이프라인**이다 — 각 언어 SDK가 계약을 올바르게 구현하는지(기능)·JWT 검증을 안전하게 하는지(보안)·SDK 자체 테스트가 그린인지(커버리지·품질)·계약 표면을 얼마나 완전히 구현했는지(동형성 근사, 성능은 후속)를 언어중립 채점기로 집계해 `report/SCORECARD.md`를 만든다.

```bash
cd harness
./verify.sh go dotnet node python java php rust ruby   # 8개 언어 전체(기본값도 이 8개)
./verify.sh go node                                     # 로컬 스모크용으로 1~2개 언어만
cat report/SCORECARD.md
```

파이프라인 단계(언어별로 반복): Keycloak 1회 기동(health 대기) → 각 언어 앱 빌드·기동(healthz 대기) → **conformance**([`conformance/conformance.mjs`](conformance/conformance.mjs), CONTRACT.md v2 엔드포인트별 assert) → **security**([`security/probe.mjs`](security/probe.mjs), JWT 검증 하드닝 공격 프로브 — alg=none·HS/RS confusion·미지/누락 kid·malformed·flood 등) → **k6 성능**(`driver/scenarios.js`, compose 네트워크 내부) → 앱 정지 → 전 언어 완료 후 **suites**([`suites/run-suite.sh`](suites/run-suite.sh), 각 SDK 자체 단위테스트+커버리지+린트를 언어 툴체인 이미지에서 실행 — 재구현 아님) → **score**([`report/score.mjs`](report/score.mjs)). 한 언어의 앱 빌드/헬스체크/프로브 실패는 `report/signals/<lang>.error.json`으로 격리되고 나머지 언어는 계속 진행한다(`|| true` 전면 적용).

### 4차원 스코어카드

| 차원 | 가중치 | 산출 신호 | 산식 |
|---|---|---|---|
| 기능(functional) | 30% | `signals/<lang>.conformance.json` `{passed,failed,checks[]}` | `passed / (passed+failed) * 100` |
| 보안(security) | 30% | `signals/<lang>.security.json` `{defended,total,probes[]}` | `defended / total * 100` |
| 커버리지·품질(coverage) | 20% | `signals/<lang>.suite.json` `{coverageLine,coverageBranch,lintClean,ran,unit}` | branch가 실측(>0)된 언어만 `line*0.6+branch*0.3+lint*0.1`, 미측정 언어는 `line*0.9+lint*0.1`로 폴백(미측정을 0%로 벌점하지 않기 위함) |
| 성능·동형성(perfiso) | 20% | conformance 통과율(근사) | 현재는 `functional`과 동일값(§주의 참고) |

종합점수 = 4차원의 가중합, 등급은 `overall≥90 → A`·`≥80 → B`·`≥70 → C`·그 외 `D`. `report/SCORECARD.md`는 언어를 종합점수 내림차순으로 정렬한 표 + 언어별 규칙기반 보완 피드백(어느 프로브가 실패했는지, 어느 커버리지가 부족한지 등)을 담는다.

> ⚠️ **성능·동형성(20%)은 아직 k6 실측이 연동되지 않았다.** 현재는 계약 엔드포인트 구현 완전성(conformance 통과율)의 근사치로 대체돼 있다(`score.mjs`의 `perf: null` 하드코딩) — k6 `report/<lang>.summary.json`을 상대 백분위로 반영하는 것은 후속 작업이다. 결측 신호(앱 빌드 실패 등)는 크래시하지 않고 0점 처리된다.

### 신호 파일 (`report/signals/`)

`verify.sh`/`suites/run-suite.sh`가 언어별로 쓰고 `score.mjs`가 읽는 생성 아티팩트(미커밋, `report/.gitignore`):

- `<lang>.conformance.json` — conformance.mjs 산출(§기능)
- `<lang>.security.json` — probe.mjs 산출(§보안)
- `<lang>.suite.json` — `suites/<lang>.sh` 마지막 줄 JSON(§커버리지·품질). `suites/<lang>.sh`가 없거나 규약(마지막 줄 JSON 한 줄) 위반 시 `{"ran":false}`로 폴백.
- `<lang>.error.json` — 앱 빌드/기동 실패 시 격리 기록(해당 언어는 conformance/security/k6가 스킵되고 커버리지·품질만 반영될 수 있음).

### 실행 범위 — CI 1차, 로컬은 스모크

8언어 전체 `verify.sh` 실행은 각 언어 툴체인 이미지 pull+의존성 설치+테스트까지 포함해 무겁다(수십 분). **CI가 1차 실행 주체**다 — `.github/workflows/harness.yml`의 `score-all` 잡이 야간(`schedule` 03:00 UTC)·수동(`workflow_dispatch`)에 8언어 전체를 돌리고 `SCORECARD.md`+`report/signals/`를 아티팩트로 업로드한다(`timeout-minutes: 60`). **로컬(특히 Windows Docker Desktop)은 1~2개 언어 스모크**로 제한하는 것을 권장한다 — Alpine(musl) 베이스(위 경고 참고)가 DNS 게차는 해결하지만, 8언어 전체 빌드+테스트는 로컬 반복개발 루프에 비효율적으로 무겁다.

## 계약

모든 언어 샘플 앱은 [`contract/CONTRACT.md`](contract/CONTRACT.md)에 정의된 엔드포인트·요청/응답 스키마·오류 매핑을 동일하게 구현한다(포트만 `APP_PORT`로 상이, v2에서 auth 확장·5 admin 리소스·오류 경로 추가). k6 드라이버·conformance·security 프로브 모두 이 계약 하나만 알면 모든 언어 앱을 동일하게 구동·검증할 수 있다.
