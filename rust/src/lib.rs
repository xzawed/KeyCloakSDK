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
// pub use config::KeycloakConfig;
// pub use error::{AdminError, KeycloakError};
// pub use tokens::{AuthorizationRequest, IntrospectionResult, TokenSet, ValidatedToken};
// pub use token_provider::{ClientCredentialsTokenProvider, TokenProvider};
// pub use client::KeycloakClient;
