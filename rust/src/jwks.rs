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
        // 재조회 결정 시점에 stamp — fetch 실패해도 rate-limit이 걸리도록(Go/Python 동형).
        // fetch가 실패해도 gate는 이미 소모되어 IdP 장애창에서 재시도 폭주를 상한한다.
        *gate = Some(now);
        let set = self.fetch().await?;
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

    /// 회귀테스트: IdP 장애창(fetch 실패)에서도 gate가 재조회 "결정 시점"에 stamp되어야
    /// 다음 미해결 kid 조회가 rate-limit된다(Go `forcedAt`/Python `_jwks_forced_at` 동형).
    /// 수정 전(스탬프가 fetch *성공 후*에만 찍힘)이라면 GET#2(500)가 실패해 gate가 unset으로
    /// 남고, get_key("k3")가 다시 재조회를 시도해 certs에 3번째 GET이 발생 → 이 테스트가 실패한다.
    #[tokio::test]
    async fn fetch_failure_still_stamps_gate_rate_limiting_next_lookup() {
        let server = MockServer::start().await;
        // GET#1: 초기 로드 — 200 + {k1}. up_to_n_times(1)로 1회만 응답하고 이후 소진.
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .up_to_n_times(1)
            .with_priority(1) // 200 mock이 소진되기 전까지 500 fallback보다 우선 매치
            .expect(1)
            .mount(&server)
            .await;
        // GET#2(그 이후): IdP 장애 — 500. k2의 게이트된 재조회에서 정확히 1회만 맞아야 한다
        // (k3는 rate-limit로 막혀 여기까지 도달하면 안 됨 — 수정 전이면 2회가 되어 expect(1) 위반).
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(500))
            .expect(1)
            .mount(&server)
            .await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            60,
        );

        // GET#1 → {k1}: 초기 로드가 캐시를 채운다(rate-limit 예산 미소모).
        store.get_key("k1").await.unwrap();

        // GET#2 → 500: 미해결 kid가 게이트된 재조회를 트리거한다 — fetch는 실패하지만
        // (수정 후) gate는 이미 stamp되어 있다.
        let err2 = store.get_key("k2").await.unwrap_err();
        assert!(
            matches!(err2, KeycloakError::Transport(_)),
            "expected Transport error from the failed fetch, got {err2:?}"
        );

        // GET#3 없어야 함: gate가 stamp되어 min_refetch 창 안이므로 즉시 rate-limited.
        let err3 = store.get_key("k3").await.unwrap_err();
        match err3 {
            KeycloakError::TokenValidation(msg) => assert!(
                msg.contains("rate-limited"),
                "expected a rate-limited TokenValidation message, got: {msg}"
            ),
            other => panic!("expected TokenValidation(rate-limited), got {other:?}"),
        }

        // 명시적 이중검증: certs 엔드포인트에 정확히 2건만 도달했는지 직접 카운트
        // (수정 전이면 k3도 재조회를 시도해 3건이 된다).
        let received = server
            .received_requests()
            .await
            .expect("request recording is enabled by default");
        let certs_hits = received.iter().filter(|r| r.url.path() == "/certs").count();
        assert_eq!(
            certs_hits, 2,
            "expected exactly 2 GETs to /certs (initial load + one gated refetch on failure), got {certs_hits}"
        );
    }
}
