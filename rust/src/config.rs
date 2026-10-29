//! Immutable configuration. client_secret is masked by a manual Debug impl (a derive would expose it).
use crate::error::{KeycloakError, Result};
use std::time::Duration;

#[derive(Clone)]
pub struct KeycloakConfig {
    pub server_url: String,
    pub realm: String,
    pub client_id: String,
    pub client_secret: Option<String>,
    pub scopes: Vec<String>,
    /// Pin of the algorithms allowed for JWT signature verification (default ["RS256"]). Configurable for ES256/PS256
    /// realms — hardcoding it would reject every legitimate token from such a realm. An empty or unsupported value is
    /// rejected in JwtValidator.
    pub signature_algorithms: Vec<String>,
    pub connect_timeout: Duration,
    pub read_timeout: Duration,
    pub clock_skew: u64,
    /// Minimum interval, in seconds (default 30), between JWKS refetches caused by an unresolved kid (key rotation) — the
    /// DoS amplification cap.
    /// Even forged kids injected back to back cannot hit the IdP more often than this interval allows.
    pub jwks_min_refetch_secs: u64,
    /// The value `validate()` looks for in the token's `aud`. `None` expects `client_id` (the existing behavior).
    /// A stock realm does not put client_id in a client-credentials token's `aud` (it gets there only once an audience
    /// mapper is added), so when the aud is an API name, as for a resource server, set that value here.
    /// It does not apply to `exchange_code`'s id_token check — the id_token's `aud` is always checked against
    /// `client_id` (OIDC Core §3.1.3.7).
    pub expected_audience: Option<String>,
    pub redirect_uri: Option<String>,
}

impl KeycloakConfig {
    /// Validates the required values + strips server_url's trailing slash. Defaults: scopes=["openid"], connect 5s,
    /// read 30s, skew 30s.
    pub fn new(
        server_url: impl Into<String>,
        realm: impl Into<String>,
        client_id: impl Into<String>,
    ) -> Result<Self> {
        let server_url = server_url.into();
        let realm = realm.into();
        let client_id = client_id.into();
        if server_url.trim().is_empty() {
            return Err(KeycloakError::Config("server_url is required".into()));
        }
        if realm.trim().is_empty() {
            return Err(KeycloakError::Config("realm is required".into()));
        }
        if client_id.trim().is_empty() {
            return Err(KeycloakError::Config("client_id is required".into()));
        }
        Ok(Self {
            server_url: server_url.trim_end_matches('/').to_string(),
            realm,
            client_id,
            client_secret: None,
            scopes: vec!["openid".to_string()],
            signature_algorithms: vec!["RS256".to_string()],
            connect_timeout: Duration::from_secs(5),
            read_timeout: Duration::from_secs(30),
            clock_skew: 30,
            jwks_min_refetch_secs: 30,
            expected_audience: None,
            redirect_uri: None,
        })
    }

    #[must_use]
    pub fn with_client_secret(mut self, secret: impl Into<String>) -> Self {
        self.client_secret = Some(secret.into());
        self
    }
    #[must_use]
    pub fn with_redirect_uri(mut self, uri: impl Into<String>) -> Self {
        self.redirect_uri = Some(uri.into());
        self
    }
    /// Sets the JWT signature-verification algorithm pin (ES256/PS256 realms, etc.). An empty list or an unsupported
    /// algorithm is rejected with `KeycloakError::Config` when the JwtValidator is built (KeycloakClient::new).
    #[must_use]
    pub fn with_signature_algorithms(mut self, algs: Vec<String>) -> Self {
        self.signature_algorithms = algs;
        self
    }
    /// Sets the minimum interval, in seconds (default 30), between JWKS refetches caused by an unresolved kid (DoS
    /// amplification cap).
    #[must_use]
    pub fn with_jwks_min_refetch_secs(mut self, secs: u64) -> Self {
        self.jwks_min_refetch_secs = secs;
        self
    }
    /// Sets the value `validate()` expects in the token's `aud` (`client_id` when unset).
    #[must_use]
    pub fn with_expected_audience(mut self, audience: impl Into<String>) -> Self {
        self.expected_audience = Some(audience.into());
        self
    }
}

// 수동 Debug — 시크릿을 절대 노출하지 않는다.
impl std::fmt::Debug for KeycloakConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeycloakConfig")
            .field("server_url", &self.server_url)
            .field("realm", &self.realm)
            .field("client_id", &self.client_id)
            .field("client_secret", &self.client_secret.as_ref().map(|_| "***"))
            .field("scopes", &self.scopes)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_and_trims() {
        let c = KeycloakConfig::new("http://kc:8080/", "it-realm", "it-client").unwrap();
        assert_eq!(c.server_url, "http://kc:8080");
        assert_eq!(c.scopes, vec!["openid".to_string()]);
        assert_eq!(c.clock_skew, 30);
        assert_eq!(c.jwks_min_refetch_secs, 30);
    }

    #[test]
    fn jwks_min_refetch_default_and_custom() {
        let c = KeycloakConfig::new("http://kc:8080", "r", "c").unwrap();
        assert_eq!(c.jwks_min_refetch_secs, 30);
        assert_eq!(c.with_jwks_min_refetch_secs(120).jwks_min_refetch_secs, 120);
    }

    #[test]
    fn expected_audience_default_none_and_custom() {
        let c = KeycloakConfig::new("http://kc:8080", "r", "c").unwrap();
        assert_eq!(c.expected_audience, None); // 미설정 → JwtValidator가 client_id로 폴백
        assert_eq!(
            c.with_expected_audience("api://orders").expected_audience,
            Some("api://orders".to_string())
        );
    }

    #[test]
    fn signature_algorithms_default_and_custom() {
        let c = KeycloakConfig::new("http://kc:8080", "r", "c").unwrap();
        assert_eq!(c.signature_algorithms, vec!["RS256".to_string()]);
        let c2 = c.with_signature_algorithms(vec!["ES256".to_string(), "RS256".to_string()]);
        assert_eq!(
            c2.signature_algorithms,
            vec!["ES256".to_string(), "RS256".to_string()]
        );
    }

    #[test]
    fn missing_required_fields_err() {
        assert!(KeycloakConfig::new("", "r", "c").is_err());
        assert!(KeycloakConfig::new("http://kc:8080", "", "c").is_err());
        assert!(KeycloakConfig::new("http://kc:8080", "r", "").is_err());
    }

    #[test]
    fn whitespace_only_fields_err() {
        // .trim().is_empty()가 공백만 있는 입력도 거부하는지 검증.
        assert!(KeycloakConfig::new("   ", "r", "c").is_err());
        assert!(KeycloakConfig::new("http://kc:8080", "   ", "c").is_err());
        assert!(KeycloakConfig::new("http://kc:8080", "r", "   ").is_err());
    }

    #[test]
    fn debug_masks_secret() {
        let c = KeycloakConfig::new("http://kc:8080", "r", "c")
            .unwrap()
            .with_client_secret("super-secret");
        let s = format!("{c:?}");
        assert!(!s.contains("super-secret"));
        assert!(s.contains("***"));
    }
}
