//! 불변 설정. client_secret은 수동 Debug로 마스킹(derive는 노출).
use crate::error::{KeycloakError, Result};
use std::time::Duration;

#[derive(Clone)]
pub struct KeycloakConfig {
    pub server_url: String,
    pub realm: String,
    pub client_id: String,
    pub client_secret: Option<String>,
    pub scopes: Vec<String>,
    pub connect_timeout: Duration,
    pub read_timeout: Duration,
    pub clock_skew: u64,
    pub redirect_uri: Option<String>,
}

impl KeycloakConfig {
    /// 필수값 검증 + server_url 후행 슬래시 제거. 기본값: scopes=["openid"], connect 5s, read 30s, skew 30s.
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
            connect_timeout: Duration::from_secs(5),
            read_timeout: Duration::from_secs(30),
            clock_skew: 30,
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
    }

    #[test]
    fn missing_required_fields_err() {
        assert!(KeycloakConfig::new("", "r", "c").is_err());
        assert!(KeycloakConfig::new("http://kc:8080", "", "c").is_err());
        assert!(KeycloakConfig::new("http://kc:8080", "r", "").is_err());
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
