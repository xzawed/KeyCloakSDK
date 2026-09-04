//! DoS-safe JWKS: kid 캐시, 미해결 kid만 재조회, rate-limit + single-flight.
use crate::error::{KeycloakError, Result};
use jsonwebtoken::jwk::{Jwk, JwkSet};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::time::Instant; // ⚠️ std 가 아니라 tokio 시계다 — `start_paused` 테스트가 백오프 창을
// 결정적으로 넘길 수 있어야 한다(실시간 sleep 없이).
use tokio::sync::{Mutex, RwLock};

/// ⚠️ **실패한 fetch 의 백오프 — `min_refetch` 와 다른 축이다.**
/// `min_refetch`(30초)는 *캐시가 찬 뒤* 미해결 kid 홍수를 막는다. 아래 둘은 **캐시가 비어 있고
/// fetch 가 계속 실패할 때**를 막는다. 그 자리에는 게이트가 없어서, 측정상 20회 조회가 IdP 요청
/// 20건을 그대로 냈다(2026-09-04 · 7개 언어 동일).
///
/// ⚠️ **여기에 `min_refetch`(30초)를 재사용하면 안 된다** — 일시적 503 한 번이 「30초간 어떤
/// 토큰도 검증 불가」가 된다. 그래서 짧게 시작해 지수적으로 늘리고 상한을 둔다.
const FAILURE_BACKOFF_BASE: Duration = Duration::from_millis(200);
const FAILURE_BACKOFF_CAP: Duration = Duration::from_secs(5);

/// 게이트 상태. **하나의 뮤텍스가 두 축을 함께 소유한다** — 강제 재조회의 30초 rate-limit 과
/// 실패 fetch 의 백오프. 잠금을 나누면 「검사 후 fetch」 사이에 다른 태스크가 끼어들 수 있다.
#[derive(Default)]
struct Gate {
    last_refetch: Option<Instant>, // 마지막 *강제* 재조회 결정 시각
    failures: u32,                 // 연속 fetch 실패 횟수(성공 시 0)
    last_failure: Option<Instant>, // 마지막 fetch 실패 시각
}

impl Gate {
    /// 백오프 잔여 시간. 0 이면 fetch 를 허용한다.
    fn backoff_remaining(&self, now: Instant) -> Duration {
        let Some(last) = self.last_failure else {
            return Duration::ZERO;
        };
        self.backoff_delay()
            .saturating_sub(now.saturating_duration_since(last))
    }

    /// 지수 백오프 + jitter([0.5, 1.0] 배수). jitter 는 여러 인스턴스가 같은 순간에 복구를
    /// 시도해 IdP 를 다시 무너뜨리는 것(thundering herd)을 흩는다.
    ///
    /// ⚠️ jitter 원천이 `rand` 가 아니라 벽시계 나노초인 것은 의도다 — 런타임 의존을 하나
    /// 늘리지 않으려는 것이고, 이 값은 암호용이 아니라 **분산용**이라 그 강도로 충분하다.
    fn backoff_delay(&self) -> Duration {
        let shift = self.failures.max(1) - 1;
        let raw = FAILURE_BACKOFF_BASE
            .saturating_mul(1u32.checked_shl(shift.min(31)).unwrap_or(u32::MAX))
            .min(FAILURE_BACKOFF_CAP);
        raw.mul_f64(jitter())
    }
}

/// [0.5, 1.0) 배수.
fn jitter() -> f64 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    0.5 + f64::from(nanos % 1_000_000) / 2_000_000.0
}

pub struct JwksStore {
    jwks_uri: String,
    http: reqwest::Client,
    cache: RwLock<Option<Arc<JwkSet>>>,
    gate: Mutex<Gate>, // single-flight + rate-limit + 실패 백오프
    min_refetch: u64,
}

impl JwksStore {
    pub fn new(jwks_uri: impl Into<String>, http: reqwest::Client, min_refetch_secs: u64) -> Self {
        Self {
            jwks_uri: jwks_uri.into(),
            http,
            cache: RwLock::new(None),
            gate: Mutex::new(Gate::default()),
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

    fn lookup(set: Option<&Arc<JwkSet>>, kid: &str) -> Option<Jwk> {
        set.and_then(|s| s.find(kid)).cloned()
    }

    /// kid로 JWK 조회. 캐시 히트=네트워크 0. 미해결 kid만 rate-limited 재조회.
    pub async fn get_key(&self, kid: &str) -> Result<Jwk> {
        if let Some(jwk) = Self::lookup(self.cache.read().await.as_ref(), kid) {
            return Ok(jwk);
        }
        // ⚠️ gate 획득이 **콜드 로드와 강제 재조회 양쪽의** single-flight 지점이다. 예전에는
        // 콜드 로드가 이 잠금 **밖**에 있어서, 20개 태스크가 동시에 첫 검증을 하면 IdP 로
        // 20건이 나갔다 — **정상(200) 엔드포인트에서도** 그랬다(실측 20/20).
        let mut gate = self.gate.lock().await;
        let cold = {
            let c = self.cache.read().await;
            // gate 획득 후 재확인(다른 태스크가 방금 채웠을 수 있음)
            if let Some(jwk) = Self::lookup(c.as_ref(), kid) {
                return Ok(jwk);
            }
            c.is_none()
        };

        if !cold {
            // 미해결 kid → rate-limit 재조회. 콜드 로드는 이 예산을 쓰지 않는다.
            if let Some(last) = gate.last_refetch
                && Instant::now().saturating_duration_since(last)
                    < Duration::from_secs(self.min_refetch)
            {
                return Err(KeycloakError::TokenValidation(format!(
                    "unknown kid '{kid}' (refetch rate-limited)"
                )));
            }
            // 재조회 결정 시점에 stamp — fetch 실패해도 rate-limit이 걸리도록(Go/Python 동형).
            gate.last_refetch = Some(Instant::now());
        }

        // ⚠️ 백오프 검사는 fetch **직전**이자 30초 게이트 **이후**다. 콜드 캐시에서는 위 분기가
        // 통째로 건너뛰어지므로, 이 줄이 없으면 매 조회가 IdP 로 나간다(그게 원래 결함이다).
        let remaining = gate.backoff_remaining(Instant::now());
        if !remaining.is_zero() {
            return Err(KeycloakError::Transport(format!(
                "JWKS fetch backing off after {} consecutive failures (retry in {:.2}s)",
                gate.failures,
                remaining.as_secs_f64()
            )));
        }

        match self.fetch().await {
            Ok(set) => {
                gate.failures = 0;
                gate.last_failure = None;
                Self::lookup(Some(&set), kid)
                    .ok_or_else(|| KeycloakError::TokenValidation(format!("unknown kid '{kid}'")))
            }
            Err(e) => {
                gate.failures = gate.failures.saturating_add(1);
                gate.last_failure = Some(Instant::now());
                Err(e)
            }
        }
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

    // ⚠️ 여기부터가 콜드 캐시 + IdP 장애 축이다. `min_refetch`(30초) 게이트는 *캐시가 찬 뒤*
    // 미해결 kid 홍수만 막는다 — 캐시가 비어 있고 fetch 가 계속 실패하면 그 게이트에 닿지도
    // 못한다. 실측(2026-09-04): 20회 조회 → IdP 요청 **20건**, 7개 언어 동일.

    async fn failing_server() -> MockServer {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;
        server
    }

    async fn certs_hits(server: &MockServer) -> usize {
        server
            .received_requests()
            .await
            .expect("request recording is enabled by default")
            .iter()
            .filter(|r| r.url.path() == "/certs")
            .count()
    }

    #[tokio::test(start_paused = true)]
    async fn failing_idp_bounds_cold_retries_to_one_request() {
        let server = failing_server().await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            30,
        );
        for _ in 0..20 {
            assert!(store.get_key("k1").await.is_err());
        }
        assert_eq!(
            certs_hits(&server).await,
            1,
            "cold cache + failing IdP: 20 lookups must collapse to one outbound request"
        );
    }

    /// ⚠️ **이 테스트를 지우지 말 것 — 위 단언은 「한 번 실패하면 영원히 차단」으로도 통과한다.**
    /// 그 동작은 원래 결함보다 나쁘다(IdP 가 복구돼도 SDK 가 영영 못 쓴다).
    #[tokio::test(start_paused = true)]
    async fn backoff_expires_and_allows_a_retry() {
        let server = failing_server().await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            30,
        );

        assert!(store.get_key("k1").await.is_err());
        assert_eq!(certs_hits(&server).await, 1);

        // 창 안 — 네트워크로 나가지 않고 즉시 실패한다(sleep 하지 않는다).
        match store.get_key("k1").await.unwrap_err() {
            KeycloakError::Transport(msg) => {
                assert!(msg.contains("backing off"), "got: {msg}")
            }
            other => panic!("expected Transport(backing off), got {other:?}"),
        }
        assert_eq!(certs_hits(&server).await, 1);

        // 창을 넘기면(상한 5초보다 크게 민다) 다시 나간다.
        tokio::time::advance(Duration::from_secs(10)).await;
        assert!(store.get_key("k1").await.is_err());
        assert_eq!(certs_hits(&server).await, 2);
    }

    /// ⚠️ 대조군 둘째 — 성공이 실패 카운터를 되돌리지 않으면 오래 산 프로세스에서 백오프가
    /// 상한까지 올라간 채 영영 내려오지 않는다.
    #[tokio::test(start_paused = true)]
    async fn success_resets_the_failure_counter() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(500))
            .up_to_n_times(1)
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .mount(&server)
            .await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            30,
        );

        assert!(store.get_key("k1").await.is_err()); // 실패 1회 — failures=1
        tokio::time::advance(Duration::from_secs(10)).await;
        store.get_key("k1").await.unwrap(); // 성공 — failures=0 이어야 한다

        // 카운터가 0 이면 다음 실패의 창은 다시 base(0.2초)에서 시작한다. 0.2초를 넘겨도
        // 여전히 막혀 있으면 카운터가 누적된 것이다.
        let gate = store.gate.lock().await;
        assert_eq!(
            gate.failures, 0,
            "a successful fetch must reset the counter"
        );
        assert!(
            gate.last_failure.is_none(),
            "and clear the failure timestamp"
        );
    }

    /// ⚠️ Rust 전용 대조군 — 콜드 로드가 예전에는 게이트 **밖**에 있었다. 정상(200) IdP 라도
    /// 동시 첫 검증 20건이 IdP 요청 20건을 냈다(실측 20/20). 이 단언이 그 자리를 겨눈다.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_cold_start_collapses_to_one_fetch() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .mount(&server)
            .await;
        let store = Arc::new(JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            30,
        ));
        let mut handles = Vec::new();
        for _ in 0..20 {
            let s = store.clone();
            handles.push(tokio::spawn(async move { s.get_key("k1").await.is_ok() }));
        }
        for h in handles {
            assert!(h.await.unwrap(), "every concurrent lookup must resolve k1");
        }
        assert_eq!(
            certs_hits(&server).await,
            1,
            "20 concurrent cold-start lookups must collapse to one fetch"
        );
    }
}
