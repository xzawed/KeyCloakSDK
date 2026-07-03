# Keycloak Python SDK 구현 계획 (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 성숙한 `python-keycloak` 라이브러리(admin + OIDC)를 감싸, Java SDK와 동형인 파사드·예외 계층·자체 강화 JWT 검증을 얹은 Python SDK(`keycloak-sdk`)를 만들어 PyPI에 배포한다.

**Architecture:** 단일 패키지 `keycloak_sdk` + 서브모듈. `python-keycloak`의 `KeycloakOpenID`(auth)와 `KeycloakAdmin`(admin)을 얇게 감싸고, JWT 검증만 `joserfc`로 자체 강화 구현. `KeycloakClient` 파사드가 auth+admin을 조립(admin 지연 초기화, 컨텍스트 매니저). 공개 API에 python-keycloak 타입 미노출.

**Tech Stack:** Python 3.10+, `python-keycloak>=7.1`, `joserfc>=1.7`, hatchling, pytest 9.x + `testcontainers[keycloak]`, mypy.

## Global Constraints

값은 [설계 스펙](../specs/2026-07-03-keycloak-python-sdk-design.md)에서 그대로 옮긴 것. 모든 태스크에 암묵 포함.

- **Python 베이스라인**: 3.10+ (`requires-python = ">=3.10"`). `src/` 레이아웃, 패키지 `keycloak_sdk`, 배포명 `keycloak-sdk`, 버전 `0.1.0`.
- **기반**: `python-keycloak>=7.1,<8` (`KeycloakOpenID`·`KeycloakAdmin`) 래핑. JWT 검증만 `joserfc>=1.7`로 자체. OpenAPI 코드생성 안 함.
- **동기(sync)만** — 공개 계약은 블로킹. async(`a_*`)는 향후.
- **보안**: 토큰/시크릿을 `__repr__`·로그에 노출 금지(마스킹). TLS 검증 기본 on. JWT는 알고리즘 핀닝(`none`/미서명 거부), issuer 정확일치, **audience 포함검사**(다중 aud 대응), exp/nbf + 클록 스큐.
- **예외**: 공개 API에 `keycloak.exceptions.*`(python-keycloak) 타입 노출 금지 — 경계에서 SDK 예외로 변환.
- **결합**: `admin`은 `auth`에 의존하지 않음. 표현형은 plain `dict[str, Any]` 통과.
- **명명**: Java 계약 동형, snake_case (`client_credentials_token`, `KeycloakNotFoundError`).
- **커버리지 게이트(G3)**: `pytest-cov` 로직 모듈 라인 ≥90% / 브랜치 ≥85%. 네트워크 경계(`AuthClient`/`AdminClient`)는 통합으로 검증, 커버리지 제외(`# pragma: no cover` 또는 omit).
- **거버넌스**: `feature/python-sdk`에서 구현, main에 PR(사람 승인). Codex 교차검증·게이트·루프. 커밋은 `git add <files> && git commit -m`.
- **툴체인**: Python은 시스템에 설치돼 있어야 함(Phase 1.0에서 확인). 가상환경 사용 권장.

---

## WBS 개요

| WBS | Phase / Work Package | 산출물 | Dep |
|---|---|---|---|
| **1** | **기반** | 설치 가능한 패키지 골격 + 도구 + CI | — |
| 1.1 | pyproject + 패키지 골격 | `pip install -e .` 성공 | — |
| 1.2 | 도구 설정 (pytest/cov/mypy) | `pytest` 통과(0개), `mypy` 통과 | 1.1 |
| 1.3 | CI 골격 | PR 매트릭스 빌드 | 1.1 |
| **2** | **core** | 설정·예외·토큰·마스킹·엔드포인트 | 1 |
| 2.1 | 예외 계층 | `KeycloakSdkError` 트리 | 1.2 |
| 2.2 | 마스킹 유틸 | `mask()` | 1.2 |
| 2.3 | `KeycloakConfig` | 불변 dataclass + 검증 | 2.1 |
| 2.4 | 토큰 값 타입 | `TokenSet`/`ValidatedToken`/`IntrospectionResult` | 2.2 |
| 2.5 | OIDC 엔드포인트 | realm URL 구성 | 2.3 |
| **3** | **auth** | 인증 흐름 | 2 |
| 3.1 | `JwtValidator` (joserfc) | 자체 강화 검증 | 2.4, 2.5 |
| 3.2 | `AuthClient` 골격 | KeycloakOpenID 래핑·에러 변환 | 2.5 |
| 3.3 | client credentials + PKCE URL | `client_credentials_token`·`authorization_url` | 3.2 |
| 3.4 | exchange/refresh/logout/introspect | 나머지 흐름 | 3.2 |
| 3.5 | `validate` 배선 | AuthClient→JwtValidator | 3.1, 3.2 |
| **4** | **admin** | 관리 파사드 | 2 |
| 4.1 | `AdminClient` 골격 + 예외변환 | KeycloakAdmin 래핑·raw | 2.1 |
| 4.2 | `users` | 사용자 CRUD | 4.1 |
| 4.3 | `clients` | 클라이언트 CRUD | 4.1 |
| 4.4 | `realms`/`roles`/`groups` | 나머지 리소스 | 4.1 |
| **5** | **facade** | 통합 진입점 | 3, 4 |
| 5.1 | `KeycloakClient` | auth+admin(지연)·컨텍스트 매니저 | 3.5, 4.1 |
| **6** | **통합 테스트** | testcontainers E2E | 5 |
| 6.1 | 하네스 + realm | 컨테이너 부팅 | 5.1 |
| 6.2 | 인증 E2E | client-creds·검증·introspect | 6.1 |
| 6.3 | 관리 E2E | user CRUD + raw | 6.1 |
| **7** | **배포·문서** | PyPI + 문서 | 6 |
| 7.1 | pyproject 메타 + 릴리스 CI | Trusted Publisher | 1.1 |
| 7.2 | examples + README·CLAUDE.md | 문서 | 5.1 |

**진행 순서**: 1 → 2 → 3 → 4 → 5 → 6 → 7.

---

## 파일 구조

```
python/
├─ pyproject.toml
├─ README.md
├─ src/keycloak_sdk/
│  ├─ __init__.py              # 공개 export
│  ├─ exceptions.py            # 예외 계층 (2.1)
│  ├─ _internal/
│  │  ├─ __init__.py
│  │  └─ secrets.py            # 마스킹 (2.2)
│  ├─ config.py                # KeycloakConfig (2.3)
│  ├─ tokens.py                # TokenSet/ValidatedToken/IntrospectionResult (2.4)
│  ├─ oidc.py                  # OidcEndpoints (2.5)
│  ├─ jwt.py                   # JwtValidator (3.1)
│  ├─ auth.py                  # AuthClient (3.2~3.5)
│  ├─ admin/
│  │  ├─ __init__.py           # AdminClient (4.1)
│  │  ├─ _translate.py         # 예외 변환 (4.1)
│  │  ├─ users.py clients.py realms.py roles.py groups.py (4.2~4.4)
│  └─ client.py                # KeycloakClient (5.1)
└─ tests/
   ├─ unit/                    # test_*.py (python-keycloak 목)
   └─ integration/             # test_*_it.py (testcontainers)
```

---

# Phase 1 — 기반

### Task 1.1: pyproject + 패키지 골격

**Files:** Create `python/pyproject.toml`, `python/src/keycloak_sdk/__init__.py`, `python/README.md`

**Interfaces:**
- Produces: 설치 가능한 `keycloak_sdk` 패키지 (`keycloak_sdk.__version__ = "0.1.0"`).

- [ ] **Step 0: Python 확인** — Run: `python --version` (3.10+ 여야 함). 없으면 BLOCKED 보고.

- [ ] **Step 1: pyproject.toml 작성**

```toml
[build-system]
requires = ["hatchling>=1.30"]
build-backend = "hatchling.build"

[project]
name = "keycloak-sdk"
version = "0.1.0"
description = "Keycloak SDK for Python — 인증(OIDC) + 관리 API, python-keycloak 래핑"
readme = "README.md"
requires-python = ">=3.10"
license = "Apache-2.0"
authors = [{ name = "xzawed", email = "xzawed31@gmail.com" }]
dependencies = [
  "python-keycloak>=7.1,<8",
  "joserfc>=1.7",
]

[project.urls]
Homepage = "https://github.com/xzawed/KeyCloakSDK"

[project.optional-dependencies]
dev = [
  "pytest>=9.0",
  "pytest-cov>=5.0",
  "mypy>=2.0",
  "testcontainers[keycloak]>=4.14",
]

[tool.hatch.build.targets.wheel]
packages = ["src/keycloak_sdk"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-q"
markers = ["integration: 실제 Keycloak 컨테이너 필요(Docker)"]

[tool.coverage.run]
branch = true
source = ["keycloak_sdk"]
omit = ["*/auth.py", "*/admin/__init__.py"]   # 네트워크 경계 — 통합으로 검증

[tool.mypy]
python_version = "3.10"
strict = true
```

- [ ] **Step 2: 패키지 초기화**

```python
# src/keycloak_sdk/__init__.py
"""Keycloak SDK for Python."""
__version__ = "0.1.0"
```
```markdown
<!-- README.md -->
# keycloak-sdk (Python)
Keycloak SDK for Python — 인증(OIDC/OAuth2) + 관리 API. `python-keycloak` 래핑, Java SDK와 동형.
```

- [ ] **Step 3: 설치 검증** — Run: `cd python && python -m pip install -e ".[dev]"` · Expected: 성공, `python -c "import keycloak_sdk; print(keycloak_sdk.__version__)"` → `0.1.0`.
- [ ] **Step 4: Commit** — `git add python/pyproject.toml python/src python/README.md && git commit -m "build(py): 패키지 골격 + pyproject (WBS 1.1)"`

---

### Task 1.2: 도구 설정 검증

**Files:** (1.1의 pyproject에 이미 pytest/cov/mypy 설정 포함) Create `python/tests/__init__.py`, `python/tests/unit/__init__.py`

- [ ] **Step 1: 테스트 디렉터리 생성** — 빈 `tests/__init__.py`, `tests/unit/__init__.py`.
- [ ] **Step 2: 스모크 테스트**

```python
# tests/unit/test_smoke.py
import keycloak_sdk
def test_version():
    assert keycloak_sdk.__version__ == "0.1.0"
```

- [ ] **Step 3: 검증** — Run: `cd python && pytest` (PASS 1개) · `mypy src` (성공). Expected: 둘 다 통과.
- [ ] **Step 4: Commit** — `git add python/tests && git commit -m "test(py): pytest/mypy 스모크 (WBS 1.2)"`

---

### Task 1.3: CI 골격

**Files:** Create `.github/workflows/python-ci.yml`

- [ ] **Step 1: 워크플로 작성**

```yaml
name: Python CI
on:
  push: { branches: [main], paths: ['python/**', '.github/workflows/python-ci.yml'] }
  pull_request: { branches: [main], paths: ['python/**'] }
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix: { python: ['3.10', '3.11', '3.12', '3.13'] }
    defaults: { run: { working-directory: python } }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '${{ matrix.python }}' }
      - run: python -m pip install -e ".[dev]"
      - run: pytest -m "not integration" --cov=keycloak_sdk --cov-fail-under=0
      - run: mypy src
```
> 통합테스트(`integration` 마커)는 Docker 필요 — 별도 잡 또는 로컬. 여기선 단위 + mypy.

- [ ] **Step 2: 로컬 검증** — Run: `cd python && pytest -m "not integration"` · Expected: PASS.
- [ ] **Step 3: Commit & push** — `git add .github/workflows/python-ci.yml && git commit -m "ci(py): 단위+mypy 매트릭스 (WBS 1.3)" && git push`

---

# Phase 2 — core

### Task 2.1: 예외 계층

**Files:** Create `python/src/keycloak_sdk/exceptions.py` · Test `python/tests/unit/test_exceptions.py`

**Interfaces:**
- Produces: `KeycloakSdkError(Exception)` base; 하위 `KeycloakConfigError`, `KeycloakAuthError`(`.error: str|None`), `TokenValidationError`, `KeycloakAdminError`(`.status_code: int`, `.keycloak_error: str|None`), `KeycloakNotFoundError`/`KeycloakConflictError`/`KeycloakForbiddenError`(AdminError 상속), `KeycloakTransportError`.

- [ ] **Step 1: 실패 테스트**

```python
# tests/unit/test_exceptions.py
from keycloak_sdk.exceptions import (
    KeycloakSdkError, KeycloakAdminError, KeycloakNotFoundError, KeycloakConfigError,
)
def test_admin_error_carries_status():
    e = KeycloakNotFoundError(404, "User not found")
    assert e.status_code == 404
    assert e.keycloak_error == "User not found"
    assert isinstance(e, KeycloakAdminError)
    assert isinstance(e, KeycloakSdkError)
def test_config_error_is_sdk_error():
    assert isinstance(KeycloakConfigError("bad"), KeycloakSdkError)
```

- [ ] **Step 2: 실패 확인** — Run: `cd python && pytest tests/unit/test_exceptions.py` · Expected: ImportError.

- [ ] **Step 3: 구현**

```python
# src/keycloak_sdk/exceptions.py
"""SDK 예외 계층. 공개 API에 python-keycloak 예외 타입을 노출하지 않는다."""
from __future__ import annotations

class KeycloakSdkError(Exception):
    """모든 SDK 예외의 기반."""

class KeycloakConfigError(KeycloakSdkError):
    """잘못된 설정."""

class KeycloakAuthError(KeycloakSdkError):
    """인증/토큰 교환 실패. OAuth error 코드 보존."""
    def __init__(self, message: str, error: str | None = None) -> None:
        super().__init__(message)
        self.error = error

class TokenValidationError(KeycloakSdkError):
    """JWT 서명·클레임 검증 실패."""

class KeycloakTransportError(KeycloakSdkError):
    """네트워크/전송 오류."""

class KeycloakAdminError(KeycloakSdkError):
    """관리 API 오류. HTTP status + Keycloak error 본문 보존."""
    def __init__(self, status_code: int, keycloak_error: str | None = None) -> None:
        super().__init__(f"Keycloak admin error (HTTP {status_code})")
        self.status_code = status_code
        self.keycloak_error = keycloak_error

class KeycloakNotFoundError(KeycloakAdminError):
    """404."""

class KeycloakConflictError(KeycloakAdminError):
    """409."""

class KeycloakForbiddenError(KeycloakAdminError):
    """403."""
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git add python/src/keycloak_sdk/exceptions.py python/tests/unit/test_exceptions.py && git commit -m "feat(py-core): 예외 계층 (WBS 2.1)"`

---

### Task 2.2: 마스킹 유틸

**Files:** Create `python/src/keycloak_sdk/_internal/__init__.py`, `python/src/keycloak_sdk/_internal/secrets.py` · Test `python/tests/unit/test_secrets.py`

**Interfaces:**
- Produces: `mask(value: str | None) -> str` — 4자 이하/None → `"***"`, 그 외 앞 3자 + `"***"`.

- [ ] **Step 1: 실패 테스트**

```python
# tests/unit/test_secrets.py
from keycloak_sdk._internal.secrets import mask
def test_mask():
    assert mask(None) == "***"
    assert mask("ab") == "***"
    assert mask("abcdef123") == "abc***"
```

- [ ] **Step 2: 실패 확인** — Run: `cd python && pytest tests/unit/test_secrets.py` · Expected: ImportError.

- [ ] **Step 3: 구현**

```python
# src/keycloak_sdk/_internal/__init__.py
```
```python
# src/keycloak_sdk/_internal/secrets.py
"""시크릿 마스킹."""
from __future__ import annotations

def mask(value: str | None) -> str:
    if value is None or len(value) <= 4:
        return "***"
    return value[:3] + "***"
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(py-core): 시크릿 마스킹 (WBS 2.2)"` (신규파일은 add 먼저)

---

### Task 2.3: `KeycloakConfig`

**Files:** Create `python/src/keycloak_sdk/config.py` · Test `python/tests/unit/test_config.py`

**Interfaces:**
- Produces: `@dataclass(frozen=True) KeycloakConfig`: `server_url: str`, `realm: str`, `client_id: str`, `client_secret: str | None = None`, `scopes: tuple[str, ...] = ("openid",)`, `read_timeout: float = 30.0`, `clock_skew: float = 30.0`. `__post_init__`이 server_url/realm/client_id 공란 → `KeycloakConfigError`. `__repr__`은 client_secret 마스킹. (⚠️ 최종리뷰 반영: `connect_timeout` 제거 — python-keycloak은 단일 `timeout`만 지원.)

- [ ] **Step 1: 실패 테스트**

```python
# tests/unit/test_config.py
import pytest
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import KeycloakConfigError
def test_defaults():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app")
    assert c.clock_skew == 30.0
    assert c.scopes == ("openid",)
def test_missing_realm_raises():
    with pytest.raises(KeycloakConfigError):
        KeycloakConfig(server_url="https://kc", realm="", client_id="app")
def test_repr_masks_secret():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app", client_secret="supersecret")
    assert "supersecret" not in repr(c)
```

- [ ] **Step 2: 실패 확인** — Run: `cd python && pytest tests/unit/test_config.py` · Expected: ImportError.

- [ ] **Step 3: 구현**

```python
# src/keycloak_sdk/config.py
"""불변 설정."""
from __future__ import annotations
from dataclasses import dataclass, field
from ._internal.secrets import mask
from .exceptions import KeycloakConfigError

@dataclass(frozen=True)
class KeycloakConfig:
    server_url: str
    realm: str
    client_id: str
    client_secret: str | None = None
    scopes: tuple[str, ...] = ("openid",)
    read_timeout: float = 30.0
    clock_skew: float = 30.0

    def __post_init__(self) -> None:
        for name in ("server_url", "realm", "client_id"):
            v = getattr(self, name)
            if not v or not str(v).strip():
                raise KeycloakConfigError(f"Missing required config: {name}")

    def __repr__(self) -> str:
        return (f"KeycloakConfig(server_url={self.server_url!r}, realm={self.realm!r}, "
                f"client_id={self.client_id!r}, client_secret={mask(self.client_secret)!r}, "
                f"scopes={self.scopes!r})")
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git add ... && git commit -m "feat(py-core): KeycloakConfig 검증·마스킹 (WBS 2.3)"`

---

### Task 2.4: 토큰 값 타입

**Files:** Create `python/src/keycloak_sdk/tokens.py` · Test `python/tests/unit/test_tokens.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) TokenSet`: `access_token: str`, `refresh_token: str | None`, `id_token: str | None`, `token_type: str`, `scope: str | None`, `expires_at: float | None` (epoch sec). `is_expired(now: float, skew: float) -> bool` = `expires_at is None or now + skew >= expires_at`. `__repr__` 마스킹.
  - `@dataclass(frozen=True) ValidatedToken`: `subject: str | None`, `issuer: str | None`, `audience: tuple[str, ...]`, `expires_at: float | None`, `issued_at: float | None`, `claims: dict[str, Any]`.
  - `@dataclass(frozen=True) IntrospectionResult`: `active: bool`, `username: str | None`, `client_id: str | None`.
  - `TokenSet.from_response(data: dict, issued_at: float) -> TokenSet` — python-keycloak `token()` 응답(dict: access_token/refresh_token/expires_in/token_type/scope) 매핑.

- [ ] **Step 1: 실패 테스트**

```python
# tests/unit/test_tokens.py
from keycloak_sdk.tokens import TokenSet, ValidatedToken
def test_is_expired_respects_skew():
    t = TokenSet("acc", None, None, "Bearer", None, 30.0)
    assert t.is_expired(now=5.0, skew=30.0) is True
    assert t.is_expired(now=5.0, skew=10.0) is False
    assert TokenSet("a", None, None, "Bearer", None, None).is_expired(0.0, 0.0) is True
def test_repr_masks():
    t = TokenSet("supersecret", "refreshsecret", None, "Bearer", None, 0.0)
    r = repr(t)
    assert "supersecret" not in r and "refreshsecret" not in r
def test_from_response():
    t = TokenSet.from_response({"access_token": "a", "expires_in": 300, "token_type": "Bearer"}, issued_at=1000.0)
    assert t.access_token == "a" and t.expires_at == 1300.0
```

- [ ] **Step 2: 실패 확인** — Run: `cd python && pytest tests/unit/test_tokens.py` · Expected: ImportError.

- [ ] **Step 3: 구현**

```python
# src/keycloak_sdk/tokens.py
"""토큰 값 타입."""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any
from ._internal.secrets import mask

@dataclass(frozen=True)
class TokenSet:
    access_token: str
    refresh_token: str | None
    id_token: str | None
    token_type: str
    scope: str | None
    expires_at: float | None

    def is_expired(self, now: float, skew: float) -> bool:
        if self.expires_at is None:
            return True
        return now + skew >= self.expires_at

    def __repr__(self) -> str:
        return (f"TokenSet(token_type={self.token_type!r}, scope={self.scope!r}, "
                f"access_token={mask(self.access_token)!r}, "
                f"refresh_token={mask(self.refresh_token)!r}, expires_at={self.expires_at!r})")

    @staticmethod
    def from_response(data: dict[str, Any], issued_at: float) -> "TokenSet":
        expires_in = data.get("expires_in")
        expires_at = issued_at + float(expires_in) if expires_in is not None else None
        return TokenSet(
            access_token=data["access_token"],
            refresh_token=data.get("refresh_token"),
            id_token=data.get("id_token"),
            token_type=data.get("token_type", "Bearer"),
            scope=data.get("scope"),
            expires_at=expires_at,
        )

@dataclass(frozen=True)
class ValidatedToken:
    subject: str | None
    issuer: str | None
    audience: tuple[str, ...]
    expires_at: float | None
    issued_at: float | None
    claims: dict[str, Any] = field(default_factory=dict)

@dataclass(frozen=True)
class IntrospectionResult:
    active: bool
    username: str | None
    client_id: str | None
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -m "feat(py-core): 토큰 값 타입 (WBS 2.4)"`

---

### Task 2.5: OIDC 엔드포인트

**Files:** Create `python/src/keycloak_sdk/oidc.py` · Test `python/tests/unit/test_oidc.py`

**Interfaces:**
- Produces: `@dataclass(frozen=True) OidcEndpoints{ issuer, authorization, token, introspection, end_session, jwks: str }`. `for_realm(config: KeycloakConfig) -> OidcEndpoints`.

- [ ] **Step 1~5: TDD** — issuer `{server_url}/realms/{realm}`, token `.../protocol/openid-connect/token`, jwks `.../certs`, auth `.../auth`, introspect `.../token/introspect`, logout `.../logout`. 테스트로 URL 조립 검증 후 구현·커밋. Run: `cd python && pytest tests/unit/test_oidc.py`. Commit: `feat(py-core): OIDC 엔드포인트 (WBS 2.5)`.

```python
# src/keycloak_sdk/oidc.py 핵심
from dataclasses import dataclass
from .config import KeycloakConfig

@dataclass(frozen=True)
class OidcEndpoints:
    issuer: str; authorization: str; token: str
    introspection: str; end_session: str; jwks: str
    @staticmethod
    def for_realm(config: KeycloakConfig) -> "OidcEndpoints":
        base = config.server_url.rstrip("/") + "/realms/" + config.realm
        oc = base + "/protocol/openid-connect"
        return OidcEndpoints(issuer=base, authorization=oc + "/auth", token=oc + "/token",
                             introspection=oc + "/token/introspect", end_session=oc + "/logout",
                             jwks=oc + "/certs")
```

---

# Phase 3 — auth

> auth 모듈은 python-keycloak `KeycloakOpenID`를 감싼다. `AuthClient`는 커버리지 omit(네트워크 경계) — 로직은 JwtValidator(3.1)와 매핑 헬퍼에 두어 단위 검증한다.

### Task 3.1: `JwtValidator` (joserfc 자체 강화) 🔴

**Files:** Create `python/src/keycloak_sdk/jwt.py` · Test `python/tests/unit/test_jwt.py`

**Interfaces:**
- Produces: `JwtValidator(issuer: str, audience: str, allowed_algs: tuple[str,...] = ("RS256",), clock_skew: float = 30.0)`. `validate(token: str, key_set) -> ValidatedToken` — joserfc로 서명 검증(알고리즘 핀닝, `none`/미서명 거부), issuer 정확일치, **audience 포함검사**, exp/nbf + skew. 실패 시 `TokenValidationError`. `key_set`은 joserfc `KeySet`(테스트는 정적 주입, 실사용은 realm JWKS에서 로드). `for_realm(endpoints, config)` 팩토리는 JWKS를 fetch(3.5에서 배선).
- 구현: joserfc `jwt.decode(token, key_set, algorithms=list(allowed_algs))` → 서명·alg 검증. `token.claims` dict를 `JWTClaimsRegistry(iss={"essential": True, "value": issuer}, exp={"essential": True})`로 검증 + audience 포함검사는 수동(`aud` claim이 str이면 == , list면 in). 예외를 `TokenValidationError`로 래핑.

- [ ] **Step 1: 실패 테스트** (로컬 RSA로 서명·검증)

```python
# tests/unit/test_jwt.py
import time, pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey, KeySet
from keycloak_sdk.jwt import JwtValidator
from keycloak_sdk.exceptions import TokenValidationError

def _key(): return RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})

def test_valid_multi_aud_accepted():
    key = _key(); issuer = "https://kc/realms/r"
    tok = jjwt.encode({"alg": "RS256", "kid": "k1"},
        {"iss": issuer, "aud": ["app", "realm-management"], "exp": int(time.time()) + 60}, key)
    v = JwtValidator(issuer=issuer, audience="app")
    vt = v.validate(tok, KeySet([key.as_dict(private=False) and key]))  # public key set
    assert vt.issuer == issuer and "app" in vt.audience

def test_wrong_aud_rejected():
    key = _key(); issuer = "https://kc/realms/r"
    tok = jjwt.encode({"alg": "RS256", "kid": "k1"},
        {"iss": issuer, "aud": ["other"], "exp": int(time.time()) + 60}, key)
    v = JwtValidator(issuer=issuer, audience="app")
    with pytest.raises(TokenValidationError):
        v.validate(tok, KeySet([key]))

def test_none_alg_rejected():
    v = JwtValidator(issuer="iss", audience="app")
    with pytest.raises(TokenValidationError):
        v.validate("eyJhbGciOiJub25lIn0.eyJpc3MiOiJpc3MifQ.", KeySet([]))
```
> ⚠️ joserfc `KeySet` 생성/`RSAKey` API는 joserfc 1.7 실제 시그니처로 구현 시 확정(`javap` 없음 — `python -c` / joserfc 문서로 검증). 위 테스트의 키셋 구성은 실제 API에 맞게 조정.

- [ ] **Step 2: 실패 확인** — Run: `cd python && pytest tests/unit/test_jwt.py` · Expected: ImportError/실패.

- [ ] **Step 3: 구현** (joserfc 1.7 실제 API로 확정)

```python
# src/keycloak_sdk/jwt.py
"""자체 강화 JWT 검증 (joserfc). python-keycloak decode_token에 의존하지 않는다."""
from __future__ import annotations
from typing import Any
from joserfc import jwt as _jwt
from joserfc.jwk import KeySet
from .exceptions import TokenValidationError
from .tokens import ValidatedToken

class JwtValidator:
    def __init__(self, issuer: str, audience: str,
                 allowed_algs: tuple[str, ...] = ("RS256",), clock_skew: float = 30.0) -> None:
        self._issuer = issuer
        self._audience = audience
        self._algs = list(allowed_algs)
        self._skew = clock_skew

    def validate(self, token: str, key_set: KeySet) -> ValidatedToken:
        try:
            decoded = _jwt.decode(token, key_set, algorithms=self._algs)  # 서명 + alg 핀닝(none/미서명 거부)
        except Exception as e:  # joserfc.errors.* 포함
            raise TokenValidationError("JWT signature/algorithm validation failed") from e
        claims: dict[str, Any] = dict(decoded.claims)
        self._check_claims(claims)
        aud = claims.get("aud")
        audiences = tuple(aud) if isinstance(aud, list) else ((aud,) if aud else ())
        return ValidatedToken(subject=claims.get("sub"), issuer=claims.get("iss"),
                              audience=audiences, expires_at=claims.get("exp"),
                              issued_at=claims.get("iat"), claims=claims)

    def _check_claims(self, claims: dict[str, Any]) -> None:
        import time
        now = time.time()
        if claims.get("iss") != self._issuer:
            raise TokenValidationError("Issuer mismatch")
        aud = claims.get("aud")
        contained = (self._audience == aud) or (isinstance(aud, list) and self._audience in aud)
        if not contained:
            raise TokenValidationError("Audience not contained")
        exp = claims.get("exp")
        if exp is None or now - self._skew >= float(exp):
            raise TokenValidationError("Token expired")
        nbf = claims.get("nbf")
        if nbf is not None and now + self._skew < float(nbf):
            raise TokenValidationError("Token not yet valid")
```
> `_jwt.decode`에 `algorithms`를 명시하면 `none`/미허용 알고리즘·미서명 토큰이 거부된다(joserfc 기본). audience는 포함검사, issuer는 정확일치, exp/nbf는 skew 적용.

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git add python/src/keycloak_sdk/jwt.py python/tests/unit/test_jwt.py && git commit -m "feat(py-auth): joserfc 자체 강화 JWT 검증 (WBS 3.1)"`

---

### Task 3.2: `AuthClient` 골격 + 에러 변환

**Files:** Create `python/src/keycloak_sdk/auth.py` · Test `python/tests/unit/test_auth.py`(목 기반)

**Interfaces:**
- Produces: `AuthClient(config: KeycloakConfig, endpoints: OidcEndpoints, openid: KeycloakOpenID | None = None)` — `openid` 미지정 시 `python-keycloak`의 `KeycloakOpenID(server_url, realm_name, client_id, client_secret_key, verify=True)` 생성. 테스트 주입용. 내부 헬퍼 `_wrap(callable)` — python-keycloak 예외(`KeycloakAuthenticationError`, `KeycloakGetError` 등)를 `KeycloakAuthError`/`KeycloakTransportError`로 변환.
- Consumes: `KeycloakConfig`(2.3), `OidcEndpoints`(2.5).

- [ ] **Step 1~5: TDD** — 목 `KeycloakOpenID` 주입 생성자 + `_wrap`이 `keycloak.exceptions.KeycloakAuthenticationError`를 `KeycloakAuthError`로 변환하는지 단위 검증. python-keycloak 예외 클래스명은 실제(`from keycloak.exceptions import ...`)로 확정. Commit: `feat(py-auth): AuthClient 골격·에러 변환 (WBS 3.2)`.

---

### Task 3.3: client credentials + PKCE URL

**Files:** Modify `auth.py` · Test `test_auth.py`

**Interfaces:**
- Produces: `AuthClient.client_credentials_token() -> TokenSet` (`openid.token(grant_type="client_credentials")` → `TokenSet.from_response(resp, issued_at=time.time())`). `AuthClient.authorization_url(redirect_uri: str) -> AuthorizationUrl` — PKCE(`python-keycloak`의 `pkce_utils` 또는 자체 `secrets` 기반 verifier/challenge) + `openid.auth_url(redirect_uri, scope, state, code_challenge, code_challenge_method="S256")`. `@dataclass AuthorizationUrl{ url, code_verifier, state, nonce }`.

- [ ] **Step 1~5: TDD** — 목으로 `token(grant_type="client_credentials")` 호출 및 매핑 검증; `authorization_url`이 code_challenge/state 포함 URL 반환 검증(목 `auth_url`). Commit: `feat(py-auth): client-credentials + PKCE URL (WBS 3.3)`.

---

### Task 3.4: exchange/refresh/logout/introspect

**Files:** Modify `auth.py` · Test `test_auth.py`

**Interfaces:**
- Produces: `exchange_code(code, redirect_uri, code_verifier) -> TokenSet` (`openid.token(grant_type="authorization_code", code=..., redirect_uri=..., code_verifier=...)`); `refresh(refresh_token) -> TokenSet` (`openid.refresh_token(refresh_token)`); `logout(refresh_token) -> None` (`openid.logout(refresh_token)`); `introspect(token) -> IntrospectionResult` (`openid.introspect(token)` dict → `IntrospectionResult(active=..., username=..., client_id=...)`).

- [ ] **Step 1~5: TDD** — 각 메서드를 목으로 위임·매핑 검증. Commit: `feat(py-auth): exchange/refresh/logout/introspect (WBS 3.4)`.

---

### Task 3.5: `validate` 배선

**Files:** Modify `auth.py` · Test `test_auth.py`

**Interfaces:**
- Produces: `AuthClient.validate(access_token: str) -> ValidatedToken` — realm JWKS를 `openid.certs()`(dict)로 로드해 joserfc `KeySet`으로 변환, `JwtValidator(issuer=endpoints.issuer, audience=config.client_id, clock_skew=config.clock_skew).validate(token, key_set)` 위임. JWKS는 인스턴스에 캐시(첫 호출 시 로드).

- [ ] **Step 1~5: TDD** — 목 `certs()` + 서명 토큰으로 validate가 `ValidatedToken` 반환/issuer 확인, 만료·불일치 aud 거부 검증(JwtValidator는 3.1에서 이미 검증되므로 여기선 배선·JWKS 로드·캐시 중심). Commit: `feat(py-auth): validate 배선(JWKS 로드+JwtValidator) (WBS 3.5)`.

---

# Phase 4 — admin

> admin 모듈은 python-keycloak `KeycloakAdmin`을 감싼다. `AdminClient`(생성·raw)는 커버리지 omit, 리소스 파사드는 목으로 단위 검증(≥90/85).

### Task 4.1: `AdminClient` 골격 + 예외 변환

**Files:** Create `python/src/keycloak_sdk/admin/__init__.py`, `python/src/keycloak_sdk/admin/_translate.py` · Test `python/tests/unit/test_admin_translate.py`

**Interfaces:**
- Produces:
  - `_translate.call(fn)` / `translate(exc)` — python-keycloak `KeycloakGetError`/`KeycloakPostError`/`KeycloakPutError`/`KeycloakDeleteError`(모두 `.response_code: int`)를 status별 SDK 예외로 변환(404→NotFound, 409→Conflict, 403→Forbidden, else AdminError). `.response_body`(있으면) 보존.
  - `AdminClient(config, admin: KeycloakAdmin | None = None)` — 미지정 시 `KeycloakAdmin(server_url, realm_name, client_id, client_secret_key, grant_type="client_credentials", verify=True)` 지연 생성(client_secret None이면 `KeycloakConfigError`). `raw -> KeycloakAdmin`. 리소스 접근자 `users`/`clients`/`realms`/`roles`/`groups`(4.2~4.4).

- [ ] **Step 1: 실패 테스트**

```python
# tests/unit/test_admin_translate.py
import pytest
from keycloak.exceptions import KeycloakGetError   # python-keycloak
from keycloak_sdk.admin._translate import call
from keycloak_sdk.exceptions import KeycloakNotFoundError, KeycloakConflictError
def test_404_maps_notfound():
    def boom(): raise KeycloakGetError("nope", response_code=404)
    with pytest.raises(KeycloakNotFoundError):
        call(boom)
def test_409_maps_conflict():
    def boom(): raise KeycloakGetError("dup", response_code=409)
    with pytest.raises(KeycloakConflictError):
        call(boom)
```

- [ ] **Step 2: 실패 확인** — Run: `cd python && pytest tests/unit/test_admin_translate.py` · Expected: ImportError.

- [ ] **Step 3: 구현** (`_translate.py`)

```python
# src/keycloak_sdk/admin/_translate.py
"""python-keycloak 예외 → SDK 예외 경계 변환."""
from __future__ import annotations
from typing import Callable, TypeVar
from keycloak.exceptions import KeycloakError
from ..exceptions import (
    KeycloakAdminError, KeycloakNotFoundError, KeycloakConflictError,
    KeycloakForbiddenError, KeycloakTransportError,
)
T = TypeVar("T")

def translate(exc: KeycloakError) -> KeycloakAdminError | KeycloakTransportError:
    status = getattr(exc, "response_code", None)
    body = getattr(exc, "response_body", None)
    body_str = body.decode() if isinstance(body, (bytes, bytearray)) else (str(body) if body else None)
    if status is None:
        return KeycloakTransportError(str(exc))
    if status == 404: return KeycloakNotFoundError(status, body_str)
    if status == 409: return KeycloakConflictError(status, body_str)
    if status == 403: return KeycloakForbiddenError(status, body_str)
    return KeycloakAdminError(status, body_str)

def call(fn: Callable[[], T]) -> T:
    try:
        return fn()
    except KeycloakError as e:
        raise translate(e) from e
```
`AdminClient`(`__init__.py`)는 지연 `KeycloakAdmin` 생성 + `raw` + 리소스 접근자(4.2~4.4에서 채움) + null client_secret 가드.

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git add python/src/keycloak_sdk/admin && git commit -m "feat(py-admin): AdminClient 골격 + 예외 변환 (WBS 4.1)"`

---

### Task 4.2: `users`

**Files:** Create `python/src/keycloak_sdk/admin/users.py` · Modify `admin/__init__.py`(`users` 접근자) · Test `python/tests/unit/test_users.py`(목 KeycloakAdmin)

**Interfaces:**
- Produces: `UsersResource(admin: KeycloakAdmin)` — `create(rep: dict) -> str`(`admin.create_user(rep)` → id), `get(id) -> dict | None`(`admin.get_user(id)`; NotFound는 `KeycloakNotFoundError` 전파), `search(username: str | None, first: int, max: int) -> list[dict]`(`admin.get_users({"username":..., "first":..., "max":...})`), `update(id, rep) -> None`(`admin.update_user(id, rep)`), `delete(id) -> None`(`admin.delete_user(id)`). 모든 호출 `_translate.call(...)`로 감쌈.

- [ ] **Step 1: 실패 테스트** (목 `KeycloakAdmin`)

```python
# tests/unit/test_users.py
from unittest.mock import MagicMock
import pytest
from keycloak.exceptions import KeycloakGetError
from keycloak_sdk.admin.users import UsersResource
from keycloak_sdk.exceptions import KeycloakNotFoundError
def test_get_missing_translates_notfound():
    kc = MagicMock()
    kc.get_user.side_effect = KeycloakGetError("no", response_code=404)
    with pytest.raises(KeycloakNotFoundError):
        UsersResource(kc).get("missing")
def test_create_returns_id():
    kc = MagicMock(); kc.create_user.return_value = "new-id"
    assert UsersResource(kc).create({"username": "a"}) == "new-id"
```

- [ ] **Step 2: 실패 확인** — Run: `cd python && pytest tests/unit/test_users.py` · Expected: ImportError.
- [ ] **Step 3: 구현** — `UsersResource` 위임 + `_translate.call`. `admin/__init__.py`의 `users` 프로퍼티가 `UsersResource(self.raw)` 반환. python-keycloak 실제 메서드명(`create_user`/`get_user`/`get_users`/`update_user`/`delete_user`) 확인.
- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -m "feat(py-admin): users 리소스 (WBS 4.2)"`

---

### Task 4.3: `clients`

**Files:** Create `python/src/keycloak_sdk/admin/clients.py` · Test `test_clients.py` — **4.2와 동일 패턴**.

**Interfaces:**
- Produces: `ClientsResource{ create(rep)->str(admin.create_client), get(id)->dict|None(admin.get_client), find_by_client_id(client_id)->str|None(admin.get_client_id), update(id, rep)->None(admin.update_client), delete(id)->None(admin.delete_client) }`, 모두 `_translate.call`. Commit: `feat(py-admin): clients 리소스 (WBS 4.3)`.

TDD: 목으로 NotFound 변환 + create id 반환 검증 → 구현 → 통과 → 커밋.

---

### Task 4.4: `realms` / `roles` / `groups`

각 리소스에 4.2 패턴 적용(위임 + `_translate.call`). 파일: `realms.py`/`roles.py`/`groups.py`.

- **realms**: `RealmsResource{ create(rep)->None(admin.create_realm), get(realm_name)->dict|None(admin.get_realm), delete(realm_name)->None(admin.delete_realm) }`. Commit `feat(py-admin): realms 리소스 (WBS 4.4a)`.
- **roles**: `RolesResource{ create(rep)->None(admin.create_realm_role), get(name)->dict|None(admin.get_realm_role), list()->list[dict](admin.get_realm_roles), delete(name)->None(admin.delete_realm_role) }`. Commit `feat(py-admin): roles 리소스 (WBS 4.4b)`.
- **groups**: `GroupsResource{ create(rep)->str(admin.create_group), get(id)->dict|None(admin.get_group), list(first, max)->list[dict](admin.get_groups), delete(id)->None(admin.delete_group) }`. Commit `feat(py-admin): groups 리소스 (WBS 4.4c)`.

각각 목 기반 TDD(NotFound 변환 + 대표 메서드 위임). python-keycloak 실제 메서드명은 `KeycloakAdmin` 소스로 확정(`create_realm`/`get_realm`/`delete_realm`, `create_realm_role`/`get_realm_roles`/`delete_realm_role`, `create_group`/`get_groups`/`get_group`/`delete_group`).

**커버리지 게이트(G3)**: Phase 4 종료 시 `cd python && pytest -m "not integration" --cov=keycloak_sdk --cov-report=term-missing` → 리소스 파사드 + `_translate` + core ≥90/85. 미달 시 각 리소스 create/get/list/update/delete happy + error path 테스트 보강.

---

# Phase 5 — facade

### Task 5.1: `KeycloakClient`

**Files:** Create `python/src/keycloak_sdk/client.py` · Modify `python/src/keycloak_sdk/__init__.py`(공개 export) · Test `python/tests/unit/test_client.py`

**Interfaces:**
- Produces: `KeycloakClient` — `@classmethod create(config) -> KeycloakClient`. `auth: AuthClient`(즉시), `admin: AdminClient`(지연 프로퍼티 — 최초 접근 시 생성, secret 필요). 컨텍스트 매니저(`__enter__`/`__exit__` → `close()`). `close()`는 하위 자원 정리(python-keycloak은 명시적 close 불필요하나 향후 대비). 테스트 주입용 `_of(auth, admin)` 클래스메서드.
- `__init__.py`에서 export: `KeycloakClient`, `KeycloakConfig`, `TokenSet`, `ValidatedToken`, `IntrospectionResult`, 예외들.

- [ ] **Step 1: 실패 테스트**

```python
# tests/unit/test_client.py
from unittest.mock import MagicMock
from keycloak_sdk import KeycloakClient, KeycloakConfig
def test_create_wires_auth():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app", client_secret="s")
    with KeycloakClient.create(c) as kc:
        assert kc.auth is not None
def test_public_client_no_secret_auth_ok():
    c = KeycloakConfig(server_url="https://kc", realm="r", client_id="app")  # secret 없음
    kc = KeycloakClient.create(c)
    assert kc.auth is not None   # auth는 secret 없이 OK (admin 접근 시에만 필요)
def test_injected_close_delegates():
    auth = MagicMock(); admin = MagicMock()
    kc = KeycloakClient._of(auth, admin)
    kc.close()
    admin.close.assert_called_once()
```

- [ ] **Step 2: 실패 확인** — Run: `cd python && pytest tests/unit/test_client.py` · Expected: ImportError.
- [ ] **Step 3: 구현** — `create()`가 `OidcEndpoints.for_realm` + `AuthClient` 즉시 생성; `admin`은 지연 프로퍼티(첫 접근 시 `AdminClient(config)`); `close()`가 admin 생성됐으면 `admin.close()`(있으면) 위임. `_of`는 테스트 주입.
- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git add python/src/keycloak_sdk/client.py python/src/keycloak_sdk/__init__.py python/tests/unit/test_client.py && git commit -m "feat(py-sdk): KeycloakClient 통합 진입점 (WBS 5.1)"`

---

# Phase 6 — 통합 테스트 (testcontainers[keycloak])

> `testcontainers[keycloak]`의 `KeycloakContainer` 사용. realm import는 컨테이너의 realm 파일 마운트 또는 부팅 후 admin API로 프로비저닝. **파일명은 `<realm>-realm.json`**(Java에서 발견 — Keycloak `--import-realm` 규약). 통합 테스트는 `@pytest.mark.integration`.

### Task 6.1: 하네스 + realm

**Files:** Create `python/tests/integration/__init__.py`, `python/tests/integration/conftest.py`, `python/tests/integration/it-realm-realm.json`, `python/tests/integration/test_smoke_it.py`

- [ ] **Step 1: realm JSON** — `it-realm`, confidential client `it-client`(secret `it-secret`, serviceAccountsEnabled, service-account에 realm-management 역할, **audience 매퍼로 aud에 it-client 추가**). (Java의 `it-realm-realm.json`을 재사용 가능.)
- [ ] **Step 2: conftest fixture** — `KeycloakContainer("quay.io/keycloak/keycloak:26.6").with_realm_import_file("it-realm-realm.json")` (testcontainers API 확인), 세션 스코프 fixture로 `get_url()` 제공.
- [ ] **Step 3: 스모크 IT**

```python
# tests/integration/test_smoke_it.py
import pytest
pytestmark = pytest.mark.integration
def test_container_starts(keycloak_url):
    assert keycloak_url  # fixture가 컨테이너 URL 반환
```

- [ ] **Step 4: 실행** — Run: `cd python && pytest -m integration tests/integration/test_smoke_it.py` (Docker 필요, 이미지 pull) · Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "test(py-it): testcontainers Keycloak 하네스 + realm (WBS 6.1)"`

---

### Task 6.2: 인증 E2E

**Files:** Create `python/tests/integration/test_auth_it.py`

- [ ] **Step 1: IT 작성** — `KeycloakConfig`(server_url=컨테이너 URL, realm `it-realm`, client_id `it-client`, secret `it-secret`)로 `KeycloakClient.create`. (a) `auth.client_credentials_token().access_token` non-empty, (b) `auth.validate(token)` 통과 + issuer가 `.../realms/it-realm`(다중 aud 수용 확인), (c) `auth.introspect(token).active is True`.
- [ ] **Step 2: 실행** — Run: `cd python && pytest -m integration tests/integration/test_auth_it.py` · Expected: PASS.
- [ ] **Step 3: Commit** — `git commit -m "test(py-it): 인증 흐름 E2E (WBS 6.2)"`

---

### Task 6.3: 관리 E2E

**Files:** Create `python/tests/integration/test_admin_it.py`

- [ ] **Step 1: IT 작성** — `KeycloakClient.create` → (a) `admin.users.create({"username":"newuser","enabled":True})` → id, (b) `get(id)` username 일치, (c) `search("newuser",0,10)` 포함, (d) `delete(id)` 후 `get(id)` → `KeycloakNotFoundError`, (e) `admin.raw.get_server_info()` non-empty(탈출구).
- [ ] **Step 2: 실행** — Run: `cd python && pytest -m integration tests/integration/test_admin_it.py` · Expected: PASS.
- [ ] **Step 3: Commit** — `git commit -m "test(py-it): 관리 작업 E2E (WBS 6.3)"`

---

# Phase 7 — 배포 · 문서

### Task 7.1: pyproject 메타 + 릴리스 CI

**Files:** Modify `python/pyproject.toml`(classifiers/urls) · Create `.github/workflows/python-release.yml`

- [ ] **Step 1: 메타 보강** — classifiers(License Apache-2.0, Python 3.10~3.13, Dev Status Beta), `project.urls`(Repository/Issues), `keywords`.
- [ ] **Step 2: 릴리스 워크플로** — `on: push: tags: ['py-v*']`. `pypa/gh-action-pypi-publish` **Trusted Publisher(OIDC)** — 저장 자격증명 없이 PyPI 배포. `python -m build` → publish. human-gated(태그 push). Secrets 불필요(OIDC).
- [ ] **Step 3: 로컬 빌드 검증** — Run: `cd python && python -m build` (`pip install build` 후) · Expected: `dist/keycloak_sdk-0.1.0-*.whl` + `.tar.gz` 생성.
- [ ] **Step 4: Commit & push** — `git add python/pyproject.toml .github/workflows/python-release.yml && git commit -m "build(py): PyPI 메타 + Trusted Publisher 릴리스 CI (WBS 7.1)" && git push`

---

### Task 7.2: examples + 문서

**Files:** Create `python/examples/quickstart.py` · Modify `python/README.md`, root `CLAUDE.md`

- [ ] **Step 1: QuickStart** — `KeycloakConfig` → `KeycloakClient.create` → 마스킹된 client-credentials 토큰 출력 + user 목록. 실행 안 해도 됨(import 검증). `mypy`/`python -c "import ast"` 통과.
- [ ] **Step 2: README** — 설치(`pip install keycloak-sdk`), QuickStart 스니펫, Java↔Python 매핑표, 호환(SDK↔Keycloak 26.6.x, python-keycloak 7.1.x).
- [ ] **Step 3: CLAUDE.md** — Python SDK 섹션 추가(구조·명령: `cd python && pytest -m "not integration"`, `pytest -m integration`, `mypy src`).
- [ ] **Step 4: Commit & push** — `git add python/examples python/README.md CLAUDE.md && git commit -m "docs(py): QuickStart + README + CLAUDE (WBS 7.2)" && git push`

---

## 자체 검토 (Self-Review)

**Spec 커버리지**: §3 구조→WBS 1,파일구조 · §4 언어중립계약→명명 전반 · §5 API(config/auth/admin)→2.3,3.x,4.x · §5.4 값타입→2.4 · §6.1 예외→2.1,4.1 · §6.2 JWT강화→3.1,3.5 · §6.3 보안(마스킹)→2.2,2.3,2.4 · §6.4 수명주기(지연admin)→5.1 · §7 의존성→1.1 · §8 테스트→2~6 · §9 배포/CI→1.3,7.1 · §10 거버넌스→전체 · §11 배포전항목→7.1.

**갭·주의**: (1) python-keycloak/joserfc/testcontainers 실제 API 시그니처(메서드명·예외 클래스·KeySet 구성)는 구현 시 `python -c`/문서로 확정 — 각 태스크에 명시. (2) `AuthClient`/`AdminClient(생성)`는 커버리지 omit(네트워크 경계, Phase 6 통합 검증). (3) realm JSON은 Java의 `it-realm-realm.json` 재사용. (4) Docker 미가용 시 Phase 6는 `-m "not integration"`로 스킵.

**플레이스홀더 스캔**: TODO/TBD 없음. 반복 리소스(4.3/4.4)는 4.2 패턴을 인터페이스·커밋까지 구체화. joserfc/python-keycloak 실제 API 확정 지점은 "구현 시 확정"으로 명시(플레이스홀더 아님 — 검증 지시).

**타입 일관성**: `TokenSet.from_response`, `JwtValidator.validate(token, key_set)->ValidatedToken`, `_translate.call`, 예외 생성자 시그니처가 전 태스크 일치. `KeycloakConfig`/`OidcEndpoints`/토큰 타입 필드명 일관.
