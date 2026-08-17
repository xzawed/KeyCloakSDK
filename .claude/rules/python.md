---
paths:
  - "python/**"
  - "harness/apps/python/**"
  - "harness/install/consume/python*"
  - ".github/workflows/python-*.yml"
---

# Python 규칙

## 툴체인

가상환경은 `python/.venv`(리포지토리 미커밋). `PY="${KCSDK_PY:-.venv/Scripts/python.exe}"`.

```bash
cd python && "$PY" -m pytest -m "not integration" --cov=keycloak_sdk   # 단위 + 커버리지 게이트 100%
cd python && "$PY" -m pytest -m integration                            # Docker 필요(testcontainers)
cd python && "$PY" -m ruff check src tests examples                    # 보안 S/bandit 포함
cd python && "$PY" -m ruff format --check src tests examples
cd python && "$PY" -m mypy src                                         # strict
cd python && "$PY" -m build                                            # 배포 빌드 검증
```

- POSIX venv 인터프리터는 `.venv/bin/python` — `KCSDK_PY`로 덮어쓴다.
- 배포는 `py-v*` 태그 → PyPI **Trusted Publisher**(OIDC, 저장 시크릿 없음, 사람 승인 게이트).
- 패키지 `keycloak_sdk`(배포명 `keycloak-sdk`)는 PEP 561 `py.typed`를 포함한다.
- ⚠️ **버전 상수를 매니페스트와 중복하지 않는다** — `__version__`은 `importlib.metadata`에서 파생한다. 예전에 `__init__.py`에 하드코딩된 값이 `pyproject.toml`을 따라가지 못해 **게시된 휠이 자신을 틀리게 보고**했고, 스모크 테스트가 같은 상수를 비교하고 있어 초록이었다.

## 게차

- ⚠️ **admin은 세션이 둘이고 그중 하나는 지연 생성된다** — `connection._s`(REST)와 `connection.keycloak_openid.connection._s`(자체 토큰 그랜트). 이 이중 구조가 **하드닝과 정리 양쪽**에 걸린다.
  - **리다이렉트**: python-keycloak sync는 `allow_redirects`를 전달하지 않는다(`raw_get`/`raw_post`가 kwargs를 쿼리스트링으로 흘린다) — 세션의 `resolve_redirects`를 덮는 것이 유일하게 우회 불가능한 지점이다. 바깥만 막으면 첫 admin 호출의 그랜트가 `client_secret`이 실린 POST 바디를 리다이렉트 대상에 그대로 넘긴다. ⚠️ **유출되는 것은 `Authorization` 헤더가 아니다** — requests의 `rebuild_auth`가 교차출처에서 헤더는 떼어내지만 **POST 바디는 307/308에서 보존**되고 거기에 자격증명이 있다. 헤더를 겨냥한 방어로는 못 막는다.
  - **정리**: `aclose()`가 바깥만 닫으면 안쪽 `httpx.AsyncClient`가 열린 채 남아 admin을 쓰는 클라이언트마다 **FD가 하나씩 샌다**(장기 async 서비스에서 EMFILE). auth 전용 경로는 깨끗해서 admin을 태우지 않는 테스트로는 절대 드러나지 않는다. 중첩 실패 시에도 바깥을 닫는 `finally` 계약이 있다.
  - ⚠️ 목을 세울 때 `MagicMock(spec=KeycloakAdmin)`은 중첩 `aclose`를 **동기** MagicMock으로 만든다 — 실제로는 코루틴이라 `AsyncMock`을 명시하지 않으면 프로덕션과 다른 모양을 검증하게 된다.
- ⚠️ **joserfc `KeySet.import_key_set`은 기형 JWKS에서 joserfc 타입도 아닌 stdlib `binascii.Error`를 던진다** — `keycloak_sdk.exceptions`를 잡는 소비자가 **아무것도 잡지 못한다**(§4 위반). `_load_jwks`의 파싱은 `_wrap`이 덮지 않는다(`_wrap`은 전송 오류용이고 이건 응답 **내용** 문제다). sync·async 두 미러 모두 `TokenValidationError`로 변환한다. IdP가 기형 JWKS를 주는 것은 가정이 아니다(프록시 오구성·부분 배포·중간자).
- ⚠️ **JWKS 재조회는 DoS-안전해야 한다** — 서명 위조(`BadSignatureError`)는 재조회를 **유발하지 않고**, kid 미해결(`InvalidKeyIdError`)에만 재조회하며 `_jwks_min_refetch`로 rate-limit한다. 기본값 30초의 근거는 `.claude/rules/security.md`.
