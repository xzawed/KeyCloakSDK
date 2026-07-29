# Keycloak SDK for Python

Authentication (OIDC / OAuth2) and the Admin REST API for [Keycloak](https://www.keycloak.org/) behind one consistent facade, with hardened JWT validation and a full async mirror.

English · [한국어](https://github.com/xzawed/KeyCloakSDK/blob/main/python/README.ko.md)

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API surface, isomorphic across all of them: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **Pre-release** — not yet published to PyPI.

## Requirements

- Python **3.10+**
- Ships the PEP 561 `py.typed` marker, so consumers can type-check with `mypy` too

## Install

```bash
pip install keycloak-sdk
```

The distribution name is `keycloak-sdk`; the import package is `keycloak_sdk`.

## Quickstart

```python
from keycloak_sdk import KeycloakClient, KeycloakConfig

config = KeycloakConfig(
    server_url="https://kc.example.com",
    realm="myrealm",
    client_id="admin-cli",
    client_secret="changeme",  # load the real value from an env var / secrets manager
)

# The `with` block cleans up the admin and auth sessions on exit.
with KeycloakClient.create(config) as kc:
    # 1) Issue a client-credentials token. repr(TokenSet) masks every token value.
    token = kc.auth.client_credentials_token()

    # 2) Validate it — algorithm pinning, exact iss, aud containment, mandatory exp, clock skew.
    validated = kc.auth.validate(token.access_token)
    print(f"subject={validated.subject} aud={validated.audience}")

    # 3) Admin API — admin is created lazily on first access. create() returns the new user id.
    user_id = kc.admin.users.create({"username": "alice", "enabled": True})
    users = kc.admin.users.search(first=0, max=20)
```

### Async

`keycloak_sdk.aio` is a complete async mirror — same method names, value types, and exceptions — so it never blocks the event loop (FastAPI and friends):

```python
from keycloak_sdk import KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient

async def handler(config: KeycloakConfig) -> None:
    async with AsyncKeycloakClient.create(config) as kc:
        token = await kc.auth.client_credentials_token()
        validated = await kc.auth.validate(token.access_token)
        users = await kc.admin.users.search(first=0, max=20)
```

Only `authorization_url` stays synchronous — it assembles a URL and needs no network.

## Secure by default

The SDK replaces the unsafe library defaults rather than inheriting them:

- **Algorithm pinning** — the header-supplied `alg` is never trusted, so `alg: none` and HS/RS confusion are rejected structurally.
- **Strict claim checks** — exact `iss` match, `aud` containment, mandatory `exp`, `nbf`, and a bounded clock skew.
- **DoS-safe JWKS** — refetch happens only for an unresolved key ID, and is rate-limited, so forged tokens cannot amplify traffic onto your IdP.
- **Secrets stay out of logs** — config secrets and tokens are fully masked (`***`, no prefix leak) and TLS verification is on by default.

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#python) — install, quickstart, async, and the compatibility matrix
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md) — the server this SDK talks to
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)
- Full examples: [`quickstart.py`](https://github.com/xzawed/KeyCloakSDK/blob/main/python/examples/quickstart.py) · [`async_quickstart.py`](https://github.com/xzawed/KeyCloakSDK/blob/main/python/examples/async_quickstart.py)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/python/LICENSE)
