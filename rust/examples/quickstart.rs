//! QuickStart — client-credentials 토큰 발급 → 강화 JWT 검증 → admin 사용자 생성.
//!
//! 실행(Keycloak 필요 — 로컬: `docker run -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin
//! -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin quay.io/keycloak/keycloak:26.6 start-dev`):
//!
//! ```bash
//! cd rust && cargo run --example quickstart
//! ```
// representation 타입은 `keycloak_sdk::types`로 재노출된다 — 소비자가 `keycloak` 크레이트를
// 자기 Cargo.toml에 직접 추가할 필요 없음(재노출이 없으면 게시된 이 예제가 컴파일되지 않는다).
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

    // 1) client-credentials 그랜트로 토큰 발급. access_token 원문은 절대 로그에 남기지 않는다
    //    (TokenSet의 Debug는 access_token/refresh_token을 "***"로 마스킹).
    let token = client.auth().client_credentials_token().await?;
    println!(
        "token type: {}, expires in: {}s",
        token.token_type, token.expires_in
    );

    // 2) 발급받은 액세스 토큰을 자체 강화 검증(RS256 핀·iss 정확일치·aud 포함검사·exp 필수·nbf·클록 스큐).
    let validated = client.auth().validate(&token.access_token).await?;
    println!(
        "subject: {}, issuer: {}",
        validated.subject, validated.issuer
    );

    // 3) 관리 API — 사용자 생성. 생성된 id는 응답 Location 헤더에서 추출(없으면 None).
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
