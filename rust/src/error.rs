//! SDK 오류 계급 — 하위 crate 오류는 경계에서 이 enum으로 변환된다.
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
        /// RFC 6749 §5.2 의 `error` **코드만**(예: `invalid_grant`) — 코드 모양이 아니면 `None`.
        /// ⚠️ `error_description`·`error_uri` 는 서버의 자유 서술이라 받은 토큰을 되울릴 수 있어 싣지
        /// 않는다(`tests/hostile_token_response.rs`).
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
    /// HTTP 상태코드(u16)를 admin 오류로 매핑(모든 admin 경계 변환의 단일 지점).
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
