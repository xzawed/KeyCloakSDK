//! TokenProvider — §4 동형 async 추상화. admin은 이 trait로만 토큰을 받는다.
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::oidc::OidcEndpoints;
use crate::tokens::TokenSet;
use async_trait::async_trait;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

#[async_trait]
pub trait TokenProvider: Send + Sync {
    async fn access_token(&self) -> Result<String>;
}

pub struct ClientCredentialsTokenProvider {
    config: KeycloakConfig,
    token_url: String,
    http: reqwest::Client,
    cache: Mutex<Option<TokenSet>>,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl ClientCredentialsTokenProvider {
    pub fn new(config: KeycloakConfig, http: reqwest::Client) -> Self {
        let token_url = OidcEndpoints::new(&config).token();
        Self {
            config,
            token_url,
            http,
            cache: Mutex::new(None),
        }
    }

    async fn fetch(&self) -> Result<TokenSet> {
        // config.scopes를 공백 조인해 그대로 전달(사용자 커스텀 스코프 반영). 비면 "openid" 폴백.
        let scope = if self.config.scopes.is_empty() {
            "openid".to_string()
        } else {
            self.config.scopes.join(" ")
        };
        let params = [
            ("grant_type", "client_credentials"),
            ("client_id", self.config.client_id.as_str()),
            (
                "client_secret",
                self.config.client_secret.as_deref().unwrap_or(""),
            ),
            ("scope", scope.as_str()),
        ];
        let resp = self
            .http
            .post(&self.token_url)
            .form(&params)
            .send()
            .await
            .map_err(|e| KeycloakError::Transport(format!("token endpoint: {e}")))?;
        let status = resp.status();
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| KeycloakError::Transport(format!("token response: {e}")))?;
        if !status.is_success() || body.get("access_token").is_none() {
            let oauth = body
                .get("error")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            return Err(KeycloakError::Auth {
                message: "client-credentials failed".into(),
                oauth_error: oauth,
            });
        }
        let expires_in = body
            .get("expires_in")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0);
        Ok(TokenSet {
            access_token: body["access_token"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
            token_type: body
                .get("token_type")
                .and_then(|v| v.as_str())
                .unwrap_or("Bearer")
                .to_string(),
            expires_in,
            refresh_token: body
                .get("refresh_token")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            id_token: None,
            scope: body
                .get("scope")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            expires_at: if expires_in > 0 {
                Some(now_secs() + expires_in)
            } else {
                None
            },
        })
    }
}

#[async_trait]
impl TokenProvider for ClientCredentialsTokenProvider {
    async fn access_token(&self) -> Result<String> {
        let mut guard = self.cache.lock().await; // single-flight: 동시 호출 직렬화
        if let Some(ts) = guard.as_ref()
            && !ts.is_expired(now_secs(), self.config.clock_skew)
        {
            return Ok(ts.access_token.clone());
        }
        let ts = self.fetch().await?;
        let token = ts.access_token.clone();
        *guard = Some(ts);
        Ok(token)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::KeycloakConfig;
    use wiremock::matchers::{body_string_contains, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn cfg(server: &str) -> KeycloakConfig {
        KeycloakConfig::new(server, "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s")
    }

    #[tokio::test]
    async fn fetches_and_caches() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "AT", "token_type": "Bearer", "expires_in": 300
            })))
            .expect(1) // 두 번째 access_token()은 캐시 → 네트워크 1회만
            .mount(&server)
            .await;
        let p = ClientCredentialsTokenProvider::new(cfg(&server.uri()), reqwest::Client::new());
        assert_eq!(p.access_token().await.unwrap(), "AT");
        assert_eq!(p.access_token().await.unwrap(), "AT");
    }

    #[tokio::test]
    async fn fetches_with_custom_scopes() {
        // config.scopes가 form body의 scope 파라미터로 실제 전달되는지 검증(no-op 아님을 증명).
        // application/x-www-form-urlencoded는 공백을 '+'로 인코딩 → "scope=openid+profile".
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .and(body_string_contains("scope=openid+profile"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "AT2", "token_type": "Bearer", "expires_in": 300
            })))
            .expect(1)
            .mount(&server)
            .await;
        let mut config = cfg(&server.uri());
        config.scopes = vec!["openid".to_string(), "profile".to_string()];
        let p = ClientCredentialsTokenProvider::new(config, reqwest::Client::new());
        assert_eq!(p.access_token().await.unwrap(), "AT2");
    }

    #[tokio::test]
    async fn oauth_error_mapped() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(
                ResponseTemplate::new(401)
                    .set_body_json(serde_json::json!({"error":"invalid_client"})),
            )
            .mount(&server)
            .await;
        let p = ClientCredentialsTokenProvider::new(cfg(&server.uri()), reqwest::Client::new());
        // 변형만이 아니라 응답의 OAuth error 코드가 실제로 매핑됐는지 검증한다(감사: vacuous 정정).
        match p.access_token().await {
            Err(KeycloakError::Auth { oauth_error, .. }) => {
                assert_eq!(oauth_error.as_deref(), Some("invalid_client"));
            }
            other => panic!("expected Auth with mapped oauth_error, got {other:?}"),
        }
    }
}
