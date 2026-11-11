//! SDK error hierarchy — errors from the underlying crates are converted into this enum at the boundary.
use thiserror::Error;

pub type Result<T> = std::result::Result<T, KeycloakError>;

#[derive(Debug, Error)]
#[non_exhaustive]
pub enum KeycloakError {
    #[error("configuration error: {0}")]
    Config(String),
    #[error("authentication error: {message}")]
    Auth {
        message: String,
        /// The RFC 6749 §5.2 `error` **code only** (e.g. `invalid_grant`) — `None` when it is not code-shaped.
        /// ⚠️ `error_description` and `error_uri` are not carried: they are the server's free-form prose and can echo
        /// back a token it received (`tests/hostile_token_response.rs`).
        oauth_error: Option<String>,
    },
    #[error("transport error: {0}")]
    Transport(String),
    #[error("admin error: {0}")]
    Admin(#[from] AdminError),
    #[error("token validation error: {0}")]
    TokenValidation(String),
}

#[derive(Debug, Error)]
pub enum AdminError {
    #[error("not found")]
    NotFound,
    #[error("conflict")]
    Conflict,
    #[error("forbidden")]
    Forbidden,
    #[error("admin HTTP {status}")]
    Other { status: u16 },
}

impl KeycloakError {
    /// Maps an HTTP status code (u16) to an admin error (the single point for every admin boundary conversion).
    pub fn from_admin_status(status: u16) -> Self {
        let inner = match status {
            404 => AdminError::NotFound,
            409 => AdminError::Conflict,
            403 => AdminError::Forbidden,
            _ => AdminError::Other { status },
        };
        KeycloakError::Admin(inner)
    }
}

/// 서버 오류 본문의 `error` 를 **코드 모양이고 그 요청이 보낸 비밀(`sent`)과 겹치지 않을 때만** `oauth_error` 로
/// 옮긴다(토큰·provider 두 경로 공용). RFC 6749 §5.2 와 등록된 확장 코드는 전부 소문자를 `_` 로 이은 것이다
/// (`invalid_grant`·`slow_down`).
/// ⚠️ 그 모양이 아닌 값은 코드가 아니라 서버의 자유 서술이다 — 받은 토큰을 `error` 자리에 되울린 응답이
/// `{:?}` 로 원문 그대로 찍혔다(실측 2026-09-26, `tests/hostile_token_response.rs` 의 `e3`). ⚠️ 소문자뿐인 시크릿은
/// 그 모양이다 — 되울린 `echoedlowersecret` 이 `oauth_error` 와 `{:?}` 에 실렸다(실측 2026-11-11,
/// `tests/oauth_error_code_echo.rs`). 겹침(어느 쪽도 다른 쪽을 품지 않음)은 잘린 · 덧붙은 되울림도 막고, 그 값은
/// 비밀이 등록 코드의 조각일 때(`client`) 그 코드를 잃는 것이다. 빈 비밀(공개 클라이언트)은 비교하지 않는다 —
/// 빈 문자열은 모든 코드의 조각이다.
pub(crate) fn oauth_error_code(raw: &str, sent: &[&str]) -> Option<String> {
    let code_shaped = raw.len() <= 64
        && raw
            .split('_')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_lowercase()));
    let echoed = sent
        .iter()
        .any(|secret| !secret.is_empty() && (raw.contains(secret) || secret.contains(raw)));
    (code_shaped && !echoed).then(|| raw.to_string())
}

/// 토큰·introspection 레인의 reqwest 오류 → 계급(auth 와 provider 두 경로 공용). 리다이렉트 실패(소비자가 준 클라이언트가
/// 따라가다 한도·정책에 걸림)는 3xx 응답들의 머리(상태와 Location)가 왔고 클라이언트가 그만둔 것이라 `Auth` 다 — 공유 클라이언트가
/// 3xx 를 그대로 받아 `Auth` 로 내는 것과 같다. reqwest 는 따라간 3xx 의 본문을 읽지 않으므로 그 본문이 끊겼어도 같다. 나머지(연결 ·
/// 타임아웃 · 본문 도중 끊김 · 요청 생성)는 `Transport` 다. ⚠️ 남은 틈: 따라가는 클라이언트가 http(s) 아닌 Location 을 만나면
/// reqwest 는 리다이렉트가 아니라 빌더 오류를 낸다(`redirect.rs:320`) — 그 3xx 는 `Transport` 로 남는다(#951 둘째 레그).
/// ⚠️ **`is_decode()` 로 가르지 말 것** — reqwest 0.12 의 `chunk()`·`bytes()` 는 본문 오류를 **전부** Decode 로 싼다
/// (`response.rs:296`·`:321`): Content-Length 보다 짧게 끊긴 본문도, 본문 도중 타임아웃도 `is_decode()` 다(단위 시험이 잰다).
/// 그래서 소비자 빌드가 켠 압축 기능(`gzip` 등) 아래의 깨진 Content-Encoding 도 `Transport` 로 남는다 — 틀이 깨진 본문과 같은
/// 계급이다(#951 독립 레그가 그 구성을 찾았다).
pub(crate) fn token_http_error(e: &reqwest::Error, message: String) -> KeycloakError {
    if e.is_redirect() {
        KeycloakError::Auth {
            message,
            oauth_error: None,
        }
    } else {
        KeycloakError::Transport(message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oauth_error_code_keeps_only_code_shaped_values() {
        for code in [
            "invalid_grant",
            "unauthorized_client",
            "slow_down",
            "invalid_dpop_proof",
            "consent_required",
        ] {
            assert_eq!(oauth_error_code(code, &[]).as_deref(), Some(code));
        }
        for not_code in [
            "",
            "E3-ERRCODE-CANARY-9K4D",
            "eyJhbGciOiJSUzI1NiJ9.e30.sig",
            "invalid__grant",
            "_invalid",
            "invalid_",
            "invalid grant",
            "abc123",
            &"a".repeat(65),
        ] {
            assert_eq!(oauth_error_code(not_code, &[]), None, "{not_code:?}");
        }
    }

    #[test]
    fn oauth_error_code_withholds_a_value_that_overlaps_a_secret_the_request_sent() {
        let cases: [(&str, &[&str], Option<&str>); 7] = [
            ("invalid_grant", &["s3cret-Value"], Some("invalid_grant")),
            ("mysecret", &["mysecret"], None),
            ("mysecret_x", &["mysecret"], None), // extended echo
            ("mysec", &["mysecret"], None),      // truncated echo
            ("mysecret", &["", "other", "mysecret"], None),
            ("invalid_grant", &["", ""], Some("invalid_grant")), // an empty secret is not compared
            ("invalid_client", &["client"], None), // the price: a secret that is a piece of the code
        ];
        for (raw, sent, want) in cases {
            assert_eq!(
                oauth_error_code(raw, sent).as_deref(),
                want,
                "{raw:?} {sent:?}"
            );
        }
    }

    /// 계급은 reqwest 가 실제로 낸 오류로 잰다 — 리다이렉트 한도는 `Auth`, 연결 거부 · 끊긴 본문 · 본문 도중 타임아웃은
    /// `Transport`. ⚠️ 끊긴 본문과 본문 도중 타임아웃이 **`is_decode()`** 라는 것도 여기서 잰다 — 그래서 판정이 그것을 안 본다.
    /// 한 번 그것으로 갈랐다가 이 대조군이 끊긴 본문을 `Auth` 로 잡아냈다(#951).
    #[tokio::test]
    async fn token_http_error_classes_real_reqwest_errors() {
        use std::time::Duration;
        use wiremock::matchers::path;
        use wiremock::{Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        Mock::given(path("/loop"))
            .respond_with(
                ResponseTemplate::new(307)
                    .insert_header("Location", format!("{}/loop", server.uri())),
            )
            .mount(&server)
            .await;
        let redirect = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::limited(2))
            .build()
            .expect("client")
            .get(format!("{}/loop", server.uri()))
            .send()
            .await
            .expect_err("redirect loop");
        let connect = reqwest::get("http://127.0.0.1:1")
            .await
            .expect_err("refused");
        // 머리는 오고 본문이 Content-Length 보다 짧다 — 하나는 바로 닫고(끊김), 하나는 쥐고 멈춘다(타임아웃).
        let partial = |hold: Duration| {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
            let addr = listener.local_addr().expect("addr");
            let fake = std::thread::spawn(move || {
                use std::io::{Read, Write};
                let (mut s, _) = listener.accept().expect("accept");
                let _ = s.read(&mut [0u8; 4096]);
                let _ = s.write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{\"a\"",
                );
                std::thread::sleep(hold);
            });
            (format!("http://{addr}/"), fake)
        };
        let (url, fake) = partial(Duration::ZERO);
        let cut = reqwest::get(url)
            .await
            .expect("head")
            .bytes()
            .await
            .expect_err("cut body");
        fake.join().expect("fake");
        let (url, fake) = partial(Duration::from_secs(2));
        let stalled = reqwest::Client::builder()
            .timeout(Duration::from_millis(300))
            .build()
            .expect("client")
            .get(url)
            .send()
            .await
            .expect("head")
            .bytes()
            .await
            .expect_err("stalled body");
        fake.join().expect("fake");
        assert!(
            redirect.is_redirect() && connect.is_connect() && stalled.is_timeout(),
            "대조군이 의도한 갈래가 아니다"
        );
        assert!(
            cut.is_decode() && stalled.is_decode(),
            "reqwest 가 본문 오류를 Decode 로 싸지 않게 됐다 — `token_http_error` 의 주석을 다시 본다"
        );
        let class = |e: &reqwest::Error| match token_http_error(e, String::new()) {
            KeycloakError::Auth {
                oauth_error: None, ..
            } => "Auth",
            KeycloakError::Transport(_) => "Transport",
            other => panic!("{other:?}"),
        };
        assert_eq!(
            [
                class(&redirect),
                class(&connect),
                class(&cut),
                class(&stalled)
            ],
            ["Auth", "Transport", "Transport", "Transport"]
        );
    }

    #[test]
    fn maps_admin_status() {
        assert!(matches!(
            KeycloakError::from_admin_status(404),
            KeycloakError::Admin(AdminError::NotFound)
        ));
        assert!(matches!(
            KeycloakError::from_admin_status(409),
            KeycloakError::Admin(AdminError::Conflict)
        ));
        assert!(matches!(
            KeycloakError::from_admin_status(403),
            KeycloakError::Admin(AdminError::Forbidden)
        ));
        assert!(matches!(
            KeycloakError::from_admin_status(500),
            KeycloakError::Admin(AdminError::Other { status: 500 })
        ));
    }

    #[test]
    fn auth_error_display_omits_secret_and_field_carries_oauth_error() {
        let e = KeycloakError::Auth {
            message: "bad".into(),
            oauth_error: Some("invalid_client".into()),
        };
        // Display은 message만 노출(oauth_error는 프로그램 접근용) — thiserror #[error] 형식 검증.
        assert_eq!(e.to_string(), "authentication error: bad");
        // 변형만이 아니라 oauth_error의 정확한 값이 보존되는지 검증한다(감사: vacuous 정정).
        let KeycloakError::Auth { oauth_error, .. } = &e else {
            panic!("expected Auth variant");
        };
        assert_eq!(oauth_error.as_deref(), Some("invalid_client"));
    }
}
