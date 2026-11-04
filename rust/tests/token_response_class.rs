//! 토큰 응답의 오류 **계급**표 — 아홉 언어 판정(#935): 응답이 **끝까지 왔고** 쓸 토큰 응답이 아니면 `Auth`,
//! 응답이 다 오지 않았거나(네트워크 · 상한 초과) 요청을 보내지 못했으면 `Transport` 다.
//!
//! 행 이름의 R 번호는 #935 의 표와 같다 — R1 503 HTML · R2 200 비-JSON · R3 400 OAuth 오류 JSON ·
//! R4 200 JSON 에 `access_token` 없음 · R5 1,048,576 바이트 상한 초과 · R6 introspection 200 비-JSON(R2 행의
//! `introspect` 칸). 빈 본문 둘(E1 200 · E2 502)과 대조군 둘(쓸 수 있는 응답 · 닿지 않는 IdP)을 더했다.
//! 열은 공개 진입점 여덟이다 — `AuthClient` 의 토큰 호출 다섯(S1) · `introspect` · `ClientCredentialsTokenProvider`(S2)
//! · admin 파사드(S5: 토큰을 못 얻으면 요청 없이 `Admin(Other { status: 401 })`).
//!
//! ⚠️ 칸 하나를 바꾸면 등록부 `token-response-class-divergent` 의 아홉 언어 표도 함께 본다 — 계급은 언어 사이 계약이다.
//! 2026-11-04 까지는 R1·R2·R4·R6·E 가 S1 에서 `Transport` 였고, S2 는 R4 만 `Auth` 였다(언어 안 분리).

use keycloak_sdk::{
    AdminError, AuthClient, ClientCredentialsTokenProvider, KeycloakClient, KeycloakConfig,
    KeycloakError, TokenProvider, reqwest,
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

/// (realm, `CALLS` 순서의 계급). 마지막 행은 닿지 않는 IdP(연결 거부)다.
#[rustfmt::skip]
const EXPECTED: &[(&str, [&str; 8])] = &[
    //                             cc           refresh      exch         exch(redir)  AuthClient TP introspect   provider     admin
    ("ok",                        ["ok",        "ok",        "ok",        "ok",        "ok",        "ok",        "ok",        "ok"]),
    ("r1-503-html",               ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("r2-200-not-json",           ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("r2-200-not-json-json-type", ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("r3-400-oauth-error",        ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("r4-no-access-token",        ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("r5-over-cap",               ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Admin(401)"]),
    ("e1-200-empty",              ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("e2-502-empty",              ["Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Auth",      "Admin(401)"]),
    ("n-unreachable",             ["Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Transport", "Admin(401)"]),
];

struct Row {
    realm: &'static str,
    status: u16,
    content_type: &'static str,
    body: String,
}

fn rows() -> Vec<Row> {
    let row = |realm: &'static str, status: u16, content_type: &'static str, body: &str| Row {
        realm,
        status,
        content_type,
        body: body.into(),
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
    ]
}

async fn mount(server: &MockServer, row: &Row) {
    let oidc = format!("/realms/{}/protocol/openid-connect", row.realm);
    let resp = ResponseTemplate::new(row.status)
        .set_body_raw(row.body.clone().into_bytes(), row.content_type);
    for p in [format!("{oidc}/token"), format!("{oidc}/token/introspect")] {
        Mock::given(method("POST"))
            .and(path(p))
            .respond_with(resp.clone())
            .mount(server)
            .await;
    }
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
    let down = KeycloakConfig::new("http://127.0.0.1:1", "n", "it-client")
        .expect("config")
        .with_client_secret("s");
    got.push(("n-unreachable", drive(down).await));

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
