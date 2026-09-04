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
    /// JWT 서명 검증 허용 알고리즘 핀(기본 ["RS256"]). ES256/PS256 realm용으로 설정 가능 —
    /// 하드코딩하면 그런 realm의 정상 토큰이 전부 거부된다. 빈/미지원 값은 JwtValidator에서 거부.
    pub signature_algorithms: Vec<String>,
    pub connect_timeout: Duration,
    pub read_timeout: Duration,
    pub clock_skew: u64,
    /// 미해결 kid(키 회전)로 인한 JWKS 재조회의 최소 간격(초, 기본 30) — DoS 증폭 상한.
    /// 위조 kid를 연속 주입해도 이 간격보다 자주 IdP를 때리지 못한다.
    pub jwks_min_refetch_secs: u64,
    /// `validate()`가 토큰 `aud`에서 찾을 값. `None`이면 `client_id`를 기대한다(기존 동작).
    /// 기본 realm은 client-credentials 토큰 `aud`에 client_id를 넣지 않으므로(audience 매퍼를
    /// 추가해야 들어간다), 리소스 서버처럼 API 이름이 aud면 여기에 그 값을 설정한다.
    /// 같은 검증기를 쓰는 `exchange_code`의 id_token 검사에도 함께 적용된다.
    pub expected_audience: Option<String>,
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
    /// JWT 서명 검증 알고리즘 핀을 설정한다(ES256/PS256 realm 등). 비었거나 미지원 알고리즘이면
    /// JwtValidator 구성 시점(KeycloakClient::new)에 `KeycloakError::Config`로 거부된다.
    #[must_use]
    pub fn with_signature_algorithms(mut self, algs: Vec<String>) -> Self {
        self.signature_algorithms = algs;
        self
    }
    /// 미해결 kid로 인한 JWKS 재조회의 최소 간격(초)을 설정한다(DoS 증폭 상한, 기본 30).
    #[must_use]
    pub fn with_jwks_min_refetch_secs(mut self, secs: u64) -> Self {
        self.jwks_min_refetch_secs = secs;
        self
    }
    /// `validate()`가 토큰 `aud`에서 기대할 값을 설정한다(미설정이면 `client_id`).
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
