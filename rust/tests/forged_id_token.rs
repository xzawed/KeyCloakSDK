//! 서명만 틀린 RS256 id_token(nonce 는 일치)을 공개 `exchange_code*` 가 거부한다.
//!
//! 실서버는 이런 토큰을 만들 수 없다 — realm 개인키가 없으면 JWKS 에 있는 kid 로 서명할 수 없다. 그래서
//! 통합(`integration_test.rs` 의 `code_exchange`)이 아니라 가짜 IdP 로 잰다. 통합의 HS256 시나리오는
//! kid 해석 단계에서 이미 거부되므로(HMAC 키는 JWKS 에 없다) **서명 검사까지 닿지 않는다.**
//!
//! `src/auth.rs` 의 `verify_nonce_rejects_untrusted_id_token` 이 같은 모양의 토큰을 `verify_nonce` 에
//! **직접** 넣는다. 여기는 공개 교환을 거친다 — 교환이 id_token 을 그 검증기로 보내지 않게 되는 회귀는
//! 그 단위 테스트가 못 본다(같은 파일의 `exchange_code_rejects_*_end_to_end` 가 nonce 에 대해 같은
//! 이유로 있다).
//!
//! 대조군: 같은 kid·같은 클레임을 **JWKS 의 키로** 서명하면 통과한다 — 거부가 서명 때문임을 보인다.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use keycloak_sdk::error::Result;
use keycloak_sdk::{KeycloakClient, KeycloakConfig, KeycloakError, TokenSet};
use rsa::pkcs1::{EncodeRsaPrivateKey, LineEnding};
use rsa::traits::PublicKeyParts;
use rsa::{RsaPrivateKey, RsaPublicKey};
use serde_json::json;
use std::time::{SystemTime, UNIX_EPOCH};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const CLIENT_ID: &str = "it-web";
const KID: &str = "realm-signing-key";
const NONCE: &str = "the-nonce-the-sdk-issued";
const REDIRECT_URI: &str = "https://app.example/callback";

/// (개인키 PEM, 공개 JWK) — JWK 의 kid 는 늘 `KID` 다.
fn rsa_key() -> (String, serde_json::Value) {
    let private = RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
    let public = RsaPublicKey::from(&private);
    let jwk = json!({
        "kty": "RSA", "kid": KID, "use": "sig", "alg": "RS256",
        "n": URL_SAFE_NO_PAD.encode(public.n().to_bytes_be()),
        "e": URL_SAFE_NO_PAD.encode(public.e().to_bytes_be()),
    });
    let pem = private.to_pkcs1_pem(LineEnding::LF).unwrap().to_string();
    (pem, jwk)
}

/// kid·iss·aud·exp·nonce 가 전부 맞는 id_token — 서명한 키만 다를 수 있다.
fn id_token(signer_pem: &str, issuer: &str) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some(KID.into());
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let claims = json!({
        "sub": "alice-id", "iss": issuer, "aud": CLIENT_ID,
        "exp": now + 300, "iat": now, "nonce": NONCE,
    });
    encode(
        &header,
        &claims,
        &EncodingKey::from_rsa_pem(signer_pem.as_bytes()).unwrap(),
    )
    .unwrap()
}

/// JWKS 에는 `published` 만 올리고, 토큰 엔드포인트는 `signer` 로 서명한 id_token 을 주는 가짜 IdP.
async fn exchange_both_ways(
    published: &serde_json::Value,
    signer_pem: &str,
) -> [Result<TokenSet>; 2] {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/realms/it-realm/protocol/openid-connect/certs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "keys": [published] })))
        .mount(&server)
        .await;
    let issuer = format!("{}/realms/it-realm", server.uri());
    Mock::given(method("POST"))
        .and(path("/realms/it-realm/protocol/openid-connect/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "AT", "token_type": "Bearer", "expires_in": 300,
            "refresh_token": "RT", "id_token": id_token(signer_pem, &issuer),
        })))
        .mount(&server)
        .await;
    let config = KeycloakConfig::new(server.uri(), "it-realm", CLIENT_ID)
        .unwrap()
        .with_client_secret("s")
        .with_redirect_uri(REDIRECT_URI);
    let kc = KeycloakClient::new(config).unwrap();
    [
        kc.auth()
            .exchange_code("code", "verifier", Some(NONCE))
            .await,
        kc.auth()
            .exchange_code_with_redirect("code", "verifier", REDIRECT_URI, Some(NONCE))
            .await,
    ]
}

#[tokio::test]
async fn exchange_refuses_a_forged_rs256_id_token_whose_nonce_matches() {
    let (_, published) = rsa_key();
    let (forger, _) = rsa_key();
    for result in exchange_both_ways(&published, &forger).await {
        match result {
            Err(KeycloakError::Auth {
                message,
                oauth_error: None,
            }) => assert_eq!(
                message,
                "authorization code exchange failed: invalid id_token: \
                 token validation error: token verification failed: invalid signature"
            ),
            other => panic!("a forged id_token must be refused for its signature, got {other:?}"),
        }
    }
}

#[tokio::test]
async fn exchange_accepts_the_same_id_token_signed_by_the_published_key() {
    let (signer, published) = rsa_key();
    for result in exchange_both_ways(&published, &signer).await {
        let tokens =
            result.expect("the control must pass — otherwise the refusal above proves nothing");
        assert!(tokens.id_token.is_some());
    }
}
