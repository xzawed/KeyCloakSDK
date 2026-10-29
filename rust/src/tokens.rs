//! Value types — secret fields are masked by a manual Debug impl.
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
    /// Expiry judged against expires_at (absolute epoch), with the skew applied. An unknown expires_at is conservatively
    /// treated as true (isomorphic with Go/Python/Node/C#/Kotlin) — this stops a provider from caching a token of
    /// unknown expiry forever, which would make admin fail permanently once that token expires (Keycloak's standard
    /// flows always send expires_in, so the real paths are unaffected).
    pub fn is_expired(&self, now: u64, skew: u64) -> bool {
        match self.expires_at {
            Some(at) => now + skew >= at,
            None => true,
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
    /// The full map of validated claims (isomorphic with the sibling SDKs' ValidatedToken.claims) — for accessing
    /// non-standard claims such as nonce.
    pub claims: std::collections::BTreeMap<String, serde_json::Value>,
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
    /// OIDC nonce — keep it until the callback, then pass it to exchange_code(expected_nonce) to block id_token replay.
    pub nonce: String,
}

impl std::fmt::Debug for AuthorizationRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthorizationRequest")
            .field("url", &self.url)
            .field("state", &self.state)
            .field("code_verifier", &"***")
            .field("nonce", &self.nonce)
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
    fn unknown_expiry_treated_as_expired() {
        // expires_at=None(만료 불명)은 보수적으로 만료로 판정 — provider가 영구 캐시하지 않도록
        // (자매 SDK 동형). 이전엔 !is_expired가 항상 true라 만료 불명 토큰이 영구 재사용됐다.
        let ts = TokenSet {
            access_token: "a".into(),
            token_type: "Bearer".into(),
            expires_in: 0,
            refresh_token: None,
            id_token: None,
            scope: None,
            expires_at: None,
        };
        assert!(ts.is_expired(9_999_999, 30));
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

    // PKCE 검증자는 코드 교환의 소유 증명 비밀이라, 인가 코드를 훔친 공격자가 로그에서 이 값을
    // 얻으면 흐름을 완성한다. `AuthorizationRequest` 는 `#[derive(Debug)]` 가 아니라 손으로 쓴
    // impl 이고, 그 impl 이 지워지거나 `&self.code_verifier` 로 바뀌면 `{:?}` 가 원문을 찍는다.
    // 자매 여덟 언어에는 이 단언이 이미 있었고 rust 만 없었다(실측 2026-09-06).
    #[test]
    fn debug_masks_code_verifier() {
        let ar = AuthorizationRequest {
            url: "https://kc.example/auth?x=1".into(),
            state: "st".into(),
            code_verifier: "secret-verifier".into(),
            nonce: "nc".into(),
        };
        let s = format!("{ar:?}");
        assert!(
            !s.contains("secret-verifier"),
            "code_verifier 가 원문으로 샜다: {s}"
        );
        assert!(s.contains("***"));
        // url/state/nonce 는 비밀이 아니므로 가리지 않는다 — 자매 SDK 와 동형이다.
        assert!(s.contains("st") && s.contains("nc"));
    }
}
