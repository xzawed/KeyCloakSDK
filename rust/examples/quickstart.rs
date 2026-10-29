//! QuickStart — get a client-credentials token → hardened JWT validation → create a user through the admin API.
//!
//! Run (needs Keycloak — locally: `docker run -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin
//! -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin quay.io/keycloak/keycloak:26.6 start-dev`):
//!
//! ```bash
//! cd rust && cargo run --example quickstart
//! ```
// The representation types are re-exported as `keycloak_sdk::types`, so a consumer does not add the `keycloak`
// crate to their own Cargo.toml (without the re-export this published example would not compile).
use keycloak_sdk::types::UserRepresentation;
use keycloak_sdk::{KeycloakClient, KeycloakConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = KeycloakConfig::new(
        std::env::var("KC_SERVER_URL").unwrap_or_else(|_| "http://localhost:8080".into()),
        std::env::var("KC_REALM").unwrap_or_else(|_| "it-realm".into()),
        std::env::var("KC_CLIENT_ID").unwrap_or_else(|_| "it-client".into()),
    )?
    .with_client_secret(std::env::var("KC_CLIENT_SECRET").unwrap_or_else(|_| "it-secret".into()));

    let client = KeycloakClient::new(cfg)?;

    // 1) Get a token with the client-credentials grant. Never log the raw access_token
    //    (TokenSet's Debug masks access_token/refresh_token as "***").
    let token = client.auth().client_credentials_token().await?;
    println!(
        "token type: {}, expires in: {}s",
        token.token_type, token.expires_in
    );

    // 2) Validate the issued access token with the self-hardened checks (RS256 pin · exact iss · aud membership ·
    //    required exp · nbf · clock skew).
    let validated = client.auth().validate(&token.access_token).await?;
    println!(
        "subject: {}, issuer: {}",
        validated.subject, validated.issuer
    );

    // 3) Admin API — create a user. The new id is taken from the response's Location header (None if absent).
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
