//! DoS-safe JWKS: kid 캐시, 미해결 kid만 재조회, rate-limit + single-flight.
use crate::error::{KeycloakError, Result};
use jsonwebtoken::jwk::{Jwk, JwkSet};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex, RwLock};

pub struct JwksStore {
    jwks_uri: String,
    http: reqwest::Client,
    cache: RwLock<Option<Arc<JwkSet>>>,
    refetch_gate: Mutex<Option<u64>>, // 마지막 재조회 시각(초); single-flight + rate-limit
    min_refetch: u64,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl JwksStore {
    pub fn new(jwks_uri: impl Into<String>, http: reqwest::Client, min_refetch_secs: u64) -> Self {
        Self {
            jwks_uri: jwks_uri.into(),
            http,
            cache: RwLock::new(None),
            refetch_gate: Mutex::new(None),
            min_refetch: min_refetch_secs,
        }
    }

    async fn fetch(&self) -> Result<Arc<JwkSet>> {
        let resp = self
            .http
            .get(&self.jwks_uri)
            .send()
            .await
            .map_err(|e| KeycloakError::Transport(format!("JWKS fetch: {e}")))?;
        let set: JwkSet = resp
            .json()
            .await
            .map_err(|e| KeycloakError::Transport(format!("JWKS parse: {e}")))?;
        let arc = Arc::new(set);
        *self.cache.write().await = Some(arc.clone());
        Ok(arc)
    }

    /// kid로 JWK 조회. 캐시 히트=네트워크 0. 미해결 kid만 rate-limited 재조회.
    pub async fn get_key(&self, kid: &str) -> Result<Jwk> {
        // 초기 로드(캐시 없음) — rate-limit 예산 미소모
        {
            let c = self.cache.read().await;
            if let Some(set) = c.as_ref()
                && let Some(jwk) = set.find(kid)
            {
                return Ok(jwk.clone());
            }
        }
        if self.cache.read().await.is_none() {
            let set = self.fetch().await?;
            if let Some(jwk) = set.find(kid) {
                return Ok(jwk.clone());
            }
        }
        // 미해결 kid → single-flight + rate-limit 재조회
        let mut gate = self.refetch_gate.lock().await;
        // gate 획득 후 재확인(다른 태스크가 방금 갱신했을 수 있음)
        if let Some(set) = self.cache.read().await.as_ref()
            && let Some(jwk) = set.find(kid)
        {
            return Ok(jwk.clone());
        }
        let now = now_secs();
        if let Some(last) = *gate
            && now.saturating_sub(last) < self.min_refetch
        {
            return Err(KeycloakError::TokenValidation(format!(
                "unknown kid '{kid}' (refetch rate-limited)"
            )));
        }
        let set = self.fetch().await?;
        *gate = Some(now);
        set.find(kid)
            .cloned()
            .ok_or_else(|| KeycloakError::TokenValidation(format!("unknown kid '{kid}'")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn jwks_json(kid: &str) -> serde_json::Value {
        serde_json::json!({ "keys": [ { "kty":"RSA","kid":kid,"use":"sig","alg":"RS256",
            "n":"sXchg","e":"AQAB" } ] })
    }

    #[tokio::test]
    async fn cache_hit_no_network_after_first() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .expect(1) // 두 번째 get_key는 캐시
            .mount(&server)
            .await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            60,
        );
        assert_eq!(
            store.get_key("k1").await.unwrap().common.key_id.as_deref(),
            Some("k1")
        );
        assert_eq!(
            store.get_key("k1").await.unwrap().common.key_id.as_deref(),
            Some("k1")
        );
    }

    #[tokio::test]
    async fn unresolved_kid_refetches_once_then_rate_limited() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .expect(2) // 초기 로드 + k2 미해결 1회. k3는 rate-limit로 재조회 없음
            .mount(&server)
            .await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            60,
        );
        store.get_key("k1").await.unwrap(); // fetch #1(초기)
        let _ = store.get_key("k2").await; // 미해결 → refetch #2
        let _ = store.get_key("k3").await; // rate-limit → refetch 없음
    }
}
