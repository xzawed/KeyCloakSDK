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

/// 서버 오류 본문의 `error` 를 **코드 모양일 때만** `oauth_error` 로 옮긴다(토큰·provider 두 경로 공용).
/// RFC 6749 §5.2 와 등록된 확장 코드는 전부 소문자를 `_` 로 이은 것이다(`invalid_grant`·`slow_down`).
/// ⚠️ 그 모양이 아닌 값은 코드가 아니라 서버의 자유 서술이다 — 받은 토큰을 `error` 자리에 되울린 응답이
/// `{:?}` 로 원문 그대로 찍혔다(실측 2026-09-26, `tests/hostile_token_response.rs` 의 `e3`).
pub(crate) fn oauth_error_code(raw: &str) -> Option<String> {
    let code_shaped = raw.len() <= 64
        && raw
            .split('_')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_lowercase()));
    code_shaped.then(|| raw.to_string())
}

/// 토큰·introspection 레인의 reqwest 오류 → 계급(auth 와 provider 두 경로 공용). 응답이 **끝까지 왔는데** reqwest 가 쓸 수
/// 없다고 낸 것은 `Auth` 다 — 해독 실패(소비자 빌드가 켠 `gzip` 같은 기능 아래의 깨진 Content-Encoding)와 리다이렉트 실패
/// (소비자가 준 클라이언트가 따라가다 한도·정책에 걸림). 나머지(연결 · 타임아웃 · 본문 도중 끊김 · 요청 생성)는 `Transport` 다.
/// ⚠️ 본문이 도중에 끊긴 것은 해독기 안에서 나도 `is_decode()` 가 아니다 — reqwest 의 `decode_io` 가 본문 오류를 꺼내 준다.
pub(crate) fn token_http_error(e: &reqwest::Error, message: String) -> KeycloakError {
    if e.is_decode() || e.is_redirect() {
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
            assert_eq!(oauth_error_code(code).as_deref(), Some(code));
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
            assert_eq!(oauth_error_code(not_code), None, "{not_code:?}");
        }
    }

    /// 계급은 reqwest 가 실제로 낸 오류로 잰다 — 해독 실패(`json()` 의 Decode 계열)와 리다이렉트 한도는 `Auth`, 연결 거부는
    /// `Transport`. ⚠️ gzip 해독 실패도 같은 Decode 계열이지만, 이 크레이트는 그 기능을 켜지 않아 여기서는 못 만든다.
    #[tokio::test]
    async fn token_http_error_classes_real_reqwest_errors() {
        use wiremock::matchers::path;
        use wiremock::{Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        Mock::given(path("/not-json"))
            .respond_with(ResponseTemplate::new(200).set_body_raw("not json", "application/json"))
            .mount(&server)
            .await;
        Mock::given(path("/loop"))
            .respond_with(
                ResponseTemplate::new(307)
                    .insert_header("Location", format!("{}/loop", server.uri())),
            )
            .mount(&server)
            .await;
        let decode = reqwest::get(format!("{}/not-json", server.uri()))
            .await
            .expect("response")
            .json::<serde_json::Value>()
            .await
            .expect_err("not json");
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
        assert!(
            decode.is_decode() && redirect.is_redirect() && connect.is_connect(),
            "대조군이 의도한 갈래가 아니다"
        );
        let class = |e: &reqwest::Error| match token_http_error(e, String::new()) {
            KeycloakError::Auth {
                oauth_error: None, ..
            } => "Auth",
            KeycloakError::Transport(_) => "Transport",
            other => panic!("{other:?}"),
        };
        assert_eq!(
            [class(&decode), class(&redirect), class(&connect)],
            ["Auth", "Auth", "Transport"]
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
