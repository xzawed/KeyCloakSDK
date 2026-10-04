//! 적대 경로 행렬 — 분류표를 세우고, 적대 변형을 **메서드 손 목록이 아니라 계급에** 붙인다
//! (등록부 `guard-detection-surface-hand-narrowed` · go `hostile_path_matrix_test.go` 의 rust 판).
//!
//! nonce·콜드캐시 백오프·토큰응답 타입검증 축은 `scripts/test/test-security-defaults.sh` 가 손으로 고른
//! 자리에 앵커를 건다. 그래서 **새 공개 교환 경로**가 생기면 세 축 모두 그것을 모른다. 여기서는 경로를
//! 손 목록이 아니라 파생한다:
//!
//!   - 선언 집합: `source_scan`(`facade_dump.rs` 와 **같은** 판독기)이 `rust/src` 에서 읽은 공개 fn 전부 —
//!     SDK 공개 타입의 고유 `pub fn` · 공개 트레이트 impl 의 fn · SDK 공개 트레이트의 기본 메서드 · 자유
//!     `pub fn`(fn 몸통 안의 impl 도 읽는다 — 그 메서드는 전역이다). 규칙으로 빼는 것은 `Debug`·`Display` 의
//!     `fmt` 하나다(렌더링이고, 그 누출은 `facade_dump.rs` 가 잰다). 오버로드가 없는 언어라 라벨 하나가 호출
//!     하나다 — 같은 이름의 트레이트 메서드는 `<T as Tr>::m` 으로 갈린다.
//!   - 호출: ⚠️ rust 에는 런타임 리플렉션이 없다. 그래서 **구동 표**(`drivers()`: 라벨 → 부르는 법)를 두고,
//!     그것이 선언 집합과 **양방향으로 같기**를 요구한다 — 선언됐는데 구동이 없으면(면제 표에 이유가 없으면)
//!     실패, 구동이 있는데 선언이 없으면 낡은 구동이라 실패. 인자는 구동이 고르지 않는다: 전부 `c.a()` 가
//!     **타입**에서 합성하고, 합성한 수가 **시그니처의 인자 수**와 같기를 단언한다(리터럴을 끼우면 운다).
//!     결과도 구동이 고르지 않는다 — `outcome!` 이 반환 타입으로 SDK 오류·그 밖의 오류·값을 가른다. 구동의
//!     호출식은 라벨의 fn 이름을 불러야 한다(`drives_its_label`). 행마다 **새** 기록 IdP 와 **새** 뿌리(캐시가
//!     옆 행으로 새지 않게). 패닉은 `tokio::spawn` 이 회수한다.
//!   - 분류: 그 호출이 IdP 에 실제로 보낸 요청으로 가른다(`classify`). 토큰 부여 = 토큰 엔드포인트 **꼬리**로 가는
//!     POST **또는** 본문(폼·JSON)에 `grant_type` 이 실린 POST — 경로를 바꾸거나 JSON 으로 보낸 교환도 잡는다.
//!
//! 단언:
//!   (1) UNDETERMINED 가 없다(면제 표에 이유와 함께 있으면 통과, 낡은 면제는 실패).
//!   (2) CODE_EXCHANGE·TOKEN_GRANT·JWKS_FETCH 가 각각 비어 있지 않다.
//!   (W1) 손으로 고른 rust 시험이 겨누는 메서드(`HAND`)가 전부 행이고, 기대 계급이고, 그 축의 파생 대상에
//!        들어 있다. 표 자신도 손 목록이라 셋과 대조한다 — 앵커 함수가 정말 그 이름을 부르는가,
//!        `hostile_token_response.rs` 의 `drive` 가 부르는 SDK 이름이 전부 표에 있는가, 보안 기본값 가드의
//!        rust 행위 앵커(`rust/…rs|fn x(`)가 전부 표의 앵커인가.
//!   (W3a) TOKEN_GRANT·CODE_EXCHANGE 행마다 형식이 틀린 토큰 응답 변형 — 변형 집합은 새로 만들지 않는다:
//!        `hostile_variants`(#623 의 열넷)와 `src/token_provider.rs` 의 비문자열 access_token 넷. 기존 시험이
//!        토큰 열 **전부**에서 실패로 단언한 것만 단언하고, 나머지는 측정만 한다(새 계약을 만들지 않는다).
//!        칸마다: 패닉 없음 · 오류 · SDK 오류 타입 · 카나리아가 `{}`·`{:?}`·`{:#?}`·`source()` 사슬 어디에도
//!        없음 · 토큰 엔드포인트에 닿음(≥ 1, 그러나 정상 응답 대조보다 많지 않음) · 그 응답 **뒤로** 요청 없음.
//!        nonce 파라미터는 비운다(`None`) — 교환 행이 id_token 부재가 아니라 **변형**으로 실패하게.
//!   (W3b) TOKEN_GRANT·CODE_EXCHANGE 행 중 **시그니처에 nonce 이름의 파라미터가 있는** 것마다 nonce 가 다른
//!        id_token · 다른 키(같은 kid·다른 kid) · id_token 없음 · nonce 클레임 없음. 대조(맞는 id_token)는 성공하고
//!        JWKS 에 닿아야 한다. nonce 파라미터가 없는 CODE_EXCHANGE 행은 `NONCE_DROP_EXEMPT` 에 이유가 있어야 한다.
//!   (W3c) 분류 실행에서 JWKS 를 조회한 행마다 콜드 캐시 + /certs 503 에서 5 회 — 전부 실패하고
//!        1 ≤ /certs 요청 ≤ 4. 시간이 아니라 요청 수만 잰다 — 다섯 호출 동안 게이트 시계를 얼리고
//!        (`GateClockFreeze`), 그 시계가 움직였으면 그것도 실패다.
//! 실패한 칸은 `KNOWN_GAPS` 에 이유와 함께 있으면 GAP 으로 찍히고, 관측되지 않는 항목은 낡은 것이라 실패한다.
//!
//! go 와 다른 자리:
//!   - 「걷기가 닿는 타입」은 rust 에서 **컴파일**이 정한다. 이 파일은 바깥 크레이트라, 공개 API 로 수신자를
//!     얻을 수 없는 타입의 구동은 컴파일되지 않는다 — 그런 fn 은 구동이 없어 면제 표로 간다(오늘은 하나).
//!   - 「SDK 오류 타입인가」의 대부분은 시그니처가 정적으로 보장한다(`Result<T, KeycloakError>`). 그래도
//!     `outcome!` 이 다른 오류 타입을 `Foreign` 으로 갈라 두어, 그런 fn 이 생기면 그 칸이 운다.
//!   - 문자열 인자 중 이름이 `uri`·`url` 로 끝나는 자리는 URL 을 받는다(rust 는 `RedirectUrl::new` 가 요청
//!     **앞**에서 파싱한다 — JWS 를 넣으면 요청 없이 실패해 교환 행이 UNDETERMINED 가 된다). 이름으로 고르는
//!     것은 nonce 와 같이 **시그니처에서** 파생한 것이다. 다른 이름으로 URL 을 받는 새 fn 은 UNDETERMINED
//!     로 드러난다(닫힌 쪽으로 실패한다).
//!
//! ⚠️ 한계(Grok 레그 실측 — 통과하지만 설계로 받아들인 것):
//!   - 요청도 오류도 없이 끝나는 경로는 NONE 으로 읽힌다(합성 인자·설정이 요청 앞에서 갈라 세우는 것, 비동기로
//!     나가는 요청, 이 IdP 가 아닌 호스트, IdP 없이 토큰을 지어 돌려주는 fn).
//!   - 재시도 상한은 손 상수가 아니라 **그 행의 정상 응답 대조**다 — 늘 두 번 부르는 fn 은 대조도 둘이라 통과한다.
//!   - `nonce = None` 은 id_token 검증을 끈다(`exchange_code` 의 문서화된 계약) — W3a 는 None, W3b 는 Some 만 준다.
//!   - `#[derive]` 가 만드는 fn 은 소스에 없어 선언 집합 밖이다. 항목 자리의 매크로 호출은 판독 불가로 떨어진다
//!     (`source_scan` 의 `flag_item_macro` — 펼칠 수 없으니 닫힌 쪽).
//!
//! 재는 명령: `cargo test --test hostile_path_matrix -- --nocapture` — 분류표·판정표·요약이 찍힌다.

mod hostile_variants;
mod source_scan;

use hostile_variants::{CALLS, EXPECTED, NON_TOKEN_CALLS, hits, renders, unique_windows, variants};
use keycloak_sdk::jwks::JwksStore;
use keycloak_sdk::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak_sdk::{
    AdminClient, AuthClient, ClientCredentialsTokenProvider, JwtValidator, KeycloakClient,
    KeycloakConfig, KeycloakError, OidcEndpoints, TokenProvider, TokenSet, reqwest,
};
use serde_json::{Value, json};
use source_scan::{FnDecl, Scan, fn_body, read_sources, scan};
use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

const CODE_EXCHANGE: &str = "CODE_EXCHANGE";
const TOKEN_GRANT: &str = "TOKEN_GRANT";
const JWKS_FETCH: &str = "JWKS_FETCH";
const OTHER: &str = "OTHER";
const NONE: &str = "NONE";
const UNDETERMINED: &str = "UNDETERMINED";

const REALM: &str = "r";
const CLIENT: &str = "c";
const BASE: &str = "/realms/r/protocol/openid-connect";
// 분류는 realm 과 무관하게 **꼬리**로 본다 — 인자로 받은 realm 의 엔드포인트도 교환이다(go 레그 실측).
const TOKEN_SUFFIX: &str = "/protocol/openid-connect/token";
const CERTS_SUFFIX: &str = "/protocol/openid-connect/certs";

/// 구동이 없어도(= UNDETERMINED) 되는 선언과 그 이유. **이유 없는 면제는 넣지 않는다.** 선언 집합에 없거나
/// 구동이 생긴 항목은 낡은 면제로 실패한다.
const UNDETERMINED_EXEMPT: &[(&str, &str)] = &[(
    "<SdkTokenSupplier as KeycloakTokenSupplier>::get",
    "admin→토큰 어댑터(admin.rs) — 소비자가 값을 얻을 길이 없다(공개 생성자가 없고 KeycloakAdmin 의 \
     token_supplier 필드는 비공개). 그것이 내는 토큰 요청은 부른 AdminClient 메서드의 행에 잡히고, \
     raw() 로 닿는 길은 §4(b) 의 foreign 메서드뿐이다",
)];

/// 선언 집합에서 **규칙으로** 빼는 트레이트 impl — 이름 목록이 아니라 트레이트로. 렌더링(`fmt`)이고, 그
/// 출력의 비밀 누출은 `facade_dump.rs` 가 판정한다.
const RULE_EXCLUDED_TRAITS: &[&str] = &["Debug", "Display"];

/// W3b 에서 빠져도 되는 CODE_EXCHANGE 행과 그 이유. **이유 없는 면제는 넣지 않는다.** nonce 파라미터의 이름으로
/// 대상을 파생하므로, nonce 를 다른 이름(`expected` 등)으로 받는 새 교환 fn 은 이 표가 없으면 **실패한다**
/// (go 레그가 지목한 조용한 빠짐을 여기서는 닫힌 쪽으로 둔다). 오늘은 비어 있다.
const NONCE_DROP_EXEMPT: &[(&str, &str)] = &[];

/// 현재 main 에서 실패하는 칸 — 키는 `W3<축> 행/변형`, 값은 `등록부 id: 한 줄 이유`. SDK 를 고치지 않고
/// 드러내 둔다. 관측되지 않는(이제 통과하거나 칸이 없는) 항목은 낡은 것이라 실패한다. **이유 없는 항목은
/// 넣지 않는다.**
const KNOWN_GAPS: &[(&str, &str)] = &[];

/// W3c 의 호출 수 — 상한 k−1 이 백오프, 하한 1 이 콜드 경로 도달의 증명이다.
const COLD_K: usize = 5;

// ── 키·서명 ──────────────────────────────────────────────────────────────────────────────

struct Key {
    pem: String,
    jwk: Value,
}

fn rsa_key() -> Key {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use rsa::pkcs1::{EncodeRsaPrivateKey, LineEnding};
    use rsa::traits::PublicKeyParts;
    let sk = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).expect("rsa key");
    let pk = rsa::RsaPublicKey::from(&sk);
    Key {
        pem: sk.to_pkcs1_pem(LineEnding::LF).expect("pem").to_string(),
        jwk: json!({"kty": "RSA", "kid": "k1", "use": "sig", "alg": "RS256",
            "n": URL_SAFE_NO_PAD.encode(pk.n().to_bytes_be()),
            "e": URL_SAFE_NO_PAD.encode(pk.e().to_bytes_be())}),
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_secs()
}

/// `iss`·`sub`·`aud`·`exp`·`iat` 가 맞는 JWS 에 `extra` 클레임을 더해 `kid` 로 서명한다.
fn sign(key: &Key, kid: &str, iss: &str, extra: Value) -> String {
    let mut claims =
        json!({"iss": iss, "sub": "u1", "aud": CLIENT, "exp": now() + 600, "iat": now()});
    if let (Some(c), Some(x)) = (claims.as_object_mut(), extra.as_object()) {
        c.extend(x.clone());
    }
    let mut h = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256);
    h.kid = Some(kid.into());
    let ek = jsonwebtoken::EncodingKey::from_rsa_pem(key.pem.as_bytes()).expect("encoding key");
    jsonwebtoken::encode(&h, &claims, &ek).expect("sign")
}

struct Keys {
    main: Key,
    /// W3b 의 「다른 키」 — JWKS 에 없다.
    other: Key,
    /// 발급자(서버 주소) → (보편 인자, id_token). 풀에서 같은 서버가 다시 나오므로 서명은 주소마다 한 번이다.
    signed: Mutex<BTreeMap<String, (String, String)>>,
}

impl Keys {
    fn new() -> Self {
        Self {
            main: rsa_key(),
            other: rsa_key(),
            signed: Mutex::new(BTreeMap::new()),
        }
    }

    /// 보편 인자와, nonce 가 그것인 id_token. ⚠️ 보편 인자는 평문이 아니라 **이 IdP 키로 서명한 JWS** 다 —
    /// 평문이면 토큰을 받는 fn(validate 둘·get_key)이 요청 전에 실패해 JWKS_FETCH 가 빈다(go 레그 실측).
    fn universal(&self, iss: &str) -> (String, String) {
        let mut m = self.signed.lock().expect("signed");
        m.entry(iss.to_string())
            .or_insert_with(|| {
                let u = sign(&self.main, "k1", iss, json!({}));
                let id = sign(&self.main, "k1", iss, json!({"nonce": u}));
                (u, id)
            })
            .clone()
    }
}

// ── 기록하는 가짜 IdP ─────────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct Resp {
    status: u16,
    content_type: String,
    body: String,
}

impl Resp {
    fn json(body: Value) -> Self {
        Resp {
            status: 200,
            content_type: "application/json".into(),
            body: body.to_string(),
        }
    }

    fn template(&self) -> ResponseTemplate {
        ResponseTemplate::new(self.status)
            .set_body_raw(self.body.clone().into_bytes(), self.content_type.as_str())
    }
}

/// 칸이 뿌리를 만든 **뒤에** 바꾸는 IdP 동작 — 토큰 응답 덮어쓰기(W3a·b) · JWKS 503(W3c).
#[derive(Default)]
struct Switch {
    token: Option<Resp>,
    certs_down: bool,
}

/// 모든 요청을 받는 응답기. 기록은 wiremock 이 라우팅 **앞**에서 하므로 라우트가 없는 경로(admin 404 포함)도
/// 남는다 — 분류는 SDK 가 무엇을 **시도했나**를 본다.
struct Router {
    switch: Arc<Mutex<Switch>>,
    normal_token: Resp,
    jwks: Value,
}

impl Respond for Router {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let sw = self.switch.lock().expect("switch");
        // 본문에 grant_type 이 실린 POST 는 경로와 무관하게 토큰 응답을 받는다 — 분류(`is_token_post`)와 같은 규칙이라
        // 다른 경로로 부여를 보내는 새 fn 도 W3 변형을 받는다.
        let grant = req.method.as_str() == "POST" && !grant_type(&req.body).is_empty();
        let t = match (req.method.as_str(), req.url.path().strip_prefix(BASE)) {
            ("POST", Some("/token")) => sw.token.as_ref().unwrap_or(&self.normal_token).template(),
            ("POST", _) if grant => sw.token.as_ref().unwrap_or(&self.normal_token).template(),
            ("POST", Some("/token/introspect")) => Resp::json(
                json!({"active": true, "username": "svc", "client_id": CLIENT, "sub": "u1"}),
            )
            .template(),
            ("GET", Some("/certs")) if sw.certs_down => ResponseTemplate::new(503),
            ("GET", Some("/certs")) => ResponseTemplate::new(200).set_body_json(&self.jwks),
            ("POST", Some("/logout")) => ResponseTemplate::new(204),
            _ => ResponseTemplate::new(404),
        };
        // ⚠️ 서버가 먼저 닫게 한다. 칸마다 새 클라이언트라 커넥션이 재사용되지 않는데, 클라이언트가 먼저 닫으면
        // TIME_WAIT 이 **클라이언트의 임시 포트**에 남는다 — 한 번 돌 때 약 2000 개였고, 윈도 동적 포트 16384 개를
        // 다른 시험들과 함께 바닥내 연결이 즉시 실패했다(요청이 기록되지 않은 채 Transport 로 떨어져 칸이
        // 「토큰 엔드포인트에 안 닿았다」로 흔들렸다 — 실측 2026-09-27). 서버가 닫으면 TIME_WAIT 은 서버의
        // 듣기 포트 하나에 모인다.
        t.insert_header("connection", "close")
    }
}

struct Idp {
    server: MockServer,
    switch: Arc<Mutex<Switch>>,
    universal: String,
    iss: String,
}

impl Idp {
    async fn start(keys: &Keys) -> Idp {
        let server = MockServer::start().await;
        let iss = format!("{}/realms/{REALM}", server.uri());
        let (universal, id_token) = keys.universal(&iss);
        let switch = Arc::new(Mutex::new(Switch::default()));
        // ⚠️ expires_in 을 skew(30s) 보다 짧게 준다 — provider 캐시가 늘 식어 있어, 부여에 **닿을 수 있는** fn 은
        // 실제로 닿는다(go 레그 실측: 300 이면 캐시가 부여 경로를 가려 TOKEN_GRANT 29→3).
        let normal_token = Resp::json(json!({
            "access_token": "hp-access", "token_type": "Bearer", "expires_in": 1,
            "refresh_token": "hp-refresh", "id_token": id_token, "scope": "openid",
        }));
        Mock::given(wiremock::matchers::any())
            .respond_with(Router {
                switch: switch.clone(),
                normal_token,
                jwks: json!({"keys": [keys.main.jwk]}),
            })
            .mount(&server)
            .await;
        Idp {
            server,
            switch,
            universal,
            iss,
        }
    }

    fn cfg(&self) -> KeycloakConfig {
        KeycloakConfig::new(self.server.uri(), REALM, CLIENT)
            .expect("config")
            .with_client_secret("hp-client-secret")
    }

    fn set_token(&self, r: Option<Resp>) {
        self.switch.lock().expect("switch").token = r;
    }

    fn set_certs_down(&self, down: bool) {
        self.switch.lock().expect("switch").certs_down = down;
    }

    async fn requests(&self) -> Vec<Req> {
        self.server
            .received_requests()
            .await
            .expect("recording")
            .iter()
            .map(Req::from)
            .collect()
    }
}

#[derive(Clone, Debug)]
struct Req {
    method: String,
    path: String,
    grant: String,
}

/// 본문의 `grant_type` — 폼(RFC 6749 §4.1.3)이든 JSON 이든. 없으면 빈 문자열.
/// ⚠️ 폼만 읽으면 JSON 으로 보낸 코드 교환이 TOKEN_GRANT 로 읽혀 W3b 가 빠졌다(Grok 레그, 실측 SILENT).
fn grant_type(body: &[u8]) -> String {
    url::form_urlencoded::parse(body)
        .find(|(k, _)| k == "grant_type")
        .map(|(_, v)| v.into_owned())
        .or_else(|| {
            serde_json::from_slice::<Value>(body)
                .ok()?
                .get("grant_type")?
                .as_str()
                .map(str::to_string)
        })
        .unwrap_or_default()
}

impl From<&Request> for Req {
    fn from(r: &Request) -> Self {
        let method = r.method.as_str().to_string();
        let path = r.url.path().to_string();
        let grant = if method == "POST" {
            grant_type(&r.body)
        } else {
            String::new()
        };
        Req {
            method,
            path,
            grant,
        }
    }
}

/// 토큰 부여 요청 — 토큰 엔드포인트 꼬리로 가는 POST, **또는** 본문에 grant_type 이 실린 POST(경로 무관).
/// ⚠️ 꼬리만 보면 `…/token/exchange` 로 코드를 교환하는 새 fn 이 OTHER 로 읽혀 W3 가 안 붙었다(Grok 레그, 실측 SILENT).
fn is_token_post(r: &Req) -> bool {
    r.method == "POST" && (r.path.ends_with(TOKEN_SUFFIX) || !r.grant.is_empty())
}

fn is_certs_get(r: &Req) -> bool {
    r.method == "GET" && r.path.ends_with(CERTS_SUFFIX)
}

/// 요청으로 가른다. 앞 줄이 이긴다: 코드 교환 > 토큰 부여 > JWKS 조회 > 그 밖의 요청 > 요청 없음.
/// ⚠️ 토큰 엔드포인트 POST 는 grant_type 이 무엇이든 TOKEN_GRANT 다 — 새 grant 가 OTHER 로 새지 않게.
fn classify(reqs: &[Req], failed: bool) -> &'static str {
    if reqs
        .iter()
        .any(|r| is_token_post(r) && r.grant == "authorization_code")
    {
        CODE_EXCHANGE
    } else if reqs.iter().any(is_token_post) {
        TOKEN_GRANT
    } else if reqs.iter().any(is_certs_get) {
        JWKS_FETCH
    } else if !reqs.is_empty() {
        OTHER
    } else if failed {
        UNDETERMINED
    } else {
        NONE
    }
}

fn format_reqs(reqs: &[Req], universal: &str) -> String {
    if reqs.is_empty() {
        return "-".into();
    }
    let mut order: Vec<String> = Vec::new();
    let mut count: BTreeMap<String, usize> = BTreeMap::new();
    for r in reqs {
        let mut p = r.path.strip_prefix(BASE).unwrap_or(&r.path).to_string();
        if !universal.is_empty() {
            p = p.replace(universal, "{U}");
        }
        let mut k = format!("{} {p}", r.method);
        if !r.grant.is_empty() {
            k += &format!("[{}]", r.grant);
        }
        if !count.contains_key(&k) {
            order.push(k.clone());
        }
        *count.entry(k).or_default() += 1;
    }
    order
        .iter()
        .map(|k| match count[k] {
            1 => k.clone(),
            n => format!("{k} ×{n}"),
        })
        .collect::<Vec<_>>()
        .join(", ")
}

// ── 호출 문맥 · 인자 합성 ────────────────────────────────────────────────────────────────

/// 한 칸의 호출 문맥. `params` 는 그 행의 **시그니처**(스캐너가 읽은 것)이고, `c.a()` 가 부를 때마다 위치가
/// 하나씩 늘어 그 위치의 인자 이름·비움 여부를 본다.
struct Ctx {
    cfg: KeycloakConfig,
    endpoints: OidcEndpoints,
    http: reqwest::Client,
    universal: String,
    url: String,
    params: Vec<(String, String)>,
    blank: BTreeSet<usize>,
    pos: AtomicUsize,
}

impl Ctx {
    fn new(idp: &Idp, params: &[(String, String)], blank: BTreeSet<usize>) -> Arc<Ctx> {
        let cfg = idp.cfg();
        Arc::new(Ctx {
            endpoints: OidcEndpoints::new(&cfg),
            cfg,
            http: reqwest::Client::new(),
            universal: idp.universal.clone(),
            url: "https://app.example/cb".into(),
            params: params.to_vec(),
            blank,
            pos: AtomicUsize::new(0),
        })
    }

    /// 다음 인자를 **타입에서** 합성한다. 비울 위치면 그 타입의 영값(`None`·`""`)이다.
    fn a<'c, T: Synth<'c>>(&'c self) -> T {
        let pos = self.pos.fetch_add(1, Ordering::SeqCst);
        if self.blank.contains(&pos) {
            return T::zero(self);
        }
        let name = self.params.get(pos).map_or("", |(n, _)| n.as_str());
        T::synth(self, name)
    }
}

/// 이름이 `uri`·`url` 로 끝나는 문자열 인자 — 시그니처에서 읽는다(머리 주석의 「go 와 다른 자리」).
fn uri_like(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n.ends_with("uri") || n.ends_with("url")
}

/// 타입 → 인자. 문자열은 보편 인자(서명된 JWS), 수는 1, 불리언은 false, 모음은 비움, representation 은
/// 기본값, SDK 부품은 이 칸의 IdP 를 가리키는 새 것이다.
trait Synth<'c>: Sized {
    fn synth(c: &'c Ctx, name: &str) -> Self;
    fn zero(c: &'c Ctx) -> Self {
        Self::synth(c, "")
    }
}

impl<'c> Synth<'c> for &'c str {
    fn synth(c: &'c Ctx, name: &str) -> Self {
        if uri_like(name) { &c.url } else { &c.universal }
    }
    fn zero(_: &'c Ctx) -> Self {
        ""
    }
}

impl<'c> Synth<'c> for Option<&'c str> {
    fn synth(c: &'c Ctx, name: &str) -> Self {
        Some(<&str>::synth(c, name))
    }
    fn zero(_: &'c Ctx) -> Self {
        None
    }
}

impl<'c> Synth<'c> for String {
    fn synth(c: &'c Ctx, name: &str) -> Self {
        <&str>::synth(c, name).to_string()
    }
    fn zero(_: &'c Ctx) -> Self {
        String::new()
    }
}

macro_rules! synth_const {
    ($($t:ty => $v:expr, $z:expr;)*) => {$(
        impl<'c> Synth<'c> for $t {
            fn synth(_: &'c Ctx, _: &str) -> Self { $v }
            fn zero(_: &'c Ctx) -> Self { $z }
        }
    )*};
}

synth_const! {
    i32 => 1, 0;
    u16 => 1, 0;
    u64 => 1, 0;
    bool => false, false;
    Vec<String> => Vec::new(), Vec::new();
    UserRepresentation => Default::default(), Default::default();
    ClientRepresentation => Default::default(), Default::default();
    RealmRepresentation => Default::default(), Default::default();
    RoleRepresentation => Default::default(), Default::default();
    GroupRepresentation => Default::default(), Default::default();
}

impl<'c> Synth<'c> for reqwest::Client {
    fn synth(c: &'c Ctx, _: &str) -> Self {
        c.http.clone()
    }
}

impl<'c> Synth<'c> for &'c KeycloakConfig {
    fn synth(c: &'c Ctx, _: &str) -> Self {
        &c.cfg
    }
}

impl<'c> Synth<'c> for KeycloakConfig {
    fn synth(c: &'c Ctx, _: &str) -> Self {
        c.cfg.clone()
    }
}

impl<'c> Synth<'c> for &'c OidcEndpoints {
    fn synth(c: &'c Ctx, _: &str) -> Self {
        &c.endpoints
    }
}

impl<'c> Synth<'c> for OidcEndpoints {
    fn synth(c: &'c Ctx, _: &str) -> Self {
        OidcEndpoints::new(&c.cfg)
    }
}

impl<'c> Synth<'c> for JwksStore {
    fn synth(c: &'c Ctx, _: &str) -> Self {
        JwksStore::new(
            c.endpoints.jwks(),
            c.http.clone(),
            c.cfg.jwks_min_refetch_secs,
        )
    }
}

impl<'c> Synth<'c> for JwtValidator {
    fn synth(c: &'c Ctx, _: &str) -> Self {
        JwtValidator::new(&c.cfg, &c.endpoints, JwksStore::synth(c, "")).expect("validator")
    }
}

impl<'c> Synth<'c> for Arc<dyn TokenProvider> {
    fn synth(c: &'c Ctx, _: &str) -> Self {
        Arc::new(ClientCredentialsTokenProvider::new(
            c.cfg.clone(),
            c.http.clone(),
        ))
    }
}

// ── 결과 가르기(autoderef 특수화) ───────────────────────────────────────────────────────────
// `(&&&Out(v)).kind()` 는 `v` 의 **구체 타입**으로 풀린다: SDK 결과 > 그 밖의 `Result` > 값. 구동이 결과를
// 어떻게 읽을지 고르지 않게 한다(오류를 `Ok` 로 감싸 넘기는 구동이 생기지 않게).

enum Kind {
    Ok,
    Sdk(KeycloakError),
    /// SDK 오류 타입이 아닌 오류 — 타입 이름과 렌더링.
    Foreign(&'static str, Vec<(&'static str, String)>),
    Panic(String),
}

struct Out<T>(Cell<Option<T>>);

trait SdkResult {
    fn kind(&self) -> Kind;
}
impl<T> SdkResult for &&Out<Result<T, KeycloakError>> {
    fn kind(&self) -> Kind {
        match self.0.take() {
            Some(Err(e)) => Kind::Sdk(e),
            _ => Kind::Ok,
        }
    }
}

trait AnyResult {
    fn kind(&self) -> Kind;
}
impl<T, E: fmt::Debug> AnyResult for &Out<Result<T, E>> {
    fn kind(&self) -> Kind {
        match self.0.take() {
            Some(Err(e)) => Kind::Foreign(
                std::any::type_name::<E>(),
                vec![("{:?}", format!("{e:?}")), ("{:#?}", format!("{e:#?}"))],
            ),
            _ => Kind::Ok,
        }
    }
}

trait PlainValue {
    fn kind(&self) -> Kind;
}
impl<T> PlainValue for Out<T> {
    fn kind(&self) -> Kind {
        Kind::Ok
    }
}

macro_rules! outcome {
    ($v:expr) => {
        (&&&Out(Cell::new(Some($v)))).kind()
    };
}

// ── 뿌리 · 구동 표 ──────────────────────────────────────────────────────────────────────

/// 수신자를 얻는 공개 API 뿌리 — **덜 데운 것부터**(go 의 builders). 칸마다 새로 만든다.
///
/// `large_enum_variant` 를 끈다 — 칸마다 하나 만들어 `Arc` 로 잠깐 쥐는 시험 그릇이라 크기가 문제가 아니고, 변형을
/// 상자에 넣으면 구동 표의 호출 원문(`TokenProvider::access_token(p)` — 스캐너가 대조한다)이 바뀐다. 이 경고는
/// `JwksStore` 가 떼어 낸 fetch 를 위해 상태를 `Arc` 뒤로 옮겨 작아지면서(둘째로 큰 변형이 `Validator` 에서
/// `Config` 로 바뀜) 처음 났다.
#[allow(clippy::large_enum_variant)]
enum Root {
    Unit(()),
    Client(KeycloakClient),
    Provider(ClientCredentialsTokenProvider),
    Validator(JwtValidator),
    Jwks(JwksStore),
    Endpoints(OidcEndpoints),
    Config(KeycloakConfig),
    Tokens(TokenSet),
}

#[derive(Clone, Copy, Debug)]
enum RootKind {
    Unit,
    Client,
    Provider,
    Validator,
    Jwks,
    Endpoints,
    Config,
    Tokens,
}

async fn build_root(kind: RootKind, c: &Ctx) -> Root {
    match kind {
        RootKind::Unit => Root::Unit(()),
        RootKind::Client => Root::Client(KeycloakClient::new(c.cfg.clone()).expect("client")),
        RootKind::Provider => Root::Provider(ClientCredentialsTokenProvider::new(
            c.cfg.clone(),
            c.http.clone(),
        )),
        RootKind::Validator => Root::Validator(JwtValidator::synth(c, "")),
        RootKind::Jwks => Root::Jwks(JwksStore::synth(c, "")),
        RootKind::Endpoints => Root::Endpoints(OidcEndpoints::new(&c.cfg)),
        RootKind::Config => Root::Config(c.cfg.clone()),
        // 값 타입은 공개 API 로 얻는다 — 그 요청은 칸이 표시를 옮긴 **앞**이라 행의 몫이 아니다.
        RootKind::Tokens => Root::Tokens(
            KeycloakClient::new(c.cfg.clone())
                .expect("client")
                .auth()
                .client_credentials_token()
                .await
                .expect("TokenSet 뿌리"),
        ),
    }
}

type Fut = Pin<Box<dyn Future<Output = Kind> + Send>>;

struct Driver {
    label: &'static str,
    root: RootKind,
    call: fn(Arc<Ctx>, Arc<Root>) -> Fut,
    /// 호출식의 원문(`stringify!`) — 라벨의 fn 을 정말 부르는지 대조한다(아래 `drives_its_label`).
    src: &'static str,
}

/// 구동의 호출식이 라벨의 fn 이름을 **호출**하는가(`이름(`·`이름::<`). ⚠️ 없으면 라벨과 다른 fn 을 부르는 구동이
/// 인자 수만 맞춰 그 라벨의 칸을 전부 대신 통과시킨다(Grok 레그, 실측 SILENT).
fn drives_its_label(d: &Driver) -> bool {
    let src: String = d.src.chars().filter(|c| !c.is_whitespace()).collect();
    let name = method_name(d.label);
    [
        format!(".{name}("),
        format!("::{name}("),
        format!(".{name}::<"),
    ]
    .iter()
    .any(|p| src.contains(p.as_str()))
}

/// 구동 한 줄 — `drv!("라벨", 뿌리, |수신자, c| 호출)`. 인자는 전부 `c.a()`(타입에서 합성)로 준다.
macro_rules! drv {
    ($label:literal, $root:ident, |$r:pat_param, $c:ident| $call:expr) => {{
        fn call(ctx: Arc<Ctx>, root: Arc<Root>) -> Fut {
            Box::pin(async move {
                let $c: &Ctx = &ctx;
                let _ = $c;
                let Root::$root($r) = &*root else {
                    panic!("{}: 뿌리가 {:?} 가 아니다", $label, RootKind::$root);
                };
                let v = $call;
                outcome!(v)
            })
        }
        Driver {
            label: $label,
            root: RootKind::$root,
            call,
            src: stringify!($call),
        }
    }};
}

/// 구동 표 — 선언 집합과 **양방향으로 같아야** 한다(아래 대조). 라벨은 스캐너의 라벨 그대로다.
fn drivers() -> Vec<Driver> {
    vec![
        // ── 연관 함수(수신자 없음) — 공개 생성자·변환 ──
        drv!("AdminClient::new", Unit, |_, c| AdminClient::new(
            c.a(),
            c.a(),
            c.a()
        )),
        drv!("AuthClient::new", Unit, |_, c| AuthClient::new(
            c.a(),
            c.a(),
            c.a(),
            c.a()
        )),
        drv!("ClientCredentialsTokenProvider::new", Unit, |_, c| {
            ClientCredentialsTokenProvider::new(c.a(), c.a())
        }),
        drv!("JwksStore::new", Unit, |_, c| JwksStore::new(
            c.a::<&str>(),
            c.a(),
            c.a()
        )),
        drv!("JwtValidator::new", Unit, |_, c| JwtValidator::new(
            c.a(),
            c.a(),
            c.a()
        )),
        drv!("KeycloakClient::new", Unit, |_, c| KeycloakClient::new(
            c.a()
        )),
        drv!("KeycloakConfig::new", Unit, |_, c| {
            KeycloakConfig::new(c.a::<&str>(), c.a::<&str>(), c.a::<&str>())
        }),
        drv!("KeycloakError::from_admin_status", Unit, |_, c| {
            KeycloakError::from_admin_status(c.a())
        }),
        drv!("OidcEndpoints::new", Unit, |_, c| OidcEndpoints::new(c.a())),
        // ── KeycloakClient ──
        drv!("KeycloakClient::auth", Client, |k, c| k.auth()),
        drv!("KeycloakClient::admin", Client, |k, c| k.admin()),
        // ── AuthClient(KeycloakClient::auth 로 닿는다) ──
        drv!(
            "AuthClient::create_authorization_request",
            Client,
            |k, c| { k.auth().create_authorization_request() }
        ),
        drv!(
            "AuthClient::create_authorization_request_with_redirect",
            Client,
            |k, c| { k.auth().create_authorization_request_with_redirect(c.a()) }
        ),
        drv!("AuthClient::exchange_code", Client, |k, c| {
            k.auth().exchange_code(c.a(), c.a(), c.a()).await
        }),
        drv!("AuthClient::exchange_code_with_redirect", Client, |k, c| {
            k.auth()
                .exchange_code_with_redirect(c.a(), c.a(), c.a(), c.a())
                .await
        }),
        drv!("AuthClient::client_credentials_token", Client, |k, c| {
            k.auth().client_credentials_token().await
        }),
        drv!("AuthClient::refresh", Client, |k, c| k
            .auth()
            .refresh(c.a())
            .await),
        drv!("AuthClient::validate", Client, |k, c| k
            .auth()
            .validate(c.a())
            .await),
        drv!("AuthClient::introspect", Client, |k, c| k
            .auth()
            .introspect(c.a())
            .await),
        drv!("AuthClient::logout", Client, |k, c| k
            .auth()
            .logout(c.a())
            .await),
        drv!(
            "<AuthClient as TokenProvider>::access_token",
            Client,
            |k, c| { TokenProvider::access_token(k.auth()).await }
        ),
        // ── AdminClient(KeycloakClient::admin 로 닿는다 — 캐싱 provider 경로) ──
        drv!("AdminClient::create_user", Client, |k, c| k
            .admin()
            .create_user(c.a())
            .await),
        drv!("AdminClient::get_user", Client, |k, c| k
            .admin()
            .get_user(c.a())
            .await),
        drv!("AdminClient::search_users", Client, |k, c| {
            k.admin().search_users(c.a(), c.a(), c.a()).await
        }),
        drv!("AdminClient::find_user_by_username", Client, |k, c| {
            k.admin().find_user_by_username(c.a()).await
        }),
        drv!("AdminClient::update_user", Client, |k, c| {
            k.admin().update_user(c.a(), c.a()).await
        }),
        drv!("AdminClient::delete_user", Client, |k, c| k
            .admin()
            .delete_user(c.a())
            .await),
        drv!("AdminClient::create_client", Client, |k, c| {
            k.admin().create_client(c.a()).await
        }),
        drv!("AdminClient::get_client", Client, |k, c| k
            .admin()
            .get_client(c.a())
            .await),
        drv!("AdminClient::list_clients", Client, |k, c| {
            k.admin().list_clients(c.a(), c.a()).await
        }),
        drv!("AdminClient::update_client", Client, |k, c| {
            k.admin().update_client(c.a(), c.a()).await
        }),
        drv!("AdminClient::delete_client", Client, |k, c| {
            k.admin().delete_client(c.a()).await
        }),
        drv!("AdminClient::get_realm", Client, |k, c| k
            .admin()
            .get_realm()
            .await),
        drv!("AdminClient::create_realm", Client, |k, c| {
            k.admin().create_realm(c.a()).await
        }),
        drv!("AdminClient::list_realms", Client, |k, c| k
            .admin()
            .list_realms()
            .await),
        drv!("AdminClient::update_realm", Client, |k, c| {
            k.admin().update_realm(c.a(), c.a()).await
        }),
        drv!("AdminClient::delete_realm", Client, |k, c| {
            k.admin().delete_realm(c.a()).await
        }),
        drv!("AdminClient::create_role", Client, |k, c| k
            .admin()
            .create_role(c.a())
            .await),
        drv!("AdminClient::get_role", Client, |k, c| k
            .admin()
            .get_role(c.a())
            .await),
        drv!("AdminClient::list_roles", Client, |k, c| {
            k.admin().list_roles(c.a(), c.a()).await
        }),
        drv!("AdminClient::update_role", Client, |k, c| {
            k.admin().update_role(c.a(), c.a()).await
        }),
        drv!("AdminClient::delete_role", Client, |k, c| k
            .admin()
            .delete_role(c.a())
            .await),
        drv!("AdminClient::create_group", Client, |k, c| {
            k.admin().create_group(c.a()).await
        }),
        drv!("AdminClient::get_group", Client, |k, c| k
            .admin()
            .get_group(c.a())
            .await),
        drv!("AdminClient::list_groups", Client, |k, c| {
            k.admin().list_groups(c.a(), c.a()).await
        }),
        drv!("AdminClient::update_group", Client, |k, c| {
            k.admin().update_group(c.a(), c.a()).await
        }),
        drv!("AdminClient::delete_group", Client, |k, c| {
            k.admin().delete_group(c.a()).await
        }),
        drv!("AdminClient::raw", Client, |k, c| k.admin().raw()),
        // ── 저수준 부품 ──
        drv!(
            "<ClientCredentialsTokenProvider as TokenProvider>::access_token",
            Provider,
            |p, c| { TokenProvider::access_token(p).await }
        ),
        drv!("JwtValidator::validate", Validator, |v, c| v
            .validate(c.a())
            .await),
        drv!("JwksStore::get_key", Jwks, |j, c| j.get_key(c.a()).await),
        drv!("OidcEndpoints::issuer", Endpoints, |e, c| e.issuer()),
        drv!("OidcEndpoints::token", Endpoints, |e, c| e.token()),
        drv!("OidcEndpoints::authorization", Endpoints, |e, c| e
            .authorization()),
        drv!("OidcEndpoints::introspection", Endpoints, |e, c| e
            .introspection()),
        drv!("OidcEndpoints::end_session", Endpoints, |e, c| e
            .end_session()),
        drv!("OidcEndpoints::jwks", Endpoints, |e, c| e.jwks()),
        // ── 값 타입 ──
        drv!("KeycloakConfig::with_client_secret", Config, |k, c| {
            k.clone().with_client_secret(c.a::<&str>())
        }),
        drv!("KeycloakConfig::with_redirect_uri", Config, |k, c| {
            k.clone().with_redirect_uri(c.a::<&str>())
        }),
        drv!(
            "KeycloakConfig::with_signature_algorithms",
            Config,
            |k, c| { k.clone().with_signature_algorithms(c.a()) }
        ),
        drv!(
            "KeycloakConfig::with_jwks_min_refetch_secs",
            Config,
            |k, c| { k.clone().with_jwks_min_refetch_secs(c.a()) }
        ),
        drv!("KeycloakConfig::with_expected_audience", Config, |k, c| {
            k.clone().with_expected_audience(c.a::<&str>())
        }),
        drv!("TokenSet::is_expired", Tokens, |t, c| t
            .is_expired(c.a(), c.a())),
    ]
}

// ── 선언 집합 ────────────────────────────────────────────────────────────────────────────

fn scan_src() -> Scan {
    let mut files = Vec::new();
    read_sources(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    scan(&files)
}

/// 선언 집합(라벨 순)과, 규칙으로 뺀 라벨.
fn declared(sc: &Scan) -> (BTreeMap<String, FnDecl>, Vec<String>) {
    let mut out = BTreeMap::new();
    let mut excluded = Vec::new();
    for f in sc.public_fns() {
        if f.owner.is_some()
            && f.trait_name
                .as_deref()
                .is_some_and(|t| RULE_EXCLUDED_TRAITS.contains(&t))
        {
            excluded.push(f.label.clone());
        } else {
            out.insert(f.label.clone(), f.clone());
        }
    }
    (out, excluded)
}

/// 시그니처에서 이름에 "nonce" 가 든 인자의 위치(0 부터, self 제외 — `c.a()` 의 순번과 같다).
fn nonce_params(f: &FnDecl) -> BTreeSet<usize> {
    f.params
        .iter()
        .enumerate()
        .filter(|(_, (n, _))| n.to_ascii_lowercase().contains("nonce"))
        .map(|(i, _)| i)
        .collect()
}

// ── 한 칸 ────────────────────────────────────────────────────────────────────────────────

async fn run_once(d: &Driver, ctx: &Arc<Ctx>, root: &Arc<Root>) -> (Kind, usize) {
    ctx.pos.store(0, Ordering::SeqCst);
    let kind = match tokio::spawn((d.call)(ctx.clone(), root.clone())).await {
        Ok(k) => k,
        Err(e) if e.is_panic() => {
            let p = e.into_panic();
            Kind::Panic(
                p.downcast_ref::<String>()
                    .cloned()
                    .or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string()))
                    .unwrap_or_else(|| "?".into()),
            )
        }
        Err(e) => Kind::Panic(e.to_string()),
    };
    (kind, ctx.pos.load(Ordering::SeqCst))
}

struct Run {
    sent: Vec<Req>,
    kind: Kind,
    args: usize,
    universal: String,
}

/// 새 IdP·새 뿌리에서 한 번 부른다. `resp` 는 뿌리를 만든 **뒤에** 토큰 응답을 바꾼다(`None` 이면 정상).
async fn cell(
    keys: &Keys,
    f: &FnDecl,
    d: &Driver,
    blank: BTreeSet<usize>,
    resp: impl FnOnce(&Idp) -> Option<Resp>,
) -> Run {
    let idp = Idp::start(keys).await;
    let ctx = Ctx::new(&idp, &f.params, blank);
    let root = Arc::new(build_root(d.root, &ctx).await);
    let mark = idp.requests().await.len();
    idp.set_token(resp(&idp));
    let (kind, args) = run_once(d, &ctx, &root).await;
    let mut sent = idp.requests().await;
    Run {
        sent: sent.split_off(mark.min(sent.len())),
        kind,
        args,
        universal: idp.universal.clone(),
    }
}

// ── 분류표 ───────────────────────────────────────────────────────────────────────────────

struct Row {
    label: String,
    class: &'static str,
    reqs: String,
    root: String,
    outcome: String,
    note: String,
    sent: Vec<Req>,
}

async fn classify_row(keys: &Keys, f: &FnDecl, d: &Driver, fails: &mut Vec<String>) -> Row {
    let run = cell(keys, f, d, BTreeSet::new(), |_| None).await;
    let failed = !matches!(run.kind, Kind::Ok);
    let (outcome, note) = match &run.kind {
        Kind::Ok => ("ok", String::new()),
        Kind::Sdk(e) => ("err", format!(" · err: {e}")),
        Kind::Foreign(ty, _) => ("err", format!(" · foreign err: {ty}")),
        Kind::Panic(p) => ("panic", format!(" · panic: {p}")),
    };
    // 인자는 전부 합성돼야 한다 — 구동이 리터럴을 끼우면 이 수가 시그니처보다 작다.
    if run.args != f.params.len() && !matches!(run.kind, Kind::Panic(_)) {
        fails.push(format!(
            "구동 {}: 합성한 인자 {} ≠ 시그니처 인자 {} {:?} — 인자는 전부 c.a() 로 준다",
            f.label,
            run.args,
            f.params.len(),
            f.params
        ));
    }
    let class = classify(&run.sent, failed);
    Row {
        label: f.label.clone(),
        class,
        reqs: format_reqs(&run.sent, &run.universal),
        root: format!("{:?}", d.root),
        outcome: outcome.into(),
        // 사유는 분류를 못 한 행에만 — 요청을 낸 행의 오류(admin 404 등)는 분류와 무관하다.
        note: if class == UNDETERMINED {
            note
        } else {
            String::new()
        },
        sent: run.sent,
    }
}

// ── W3: 계급별 적대 변형 ─────────────────────────────────────────────────────────────────

/// 토큰 엔드포인트가 내는 형식이 틀린 응답 하나. `from` 이 비면 **측정만** 한다(단언하지 않는다).
struct TokVariant {
    code: String,
    from: String,
    canaries: Vec<(&'static str, String)>,
    resp: Resp,
}

const AT_REFRESH_CANARY: &str = "AT-VARIANT-REFRESH-CANARY-7M3Q";
const AT_ANCHOR: (&str, &str) = (
    "src/token_provider.rs",
    "non_string_access_token_is_rejected",
);
/// `AT_ANCHOR` 의 `for bad in [ … ]` 가 도는 값 — 그 시험의 원문과 대조한다(베낀 값이 썩지 않게).
const AT_CASES: &[(&str, &str)] = &[
    ("at:12345", "12345"),
    ("at:null", "null"),
    ("at:object", r#"{"a": 1}"#),
    ("at:empty", r#""""#),
];

fn at_resp(access_token: Option<&str>) -> Resp {
    let mut body =
        json!({"token_type": "Bearer", "expires_in": 300, "refresh_token": AT_REFRESH_CANARY});
    if let Some(raw) = access_token {
        body["access_token"] = serde_json::from_str(raw).expect("AT_CASES 는 JSON 이다");
    }
    Resp::json(body)
}

/// 변형 집합 — 새로 만들지 않고 기존 시험에서 가져온다.
///   - `hostile_variants`(#623): `EXPECTED` 가 **토큰 열 전부**에서 실패로 단언한 것은 단언, 나머지는 측정.
///   - `src/token_provider.rs` 의 비문자열 access_token 넷 — 1c 축(「비어 있지 않은 문자열이 아니면
///     TokenSet 을 만들지 않는다」)의 rust 앵커라 단언한다.
///   - `at:missing` — 어느 기존 시험도 **그 모양**을 단언하지 않는다(f1 이 키 없는 본문으로 덮기는 한다). 측정만.
fn token_variants(base: &str, fails: &mut Vec<String>) -> Vec<TokVariant> {
    let token_cols: Vec<usize> = (0..CALLS.len())
        .filter(|i| !NON_TOKEN_CALLS.contains(&CALLS[*i]))
        .collect();
    if token_cols.len() + NON_TOKEN_CALLS.len() != CALLS.len() {
        fails.push("W3a NON_TOKEN_CALLS 가 CALLS 에 없는 이름을 담는다".into());
    }
    let mut out = Vec::new();
    for v in variants(base) {
        let code = v.realm.split('-').next().unwrap_or(v.realm).to_string();
        let asserted = match EXPECTED.iter().find(|(r, _)| *r == v.realm) {
            Some((_, row)) => token_cols.iter().all(|i| row[*i] != "ok"),
            None => {
                fails.push(format!("W3a 변형 {} 이 EXPECTED 에 없다", v.realm));
                false
            }
        };
        out.push(TokVariant {
            code,
            from: if asserted {
                format!("tests/hostile_token_response.rs EXPECTED {}", v.realm)
            } else {
                String::new()
            },
            canaries: v.canaries.clone(),
            resp: Resp {
                status: v.status,
                content_type: v.content_type.clone(),
                body: v.body.clone(),
            },
        });
    }
    // 베낀 값이 그 시험의 원문과 같은가 — 늘거나 바뀌면 여기가 운다.
    let src = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(AT_ANCHOR.0))
        .expect("token_provider.rs");
    let region = fn_body(&src, AT_ANCHOR.1).and_then(|b| {
        let start = b.text.find("for bad in [")?;
        let end = b.text[start..].find("] {")? + start;
        Some(b.text[start..end].to_string())
    });
    match region {
        None => fails.push(format!(
            "W3a {}|{} 에서 `for bad in [ … ]` 를 못 읽었다 — 앵커가 옮겨졌으면 AT_CASES 를 따라 고쳐라",
            AT_ANCHOR.0, AT_ANCHOR.1
        )),
        Some(r) => {
            let n = r.matches("json!(").count();
            if n != AT_CASES.len() {
                fails.push(format!(
                    "W3a {} 의 값 {n} 개 ≠ AT_CASES {} 개 — 표를 따라 고쳐라",
                    AT_ANCHOR.1,
                    AT_CASES.len()
                ));
            }
            for (code, lit) in AT_CASES {
                if !r.contains(&format!("json!({lit})")) {
                    fails.push(format!(
                        "W3a {code}: {} 에 json!({lit}) 가 없다 — 베낀 값이 낡았다",
                        AT_ANCHOR.1
                    ));
                }
            }
        }
    }
    for (code, lit) in AT_CASES {
        out.push(TokVariant {
            code: code.to_string(),
            from: format!("{}|{}", AT_ANCHOR.0, AT_ANCHOR.1),
            canaries: vec![("AT_RT", AT_REFRESH_CANARY.into())],
            resp: at_resp(Some(lit)),
        });
    }
    out.push(TokVariant {
        code: "at:missing".into(),
        from: String::new(),
        canaries: vec![("AT_RT", AT_REFRESH_CANARY.into())],
        resp: at_resp(None),
    });
    out
}

/// W3a 대조 — 변형들과 같은 모양(id_token 없음)의 쓸 수 있는 토큰 응답이다.
fn well_formed() -> Resp {
    Resp::json(json!({"access_token": "hp-access", "token_type": "Bearer",
        "expires_in": 300, "refresh_token": "hp-refresh"}))
}

/// 토큰 엔드포인트 요청 수와, 첫 토큰 요청 **뒤에** 나간 토큰 아닌 요청.
fn after_token(reqs: &[Req]) -> (usize, Vec<Req>) {
    let mut hits = 0;
    let mut after = Vec::new();
    for r in reqs {
        if is_token_post(r) {
            hits += 1;
        } else if hits > 0 {
            after.push(r.clone());
        }
    }
    (hits, after)
}

/// 오류의 카나리아 — 네 경로(`{}`·`{:?}`·`{:#?}`·`source()` 사슬) 어디든 찍히면 사유다.
fn canary_why(kind: &Kind, canaries: &[(&'static str, String)]) -> Vec<String> {
    let outs: Vec<(&'static str, String)> = match kind {
        Kind::Sdk(e) => renders(e).to_vec(),
        Kind::Foreign(_, r) => r.clone(),
        _ => Vec::new(),
    };
    let windows = unique_windows(canaries);
    let mut why = Vec::new();
    for (how, out) in outs {
        for (name, level) in hits(&out, canaries, &windows) {
            why.push(format!("카나리아 {name} 가 {how} 에 찍혔다({level})"));
        }
    }
    why
}

/// 적대 토큰 응답 한 칸의 실패 사유 — 비면 통과. `ctl_hits` 는 같은 행의 대조가 낸 토큰 요청 수다.
fn hostile_why(run: &Run, canaries: &[(&'static str, String)], ctl_hits: usize) -> Vec<String> {
    let mut why = Vec::new();
    match &run.kind {
        Kind::Panic(p) => why.push(format!("패닉: {p}")),
        Kind::Ok => why.push("오류 없이 성공했다".into()),
        Kind::Foreign(ty, _) => why.push(format!("SDK 오류 타입이 아니다: {ty}")),
        Kind::Sdk(_) => {}
    }
    why.extend(canary_why(&run.kind, canaries));
    let (hits, after) = after_token(&run.sent);
    if hits == 0 {
        why.push(format!(
            "토큰 엔드포인트에 한 번도 안 닿았다 — 변형이 공허하다({})",
            kind_text(&run.kind)
        ));
    }
    // 하한만 두면 틀린 응답마다 재시도하는 새 fn 이 통과한다(go 레그 지목). 상한은 손 상수가 아니라 같은 행의 대조다.
    if hits > ctl_hits {
        why.push(format!(
            "토큰 요청 {hits} 건 — 정상 응답 대조({ctl_hits} 건)보다 많다: 틀린 응답이 재시도를 부른다"
        ));
    }
    if !after.is_empty() {
        why.push(format!(
            "적대 토큰 응답 뒤로 나아갔다: {}",
            format_reqs(&after, "")
        ));
    }
    why
}

/// 판정표의 한 칸. `why` 가 비면 통과, `measure` 면 단언하지 않고 결과만 찍는다.
struct Slot {
    axis: &'static str,
    label: String,
    variant: String,
    why: Vec<String>,
    measure: bool,
    note: String,
}

impl Slot {
    fn key(&self) -> String {
        format!("W3{} {}/{}", self.axis, self.label, self.variant)
    }
}

/// `kind_name` 과 SDK 오류의 `Display` — 실패 사유에 원인을 남긴다(연결 실패와 판정 실패를 가른다).
fn kind_text(k: &Kind) -> String {
    match k {
        Kind::Sdk(e) => format!("{}: {e}", kind_name(k)),
        Kind::Panic(p) => format!("panic: {p}"),
        _ => kind_name(k),
    }
}

fn kind_name(k: &Kind) -> String {
    match k {
        Kind::Ok => "ok".into(),
        Kind::Sdk(e) => {
            let d = format!("{e:?}");
            d.split(|c: char| !c.is_alphanumeric())
                .next()
                .unwrap_or("")
                .to_string()
        }
        Kind::Foreign(ty, _) => format!("foreign {ty}"),
        Kind::Panic(_) => "panic".into(),
    }
}

async fn run_variants_a(
    keys: &Keys,
    decl: &BTreeMap<String, FnDecl>,
    drv: &BTreeMap<&str, &Driver>,
    labels: &[String],
    variants: &[TokVariant],
) -> Vec<Slot> {
    let mut slots = Vec::new();
    for label in labels {
        let (f, d) = (&decl[label], drv[label.as_str()]);
        let blank = nonce_params(f);
        // 대조 — 변형과 **같은 모양의** 정상 응답(id_token 없음). 이 행에서 무엇이 적대 변형을 가르는지 정한다:
        // 성공하면 「오류다」가, 토큰 뒤로 나아가면(admin 자원 → 404) 「뒤로 안 나아갔다」가 무게를 진다.
        // 둘 다 아니면 행 전체가 공허하다.
        let ctl = cell(keys, f, d, blank.clone(), |_| Some(well_formed())).await;
        let (ctl_hits, ctl_after) = after_token(&ctl.sent);
        let mut c = Slot {
            axis: "a",
            label: label.clone(),
            variant: "대조".into(),
            why: Vec::new(),
            measure: false,
            note: match ctl.kind {
                Kind::Ok => "ok".into(),
                _ => format!("↓{}", ctl_after.len()),
            },
        };
        match &ctl.kind {
            Kind::Panic(p) => c.why.push(format!("정상 응답에 패닉: {p}")),
            k if ctl_hits == 0 => c.why.push(format!(
                "정상 응답에서 토큰 엔드포인트에 안 닿았다({}) — 이 행의 변형은 공허하다",
                kind_text(k)
            )),
            Kind::Ok => {}
            k if ctl_after.is_empty() => c.why.push(format!(
                "정상 응답에 실패했고({}) 토큰 뒤로 나아가지도 않았다 — 변형이 무엇을 바꿨는지 가를 수 없다",
                kind_text(k)
            )),
            _ => {}
        }
        slots.push(c);
        for v in variants {
            let run = cell(keys, f, d, blank.clone(), |_| Some(v.resp.clone())).await;
            let mut s = Slot {
                axis: "a",
                label: label.clone(),
                variant: v.code.clone(),
                why: hostile_why(&run, &v.canaries, ctl_hits),
                measure: v.from.is_empty(),
                note: String::new(),
            };
            if s.measure {
                s.note = kind_name(&run.kind);
            }
            slots.push(s);
        }
    }
    slots
}

/// W3b 의 변형 — 대조(맞는 id_token)와 다섯. 다른 키로 서명할 때 kid 가 k1 이면 캐시된 키로 서명 검증이
/// 실패하고, k2 면 키를 못 찾는다. 「id_token 없음」·「nonce 클레임 없음」·「nonce 다름」은
/// `src/auth.rs` 의 `exchange_code_rejects_*` 가 단언하는 계약이고, 다른 키는 `tests/forged_id_token.rs` 의 것이다.
struct NonceVariant {
    code: &'static str,
    kid: &'static str,
    other_key: bool,
    /// `None` 이면 `{"nonce": 보편 인자(= 호출에 넘긴 nonce)}`.
    claims: Option<Value>,
    no_id_token: bool,
    want_ok: bool,
}

fn nonce_variants() -> Vec<NonceVariant> {
    let nv = |code, kid, other_key, claims, no_id_token, want_ok| NonceVariant {
        code,
        kid,
        other_key,
        claims,
        no_id_token,
        want_ok,
    };
    vec![
        nv("대조", "k1", false, None, false, true),
        nv(
            "nonce≠",
            "k1",
            false,
            Some(json!({"nonce": "hp-other-nonce"})),
            false,
            false,
        ),
        nv("key≠·kid=k1", "k1", true, None, false, false),
        nv("key≠·kid=k2", "k2", true, None, false, false),
        nv("id_token없음", "k1", false, None, true, false),
        nv(
            "nonce클레임없음",
            "k1",
            false,
            Some(json!({})),
            false,
            false,
        ),
    ]
}

async fn run_nonce_b(
    keys: &Keys,
    decl: &BTreeMap<String, FnDecl>,
    drv: &BTreeMap<&str, &Driver>,
    labels: &[String],
) -> Vec<Slot> {
    let mut slots = Vec::new();
    for label in labels {
        let (f, d) = (&decl[label], drv[label.as_str()]);
        for nv in nonce_variants() {
            let run = cell(keys, f, d, BTreeSet::new(), |idp: &Idp| {
                let mut body = json!({"access_token": "hp-access", "token_type": "Bearer",
                    "expires_in": 300, "refresh_token": "hp-refresh"});
                if !nv.no_id_token {
                    let signer = if nv.other_key {
                        &keys.other
                    } else {
                        &keys.main
                    };
                    let claims = nv
                        .claims
                        .clone()
                        .unwrap_or_else(|| json!({"nonce": idp.universal}));
                    body["id_token"] = json!(sign(signer, nv.kid, &idp.iss, claims));
                }
                Some(Resp::json(body))
            })
            .await;
            let certs = run.sent.iter().filter(|r| is_certs_get(r)).count();
            let mut s = Slot {
                axis: "b",
                label: label.clone(),
                variant: nv.code.into(),
                why: Vec::new(),
                measure: false,
                note: format!("certs {certs}"),
            };
            if let Kind::Panic(p) = &run.kind {
                s.why.push(format!("패닉: {p}"));
            }
            if !run.sent.iter().any(is_token_post) {
                s.why.push(format!(
                    "토큰 엔드포인트에 안 닿았다({}) — 변형이 공허하다",
                    kind_text(&run.kind)
                ));
            }
            // id_token 이 있는 변형은 검증기에 닿아야 한다(콜드 캐시라 JWKS 를 조회한다) — 아니면 다른 이유로 실패했다.
            if certs == 0 && !nv.no_id_token {
                s.why
                    .push("JWKS 를 조회하지 않았다 — id_token 이 검증기에 닿지 않았다".into());
            }
            match (&run.kind, nv.want_ok) {
                (Kind::Ok, true) | (Kind::Sdk(_), false) | (Kind::Panic(_), _) => {}
                (k, true) => s.why.push(format!(
                    "맞는 id_token 에 실패했다({}) — 아래 변형의 실패가 아무것도 증명하지 않는다",
                    kind_text(k)
                )),
                (Kind::Ok, false) => s.why.push("틀린 id_token 을 받아들였다".into()),
                (Kind::Foreign(ty, _), false) => {
                    s.why.push(format!("SDK 오류 타입이 아니다: {ty}"))
                }
            }
            slots.push(s);
        }
    }
    slots
}

/// W3c 의 다섯 호출 동안 백오프 게이트의 시계(`tokio::time::Instant`, `src/jwks.rs`)를 얼린다.
///
/// ⚠️ **떼지 말 것 — 실시간 시계에서는 상한 4 가 러너 속도를 잰다.** 백오프 창은 0.1–0.2·0.2–0.4·0.4–0.8·
/// 0.8–1.6초로 늘어서, 호출 사이마다 그보다 긴 정지가 끼면 다섯 호출이 전부 나간다(실측: 호출마다 1.7초를
/// 재우면 다섯 행 전부 `certs 5`). 얼린 시계에서는 실패 기록과 다음 백오프 검사 사이의 경과가 0 이다 — 그래서
/// 이 축은 창의 **크기**를 못 잰다(창이 0 보다 크기만 하면 통과). 크기는 `src/jwks.rs` 의
/// `backoff_window_holds_its_minimum_and_doubles` 가 결정적으로 잰다.
///
/// ⚠️ **`pause()` 만으로는 안 된다 — 막힌 작업이 함께 살아 있어야 한다.** 멈춘 시계는 런타임이 할 일 없이
/// park 할 때 다음 타이머까지 **자동 전진**한다. 실측(막힌 작업 없이 `pause()` 만): 교환 두 행은 매 호출의
/// 토큰 POST 가 `KeycloakClient` 뿌리의 30초 타임아웃에 터져 JWKS 에 한 번도 닿지 못했고(`certs 0`, 게이트
/// 시계 150초 이동), `AuthClient::validate` 행은 시계가 30초 뛰었다 — 그때 칸을 가르는 것은 백오프가 아니라
/// 타임아웃이다. `spawn_blocking` 작업이 살아 있는 동안 current_thread 런타임은 자동 전진하지 않는다(tokio
/// 1.53.1 `runtime/blocking/schedule.rs` 의 `inhibit_auto_advance` — `time::pause` 문서의 「Preventing
/// auto-advance」). 그래서 시계는 정확히 멈추고, I/O 는 실시간으로 기다린다.
///
/// 막힌 작업은 센더를 놓을 때(`finish` · 패닉 중의 `Drop`) 끝난다. 실시간 상한은 일부러 두지 않는다 — 두면
/// 그것이 다시 벽시계 판정이 된다. IdP 가 영영 답하지 않으면 이 다섯 호출은 기다린다(타임아웃 없는
/// `reqwest::Client::new()` 를 쓰는 두 행은 동결 전에도 그랬다).
struct GateClockFreeze {
    at: tokio::time::Instant,
    release: Option<std::sync::mpsc::Sender<()>>,
}

impl GateClockFreeze {
    fn start() -> Self {
        let (release, held) = std::sync::mpsc::channel::<()>();
        // 자동 전진 금지는 spawn 시점에 걸린다(`BlockingSchedule::new`) — 클로저가 돌기를 기다릴 필요가 없다.
        tokio::task::spawn_blocking(move || held.recv());
        tokio::time::pause();
        GateClockFreeze {
            at: tokio::time::Instant::now(),
            release: Some(release),
        }
    }

    /// 얼린 동안 게이트 시계가 움직인 양. 0 이 아니면 동결이 깨진 것이다(자동 전진 · `pause` 누락).
    fn finish(mut self) -> Duration {
        let drift = self.at.elapsed();
        self.thaw();
        drift
    }

    fn thaw(&mut self) {
        if let Some(release) = self.release.take() {
            tokio::time::resume();
            drop(release); // 막힌 작업이 곧 끝나 자동 전진 금지가 풀린다
        }
    }
}

impl Drop for GateClockFreeze {
    fn drop(&mut self) {
        self.thaw();
    }
}

async fn run_cold_jwks_c(
    keys: &Keys,
    decl: &BTreeMap<String, FnDecl>,
    drv: &BTreeMap<&str, &Driver>,
    labels: &[String],
) -> Vec<Slot> {
    let mut slots = Vec::new();
    for label in labels {
        let (f, d) = (&decl[label], drv[label.as_str()]);
        let idp = Idp::start(keys).await;
        let ctx = Ctx::new(&idp, &f.params, BTreeSet::new());
        let root = Arc::new(build_root(d.root, &ctx).await); // 새 뿌리 — 캐시가 비어 있다
        let mark = idp.requests().await.len();
        idp.set_certs_down(true);
        let mut s = Slot {
            axis: "c",
            label: label.clone(),
            variant: format!("503×{COLD_K}"),
            why: Vec::new(),
            measure: false,
            note: String::new(),
        };
        let freeze = GateClockFreeze::start();
        for i in 1..=COLD_K {
            match run_once(d, &ctx, &root).await.0 {
                Kind::Panic(p) => s.why.push(format!("{i}번째 호출이 패닉: {p}")),
                Kind::Ok => s.why.push(format!("{i}번째 호출이 JWKS 503 인데 성공했다")),
                Kind::Foreign(ty, _) => s.why.push(format!(
                    "{i}번째 호출의 오류가 SDK 오류 타입이 아니다: {ty}"
                )),
                Kind::Sdk(_) => {}
            }
        }
        let drift = freeze.finish();
        if !drift.is_zero() {
            s.why.push(format!(
                "다섯 호출 동안 게이트 시계가 {drift:?} 움직였다 — 동결이 깨지면 상한이 요청 수가 아니라 시간을 잰다"
            ));
        }
        let sent = idp.requests().await;
        let hits = sent[mark.min(sent.len())..]
            .iter()
            .filter(|r| is_certs_get(r))
            .count();
        s.note = format!("certs {hits}");
        if hits < 1 {
            s.why.push(format!(
                "/certs 요청 {hits} — 콜드 경로에 닿지 않았다(하한 1)"
            ));
        }
        if hits > COLD_K - 1 {
            s.why.push(format!(
                "/certs 요청 {hits} — 실패한 조회가 물러서지 않았다(상한 {})",
                COLD_K - 1
            ));
        }
        slots.push(s);
    }
    slots
}

/// 칸마다 통과·GAP·FAIL 을 정하고 판정표를 찍는다. 실패 사유는 표 **뒤에** 모은다.
fn judge(slots: &[Slot], report: &mut Vec<String>, fails: &mut Vec<String>) -> Vec<String> {
    let gaps: BTreeMap<&str, &str> = KNOWN_GAPS.iter().copied().collect();
    let mut verdict: BTreeMap<String, String> = BTreeMap::new();
    let mut observed = BTreeSet::new();
    for s in slots {
        let mut v = if s.measure {
            (if s.why.is_empty() { "m:rej" } else { "m:ACC" }).to_string()
        } else if s.why.is_empty() {
            "pass".into()
        } else if gaps.contains_key(s.key().as_str()) {
            observed.insert(s.key());
            "GAP".into()
        } else {
            fails.push(format!("{}: {}", s.key(), s.why.join(" · ")));
            "FAIL".into()
        };
        if !s.note.is_empty() && (s.axis != "a" || s.variant == "대조") {
            v += &format!("({})", s.note);
        }
        verdict.insert(s.key(), v);
    }
    for axis in ["a", "b", "c"] {
        log_verdicts(axis, slots, &verdict, report);
    }
    // 측정 칸은 변형마다 한 줄로 모은다 — 받아들인 행은 수와 앞 셋만 적는다.
    let mut measured: BTreeMap<String, (Vec<String>, Vec<String>)> = BTreeMap::new();
    let mut order = Vec::new();
    for s in slots.iter().filter(|s| s.measure) {
        let k = format!("W3{} {}", s.axis, s.variant);
        if !measured.contains_key(&k) {
            order.push(k.clone());
        }
        let e = measured.entry(k).or_default();
        if s.why.is_empty() {
            e.0.push(s.note.clone());
        } else {
            e.1.push(format!("{}({})", s.label, s.why.join(" · ")));
        }
    }
    for k in &order {
        let (rej, acc) = &measured[k];
        let kinds: BTreeSet<&String> = rej.iter().collect();
        let shown: Vec<&String> = acc.iter().take(3).collect();
        report.push(format!(
            "측정(단언 안 함) {k} — 거부 {} · 받아들임 {} · 거부 오류 {kinds:?} · 받아들인 행(앞 셋) {shown:?}",
            rej.len(),
            acc.len()
        ));
    }
    for (key, reason) in KNOWN_GAPS {
        if !observed.contains(*key) {
            fails.push(format!(
                "KNOWN_GAPS[{key}]: 더는 관측되지 않는다 — 낡은 항목을 지워라({reason})"
            ));
        }
    }
    let mut summary = Vec::new();
    for axis in ["a", "b", "c"] {
        let mut n: BTreeMap<&str, usize> = BTreeMap::new();
        let mut failed_by: Vec<(String, usize)> = Vec::new();
        for s in slots.iter().filter(|s| s.axis == axis) {
            let v = verdict[&s.key()]
                .split('(')
                .next()
                .unwrap_or("")
                .to_string();
            let key = match v.as_str() {
                "pass" => "pass",
                "GAP" => "GAP",
                "FAIL" => "FAIL",
                "m:rej" => "m:rej",
                _ => "m:ACC",
            };
            *n.entry(key).or_default() += 1;
            if key == "FAIL" {
                match failed_by.iter_mut().find(|(c, _)| *c == s.variant) {
                    Some((_, k)) => *k += 1,
                    None => failed_by.push((s.variant.clone(), 1)),
                }
            }
        }
        let g = |k: &str| n.get(k).copied().unwrap_or(0);
        let fv: Vec<String> = failed_by.iter().map(|(v, k)| format!("{v}×{k}")).collect();
        summary.push(format!(
            "W3{axis} 요약: pass {} · GAP {} · FAIL {} · 측정 {}(m:rej {} · m:ACC {}) · FAIL 열 {fv:?}",
            g("pass"),
            g("GAP"),
            g("FAIL"),
            g("m:rej") + g("m:ACC"),
            g("m:rej"),
            g("m:ACC")
        ));
    }
    summary
}

/// 한 축의 판정표 — 행은 fn, 열은 변형.
fn log_verdicts(
    axis: &str,
    slots: &[Slot],
    verdict: &BTreeMap<String, String>,
    report: &mut Vec<String>,
) {
    let mut labels: Vec<&str> = Vec::new();
    let mut cols: Vec<&str> = Vec::new();
    for s in slots.iter().filter(|s| s.axis == axis) {
        if !labels.contains(&s.label.as_str()) {
            labels.push(&s.label);
        }
        if !cols.contains(&s.variant.as_str()) {
            cols.push(&s.variant);
        }
    }
    if labels.is_empty() {
        report.push(format!("W3{axis} 판정표: 대상 행이 없다"));
        return;
    }
    let cell_of = |l: &str, col: &str| -> String {
        verdict
            .get(&format!("W3{axis} {l}/{col}"))
            .cloned()
            .unwrap_or_default()
    };
    let width: Vec<usize> = cols
        .iter()
        .map(|c| {
            labels
                .iter()
                .map(|l| cell_of(l, c).chars().count())
                .chain([c.chars().count()])
                .max()
                .unwrap_or(0)
        })
        .collect();
    let first = labels.iter().map(|l| l.chars().count()).max().unwrap_or(0);
    let pad = |s: &str, n: usize| format!("{s}{}", " ".repeat(n.saturating_sub(s.chars().count())));
    let line = |head: &str, vals: Vec<String>| {
        let mut parts = vec![pad(head, first)];
        parts.extend(vals.iter().zip(&width).map(|(v, w)| pad(v, *w)));
        parts.join(" ").trim_end().to_string()
    };
    report.push(format!(
        "W3{axis} 판정표 — {}행 × {}열 (pass · GAP=알려진 틈 · FAIL · m:rej/m:ACC=측정만: 거부/받아들임)",
        labels.len(),
        cols.len()
    ));
    report.push(line(
        "행 \\ 변형",
        cols.iter().map(|c| c.to_string()).collect(),
    ));
    for l in &labels {
        report.push(line(l, cols.iter().map(|c| cell_of(l, c)).collect()));
    }
}

// ── W1: 손 목록 포함 ─────────────────────────────────────────────────────────────────────

/// 손으로 고른 rust 시험이 겨누는 fn — 파생 집합이 이것 밑으로 **조용히** 줄지 않게 한다.
/// `anchor` 는 그 손 시험(`rust/` 기준 파일|fn 이름), `call` 은 그 fn 이 실제로 부르는 이름이다. `call` 이 라벨의
/// 메서드 이름과 다르면 라벨의 소스가 그것을 부르는지 대조한다(한 단계). `axis`: a·b·c = 그 W3 축의 파생
/// 대상에 있어야 한다 · row = 행이고 계급이 맞기만 하면 된다(교환 계급 밖).
struct Hand {
    label: &'static str,
    class: &'static str,
    axis: &'static str,
    anchor: &'static str,
    call: &'static str,
}

const fn h(
    label: &'static str,
    class: &'static str,
    axis: &'static str,
    anchor: &'static str,
    call: &'static str,
) -> Hand {
    Hand {
        label,
        class,
        axis,
        anchor,
        call,
    }
}

/// `hostile_token_response.rs` 의 호출 구동 — go 의 `causeRun` 자리다. 부르는 SDK 이름이 전부 표에 있어야 한다.
const DRIVE: &str = "tests/hostile_token_response.rs|drive";

const HAND: &[Hand] = &[
    h(
        "AuthClient::client_credentials_token",
        TOKEN_GRANT,
        "a",
        DRIVE,
        "client_credentials_token",
    ),
    h("AuthClient::refresh", TOKEN_GRANT, "a", DRIVE, "refresh"),
    h(
        "AuthClient::exchange_code",
        CODE_EXCHANGE,
        "a",
        DRIVE,
        "exchange_code",
    ),
    h(
        "AuthClient::exchange_code_with_redirect",
        CODE_EXCHANGE,
        "a",
        DRIVE,
        "exchange_code_with_redirect",
    ),
    h("AuthClient::introspect", OTHER, "row", DRIVE, "introspect"),
    h(
        "<AuthClient as TokenProvider>::access_token",
        TOKEN_GRANT,
        "a",
        DRIVE,
        "access_token",
    ),
    h(
        "<ClientCredentialsTokenProvider as TokenProvider>::access_token",
        TOKEN_GRANT,
        "a",
        DRIVE,
        "access_token",
    ),
    h("AdminClient::get_user", TOKEN_GRANT, "a", DRIVE, "get_user"),
    h("KeycloakClient::auth", NONE, "row", DRIVE, "auth"),
    h("KeycloakClient::admin", NONE, "row", DRIVE, "admin"),
    // 보안 기본값 가드(scripts/test/test-security-defaults.sh)의 rust 행위 앵커 — nonce · 토큰 타입 · 백오프.
    h(
        "AuthClient::exchange_code",
        CODE_EXCHANGE,
        "b",
        "src/auth.rs|exchange_code_rejects_mismatched_nonce_end_to_end",
        "exchange_code",
    ),
    h(
        "AuthClient::exchange_code",
        CODE_EXCHANGE,
        "b",
        "src/auth.rs|exchange_code_rejects_missing_id_token_when_nonce_expected",
        "exchange_code",
    ),
    h(
        "AuthClient::exchange_code",
        CODE_EXCHANGE,
        "b",
        "src/auth.rs|exchange_code_rejects_id_token_without_nonce_claim",
        "exchange_code",
    ),
    h(
        "<ClientCredentialsTokenProvider as TokenProvider>::access_token",
        TOKEN_GRANT,
        "a",
        "src/token_provider.rs|non_string_access_token_is_rejected",
        "access_token",
    ),
    h(
        "JwksStore::get_key",
        JWKS_FETCH,
        "c",
        "src/jwks.rs|failing_idp_bounds_cold_retries_to_one_request",
        "get_key",
    ),
    h(
        "JwksStore::get_key",
        JWKS_FETCH,
        "c",
        "src/jwks.rs|backoff_expires_and_allows_a_retry",
        "get_key",
    ),
    h(
        "JwksStore::get_key",
        JWKS_FETCH,
        "c",
        "src/jwks.rs|success_resets_the_failure_counter",
        "get_key",
    ),
    // 가드 밖의 손 시험 — 빈 access_token 을 refresh 에(형식 틀린 토큰 응답), 위조 서명 id_token 을 공개 교환 둘에.
    h(
        "AuthClient::refresh",
        TOKEN_GRANT,
        "a",
        "src/auth.rs|refresh_rejects_empty_access_token",
        "refresh",
    ),
    h(
        "AuthClient::exchange_code",
        CODE_EXCHANGE,
        "b",
        "tests/forged_id_token.rs|exchange_both_ways",
        "exchange_code",
    ),
    h(
        "AuthClient::exchange_code_with_redirect",
        CODE_EXCHANGE,
        "b",
        "tests/forged_id_token.rs|exchange_both_ways",
        "exchange_code_with_redirect",
    ),
];

/// 보안 기본값 가드가 rust 행위 앵커를 적는 모양 `rust/<파일>.rs|(async )fn <이름>(` 을 전부 읽는다.
fn script_anchors(script: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in script.lines() {
        let mut rest = line;
        while let Some(i) = rest.find("rust/") {
            let tail = &rest[i + "rust/".len()..];
            rest = tail;
            let Some((file, decl)) = tail.split_once('|') else {
                continue;
            };
            if !file.ends_with(".rs") || file.contains(['\'', ' ']) {
                continue;
            }
            let decl = decl.split('\'').next().unwrap_or("");
            let name = decl
                .strip_prefix("async fn ")
                .or_else(|| decl.strip_prefix("fn "))
                .and_then(|d| d.strip_suffix('('));
            if let Some(name) = name.filter(|n| n.chars().all(|c| c == '_' || c.is_alphanumeric()))
            {
                out.push(format!("{file}|{name}"));
            }
        }
    }
    out
}

fn method_name(label: &str) -> &str {
    label.rsplit("::").next().unwrap_or(label)
}

fn check_hand(
    sc: &Scan,
    decl: &BTreeMap<String, FnDecl>,
    rows: &BTreeMap<String, Row>,
    tgt: &BTreeMap<&str, Vec<String>>,
    report: &mut Vec<String>,
) -> Vec<String> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut why = Vec::new();
    let mut anchors = BTreeSet::new();
    let mut drive_calls = BTreeSet::new();
    for h in HAND {
        anchors.insert(h.anchor);
        if h.anchor == DRIVE {
            drive_calls.insert(h.call);
        }
        match rows.get(h.label) {
            None => why.push(format!(
                "W1 {}: 손 시험({})이 겨누는데 파생 집합에 행이 없다",
                h.label, h.anchor
            )),
            Some(r) if r.class != h.class => why.push(format!(
                "W1 {}: 손 시험({})이 겨누는 계급은 {} 인데 파생은 {} 다",
                h.label, h.anchor, h.class, r.class
            )),
            Some(_)
                if h.axis != "row"
                    && !tgt
                        .get(h.axis)
                        .is_some_and(|t| t.iter().any(|l| l == h.label)) =>
            {
                why.push(format!(
                    "W1 {}: 손 시험({})이 겨누는데 W3{} 의 파생 대상에 없다",
                    h.label, h.anchor, h.axis
                ))
            }
            Some(_) => {}
        }
        let (file, name) = h.anchor.split_once('|').expect("anchor");
        let body = std::fs::read_to_string(root.join(file))
            .ok()
            .and_then(|src| fn_body(&src, name));
        let Some(body) = body else {
            why.push(format!(
                "W1 {}: 앵커 함수가 없다 — 손 시험이 옮겨졌으면 표를 따라 고쳐라",
                h.anchor
            ));
            continue;
        };
        if !body.calls.contains(h.call) {
            why.push(format!(
                "W1 {}: 앵커가 {}( 를 부르지 않는다 — 손 시험의 대상이 바뀌었다",
                h.anchor, h.call
            ));
        }
        if method_name(h.label) != h.call
            && !decl.get(h.label).is_some_and(|f| f.calls.contains(h.call))
        {
            why.push(format!(
                "W1 {}: 공개 입구가 {} 를 부르지 않는다 — 앵커({})의 대상과 이어지지 않는다",
                h.label, h.call, h.anchor
            ));
        }
    }
    // drive 가 부르는 SDK 이름은 전부 표에 있다 — 손 시험에 대상이 늘면 여기가 먼저 운다.
    // SDK 이름 = 메서드 호출(`.x(`) 중 선언 집합의 이름 + SDK 트레이트의 정식 호출(`Tr::x(`).
    // ⚠️ 타입 경로 호출(`KeycloakClient::new(`)은 수신자를 만드는 것이지 겨누는 것이 아니다.
    let names: BTreeSet<&str> = decl.values().map(|f| f.name.as_str()).collect();
    let (file, name) = DRIVE.split_once('|').expect("DRIVE");
    let mut n_drive = 0;
    if let Some(body) = std::fs::read_to_string(root.join(file))
        .ok()
        .and_then(|src| fn_body(&src, name))
    {
        let traits: BTreeSet<&str> = sc.traits.keys().map(String::as_str).collect();
        let called: BTreeSet<&str> = body
            .dot_calls
            .iter()
            .map(String::as_str)
            .filter(|n| names.contains(n))
            .chain(
                body.path_calls
                    .iter()
                    .filter(|(seg, _)| traits.contains(seg.as_str()))
                    .map(|(_, n)| n.as_str()),
            )
            .collect();
        for n in &called {
            n_drive += 1;
            if !drive_calls.contains(n) {
                why.push(format!("W1 drive 가 {n} 를 부르는데 HAND 에 없다"));
            }
        }
    }
    if n_drive == 0 {
        why.push("W1 drive 에서 SDK 호출을 하나도 못 읽었다 — 대조가 공허하다".into());
    }
    // 보안 기본값 가드의 rust 행위 앵커는 전부 표의 앵커다 — 그 가드에 rust 앵커가 늘면 여기가 운다.
    let script_path = root.join("../scripts/test/test-security-defaults.sh");
    match std::fs::read_to_string(&script_path) {
        Ok(script) => {
            let found = script_anchors(&script);
            report.push(format!(
                "W1 손 목록 {} 항목 · 앵커 {} — drive 의 SDK 호출 {n_drive} · 보안 기본값 가드의 rust 행위 앵커 {} 와 대조",
                HAND.len(),
                anchors.len(),
                found.len()
            ));
            if found.is_empty() {
                why.push(
                    "W1 test-security-defaults.sh 에서 rust 행위 앵커를 하나도 못 읽었다 — 적는 모양이 바뀌었나?"
                        .into(),
                );
            }
            for a in found {
                if !anchors.contains(a.as_str()) {
                    why.push(format!(
                        "W1 보안 기본값 가드의 rust 앵커 {a} 가 HAND 에 없다"
                    ));
                }
            }
        }
        Err(e) if root.join("../.git").exists() => why.push(format!(
            "W1 저장소 체크아웃인데 보안 기본값 가드를 못 읽었다: {e}"
        )),
        Err(_) => report.push("W1: 저장소 밖에서 돌아 보안 기본값 가드 대조는 건너뛴다".into()),
    }
    why
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn hostile_path_matrix() {
    let keys = Keys::new();
    let sc = scan_src();
    let mut fails: Vec<String> = sc
        .unreadable
        .iter()
        .map(|u| format!("판독 불가: {u}"))
        .collect();
    let (decl, excluded) = declared(&sc);
    if decl.len() < 30 {
        fails.push(format!(
            "선언 집합이 {} 뿐이다 — 판독기가 공허해졌다",
            decl.len()
        ));
    }

    // 구동 표 = 선언 집합(양방향).
    let all_drivers = drivers();
    let mut drv: BTreeMap<&str, &Driver> = BTreeMap::new();
    for d in &all_drivers {
        if drv.insert(d.label, d).is_some() {
            fails.push(format!("구동 {}: 같은 라벨이 둘이다", d.label));
        }
        if !decl.contains_key(d.label) {
            fails.push(format!(
                "구동 {}: 선언 집합에 없다 — 낡은 구동이거나 라벨이 스캐너와 다르다",
                d.label
            ));
        }
        if !drives_its_label(d) {
            fails.push(format!(
                "구동 {}: 호출식 `{}` 이 라벨의 fn 을 부르지 않는다 — 다른 fn 의 결과가 이 행을 대신한다",
                d.label, d.src
            ));
        }
    }
    let exempt: BTreeMap<&str, &str> = UNDETERMINED_EXEMPT.iter().copied().collect();

    // 분류.
    let mut report = Vec::new();
    let mut rows: BTreeMap<String, Row> = BTreeMap::new();
    let mut called = 0;
    for (label, f) in &decl {
        let row = match drv.get(label.as_str()) {
            Some(d) => {
                called += 1;
                classify_row(&keys, f, d, &mut fails).await
            }
            None => Row {
                label: label.clone(),
                class: UNDETERMINED,
                reqs: "-".into(),
                root: "없음".into(),
                outcome: "-".into(),
                note: " · 구동이 없다(drivers() 에 한 줄 더하거나 이유와 함께 UNDETERMINED_EXEMPT 에 적어라)"
                    .into(),
                sent: Vec::new(),
            },
        };
        rows.insert(label.clone(), row);
    }
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    report.push(format!(
        "선언 집합 {} fn(구동으로 부른 것 {called} + 구동 없는 것 {}) · 규칙으로 뺀 것 {} {excluded:?} — 경로의 {BASE} 는 생략, {{U}} 는 보편 인자(서명된 JWS)",
        decl.len(),
        decl.len() - called,
        excluded.len()
    ));
    let lw = rows.keys().map(|l| l.chars().count()).max().unwrap_or(0);
    for r in rows.values() {
        *counts.entry(r.class).or_default() += 1;
        report.push(format!(
            "{}{} → {:<13} · {}  [뿌리 {} · {}]{}",
            r.label,
            " ".repeat(lw - r.label.chars().count()),
            r.class,
            r.reqs,
            r.root,
            r.outcome,
            r.note
        ));
    }
    let class_line = [
        CODE_EXCHANGE,
        TOKEN_GRANT,
        JWKS_FETCH,
        OTHER,
        NONE,
        UNDETERMINED,
    ]
    .iter()
    .map(|c| format!("{c} {}", counts.get(c).copied().unwrap_or(0)))
    .collect::<Vec<_>>()
    .join(" · ");
    report.push(format!("계급별: {class_line}"));

    // (1) UNDETERMINED 없음 — 면제는 이유와 함께, 낡은 면제는 실패.
    for r in rows.values() {
        if r.class == UNDETERMINED && !exempt.contains_key(r.label.as_str()) {
            fails.push(format!(
                "{}: 분류하지 못했다(UNDETERMINED){}",
                r.label, r.note
            ));
        }
    }
    for (label, reason) in &exempt {
        if rows.get(*label).is_none_or(|r| r.class != UNDETERMINED) {
            fails.push(format!(
                "{label}: 낡은 면제다 — 선언 집합에 없거나 더는 UNDETERMINED 가 아니다({reason})"
            ));
        }
    }
    // (2) 세 교환 계급이 각각 비어 있지 않다 — 비면 분류기·가짜 IdP·인자 합성 중 하나가 공허해진 것이다.
    for c in [CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH] {
        if counts.get(c).copied().unwrap_or(0) == 0 {
            fails.push(format!("{c} 계급이 비었다 — 교환 경로를 하나도 못 찾았다"));
        }
    }

    // W3 — 대상은 전부 파생이다: (a) 계급 · (b) 계급 ∩ 시그니처 · (c) 분류 실행이 보낸 요청.
    let nonce_exempt: BTreeMap<&str, &str> = NONCE_DROP_EXEMPT.iter().copied().collect();
    let mut tgt: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    let mut late = Vec::new();
    for r in rows.values().filter(|r| drv.contains_key(r.label.as_str())) {
        if r.class == TOKEN_GRANT || r.class == CODE_EXCHANGE {
            tgt.entry("a").or_default().push(r.label.clone());
        }
        let has_nonce = !nonce_params(&decl[&r.label]).is_empty();
        // (b) 대상 = 토큰을 부여받는 행 중 시그니처에 nonce 가 있는 것 — 계급이 CODE_EXCHANGE 가 아니어도
        // 붙인다. 분류가 grant 를 못 읽어 TOKEN_GRANT 로 떨어진 교환(Grok 레그 실측: JSON 본문)도 빠지지 않게.
        if has_nonce && (r.class == TOKEN_GRANT || r.class == CODE_EXCHANGE) {
            tgt.entry("b").or_default().push(r.label.clone());
        }
        if r.class == CODE_EXCHANGE && !has_nonce {
            if let Some(reason) = nonce_exempt.get(r.label.as_str()) {
                report.push(format!(
                    "(b) nonce 파라미터가 없어 빠진 CODE_EXCHANGE 행: {} — {reason}",
                    r.label
                ));
            } else {
                late.push(format!(
                    "W3b {}: CODE_EXCHANGE 인데 이름에 nonce 가 든 파라미터가 없어 W3b 가 붙지 않는다 — nonce 를 그 이름으로 받게 하거나, 정말 nonce 없는 흐름이면 이유와 함께 NONCE_DROP_EXEMPT 에 적어라",
                    r.label
                ));
            }
        }
        if r.sent.iter().any(is_certs_get) {
            tgt.entry("c").or_default().push(r.label.clone());
        }
    }
    for (label, reason) in &nonce_exempt {
        let stale = rows.get(*label).is_none_or(|r| r.class != CODE_EXCHANGE)
            || decl
                .get(*label)
                .is_some_and(|f| !nonce_params(f).is_empty());
        if stale {
            late.push(format!(
                "NONCE_DROP_EXEMPT[{label}]: 낡은 면제다 — nonce 파라미터 없는 CODE_EXCHANGE 행이 아니다({reason})"
            ));
        }
    }
    let empty = Vec::new();
    let variants_a = {
        let probe_idp = Idp::start(&keys).await;
        token_variants(&probe_idp.server.uri(), &mut fails)
    };
    report.push(format!(
        "(a) 토큰응답 형식 변형 {}(측정만 {}) — 기존 시험에서 파생: {:?}",
        variants_a.len(),
        variants_a.iter().filter(|v| v.from.is_empty()).count(),
        variants_a
            .iter()
            .map(|v| format!("{}{}", v.code, if v.from.is_empty() { "(m)" } else { "" }))
            .collect::<Vec<_>>()
    ));
    let b_names: Vec<String> = tgt
        .get("b")
        .unwrap_or(&empty)
        .iter()
        .map(|l| format!("{l}{:?}", nonce_params(&decl[l])))
        .collect();
    report.push(format!(
        "(b) nonce 대상(시그니처에서 파생 — 파라미터 위치): {b_names:?}"
    ));
    report.push(format!(
        "(c) 콜드 캐시 JWKS 대상(분류 실행이 /certs 를 조회한 행): {:?}",
        tgt.get("c").unwrap_or(&empty)
    ));
    let mut slots = run_variants_a(
        &keys,
        &decl,
        &drv,
        tgt.get("a").unwrap_or(&empty),
        &variants_a,
    )
    .await;
    slots.extend(run_nonce_b(&keys, &decl, &drv, tgt.get("b").unwrap_or(&empty)).await);
    slots.extend(run_cold_jwks_c(&keys, &decl, &drv, tgt.get("c").unwrap_or(&empty)).await);
    let summary = judge(&slots, &mut report, &mut fails);

    // W1 — 손 목록 포함.
    late.extend(check_hand(&sc, &decl, &rows, &tgt, &mut report));
    fails.extend(late);

    for line in &report {
        println!("{line}");
    }
    // 실패 줄 뒤에 요약을 찍는다 — 변이 프로브는 출력 꼬리만 보여 준다.
    for f in &fails {
        println!("FAIL {f}");
    }
    println!("계급별: {class_line}");
    for s in &summary {
        println!("{s}");
    }
    assert!(
        fails.is_empty(),
        "적대 경로 행렬 실패 {} 건:\n{}\n계급별: {class_line}\n{}",
        fails.len(),
        fails.join("\n"),
        summary.join("\n")
    );
}

/// `outcome!` 대조군 — 결과를 **타입**으로 가르는가. SDK 오류 · 다른 오류(가 생기면 W3 가 SDK 오류 타입이
/// 아니라고 운다) · 값. 이것이 늘 `Ok` 를 내면 모든 칸의 「오류다」가 공허하다.
#[test]
fn outcome_sorts_results_by_type() {
    let names = [
        kind_name(&outcome!(Ok::<u8, KeycloakError>(1))),
        kind_name(&outcome!(Err::<u8, KeycloakError>(
            KeycloakError::Transport("x".into())
        ))),
        kind_name(&outcome!(Err::<u8, fmt::Error>(fmt::Error))),
        kind_name(&outcome!(String::from("값"))),
    ];
    assert_eq!(names, ["ok", "Transport", "foreign core::fmt::Error", "ok"]);
}

/// 분류기 대조군 — 부여는 경로 꼬리가 아니어도 본문(폼·JSON)의 grant_type 으로 잡힌다. introspect·admin
/// JSON 본문은 부여가 아니다. 구동 원문 대조는 라벨의 fn 을 **부르는** 자리만 받는다.
#[test]
fn classifier_reads_grants_from_any_post_and_drivers_must_call_their_label() {
    let req = |method: &str, path: &str, body: &str| {
        let grant = if method == "POST" {
            grant_type(body.as_bytes())
        } else {
            String::new()
        };
        Req {
            method: method.into(),
            path: path.into(),
            grant,
        }
    };
    let oidc = "/realms/r/protocol/openid-connect";
    let cases = [
        (
            req("POST", &format!("{oidc}/token"), "grant_type=refresh_token"),
            TOKEN_GRANT,
        ),
        (
            req(
                "POST",
                &format!("{oidc}/token/exchange"),
                "grant_type=authorization_code&code=x",
            ),
            CODE_EXCHANGE,
        ),
        (
            req(
                "POST",
                &format!("{oidc}/token"),
                r#"{"grant_type":"authorization_code"}"#,
            ),
            CODE_EXCHANGE,
        ),
        (
            req("POST", &format!("{oidc}/token/introspect"), "token=x"),
            OTHER,
        ),
        (
            req("POST", "/admin/realms/r/users", r#"{"username":"u"}"#),
            OTHER,
        ),
        (req("GET", &format!("{oidc}/certs"), ""), JWKS_FETCH),
    ];
    for (r, want) in cases {
        assert_eq!(classify(std::slice::from_ref(&r), false), want, "{r:?}");
    }
    assert_eq!(classify(&[], true), UNDETERMINED);
    assert_eq!(classify(&[], false), NONE);

    let d = |label: &'static str, src: &'static str| Driver {
        label,
        root: RootKind::Unit,
        call: |_, _| Box::pin(async { Kind::Ok }),
        src,
    };
    assert!(drives_its_label(&d("A::go", "k.auth().go(c.a()).await")));
    assert!(drives_its_label(&d("A::new", "A::new(c.a())")));
    assert!(drives_its_label(&d(
        "<A as Tr>::access_token",
        "TokenProvider::access_token(k.auth()).await"
    )));
    assert!(!drives_its_label(&d(
        "A::go_unchecked",
        "k.auth().go(c.a()).await"
    )));
    assert!(!drives_its_label(&d(
        "A::go",
        "k.auth().go_unchecked(c.a()).await"
    )));
}

/// 판독기(fn 쪽)가 기대는 모양 — 고유·트레이트 impl, 가시성 셋, 트레이트 기본·필수 메서드, 자유 fn, fn 몸통 안의
/// impl, 항목 자리 매크로, cfg(test) 모듈, 인자 패턴·제네릭·where·반환 타입, 몸통의 호출 이름, 같은 라벨 둘.
#[test]
fn fn_scanner_reads_the_shapes_the_matrix_relies_on() {
    let src = r##"
        pub struct A;
        struct Hidden;
        pub trait Tr { fn req(&self); fn dflt(&self) -> u8 { self.req(); 1 } }
        trait Private { fn p(&self); }
        impl A {
            /// doc
            #[must_use]
            pub fn new(url: impl Into<String>, n: Option<&str>) -> Self { let _ = helper(); A }
            pub async fn go<T: Clone>(&self, mut x: T, (a, b): (u8, u8)) -> Result<Vec<u8>, E> where T: Send {
                self.inner().await; Self::assoc(); Tr::dflt(self); x.clone(); m!(y);
                "fn fake(&self) {";
                Ok(vec![])
            }
            pub(crate) fn crate_only(&self) {}
            fn private(&self) {}
            pub const fn k() -> u8 { 1 }
        }
        impl Tr for A { fn req(&self) {} }
        impl Private for A { fn p(&self) {} }
        impl std::fmt::Debug for A { fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { Ok(()) } }
        impl Private for other::Foreign { fn p(&self) {} }
        impl Hidden { pub fn unreachable(&self) {} }
        pub fn free(a: u8) {}
        fn private_free() {
            impl A { pub fn smuggled(&self, nonce: &str) {} }
            pub fn inner_free() {}
        }
        pub mod m { pub fn nested() {} }
        #[cfg(test)]
        mod tests { impl A { pub fn test_only(&self) {} } pub fn t() {} }
    "##;
    let sc = scan(&[("lib".into(), src.into())]);
    let public: BTreeMap<&str, &FnDecl> = sc
        .public_fns()
        .into_iter()
        .map(|f| (f.label.as_str(), f))
        .collect();
    let labels: Vec<&str> = public.keys().copied().collect();
    assert_eq!(
        labels,
        [
            "<A as Debug>::fmt",
            "<A as Tr>::req",
            "A::go",
            "A::k",
            "A::new",
            "A::smuggled",
            "Tr::dflt",
            "crate::free",
            "crate::m::nested",
        ],
        "{:#?}",
        sc.fns
            .iter()
            .map(|f| (&f.label, f.vis_pub, f.nested))
            .collect::<Vec<_>>()
    );
    let go = public["A::go"];
    assert!(go.receiver);
    assert_eq!(
        go.params,
        [
            ("x".to_string(), "T".to_string()),
            ("_".into(), "(u8,u8)".into())
        ]
    );
    assert_eq!(go.ret, "Result<Vec<u8>,E>");
    assert_eq!(
        go.calls.iter().map(String::as_str).collect::<Vec<_>>(),
        ["assoc", "clone", "dflt", "inner"]
    );
    let new = public["A::new"];
    assert!(!new.receiver);
    assert_eq!(
        new.params,
        [
            ("url".to_string(), "impl Into<String>".to_string()),
            ("n".into(), "Option<&str>".into())
        ]
    );
    assert_eq!(new.ret, "Self");
    assert_eq!(
        public["A::smuggled"].params,
        [("nonce".to_string(), "&str".to_string())]
    );
    assert_eq!(sc.traits.get("Tr"), Some(&true));
    assert_eq!(sc.traits.get("Private"), Some(&false));
    assert!(sc.unreadable.is_empty(), "{:?}", sc.unreadable);
    // 같은 라벨 둘은 판독 불가로 떨어진다.
    let dup = scan(&[
        (
            "a".into(),
            "pub struct S; impl S { pub fn x(&self) {} }".into(),
        ),
        ("b".into(), "impl S { pub fn x(&self, y: u8) {} }".into()),
    ]);
    assert_eq!(dup.unreadable.len(), 1, "{:?}", dup.unreadable);
    // 항목 자리의 매크로 호출은 판독 불가다 — impl·트레이트 본문·모듈 셋. 정의(`macro_rules!`)와 fn 몸통의
    // 문장 매크로는 아니다.
    let macros = scan(&[(
        "lib".into(),
        "macro_rules! mint { () => {} }
         pub struct S;
         impl S { mint!(); pub fn f(&self) { println!(\"x\"); } }
         pub trait T { a::mint! {} }
         crate::mint!();"
            .into(),
    )]);
    assert_eq!(macros.unreadable.len(), 3, "{:#?}", macros.unreadable);
    // 스크립트 앵커 판독기 — 모양 둘(`async fn`·`fn`)과 접두(`canary|`), 경로 아닌 언급은 버린다.
    let script = "    rust)   printf '%s\\n' 'rust/src/auth.rs|async fn a_b(' \\\n\
                  'canary|rust/src/token_provider.rs|fn c(' ;;\n\
                  # rust/src/config.rs:18 는 앵커가 아니다\n\
                  rust)   printf '%s' 'rust/src/auth.rs' ;;";
    assert_eq!(
        script_anchors(script),
        ["src/auth.rs|a_b", "src/token_provider.rs|c"]
    );
}
