# 기여 가이드 (CONTRIBUTING)

Keycloak polyglot SDK(Java + Python)에 기여할 때의 **검증 워크플로 단일 진실 원천**이다. 머지 전 통과해야 하는 게이트, 로컬 실행 명령, 테스트 추가법, PR 체크리스트를 한곳에 모았다. (프로젝트 구조·아키텍처는 [CLAUDE.md](CLAUDE.md), 배포는 [DEPLOY.md](DEPLOY.md), 검증 이력은 [docs/governance/](docs/governance/) 참고.)

> 이 저장소의 머신 전용 절대경로 명령(이 개발자의 JDK/venv 경로)은 [CLAUDE.md](CLAUDE.md)에 있다. 아래는 **다른 머신에서도 통하는 이식성 있는 명령**이다.

---

## 1. 머지 전 반드시 통과해야 하는 게이트

CI(`.github/workflows/ci.yml`, `python-ci.yml`)가 push/PR마다 자동 실행한다. **아래가 하나라도 red면 머지하지 않는다.**

### Java (`mvn -f java/pom.xml verify`)
| 게이트 | 도구 | 강제 방식 |
|---|---|---|
| 컴파일 | `maven-compiler` | 실패 시 빌드 red |
| 단위테스트 (117) | surefire (`*Test`) | 1개라도 실패 시 red |
| 통합테스트 (6, Docker) | failsafe (`*IT`, Testcontainers 실제 Keycloak 26.6) | CI `integration` 잡에서 실행 |
| **커버리지 라인≥90%/브랜치≥85%** | JaCoCo `jacoco:check` (verify 바인딩) | 미달 시 빌드 red |
| 의존성 수렴·Java/Maven 버전 | maven-enforcer | 충돌/버전 미달 시 red |

### Python (`python/`)
| 게이트 | 명령 | 강제 방식 |
|---|---|---|
| 린트 (보안 S/bandit 포함 확장 룰셋) | `ruff check src tests examples` | 위반 시 잡 red |
| 포맷 | `ruff format --check src tests examples` | 미포맷 시 red |
| **커버리지 로직모듈 100%** | `pytest -m "not integration" --cov=keycloak_sdk` | `pyproject [tool.coverage.report] fail_under=100` — 미달 시 red |
| 타입 (strict) | `mypy src` | 오류 시 red |
| 통합테스트 (11, Docker) | `pytest -m integration` | CI `integration` 잡에서 실행 |

> ⚠️ **네트워크 경계 모듈은 커버리지에서 omit**된다(Java: `AuthClient`/`AdminClient`, Python: `auth.py`/`admin/__init__.py` + aio 대응). 이들은 단위 커버리지 하한이 없고 **통합테스트로만** 검증되므로, 경계 코드를 바꾸면 반드시 통합테스트를 함께 돌린다.

---

## 2. 로컬 실행 (이식성 명령)

### Java (JDK 17+ · Maven 3.9+ 필요)
```bash
mvn -f java/pom.xml verify                                   # 전체: 단위+커버리지 게이트 (Docker 있으면 통합까지)
mvn -f java/pom.xml test -DskipITs=true                      # 단위테스트만 (커버리지 게이트 포함)
mvn -f java/pom.xml test -pl <module> -Dtest=<Class>#<method>  # 단일 테스트
```

### Python (3.10+ · Docker는 통합테스트에만 필요)
```bash
cd python
python -m pip install -e ".[dev]"
ruff check src tests examples          # ① 린트(보안 스캔 포함)
ruff format --check src tests examples # ② 포맷
mypy src                               # ③ 타입(strict)
pytest -m "not integration" --cov=keycloak_sdk   # ④ 단위 + 커버리지 100% 게이트
pytest -m integration                  # ⑤ 통합(Docker 필요)
```
`ruff format`(‑‑check 없이)으로 포맷을 자동 적용할 수 있다.

---

## 3. 테스트 추가법

| | Java | Python |
|---|---|---|
| 단위테스트 위치 | `java/<module>/src/test/java/...` | `python/tests/unit/` (async는 `tests/unit/aio/`) |
| 통합테스트 위치 | `java/keycloak-sdk/src/test/java/...` 파일명 `*IT.java` | `python/tests/integration/` (async는 `*_async_it.py`) |
| 네이밍 규약 | 단위 `*Test`, 통합 `*IT` (surefire/failsafe 분리 기준) | `def test_*` / `async def test_*`, 통합은 `@pytest.mark.integration` |
| 실 Keycloak fixture | `java/keycloak-sdk/src/test/resources/it-realm-realm.json` | 동일 파일 재사용 (`tests/integration/conftest.py`) |

- **JWT·보안 관련 코드**를 바꾸면 네거티브 테스트를 함께 추가한다(alg=none·미서명·알고리즘 혼동·iss/aud·클록스큐 — 기존 `JwtValidatorTest`/`test_jwt.py` 패턴 참고). 실서명 기반의 **비-vacuous** 단언으로 작성해 우연한 통과를 배제한다.
- 커버리지 100%(Python)/90·85%(Java) 게이트를 유지하도록 새 분기에 테스트를 붙인다.

---

## 4. PR 체크리스트

- [ ] feature 브랜치에서 작업(main 직접 커밋 금지)
- [ ] 위 **1절 게이트**를 로컬에서 모두 green으로 확인
- [ ] 새 코드에 테스트 추가(커버리지 게이트 유지), 보안 코드는 네거티브 테스트 포함
- [ ] 하위 라이브러리 타입을 공개 API에 노출하지 않음(파사드 뒤로 은닉 — Java/Python 공통 규칙)
- [ ] 문서 최신화: 구조/명령/테스트 수 변경 시 [CLAUDE.md](CLAUDE.md)·해당 `README`·[docs/](docs/) 동기화
- [ ] (거버넌스 태스크면) [docs/governance/verification-log*.md](docs/governance/)에 게이트 판정 기록

---

## 5. ⚠️ 브랜치 보호 (저장소 소유자 조치 필요)

CI가 도는 것과 **CI가 머지를 막는 것**은 다르다. GitHub → Settings → Branches → `main` 보호 규칙에서 아래를 **required status checks**로 지정해야 red인 PR의 머지가 실제로 차단된다(저장소 파일로는 설정 불가):
- Java: `build` (matrix), `integration`
- Python: `test` (matrix), `integration`

> path 필터(`java/**`·`python/**`)로 스킵된 잡을 required로 지정하면 pending으로 남을 수 있으니, 필요 시 필터를 조정하거나 required 목록을 언어별로 관리한다.

---

## 6. advisory 품질 로드맵 (선택 · 아직 CI 미강제)

커버리지는 "코드가 실행됐다"만 보장하고 "테스트가 결함을 잡는다"는 보장하지 않는다. 아래는 그 간극을 메우는 권장 도구다. 도입 시 먼저 **advisory(비차단)**로 운영하고 안정화 후 게이트화한다.

- **뮤테이션 테스트**
  - Java: [pitest](https://pitest.org) — `org.pitest:pitest-maven`. ⚠️ 이 프로젝트는 **JUnit 6.1.1**을 쓰므로 `pitest-junit5-plugin`의 JUnit Platform 6 호환을 먼저 확인해야 한다(현재 미검증).
  - Python: [mutmut](https://github.com/boxed/mutmut) — 예) `pip install mutmut && mutmut run --paths-to-mutate src/keycloak_sdk/jwt.py`. ⚠️ **네이티브 Windows 미지원(WSL 필요)** — CI(ubuntu)나 WSL에서 실행.
  - 우선 적용 대상: `jwt.py`/`JwtValidator` 등 **보안 핵심 모듈**.
- **정적분석 확장**: Python `ruff`는 이미 보안(S/bandit)·버그성(B)·현대화(UP) 룰을 강제한다. Java는 현재 enforcer(의존성)만 강제 — [SpotBugs](https://spotbugs.github.io)·Checkstyle·Spotless 중 하나를 advisory 프로파일로 검토.
- **mypy 범위 확장**: 현재 `mypy src`만 strict. `tests`까지 확장하려면 테스트 타입 정리가 선행되어야 한다.
