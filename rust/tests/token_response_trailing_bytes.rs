//! 토큰·introspection 응답 본문은 JSON 값 **하나**다 — 값 뒤에 JSON 공백 아닌 바이트가 붙으면 모든 레인이 그 본문을 그
//! 레인의 다른 형식 오류와 **같이** 거부하고, JSON 공백(SP·HTAB·LF·CR)만 붙으면 지금처럼 받는다. 둘 다
//! `serde_json::from_slice` 의 계약이다(`Deserializer::end` — 그 넷만 건너뛰고 나머지는 `TrailingCharacters`).
//!
//! ⚠️ oauth2 5.0 은 본문을 `serde_json::Deserializer::from_slice` 로 값 하나만 읽고 `end()` 를 부르지 않는다
//! (`endpoint.rs` 의 `endpoint_response` · `check_response_status`). 그래서 이 파일 전에는(실측 2026-10-29, main
//! e688039b) cc · refresh · code · introspect 레인이 `{…}garbage` · `{…}{…}` · `{…}\0` 을 **받았고**, 같은 SDK 의 admin
//! provider(`from_slice`)는 거부했다. 오류 상태도 갈렸다 — `{"error":…}garbage` 400 을 auth 레인은 `Auth`(코드까지
//! 옮겨), provider 는 `Transport` 로 냈다.
//!
//! 「다른 형식 오류」의 기준은 같은 레인·같은 상태의 **잘린 본문**(닫는 `}` 없음)이다 — 문구를 손으로 적지 않고 그
//! 레인이 실제로 내는 결과와 `Debug` 렌더링 전체(변형 · 문구 · `oauth_error`)로 대조한다. 레인 여덟은
//! `token_response_cap.rs` 와 같다(공개 진입점마다 따로 부른다).

use keycloak_sdk::{
    AuthClient, ClientCredentialsTokenProvider, KeycloakClient, KeycloakConfig, KeycloakError,
    TokenProvider, reqwest,
};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[derive(Clone, Copy, Debug)]
enum Lane {
    ClientCredentials,
    /// `<AuthClient as TokenProvider>::access_token` — 소비자가 admin 에 주입할 수 있는 auth 쪽 공급자.
    AuthAsTokenProvider,
    Refresh,
    Code,
    CodeWithRedirect,
    Introspect,
    /// admin 이 쓰는 `ClientCredentialsTokenProvider` 단독 — 이 SDK 에서 원래 `from_slice` 로 읽던 레인이다.
    Provider,
    /// admin 파사드(`list_realms`) — 그 provider 가 토큰을 먼저 얻는다.
    Admin,
}

const LANES: [Lane; 8] = [
    Lane::ClientCredentials,
    Lane::AuthAsTokenProvider,
    Lane::Refresh,
    Lane::Code,
    Lane::CodeWithRedirect,
    Lane::Introspect,
    Lane::Provider,
    Lane::Admin,
];

const TOKEN: &str = r#"{"access_token":"usable-access-token","token_type":"Bearer","expires_in":300,"refresh_token":"rt"}"#;
const INTROSPECT: &str = r#"{"active":true,"username":"u","client_id":"it-client"}"#;
const OAUTH_ERROR: &str = r#"{"error":"invalid_grant","error_description":"rejected"}"#;

/// 값 뒤에 붙는 공백 아닌 바이트. ⚠️ 마지막 것은 공백 **뒤의** 쓰레기다 — 꼬리의 첫 바이트만 보는 판정을 잡는다.
const NOT_WHITESPACE: [&str; 4] = [
    "garbage",
    r#"{"access_token":"second"}"#,
    "\0",
    " \r\n\tgarbage",
];

/// JSON 공백(RFC 8259 §2) 넷과 그 묶음 — serde_json 의 `end()` 가 건너뛰는 것이 정확히 이 넷이다.
const WHITESPACE: [&str; 5] = [" ", "\t", "\n", "\r", "\r\n\t "];

/// 응답 하나 — token 과 introspect 엔드포인트가 각자의 본문을 같은 상태로 준다.
struct Reply {
    status: u16,
    token: String,
    introspect: String,
}

impl Reply {
    /// 상태 200 이면 쓸 수 있는 응답, 아니면 OAuth 오류 응답 — 뒤에 `tail` 을 붙인다.
    fn with_tail(status: u16, tail: &str) -> Self {
        let (token, introspect) = if status == 200 {
            (TOKEN, INTROSPECT)
        } else {
            (OAUTH_ERROR, OAUTH_ERROR)
        };
        Self {
            status,
            token: format!("{token}{tail}"),
            introspect: format!("{introspect}{tail}"),
        }
    }

    /// 잘린 본문(닫는 `}` 가 없다) — 그 레인 · 그 상태의 「형식이 틀린 응답」 기준.
    fn truncated(status: u16) -> Self {
        let full = Self::with_tail(status, "");
        let cut = |s: &str| s[..s.len() - 1].to_string();
        Self {
            status,
            token: cut(&full.token),
            introspect: cut(&full.introspect),
        }
    }
}

/// 레인 하나를 새 IdP · 새 SDK 로 부른다(provider 는 토큰을 캐시한다) → (결과의 `Debug`, admin 요청 수).
async fn call(lane: Lane, reply: &Reply) -> (String, usize) {
    let server = MockServer::start().await;
    let oidc = "/realms/it-realm/protocol/openid-connect";
    for (p, body) in [
        (format!("{oidc}/token"), &reply.token),
        (format!("{oidc}/token/introspect"), &reply.introspect),
    ] {
        Mock::given(method("POST"))
            .and(path(p))
            .respond_with(
                ResponseTemplate::new(reply.status)
                    .set_body_raw(body.clone().into_bytes(), "application/json"),
            )
            .mount(&server)
            .await;
    }
    Mock::given(method("GET"))
        .and(path("/admin/realms"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(b"[]".to_vec(), "application/json"))
        .mount(&server)
        .await;
    let cfg = KeycloakConfig::new(server.uri(), "it-realm", "it-client")
        .unwrap()
        .with_client_secret("s");
    let client = KeycloakClient::new(cfg.clone()).unwrap();
    let provider = ClientCredentialsTokenProvider::new(cfg, reqwest::Client::new());
    let auth = client.auth();
    let verifier = "verifier-0123456789-0123456789-0123456789";
    let r: Result<String, KeycloakError> = match lane {
        Lane::ClientCredentials => auth
            .client_credentials_token()
            .await
            .map(|t| t.access_token),
        Lane::AuthAsTokenProvider => <AuthClient as TokenProvider>::access_token(auth).await,
        Lane::Refresh => auth.refresh("rt").await.map(|t| t.access_token),
        Lane::Code => auth
            .exchange_code("code", verifier, None)
            .await
            .map(|t| t.access_token),
        Lane::CodeWithRedirect => auth
            .exchange_code_with_redirect("code", verifier, "http://localhost/callback", None)
            .await
            .map(|t| t.access_token),
        Lane::Introspect => auth
            .introspect("some-token")
            .await
            .map(|r| format!("active={}", r.active)),
        Lane::Provider => provider.access_token().await,
        Lane::Admin => client
            .admin()
            .list_realms()
            .await
            .map(|realms| format!("{} realm(s)", realms.len())),
    };
    let admin_hits = server
        .received_requests()
        .await
        .expect("request recording is on")
        .iter()
        .filter(|r| r.url.path() == "/admin/realms")
        .count();
    (format!("{r:?}"), admin_hits)
}

/// 값 뒤의 공백 아닌 바이트 — 레인마다 잘린 본문과 **같은** 결과(오류)이고, admin 은 admin 요청을 보내지 않는다.
/// 200 과 400 둘 다다(상태와 무관하게 본문 하나 = 값 하나). 시험은 칸 전부를 돈 뒤 한꺼번에 실패한다.
#[tokio::test]
async fn bytes_after_the_json_value_fail_every_lane_like_a_truncated_body() {
    let mut wrong = Vec::new();
    for status in [200_u16, 400] {
        for lane in LANES {
            let (want, _) = call(lane, &Reply::truncated(status)).await;
            // 기준이 공허하지 않은가 — 잘린 본문이 성공하면 「같다」는 아무것도 재지 않는다.
            if !want.starts_with("Err(") {
                wrong.push(format!(
                    "status={status} {lane:?}: the truncated reference must fail, got {want}"
                ));
                continue;
            }
            for tail in NOT_WHITESPACE {
                let (got, admin_hits) = call(lane, &Reply::with_tail(status, tail)).await;
                if got != want {
                    wrong.push(format!(
                        "status={status} {lane:?} tail={tail:?}: {got} ≠ truncated {want}"
                    ));
                }
                if admin_hits != 0 {
                    wrong.push(format!(
                        "status={status} {lane:?} tail={tail:?}: {admin_hits} admin request(s) after a rejected token response"
                    ));
                }
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} cell(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// 대조 — JSON 공백만 붙으면 레인마다 꼬리 없는 본문과 같은 결과다. 200 은 성공(admin 은 admin 요청 하나), 400 은 그
/// 상태의 OAuth 오류(`oauth_error` 코드 그대로 · admin 은 401). 없으면 위 시험이 「꼬리가 있으면 늘 거부」와 구분되지 않는다.
#[tokio::test]
async fn json_whitespace_after_the_value_is_accepted_like_the_bare_body_on_every_lane() {
    let mut wrong = Vec::new();
    for status in [200_u16, 400] {
        for lane in LANES {
            let (want, want_hits) = call(lane, &Reply::with_tail(status, "")).await;
            let sane = match (status, lane) {
                (200, _) => want.starts_with("Ok("),
                (_, Lane::Admin) => want == "Err(Admin(Other { status: 401 }))",
                _ => {
                    want.starts_with("Err(Auth {")
                        && want.contains(r#"oauth_error: Some("invalid_grant")"#)
                }
            };
            if !sane {
                wrong.push(format!(
                    "status={status} {lane:?}: the bare reference is not what this lane answers today, got {want}"
                ));
                continue;
            }
            for tail in WHITESPACE {
                let (got, hits) = call(lane, &Reply::with_tail(status, tail)).await;
                if (got.as_str(), hits) != (want.as_str(), want_hits) {
                    wrong.push(format!(
                        "status={status} {lane:?} tail={tail:?}: ({got}, {hits} admin) ≠ bare ({want}, {want_hits} admin)"
                    ));
                }
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} cell(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}
