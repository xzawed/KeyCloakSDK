//! OIDC endpoint assembly and the authorization request's scopes (no network).
use crate::config::KeycloakConfig;
use openidconnect::Scope;

/// The scopes the authorization request adds to the `openid` that openidconnect's `authorize_url` always puts first:
/// the configured ones without an exact `openid`, which would otherwise be sent twice (`scope=openid+openid`). Only the
/// authorization request — client_credentials sends the configured scopes as they are.
// 등록부 rust-authz-scope-openid-duplicated. auth.rs 는 커버리지 경계라 규칙은 여기 있고 auth.rs 는 한 줄로 부른다.
pub(crate) fn authorization_scopes(configured: &[String]) -> Vec<Scope> {
    configured
        .iter()
        .filter(|s| s.as_str() != "openid")
        .map(|s| Scope::new(s.clone()))
        .collect()
}

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

    /// 정확한 `openid` 만 뺀다 — 순서는 그대로, 다른 철자(`OpenID`)는 남긴다.
    #[test]
    fn authorization_scopes_leave_out_an_exact_openid() {
        let names = |configured: &[&str]| -> Vec<String> {
            let configured: Vec<String> = configured.iter().map(|s| s.to_string()).collect();
            authorization_scopes(&configured)
                .iter()
                .map(|s| s.as_str().to_string())
                .collect()
        };
        assert!(names(&[]).is_empty());
        assert!(names(&["openid"]).is_empty());
        assert_eq!(names(&["openid", "profile"]), ["profile"]);
        assert_eq!(names(&["email", "openid", "OpenID"]), ["email", "OpenID"]);
    }
}
