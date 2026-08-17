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
> ⚠️ **Stable `0.1.0` is live for all nine languages** — every release is human-gated, and the line is still pre-1.0. Everything below also runs today from a clone: see [Try it today](#try-it-today).

---

## Why not just use `python-keycloak` / `gocloak` / the official client?

You still do — this SDK **wraps the best client in each ecosystem** instead of replacing it, and adds the three things those clients leave to you:

- **JWT validation that is hardened by default.** The wrapped libraries ship permissive defaults, or only building blocks. Here, algorithm pinning, exact `iss`, `aud` checking, mandatory `exp`, bounded clock skew and rate-limited JWKS refetch are the default in all nine (.NET’s refetch trigger is broader — [details below](#hardened-by-default)).
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

Registry installs exist so far only as first RCs — either way, the whole path works from a clone:

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

- **Auth: the same seven operations exist in all nine** — client-credentials token · authorization request (PKCE S256) · code exchange · refresh · introspect · logout · validate. Signatures are not identical: PHP and Rust take `redirectUri` from config rather than as an argument; Python names the start `authorization_url`. All nine issue a nonce on the authorization request; `exchange*` validates the `id_token` against it when the caller passes that nonce back (the parameter is optional on all nine — omit it and id_token validation is skipped). The types are named `TokenSet` / `ValidatedToken` / `IntrospectionResult` everywhere; a few fields differ (`expires_in` is not on Java/Python/Kotlin; PHP and Ruby treat a missing `expiresAt` as not-expired). Go and Rust return error values; the other seven raise a `Keycloak*` hierarchy.
- **Admin: five resources everywhere, and now the same five operations.** All nine expose users · clients · realms · roles · groups with create · get · list · update · delete — **25/25 in every language** — plus a `raw` escape hatch for anything past that. What still differs is shape, not coverage: Rust's facade is flat (`admin.update_role(name, rep)`) where the rest nest (`admin.roles().update(…)`), and list pagination is explicit in Rust and Go. The exact table is the [Admin capability matrix](docs/guides/getting-started.md#admin-capability-matrix).

---

## Hardened by default

All nine ship **the same claim-check rules** (algorithm pinning, exact `iss`, `aud` containment, mandatory `exp`, bounded clock skew) — not the underlying library defaults. JWKS refetch is rate-limited on all nine; **“only on an unresolved key id” is eight languages**. .NET’s `Microsoft.IdentityModel` `ConfigurationManager` also refetches on a bad signature, so the rate-limit is the amplification cap — see [dotnet/README.md](dotnet/README.md).

Secrets and tokens are masked in logs and serialization, and TLS verification is on by default. Auth-path types stay behind the facade; admin representations and `raw()` are documented exceptions ([Admin capability matrix](docs/guides/getting-started.md#admin-capability-matrix)).

---

## Status

All nine SDKs are feature-complete and merged to `main`. Each is verified against a **real Keycloak 26.6 server** (Testcontainers; PHP and Ruby shell out to the docker CLI). Logic modules are held to a line ≥ 90% coverage gate; six languages also gate branch ≥ 85% (Go, PHP and Rust measure lines only). Security cores were reviewed adversarially. Configurable JWT signature algorithms and dependency CVE audits apply across all nine. OIDC nonce / `id_token` replay protection is in **all nine**: `create*` always issues a nonce and puts it on the authorization URL; `exchange*` fully validates the `id_token` (signature · `iss` · `aud` · `exp`) and compares the nonce claim when the caller passes that value back. Omitting the nonce argument still skips id_token validation — that opt-out is the shared pattern, not a Ruby-only exception.

Everything is **pre-1.0 (`0.1.0` line)**. All nine have shipped a stable release to public registries — Packagist `xzawed/keycloak-sdk` 0.1.0 · PyPI `keycloak-sdk` 0.1.0 · NuGet `Xzawed.Keycloak.Sdk` 0.1.0 · crates.io `keycloak-sdk` 0.1.0 · RubyGems `keycloak-sdk` 0.1.0 · npm `@xzawed/keycloak-sdk` 0.1.0 · Maven Central `io.github.xzawed:keycloak-sdk` 0.1.0 · Maven Central `io.github.xzawed:keycloak-sdk-kotlin` 0.1.0 · Go module proxy `github.com/xzawed/KeyCloakSDK/go` v0.1.0 — each one behind a human tag gate, and each preceded by a release candidate that stays on its registry. See [DEPLOY.md](DEPLOY.md) for that procedure, and [SECURITY.md](SECURITY.md) for the security policy and what pre-1.0 means here.

---

## Docs

- 🚀 **[Getting started](docs/guides/getting-started.md)** — per-language install, runnable example, async, compatibility matrix
- 🖥️ **[Deploying a Keycloak server](docs/guides/deploying-keycloak-server.md)** — the server your SDK connects to (single VM + Docker Compose)
- 🔒 **[Security policy](SECURITY.md)** — reporting, hardening scope, supported versions
- 🗺️ **[Language roadmap](docs/roadmap/language-support.md)** — what exists today and what may come next
- 📦 **[Deploy](DEPLOY.md)** — the human-gated release procedure for all nine

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) · [development setup](docs/guides/development-setup.md) (`node scripts/doctor.mjs` reports what your machine is missing) · [add-a-language playbook](docs/guides/add-a-language-playbook.md) · [cross-language test harness](harness/README.md). Internal architecture and maintainer notes live in [CLAUDE.md](CLAUDE.md); every design spec, plan and verification log is indexed in the [documentation map](docs/README.md).

---

**License:** [Apache-2.0](LICENSE)
