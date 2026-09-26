//! 형식이 틀리거나 적대적인 토큰·introspect 응답에서 난 SDK 오류가 **응답이 품은 토큰과 호출 인자로
//! 넘긴 비밀을 찍지 않는다** — node #603 의 rust 판. `facade_dump.rs` 가 정상 응답으로 만든 뿌리를
//! 걷는다면, 여기는 IdP 가 틀린 응답을 줄 때 나는 오류만 본다.
//!
//! 가짜 IdP 하나가 변형마다 realm 하나를 갖고, 그 realm 의 token·introspect 엔드포인트가 **같은 본문**을
//! 준다(refresh·코드 교환도 token 엔드포인트라 같은 모양을 받는다). 공개 인증 호출 전부를 변형마다 부른다.
//!
//! 찍는 경로 넷: `{e}` · `{e:?}` · `{e:#?}` · 로거가 찍는 `source()` 사슬(고리마다 `{}`, `": "` 로 잇는다).
//! 판정: 카나리아 원문, 또는 **그 카나리아에만 있는** 10자 조각(앞 10자 = 접두 노출 포함).
//!
//! ⚠️ 흐름 검사가 먼저다 — 변형이 호출을 실제로 실패시키지 않으면(가짜 IdP 가 정상 응답을 주면) 누출 검사는
//! 없는 오류를 찾으며 통과한다. 그래서 (변형, 호출) 마다 결과 분류를 못박는다.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use keycloak_sdk::{
    AdminError, AuthClient, ClientCredentialsTokenProvider, KeycloakClient, KeycloakConfig,
    KeycloakError, TokenProvider, reqwest,
};
use serde_json::json;
use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::time::{SystemTime, UNIX_EPOCH};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── 카나리아 ─────────────────────────────────────────────────────────────────────────────
// 대문자·하이픈으로 짓는다 — realm 이름·URL·오류 문구(소문자)의 조각과 겹치면 안 된다.

/// 호출 인자·설정으로 흘려 넣는 비밀. 오류가 **요청**을 품으면 여기서 샌다.
const SECRET: &str = "CLIENT-SECRET-CANARY-HOSTILE";
const RT_ARG: &str = "REFRESH-ARG-CANARY-HOSTILE";
const INTROSPECT_ARG: &str = "INTROSPECT-ARG-CANARY-HOSTILE";
const CODE_ARG: &str = "AUTHCODE-ARG-CANARY-HOSTILE";
const VERIFIER_ARG: &str = "PKCE-VERIFIER-ARG-CANARY-HOSTILE-0123456789-abcdefghijk";

const CLIENT_ID: &str = "c";
const NONCE: &str = "expected-nonce";
const WINDOW: usize = 10;

/// 알려진 누출 — `"realm|호출|카나리아"` → 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**.
const KNOWN_LEAKS: &[(&str, &str)] = &[];

/// 응답 모양 하나 — token 과 introspect 엔드포인트가 같은 것을 준다.
struct Variant {
    realm: &'static str,
    status: u16,
    content_type: String,
    body: String,
    /// 이 응답이 품은 비밀.
    canaries: Vec<(&'static str, String)>,
}

fn json_variant(
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

fn raw_variant(
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

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_secs()
}

/// 서명만 가짜인, 형식은 맞는 id_token. openidconnect 파싱을 통과해 SDK 의 nonce 검증(`JwtValidator`)에 닿는다.
fn untrusted_jwt(issuer: &str, kid: &str) -> String {
    let header =
        URL_SAFE_NO_PAD.encode(json!({"alg": "RS256", "typ": "JWT", "kid": kid}).to_string());
    let claims = json!({"iss": issuer, "sub": "u", "aud": CLIENT_ID, "exp": now() + 300,
        "iat": now(), "nonce": NONCE});
    let payload = URL_SAFE_NO_PAD.encode(claims.to_string());
    let sig = URL_SAFE_NO_PAD.encode("A2-FORGED-SIGNATURE-BYTES");
    format!("{header}.{payload}.{sig}")
}

/// 서명 검증까지 가게 할 공개키(비밀키는 버린다 — 위 서명은 어차피 가짜다).
fn public_jwk() -> serde_json::Value {
    use rsa::traits::PublicKeyParts;
    let sk = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).expect("rsa key");
    let pk = rsa::RsaPublicKey::from(&sk);
    json!({"kty":"RSA","kid":"k1","use":"sig","alg":"RS256",
        "n": URL_SAFE_NO_PAD.encode(pk.n().to_bytes_be()),
        "e": URL_SAFE_NO_PAD.encode(pk.e().to_bytes_be())})
}

fn variants(base: &str) -> Vec<Variant> {
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

async fn mount(server: &MockServer, v: &Variant, jwk: &serde_json::Value) {
    let oidc = format!("/realms/{}/protocol/openid-connect", v.realm);
    let hostile = ResponseTemplate::new(v.status)
        .set_body_raw(v.body.clone().into_bytes(), v.content_type.as_str());
    for p in [format!("{oidc}/token"), format!("{oidc}/token/introspect")] {
        Mock::given(method("POST"))
            .and(path(p))
            .respond_with(hostile.clone())
            .mount(server)
            .await;
    }
    Mock::given(method("GET"))
        .and(path(format!("{oidc}/certs")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"keys": [jwk]})))
        .mount(server)
        .await;
    // provider 가 토큰을 얻으면 admin 호출은 성공한다 — 실패는 토큰 경로에서만 나야 한다.
    Mock::given(method("GET"))
        .and(path(format!("/admin/realms/{}/users/u", v.realm)))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id": "u"})))
        .mount(server)
        .await;
}

type Outcome = std::result::Result<(), KeycloakError>;

/// token·introspect 엔드포인트를 치는 공개 인증 호출 전부.
async fn drive(cfg: &KeycloakConfig) -> Vec<(&'static str, Outcome)> {
    let client = KeycloakClient::new(cfg.clone()).expect("client");
    let auth: &AuthClient = client.auth();
    let provider = ClientCredentialsTokenProvider::new(cfg.clone(), reqwest::Client::new());
    vec![
        (
            "client_credentials_token",
            auth.client_credentials_token().await.map(|_| ()),
        ),
        ("refresh", auth.refresh(RT_ARG).await.map(|_| ())),
        (
            "exchange_code(nonce=None)",
            auth.exchange_code(CODE_ARG, VERIFIER_ARG, None)
                .await
                .map(|_| ()),
        ),
        (
            "exchange_code(nonce=Some)",
            auth.exchange_code(CODE_ARG, VERIFIER_ARG, Some(NONCE))
                .await
                .map(|_| ()),
        ),
        (
            "exchange_code_with_redirect",
            auth.exchange_code_with_redirect(
                CODE_ARG,
                VERIFIER_ARG,
                "https://app.example/cb2",
                Some(NONCE),
            )
            .await
            .map(|_| ()),
        ),
        (
            "introspect",
            auth.introspect(INTROSPECT_ARG).await.map(|_| ()),
        ),
        (
            "AuthClient as TokenProvider",
            TokenProvider::access_token(auth).await.map(|_| ()),
        ),
        (
            "ClientCredentialsTokenProvider",
            provider.access_token().await.map(|_| ()),
        ),
        (
            "admin get_user (default provider)",
            client.admin().get_user("u").await.map(|_| ()),
        ),
    ]
}

/// 결과 분류 — 흐름 검사가 못박는 것. oauth_error 는 따로 본다(수정 대상이다).
fn kind(r: &Outcome) -> String {
    match r {
        Ok(()) => "ok".into(),
        Err(KeycloakError::Auth { .. }) => "Auth".into(),
        Err(KeycloakError::Transport(_)) => "Transport".into(),
        Err(KeycloakError::TokenValidation(_)) => "TokenValidation".into(),
        Err(KeycloakError::Config(_)) => "Config".into(),
        Err(KeycloakError::Admin(AdminError::Other { status })) => format!("Admin({status})"),
        Err(KeycloakError::Admin(a)) => format!("Admin({a:?})"),
        Err(other) => format!("unexpected {other:?}"),
    }
}

/// (realm, 호출) → 기대 분류, `drive` 의 호출 순서대로. ⚠️ 변형이 호출을 **실제로 실패시켰는가**가
/// 여기 걸린다 — 수정 전(원 소스)에서 잰 표이고, 수정은 이 분류를 하나도 바꾸지 않는다.
/// `ok` 는 그 호출이 그 필드를 안 읽어(관대한 파싱) 성공하는 자리다 — 오류 뿌리가 아니다.
/// ⚠️ openidconnect 경로에서 응답 파싱 실패는 `Transport` 다(`map_token_err` 의 기존 분류).
#[rustfmt::skip]
const EXPECTED: &[(&str, [&str; 9])] = &[
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
fn renders(e: &KeycloakError) -> [(&'static str, String); 4] {
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
fn unique_windows(canaries: &[(&'static str, String)]) -> Vec<BTreeSet<String>> {
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
fn hits(
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

#[tokio::test]
async fn hostile_token_responses_fail_as_classified_and_errors_do_not_render_tokens() {
    let server = MockServer::start().await;
    let jwk = public_jwk();
    let vs = variants(&server.uri());
    for v in &vs {
        mount(&server, v, &jwk).await;
    }

    let mut canaries: Vec<(&'static str, String)> = vec![
        ("SECRET", SECRET.into()),
        ("RT_ARG", RT_ARG.into()),
        ("INTROSPECT_ARG", INTROSPECT_ARG.into()),
        ("CODE_ARG", CODE_ARG.into()),
        ("VERIFIER_ARG", VERIFIER_ARG.into()),
    ];
    canaries.extend(vs.iter().flat_map(|v| v.canaries.iter().cloned()));
    let windows = unique_windows(&canaries);
    let blind: Vec<_> = canaries
        .iter()
        .zip(&windows)
        .filter(|(_, w)| w.is_empty())
        .map(|((n, _), _)| *n)
        .collect();
    assert!(
        blind.is_empty(),
        "고유 10자 조각이 없는 카나리아: {blind:?}"
    );
    // 판정기 대조군 — 원문·접두·조각을 실제로 알아보는가.
    assert_eq!(
        hits(&format!("x{SECRET}x"), &canaries, &windows),
        [("SECRET", "full")]
    );
    assert_eq!(
        hits(&format!("x{}x", &RT_ARG[..WINDOW]), &canaries, &windows),
        [("RT_ARG", "prefix")]
    );

    let mut observed: Vec<(&'static str, &'static str, Outcome)> = Vec::new();
    for v in &vs {
        let cfg = KeycloakConfig::new(server.uri(), v.realm, CLIENT_ID)
            .expect("config")
            .with_client_secret(SECRET)
            .with_redirect_uri("https://app.example/cb");
        for (call, r) in drive(&cfg).await {
            observed.push((v.realm, call, r));
        }
    }

    // ── (1) 흐름 — 적대적 응답이 실제로 흘렀고, 호출마다 기대한 대로 실패했다.
    let reqs = server.received_requests().await.expect("recording");
    let mut flow = Vec::new();
    for v in &vs {
        let oidc = format!("/realms/{}/protocol/openid-connect", v.realm);
        for (p, needle) in [
            (format!("{oidc}/token"), format!("code={CODE_ARG}")),
            (format!("{oidc}/token"), format!("refresh_token={RT_ARG}")),
            (
                format!("{oidc}/token/introspect"),
                format!("token={INTROSPECT_ARG}"),
            ),
        ] {
            let seen = reqs
                .iter()
                .any(|r| r.url.path() == p && String::from_utf8_lossy(&r.body).contains(&needle));
            if !seen {
                flow.push(format!("{}: {p} 에 {needle} 가 안 실렸다", v.realm));
            }
        }
        let got: Vec<String> = observed
            .iter()
            .filter(|(realm, _, _)| *realm == v.realm)
            .map(|(_, _, r)| kind(r))
            .collect();
        match EXPECTED.iter().find(|(realm, _)| *realm == v.realm) {
            Some((_, want)) if got == want.as_slice() => {}
            Some((_, want)) => flow.push(format!("{}: 기대 {want:?} ≠ 실제 {got:?}", v.realm)),
            None => flow.push(format!("(\"{}\", {got:?}), — EXPECTED 에 없다", v.realm)),
        }
    }
    assert!(flow.is_empty(), "흐름 검사:\n{}", flow.join("\n"));

    // ── (2) 누출 — 오류 뿌리 전부를 네 경로로 찍는다.
    let mut leaks = Vec::new();
    let mut known_seen = BTreeSet::new();
    let mut roots = 0;
    for (realm, call, r) in &observed {
        let Err(e) = r else { continue };
        roots += 1;
        for (how, out) in renders(e) {
            for (name, level) in hits(&out, &canaries, &windows) {
                let key = format!("{realm}|{call}|{name}");
                if KNOWN_LEAKS.iter().any(|(k, _)| *k == key) {
                    known_seen.insert(key);
                    continue;
                }
                leaks.push(format!(
                    "{realm} | {call} | {how} | {name} ({level}) | {out}"
                ));
            }
        }
    }
    let want_roots = EXPECTED
        .iter()
        .flat_map(|(_, row)| row.iter())
        .filter(|k| **k != "ok")
        .count();
    assert_eq!(roots, want_roots, "오류 뿌리 수가 표와 다르다");
    assert!(
        leaks.is_empty(),
        "적대적 응답의 오류가 비밀을 찍는다 ({} 건):\n{}",
        leaks.len(),
        leaks.join("\n")
    );
    let stale: Vec<_> = KNOWN_LEAKS
        .iter()
        .filter(|(k, _)| !known_seen.contains(*k))
        .map(|(k, _)| *k)
        .collect();
    assert!(
        stale.is_empty(),
        "알려진 누출이 더 안 난다 — KNOWN_LEAKS 에서 지워라: {stale:?}"
    );

    // ── (3) 디버깅 정보는 남는다 — 서버 OAuth 오류는 `Auth` 이고 `oauth_error` 는 **코드 그대로**다.
    // 정화가 코드까지 지우면(None) 여기서 떨어진다(누출 검사는 그것을 못 본다). 코드 자리에 코드 아닌
    // 값이 오면(e3) `None` 이다 — 두 경로(openidconnect·provider) 모두.
    let mut codes = Vec::new();
    for (realm, want) in [
        ("e1-error-description", Some("invalid_grant")),
        ("e2-error-uri", Some("invalid_client")),
        ("e3-error-code-token", None),
    ] {
        for (_, call, r) in observed.iter().filter(|(v, _, _)| *v == realm) {
            match r {
                Err(KeycloakError::Auth { oauth_error, .. }) if oauth_error.as_deref() == want => {}
                Err(KeycloakError::Admin(_)) => {} // admin 경로는 상태코드만 싣는다(map_admin).
                other => codes.push(format!(
                    "{realm} | {call}: 기대 oauth_error={want:?}, 실제 {other:?}"
                )),
            }
        }
    }
    assert!(codes.is_empty(), "OAuth 오류 코드:\n{}", codes.join("\n"));
}
