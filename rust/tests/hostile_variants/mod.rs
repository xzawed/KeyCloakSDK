//! 형식이 틀리거나 적대적인 토큰·introspect 응답 변형과, 그것을 `drive` 의 호출마다 어떻게 실패해야 하는지
//! 적은 표(`EXPECTED`), 그리고 오류 렌더링의 카나리아 판정기. `hostile_token_response.rs` 가 이것을 만들었고
//! (#623), `hostile_path_matrix.rs` 가 같은 변형을 **계급**(토큰 부여·코드 교환) 행 전부에 붙인다 — 변형
//! 집합을 새로 만들지 않으려고 한 사본을 함께 쓴다.
//!
//! ⚠️ 두 시험 크레이트가 각자 쓰는 부분만 쓴다 — 한쪽에서 안 쓰는 항목이 `dead_code` 로 울지 않게 모듈
//! 전체에서 끈다(`tests/common` 관용).
#![allow(dead_code)]

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use keycloak_sdk::KeycloakError;
use serde_json::json;
use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::time::{SystemTime, UNIX_EPOCH};

pub const CLIENT_ID: &str = "c";
pub const NONCE: &str = "expected-nonce";
pub const WINDOW: usize = 10;

/// `hostile_token_response.rs` 의 `drive` 가 부르는 순서 = `EXPECTED` 의 열 이름. 그 시험이 `drive` 의
/// 실제 순서와 같은지 단언한다(이름이 표와 어긋나면 행렬이 토큰 열을 잘못 가른다).
pub const CALLS: [&str; 9] = [
    "client_credentials_token",
    "refresh",
    "exchange_code(nonce=None)",
    "exchange_code(nonce=Some)",
    "exchange_code_with_redirect",
    "introspect",
    "AuthClient as TokenProvider",
    "ClientCredentialsTokenProvider",
    "admin get_user (default provider)",
];

/// `CALLS` 중 토큰 엔드포인트를 **치지 않는** 열 — introspect 는 자기 엔드포인트다. 나머지 여덟은 토큰 호출이다
/// (admin 도 provider 를 거쳐 토큰을 먼저 얻는다). 행렬은 「토큰 열 전부에서 실패로 단언된 변형」만 단언한다.
pub const NON_TOKEN_CALLS: [&str; 1] = ["introspect"];

/// 응답 모양 하나 — token 과 introspect 엔드포인트가 같은 것을 준다.
pub struct Variant {
    pub realm: &'static str,
    pub status: u16,
    pub content_type: String,
    pub body: String,
    /// 이 응답이 품은 비밀.
    pub canaries: Vec<(&'static str, String)>,
}

pub fn json_variant(
    realm: &'static str,
    status: u16,
    body: serde_json::Value,
    canaries: &[(&'static str, &str)],
) -> Variant {
    Variant {
        realm,
        status,
        content_type: "application/json".into(),
        body: body.to_string(),
        canaries: canaries.iter().map(|(n, v)| (*n, v.to_string())).collect(),
    }
}

pub fn raw_variant(
    realm: &'static str,
    status: u16,
    body: String,
    canary: (&'static str, &str),
) -> Variant {
    Variant {
        realm,
        status,
        // ⚠️ JSON 이라고 주장한다 — 아니면 oauth2 가 Content-Type 검사에서 먼저 떨어져 파서에 안 닿는다.
        content_type: "application/json".into(),
        body,
        canaries: vec![(canary.0, canary.1.to_string())],
    }
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_secs()
}

/// 서명만 가짜인, 형식은 맞는 id_token. openidconnect 파싱을 통과해 SDK 의 nonce 검증(`JwtValidator`)에 닿는다.
pub fn untrusted_jwt(issuer: &str, kid: &str) -> String {
    let header =
        URL_SAFE_NO_PAD.encode(json!({"alg": "RS256", "typ": "JWT", "kid": kid}).to_string());
    let claims = json!({"iss": issuer, "sub": "u", "aud": CLIENT_ID, "exp": now() + 300,
        "iat": now(), "nonce": NONCE});
    let payload = URL_SAFE_NO_PAD.encode(claims.to_string());
    let sig = URL_SAFE_NO_PAD.encode("A2-FORGED-SIGNATURE-BYTES");
    format!("{header}.{payload}.{sig}")
}

/// 서명 검증까지 가게 할 공개키(비밀키는 버린다 — 위 서명은 어차피 가짜다).
pub fn public_jwk() -> serde_json::Value {
    use rsa::traits::PublicKeyParts;
    let sk = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).expect("rsa key");
    let pk = rsa::RsaPublicKey::from(&sk);
    json!({"kty":"RSA","kid":"k1","use":"sig","alg":"RS256",
        "n": URL_SAFE_NO_PAD.encode(pk.n().to_bytes_be()),
        "e": URL_SAFE_NO_PAD.encode(pk.e().to_bytes_be())})
}

pub fn variants(base: &str) -> Vec<Variant> {
    let a2_id = untrusted_jwt(&format!("{base}/realms/a2-id-jwt-untrusted"), "k1");
    let a3_id = untrusted_jwt(
        &format!("{base}/realms/a3-id-kid-echo"),
        "A3-KID-CANARY-6C1V",
    );
    vec![
        // (a) id_token 이 JWT 가 아니다.
        json_variant(
            "a-id-not-jwt",
            200,
            json!({"access_token": "A-ACCESS-CANARY-7Q2K", "token_type": "Bearer",
                "expires_in": 300, "refresh_token": "A-REFRESH-CANARY-3K9M",
                "id_token": "A-IDTOKEN-NOT-JWT-CANARY-5M1X"}),
            &[
                ("A_AT", "A-ACCESS-CANARY-7Q2K"),
                ("A_RT", "A-REFRESH-CANARY-3K9M"),
                ("A_ID", "A-IDTOKEN-NOT-JWT-CANARY-5M1X"),
            ],
        ),
        // (a') id_token 은 형식이 맞지만 서명이 가짜다 — nonce 검증 경로(`verify_nonce`)의 오류 문구를 본다.
        json_variant(
            "a2-id-jwt-untrusted",
            200,
            json!({"access_token": "A2-ACCESS-CANARY-8D4F", "token_type": "Bearer",
                "expires_in": 300, "refresh_token": "A2-REFRESH-CANARY-6S2L", "id_token": a2_id}),
            &[
                ("A2_AT", "A2-ACCESS-CANARY-8D4F"),
                ("A2_RT", "A2-REFRESH-CANARY-6S2L"),
                ("A2_ID", &a2_id),
            ],
        ),
        // (a'') 형식은 맞는 id_token 의 헤더 kid 가 카나리아다 — JWKS 가 모르는 kid 를 오류 문구에 인용하는가.
        json_variant(
            "a3-id-kid-echo",
            200,
            json!({"access_token": "A3-ACCESS-CANARY-2X8T", "token_type": "Bearer",
                "expires_in": 300, "id_token": a3_id}),
            &[
                ("A3_AT", "A3-ACCESS-CANARY-2X8T"),
                ("A3_KID", "A3-KID-CANARY-6C1V"),
                ("A3_ID", &a3_id),
            ],
        ),
        // (b) access_token 이 문자열이 아니고 refresh_token 이 카나리아다.
        json_variant(
            "b-at-not-string",
            200,
            json!({"access_token": 12345, "token_type": "Bearer", "expires_in": 300,
                "refresh_token": "B-REFRESH-CANARY-8W4N"}),
            &[("B_RT", "B-REFRESH-CANARY-8W4N")],
        ),
        // (c) expires_in 이 문자열(serde 는 틀린 타입의 **문자열 값**을 인용한다)이고 토큰이 카나리아다.
        json_variant(
            "c1-expires-in-string",
            200,
            json!({"access_token": "C1-ACCESS-CANARY-4R8P", "token_type": "Bearer",
                "expires_in": "C1-EXPIRES-CANARY-9T3B", "refresh_token": "C1-REFRESH-CANARY-2H6T"}),
            &[
                ("C1_AT", "C1-ACCESS-CANARY-4R8P"),
                ("C1_EXP", "C1-EXPIRES-CANARY-9T3B"),
                ("C1_RT", "C1-REFRESH-CANARY-2H6T"),
            ],
        ),
        // (c) token_type 이 숫자다.
        json_variant(
            "c2-token-type-number",
            200,
            json!({"access_token": "C2-ACCESS-CANARY-6Y1G", "token_type": 5,
                "expires_in": 300, "refresh_token": "C2-REFRESH-CANARY-1U7J"}),
            &[
                ("C2_AT", "C2-ACCESS-CANARY-6Y1G"),
                ("C2_RT", "C2-REFRESH-CANARY-1U7J"),
            ],
        ),
        // (d) 200 인데 본문이 JSON 이 아니다 — 짧은 것(≤20자)은 통째로 토큰이다.
        raw_variant(
            "d1-short-body",
            200,
            "D1-BODY-CANARY-9Z".into(),
            ("D1_BODY", "D1-BODY-CANARY-9Z"),
        ),
        // (d) 긴 것은 카나리아로 **시작한다** — 앞 몇 자만 인용하는 파서 오류를 본다.
        raw_variant(
            "d2-long-body",
            200,
            format!("D2-LONGBODY-CANARY-5P0Z{}", " trailing-not-json".repeat(64)),
            ("D2_BODY", "D2-LONGBODY-CANARY-5P0Z"),
        ),
        // (d) 오류 상태 + JSON 아닌 본문 — oauth2 는 오류 본문을 따로 파싱한다.
        raw_variant(
            "d3-error-body-not-json",
            401,
            "D3-ERRBODY-CANARY-8V2C".into(),
            ("D3_BODY", "D3-ERRBODY-CANARY-8V2C"),
        ),
        // (e) OAuth 오류 본문의 error_description 이 받은 토큰을 되울린다.
        json_variant(
            "e1-error-description",
            400,
            json!({"error": "invalid_grant",
                "error_description": "Token E1-ECHOED-TOKEN-CANARY-4N6W is not active"}),
            &[("E1_ECHO", "E1-ECHOED-TOKEN-CANARY-4N6W")],
        ),
        // (e) error_uri 가 토큰을 실어 보낸다.
        json_variant(
            "e2-error-uri",
            401,
            json!({"error": "invalid_client", "error_description": "Invalid client",
                "error_uri": "https://idp.example/err?token=E2-ERRURI-CANARY-7J3V"}),
            &[("E2_URI", "E2-ERRURI-CANARY-7J3V")],
        ),
        // (e) OAuth 오류 **코드** 자리에 토큰이 온다(Grok 레그) — 코드는 옮기기로 한 값이다.
        json_variant(
            "e3-error-code-token",
            400,
            json!({"error": "E3-ERRCODE-CANARY-9K4D", "error_description": "x"}),
            &[("E3_CODE", "E3-ERRCODE-CANARY-9K4D")],
        ),
        // (f) introspect 모양 — active 가 불리언이 아니라 카나리아 문자열이다.
        json_variant(
            "f1-active-not-bool",
            200,
            json!({"active": "F1-ACTIVE-CANARY-3Q8R", "username": "svc",
                "refresh_token": "F1-REFRESH-CANARY-0L5E"}),
            &[
                ("F1_ACTIVE", "F1-ACTIVE-CANARY-3Q8R"),
                ("F1_RT", "F1-REFRESH-CANARY-0L5E"),
            ],
        ),
        // Content-Type 헤더가 토큰을 되울린다 — oauth2 는 그 값을 오류 문구에 인용한다.
        Variant {
            realm: "g-content-type-echo",
            status: 200,
            content_type: "text/plain; token=G-CONTENTTYPE-CANARY-2B7N".into(),
            body: json!({"access_token": "G-ACCESS-CANARY-5F9H", "token_type": "Bearer",
                "expires_in": 300})
            .to_string(),
            canaries: vec![
                ("G_CT", "G-CONTENTTYPE-CANARY-2B7N".into()),
                ("G_AT", "G-ACCESS-CANARY-5F9H".into()),
            ],
        },
    ]
}

/// (realm, 호출) → 기대 분류, `drive` 의 호출 순서대로. ⚠️ 변형이 호출을 **실제로 실패시켰는가**가
/// 여기 걸린다 — 수정 전(원 소스)에서 잰 표이고, 수정은 이 분류를 하나도 바꾸지 않는다.
/// `ok` 는 그 호출이 그 필드를 안 읽어(관대한 파싱) 성공하는 자리다 — 오류 뿌리가 아니다.
/// ⚠️ openidconnect 경로에서 응답 파싱 실패는 `Transport` 다(`map_token_err` 의 기존 분류).
#[rustfmt::skip]
pub const EXPECTED: &[(&str, [&str; 9])] = &[
    //                          cc           refresh      exch(None)   exch(Some)   exch(redir)  introspect   AuthClient TP  provider     admin
    ("a-id-not-jwt",           ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "ok",        "ok"]),
    ("a2-id-jwt-untrusted",    ["ok",        "ok",        "ok",        "Auth",      "Auth",      "Transport", "ok",        "ok",        "ok"]),
    ("a3-id-kid-echo",         ["ok",        "ok",        "ok",        "Auth",      "Auth",      "Transport", "ok",        "ok",        "ok"]),
    ("b-at-not-string",        ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Auth",      "Admin(401)"]),
    ("c1-expires-in-string",   ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "ok",        "ok"]),
    ("c2-token-type-number",   ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "ok",        "ok"]),
    ("d1-short-body",          ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Admin(401)"]),
    ("d2-long-body",           ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Admin(401)"]),
    ("d3-error-body-not-json", ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Admin(401)"]),
    ("e1-error-description",   ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("e2-error-uri",           ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("e3-error-code-token",    ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("f1-active-not-bool",     ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Auth",      "Admin(401)"]),
    ("g-content-type-echo",    ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "ok",        "ok"]),
];

/// 찍는 경로 넷.
pub fn renders(e: &KeycloakError) -> [(&'static str, String); 4] {
    let mut chain = e.to_string();
    let mut src = std::error::Error::source(e);
    while let Some(s) = src {
        let _ = write!(chain, ": {s}");
        src = s.source();
    }
    [
        ("{}", format!("{e}")),
        ("{:?}", format!("{e:?}")),
        ("{:#?}", format!("{e:#?}")),
        ("source() chain {}", chain),
    ]
}

/// 카나리아마다 **그 카나리아에만 있는** 10자 조각. 공유 조각(`-CANARY-`)은 어느 비밀인지 못 가른다.
pub fn unique_windows(canaries: &[(&'static str, String)]) -> Vec<BTreeSet<String>> {
    let windows = |v: &str| -> BTreeSet<String> {
        v.as_bytes()
            .windows(WINDOW)
            .filter_map(|w| std::str::from_utf8(w).ok())
            .map(str::to_string)
            .collect()
    };
    let all: Vec<BTreeSet<String>> = canaries.iter().map(|(_, v)| windows(v)).collect();
    all.iter()
        .map(|mine| {
            mine.iter()
                .filter(|w| all.iter().filter(|o| o.contains(*w)).count() == 1)
                .cloned()
                .collect()
        })
        .collect()
}

/// `out` 에 찍힌 카나리아 → (이름, 원문|접두|조각).
pub fn hits(
    out: &str,
    canaries: &[(&'static str, String)],
    windows: &[BTreeSet<String>],
) -> Vec<(&'static str, &'static str)> {
    canaries
        .iter()
        .zip(windows)
        .filter_map(|((name, value), ws)| {
            if out.contains(value.as_str()) {
                Some((*name, "full"))
            } else if out.contains(&value[..WINDOW.min(value.len())]) {
                Some((*name, "prefix"))
            } else if ws.iter().any(|w| out.contains(w.as_str())) {
                Some((*name, "fragment"))
            } else {
                None
            }
        })
        .collect()
}
