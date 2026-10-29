//! admin Bearer 문법 — 아홉 언어 같은 표(결정 2026-10-29, 등록부 `bearer-token-grammar-divergent`). 앞뒤의 SP·HTAB·
//! CR·LF 넷만 떼고, 남은 값이 RFC 6750 `b64token`(`^[A-Za-z0-9\-._~+/]+=*$`)이면 **뗀 값**을 Bearer 로 보내고, 아니면
//! 요청 없이 거부한다. 길은 넷 — 소비자가 주입한 `TokenProvider` 위의 파사드(`list_realms`)와 `raw()`(`get`), SDK 의
//! `ClientCredentialsTokenProvider`(거부한 토큰을 캐시하지 않는다), 기본 경로 `KeycloakClient` 의 파사드·`raw()`.
//!
//! 고치기 전(실측 2026-10-29, main 3ed85eb3 — 네 길 × 스무 행 중 61 칸이 틀렸다): 파사드는 reqwest 의 헤더 검사에
//! 걸리는 값(CR·LF·NUL·DEL·VT — 끝 개행 포함)만 `Transport("admin request: builder error")` 로, `raw()` 는 crate 의
//! `ReqwestFailure(Builder)` 로 거부했고, 안쪽 공백·탭·`=`·빈 값·Latin-1·U+0100·U+0085·NBSP·U+3000 은 그대로(ASCII
//! 밖은 날 UTF-8) 보냈다. `lead-tab` 은 `Bearer  \tabc` 로 나갔다. provider 는 빈 값만 거부하고 나머지를 그대로
//! 캐시했다. ⚠️ `raw()` 의 거부는 이제 공급자가 내는 `HttpFailure { status: 401 }` 이다 — `reqwest::Error` 는 공개
//! 생성자가 없어 crate 의 그 변형을 SDK 가 만들 수 없다.

use async_trait::async_trait;
use keycloak_sdk::{
    AdminClient, AdminError, ClientCredentialsTokenProvider, KeycloakClient, KeycloakConfig,
    KeycloakError, RawKeycloakError, TokenProvider, reqwest,
};
use std::sync::Arc;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const REALM: &str = "r";
const TOKEN_PATH: &str = "/realms/r/protocol/openid-connect/token";
const ADMIN_PATH: &str = "/admin/realms";
/// 보내는 자리의 거부 문구 — 정확히 본다. ⚠️ 접두사(`admin request: `)만 보면 reqwest 의 헤더 검사가 내는
/// `admin request: builder error` 도 통과해, 검사를 빼도 NUL·DEL·VT 행이 살아남는다(변이로 확인했다).
const REFUSED: &str = "admin request: access token is not an RFC 6750 bearer token (b64token)";

/// 표의 한 행 — 입력, 서버가 받는 Bearer 값(거부면 `None`), 오류 렌더에 없어야 할 글자(없으면 `""`).
struct Case {
    id: &'static str,
    token: String,
    sent: Option<String>,
    canary: &'static str,
}

fn case(id: &'static str, token: &str, sent: Option<&str>, canary: &'static str) -> Case {
    Case {
        id,
        token: token.to_string(),
        sent: sent.map(str::to_string),
        canary,
    }
}

/// 표 — 스무 행 전부. rust 의 덤은 없다: `String` 은 늘 올바른 UTF-8 이라 짝 없는 서로게이트도 잘못된 바이트도 담지 못한다.
fn cases() -> Vec<Case> {
    let jws = jsonwebtoken::encode(
        &jsonwebtoken::Header::default(),
        &serde_json::json!({"sub": "u1"}),
        &jsonwebtoken::EncodingKey::from_secret(b"bearer-grammar-test-key-0123456789"),
    )
    .expect("sign");
    vec![
        case(
            "plain",
            "abc.DEF-ghi_jkl~mno+pqr/stu",
            Some("abc.DEF-ghi_jkl~mno+pqr/stu"),
            "",
        ),
        case("pad", "abc==", Some("abc=="), ""),
        case("jwt", &jws, Some(&jws), ""),
        case("lf", "abc\n", Some("abc"), ""),
        case("crlf", "abc\r\n", Some("abc"), ""),
        case("lead-tab", " \tabc\t ", Some("abc"), ""),
        case("inner-sp", "a bc", None, "a bc"),
        case("inner-tab", "a\tbc", None, "a\tbc"),
        case("inner-crlf", "a\r\nX-Evil: 1", None, "X-Evil"),
        case("mid-pad", "a=bc", None, "a=bc"),
        case("empty", "", None, ""),
        case("blank", " \t\r\n", None, ""),
        case("latin1", "abc\u{e9}", None, "abc"),
        case("above-ff", "abc\u{100}", None, "abc"),
        case("c1", "abc\u{85}", None, "abc"),
        case("nul", "abc\u{0}", None, "abc"),
        case("del", "abc\u{7f}", None, "abc"),
        case("nbsp", "abc\u{a0}", None, "abc"),
        case("ideographic", "\u{3000}abc", None, "abc"),
        case("vt", "abc\u{b}", None, "abc"),
    ]
}

/// 소비자가 주입한 공급자 — 늘 같은 값을 준다(캐시도 검사도 없다).
struct Fixed(String);

#[async_trait]
impl TokenProvider for Fixed {
    async fn access_token(&self) -> Result<String, KeycloakError> {
        Ok(self.0.clone())
    }
}

fn config(server: &MockServer) -> KeycloakConfig {
    KeycloakConfig::new(server.uri(), REALM, "it-client")
        .unwrap()
        .with_client_secret("s")
}

/// 가짜 IdP — 토큰 엔드포인트는 `token` 을 access_token 으로 주고, `GET /admin/realms` 는 `[]` 다.
async fn server_serving(token: &str) -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "access_token": token, "token_type": "Bearer", "expires_in": 300
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(ADMIN_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([])))
        .mount(&server)
        .await;
    server
}

/// `p` 로 간 요청마다 서버가 받은 `Authorization` 바이트.
async fn received(server: &MockServer, p: &str) -> Vec<Option<Vec<u8>>> {
    server
        .received_requests()
        .await
        .expect("received_requests available")
        .iter()
        .filter(|r| r.url.path() == p)
        .map(|r| {
            r.headers
                .get("authorization")
                .map(|v| v.as_bytes().to_vec())
        })
        .collect()
}

/// 보낸 행 — admin 요청이 정확히 하나이고, 그 Bearer 가 뗀 값이다.
async fn check_sent(wrong: &mut Vec<String>, label: &str, server: &MockServer, sent: &str) {
    let want = Some(format!("Bearer {sent}").into_bytes());
    let got = received(server, ADMIN_PATH).await;
    if got != vec![want] {
        let shown: Vec<_> = got
            .iter()
            .map(|h| h.as_ref().map(|b| String::from_utf8_lossy(b).into_owned()))
            .collect();
        wrong.push(format!(
            "{label}: expected one `Bearer {sent:?}`, server got {shown:?}"
        ));
    }
}

/// 거부한 행 — admin 요청이 하나도 없고, 오류 렌더(`Display`·`Debug`)에 토큰의 글자가 없다.
async fn check_refused(
    wrong: &mut Vec<String>,
    label: &str,
    server: &MockServer,
    rendered: &[String],
    canary: &str,
) {
    let n = received(server, ADMIN_PATH).await.len();
    if n != 0 {
        wrong.push(format!("{label}: {n} admin request(s) reached the server"));
    }
    if !canary.is_empty() && rendered.iter().any(|r| r.contains(canary)) {
        wrong.push(format!("{label}: error quotes the token: {rendered:?}"));
    }
}

/// `raw()` 의 거부 — 공급자가 내는 401 이고, 그 문구가 보내는 자리의 거부다(crate 의 `ReqwestFailure` 가 아니다).
fn refused_raw(e: &RawKeycloakError) -> bool {
    matches!(e, RawKeycloakError::HttpFailure { status: 401, text, .. } if text.ends_with(REFUSED))
}

fn report(route: &str, wrong: &[String]) {
    assert!(
        wrong.is_empty(),
        "{route} — {} row(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// 파사드 — 소비자가 주입한 공급자의 값이 보내는 자리를 지난다. 거부는 `Transport`(`admin request: …`)다.
#[tokio::test]
async fn facade_sends_the_trimmed_b64token_or_refuses_without_a_request() {
    let mut wrong = Vec::new();
    for c in cases() {
        let server = server_serving("unused").await;
        let admin = AdminClient::new(
            &config(&server),
            reqwest::Client::new(),
            Arc::new(Fixed(c.token.clone())),
        );
        let label = format!("{} via list_realms", c.id);
        match (admin.list_realms().await, &c.sent) {
            (Ok(_), Some(sent)) => check_sent(&mut wrong, &label, &server, sent).await,
            (Err(KeycloakError::Transport(msg)), None) if msg == REFUSED => {
                let e = KeycloakError::Transport(msg);
                let rendered = [e.to_string(), format!("{e:?}")];
                check_refused(&mut wrong, &label, &server, &rendered, c.canary).await;
            }
            (got, _) => {
                let n = received(&server, ADMIN_PATH).await.len();
                wrong.push(format!(
                    "{label}: got {:?} (admin requests {n}), want {}",
                    got.map(|_| "Ok"),
                    c.sent
                        .as_deref()
                        .map_or(format!("Transport({REFUSED:?})"), |s| format!(
                            "Ok with `Bearer {s:?}`"
                        ))
                ));
            }
        }
    }
    report("facade (injected provider)", &wrong);
}

/// `raw()` — crate 가 `SdkTokenSupplier` 에서 토큰을 받는다. 거부는 그 공급자가 내는 `HttpFailure { status: 401 }` 다.
#[tokio::test]
async fn raw_sends_the_trimmed_b64token_or_refuses_without_a_request() {
    let mut wrong = Vec::new();
    for c in cases() {
        let server = server_serving("unused").await;
        let admin = AdminClient::new(
            &config(&server),
            reqwest::Client::new(),
            Arc::new(Fixed(c.token.clone())),
        );
        let label = format!("{} via raw().get", c.id);
        match (admin.raw().get(None).await, &c.sent) {
            (Ok(_), Some(sent)) => check_sent(&mut wrong, &label, &server, sent).await,
            (Err(e), None) if refused_raw(&e) => {
                let rendered = [e.to_string(), format!("{e:?}")];
                check_refused(&mut wrong, &label, &server, &rendered, c.canary).await;
            }
            (got, _) => {
                let n = received(&server, ADMIN_PATH).await.len();
                let want = match c.sent.as_deref() {
                    Some(s) => format!("Ok with `Bearer {s:?}`"),
                    None => format!("HttpFailure {{ status: 401, text: …{REFUSED:?} }}"),
                };
                wrong.push(format!(
                    "{label}: got {:?} (admin requests {n}), want {want}",
                    got.map(|_| "Ok")
                ));
            }
        }
    }
    report("raw() (injected provider)", &wrong);
}

/// SDK 의 캐싱 공급자 — 뗀 값을 캐시하고(두 번째 호출은 IdP 에 묻지 않는다), 거부한 값은 캐시하지 않는다(다시
/// 묻는다). 거부는 이 레인의 「쓸 수 없는 부여」 오류 `Auth`(`client-credentials failed`)다.
#[tokio::test]
async fn sdk_provider_caches_the_trimmed_token_and_never_a_refused_one() {
    let mut wrong = Vec::new();
    for c in cases() {
        let server = server_serving(&c.token).await;
        let provider = ClientCredentialsTokenProvider::new(config(&server), reqwest::Client::new());
        let first = provider.access_token().await;
        let second = provider.access_token().await;
        let grants = received(&server, TOKEN_PATH).await.len();
        let label = format!("{} via ClientCredentialsTokenProvider", c.id);
        match (&c.sent, &first, &second) {
            (Some(sent), Ok(a), Ok(b)) if a == sent && b == sent => {
                if grants != 1 {
                    wrong.push(format!("{label}: {grants} grants, want 1 (cached)"));
                }
            }
            (None, Err(KeycloakError::Auth { .. }), Err(KeycloakError::Auth { .. })) => {
                if grants != 2 {
                    wrong.push(format!("{label}: {grants} grants, want 2 (not cached)"));
                }
                for e in [&first, &second]
                    .into_iter()
                    .filter_map(|r| r.as_ref().err())
                {
                    let rendered = [e.to_string(), format!("{e:?}")];
                    if !c.canary.is_empty() && rendered.iter().any(|r| r.contains(c.canary)) {
                        wrong.push(format!("{label}: error quotes the token: {rendered:?}"));
                    }
                }
            }
            _ => wrong.push(format!(
                "{label}: got {first:?} then {second:?} ({grants} grants), want {}",
                c.sent
                    .as_deref()
                    .map_or("Auth twice, 2 grants".into(), |s| format!(
                        "Ok({s:?}) twice, 1 grant"
                    ))
            )),
        }
    }
    report("ClientCredentialsTokenProvider", &wrong);
}

/// 기본 경로 — `KeycloakClient` 의 캐싱 공급자가 먼저 거르므로, 거부한 토큰이면 파사드는 토큰 실패의 401
/// (`Admin(Other { status: 401 })`), `raw()` 는 `HttpFailure { status: 401 }` 이고 admin 요청은 없다.
#[tokio::test]
async fn default_client_sends_the_trimmed_b64token_or_refuses_without_a_request() {
    let mut wrong = Vec::new();
    for c in cases() {
        let server = server_serving(&c.token).await;
        let client = KeycloakClient::new(config(&server)).expect("client");
        let facade = client.admin().list_realms().await;
        let raw = client.admin().raw().get(None).await;
        let label = format!("{} via KeycloakClient", c.id);
        match (&c.sent, &facade, &raw) {
            (Some(sent), Ok(_), Ok(_)) => {
                let want = Some(format!("Bearer {sent}").into_bytes());
                let got = received(&server, ADMIN_PATH).await;
                if got != vec![want.clone(), want] {
                    wrong.push(format!(
                        "{label}: expected two `Bearer {sent:?}`, got {got:?}"
                    ));
                }
            }
            (
                None,
                Err(KeycloakError::Admin(AdminError::Other { status: 401 })),
                Err(RawKeycloakError::HttpFailure { status: 401, .. }),
            ) => {
                let n = received(&server, ADMIN_PATH).await.len();
                if n != 0 {
                    wrong.push(format!("{label}: {n} admin request(s) reached the server"));
                }
            }
            _ => {
                let n = received(&server, ADMIN_PATH).await.len();
                wrong.push(format!(
                    "{label}: facade {:?} · raw {:?} (admin requests {n})",
                    facade.as_ref().map(|_| "Ok"),
                    raw.as_ref().map(|_| "Ok")
                ));
            }
        }
    }
    report("KeycloakClient (default provider)", &wrong);
}
