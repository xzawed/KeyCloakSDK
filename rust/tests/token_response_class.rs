//! 토큰 응답의 오류 **계급**표 — 아홉 언어 판정(#935): 응답이 **끝까지 왔고** 쓸 토큰 응답이 아니면 `Auth`,
//! 응답이 다 오지 않았거나(네트워크 · 상한 초과) 요청을 보내지 못했으면 `Transport` 다.
//!
//! 행 이름의 R 번호는 #935 의 표와 같다 — R1 503 HTML · R2 200 비-JSON · R3 400 OAuth 오류 JSON ·
//! R4 200 JSON 에 `access_token` 없음 · R5 1,048,576 바이트 상한 초과 · R6 introspection 200 비-JSON(R2 행의
//! `introspect` 칸). 빈 본문 둘(E1 200 · E2 502), 307 루프(X1 — 공유 클라이언트는 3xx 를 그대로 받고, 여기 provider 가
//! 받은 `reqwest::Client::new()` 만 따라가다 한도에 걸린다)와 대조군 셋(쓸 수 있는 응답 · 닿지 않는 IdP · 70,000 자 realm 으로
//! 보내지 못한 요청)을 더했다.
//! 열은 공개 진입점 여덟이다 — `AuthClient` 의 토큰 호출 다섯(S1) · `introspect` · `ClientCredentialsTokenProvider`(S2)
//! · admin 파사드(S5: 토큰을 못 얻으면 요청 없이 공급자의 오류 그대로 — 판정 D4. #1009 전에는 무엇이든
//! `Admin(Other { status: 401 })` 이라 연결 실패까지 「401」이었다).
//!
//! ⚠️ 칸 하나를 바꾸면 등록부 `token-response-class-divergent` 의 아홉 언어 표도 함께 본다 — 계급은 언어 사이 계약이다.
//! 2026-11-04 까지는 R1·R2·R4·R6·E 가 S1 에서 `Transport` 였고, S2 는 R4 만 `Auth` 였다(언어 안 분리).

use keycloak_sdk::jwks::JwksStore;
use keycloak_sdk::{
    AdminError, AuthClient, ClientCredentialsTokenProvider, JwtValidator, KeycloakClient,
    KeycloakConfig, KeycloakError, OidcEndpoints, TokenProvider, reqwest,
};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

/// 토큰·introspection 응답 상한 — `jwks.rs` 의 `TOKEN_RESPONSE_MAX_BYTES`(비공개)와 같은 수.
const CAP: usize = 1_048_576;
const VERIFIER: &str = "verifier-0123456789-0123456789-0123456789";
/// 쓸 수 있는 토큰 응답 — introspect 도 같은 본문을 받으므로 `active` 를 함께 싣는다.
const USABLE: &str = r#"{"access_token":"at","token_type":"Bearer","expires_in":300,"refresh_token":"rt","active":true}"#;
const OAUTH_ERROR_ROW: &str = "r3-400-oauth-error";

const CALLS: [&str; 8] = [
    "client_credentials_token",
    "refresh",
    "exchange_code",
    "exchange_code_with_redirect",
    "AuthClient as TokenProvider",
    "introspect",
    "ClientCredentialsTokenProvider",
    "admin list_realms",
];

/// (realm, `CALLS` 순서의 계급). 마지막 세 행은 본문이 끊기는 IdP · 닿지 않는 IdP(연결 거부) · 보내지 못한 요청이다.
#[rustfmt::skip]
const EXPECTED: &[(&str, [&str; 8])] = &[
    //                             cc           refresh      exch         exch(redir)  AuthClient TP introspect   provider     admin
    ("ok",                        ["ok",        "ok",        "ok",        "ok",        "ok",        "ok",        "ok",        "ok"]),
    ("r1-503-html",               ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth"]),
    ("r2-200-not-json",           ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth"]),
    ("r2-200-not-json-json-type", ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth"]),
    ("r3-400-oauth-error",        ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth"]),
    ("r4-no-access-token",        ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth"]),
    ("r5-over-cap",               ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport"]),
    ("e1-200-empty",              ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth"]),
    ("e2-502-empty",              ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth"]),
    ("x1-307-loop",               ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth"]),
    ("t-truncated-body",          ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport"]),
    ("n-unreachable",             ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport"]),
    ("u-uri-too-long",            ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport"]),
];

struct Row {
    realm: &'static str,
    status: u16,
    content_type: &'static str,
    body: String,
    /// `Location` 을 그 realm 의 token 주소로 — 따라가는 클라이언트가 끝없이 돈다.
    redirect_to_self: bool,
}

fn rows() -> Vec<Row> {
    let row = |realm: &'static str, status: u16, content_type: &'static str, body: &str| Row {
        realm,
        status,
        content_type,
        body: body.into(),
        redirect_to_self: false,
    };
    // 쓸 수 있는 응답 뒤에 JSON 공백을 붙여 상한을 한 바이트 넘긴다 — 상한 말고는 거부할 까닭이 없는 본문이다.
    let over_cap = format!("{USABLE}{}", " ".repeat(CAP + 1 - USABLE.len()));
    vec![
        row("ok", 200, "application/json", USABLE),
        row(
            "r1-503-html",
            503,
            "text/html; charset=utf-8",
            "<html><body><h1>503 Service Unavailable</h1></body></html>",
        ),
        row("r2-200-not-json", 200, "text/plain", "not json"),
        row(
            "r2-200-not-json-json-type",
            200,
            "application/json",
            "not json",
        ),
        row(
            OAUTH_ERROR_ROW,
            400,
            "application/json",
            r#"{"error":"invalid_client","error_description":"bad client"}"#,
        ),
        row(
            "r4-no-access-token",
            200,
            "application/json",
            r#"{"token_type":"Bearer","expires_in":300}"#,
        ),
        row("r5-over-cap", 200, "application/json", &over_cap),
        row("e1-200-empty", 200, "application/json", ""),
        row("e2-502-empty", 502, "text/html", ""),
        Row {
            redirect_to_self: true,
            ..row("x1-307-loop", 307, "text/plain", "")
        },
    ]
}

async fn mount(server: &MockServer, row: &Row) {
    let oidc = format!("/realms/{}/protocol/openid-connect", row.realm);
    let mut resp = ResponseTemplate::new(row.status)
        .set_body_raw(row.body.clone().into_bytes(), row.content_type);
    if row.redirect_to_self {
        resp = resp.insert_header("Location", format!("{}{oidc}/token", server.uri()));
    }
    for p in [format!("{oidc}/token"), format!("{oidc}/token/introspect")] {
        Mock::given(method("POST"))
            .and(path(p))
            .respond_with(resp.clone())
            .mount(server)
            .await;
    }
}

/// 머리는 온전하고 본문만 Content-Length 보다 짧게 끊는 가짜 IdP — 요청을 끝까지 읽은 뒤 답한다(보내기 실패와 섞이지 않게).
/// ⚠️ reqwest 0.12 는 이 끊김을 `is_decode()` 로 싼다 — 그것으로 계급을 가르면 이 행이 `Auth` 가 된다(#951 에서 실제로 그랬다).
fn truncating_idp() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let base = format!("http://{}", listener.local_addr().expect("addr"));
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { continue };
            std::thread::spawn(move || {
                use std::io::{Read, Write};
                let (mut req, mut buf) = (Vec::new(), [0u8; 4096]);
                let mut read_more = |req: &mut Vec<u8>| match s.read(&mut buf) {
                    Ok(n) if n > 0 => {
                        req.extend_from_slice(&buf[..n]);
                        true
                    }
                    _ => false,
                };
                let body_at = loop {
                    if let Some(i) = req.windows(4).position(|w| w == b"\r\n\r\n") {
                        break i + 4;
                    }
                    if !read_more(&mut req) {
                        return;
                    }
                };
                let head = String::from_utf8_lossy(&req[..body_at]).to_ascii_lowercase();
                let len = head
                    .lines()
                    .find_map(|l| l.strip_prefix("content-length:"))
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                while req.len() < body_at + len {
                    if !read_more(&mut req) {
                        return;
                    }
                }
                let _ = s.write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{\"access_token\"",
                );
            });
        }
    });
    base
}

type Outcome = std::result::Result<(), KeycloakError>;

/// 열마다 새 클라이언트다(provider 는 토큰을 캐시한다). 동시에 부른다 — 윈도에서 거부된 연결은 한 번에 수 초다.
async fn drive(cfg: KeycloakConfig) -> Vec<Outcome> {
    let client = KeycloakClient::new(cfg.clone()).expect("client");
    let auth: &AuthClient = client.auth();
    let provider = ClientCredentialsTokenProvider::new(cfg, reqwest::Client::new());
    let (cc, refresh, code, code_redirect, tp, introspect, prov, admin) = tokio::join!(
        auth.client_credentials_token(),
        auth.refresh("rt"),
        auth.exchange_code("code", VERIFIER, None),
        auth.exchange_code_with_redirect("code", VERIFIER, "http://localhost/cb", None),
        TokenProvider::access_token(auth),
        auth.introspect("at"),
        provider.access_token(),
        client.admin().list_realms(),
    );
    vec![
        cc.map(|_| ()),
        refresh.map(|_| ()),
        code.map(|_| ()),
        code_redirect.map(|_| ()),
        tp.map(|_| ()),
        introspect.map(|_| ()),
        prov.map(|_| ()),
        admin.map(|_| ()),
    ]
}

fn kind(r: &Outcome) -> String {
    match r {
        Ok(()) => "ok".into(),
        Err(KeycloakError::Auth { .. }) => "Auth".into(),
        Err(KeycloakError::Transport(_)) => "Transport".into(),
        Err(KeycloakError::Admin(AdminError::Other { status })) => format!("Admin({status})"),
        Err(other) => format!("unexpected {other:?}"),
    }
}

fn oauth_error(r: &Outcome) -> Option<&str> {
    match r {
        Err(KeycloakError::Auth { oauth_error, .. }) => oauth_error.as_deref(),
        _ => None,
    }
}

#[tokio::test]
async fn token_response_class_follows_the_nine_language_decision() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/admin/realms"))
        .respond_with(ResponseTemplate::new(200).set_body_raw("[]", "application/json"))
        .mount(&server)
        .await;
    let mut got: Vec<(&str, Vec<Outcome>)> = Vec::new();
    for row in rows() {
        mount(&server, &row).await;
        let cfg = KeycloakConfig::new(server.uri(), row.realm, "it-client")
            .expect("config")
            .with_client_secret("s");
        got.push((row.realm, drive(cfg).await));
    }
    let cut = KeycloakConfig::new(truncating_idp(), "t", "it-client")
        .expect("config")
        .with_client_secret("s");
    got.push(("t-truncated-body", drive(cut).await));
    let down = KeycloakConfig::new("http://127.0.0.1:1", "n", "it-client")
        .expect("config")
        .with_client_secret("s");
    got.push(("n-unreachable", drive(down).await));
    // 설정은 받지만 요청으로 만들 수 없는 주소 — oauth2 는 「failed to prepare request: uri too long」, reqwest 는 빌더 오류다.
    let unsent = KeycloakConfig::new(server.uri(), "r".repeat(70_000), "it-client")
        .expect("config")
        .with_client_secret("s");
    got.push(("u-uri-too-long", drive(unsent).await));

    assert_eq!(got.len(), EXPECTED.len(), "행 수가 기대표와 다르다");
    let mut wrong = Vec::new();
    for ((realm, outcomes), (want_realm, want)) in got.iter().zip(EXPECTED) {
        assert_eq!(realm, want_realm, "행 순서가 기대표와 다르다");
        for ((call, out), want) in CALLS.iter().zip(outcomes).zip(want) {
            let k = kind(out);
            if k != *want {
                wrong.push(format!("{realm} × {call}: {k} (기대 {want})"));
            }
            // 서버가 보낸 OAuth 오류만 코드를 싣는다 — 끝까지 온 쓸 수 없는 응답은 `oauth_error: None` 이다.
            let want_code = (*realm == OAUTH_ERROR_ROW).then_some("invalid_client");
            if k == "Auth" && oauth_error(out) != want_code {
                wrong.push(format!(
                    "{realm} × {call}: oauth_error {:?} (기대 {want_code:?})",
                    oauth_error(out)
                ));
            }
        }
    }
    assert!(wrong.is_empty(), "계급표와 다른 칸:\n{}", wrong.join("\n"));
}

/// 두 엔드포인트가 200 으로 각자의 본문을 준다 — `GET /admin/realms` 는 `[]` 다(admin 요청이 나갔는지 세는 자리).
async fn mount_success(server: &MockServer, realm: &str, token: String, introspect: String) {
    let oidc = format!("/realms/{realm}/protocol/openid-connect");
    for (p, body) in [
        (format!("{oidc}/token"), token),
        (format!("{oidc}/token/introspect"), introspect),
    ] {
        Mock::given(method("POST"))
            .and(path(p))
            .respond_with(ResponseTemplate::new(200).set_body_raw(body, "application/json"))
            .mount(server)
            .await;
    }
    Mock::given(method("GET"))
        .and(path("/admin/realms"))
        .respond_with(ResponseTemplate::new(200).set_body_raw("[]", "application/json"))
        .mount(server)
        .await;
}

async fn admin_requests(server: &MockServer) -> usize {
    server
        .received_requests()
        .await
        .expect("recording")
        .iter()
        .filter(|r| r.url.path() == "/admin/realms")
        .count()
}

/// 성공 상태(200)로 온 OAuth 오류(등록부 `auth-2xx-error-code-divergent` — 아홉 언어 같은 규칙): 본문이 JSON 객체이고 `error`
/// 가 비지 않은 문자열이면 그 호출은 400 의 `error` 와 같은 길로 실패한다 — 계급 `Auth`, 코드는 `oauth_error_code` 를 거친 값이고,
/// 같이 온 것(`access_token` · `active`)은 쓰지 않는다: 토큰을 돌려주지 않고, introspect 는 active 가 아니며, admin 요청은 없다.
/// 고치기 전(실측 2026-11-20): B1 은 `AuthClient` 의 여섯 칸이 코드 없는 「Failed to parse server response」였고, B2 는 여덟 칸이
/// 전부 성공했다(introspect 는 active=true, admin 은 그 토큰으로 요청을 보냈다).
#[tokio::test]
async fn success_status_oauth_error_fails_with_the_code_and_nothing_is_used() {
    const B2_ACCESS_TOKEN: &str = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl";
    let rows = [
        (
            "B1",
            r#"{"error":"invalid_grant","error_description":"d"}"#.to_string(),
            r#"{"error":"invalid_token"}"#.to_string(),
        ),
        (
            "B2",
            format!(
                r#"{{"error":"invalid_grant","access_token":"{B2_ACCESS_TOKEN}","token_type":"Bearer","expires_in":300}}"#
            ),
            r#"{"error":"invalid_token","active":true}"#.to_string(),
        ),
    ];
    let mut wrong = Vec::new();
    for (row, token, introspect) in rows {
        let server = MockServer::start().await;
        mount_success(&server, "r", token, introspect).await;
        let cfg = KeycloakConfig::new(server.uri(), "r", "it-client")
            .expect("config")
            .with_client_secret("s");
        for (call, out) in CALLS.iter().zip(drive(cfg).await) {
            let want = if *call == "introspect" {
                "invalid_token"
            } else {
                "invalid_grant"
            };
            if kind(&out) != "Auth" || oauth_error(&out) != Some(want) {
                wrong.push(format!(
                    "{row} × {call}: {} · oauth_error {:?} (기대 Auth · {want:?})",
                    kind(&out),
                    oauth_error(&out)
                ));
            }
        }
        let n = admin_requests(&server).await;
        if n != 0 {
            wrong.push(format!("{row}: admin 요청 {n} 번 (기대 0)"));
        }
    }
    assert!(wrong.is_empty(), "다른 칸:\n{}", wrong.join("\n"));
}

/// `error` 가 있고 null 도 `""` 도 아니면 — 숫자 · 객체 · 배열 · 불리언도 — 그 호출은 400 이 같은 본문을 실었을 때처럼 실패한다:
/// 여덟 칸 모두 계급 `Auth`, 코드 없음(문자열이 아니다), admin 요청 없음(등록부 `token-response-residual-divergence` A). 예전에는
/// 대조군이었다 — 같이 온 쓸 수 있는 응답이 여덟 칸 모두 성공했다.
#[tokio::test]
async fn success_status_oauth_error_that_is_no_string_fails_without_a_code() {
    let values = [
        ("p2-number", serde_json::json!(5)),
        ("p2-object", serde_json::json!({"code": "invalid_grant"})),
        ("p2-array", serde_json::json!(["invalid_grant"])),
        ("p2-bool", serde_json::json!(true)),
    ];
    let mut wrong = Vec::new();
    for (realm, value) in values {
        let server = MockServer::start().await;
        let token = serde_json::json!({
            "error": value, "access_token": "at", "token_type": "Bearer", "expires_in": 300,
            "refresh_token": "rt"
        });
        let introspect = serde_json::json!({ "error": value, "active": true });
        mount_success(&server, realm, token.to_string(), introspect.to_string()).await;
        let cfg = KeycloakConfig::new(server.uri(), realm, "it-client")
            .expect("config")
            .with_client_secret("s");
        for (call, out) in CALLS.iter().zip(drive(cfg).await) {
            if kind(&out) != "Auth" || oauth_error(&out).is_some() {
                wrong.push(format!(
                    "{realm} × {call}: {} · oauth_error {:?} (기대 Auth · None)",
                    kind(&out),
                    oauth_error(&out)
                ));
            }
        }
        let n = admin_requests(&server).await;
        if n != 0 {
            wrong.push(format!("{realm}: admin 요청 {n} 번 (기대 0)"));
        }
    }
    assert!(wrong.is_empty(), "다른 칸:\n{}", wrong.join("\n"));
}

/// 대조군 — `error` 가 null 이거나 `""` 이면 지금처럼 다룬다: 같이 온 쓸 수 있는 응답이 여덟 칸 모두 성공이다.
#[tokio::test]
async fn success_status_oauth_error_that_is_null_or_empty_is_ignored() {
    let server = MockServer::start().await;
    let values = [
        ("p2-null", serde_json::Value::Null),
        ("p2-empty", serde_json::json!("")),
    ];
    let mut wrong = Vec::new();
    for (realm, value) in values {
        let token = serde_json::json!({
            "error": value, "access_token": "at", "token_type": "Bearer", "expires_in": 300,
            "refresh_token": "rt"
        });
        let introspect = serde_json::json!({ "error": value, "active": true });
        mount_success(&server, realm, token.to_string(), introspect.to_string()).await;
        let cfg = KeycloakConfig::new(server.uri(), realm, "it-client")
            .expect("config")
            .with_client_secret("s");
        for (call, out) in CALLS.iter().zip(drive(cfg).await) {
            if kind(&out) != "ok" {
                wrong.push(format!("{realm} × {call}: {} (기대 ok)", kind(&out)));
            }
        }
    }
    assert!(wrong.is_empty(), "다른 칸:\n{}", wrong.join("\n"));
}

/// 저수준 `AuthClient::new` 에 리다이렉트를 따라가는 클라이언트를 주면 X1 이 openidconnect 경로에서도 reqwest 의 리다이렉트
/// 실패가 된다 — `map_token_err` 의 `Reqwest` 갈래(공유 클라이언트는 3xx 를 그대로 받아 이 갈래에 안 닿는다).
#[tokio::test]
async fn injected_following_client_reports_a_redirect_loop_as_auth() {
    let server = MockServer::start().await;
    let row = rows()
        .into_iter()
        .find(|r| r.redirect_to_self)
        .expect("X1 row");
    mount(&server, &row).await;
    let cfg = KeycloakConfig::new(server.uri(), row.realm, "it-client")
        .expect("config")
        .with_client_secret("s");
    let endpoints = OidcEndpoints::new(&cfg);
    let jwks = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
    let validator = JwtValidator::new(&cfg, &endpoints, jwks).expect("validator");
    let auth = AuthClient::new(cfg, endpoints, reqwest::Client::new(), validator).expect("auth");
    let cc = auth.client_credentials_token().await.map(|_| ());
    let introspect = auth.introspect("at").await.map(|_| ());
    assert_eq!([kind(&cc), kind(&introspect)], ["Auth", "Auth"]);
    let hits = server.received_requests().await.expect("recording").len();
    assert!(hits > 2, "따라가지 않았다 — 요청 {hits} 번");
}

/// 칸 하나의 결과를 한 줄로 — 성공이면 `ok`, 실패면 계급 · 문구 · 코드(같은 본문의 400 과 견준다).
fn line(r: &Outcome) -> String {
    match r {
        Ok(()) => "ok".into(),
        Err(KeycloakError::Auth {
            message,
            oauth_error,
        }) => format!("Auth({message}) code={oauth_error:?}"),
        Err(KeycloakError::Transport(m)) => format!("Transport({m})"),
        Err(other) => format!("unexpected {other:?}"),
    }
}

/// 두 엔드포인트가 `status` 로 각자의 본문을 준다(204 는 본문 없이 간다) — `GET /admin/realms` 는 200 `[]` 다.
async fn mount_status(server: &MockServer, status: u16, token: &str, introspect: &str) {
    server.reset().await;
    let oidc = "/realms/r/protocol/openid-connect";
    for (p, body) in [
        (format!("{oidc}/token"), token),
        (format!("{oidc}/token/introspect"), introspect),
    ] {
        Mock::given(method("POST"))
            .and(path(p))
            .respond_with(
                ResponseTemplate::new(status).set_body_raw(body.to_string(), "application/json"),
            )
            .mount(server)
            .await;
    }
    Mock::given(method("GET"))
        .and(path("/admin/realms"))
        .respond_with(ResponseTemplate::new(200).set_body_raw("[]", "application/json"))
        .mount(server)
        .await;
}

async fn token_requests(server: &MockServer) -> usize {
    server
        .received_requests()
        .await
        .expect("recording")
        .iter()
        .filter(|r| r.url.path().ends_with("/token"))
        .count()
}

/// 토큰 · introspection 응답의 성공은 HTTP 200 뿐이다(토큰은 RFC 6749 §5.1, introspection 은 SDK 의 규칙 — RFC 7662 §2.2 는
/// 상태를 정하지 않고 그 예와 Keycloak 이 200 이다 · 아홉 언어, 등록부
/// `token-success-status-range-divergent`): 다른 2xx 는 같은 본문의 400 과 같은 길로 실패한다 — 같은 계급 · 문구 · 코드, 토큰을
/// 돌려주지도 캐시하지도 않고 admin 요청이 없다(204 는 본문이 없어 본문 없는 400 과 견준다). `error` 를 실은 201 은 그것을 실은
/// 400 과 같다. 고치기 전(main c4b5096a): `AuthClient` 의 여섯 칸은 oauth2 가 200 만 성공으로 읽어 이미 그랬고(핀), provider 는
/// 2xx 의 토큰을 캐시했고 admin 은 그것으로 요청을 보냈다.
#[tokio::test]
async fn non_200_success_status_fails_as_the_lanes_error_response() {
    const B1_TOKEN: &str = r#"{"error":"invalid_grant","error_description":"d"}"#;
    const B1_INTROSPECT: &str = r#"{"error":"invalid_token"}"#;
    const PARSE: &str = "Auth(token request failed: Failed to parse server response) code=None";
    const EMPTY: &str =
        "Auth(token request failed: Other error: server returned empty error response) code=None";
    // introspection 은 제 엔드포인트를 댄다(#1205 auth-error-message-misnames — 그랜트 문구는 그대로다).
    const PARSE_INTROSPECT: &str =
        "Auth(introspection request failed: Failed to parse server response) code=None";
    const EMPTY_INTROSPECT: &str = "Auth(introspection request failed: Other error: server returned empty error response) code=None";
    const PROVIDER: &str = "Auth(client-credentials failed) code=None";
    const PROVIDER_EMPTY: &str = "Auth(token response: error decoding response body) code=None";
    // 400 의 칸(고정 — 다른 상태가 견주는 기준): `CALLS` 순서로 AuthClient 여섯(다섯째 뒤 여섯째가 introspect) · provider · admin.
    let auth_six = |token: &'static str, introspect: &'static str| {
        let mut six = [token; 6];
        six[5] = introspect;
        six
    };
    let at400 = |six: [&str; 6], provider: &str| -> Vec<String> {
        six.iter()
            .chain([provider, provider].iter())
            .map(|s| s.to_string())
            .collect()
    };
    let b1_six = auth_six(
        "Auth(token endpoint rejected) code=Some(\"invalid_grant\")",
        "Auth(introspection endpoint rejected) code=Some(\"invalid_token\")",
    );
    let pinned = [
        ("good", at400(auth_six(PARSE, PARSE_INTROSPECT), PROVIDER)),
        (
            "empty",
            at400(auth_six(EMPTY, EMPTY_INTROSPECT), PROVIDER_EMPTY),
        ),
        (
            "B1",
            at400(
                b1_six,
                "Auth(client-credentials failed) code=Some(\"invalid_grant\")",
            ),
        ),
    ];
    let body = |kind: &str| match kind {
        "good" => (USABLE, USABLE),
        "empty" => ("", ""),
        _ => (B1_TOKEN, B1_INTROSPECT),
    };
    // (상태, 본문) — 400 칸 셋 · 200 · 다른 2xx(204 는 본문 없는 400 과) · `error` 를 실은 201.
    let mut cells: Vec<(u16, &str)> =
        vec![(400, "good"), (400, "empty"), (400, "B1"), (200, "good")];
    cells.extend([201, 202, 203, 204, 206, 299].map(|s| (s, "good")));
    cells.push((201, "B1"));
    let server = MockServer::start().await;
    let cfg = KeycloakConfig::new(server.uri(), "r", "it-client")
        .expect("config")
        .with_client_secret("s");
    let (mut wrong, mut table) = (Vec::new(), Vec::new());
    for (status, kind) in cells {
        let (token, introspect) = body(kind);
        mount_status(&server, status, token, introspect).await;
        let got: Vec<String> = drive(cfg.clone()).await.iter().map(line).collect();
        let held_to = if status == 204 { "empty" } else { kind };
        let want: Vec<String> = if status == 200 {
            vec!["ok".to_string(); CALLS.len()]
        } else {
            pinned
                .iter()
                .find(|(k, _)| *k == held_to)
                .expect("pinned")
                .1
                .clone()
        };
        for ((call, got), want) in CALLS.iter().zip(&got).zip(&want) {
            table.push(format!("{status} {kind} × {call} → {got}"));
            if got != want {
                wrong.push(format!("{status} {kind} × {call}: {got} ≠ {want}"));
            }
        }
        let admin = admin_requests(&server).await;
        if admin != usize::from(status == 200) {
            wrong.push(format!("{status} {kind}: admin 요청 {admin} 번"));
        }
        // 캐시하지 않았다 — 같은 provider · 같은 admin 파사드가 200 에서 다시 묻고 그 토큰을 쓴다.
        if status != 200 {
            let client = KeycloakClient::new(cfg.clone()).expect("client");
            let provider = ClientCredentialsTokenProvider::new(cfg.clone(), reqwest::Client::new());
            let first = (
                provider.access_token().await,
                client.admin().list_realms().await,
            );
            mount_status(&server, 200, USABLE, USABLE).await;
            let again = (
                provider.access_token().await,
                client.admin().list_realms().await,
            );
            let (tokens, admin) = (token_requests(&server).await, admin_requests(&server).await);
            if first.0.is_ok() || first.1.is_ok() || again.0.is_err() || again.1.is_err() {
                wrong.push(format!(
                    "{status} {kind}: provider {} → {} · admin {} → {}",
                    first.0.is_ok(),
                    again.0.is_ok(),
                    first.1.is_ok(),
                    again.1.is_ok()
                ));
            }
            if (tokens, admin) != (2, 1) {
                wrong.push(format!(
                    "{status} {kind}: 200 에서 토큰 요청 {tokens} 번 · admin 요청 {admin} 번(기대 2 · 1)"
                ));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "다른 칸:\n{}\n\n{}",
        wrong.join("\n"),
        table.join("\n")
    );
}
