# Keycloak SDK

**One SDK shape for [Keycloak](https://www.keycloak.org/), in nine languages.** Issue a token, validate it safely, and drive the Admin REST API — with the same concepts, layers and flows whether the service in front of you is Java, Python, Node, Go, C#, PHP, Rust, Ruby or Kotlin.

**Who it's for:** teams running Keycloak behind services written in more than one language, who would rather not re-learn a client — and re-decide JWT validation — in every stack.

English · [한국어](README.ko.md)

![License](https://img.shields.io/badge/license-Apache--2.0-blue)
![Languages](https://img.shields.io/badge/languages-9-brightgreen)
![Status](https://img.shields.io/badge/status-pre--release-orange)
![Keycloak](https://img.shields.io/badge/Keycloak-26.6-informational)

> "Polyglot" here means **programming languages**, not natural-language localization (i18n).
>
> ⚠️ **First release candidates are live for PHP, Python, .NET and Rust; the other five languages are not on a registry yet** — every release is human-gated. Everything below runs today from a clone: see [Try it today](#try-it-today).

---

## Why not just use `python-keycloak` / `gocloak` / the official client?

You still do — this SDK **wraps the best client in each ecosystem** instead of replacing it, and adds the three things those clients leave to you:

- **JWT validation that is hardened by default.** The wrapped libraries ship permissive defaults, or only building blocks. Here, algorithm pinning, exact `iss`, `aud` checking, mandatory `exp`, bounded clock skew and DoS-safe JWKS refetch are the default in all nine — [details below](#hardened-by-default).
- **One mental model across the fleet.** The same `auth` / `admin` facade, the same token and validation types, the same error hierarchy, in every language — so the Go service and the PHP service review the same way.
- **Nothing taken away.** The wrapped client stays reachable through a `raw` escape hatch whenever the facade doesn't cover what you need.

---

## The shape

Every language follows the same three steps — **get a token → validate it → call the Admin API**. In Python:

```python
from keycloak_sdk import KeycloakClient, KeycloakConfig

config = KeycloakConfig(
    server_url="https://keycloak.example.com",
    realm="my-realm",
    client_id="my-client",
    client_secret="…",              # load from env / a secret manager
)

with KeycloakClient.create(config) as kc:
    token  = kc.auth.client_credentials_token()      # 1. get a token
    claims = kc.auth.validate(token.access_token)     # 2. verify it (hardened)
    users  = kc.admin.users.search(first=0, max=10)   # 3. call the Admin API
```

`validate()` requires the token's `aud` to contain the audience you expect — your client id by default. A token minted for a *different* audience is rejected until that expected audience is configured (in the SDK, or via an audience mapper in Keycloak). The same three steps in the other eight languages, plus async variants, are in the **[getting-started guide](docs/guides/getting-started.md)**.

---

## Try it today

Registry installs exist so far only as first RCs (PHP · Python · .NET · Rust) — either way, the whole path works from a clone:

```bash
# 1) a Keycloak server to talk to
docker run -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  quay.io/keycloak/keycloak:26.6 start-dev

# 2) the SDK, from source — Python shown, every language has an equivalent
git clone https://github.com/xzawed/KeyCloakSDK.git
pip install -e KeyCloakSDK/python
```

Then create a confidential client with its service account enabled in the realm — that pair is the `client_id` / `client_secret` the examples take. Per-language local installs (Maven · Gradle · npm · go · dotnet · composer · cargo · bundler) and a runnable example for each are in the [getting-started guide](docs/guides/getting-started.md).

---

## Languages

| Language | Runtime · idiom | Package *(registry availability: see [Status](#status))* | Example |
|---|---|---|---|
| **Java** | JDK 21+ · blocking | `io.github.xzawed:keycloak-sdk` (Maven Central) | [QuickStart.java](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java) |
| **Python** | 3.10+ · sync + async (`aio`) | `keycloak-sdk` (PyPI) | [quickstart.py](python/examples/quickstart.py) · [async](python/examples/async_quickstart.py) |
| **Node** | 22+ · ESM · async-only | `@xzawed/keycloak-sdk` (npm) | [quickstart.ts](node/examples/quickstart.ts) |
| **Go** | 1.25+ · sync + `context.Context` | `github.com/xzawed/KeyCloakSDK/go` | [example_test.go](go/example_test.go) |
| **C# / .NET** | 8+ · async-first | `Xzawed.Keycloak.Sdk` (NuGet) | [getting-started](docs/guides/getting-started.md#c--net) |
| **PHP** | 8.3+ · `final readonly class` | `xzawed/keycloak-sdk` (Packagist) | [quickstart.php](php/examples/quickstart.php) |
| **Rust** | 1.88+ (edition 2024) · async (tokio) | `keycloak-sdk` (crates.io) | [quickstart.rs](rust/examples/quickstart.rs) |
| **Ruby** | 3.2+ · sync-only | `keycloak-sdk` (RubyGems) | [quickstart.rb](ruby/examples/quickstart.rb) |
| **Kotlin** | 2.2+ / JDK 21+ · coroutines | `io.github.xzawed:keycloak-sdk-kotlin` (Maven Central) | [quickstart.kt](kotlin/examples/quickstart.kt) |

---

## What's identical, and what isn't

- **Auth and JWT validation: identical in all nine.** The same seven operations — client-credentials token · authorization request (PKCE S256) · code exchange · refresh · introspect · logout · validate — the same `TokenSet` / `ValidatedToken` / `IntrospectionResult` shapes, and the same validation rules. What differs is naming conventions and the error idiom: Go and Rust return error values, the other seven raise a `Keycloak*` exception hierarchy.
- **Admin: same coverage, not the same shape.** All nine expose the same five resources — users · clients · realms · roles · groups — each able to create, read and delete, plus a `raw` escape hatch. Past that, the surface follows the client being wrapped: **Rust** is flat (`admin.create_user(…)`, not `admin.users.create(…)`), **Rust and PHP have no `update()`**, PHP spells create as `import()` for clients and realms, and list/search coverage varies per resource. Check your language's example before assuming a method is there.

---

## Hardened by default

All nine ship the **same JWT validation rules** — not the underlying library defaults:

- Algorithm pinning (rejects `alg: none` and header-supplied algorithms)
- Exact `iss` match · `aud` containment check · mandatory `exp` · bounded clock skew
- DoS-safe JWKS refetch (rate-limited, and only on an unresolved key id)

Secrets and tokens are masked in logs and serialization, TLS verification is on by default, and each SDK keeps its underlying library types behind a consistent facade so they don't leak into your code.

---

## Status

All nine SDKs are feature-complete and merged to `main`. Each is verified against a **real Keycloak 26.6 server** (Testcontainers; PHP and Ruby shell out to the docker CLI) and held to a coverage gate of line ≥ 90% / branch ≥ 85% on logic modules. Security cores were reviewed adversarially, and pre-release hardening (OIDC nonce replay protection, configurable JWT signature algorithms, dependency CVE audits) is applied across all nine.

Everything is **pre-1.0 (`0.1.0` line)**. Four of the nine have shipped their first release candidates to public registries — Packagist `xzawed/keycloak-sdk` 0.1.0-rc.1 · PyPI `keycloak-sdk` 0.1.0rc1 · NuGet `Xzawed.Keycloak.Sdk` 0.1.0-rc.1 · crates.io `keycloak-sdk` 0.1.0-rc.1 — while the remaining five (Java · Node · Go · Ruby · Kotlin) are unpublished, behind a human tag gate. See [DEPLOY.md](DEPLOY.md) for that procedure, and [SECURITY.md](SECURITY.md) for the security policy and what pre-1.0 means here.

---

## Docs

- 🚀 **[Getting started](docs/guides/getting-started.md)** — per-language install, runnable example, async, compatibility matrix
- 🖥️ **[Deploying a Keycloak server](docs/guides/deploying-keycloak-server.md)** — the server your SDK connects to (single VM + Docker Compose)
- 🔒 **[Security policy](SECURITY.md)** — reporting, hardening scope, supported versions
- 🗺️ **[Language roadmap](docs/roadmap/language-support.md)** — what exists today and what may come next
- 📦 **[Deploy](DEPLOY.md)** — the human-gated release procedure for all nine

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) · [development setup](docs/guides/development-setup.md) (`node scripts/doctor.mjs` reports what your machine is missing) · [add-a-language playbook](docs/guides/add-a-language-playbook.md) · [cross-language test harness](harness/README.md). Internal architecture and maintainer notes live in [CLAUDE.md](CLAUDE.md).

---

**License:** [Apache-2.0](LICENSE)
