# Virtual-User Test Harness

폴리글랏 Keycloak SDK(Go/C#/Node/Python/Java)를 위한 **가상 사용자(virtual-user) 부하·회귀 테스트 하네스**. 실제 Keycloak 26.6(`it-realm` — 언어별 통합테스트와 동일 realm)을 Docker Compose로 띄우고, 각 언어 SDK로 작성된 동일 스펙의 샘플 앱(5개 언어 모두 완료)을 [`contract/CONTRACT.md`](contract/CONTRACT.md)의 공통 HTTP 계약으로 노출시켜, k6 기반 드라이버로 동형(isomorphic) 부하 시나리오를 각 언어에 대해 동일하게 재현·비교한다.

각 앱은 그 언어의 **관용 프레임워크**로 SDK를 소비한다 — 따라서 성능 실측은 순수 SDK 비용이 아니라 "SDK-in-idiomatic-app"(프레임워크 오버헤드 포함) 실측이다.

| 언어 | 프레임워크 | 앱 디렉터리 | 호스트 포트 |
|---|---|---|---|
| go | net/http | [`apps/go/`](apps/go/) | 8090 |
| dotnet | ASP.NET Core | [`apps/dotnet/`](apps/dotnet/) | 8091 |
| node | Express 5 | [`apps/node/`](apps/node/) | 8092 |
| python | FastAPI | [`apps/python/`](apps/python/) | 8093 |
| java | Spring Boot | [`apps/java/`](apps/java/) | 8094 |

모든 앱은 컨테이너 **내부 8090**을 사용하고(계약 단순화), 호스트로만 8090~8094로 다르게 매핑한다.

> ⚠️ **앱 빌드 이미지는 Alpine(musl) 베이스를 쓴다.** Debian/glibc 빌드 이미지는 Docker Desktop(Windows) 내장 DNS 프록시가 패키지 레지스트리(nuget/pypi/maven·npm의 Fastly CNAME 체인)를 glibc 리졸버에 실패로 돌려줘 `dotnet restore`/`pip install`/Maven 다운로드가 DNS 오류로 막힌다. musl 리졸버는 동일 환경에서 정상 동작하고 Linux 네이티브 Docker(CI)에서도 문제없어, 호스트별 `extra_hosts`/IP 고정 없이 이식성 있게 동작하는 근본 해결책이다(공유 compose 파일엔 하드코딩 IP가 없다).

## 구성

```
harness/
├─ docker-compose.yml     # keycloak(기본) + app-{go,dotnet,node,python,java}(profile: apps)
├─ keycloak/
│  └─ harness-realm.json  # go/testdata/it-realm-realm.json 재사용(realm import)
├─ contract/
│  └─ CONTRACT.md         # 공통 HTTP 계약(진실 원천) — 모든 언어 앱이 동일 구현
├─ apps/
│  ├─ go/                 # Go 샘플 앱(net/http)
│  ├─ dotnet/             # C# 샘플 앱(ASP.NET Core)
│  ├─ node/               # Node 샘플 앱(Express 5)
│  ├─ python/             # Python 샘플 앱(FastAPI)
│  └─ java/               # Java 샘플 앱(Spring Boot)
├─ driver/                # k6 부하 드라이버
├─ report/                # 결과 리포트(RESULTS.md — 생성물, 미커밋)
└─ run.sh                 # 원커맨드 실행
```

## 사용법

원커맨드 파이프라인 — `run.sh`가 Keycloak 기동(health 대기) → 각 언어 앱 빌드·기동(healthz 대기) → k6 부하(compose 네트워크 내부 컨테이너) → 리포트 취합 → compose down을 순서대로 수행하고, 기능 게이트(checks 100%) 실패 시 비0 종료한다.

```bash
cd harness
./run.sh go                                    # Go 앱만 실행 → report/RESULTS.md (기본값도 go)
./run.sh go dotnet node python java            # 5개 언어 전체를 순차 실행·비교
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

## 계약

모든 언어 샘플 앱은 [`contract/CONTRACT.md`](contract/CONTRACT.md)에 정의된 엔드포인트·요청/응답 스키마·오류 매핑을 동일하게 구현한다(포트만 `APP_PORT`로 상이). k6 드라이버는 이 계약 하나만 알면 모든 언어 앱을 동일하게 구동할 수 있다.
