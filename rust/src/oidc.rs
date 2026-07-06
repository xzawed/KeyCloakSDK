//! OIDC 엔드포인트 조립(네트워크 없음).
use crate::config::KeycloakConfig;

pub struct OidcEndpoints {
    base: String,
}

impl OidcEndpoints {
    pub fn new(config: &KeycloakConfig) -> Self {
        Self {
            base: format!("{}/realms/{}", config.server_url, config.realm),
        }
    }
    pub fn issuer(&self) -> String {
        self.base.clone()
    }
    pub fn token(&self) -> String {
        format!("{}/protocol/openid-connect/token", self.base)
    }
    pub fn authorization(&self) -> String {
        format!("{}/protocol/openid-connect/auth", self.base)
    }
    pub fn introspection(&self) -> String {
        format!("{}/protocol/openid-connect/token/introspect", self.base)
    }
    pub fn end_session(&self) -> String {
        format!("{}/protocol/openid-connect/logout", self.base)
    }
    pub fn jwks(&self) -> String {
        format!("{}/protocol/openid-connect/certs", self.base)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::KeycloakConfig;

    #[test]
    fn assembly() {
        let c = KeycloakConfig::new("http://kc:8080", "it-realm", "c").unwrap();
        let e = OidcEndpoints::new(&c);
        assert_eq!(e.issuer(), "http://kc:8080/realms/it-realm");
        assert_eq!(
            e.token(),
            "http://kc:8080/realms/it-realm/protocol/openid-connect/token"
        );
        assert_eq!(
            e.authorization(),
            "http://kc:8080/realms/it-realm/protocol/openid-connect/auth"
        );
        assert_eq!(
            e.introspection(),
            "http://kc:8080/realms/it-realm/protocol/openid-connect/token/introspect"
        );
        assert_eq!(
            e.end_session(),
            "http://kc:8080/realms/it-realm/protocol/openid-connect/logout"
        );
        assert_eq!(
            e.jwks(),
            "http://kc:8080/realms/it-realm/protocol/openid-connect/certs"
        );
    }
}
