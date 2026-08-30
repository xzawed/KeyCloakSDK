# Keycloak SDK for Python

Authentication (OIDC / OAuth2) and the Admin REST API for [Keycloak](https://www.keycloak.org/) behind one consistent facade, with hardened JWT validation and a full async mirror.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API surface, isomorphic across all of them: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.0.0` is on PyPI** — a bare `pip install keycloak-sdk` resolves it. It is the first release carrying the stability guarantee: from here, a breaking change to the public API requires a **major** bump.
>
> ⚠️ **One breaking change since `0.1.0`, and it is narrow** (it landed in `0.2.0`; `1.0.0` adds none): the `keycloak_sdk.jwt` module moved to `keycloak_sdk._internal.jwt`. Only code that imported `JwtValidator` **from that path directly** is affected — it was never in `__all__` and appears in no quickstart. The normal validation path, `kc.auth.validate(token)`, is unchanged. The move was structural: `py.typed` makes every module's signatures part of the public type surface, so a module under the top level was publishing joserfc's `KeySet` as part of this SDK's API.

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

# The `with` block closes the auth session on exit (AdminClient owns no session, so its close() is a no-op).
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

`validate()` expects the token's `aud` to contain `client_id` by default, but a stock realm does not put the client id into a client-credentials token. Either set `expected_audience="my-api"` on the config to check the audience your tokens actually carry, or add an audience mapper to the client in Keycloak (Client scopes → dedicated scope → Add mapper → Audience).

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

## Security defaults

The SDK replaces the unsafe library defaults rather than inheriting them:

- **Algorithm pinning** — the header-supplied `alg` is never trusted, so `alg: none` and HS/RS confusion are rejected structurally: joserfc decodes against the configured allowlist, and an empty allowlist is refused at construction rather than falling back to joserfc's permissive default set.
- **Strict claim checks** — exact `iss` match, `aud` containment, mandatory `exp`, `nbf`, and a bounded clock skew.
- **DoS-safe JWKS** — a refetch is triggered only by an unresolved key ID and never by a bad signature, and is rate-limited to a minimum interval (`jwks_min_refetch_seconds`, 30s by default) — so no volume of forged tokens makes the SDK issue more than one JWKS request per interval.
- **Secret handling** — `repr()` of the config and token types masks secrets and tokens as `***` (no prefix leak), and TLS verification is on by default.

Masking covers this SDK's own `repr()`; it cannot cover what your logging framework or a traceback does with a value you hand it. Python has no erasable string type, so the client secret lives in an ordinary `str` for its lifetime — masking is defence in depth, not an erasure guarantee.

## Versioning and support

This SDK is **`1.0`** and follows SemVer: a breaking change to the public API requires a **major** bump. That promise is machine-backed — CI diffs this lane's public API against the **previously published artifact** on every build (`griffe check`), and a removal or an incompatible change fails the build. ⚠️ **The gate compares the API _surface_.** A change that leaves the surface identical but alters behaviour is not caught by it, so read the release notes before upgrading.

Only the newest released version of each language SDK receives security fixes; there are no long-term-support lines and older releases are not backported to.

**Each of the nine languages versions independently.** All nine reached `1.0.0` on the same day because they earned the same guarantee at the same time — they do **not** move in lockstep afterwards.

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#python) — install and quickstart for this language
- [Compatibility](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/reference/compatibility.md) — which Keycloak server range and base libraries each published version shipped against
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md) — the server this SDK talks to
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)
- Full examples: [`quickstart.py`](https://github.com/xzawed/KeyCloakSDK/blob/main/python/examples/quickstart.py) · [`async_quickstart.py`](https://github.com/xzawed/KeyCloakSDK/blob/main/python/examples/async_quickstart.py)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/python/LICENSE)
