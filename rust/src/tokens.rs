//! 값 타입 — 시크릿 필드는 수동 Debug로 마스킹.
#[derive(Clone)]
pub struct TokenSet {
    pub access_token: String,
    pub token_type: String,
    pub expires_in: u64,
    pub refresh_token: Option<String>,
    pub id_token: Option<String>,
    pub scope: Option<String>,
    pub expires_at: Option<u64>,
}

impl TokenSet {
    /// expires_at(절대 epoch) 기준 만료(스큐 적용). expires_at 없으면 false.
    pub fn is_expired(&self, now: u64, skew: u64) -> bool {
        match self.expires_at {
            Some(at) => now + skew >= at,
            None => false,
        }
    }
}

impl std::fmt::Debug for TokenSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TokenSet")
            .field("token_type", &self.token_type)
            .field("expires_in", &self.expires_in)
            .field("access_token", &"***")
            .field("refresh_token", &self.refresh_token.as_ref().map(|_| "***"))
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug)]
pub struct ValidatedToken {
    pub subject: String,
    pub audience: Vec<String>,
    pub issuer: String,
    pub expires_at: Option<u64>,
    pub issued_at: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct IntrospectionResult {
    pub active: bool,
    pub username: Option<String>,
    pub client_id: Option<String>,
}

#[derive(Clone)]
pub struct AuthorizationRequest {
    pub url: String,
    pub state: String,
    pub code_verifier: String,
}

impl std::fmt::Debug for AuthorizationRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthorizationRequest")
            .field("url", &self.url)
            .field("state", &self.state)
            .field("code_verifier", &"***")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_expired_with_skew() {
        let ts = TokenSet {
            access_token: "a".into(),
            token_type: "Bearer".into(),
            expires_in: 300,
            refresh_token: None,
            id_token: None,
            scope: None,
            expires_at: Some(1300),
        };
        assert!(!ts.is_expired(1200, 30));
        assert!(ts.is_expired(1290, 30)); // 1290+30 >= 1300
    }

    #[test]
    fn no_expiry_never_expired() {
        let ts = TokenSet {
            access_token: "a".into(),
            token_type: "Bearer".into(),
            expires_in: 0,
            refresh_token: None,
            id_token: None,
            scope: None,
            expires_at: None,
        };
        assert!(!ts.is_expired(9_999_999, 30));
    }

    #[test]
    fn debug_masks_tokens() {
        let ts = TokenSet {
            access_token: "secret-at".into(),
            token_type: "Bearer".into(),
            expires_in: 60,
            refresh_token: Some("secret-rt".into()),
            id_token: None,
            scope: None,
            expires_at: None,
        };
        let s = format!("{ts:?}");
        assert!(!s.contains("secret-at") && !s.contains("secret-rt") && s.contains("***"));
    }
}
