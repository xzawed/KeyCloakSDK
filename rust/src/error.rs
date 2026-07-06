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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn auth_carries_oauth_error() {
        let e = KeycloakError::Auth {
            message: "bad".into(),
            oauth_error: Some("invalid_client".into()),
        };
        assert!(matches!(
            e,
            KeycloakError::Auth {
                oauth_error: Some(_),
                ..
            }
        ));
    }
}
