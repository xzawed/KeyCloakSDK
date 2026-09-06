---
paths:
  - "python/**"
  - "harness/apps/python/**"
  - "harness/install/consume/python*"
  - ".github/workflows/python-*.yml"
---
<!-- doc-budget: max-bytes=4690 -->
<!-- 4643 → 4690 (2026-09-06, +47B). 규약 (1) — 증가분이 **실행 가능성**을 사 온다: 이 블록이
     처방하던 `"$PY" -m build` 가 같은 블록이 전제하는 venv 에서 실행 불가였다(`build` 는
     [dev] 에 없다). 설치 단계를 붙여 명령이 실제로 도는 것으로 바꿨다. 300B 이하. -->

# Python rules

## Toolchain

The venv is `python/.venv` (not committed). `PY="${KCSDK_PY:-.venv/Scripts/python.exe}"`.

```bash
cd python && "$PY" -m pytest -m "not integration" --cov=keycloak_sdk   # unit + coverage gate 100%
cd python && "$PY" -m pytest -m integration                            # needs Docker (testcontainers)
cd python && "$PY" -m ruff check src tests examples                    # includes the security S/bandit rules
cd python && "$PY" -m ruff format --check src tests examples
cd python && "$PY" -m mypy src                                         # strict
cd python && "$PY" -m pip install build && "$PY" -m build              # release build check (`build` is not in [dev])
```

- The POSIX venv interpreter is `.venv/bin/python` — override it with `KCSDK_PY`.
- Releasing goes `py-v*` tag → PyPI **Trusted Publisher** (OIDC, no stored secret, human approval gate).
- The package `keycloak_sdk` (distribution name `keycloak-sdk`) ships PEP 561 `py.typed`.
- ⚠️ **`py.typed` makes every module's signatures part of the public type surface, `__all__` or not.** Python has no `internal`, so the only structural way to keep a foreign type out of the consumer API is to put the module under `_internal/` — which is what `secrets`, `redirects` and `jwt` do. ⚠️ **Do not hide a foreign type by widening the annotation to `Any`.** Measured on `JwtValidator.validate(token, key_set)`: with the real `KeySet`, passing a wrong type is **2 mypy errors**; with `Any` it is **0**. That trades a working check for a cosmetic one, and `strict` does not warn about it, so the loss is invisible.
- ⚠️ **The version constant lives in the manifest only — never keep a second copy.** `__version__` is derived from `importlib.metadata`. A hardcoded value in `__init__.py` once fell behind `pyproject.toml`, so **the published wheel reported its own version wrongly** — and the smoke test was green throughout, because it compared against that same constant.

- ⚠️ **`pip-audit` exits 1 even when it merely skips an editable install** — feed it `pip freeze --exclude-editable` + `-r` instead. (This lived in `ci.md`, which is not loaded when you work in `python/`.)

## Gotchas

- ⚠️ **admin has two sessions, and one of them is created lazily** — `connection._s` (REST) and `connection.keycloak_openid.connection._s` (its own token grant). That doubled structure bears on **both hardening and cleanup**.
  - **Redirects**: python-keycloak's sync path does not forward `allow_redirects` (`raw_get`/`raw_post` leak kwargs into the query string), so overriding the session's `resolve_redirects` is the only point that cannot be bypassed. Block the outer session alone and the first admin call's grant hands the POST body — `client_secret` included — straight to the redirect target. ⚠️ **What leaks is not the `Authorization` header.** requests' `rebuild_auth` does strip that header across origins, but **a POST body survives a 307/308**, and the credential is in the body. A defence aimed at headers does not stop this one.
  - **Cleanup**: if `aclose()` closes only the outer session, the inner `httpx.AsyncClient` stays open and **one FD leaks per client that uses admin** (EMFILE in a long-lived async service). The auth-only path is clean, so a test that never exercises admin can never reveal it. A `finally` contract closes the outer session even when the nested close fails.
  - ⚠️ When building the mocks, `MagicMock(spec=KeycloakAdmin)` makes the nested `aclose` a **synchronous** MagicMock — in production it is a coroutine, so without an explicit `AsyncMock` you are asserting against a shape that never occurs.
- ⚠️ **joserfc's `KeySet.import_key_set` raises the stdlib `binascii.Error` on a malformed JWKS — not even a joserfc type** — so a consumer catching `keycloak_sdk.exceptions` **catches nothing** (a §4 violation). The parsing in `_load_jwks` is not covered by `_wrap`: `_wrap` is for transport errors, and this is a problem with the **content** of the response. Both the sync and the async mirror convert it to `TokenValidationError`. An IdP serving a malformed JWKS is not a hypothetical — proxy misconfiguration, a partial rollout, a man in the middle.
- ⚠️ **JWKS refetching has to be DoS-safe.** A forged signature (`BadSignatureError`) **does not** trigger a refetch; only an unresolved key id (`InvalidKeyIdError` or `MissingKeyError`) does, and `_jwks_min_refetch` rate-limits it. The 30-second default and its rationale live in `.claude/rules/security.md`.
