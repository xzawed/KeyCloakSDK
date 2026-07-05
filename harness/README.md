# Virtual-User Test Harness

폴리글랏 Keycloak SDK(Java/Python/Node/Go, 향후 C#)를 위한 **가상 사용자(virtual-user) 부하·회귀 테스트 하네스**. 실제 Keycloak 26.6(`it-realm` — Java/Python/Node/Go 통합테스트와 동일 realm)을 Docker Compose로 띄우고, 각 언어 SDK로 작성된 동일 스펙의 샘플 앱(Go 우선, 이후 C#/Node/Python/Java)을 [`contract/CONTRACT.md`](contract/CONTRACT.md)의 공통 HTTP 계약으로 노출시켜, k6 기반 드라이버로 동형(isomorphic) 부하 시나리오를 각 언어에 대해 동일하게 재현·비교한다.

## 구성

```
harness/
├─ docker-compose.yml     # keycloak(기본) + app-go(profile: apps)
├─ keycloak/
│  └─ harness-realm.json  # go/testdata/it-realm-realm.json 재사용(realm import)
├─ contract/
│  └─ CONTRACT.md         # 공통 HTTP 계약(진실 원천) — 모든 언어 앱이 동일 구현
├─ apps/go/               # Go 샘플 앱(Task 2)
├─ driver/                # k6 부하 드라이버(Task 3)
├─ report/                # 결과 리포트(Task 4)
└─ run.sh                 # 원커맨드 실행(Task 4)
```

## 사용법

원커맨드 파이프라인 — `run.sh`가 Keycloak 기동(health 대기) → 각 언어 앱 빌드·기동(healthz 대기) → k6 부하(compose 네트워크 내부 컨테이너) → 리포트 취합 → compose down을 순서대로 수행하고, 기능 게이트(checks 100%) 실패 시 비0 종료한다.

```bash
cd harness
./run.sh go                                    # Go 앱 전체 실행 → report/RESULTS.md (기본값도 go)
./run.sh go node python                        # 여러 언어를 순차 실행·비교(언어 인자 나열)
cat report/RESULTS.md                          # 기능 정확성 게이트 + 언어간 성능 실측표
```

결과 `report/RESULTS.md`(및 `report/<lang>.json` k6 요약)는 생성 아티팩트라 커밋하지 않는다(`report/.gitignore`).

수동 단계 실행(디버깅용):

```bash
docker compose up -d keycloak                  # Keycloak만 기동(realm import 포함)
docker compose --profile apps up -d --build    # 언어 샘플 앱까지 기동
docker compose down -v
```

## 계약

모든 언어 샘플 앱은 [`contract/CONTRACT.md`](contract/CONTRACT.md)에 정의된 엔드포인트·요청/응답 스키마·오류 매핑을 동일하게 구현한다(포트만 `APP_PORT`로 상이). k6 드라이버는 이 계약 하나만 알면 모든 언어 앱을 동일하게 구동할 수 있다.
