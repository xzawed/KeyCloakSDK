# Keycloak SDK

**One API surface, nine languages.** A polyglot SDK for [Keycloak](https://www.keycloak.org/) that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** — idiomatic in each language, isomorphic across all of them.

English · [한국어](README.ko.md)

![License](https://img.shields.io/badge/license-Apache--2.0-blue)
![Languages](https://img.shields.io/badge/languages-9-brightgreen)
![Status](https://img.shields.io/badge/status-pre--release-orange)
![Keycloak](https://img.shields.io/badge/Keycloak-26.6-informational)
![Tests](https://img.shields.io/badge/tests-877%20passing-success)

> "Polyglot" here means **programming languages** (Java, Python, Node, Go, C#, PHP, Rust, Ruby, Kotlin) — not natural-language localization (i18n).

---

## Languages

| Language | Install *(after release)* | Example |
|---|---|---|
| **Java** 21+ | Maven `io.github.xzawed:keycloak-sdk` | [QuickStart.java](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java) |
| **Python** 3.10+ | `pip install keycloak-sdk` | [quickstart.py](python/examples/quickstart.py) · [async](python/examples/async_quickstart.py) |
| **Node** 22+ (ESM) | `npm i @xzawed/keycloak-sdk` | [quickstart.ts](node/examples/quickstart.ts) |
| **Go** 1.25+ | `go get github.com/xzawed/KeyCloakSDK/go` | [example_test.go](go/example_test.go) |
| **C# / .NET** 8+ | `dotnet add package Xzawed.Keycloak.Sdk` | [getting-started](docs/guides/getting-started.md#c--net) |
| **PHP** 8.3+ | `composer require xzawed/keycloak-sdk` | [quickstart.php](php/examples/quickstart.php) |
| **Rust** 1.88+ | `cargo add keycloak-sdk` | [quickstart.rs](rust/examples/quickstart.rs) |
| **Ruby** 3.2+ | `gem install keycloak-sdk` | [quickstart.rb](ruby/examples/quickstart.rb) |
| **Kotlin** 2.2+ (JVM) | Gradle `io.github.xzawed:keycloak-sdk-kotlin` | [quickstart.kt](kotlin/examples/quickstart.kt) |

> ⚠️ **Not published to public registries yet** — every release is human-gated. The commands above show the *post-release* form. Until then, build from source — see the [getting-started guide](docs/guides/getting-started.md).

---

## Quickstart (30 seconds)

Every language follows the same three-step shape — **get a token → verify it → call the Admin API**. Here it is in Python:

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

The same flow in all nine languages, plus async usage, lives in the **[getting-started guide](docs/guides/getting-started.md)**.

---

## Secure by default

All nine SDKs ship the **same hardened JWT validation** — not the unsafe library defaults:

- Algorithm pinning (rejects `alg: none` and header-supplied algorithms)
- Exact `iss` match · `aud` containment check · mandatory `exp` · bounded clock skew
- DoS-safe JWKS refetch (rate-limited, refetches only on unresolved key IDs)

Secrets and tokens are masked in logs, TLS verification is on by default, and every SDK hides its underlying library types behind a consistent facade.

---

## Status

**All nine SDKs are complete and merged to `main`.** Each one passes **real Keycloak 26.6 integration tests** and a logic-coverage gate (line ≥ 90% / branch ≥ 85%). The only thing left is publishing to public registries — human-gated (see [DEPLOY.md](DEPLOY.md)).

| SDK | Tests | Coverage | Notes |
|---|---|---|---|
| Java | 138 | gate 90 / 85 | reference implementation |
| Python | 247 | 100% enforced | sync + async (`aio`) |
| Node | 81 | line 100 / branch 94 | ESM · async-only |
| Go | 46 | 95% | sync + `context.Context` |
| C# / .NET | 63 | 97 / 93 | async-first |
| PHP | 71 | 100% | `final readonly class` |
| Rust | 41 | 95% | edition 2024 · async |
| Ruby | 84 | 100 / 93 | Faraday raw-REST admin |
| Kotlin | 106 | 99 / 86 | coroutines · reuses JVM stack |

*Integration tests run on Testcontainers (PHP & Ruby fall back to docker-CLI on Windows). Each SDK's security core was reviewed adversarially — see [SECURITY.md](SECURITY.md). Pre-release hardening (OIDC nonce replay protection, configurable JWT signature algorithms, dependency CVE audits) is applied across all nine SDKs.*

---

## Learn more

- 🚀 **[Getting started](docs/guides/getting-started.md)** — per-language install, quickstart, async, and compatibility matrix
- 🖥️ **[Deploying a Keycloak server](docs/guides/deploying-keycloak-server.md)** — the server your SDK connects to (single VM + Docker Compose)
- 🗺️ **[Language roadmap](docs/roadmap/language-support.md)** · 🧩 **[Add-a-language playbook](docs/guides/add-a-language-playbook.md)**
- 🧪 **[Test harness](harness/README.md)** — cross-language conformance, security probes, and scoring against real Keycloak
- 🤝 **[Contributing](CONTRIBUTING.md)** · 📦 **[Deploy](DEPLOY.md)** · 🏗️ **[Architecture & build (CLAUDE.md)](CLAUDE.md)**

---

**License:** [Apache-2.0](LICENSE)
