# Compatibility reference

> Extracted from [Getting Started](../guides/getting-started.md) — that guide installs and runs one
> language; this file answers "which server and which base libraries did that published version
> actually ship against", which is a different question asked at a different time.
>
> ⚠️ The version cell of every row is machine-checked against `scripts/lib/deploy-facts.sh`
> (`df_published_version`) by `scripts/test/test-publication-claims.sh`. It finds a row by the
> language label followed by a backtick — **keep the row shape**, and do not add a second table
> above this one whose rows start the same way.

## Compatibility

Each SDK's own SemVer is decoupled from the Keycloak server and underlying library versions. See the table below for the supported server range and the base libraries · runtimes.

> ⚠️ **Each row describes what that row's published version actually shipped.** The library versions in a cell are the values in the release named in the first column, not whatever `main` happens to pin today. `main` can already be ahead; the next release of that language is when this table should move. Java and Kotlin have no lockfile — their published POM / `build.gradle.kts` pins are the source; Go has no lockfile either, so its row is the `go/go.mod` of the tagged commit (`go/v1.0.0`, which the proxy serves as the module's `.mod`). Every row now names a published version — there is no "current `main`" row left. The contract a *new* consumer resolves is still the range in each manifest; read the manifest, not this table, when that difference matters.

| SDK | Target Keycloak server | Base libraries · runtime |
|---|---|---|
| Java `1.0.0` | 26.6.x (integration tests: actual **26.6.4**) | `keycloak-admin-client` **26.0.12** (an independent version track from the server — there is no "26.6.x admin-client") · Nimbus `oauth2-oidc-sdk` **11.38.2** · `nimbus-jose-jwt` **10.9.1** · JDK 21+ |
| Python `1.0.0` | 26.6.x (integration tests: actual **26.6.4**) | `python-keycloak` **7.1.x** · `joserfc` **1.7.x** · Python 3.10+ |
| Node `1.0.0` | 26.6.x (integration tests: actual **26.6**) | `@keycloak/keycloak-admin-client` **26.7.1** · `openid-client` **6.8.5** · `jose` **6.2.9** · Node 22+ |
| Go `1.0.0` | 26.6.x (integration tests: actual **26.6**) | `Nerzal/gocloak/v13` **13.9.0** · `golang.org/x/oauth2` **0.36.0** · `go-jose/v4` **4.1.4** · Go 1.25+ |
| C#/.NET `1.0.0` | 26.6.x (integration tests: actual **26.6**) | `Keycloak.AuthServices.Sdk` **2.7.0** · `Duende.IdentityModel` **8.1.0** · `Microsoft.IdentityModel.JsonWebTokens` **8.22.0** · .NET 8+ |
| PHP `1.0.0` | 26.6.x (integration tests: actual **26.6**, docker CLI shell-out) | `fschmtt/keycloak-rest-api-client-php` **0.42.0** · `league/oauth2-client` **^2.8** · `stevenmaguire/oauth2-keycloak` **^6.1** · `firebase/php-jwt` **^7.1** · PHP 8.3+ |
| Rust `1.0.0` | 26.6.x (integration tests: actual **26.6**, Testcontainers) | `keycloak` **~26.6.2** (`reqwest12` feature) · `openidconnect` **4.0.1** · `jsonwebtoken` **11.0.0** · Rust 1.88+ (edition 2024) |
| Ruby `1.0.0` | 26.6.x (integration tests: actual **26.6**, docker CLI shell-out) | `rack-oauth2` **~>2.3** · `faraday` **~>2.0** · `jwt` (ruby-jwt) **~>3.2** · Ruby 3.2+ |
| Kotlin `1.0.0` | 26.6.x (integration tests: actual **26.6**, Testcontainers) | `keycloak-admin-client` **26.0.12** · `oauth2-oidc-sdk` **11.38.2** · `nimbus-jose-jwt` **10.9.1** (same JVM stack as Java) · Kotlin 2.2+ consumers (built with 2.4.10, metadata pinned to 2.2) · JDK 21+ |

> Note on the Rust row: those are **ranges, not exact `=` pins**. An exact pin in a *library* crate hard-fails dependency resolution for any consumer whose tree also wants a newer compatible version. `openidconnect`/`jsonwebtoken` are ordinary semver crates and take a caret; the `keycloak` crate takes a tilde (`>=26.6.2, <26.7.0`) because its version tracks the Keycloak **server** line rather than semver. Reproducibility of *our* builds comes from the committed [`rust/Cargo.lock`](../../rust/Cargo.lock) — cargo ignores a dependency's lockfile, so as a consumer you pin with your own.

---
