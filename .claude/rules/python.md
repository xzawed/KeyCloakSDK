---
paths:
  - "python/**"
  - "harness/apps/python/**"
  - "harness/install/consume/python*"
  - ".github/workflows/python-*.yml"
---

# Python 규칙

## 툴체인 (빌드 명령)

가상환경은 `python/.venv`에 있다(리포지토리에 커밋 안 함). 명령은 `python/`에서 실행하거나 절대경로의 venv 인터프리터를 직접 호출한다:
```bash
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m pytest -m "not integration" --cov=keycloak_sdk   # 단위테스트 224개 + 커버리지 게이트 100%
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m pytest -m integration            # 통합테스트 11개(Docker 필요, testcontainers)
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m ruff check src tests examples     # 린트(보안 S/bandit 포함 확장 룰셋)
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m ruff format --check src tests examples  # 포맷 검사
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m mypy src                          # 정적 타입 검사(strict)
```
> 다른 PC에서는 `KCSDK_TOOLS`(포터블 툴 상위 디렉터리, 기본 `$HOME/tools`)·`KCSDK_PY`(venv 인터프리터 — POSIX는 `.venv/bin/python`)를 덮어쓰거나, 이미 PATH에 있으면 프리픽스를 생략한다. 설치·진단은 [development-setup.md](../../docs/guides/development-setup.md)(`node scripts/doctor.mjs python`).
- 로컬 배포 빌드 검증(업로드 없이): `cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m build` → `dist/keycloak_sdk-0.1.0-py3-none-any.whl` + `.tar.gz` 생성 확인
- 실제 PyPI 배포는 로컬에서 실행하지 않는다 — `py-v*` 태그 push 시 `.github/workflows/python-release.yml`에서 PyPI Trusted Publisher(OIDC, 저장 시크릿 없음)로 실행(사람 승인 게이트)
- 패키지 `keycloak_sdk`(배포명 `keycloak-sdk`)는 PEP 561 `py.typed` 마커를 포함 — 소비자 측 mypy도 타입 검사 가능

## 게차

- ⚠️ **(Python) admin의 "세션이 둘"은 정리(close) 경로에도 그대로 적용된다 — async에서 바깥만 닫으면 FD가 샌다.** 아래 리다이렉트 게차가 말하는 그 이중 구조(`connection` · 지연 생성되는 `connection.keycloak_openid.connection`)는 하드닝뿐 아니라 `aclose()`에서도 둘 다 다뤄야 한다. 게시된 `0.1.0rc1`을 실 Keycloak에 대해 돌려 실측한 결함이다: `AsyncAdminClient.aclose()`가 바깥 `ConnectionManager`만 닫아 안쪽 토큰그랜트 `httpx.AsyncClient`가 `is_closed=False`로 남았고, "unclosed transport"/"unclosed socket" ResourceWarning과 함께 admin을 쓰는 클라이언트마다 FD가 하나씩 샜다(장기 async 서비스에서 EMFILE). **auth 전용 클라이언트는 깨끗했다** — 그래서 admin을 태우지 않는 테스트로는 절대 드러나지 않는다. 회귀 테스트: `tests/unit/aio/test_admin_client.py`의 `test_aclose_also_closes_the_nested_token_grant_connection`(+ 중첩 실패 시에도 바깥을 닫는 `finally` 계약). ⚠️ 목을 세울 때 `MagicMock(spec=KeycloakAdmin)`은 중첩 `aclose`를 **동기** MagicMock으로 자동 생성한다 — 실제로는 코루틴 함수라 `AsyncMock`으로 명시하지 않으면 프로덕션과 다른 모양의 목을 검증하게 된다.

- ⚠️ **(Python) 버전 상수를 매니페스트와 중복해 두지 말 것.** `keycloak_sdk.__version__`은 `importlib.metadata`에서 파생한다. 예전에는 `__init__.py`에 `"0.1.0"`이 하드코딩돼 있었고 `pyproject.toml`이 `0.1.0rc1`로 범프됐을 때 따라가지 못해, **게시된 휠이 자신을 `0.1.0`으로 보고**했다(스모크 테스트도 같은 상수를 비교하고 있어 초록이었다 — 실배포 검증에서 발견). 아홉 언어 중 이 중복이 있던 것은 Python뿐이다(Ruby `VERSION`은 gemspec이 읽는 SSOT 자체라 중복이 아니다).

- ⚠️ **(Python) python-keycloak sync는 `allow_redirects`를 전달하지 않고, admin은 세션이 **둘**이며 그중 하나는 지연 생성된다.** `raw_get`/`raw_post`가 kwargs를 `params=`(쿼리스트링)로 흘려보내므로 호출 시점에 플래그를 넘길 수단이 없다 — 세션의 `resolve_redirects`를 덮는 것이 유일하게 우회 불가능한 지점이다. ⚠️ **admin은 `connection._s`(REST)와 `connection.keycloak_openid.connection._s`(자체 토큰 그랜트) 두 세션을 갖고, 후자는 첫 접근 때 생성된다** — 바깥만 막으면 첫 admin 호출의 그랜트가 `client_secret`이 실린 POST 바디를 리다이렉트 대상에 그대로 넘긴다(실측). ⚠️ 유출되는 것은 `Authorization` 헤더가 아니다 — requests의 `rebuild_auth`가 교차출처에서 그 헤더는 떼어내지만 **POST 바디는 307/308에서 그대로 보존**하며 거기에 자격증명이 있다(헤더를 겨냥한 방어는 이걸 못 막는다). 근거: `_internal/redirects.py`·`tests/unit/test_redirects.py`.

- ⚠️ **(Python) joserfc `KeySet.import_key_set`은 기형 JWKS에서 joserfc 타입도 아닌 stdlib `binascii.Error`를 던진다.** base64url이 아닌 modulus가 오면 이 예외가 SDK 경계를 그대로 뚫고 나가, `keycloak_sdk.exceptions`를 잡는 소비자는 **아무것도 잡지 못한다**(§4 위반). `_load_jwks`의 파싱은 `_wrap`이 덮지 않는다 — `_wrap`은 전송 오류용이고 이건 **응답 내용** 문제다. sync·async 두 미러 모두 `TokenValidationError`로 변환한다. IdP가 기형 JWKS를 주는 것은 가정이 아니다(프록시 오구성·부분 배포·중간자). 근거: `test_auth.py`·`aio/test_auth.py`의 `test_malformed_jwks_yields_sdk_error_not_a_raw_library_exception`.

위 두 건 외의 Python 관련 게차(JWKS DoS-안전 재조회·admin 타임아웃/자원정리 등)는 태그 없는 프로젝트 공통 항목이라 루트 `CLAUDE.md`의 `## 핵심 게차` 섹션에 전문이 남아있다.
