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
        // ⚠️ 공개 클라이언트에는 `client_secret` 를 **싣지 않는다**(빈 값도 아니다). `auth.rs` 의
        // 같은 계약과 함께 움직인다 — 사본 중 하나만 고치는 것이 이 저장소가 반복해 겪은 부류다.
        // (client_credentials 자체는 기밀 클라이언트용이지만, 빈 시크릿을 보내면 서버가 내는
        //  오류가 「시크릿이 틀렸다」로 바뀌어 오설정 진단이 어긋난다.)
        let mut params: Vec<(&str, &str)> = vec![
            ("grant_type", "client_credentials"),
            ("client_id", self.config.client_id.as_str()),
            ("scope", scope.as_str()),
        ];
        if let Some(secret) = self.config.client_secret.as_deref() {
            params.push(("client_secret", secret));
        }
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
        // ⚠️ **존재 검사는 타입 검사가 아니다.** 예전에는 `is_none()` 만 봐서 `access_token`
        // 이 숫자·객체·null 이어도 통과했고, 아래 `as_str().unwrap_or_default()` 가 그것을
        // **빈 문자열**로 만들어 호출자에게 성공을 돌려줬다. 그 빈 토큰은 `expires_at` 까지
        // 캐시되므로 그 창 내내 admin 호출마다 401 이 난다.
        let access_token = body
            .get("access_token")
            .and_then(serde_json::Value::as_str)
            .filter(|s| !s.is_empty());
        let Some(access_token) = access_token.filter(|_| status.is_success()) else {
            let oauth = body
                .get("error")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            return Err(KeycloakError::Auth {
                message: "client-credentials failed".into(),
                oauth_error: oauth,
            });
        };
        let expires_in = body
            .get("expires_in")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0);
        Ok(TokenSet {
            access_token: access_token.to_string(),
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

    /// ⚠️ **존재 검사는 타입 검사가 아니다.** `access_token` 이 문자열이 아니면
    /// `as_str().unwrap_or_default()` 가 그것을 **빈 문자열**로 만들고, 호출자는 성공을
    /// 받는다 — 그 빈 토큰이 `expires_at` 까지 캐시되므로 그 창 내내 admin 호출마다 401 이
    /// 난다(패닉도 재시도도 아니라 조용한 반복 실패다).
    ///
    /// 아홉 언어 전수 측정에서 **다섯이 이 부류**였다(java·kotlin·node·go 는 이미 거부).
    #[tokio::test]
    async fn non_string_access_token_is_rejected() {
        for bad in [
            serde_json::json!(12345),
            serde_json::json!(null),
            serde_json::json!({"a": 1}),
            serde_json::json!(""),
        ] {
            let server = MockServer::start().await;
            Mock::given(method("POST"))
                .and(path("/realms/it-realm/protocol/openid-connect/token"))
                .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "access_token": bad, "token_type": "Bearer", "expires_in": 300
                })))
                .mount(&server)
                .await;
            let p = ClientCredentialsTokenProvider::new(cfg(&server.uri()), reqwest::Client::new());
            match p.access_token().await {
                Err(KeycloakError::Auth { .. }) => {}
                other => panic!("expected Auth error for access_token={bad}, got {other:?}"),
            }
        }
    }

    /// 음성 대조군 — 정상 응답은 그대로 통과한다(위 거부가 과녁을 넘지 않았다).
    #[tokio::test]
    async fn valid_access_token_still_accepted() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "AT", "token_type": "Bearer", "expires_in": 300
            })))
            .mount(&server)
            .await;
        let p = ClientCredentialsTokenProvider::new(cfg(&server.uri()), reqwest::Client::new());
        assert_eq!(p.access_token().await.unwrap(), "AT");
    }

    // ⚠️ `auth.rs` 의 같은 계약과 함께 움직인다 — 사본 중 하나만 고치면 그쪽만 초록이 된다.
    // 빈 `client_secret=` 를 보내면 서버가 내는 오류가 「시크릿이 틀렸다」로 바뀌어, 실제 원인인
    // 「이 클라이언트는 client_credentials 를 쓸 수 없다」가 가려진다.
    #[tokio::test]
    async fn public_client_omits_client_secret_field() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "AT", "token_type": "Bearer", "expires_in": 300
            })))
            .mount(&server)
            .await;
        // ⚠️ `with_client_secret` 를 부르지 않는다 — 그것이 공개 클라이언트다.
        let config = KeycloakConfig::new(server.uri(), "it-realm", "it-client").unwrap();
        let p = ClientCredentialsTokenProvider::new(config, reqwest::Client::new());
        assert_eq!(p.access_token().await.unwrap(), "AT");
        let reqs = server
            .received_requests()
            .await
            .expect("received_requests available");
        let body = String::from_utf8_lossy(&reqs[0].body).to_string();
        assert!(
            !body.contains("client_secret"),
            "공개 클라이언트 본문에 client_secret 이 실렸다: {body}"
        );
        assert!(body.contains("client_id=it-client"), "본문: {body}");
    }

    // 대조군 — 시크릿이 있으면 그대로 실려야 한다.
    #[tokio::test]
    async fn confidential_client_still_sends_client_secret_field() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "AT", "token_type": "Bearer", "expires_in": 300
            })))
            .mount(&server)
            .await;
        let p = ClientCredentialsTokenProvider::new(cfg(&server.uri()), reqwest::Client::new());
        assert_eq!(p.access_token().await.unwrap(), "AT");
        let reqs = server
            .received_requests()
            .await
            .expect("received_requests available");
        let body = String::from_utf8_lossy(&reqs[0].body).to_string();
        assert!(body.contains("client_secret=s"), "본문: {body}");
    }
}
