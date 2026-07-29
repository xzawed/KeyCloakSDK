# Keycloak SDK for Rust

An async Keycloak SDK for Rust — OIDC/OAuth2 authentication with hardened JWT validation plus the Admin REST API, behind a single facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layering and flows are isomorphic across every language — monorepo: <https://github.com/xzawed/KeyCloakSDK>

> **Pre-release** — not yet published to crates.io.

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

Errors are values, not panics: every fallible call returns `Result<T, KeycloakError>`, whose variants are
`Config` · `Auth` · `Transport` · `Admin` · `TokenValidation`.

The Admin representation types (`UserRepresentation`, `ClientRepresentation`, `RealmRepresentation`,
`RoleRepresentation`, `GroupRepresentation`) are re-exported from `keycloak_sdk::types`, so the `keycloak`
crate does not need to be a direct dependency of your project.

## Secure by default

- **Algorithm pinning** — only the configured signature algorithms are accepted (default `RS256`); the header's `alg` is never trusted and `alg: none` is structurally impossible.
- **Strict claim checks** — exact `iss` match, `aud` containment, mandatory `exp`, `nbf` verified, and a bounded clock skew (30s by default).
- **DoS-safe JWKS** — keys are cached, a refetch is triggered only by an unresolved `kid`, and it is rate-limited, so a flood of forged tokens cannot amplify traffic to your identity provider.
- **Safe transport** — TLS verification on by default (rustls), redirects disabled (SSRF hardening), and secrets/tokens masked as `***` in every `Debug` output.

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#rust) — install, quickstart, and the compatibility matrix
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Full runnable example](https://github.com/xzawed/KeyCloakSDK/blob/main/rust/examples/quickstart.rs)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/rust/LICENSE)
