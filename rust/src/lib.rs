//! Keycloak SDK for Rust — async OIDC auth + Admin REST.
#![forbid(unsafe_code)]

pub mod admin;
pub mod auth;
pub mod client;
pub mod config;
pub mod error;
pub mod jwks;
pub mod jwt;
pub mod oidc;
pub mod token_provider;
pub mod tokens;

// re-exports 활성화는 각 타입 구현 후(Task 2~10)
pub use admin::AdminClient;
pub use auth::AuthClient;
pub use client::KeycloakClient;
pub use config::KeycloakConfig;
pub use error::{AdminError, KeycloakError};
pub use jwt::JwtValidator;
pub use oidc::OidcEndpoints;
pub use token_provider::{ClientCredentialsTokenProvider, TokenProvider};
pub use tokens::{AuthorizationRequest, IntrospectionResult, TokenSet, ValidatedToken};

// ── 하위 crate 타입 재노출 ──
// 공개 API가 실제로 받거나 돌려주는 foreign 타입만 재노출한다(§4(b) 문서화된 은닉성 예외).
// 이게 없으면 소비자가 `keycloak`/`reqwest`를 자기 Cargo.toml에 버전까지 맞춰 직접 추가해야만
// admin 파사드를 호출할 수 있다(공개 퀵스타트가 그대로는 컴파일되지 않는다).

/// admin 파사드가 데이터 모델로 그대로 노출하는 representation 타입(`keycloak::types` 미러).
/// admin.rs의 공개 시그니처에 나타나는 5종 전부다.
pub mod types {
    pub use keycloak::types::{
        ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
        UserRepresentation,
    };
}

// `AdminClient::raw()`의 반환 타입 `&KeycloakAdmin<SdkTokenSupplier>`를 이름 붙이는 데 필요한 둘
// (`KeycloakAdmin`은 foreign, `SdkTokenSupplier`는 우리 것이지만 루트에 없었다).
pub use admin::SdkTokenSupplier;
pub use keycloak::KeycloakAdmin;
// 저수준 주입 지점(`AdminClient::new`·`AuthClient::new`·`ClientCredentialsTokenProvider::new`·
// `JwksStore::new`)이 받는 공유 HTTP 클라이언트 — SDK가 실제로 쓰는 crate를 그대로 재노출한다.
pub use reqwest;
