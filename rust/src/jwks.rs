//! DoS-safe JWKS: kid 캐시(키셋 수명 300초), 그 안에서는 미해결 kid만 재조회, rate-limit + single-flight.
use crate::error::{KeycloakError, Result};
use jsonwebtoken::jwk::{Jwk, JwkSet};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::time::Instant; // ⚠️ std 가 아니라 tokio 시계다 — `start_paused` 테스트가 백오프 창을
// 결정적으로 넘길 수 있어야 한다(실시간 sleep 없이).
use tokio::sync::{Mutex, RwLock};

/// 성공한 조회가 받은 키셋의 수명(초, 아홉 언어 공통) — 그 조회가 끝난 때(`tokio::time::Instant`, 단조)부터 센다.
/// 그 나이에 이르면 캐시는 콜드와 **똑같다**: `get_key` 가 같은 게이트 잠금(single-flight) 아래 같은 실패 백오프로
/// 다시 받고, 30초 강제 재조회 창은 보지도 찍지도 않는다. 그 조회가 실패하면 조회가 실패한다 — 나이가 찬 키는
/// IdP 장애 중에도 다시 쓰지 않는다. 강제 재조회의 성공도 키셋을 바꾸고 나이를 다시 센다.
/// ⚠️ 교차언어 가드가 이 값을 뽑는다 — 식이 아니라 맨 십진 리터럴로 둔다.
const JWKS_MAX_AGE_SECONDS: u64 = 300;

/// ⚠️ **실패한 fetch 의 백오프 — `min_refetch` 와 다른 축이다.**
/// `min_refetch`(30초)는 *캐시가 찬 뒤* 미해결 kid 홍수를 막는다. 아래 둘은 **캐시가 비어 있고(또는 수명을
/// 다했고) fetch 가 계속 실패할 때**를 막는다. 그 자리에는 게이트가 없어서, 측정상 20회 조회가 IdP 요청
/// 20건을 그대로 냈다(2026-09-04 · 7개 언어 동일).
///
/// ⚠️ **여기에 `min_refetch`(30초)를 재사용하면 안 된다** — 일시적 503 한 번이 「30초간 어떤
/// 토큰도 검증 불가」가 된다. 그래서 짧게 시작해 지수적으로 늘리고 상한을 둔다.
const FAILURE_BACKOFF_BASE: Duration = Duration::from_millis(200);
const FAILURE_BACKOFF_CAP: Duration = Duration::from_secs(5);

/// JWKS 본문의 바이트 상한. ⚠️ **이 수는 우리가 고른 것이 아니다** — Nimbus 의
/// `RemoteJWKSet.DEFAULT_HTTP_SIZE_LIMIT` 이고 java·kotlin 이 그 상수를 직접 참조하며 go 는
/// 같은 값을 리터럴로 둔다(`go/jwt.go` 의 `jwksMaxBytes`). 아홉 언어가 함께 움직여야 하는 값이라
/// 여기만 바꾸지 말 것. 상한이 없으면 적대적·거대 JWKS 가 그대로 메모리에 올라온다.
const JWKS_MAX_BYTES: usize = 51200;

/// 토큰 엔드포인트(모든 grant — auth 레인과 admin 레인의 자기 토큰)·introspection 응답 본문의 바이트 상한. 레인이
/// 몇이든 이 상수 하나다(`auth.rs` 의 `CappedHttp` · `token_provider.rs`). 두 끝과 할당 상한은
/// `tests/token_response_cap.rs` 가 고정한다.
/// ⚠️ 51200(JWKS 상한)을 빌려 쓰지 말 것 — Keycloak 26.6 이 기본으로 받아들이는 가장 긴 Bearer 가 65,459 바이트다.
/// ⚠️ 교차언어 가드가 이 값을 뽑는다 — 식(`1 << 20`)이 아니라 맨 십진 리터럴로 둔다.
pub(crate) const TOKEN_RESPONSE_MAX_BYTES: usize = 1_048_576;

/// 응답 본문을 `cap` 바이트까지만 읽는다 — 넘으면 `Ok(None)`(JWKS · 토큰 · introspection 공용).
///
/// ⚠️ 쥐는 본문은 많아야 `cap` 바이트다 — 넘기는 청크는 복사하지 않고, 벡터는 읽은 만큼만 자라며(선할당 금지)
/// 용량도 `cap` 에서 멈춘다. 청크 크기는 hyper 가 정한다(읽기 버퍼 최대 8192 + 4096 × 100 = 417,792 바이트) —
/// 판정 순간 그 한 청크가 더 있을 수 있다. reqwest 가 디코딩하면 `chunk()` 가 푼 바이트를 준다.
/// 오류는 `bytes()` 와 같다(둘 다 reqwest 의 `decode`).
pub(crate) async fn read_capped(
    resp: &mut reqwest::Response,
    cap: usize,
) -> std::result::Result<Option<Vec<u8>>, reqwest::Error> {
    let mut body: Vec<u8> = Vec::new();
    while let Some(chunk) = resp.chunk().await? {
        let len = body.len().saturating_add(chunk.len());
        if len > cap {
            return Ok(None);
        }
        if len > body.capacity() {
            let target = len.max(body.capacity().saturating_mul(2)).min(cap);
            body.reserve_exact(target - body.len());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(Some(body))
}

/// 게이트 상태. **하나의 뮤텍스가 두 축을 함께 소유한다** — 강제 재조회의 30초 rate-limit 과
/// 실패 fetch 의 백오프. 잠금을 나누면 「검사 후 fetch」 사이에 다른 태스크가 끼어들 수 있다.
#[derive(Default)]
struct Gate {
    last_refetch: Option<Instant>, // 마지막 *강제* 재조회 결정 시각
    failures: u32,                 // 연속 fetch 실패 횟수(성공 시 0)
    last_failure: Option<Instant>, // 마지막 fetch 실패 시각
    backoff: Duration,             // 그 실패가 연 창 — jitter 는 실패를 기록할 때 한 번 뽑았다
}

impl Gate {
    /// 백오프 잔여 시간. 0 이면 fetch 를 허용한다.
    fn backoff_remaining(&self, now: Instant) -> Duration {
        let Some(last) = self.last_failure else {
            return Duration::ZERO;
        };
        self.backoff
            .saturating_sub(now.saturating_duration_since(last))
    }

    /// fetch 실패 하나를 기록하고 그 창을 **지금** 정한다 — jitter 는 여기서 한 번 뽑는다. 검사마다 뽑으면 창의 끝이
    /// 검사마다 움직여, 같은 순간에 한 검사는 거부하고 다음 검사는 IdP 로 나갔다
    /// (`backoff_jitter_is_drawn_once_when_the_failure_is_recorded`).
    fn record_failure(&mut self, now: Instant, jitter: f64) {
        self.failures = self.failures.saturating_add(1);
        self.last_failure = Some(now);
        self.backoff = self.backoff_delay(jitter);
    }

    fn record_success(&mut self) {
        self.failures = 0;
        self.last_failure = None;
        self.backoff = Duration::ZERO;
    }

    /// 지수 백오프 + jitter([0.5, 1.0] 배수). jitter 는 여러 인스턴스가 같은 순간에 복구를
    /// 시도해 IdP 를 다시 무너뜨리는 것(thundering herd)을 흩는다.
    ///
    /// ⚠️ jitter 원천이 `rand` 가 아니라 벽시계 나노초인 것은 의도다 — 런타임 의존을 하나
    /// 늘리지 않으려는 것이고, 이 값은 암호용이 아니라 **분산용**이라 그 강도로 충분하다.
    fn backoff_delay(&self, jitter: f64) -> Duration {
        let shift = self.failures.max(1) - 1;
        let raw = FAILURE_BACKOFF_BASE
            .saturating_mul(1u32.checked_shl(shift.min(31)).unwrap_or(u32::MAX))
            .min(FAILURE_BACKOFF_CAP);
        raw.mul_f64(jitter)
    }
}

/// [0.5, 1.0) 배수 — 기본 jitter 원천(`JwksStore::jitter`).
fn clock_jitter() -> f64 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    0.5 + f64::from(nanos % 1_000_000) / 2_000_000.0
}

pub struct JwksStore {
    source: Arc<Source>,
    gate: Arc<Mutex<Gate>>, // single-flight + rate-limit + 실패 백오프 — 떼어 낸 fetch 가 소유 가드를 쥔다
    min_refetch: u64,
    jitter: fn() -> f64, // 실패 백오프의 jitter 원천 — 시험 이음매(기본 `clock_jitter`)
}

/// 떼어 낸 fetch 태스크가 들고 가는 것 — 호출자가 사라져도 이것만으로 끝까지 돌아 캐시를 채운다.
struct Source {
    jwks_uri: String,
    http: reqwest::Client,
    cache: RwLock<Option<Cached>>,
}

/// 캐시된 키셋과 그것을 받은 조회가 끝난 시각 — 그로부터 `JWKS_MAX_AGE_SECONDS` 동안만 쓴다.
struct Cached {
    set: Arc<JwkSet>,
    loaded_at: Instant,
}

impl JwksStore {
    pub fn new(jwks_uri: impl Into<String>, http: reqwest::Client, min_refetch_secs: u64) -> Self {
        Self {
            source: Arc::new(Source {
                jwks_uri: jwks_uri.into(),
                http,
                cache: RwLock::new(None),
            }),
            gate: Arc::new(Mutex::new(Gate::default())),
            min_refetch: min_refetch_secs,
            jitter: clock_jitter,
        }
    }
}

impl Source {
    async fn fetch(&self) -> Result<Arc<JwkSet>> {
        let resp = self
            .http
            .get(&self.jwks_uri)
            .send()
            .await
            .map_err(|e| KeycloakError::Transport(format!("JWKS fetch: {e}")))?;
        // ⚠️ **상태를 먼저 본다.** 안 보면 IdP 의 오류 응답이 JSON 이기만 하면 파싱되고, 빈
        // 키셋이 캐시된 뒤 rate-limit 게이트가 재조회를 막아 모든 검증이 「알 수 없는 kid」로
        // 죽는다. php(`getStatusCode() !== 200`)·ruby(`resp.success?`)·go 는 이미 본다.
        let status = resp.status();
        if !status.is_success() {
            return Err(KeycloakError::Transport(format!(
                "JWKS fetch failed: HTTP {}",
                status.as_u16()
            )));
        }
        // ⚠️ **본문을 통째로 읽기 전에 상한을 건다.** `resp.json()`/`resp.bytes()` 는 서버가
        // 보내는 만큼 다 받는다. 청크 단위로 받으며 상한+1 을 넘는 순간 끊는다 — `Content-Length`
        // 로만 판정하면 그 헤더가 없거나 거짓인 응답을 놓친다.
        let mut resp = resp;
        let body = read_capped(&mut resp, JWKS_MAX_BYTES)
            .await
            .map_err(|e| KeycloakError::Transport(format!("JWKS read: {e}")))?
            .ok_or_else(|| {
                KeycloakError::Transport(format!("JWKS response exceeds {JWKS_MAX_BYTES} bytes"))
            })?;
        // ⚠️ serde_json 의 `Display` 는 틀린 타입의 문자열 값을 인용한다(`invalid type: string "…"`) —
        // 응답 본문을 오류로 옮기지 않도록 분류와 위치만 남긴다(Grok 레그 실측 2026-09-26).
        let set: JwkSet = serde_json::from_slice(&body).map_err(|e| {
            KeycloakError::Transport(format!(
                "JWKS parse: {:?} error at line {} column {}",
                e.classify(),
                e.line(),
                e.column()
            ))
        })?;
        // ⚠️ **빈 집합은 정상 답이 아니고, 설치하면 검증기가 눈이 먼다**(go/jwt.go 와 동형 —
        // 그쪽 #380 픽스의 나머지 절반이다). 200 + `{"keys":[]}` 를 주는 것은 키를 전부 회수한
        // IdP 가 아니라 프록시·WAF·반쯤 뜬 realm 이고, 좋은 캐시를 그것으로 덮으면 방금 검증되던
        // 토큰이 거부되며 refetch 게이트가 복구까지 막는다. 쓰기 **전에** 거부한다.
        if set.keys.is_empty() {
            return Err(KeycloakError::Transport(
                "JWKS response contains no keys".to_string(),
            ));
        }
        let arc = Arc::new(set);
        *self.cache.write().await = Some(Cached {
            set: arc.clone(),
            loaded_at: Instant::now(),
        });
        Ok(arc)
    }
}

impl JwksStore {
    fn lookup(set: Option<&Arc<JwkSet>>, kid: &str) -> Option<Jwk> {
        set.and_then(|s| s.find(kid)).cloned()
    }

    /// 아직 쓸 수 있는 캐시의 키셋 — 비었거나 `JWKS_MAX_AGE_SECONDS` 를 다했으면 `None`(콜드와 똑같다).
    fn fresh_set(cache: &Option<Cached>, now: Instant) -> Option<&Arc<JwkSet>> {
        cache
            .as_ref()
            .filter(|c| {
                now.saturating_duration_since(c.loaded_at)
                    < Duration::from_secs(JWKS_MAX_AGE_SECONDS)
            })
            .map(|c| &c.set)
    }

    /// kid로 JWK 조회. 신선한 캐시 히트=네트워크 0 · 수명을 다한 캐시는 콜드처럼 다시 받는다 · 미해결 kid만
    /// rate-limited 재조회.
    pub async fn get_key(&self, kid: &str) -> Result<Jwk> {
        let hit = Self::lookup(
            Self::fresh_set(&*self.source.cache.read().await, Instant::now()),
            kid,
        );
        if let Some(jwk) = hit {
            return Ok(jwk);
        }
        // ⚠️ gate 획득이 **콜드 로드와 강제 재조회 양쪽의** single-flight 지점이다. 예전에는
        // 콜드 로드가 이 잠금 **밖**에 있어서, 20개 태스크가 동시에 첫 검증을 하면 IdP 로
        // 20건이 나갔다 — **정상(200) 엔드포인트에서도** 그랬다(실측 20/20).
        // 소유 가드(`lock_owned`)인 것은 아래에서 그 가드를 fetch 태스크로 넘기기 때문이다.
        let mut gate = self.gate.clone().lock_owned().await;
        let cold = {
            let c = self.source.cache.read().await;
            let fresh = Self::fresh_set(&c, Instant::now());
            // gate 획득 후 재확인(다른 태스크가 방금 채웠을 수 있음)
            if let Some(jwk) = Self::lookup(fresh, kid) {
                return Ok(jwk);
            }
            // ⚠️ 수명을 다한 키셋은 콜드와 **똑같다** — 이 잠금 · 아래 백오프를 같이 타고 30초 창은 건너뛴다.
            fresh.is_none()
        };

        if !cold {
            // 미해결 kid → rate-limit 재조회. 콜드 로드는 이 예산을 쓰지 않는다.
            if let Some(last) = gate.last_refetch
                && Instant::now().saturating_duration_since(last)
                    < Duration::from_secs(self.min_refetch)
            {
                // ⚠️ kid 값은 인용하지 않는다 — 검증 대상 토큰(적대적 IdP 의 id_token 포함)이 준 입력이다
                // (실측 2026-09-26, `tests/hostile_token_response.rs` 의 `a3`). jose·Nimbus 도 인용하지 않는다.
                return Err(KeycloakError::TokenValidation(
                    "unknown kid (refetch rate-limited)".into(),
                ));
            }
            // 재조회 결정 시점에 stamp — fetch 실패해도 rate-limit이 걸리도록(Go/Python 동형).
            gate.last_refetch = Some(Instant::now());
        }

        // ⚠️ 백오프 검사는 fetch **직전**이자 30초 게이트 **이후**다. 콜드(또는 수명을 다한) 캐시에서는 위 분기가
        // 통째로 건너뛰어지므로, 이 줄이 없으면 매 조회가 IdP 로 나간다(그게 원래 결함이다).
        let remaining = gate.backoff_remaining(Instant::now());
        if !remaining.is_zero() {
            return Err(KeycloakError::Transport(format!(
                "JWKS fetch backing off after {} consecutive failures (retry in {:.2}s)",
                gate.failures,
                remaining.as_secs_f64()
            )));
        }

        // ⚠️ **fetch 를 호출자에게서 떼어 낸다 — 게이트 가드째.** 호출자의 future 안에서 돌리면 창을 찍은 뒤 호출자가
        // 취소(드롭)될 때 fetch 도 죽어 창만 쓰고 키는 못 받았다 — 같은 fetch 를 기다리던 호출자까지 `rate-limited`
        // (`forced_refetch_cancelled_*`). 태스크는 HTTP 타임아웃으로만 끝나고 결과(캐시·백오프)를 남긴 뒤 가드를 놓는다.
        // 핸들을 버려도 태스크는 취소되지 않는다. ⚠️ 취소 시 stamp 를 되돌리지 말 것 — 취소된 위조 kid 검증마다 IdP
        // 요청이 하나씩 나간다. ⚠️ 저수준 주입에 타임아웃 없는 클라이언트를 주면 멈춘 IdP 가 게이트를 그만큼 쥔다.
        let source = self.source.clone();
        let jitter = self.jitter;
        let fetch = tokio::spawn(async move {
            let fetched = source.fetch().await;
            match &fetched {
                Ok(_) => gate.record_success(),
                Err(_) => gate.record_failure(Instant::now(), jitter()),
            }
            fetched
        });
        let set = fetch.await.map_err(|_| {
            KeycloakError::Transport("JWKS fetch task did not complete".to_string())
        })??;
        Self::lookup(Some(&set), kid)
            .ok_or_else(|| KeycloakError::TokenValidation("unknown kid".into()))
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

    /// 모르는 kid 의 오류가 그 kid 를 인용하지 않는다 — 두 갈래(재조회 뒤 · rate-limit) 다. kid 는 검증
    /// 대상 토큰이 준 입력이다. rate-limit 갈래는 `tests/hostile_token_response.rs` 가 닿지 못해 여기서 본다.
    #[tokio::test]
    async fn unknown_kid_errors_do_not_quote_the_kid() {
        const KID: &str = "KID-FROM-TOKEN-CANARY-7M3Q";
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .mount(&server)
            .await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            60,
        );
        store.get_key("k1").await.unwrap();
        let after_refetch = store.get_key(KID).await.unwrap_err().to_string();
        let rate_limited = store.get_key(KID).await.unwrap_err().to_string();
        assert!(rate_limited.contains("rate-limited"), "{rate_limited}");
        for msg in [&after_refetch, &rate_limited] {
            assert!(msg.contains("unknown kid"), "{msg}");
            assert!(!msg.contains(&KID[..10]), "kid 를 인용했다: {msg}");
        }
    }

    /// 파싱 실패가 응답 본문을 인용하지 않는다 — serde_json 은 틀린 타입의 **문자열 값**을 오류 문구에
    /// 인용한다(`invalid type: string "…"`). 형식 오류(비 JSON)도 함께 본다.
    #[tokio::test]
    async fn jwks_parse_error_does_not_quote_the_body() {
        for body in [
            r#"{"keys":"JWKS-BODY-CANARY-4T8W"}"#,
            r#"{"keys":[{"kty":"RSA","kid":7,"n":"JWKS-BODY-CANARY-4T8W"}], "x": 1}"#,
            "JWKS-BODY-CANARY-4T8W",
        ] {
            let server = MockServer::start().await;
            Mock::given(method("GET"))
                .and(path("/certs"))
                .respond_with(ResponseTemplate::new(200).set_body_string(body))
                .mount(&server)
                .await;
            let store = JwksStore::new(
                format!("{}/certs", server.uri()),
                reqwest::Client::new(),
                60,
            );
            let err = store.get_key("k1").await.unwrap_err();
            let msg = format!("{err} {err:?}");
            assert!(matches!(err, KeycloakError::Transport(_)), "{body}: {msg}");
            assert!(msg.contains("JWKS parse"), "{body}: {msg}");
            assert!(!msg.contains("JWKS-BODY-"), "본문을 인용했다: {msg}");
        }
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

    fn backing_off(r: &Result<Jwk>) -> bool {
        matches!(r, Err(KeycloakError::Transport(m)) if m.contains("backing off"))
    }

    /// 실패 2 로부터 「둘째 창은 아직 안 끝났다」를 보는 시점. 두 배가 된 창은 0.4초 × jitter 라 가장 짧아도
    /// 0.2초(jitter 최소 0.5)이고, 두 배를 잃은 창은 첫 창과 같아 0.2초 × jitter 라 가장 길어도 0.1999999초
    /// (jitter 최대 0.5 + 999_999/2_000_000)다 — 그 사이에 둬야 **모든** jitter 에서 둘을 가른다.
    /// ⚠️ **199ms 로 되돌리지 말 것.** 그 탐침은 jitter 가 0.995 를 넘는 판(약 1%)에서 두 배를 잃은 창도
    /// 덮는다 — 실측: `backoff_delay` 의 두 배를 없앤 변이가 아래 시험을 1500 판 중 17 판 통과했다.
    /// 그 성질은 `doubling_probe_splits_undoubled_from_doubled_window_at_every_jitter` 가 지킨다.
    const SECOND_WINDOW_PROBE: Duration = Duration::from_nanos(199_999_999);

    /// ⚠️ **창의 크기를 못 박는다 — 이 시험을 지우지 말 것.** 백오프를 쓰는 다른 시험은 아래 회귀 시험 말고는
    /// 전부 멈춘 시계(경과 0)에서 돌아, 창이 0 보다 크기만 하면 통과한다. W3c(`tests/hostile_path_matrix.rs`)는
    /// 실시간 시계였을 때 교환 행의 호출 간격으로 「창이 µs 로 줄었다」를 잡았다 — 실측: `FAILURE_BACKOFF_BASE`
    /// 200ms→200µs 를 main 의 W3c 교환 두 행이 `certs 5` 로 잡았고, 얼린 뒤에는 이 시험과 아래 회귀 시험만 잡는다.
    /// 0.2초 × jitter[0.5, 1.0) 이라 첫 창은 [0.1, 0.2)초, 둘째 창은 그 두 배다. 「두 배가 아니다」 단언이
    /// jitter 와 무관하게 결정적인 것은 탐침이 `SECOND_WINDOW_PROBE` 라서다.
    #[tokio::test(start_paused = true)]
    async fn backoff_window_holds_its_minimum_and_doubles() {
        let server = failing_server().await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            30,
        );

        assert!(store.get_key("k1").await.is_err()); // 실패 1
        tokio::time::advance(Duration::from_millis(99)).await;
        assert!(
            backing_off(&store.get_key("k1").await),
            "첫 창이 0.1초보다 짧다"
        );
        assert_eq!(certs_hits(&server).await, 1);

        tokio::time::advance(Duration::from_millis(101)).await; // 실패 1 로부터 0.2초 — 첫 창의 상한
        assert!(!backing_off(&store.get_key("k1").await)); // 실패 2
        assert_eq!(certs_hits(&server).await, 2);

        tokio::time::advance(SECOND_WINDOW_PROBE).await;
        assert!(
            backing_off(&store.get_key("k1").await),
            "둘째 창이 첫 창의 두 배(0.2초 이상)가 아니다"
        );
        // 실패 2 로부터 0.4초 — 둘째 창의 상한
        tokio::time::advance(Duration::from_millis(400) - SECOND_WINDOW_PROBE).await;
        assert!(!backing_off(&store.get_key("k1").await));
        assert_eq!(certs_hits(&server).await, 3);
    }

    /// 회귀 — 위 시험의 「두 배가 아니다」 단언이 두 배 상실을 **jitter 와 무관하게** 잡는가. 두 배를 잃은
    /// 둘째 창은 첫 창과 같으므로 실패 1 회의 게이트로, 두 배가 된 창은 실패 2 회의 게이트로 본다. jitter 는
    /// 실패를 기록할 때 `clock_jitter` 가 벽시계 나노초의 1ms 주기에서 한 번 뽑으니(0.5 + k/2_000_000, k < 10⁶),
    /// 그 원천이 낼 수 있는 값 백만 개를 전부 넣어 본다 — 통과는 jitter 값에 기대지 않고(모든 값에서 성립해야
    /// 한다), 탐침이 헐거우면 어느 값에서든 깨진다.
    #[test]
    fn doubling_probe_splits_undoubled_from_doubled_window_at_every_jitter() {
        let t0 = Instant::now();
        let at = t0 + SECOND_WINDOW_PROBE;
        for k in 0..1_000_000u32 {
            let jitter = 0.5 + f64::from(k) / 2_000_000.0;
            let mut undoubled = Gate::default();
            undoubled.record_failure(t0, jitter);
            let mut doubled = Gate::default();
            doubled.record_failure(t0, jitter);
            doubled.record_failure(t0, jitter);
            let left = undoubled.backoff_remaining(at);
            assert!(
                left.is_zero(),
                "두 배를 잃은 창이 탐침 {SECOND_WINDOW_PROBE:?} 을 {left:?} 넘는다 — jitter {jitter} 에서는 두 배 상실이 산다"
            );
            assert!(
                !doubled.backoff_remaining(at).is_zero(),
                "두 배가 된 창이 탐침 {SECOND_WINDOW_PROBE:?} 전에 끝났다 — jitter {jitter} 에서 둘째 창이 0.2초보다 짧다"
            );
        }
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

    // ⚠️ HTTP 상태를 안 보면 **500 본문이 JSON 이기만 하면 파싱된다.** IdP 의 오류 페이지가
    // `{"keys":[]}` 든 무엇이든 JSON 이면 빈 키셋이 캐시되고, 그 뒤 모든 검증이 「알 수 없는
    // kid」로 실패한다 — 그리고 rate-limit 게이트가 재조회를 막는다. php(`getStatusCode() !== 200`)·
    // ruby(`resp.success?`)·go 는 이미 상태를 본다. rust 만 안 봤다.
    #[tokio::test]
    async fn non_2xx_is_transport_error_not_parsed() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(500).set_body_json(serde_json::json!({"keys":[]})))
            .mount(&server)
            .await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            60,
        );
        let err = store
            .get_key("k1")
            .await
            .expect_err("500 must not be parsed");
        assert!(
            matches!(err, KeycloakError::Transport(ref m) if m.contains("500")),
            "expected Transport carrying the status, got {err:?}"
        );
    }

    // ⚠️ 본문 크기 상한이 없으면 적대적·거대 JWKS 가 그대로 메모리에 올라온다. 상한값은 go 와
    // 같은 51200 이고, 그것은 Nimbus 의 `RemoteJWKSet.DEFAULT_HTTP_SIZE_LIMIT` 다(java·kotlin 이
    // 그 상수를 직접 참조한다) — 아홉 언어가 같은 수를 쓰게 하려고 여기서도 그 값을 쓴다.
    #[tokio::test]
    async fn oversized_body_is_rejected() {
        let server = MockServer::start().await;
        // 유효한 JSON 이되 상한을 넘는 본문 — 「파싱 실패」가 아니라 「크기 초과」로 죽어야 한다.
        let big = "x".repeat(JWKS_MAX_BYTES + 1024);
        let body = serde_json::json!({ "keys": [], "padding": big });
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(body))
            .mount(&server)
            .await;
        let store = JwksStore::new(
            format!("{}/certs", server.uri()),
            reqwest::Client::new(),
            60,
        );
        let err = store
            .get_key("k1")
            .await
            .expect_err("oversized JWKS must not be parsed");
        assert!(
            matches!(err, KeycloakError::Transport(ref m) if m.contains("exceeds")),
            "expected a size-limit Transport error, got {err:?}"
        );
    }

    // 대조군 — 상한 바로 아래는 통과해야 한다. 없으면 위 테스트가 「늘 실패한다」와 구분되지 않는다.
    #[tokio::test]
    async fn body_under_the_cap_still_parses() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
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
    }

    // ⚠️ **빈 키셋 200 은 좋은 캐시를 덮어서는 안 된다.** go 의 #380 픽스는 절반이 상태코드,
    // 나머지 절반이 `len(ks.Keys) == 0` 거부였는데 자매 SDK 로는 앞 절반만 복제됐다. 프록시·WAF·
    // 반쯤 뜬 realm 이 200 + `{"keys":[]}` 를 주면 검증기가 눈이 멀고, 30 초 refetch 게이트가
    // 복구까지 막는다(실측 재현). 「키가 0 개인 정상 IdP」는 이 부류가 아니다 — 키를 전부 회수한
    // 발급자는 교체 집합을 주거나 HTTP 로 실패한다.
    #[tokio::test]
    async fn empty_keyset_200_does_not_clobber_a_good_cache() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        // min_refetch=0 — 게이트가 아니라 **빈 집합 거부**가 캐시를 지키는지 본다.
        let store = JwksStore::new(format!("{}/certs", server.uri()), reqwest::Client::new(), 0);
        assert_eq!(
            store.get_key("k1").await.unwrap().common.key_id.as_deref(),
            Some("k1"),
            "사전조건: 좋은 캐시가 올라가야 한다"
        );

        // 이제부터 빈 200 만 준다.
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"keys":[]})))
            .mount(&server)
            .await;

        // 미해결 kid 는 재조회를 유발한다 — 그 재조회가 빈 200 을 받는다.
        let miss = store.get_key("k2").await;
        assert!(miss.is_err(), "없는 kid 는 실패해야 한다");

        // 핵심: 방금 검증되던 k1 이 살아 있어야 한다.
        assert_eq!(
            store.get_key("k1").await.unwrap().common.key_id.as_deref(),
            Some("k1"),
            "빈 200 이 좋은 캐시를 덮었다 — go 의 len(keys)==0 절반이 빠졌다"
        );
    }

    // 콜드 스타트에서 빈 200 은 **SDK 오류 타입**으로 실패해야 한다(하위 타입 누출 금지, §4).
    #[tokio::test]
    async fn empty_keyset_200_on_cold_start_is_transport_error() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"keys":[]})))
            .mount(&server)
            .await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), reqwest::Client::new(), 0);
        let err = store
            .get_key("k1")
            .await
            .expect_err("빈 키셋은 성공이 아니다");
        assert!(
            matches!(err, KeycloakError::Transport(ref m) if m.contains("no keys")),
            "expected Transport('…no keys…'), got {err:?}"
        );
    }

    // ⚠️ 반대 방향 — 「캐시를 영원히 얼린다」는 가짜 픽스를 죽인다. 비어 있지 않은 새 집합은
    // 여전히 교체되어야 한다.
    #[tokio::test]
    async fn non_empty_keyset_still_replaces_the_cache() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), reqwest::Client::new(), 0);
        assert!(store.get_key("k1").await.is_ok(), "사전조건");

        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k9")))
            .mount(&server)
            .await;
        assert_eq!(
            store.get_key("k9").await.unwrap().common.key_id.as_deref(),
            Some("k9"),
            "비어 있지 않은 회전 집합은 반영되어야 한다"
        );
    }

    // ⚠️ **적대적·고장난 IdP 가 빈 200 을 영원히 줘도 요청이 무한해지면 안 된다.** 새 거부는
    // `fetch()` 안에서 Err 로 나가고, `get_key` 의 Err 분기가 실패 카운터를 올리고 백오프를
    // 찍는다 — 즉 기존 실패 경로를 그대로 탄다. 그 사실을 읽기가 아니라 **세어서** 단언한다
    // (거부를 실패로 기록하지 않는 구현은 여기서 20 번 나간다).
    //
    // ⚠️ **`start_paused` 를 떼지 말 것 — 실시간 시계에서는 이 단언이 러너 속도를 잰다.** 첫 실패의 창은
    // 0.2초 × jitter[0.5, 1.0) 라 0.1초까지 좁고, 첫 조회와 나머지 19 회 사이에 그보다 긴 정지가 한 번만
    // 끼어도 다음 조회가 IdP 로 나가 `left: 2` 로 깨진다. 멈춘 시계에서는 첫 실패 뒤의 조회가 I/O 없이
    // 끝나 자동 전진이 일어날 park 가 없으므로 그 사이 경과가 0 이다(위
    // `failing_idp_bounds_cold_retries_to_one_request` 와 같은 틀). 픽스처의 `reqwest::Client::new()` 에는
    // 자동 전진이 터뜨릴 타임아웃이 없다.
    #[tokio::test(start_paused = true)]
    async fn empty_keyset_flood_is_bounded_like_any_other_failure() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"keys":[]})))
            .mount(&server)
            .await;
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
            "빈 200 을 주는 IdP 에 20 회 조회가 요청 1 건으로 접혀야 한다 — 거부가 백오프를 찍지 않으면 20 건이 나간다"
        );
    }

    // ── 강제 재조회 창 + 호출자 취소 (jwks-forced-refetch-window-burned) ───────────────────────
    //
    // 창은 재조회를 **결정할 때** 찍힌다(위 `fetch_failure_still_stamps_gate_rate_limiting_next_lookup`). 그 fetch 가
    // 호출자의 future 안에서 돌면, 호출자가 취소(드롭)될 때 fetch 도 함께 죽어 **창만 쓰고 키는 못 받는다** — 키가
    // 회전한 IdP 의 진짜 토큰이 창이 끝날 때까지 거부된다(실측 2026-10-05: 시간 초과 · abort 로 #1 을 비행 중에
    // 끊으면 #2 가 `unknown kid (refetch rate-limited)`, IdP 는 소켓이 먼저 닫힌 것을 봤다).
    //
    // ⚠️ 창을 되돌려(취소 시 stamp 철회) 고치지 말 것 — 그러면 취소된 위조 kid 검증마다 IdP 요청이 하나씩 나간다
    // (python 실측 10 대 1). 아래 503 시험이 그 「고침」을 잡는다.
    //
    // ⚠️ 이 시험들의 클라이언트에는 **유휴 연결 풀이 없다** — 풀 정리 타이머가 없어야 멈춘 시계가 I/O 를 기다리는 동안
    // 다음 타이머로 자동 전진하지 않는다(그러면 30초 창이 몰래 끝나 「창 안」이 거짓이 된다). 시험마다 시계가
    // 움직이지 않았음을 마지막에 단언한다.

    fn timerless_http() -> reqwest::Client {
        reqwest::Client::builder()
            .pool_max_idle_per_host(0)
            .build()
            .expect("reqwest client")
    }

    /// 첫 조회(콜드 로드)에 k1 을 주고, 그 뒤로는 `rotated` 를 준다(키 회전 · 장애).
    async fn rotating_idp(rotated: ResponseTemplate) -> MockServer {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .up_to_n_times(1)
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(rotated)
            .mount(&server)
            .await;
        server
    }

    /// 강제 재조회가 IdP 에 닿을 때까지 기다린다 — wiremock 은 자기 스레드의 실시간으로 돌고, 여기는 `yield` 만 하므로
    /// 멈춘 시계를 건드리지 않는다.
    async fn until_certs_hits(server: &MockServer, n: usize) {
        while certs_hits(server).await < n {
            tokio::task::yield_now().await;
        }
    }

    /// 취소 지점 하나 — 첫 poll 에서 게이트가 찍힌 뒤, fetch 요청이 IdP 에 닿기 **전**에 버린다.
    #[tokio::test(start_paused = true)]
    async fn forced_refetch_cancelled_after_its_first_poll_still_fills_the_cache() {
        let server = rotating_idp(ResponseTemplate::new(200).set_body_json(jwks_json("k2"))).await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), timerless_http(), 30);
        store.get_key("k1").await.unwrap(); // 콜드 로드 — 창을 쓰지 않는다
        let t0 = Instant::now();
        {
            let first = store.get_key("k2");
            tokio::pin!(first);
            // 잠금이 모두 비어 있어 이 한 번의 poll 안에서 게이트가 찍힌다. 그리고 버린다 = 취소.
            let polled = std::future::poll_fn(|cx| {
                std::task::Poll::Ready(std::future::Future::poll(first.as_mut(), cx))
            })
            .await;
            assert!(
                polled.is_pending(),
                "the forced fetch cannot finish within one poll"
            );
        }
        assert_eq!(
            certs_hits(&server).await,
            1,
            "#1 was cancelled before its request reached the IdP"
        );

        let jwk = store.get_key("k2").await.expect(
            "#2 inside the window: the window's one fetch must still fill the cache with k2",
        );
        assert_eq!(jwk.common.key_id.as_deref(), Some("k2"));
        assert_eq!(
            certs_hits(&server).await,
            2,
            "exactly one /certs request for the window"
        );
        assert_eq!(
            Instant::now(),
            t0,
            "the paused clock must not move — #2 is inside the window"
        );
    }

    /// 취소 지점 둘 — 요청이 IdP 에 닿은 **뒤**(비행 중) 버린다. 같은 fetch 를 게이트에서 기다리던 다른 호출자도
    /// 그 취소로 실패해서는 안 된다.
    #[tokio::test(start_paused = true)]
    async fn forced_refetch_cancelled_mid_flight_still_fills_the_cache_for_every_waiter() {
        let server = rotating_idp(
            ResponseTemplate::new(200)
                .set_body_json(jwks_json("k2"))
                .set_delay(Duration::from_millis(300)), // 실시간 — 그동안 #1 을 끊는다
        )
        .await;
        let store = Arc::new(JwksStore::new(
            format!("{}/certs", server.uri()),
            timerless_http(),
            30,
        ));
        store.get_key("k1").await.unwrap();
        let t0 = Instant::now();

        let s = store.clone();
        let first = tokio::spawn(async move { s.get_key("k2").await });
        until_certs_hits(&server, 2).await;
        let s = store.clone();
        let waiter = tokio::spawn(async move { s.get_key("k2").await });
        tokio::task::yield_now().await; // waiter 가 게이트에 줄을 선다
        first.abort();
        assert!(
            first.await.expect_err("#1 must be cut").is_cancelled(),
            "#1 was cancelled mid-flight"
        );

        let waited = waiter.await.expect("waiter task").expect(
            "a caller waiting on the same fetch must not be failed by another caller's cancellation",
        );
        assert_eq!(waited.common.key_id.as_deref(), Some("k2"));
        let jwk = store
            .get_key("k2")
            .await
            .expect("#2 inside the window must be accepted");
        assert_eq!(jwk.common.key_id.as_deref(), Some("k2"));
        assert_eq!(
            certs_hits(&server).await,
            2,
            "exactly one /certs request for the window"
        );
        assert_eq!(
            Instant::now(),
            t0,
            "the paused clock must not move — #2 is inside the window"
        );
    }

    /// 의도된 실패 의미는 그대로다 — **실패한** 강제 fetch(503)는 호출자가 취소됐어도 창을 쓴다. 창 안의 #2 는
    /// IdP 에 가지 않고 거부된다(취소 시 stamp 를 되돌리는 「고침」이면 여기서 #2 가 다시 나가 503 을 받는다).
    #[tokio::test(start_paused = true)]
    async fn failed_forced_refetch_still_spends_the_window_when_its_caller_was_cancelled() {
        let server =
            rotating_idp(ResponseTemplate::new(503).set_delay(Duration::from_millis(300))).await;
        let store = Arc::new(JwksStore::new(
            format!("{}/certs", server.uri()),
            timerless_http(),
            30,
        ));
        store.get_key("k1").await.unwrap();
        let t0 = Instant::now();

        let s = store.clone();
        let first = tokio::spawn(async move { s.get_key("k2").await });
        until_certs_hits(&server, 2).await;
        first.abort();
        assert!(first.await.expect_err("#1 must be cut").is_cancelled());

        match store.get_key("k2").await {
            Err(KeycloakError::TokenValidation(m)) => {
                assert_eq!(m, "unknown kid (refetch rate-limited)")
            }
            other => panic!("a failed forced fetch must still spend the window, got {other:?}"),
        }
        assert_eq!(
            certs_hits(&server).await,
            2,
            "the refused #2 must not reach the IdP"
        );
        assert_eq!(
            Instant::now(),
            t0,
            "the paused clock must not move — #2 is inside the window"
        );
    }

    // ── 떼어 낸 강제 재조회는 그것을 띄운 런타임과 함께 끝난다 — `AuthClient::validate` rustdoc 의 문장 ──────────
    //
    // 그 문장의 앞 절반(호출이 취소돼도 끝까지 간다)은 위 `forced_refetch_cancelled_*` 가 본다. 뒤 절반(런타임이 먼저
    // 내려가면 함께 끝나 창 안의 새 키가 `unknown kid (refetch rate-limited)` 로 거부된다)은 런타임이 둘이어야 보여
    // `#[test]` 가 런타임을 손수 만든다 — 그 문장이 경고하는 동기 래퍼(호출마다 런타임을 만들고 끊는다)의 모양 그대로다.
    // ⚠️ 멈춘 시계를 쓰지 않는다 — 런타임마다 시계가 따로다. 창은 실시간 30초이고 시험은 그 안에 끝난다.

    /// 강제 재조회 응답이 `delay` 늦는 IdP 에 호출마다 새 런타임으로 콜드 로드 → k2 조회를 하고, IdP 가 그 요청을 받는
    /// 순간 호출을 끊는다(future 를 버린다). `outlive` 면 그 런타임이 떼어 낸 fetch 가 게이트를 놓을 때까지(= 끝날
    /// 때까지) 산다. → (끊기 전에 fetch 가 끝났는가, 또 새 런타임의 k2 조회, IdP 가 받은 `/certs` 요청 수).
    fn cut_forced_refetch_then_retry(delay: Duration, outlive: bool) -> (bool, Result<Jwk>, usize) {
        let runtime = || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("runtime")
        };
        let host = runtime();
        let server = host.block_on(rotating_idp(
            ResponseTemplate::new(200)
                .set_body_json(jwks_json("k2"))
                .set_delay(delay),
        ));
        let store = JwksStore::new(format!("{}/certs", server.uri()), timerless_http(), 30);
        runtime().block_on(store.get_key("k1")).expect("cold load");
        let landed_first = runtime().block_on(async {
            let landed_first = tokio::select! {
                r = store.get_key("k2") => {
                    r.expect("a forced fetch that landed must return k2");
                    true
                }
                () = until_certs_hits(&server, 2) => false,
            };
            if outlive {
                // 떼어 낸 fetch 는 게이트 가드를 쥐고 끝까지 간다 — 그것을 놓을 때까지 이 런타임이 산다.
                drop(store.gate.lock().await);
            }
            landed_first
        }); // ← 그 호출의 런타임이 여기서 내려간다
        let retried = runtime().block_on(store.get_key("k2"));
        (landed_first, retried, host.block_on(certs_hits(&server)))
    }

    /// 런타임이 먼저 내려가면 떼어 낸 fetch 도 함께 끝난다 — 창은 결정할 때 찍혔으므로 창 안의 다음 조회는 IdP 에 가지
    /// 않고 거부된다. 응답은 끊기 한참 뒤에 오지만 기다리지 않는다(시험 시간에 안 든다).
    #[test]
    fn forced_refetch_ends_with_the_runtime_that_spawned_it() {
        let (landed_first, retried, hits) =
            cut_forced_refetch_then_retry(Duration::from_secs(10), false);
        assert!(
            !landed_first,
            "the forced fetch landed before the cut — the scenario did not happen"
        );
        match retried {
            Err(KeycloakError::TokenValidation(m)) => {
                assert_eq!(m, "unknown kid (refetch rate-limited)")
            }
            other => panic!(
                "a fetch whose runtime shut down must leave the window spent and k2 unknown, got {other:?}"
            ),
        }
        assert_eq!(hits, 2, "the refused retry must not reach the IdP");
    }

    /// 대조 — 같은 IdP · 같은 끊기에서 런타임만 fetch 가 끝날 때까지 산다. k2 가 캐시에 남아 다음 런타임의 조회가 IdP 에
    /// 가지 않고 받는다 — 위 거부가 런타임의 수명 탓이지 런타임을 건넌 탓이 아님을 가른다.
    #[test]
    fn forced_refetch_lands_for_the_next_runtime_when_its_runtime_outlives_it() {
        let (_, retried, hits) = cut_forced_refetch_then_retry(Duration::from_millis(300), true);
        let jwk = retried.expect("the fetch landed while its runtime lived — k2 must be cached");
        assert_eq!(jwk.common.key_id.as_deref(), Some("k2"));
        assert_eq!(hits, 2, "exactly one /certs request for the window");
    }

    // ── 키셋의 수명 300 초 (jwks-cache-lifetime-divergent, 판정 2026-10-29) ──────────────────────────────────────
    //
    // 성공한 조회가 받은 키셋은 그 조회가 끝난 때부터 300 초만 쓴다. 그 나이에 이르면 캐시는 콜드와 똑같다: 같은 게이트
    // 잠금(single-flight) 아래 같은 실패 백오프로 다시 받고, 실패하면 조회가 실패한다 — 낡은 키로 물러서지 않는다.
    // 시각은 리터럴로 적는다 — 상수에서 끌어 쓰면 상수가 바뀔 때 이 시험도 함께 움직인다. 클라이언트는 `timerless_http`
    // 다 — 풀 정리 타이머가 있으면 멈춘 시계가 I/O 를 기다리는 동안 자동 전진해 적재 시각이 밀린다.

    fn jwks_of(kids: &[&str]) -> serde_json::Value {
        let keys: Vec<_> = kids
            .iter()
            .map(|kid| {
                serde_json::json!({ "kty":"RSA","kid":kid,"use":"sig","alg":"RS256","n":"sXchg","e":"AQAB" })
            })
            .collect();
        serde_json::json!({ "keys": keys })
    }

    fn serving(kids: &[&str]) -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(jwks_of(kids))
    }

    /// 시험이 응답을 바꿔 낼 수 있는 /certs — 키셋 교체 · 장애 · 회복.
    #[derive(Clone)]
    struct Switchable(Arc<std::sync::Mutex<ResponseTemplate>>);

    impl wiremock::Respond for Switchable {
        fn respond(&self, _: &wiremock::Request) -> ResponseTemplate {
            self.0.lock().expect("responder").clone()
        }
    }

    impl Switchable {
        fn set(&self, next: ResponseTemplate) {
            *self.0.lock().expect("responder") = next;
        }
    }

    async fn switchable_idp(first: ResponseTemplate) -> (MockServer, Switchable) {
        let server = MockServer::start().await;
        let idp = Switchable(Arc::new(std::sync::Mutex::new(first)));
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(idp.clone())
            .mount(&server)
            .await;
        (server, idp)
    }

    /// 적재 한 번으로 캐시를 채운다 — 멈춘 시계는 그사이 움직이지 않으므로 돌려준 시각이 그 적재가 끝난 시각이다.
    async fn warm(store: &JwksStore, server: &MockServer) -> Instant {
        let t0 = Instant::now();
        store.get_key("k1").await.expect("warm load");
        assert_eq!(Instant::now(), t0, "the load moved the paused clock");
        assert_eq!(certs_hits(server).await, 1);
        t0
    }

    /// T1 정상 만료 — 299 초에는 조회 없이 답하고, 301 초에는 정확히 한 번 조회하고 답한다(방금 받은 키셋의 나이는 0).
    #[tokio::test(start_paused = true)]
    async fn key_set_is_used_for_300_seconds_then_fetched_again() {
        let (server, _idp) = switchable_idp(serving(&["k1"])).await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), timerless_http(), 30);
        let t0 = warm(&store, &server).await;
        tokio::time::advance(Duration::from_secs(299)).await;
        store.get_key("k1").await.expect("299 s");
        assert_eq!(
            certs_hits(&server).await,
            1,
            "299 s — the cached set still answers"
        );
        tokio::time::advance(Duration::from_secs(2)).await;
        store.get_key("k1").await.expect("301 s");
        assert_eq!(
            certs_hits(&server).await,
            2,
            "301 s — the set has expired and is fetched once"
        );
        store.get_key("k1").await.expect("right after");
        assert_eq!(certs_hits(&server).await, 2, "the set just fetched is new");
        assert_eq!(
            Instant::now(),
            t0 + Duration::from_secs(301),
            "the paused clock moved by itself"
        );
    }

    /// T2 만료 뒤 장애 — 301 초의 조회는 한 번 나가 503 으로 실패하고(캐시된 kid 라도 — 낡은 키로 물러서지 않는다),
    /// 백오프 창 안은 IdP 없이 실패하며, IdP 가 회복하고 창이 지나면 한 번 나가 답한다. 창의 탐침은 jitter 와 무관하다 —
    /// 첫 창은 0.2초 × [0.5, 1.0) = [100ms, 200ms) 다.
    #[tokio::test(start_paused = true)]
    async fn expired_key_set_is_not_used_during_an_outage() {
        let (server, idp) = switchable_idp(serving(&["k1"])).await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), timerless_http(), 30);
        warm(&store, &server).await;
        idp.set(ResponseTemplate::new(503));
        tokio::time::advance(Duration::from_secs(301)).await;
        match store.get_key("k1").await {
            Err(KeycloakError::Transport(m)) => assert!(m.contains("HTTP 503"), "{m}"),
            other => panic!("301 s, IdP down — the expired set must not answer, got {other:?}"),
        }
        assert_eq!(certs_hits(&server).await, 2);
        for _ in 0..5 {
            assert!(
                backing_off(&store.get_key("k1").await),
                "inside the backoff window"
            );
        }
        tokio::time::advance(Duration::from_nanos(99_999_999)).await;
        assert!(
            backing_off(&store.get_key("k1").await),
            "still inside the shortest first window"
        );
        assert_eq!(certs_hits(&server).await, 2);
        idp.set(serving(&["k1"]));
        tokio::time::advance(Duration::from_nanos(100_000_001)).await; // 실패로부터 0.2초 — 어느 jitter 의 창도 지났다
        store
            .get_key("k1")
            .await
            .expect("IdP recovered and the window has passed");
        assert_eq!(certs_hits(&server).await, 3);
    }

    /// T3 지운 키 — k1·k2 로 적재, IdP 가 이제 k2 만 낸다: 299 초에는 캐시가 답하고(대조), 301 초에 k1 은 재조회 뒤
    /// 모르는 kid 로 실패하며 k2 는 그 키셋에서 답한다.
    #[tokio::test(start_paused = true)]
    async fn key_removed_from_the_set_is_rejected_once_the_set_expires() {
        let (server, idp) = switchable_idp(serving(&["k1", "k2"])).await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), timerless_http(), 30);
        warm(&store, &server).await;
        idp.set(serving(&["k2"]));
        tokio::time::advance(Duration::from_secs(299)).await;
        store
            .get_key("k1")
            .await
            .expect("299 s — control: within its age the cached set answers");
        assert_eq!(certs_hits(&server).await, 1);
        tokio::time::advance(Duration::from_secs(2)).await;
        match store.get_key("k1").await {
            Err(KeycloakError::TokenValidation(m)) => assert_eq!(m, "unknown kid"),
            other => panic!("301 s — refetched, k1 is gone: got {other:?}"),
        }
        assert_eq!(certs_hits(&server).await, 2);
        store
            .get_key("k2")
            .await
            .expect("k2 answers from the set just fetched");
        assert_eq!(certs_hits(&server).await, 2);
    }

    /// T4 — 100 초의 미해결 kid 강제 재조회(회전한 k2)가 성공하면 키셋을 바꾸고 나이를 다시 센다: 350 초(그
    /// 재조회로부터 250 초)에는 조회가 없고, 401 초(301 초)에는 한 번 있다.
    #[tokio::test(start_paused = true)]
    async fn forced_refetch_restarts_the_age() {
        let (server, idp) = switchable_idp(serving(&["k1"])).await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), timerless_http(), 30);
        warm(&store, &server).await;
        idp.set(serving(&["k1", "k2"]));
        tokio::time::advance(Duration::from_secs(100)).await;
        store
            .get_key("k2")
            .await
            .expect("100 s — an unknown kid forces a refetch");
        assert_eq!(certs_hits(&server).await, 2);
        tokio::time::advance(Duration::from_secs(250)).await;
        store.get_key("k1").await.expect("350 s");
        assert_eq!(
            certs_hits(&server).await,
            2,
            "350 s — 250 s after the refetch, no fetch"
        );
        tokio::time::advance(Duration::from_secs(51)).await;
        store.get_key("k1").await.expect("401 s");
        assert_eq!(
            certs_hits(&server).await,
            3,
            "401 s — 301 s after the refetch, the restarted age has run out"
        );
    }

    /// 나이가 찬 키셋의 재적재도 콜드 적재와 **같은 게이트 잠금** 아래다 — 동시 조회 20 이 요청 하나로 접힌다
    /// (`concurrent_cold_start_collapses_to_one_fetch` 의 짝). 잠금 밖에서 다시 받으면 여기서 21 이 된다.
    #[tokio::test(start_paused = true)]
    async fn concurrent_lookups_on_an_expired_set_collapse_to_one_fetch() {
        let (server, _idp) = switchable_idp(serving(&["k1"])).await;
        let store = Arc::new(JwksStore::new(
            format!("{}/certs", server.uri()),
            timerless_http(),
            30,
        ));
        warm(&store, &server).await;
        tokio::time::advance(Duration::from_secs(301)).await;
        let lookups: Vec<_> = (0..20)
            .map(|_| {
                let s = store.clone();
                tokio::spawn(async move { s.get_key("k1").await.is_ok() })
            })
            .collect();
        for h in lookups {
            assert!(h.await.unwrap(), "every concurrent lookup must resolve k1");
        }
        assert_eq!(
            certs_hits(&server).await,
            2,
            "20 concurrent lookups on an expired set must collapse to one fetch"
        );
    }

    /// 실패 백오프의 jitter 는 실패를 **기록할 때** 한 번 뽑는다(등록부 backoff-jitter-redrawn-per-check) — 실패 하나 뒤
    /// 같은 순간의 거듭된 검사는 같은 답이고, 창의 끝은 검사 사이에 움직이지 않는다. 이음매는 뽑을 때마다 0.95 와 0.5 를
    /// 번갈아 낸다: 한 번 뽑으면 첫 창은 0.2초 × 0.95 = 190ms 다. 검사마다 뽑으면 둘째 검사가 0.5(창 100ms)를 받아
    /// 150ms 에 IdP 로 나가고, 같은 실패가 한 번은 거부하고 한 번은 통과시킨다.
    #[tokio::test(start_paused = true)]
    async fn backoff_jitter_is_drawn_once_when_the_failure_is_recorded() {
        static DRAWS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        fn alternating() -> f64 {
            if DRAWS.fetch_add(1, std::sync::atomic::Ordering::SeqCst) % 2 == 0 {
                0.95
            } else {
                0.5
            }
        }
        let server = failing_server().await;
        let mut store = JwksStore::new(format!("{}/certs", server.uri()), timerless_http(), 30);
        store.jitter = alternating;

        assert!(store.get_key("k1").await.is_err()); // 실패 1(콜드 캐시)
        tokio::time::advance(Duration::from_millis(150)).await;
        let in_window = "JWKS fetch backing off after 1 consecutive failures (retry in 0.04s)";
        for i in 0..6 {
            match store.get_key("k1").await {
                Err(KeycloakError::Transport(m)) => {
                    assert_eq!(m, in_window, "check {i} at the same instant")
                }
                other => panic!("check {i} at the same instant: got {other:?}"),
            }
        }
        assert_eq!(
            certs_hits(&server).await,
            1,
            "checks inside the window reached the IdP"
        );
        tokio::time::advance(Duration::from_nanos(39_999_999)).await; // 실패로부터 190ms − 1ns
        assert!(
            backing_off(&store.get_key("k1").await),
            "1ns before the window's end the check must still refuse (the end did not move earlier)"
        );
        tokio::time::advance(Duration::from_nanos(1)).await; // 190ms
        assert!(
            !backing_off(&store.get_key("k1").await),
            "at the window's end the fetch must go (the end did not move later)"
        );
        assert_eq!(certs_hits(&server).await, 2);
        assert_eq!(
            DRAWS.load(std::sync::atomic::Ordering::SeqCst),
            2,
            "once per recorded failure, never per check"
        );
    }
}
