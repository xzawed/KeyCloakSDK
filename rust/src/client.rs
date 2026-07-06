//! 통합 진입점 — 공유 reqwest 1개(SSRF·타임아웃·TLS)를 auth·jwks·admin에 주입.
use crate::admin::AdminClient;
use crate::auth::AuthClient;
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::jwks::JwksStore;
use crate::jwt::JwtValidator;
use crate::oidc::OidcEndpoints;
use crate::token_provider::TokenProvider;
use keycloak::prelude::reqwest;
use std::sync::Arc;

pub struct KeycloakClient {
    auth: Arc<AuthClient>,
    admin: AdminClient,
}

impl KeycloakClient {
    pub fn new(config: KeycloakConfig) -> Result<Self> {
        let endpoints = OidcEndpoints::new(&config);
        // 공유 reqwest — SSRF 하드닝(redirect none) + 타임아웃 + rustls(TLS on).
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(config.connect_timeout)
            .timeout(config.read_timeout)
            .build()
            .map_err(|e| KeycloakError::Config(format!("http client: {e}")))?;

        let jwks = JwksStore::new(endpoints.jwks(), http.clone(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks);
        let auth = Arc::new(AuthClient::new(
            config.clone(),
            OidcEndpoints::new(&config),
            http.clone(),
            validator,
        )?);
        let admin = AdminClient::new(
            &config,
            http.clone(),
            auth.clone() as Arc<dyn TokenProvider>,
        );
        Ok(Self { auth, admin })
    }

    pub fn auth(&self) -> &AuthClient {
        &self.auth
    }
    pub fn admin(&self) -> &AdminClient {
        &self.admin
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_client() {
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s");
        let client = KeycloakClient::new(cfg).unwrap();
        // auth/admin 접근자가 동작(네트워크 없음 — 조립만 검증)
        let _ = client.auth();
        let _ = client.admin();
    }
}
