# Keycloak SDK for Rust

An async Keycloak SDK for Rust — OIDC/OAuth2 authentication with hardened JWT validation plus the Admin REST API, behind a single facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layering and flows are isomorphic across every language — monorepo: <https://github.com/xzawed/KeyCloakSDK>

> **Pre-release** — the first release candidate (`0.1.0-rc.1`) is on crates.io; there is no stable release yet. **Ask for it explicitly** — `cargo add keycloak-sdk@0.1.0-rc.1` — because a plain version requirement never matches a pre-release in Cargo, so the bare command below will not find it until a stable version exists.

## Requirements

- Rust **1.88+** (MSRV — required by edition 2024 and let-chains)
- A [tokio](https://tokio.rs) runtime — the SDK is async-only
- A Keycloak server (verified against 26.6)

## Install

```bash
cargo add keycloak-sdk
```

## Quickstart

The same three steps as every sibling SDK — get a token, verify it, call the Admin API.

```rust
use keycloak_sdk::types::UserRepresentation;
use keycloak_sdk::{KeycloakClient, KeycloakConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = KeycloakConfig::new("https://keycloak.example.com", "my-realm", "my-client")?
        .with_client_secret(std::env::var("KC_CLIENT_SECRET")?); // load from env / a secret manager

    let client = KeycloakClient::new(cfg)?;

    // 1. Get a token (client-credentials grant). TokenSet's Debug masks the tokens as "***".
    let token = client.auth().client_credentials_token().await?;
    println!("token type: {}, expires in: {}s", token.token_type, token.expires_in);

    // 2. Verify it — hardened validation, not the library defaults.
    let validated = client.auth().validate(&token.access_token).await?;
    println!("subject: {}, issuer: {}", validated.subject, validated.issuer);

    // 3. Call the Admin API. The new id comes from the response Location header (None if absent).
    let user_id = client
        .admin()
        .create_user(UserRepresentation {
            username: Some("demo-user".into()),
            email: Some("demo@example.com".into()),
            enabled: Some(true),
            ..Default::default()
        })
        .await?;
    println!("created demo-user (id={user_id:?})");

    Ok(())
}
```

A stock realm does **not** put the client id in a client-credentials token's `aud`, so step 2 fails until the
audience matches: either add an *Audience* protocol mapper to the client in Keycloak, or chain
`.with_expected_audience("…")` onto the config with the value your tokens actually carry (the API/resource
name, when the token is audienced at a resource server).

Errors are values, not panics: every fallible call returns `Result<T, KeycloakError>`, whose variants are
`Config` · `Auth` · `Transport` · `Admin` · `TokenValidation`.

The Admin representation types (`UserRepresentation`, `ClientRepresentation`, `RealmRepresentation`,
`RoleRepresentation`, `GroupRepresentation`) are re-exported from `keycloak_sdk::types`, so the `keycloak`
crate does not need to be a direct dependency of your project.

## Security defaults

- **Algorithm pinning** — only the configured signature algorithms are accepted (default `RS256`); the header's `alg` is never trusted, and `alg: none` is structurally impossible: `jsonwebtoken`'s `Algorithm` enum has no `none` variant, so such a header fails to deserialize before any key is looked up.
- **Strict claim checks** — exact `iss` match, `aud` containment (against `expected_audience`, the client id by default), mandatory `exp`, `nbf` verified, and a bounded clock skew (30s by default).
- **DoS-safe JWKS** — keys are cached, a refetch is triggered only by an unresolved `kid` and never by a bad signature, and it is rate-limited to a minimum interval (`with_jwks_min_refetch_secs`, 30s by default). The gate is stamped when the refetch is *decided*, not when it succeeds, so an IdP outage cannot be used to reopen it — no volume of forged `kid`s makes the SDK issue more than one JWKS request per interval.
- **Safe transport** — TLS verification on by default (rustls), redirects disabled entirely (SSRF hardening), and secrets/tokens masked as `***` in the SDK's `Debug` output.

Masking covers the SDK's own `Debug` impls; it cannot cover what your logging framework or a panic message does with a value you hand it.

## Versioning and support

This crate is **pre-1.0**. Under SemVer a `0.x` **minor** bump may carry breaking changes, so read the release notes before upgrading — and note that Cargo's default caret requirement treats `0.x` minors as incompatible, so `cargo update` will not cross one for you. Only the newest released version of each language SDK receives security fixes — there are no LTS lines, and older `0.x` releases are not backported to. Full policy: [SECURITY.md](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md).

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#rust) — install, quickstart, and the compatibility matrix
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Full runnable example](https://github.com/xzawed/KeyCloakSDK/blob/main/rust/examples/quickstart.rs)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/rust/LICENSE)
