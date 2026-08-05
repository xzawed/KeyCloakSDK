# Keycloak Python SDK async 변형 구현 계획 (WBS)

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 sync `keycloak_sdk`에 python-keycloak의 `a_*` 비동기 메서드를 감싼 **`keycloak_sdk.aio` async 미러**(auth+admin, sync와 완전 대칭)를 순수 추가한다.

**Architecture:** 신규 `aio/` 서브패키지에 `AsyncKeycloakClient`/`AsyncAuthClient`/`AsyncAdminClient` + async 리소스 파사드. 값 타입·예외·설정·PKCE·마스킹·**`JwtValidator`(sync 검증 로직)** 는 `keycloak_sdk.*`에서 재사용. async는 얇은 `await` 래퍼 + async 예외 변환.

**Tech Stack:** Python 3.10+, python-keycloak>=7.1(`a_*`), joserfc, pytest + pytest-asyncio + `testcontainers[keycloak]`, mypy.

## Global Constraints

값은 [async 설계 스펙](../specs/2026-07-03-keycloak-python-async-design.md)에서 그대로. 모든 태스크 암묵 포함.

- **순수 추가**: sync API(`keycloak_sdk.auth/admin/client`) 변경 금지. 기존 130 테스트 무회귀.
- **네임스페이스**: `keycloak_sdk.aio` 서브모듈. `from keycloak_sdk.aio import AsyncKeycloakClient`.
- **재사용**: 값타입(`TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationUrl`)·예외(`keycloak_sdk.exceptions`)·`KeycloakConfig`·`OidcEndpoints`·PKCE·`_internal.secrets.mask`·`JwtValidator`(sync)·`TokenSignatureError`.
- **동형**: 같은 메서드명·값타입·예외. `authorization_url`은 네트워크 없어 **동기 메서드**(async 아님). 나머지 흐름은 `async def`.
- **보안**: 마스킹, TLS 검증 기본 on, JWT 하드닝(JwtValidator 재사용으로 일관: alg 핀닝·none 거부·iss 정확일치·aud 포함검사·skew·키회전 재시도).
- **예외**: 공개 시그니처에 `keycloak.exceptions.*` 미노출 — async 경계에서 SDK 예외로 변환.
- **커버리지(G3)**: async 리소스 파사드 + `acall` ≥90/85. 네트워크 경계 `aio/auth.py`·`aio/admin/__init__.py`는 커버리지 omit(pyproject). `mypy --strict` 유지.
- **툴체인**: `/d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m <pytest|mypy|pip>` (from `python/`). 커밋 `git add <files> && git commit -m`(never -am). 브랜치 `feature/python-async`, NO push.
- **pytest-asyncio**: dev 의존 추가, `asyncio_mode = "auto"`(async 테스트 함수 자동 실행).

---

## WBS 개요

| WBS | 작업 | 산출물 | Dep |
|---|---|---|---|
| 1 | 기반 | pytest-asyncio + aio 골격 + 커버리지 omit | — |
| 2 | AsyncAuthClient | 인증 흐름 async | 1 |
| 3 | admin acall + AsyncAdminClient | 관리 파사드 async | 1 |
| 4 | AsyncKeycloakClient | 통합 진입점 async | 2,3 |
| 5 | 통합 테스트 | async E2E | 4 |
| 6 | 문서·예제 | README/CLAUDE async 섹션 | 4 |

---

## 파일 구조
```
python/src/keycloak_sdk/aio/
├─ __init__.py            # AsyncKeycloakClient export
├─ auth.py                # AsyncAuthClient (커버리지 omit)
├─ admin/
│  ├─ __init__.py         # AsyncAdminClient (커버리지 omit)
│  ├─ _translate.py       # acall(awaitable)
│  ├─ users.py clients.py realms.py roles.py groups.py
├─ (client.py 는 __init__.py에 포함하거나 별도)
python/tests/unit/aio/    # test_*.py (AsyncMock)
python/tests/integration/ # test_*_async_it.py
```

---

# Task 1: 기반 (pytest-asyncio + aio 골격)

**Files:** Modify `python/pyproject.toml`; Create `python/src/keycloak_sdk/aio/__init__.py`, `python/tests/unit/aio/__init__.py`

**Interfaces:** Produces: `keycloak_sdk.aio` 임포트 가능(빈 패키지), pytest-asyncio 설치·설정.

- [ ] **Step 1: pyproject 수정** — `[project.optional-dependencies].dev`에 `pytest-asyncio>=0.24` 추가. `[tool.pytest.ini_options]`에 `asyncio_mode = "auto"` 추가. `[tool.coverage.run].omit`에 `*/aio/auth.py`, `*/aio/admin/__init__.py` 추가.
- [ ] **Step 2: 패키지 골격** — `aio/__init__.py`(우선 빈 docstring), `aio/admin/__init__.py` 자리표시는 Task 3, 여기선 `aio/__init__.py`만. `tests/unit/aio/__init__.py`(빈 파일).
- [ ] **Step 3: 설치·검증** — Run: `... -m pip install -e ".[dev]"` 후 `... -m python -c "import keycloak_sdk.aio"`. `... -m pytest -m "not integration" -q`(기존 무회귀). Expected: 성공.
- [ ] **Step 4: Commit** — `git add python/pyproject.toml python/src/keycloak_sdk/aio/__init__.py python/tests/unit/aio/__init__.py && git commit -m "build(py-aio): pytest-asyncio + aio 패키지 골격 (WBS 1)"`

---

# Task 2: AsyncAuthClient

**Files:** Create `python/src/keycloak_sdk/aio/auth.py` · Test `python/tests/unit/aio/test_auth.py`

**Interfaces:**
- Consumes: `KeycloakConfig`, `OidcEndpoints`, `TokenSet`, `ValidatedToken`, `IntrospectionResult`, `AuthorizationUrl`(sync auth의 것 — 공유 위해 `keycloak_sdk.auth`에서 import), `JwtValidator`, `TokenSignatureError`, 예외들, PKCE 헬퍼, `mask`. python-keycloak `KeycloakOpenID`.
- Produces: `AsyncAuthClient(config, endpoints, openid=None)`. 동기 `authorization_url(redirect_uri) -> AuthorizationUrl`. `async def client_credentials_token()`/`exchange_code(code, redirect_uri, code_verifier)`/`refresh(refresh_token)`/`logout(refresh_token)`/`introspect(token)`/`validate(access_token)`. 내부 `async def _awrap(awaitable)` 예외 변환, `async def _aload_jwks(force=False)` JWKS 캐시.

> ⚠️ `AuthorizationUrl` 및 PKCE 생성이 sync `keycloak_sdk.auth`에 있다면 그대로 import해 재사용(중복 금지). 없으면 공유 위치(`keycloak_sdk/_internal` 또는 `tokens`)로 이동. 구현자는 sync `auth.py`를 읽고 재사용 지점을 확정한다.

- [ ] **Step 1: 실패 테스트** (AsyncMock)

```python
# tests/unit/aio/test_auth.py
import time
import pytest
from unittest.mock import AsyncMock, MagicMock
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.oidc import OidcEndpoints
from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.exceptions import KeycloakAuthError

def _client(openid):
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app", client_secret="s")
    return AsyncAuthClient(c, OidcEndpoints.for_realm(c), openid=openid)

async def test_client_credentials_maps_tokenset():
    openid = MagicMock()
    openid.a_token = AsyncMock(return_value={"access_token": "a", "expires_in": 300, "token_type": "Bearer"})
    ts = await _client(openid).client_credentials_token()
    assert ts.access_token == "a"
    openid.a_token.assert_awaited_once()

async def test_awrap_translates_auth_error():
    from keycloak.exceptions import KeycloakAuthenticationError
    openid = MagicMock()
    openid.a_token = AsyncMock(side_effect=KeycloakAuthenticationError("bad", response_code=401))
    with pytest.raises(KeycloakAuthError):
        await _client(openid).client_credentials_token()
```

- [ ] **Step 2: 실패 확인** — Run: `... -m pytest tests/unit/aio/test_auth.py` · Expected: ImportError.

- [ ] **Step 3: 구현** (sync `auth.py`를 async로 미러; python-keycloak `a_*` 실제 시그니처 확인)

```python
# src/keycloak_sdk/aio/auth.py
"""AsyncAuthClient — python-keycloak KeycloakOpenID의 a_* 비동기 메서드 래핑."""
from __future__ import annotations
import time
from typing import Any, Awaitable, TypeVar
from keycloak import KeycloakOpenID
from keycloak.exceptions import KeycloakError
from ..config import KeycloakConfig
from ..oidc import OidcEndpoints
from ..tokens import TokenSet, ValidatedToken, IntrospectionResult
from ..auth import AuthorizationUrl, _generate_pkce_pair  # 재사용(sync auth.py의 실제 심볼)
from ..jwt import JwtValidator
from ..exceptions import KeycloakAuthError, KeycloakTransportError, TokenSignatureError, TokenValidationError

T = TypeVar("T")

class AsyncAuthClient:
    def __init__(self, config: KeycloakConfig, endpoints: OidcEndpoints,
                 openid: KeycloakOpenID | None = None) -> None:
        self._config = config
        self._endpoints = endpoints
        self._openid = openid or KeycloakOpenID(
            server_url=config.server_url, realm_name=config.realm,
            client_id=config.client_id, client_secret_key=config.client_secret,
            verify=True, timeout=int(config.read_timeout))
        self._jwks: Any = None

    async def _awrap(self, awaitable: Awaitable[T]) -> T:
        try:
            return await awaitable
        except KeycloakError as e:
            code = getattr(e, "response_code", None)
            if code is None:
                raise KeycloakTransportError(str(e)) from e
            raise KeycloakAuthError(str(e), error=None) from e

    def authorization_url(self, redirect_uri: str) -> AuthorizationUrl:
        # ⚠️ 네트워크 없이 endpoints에서 직접 조립(sync는 openid.auth_url을 쓰지만
        # 그건 well_known() 네트워크를 유발할 수 있어 async 이벤트 루프를 블로킹 → 회피).
        import secrets as _s
        from urllib.parse import urlencode
        verifier, challenge = _generate_pkce_pair()
        state, nonce = _s.token_urlsafe(16), _s.token_urlsafe(16)
        params = urlencode({
            "response_type": "code", "client_id": self._config.client_id,
            "redirect_uri": redirect_uri, "scope": " ".join(self._config.scopes),
            "state": state, "nonce": nonce,
            "code_challenge": challenge, "code_challenge_method": "S256"})
        url = f"{self._endpoints.authorization}?{params}"
        return AuthorizationUrl(url=url, code_verifier=verifier, state=state, nonce=nonce)

    async def client_credentials_token(self) -> TokenSet:
        issued = time.time()
        resp = await self._awrap(self._openid.a_token(
            grant_type="client_credentials", scope=" ".join(self._config.scopes)))
        return TokenSet.from_response(resp, issued_at=issued)

    async def exchange_code(self, code: str, redirect_uri: str, code_verifier: str) -> TokenSet:
        issued = time.time()
        resp = await self._awrap(self._openid.a_token(
            grant_type="authorization_code", code=code,
            redirect_uri=redirect_uri, code_verifier=code_verifier))
        return TokenSet.from_response(resp, issued_at=issued)

    async def refresh(self, refresh_token: str) -> TokenSet:
        issued = time.time()
        resp = await self._awrap(self._openid.a_refresh_token(refresh_token))
        return TokenSet.from_response(resp, issued_at=issued)

    async def logout(self, refresh_token: str) -> None:
        await self._awrap(self._openid.a_logout(refresh_token))

    async def introspect(self, token: str) -> IntrospectionResult:
        data = await self._awrap(self._openid.a_introspect(token))
        return IntrospectionResult(active=bool(data.get("active")),
                                   username=data.get("username"), client_id=data.get("client_id"))

    async def _aload_jwks(self, force: bool = False) -> Any:
        if self._jwks is None or force:
            from joserfc.jwk import KeySet
            certs = await self._awrap(self._openid.a_certs())
            self._jwks = KeySet.import_key_set(certs)
        return self._jwks

    async def validate(self, access_token: str) -> ValidatedToken:
        validator = JwtValidator(issuer=self._endpoints.issuer, audience=self._config.client_id,
                                 clock_skew=self._config.clock_skew)
        try:
            return validator.validate(access_token, await self._aload_jwks())
        except TokenSignatureError:
            return validator.validate(access_token, await self._aload_jwks(force=True))
```
> `_sync_authorization_url`/`_generate_pkce`는 sync `auth.py`의 실제 심볼로 대체(구현자 확정). python-keycloak `a_*`가 `scope`/`code_verifier` kwargs를 받는지 `inspect`로 확인.

- [ ] **Step 4~5: 통과 확인 + Commit** — Run: `... -m pytest tests/unit/aio/test_auth.py` + `... -m mypy src`. Commit: `feat(py-aio): AsyncAuthClient (WBS 2)`. (추가 테스트: exchange/refresh/logout/introspect/validate 위임·매핑, validate가 a_certs 로드+JwtValidator 위임 — 실제 RSA 서명 토큰 + AsyncMock a_certs.)

---

# Task 3: async 예외변환 + AsyncAdminClient + 리소스

**Files:** Create `python/src/keycloak_sdk/aio/admin/__init__.py`, `.../_translate.py`, `.../users.py|clients.py|realms.py|roles.py|groups.py` · Test `python/tests/unit/aio/test_admin.py`(+리소스별)

**Interfaces:**
- Produces:
  - `_translate.acall(awaitable) -> T` — `await` 후 python-keycloak 예외를 sync `keycloak_sdk.admin._translate.translate(exc)`로 변환(매핑 재사용). 
  - `AsyncAdminClient(config, admin=None)` — `admin` 미지정 시 `KeycloakAdmin(server_url, realm_name, client_id, client_secret_key, grant_type="client_credentials", verify=True, timeout=int(read_timeout))` 지연 생성(secret None → KeycloakConfigError). `raw` 프로퍼티. 리소스 프로퍼티 `users/clients/realms/roles/groups`.
  - `AsyncUsersResource(admin)`: `async def create(rep)->str`(`await admin.a_create_user(rep)`), `get(id)->dict|None`(`a_get_user`), `search(username,first,max)->list`(`a_get_users`), `update(id,rep)->None`(`a_update_user`), `delete(id)->None`(`a_delete_user`). 각 `await acall(...)`. 나머지 리소스는 sync 대응의 async 미러(같은 python-keycloak 메서드의 `a_*`).

- [ ] **Step 1: 실패 테스트** (acall + users, AsyncMock)

```python
# tests/unit/aio/test_admin.py
import pytest
from unittest.mock import AsyncMock, MagicMock
from keycloak.exceptions import KeycloakGetError
from keycloak_sdk.aio.admin._translate import acall
from keycloak_sdk.aio.admin.users import AsyncUsersResource
from keycloak_sdk.exceptions import KeycloakNotFoundError

async def test_acall_translates_404():
    async def boom(): raise KeycloakGetError("no", response_code=404)
    with pytest.raises(KeycloakNotFoundError):
        await acall(boom())

async def test_users_get_missing_translates():
    kc = MagicMock()
    kc.a_get_user = AsyncMock(side_effect=KeycloakGetError("no", response_code=404))
    with pytest.raises(KeycloakNotFoundError):
        await AsyncUsersResource(kc).get("missing")
```

- [ ] **Step 2: 실패 확인** — Run: `... -m pytest tests/unit/aio/test_admin.py` · Expected: ImportError.

- [ ] **Step 3: 구현** (`_translate.py` + 리소스 + AdminClient)

```python
# src/keycloak_sdk/aio/admin/_translate.py
from __future__ import annotations
from typing import Awaitable, TypeVar
from keycloak.exceptions import KeycloakError
from ...admin._translate import translate   # sync 매핑 재사용
T = TypeVar("T")
async def acall(awaitable: Awaitable[T]) -> T:
    try:
        return await awaitable
    except KeycloakError as e:
        raise translate(e) from e
```
```python
# src/keycloak_sdk/aio/admin/users.py
from __future__ import annotations
from typing import Any
from ._translate import acall
class AsyncUsersResource:
    def __init__(self, admin: Any) -> None:
        self._admin = admin
    async def create(self, rep: dict[str, Any]) -> str:
        return await acall(self._admin.a_create_user(rep))
    async def get(self, user_id: str) -> dict[str, Any]:
        return await acall(self._admin.a_get_user(user_id))
    async def search(self, username: str | None, first: int, max: int) -> list[dict[str, Any]]:
        q: dict[str, Any] = {"first": first, "max": max}
        if username is not None: q["username"] = username
        return await acall(self._admin.a_get_users(q))
    async def update(self, user_id: str, rep: dict[str, Any]) -> None:
        await acall(self._admin.a_update_user(user_id, rep))
    async def delete(self, user_id: str) -> None:
        await acall(self._admin.a_delete_user(user_id))
```
`clients.py`/`realms.py`/`roles.py`/`groups.py`는 sync 대응(`keycloak_sdk/admin/`)의 async 미러 — 같은 메서드의 `a_*`(예: `a_create_client`/`a_get_client`/`a_get_client_id`/`a_update_client`/`a_delete_client`; `a_create_realm`/`a_get_realm`/`a_delete_realm`; `a_create_realm_role`/`a_get_realm_role`/`a_get_realm_roles`/`a_delete_realm_role`; `a_create_group`/`a_get_group`/`a_get_groups`/`a_delete_group`), 각 `await acall(...)`. sync 리소스의 반환 타입·시그니처를 그대로 async로.
`admin/__init__.py`: `AsyncAdminClient` 지연 `KeycloakAdmin` + `raw` + 리소스 프로퍼티(`AsyncUsersResource(self.raw)` 등). python-keycloak `a_*` 실제 존재를 `inspect`로 확인.

- [ ] **Step 4~5: 통과 확인 + Commit(리소스별 또는 그룹)** — Run: `... -m pytest tests/unit/aio/ -q`. Commit: `feat(py-aio): AsyncAdminClient + acall + users/clients/realms/roles/groups (WBS 3)`. (각 리소스 happy + 404 변환 테스트로 커버리지 ≥90/85.)

---

# Task 4: AsyncKeycloakClient

**Files:** Create/extend `python/src/keycloak_sdk/aio/__init__.py`(또는 `aio/client.py`) · Test `python/tests/unit/aio/test_client.py`

**Interfaces:**
- Produces: `AsyncKeycloakClient` — `@classmethod create(config) -> AsyncKeycloakClient`. `auth: AsyncAuthClient`(즉시), `admin: AsyncAdminClient`(지연 프로퍼티). `async def aclose()`(생성된 admin만 정리). `__aenter__`/`__aexit__`(→ aclose). 테스트 시드 `_of(auth, admin)`. `aio/__init__.py`에서 `AsyncKeycloakClient` export(+ `__all__`).

- [ ] **Step 1: 실패 테스트**

```python
# tests/unit/aio/test_client.py
from unittest.mock import AsyncMock, MagicMock
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient

async def test_async_context_manager_and_wiring():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app", client_secret="s")
    async with AsyncKeycloakClient.create(c) as kc:
        assert kc.auth is not None

async def test_of_aclose_delegates():
    auth = MagicMock(); admin = MagicMock(); admin.aclose = AsyncMock()
    kc = AsyncKeycloakClient._of(auth, admin)
    assert kc.admin is admin
    await kc.aclose()
```

- [ ] **Step 2: 실패 확인** — Run: `... -m pytest tests/unit/aio/test_client.py` · Expected: ImportError.
- [ ] **Step 3: 구현** — `create()`가 `OidcEndpoints.for_realm` + `AsyncAuthClient` 즉시; `admin` 지연 프로퍼티(첫 접근 시 `AsyncAdminClient(config)`); `aclose()`가 admin 생성됐고 `aclose` 있으면 await 위임; `__aenter__/__aexit__`. `_of`는 테스트 주입. `aio/__init__.py`에서 export. (⚠️ AsyncAdminClient에 `async def aclose()` 추가 — python-keycloak KeycloakAdmin에 async close가 있으면 위임, 없으면 no-op.)
- [ ] **Step 4~5: 통과 확인 + Commit** — Run: `... -m pytest tests/unit/aio/ -q` + `... -m mypy src` + `... -m pytest --cov=keycloak_sdk`(aio 로직 ≥90/85, aio/auth·aio/admin/__init__ omit). Commit: `feat(py-aio): AsyncKeycloakClient 통합 진입점 (WBS 4)`.

---

# Task 5: 통합 테스트 (async E2E)

**Files:** Create `python/tests/integration/test_auth_async_it.py`, `python/tests/integration/test_admin_async_it.py` (기존 `conftest.py` fixture 재사용)

- [ ] **Step 1: async 인증 IT** — 기존 `keycloak_url` fixture 사용. `@pytest.mark.integration`. `async with AsyncKeycloakClient.create(config)`: (a) `await auth.client_credentials_token()` non-empty; (b) `await auth.validate(token)` issuer가 `.../realms/it-realm`(다중 aud 통과); (c) `await auth.introspect(token)` active.
- [ ] **Step 2: async 관리 IT** — user CRUD: `await admin.users.create(...)` → id, `get`, `search`, `delete` 후 `get` → `KeycloakNotFoundError`, `admin.raw` 서버정보.
- [ ] **Step 3: 실행** — Run: `... -m pytest -m integration tests/integration/test_auth_async_it.py tests/integration/test_admin_async_it.py -v` (Docker). Expected: PASS. (asyncio_mode=auto로 async 테스트 자동 실행.)
- [ ] **Step 4: Commit** — `git commit -m "test(py-aio): async E2E (client-credentials·validate·introspect·admin CRUD) (WBS 5)"`

---

# Task 6: 문서·예제

**Files:** Modify `python/README.md`, root `CLAUDE.md`; Create `python/examples/async_quickstart.py`

- [ ] **Step 1: async 예제** — `async def main()`에서 `AsyncKeycloakClient` 사용, 마스킹된 토큰 출력 + user 목록. `... -m mypy examples/async_quickstart.py` + `ruff check examples`.
- [ ] **Step 2: README** — "Async" 섹션 추가(`from keycloak_sdk.aio import AsyncKeycloakClient`, `async with`, FastAPI 적합성 한 줄).
- [ ] **Step 3: CLAUDE.md** — Python 섹션에 `aio` 서브모듈(async 미러) 한 줄 + 테스트 수 갱신.
- [ ] **Step 4: Commit & 최종 검증** — `... -m pytest -m "not integration"`(무회귀) + `ruff check`(clean) + `mypy src`. Commit: `docs(py-aio): async 예제 + README/CLAUDE (WBS 6)`.

---

## 자체 검토 (Self-Review)

**Spec 커버리지**: §3 구조→Task1,파일구조 · §4 API(auth/admin/client)→Task2,3,4 · §5.1 예외변환→acall/_awrap(2,3) · §5.2 JWT(async certs+JwtValidator+회전재시도)→Task2 validate · §5.3 보안/수명주기→Task2,4 · §6 테스트→Task2~5 · §7 의존성(pytest-asyncio)→Task1 · §8 거버넌스→전체.

**갭·주의**: (1) `AuthorizationUrl`/PKCE 생성 심볼의 재사용 위치는 sync `auth.py`를 읽고 확정(중복 금지) — Task2에 명시. (2) python-keycloak `a_*` 시그니처(특히 `a_get_users` 쿼리 dict, `a_token` kwargs)는 `inspect`로 확인 — 각 태스크에 명시. (3) async 네트워크 경계(`aio/auth.py`·`aio/admin/__init__.py`) 커버리지 omit — Task1에서 pyproject 설정. (4) sync 무회귀는 매 태스크 `pytest -m "not integration"`로 확인.

**플레이스홀더 스캔**: TODO/TBD 없음. 반복 리소스(Task3 clients/realms/roles/groups)는 users 패턴 + sync 대응 메서드명을 구체 명시. "실제 API inspect 확정"은 검증 지시(플레이스홀더 아님).

**타입 일관성**: `AsyncAuthClient`/`AsyncAdminClient`/`AsyncKeycloakClient` 시그니처, `acall`/`_awrap`, 재사용 값타입·예외가 전 태스크 일치. `validate`가 sync `JwtValidator`+`TokenSignatureError` 재사용으로 sync와 정합.
