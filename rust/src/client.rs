//! 통합 진입점 — 공유 reqwest 1개(SSRF·타임아웃·TLS)를 auth·jwks·admin에 주입.
use crate::admin::AdminClient;
use crate::auth::AuthClient;
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::jwks::JwksStore;
use crate::jwt::JwtValidator;
use crate::oidc::OidcEndpoints;
use crate::token_provider::{ClientCredentialsTokenProvider, TokenProvider};
use keycloak::prelude::reqwest;
use std::sync::Arc;

pub struct KeycloakClient {
    auth: Arc<AuthClient>,
    admin: AdminClient,
}

fn build_http(config: &KeycloakConfig) -> Result<reqwest::Client> {
    // 공유 reqwest — SSRF 하드닝(redirect none) + 타임아웃 + rustls(TLS on).
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(config.connect_timeout)
        .timeout(config.read_timeout)
        .build()
        .map_err(|e| KeycloakError::Config(format!("http client: {e}")))
}

impl KeycloakClient {
    pub fn new(config: KeycloakConfig) -> Result<Self> {
        let endpoints = OidcEndpoints::new(&config);
        let http = build_http(&config)?;

        let jwks = JwksStore::new(endpoints.jwks(), http.clone(), config.jwks_min_refetch_secs);
        let validator = JwtValidator::new(&config, &endpoints, jwks)?;
        let auth = Arc::new(AuthClient::new(
            config.clone(),
            OidcEndpoints::new(&config),
            http.clone(),
            validator,
        )?);
        // admin은 캐싱 client-credentials TokenProvider를 쓴다(§4 캐시 불변식 — 만료 전 재사용·
        // single-flight). 우회 없이 AuthClient를 주입하면 admin 호출마다 토큰을 재발급(무캐시)한다.
        // 공유 `http`를 그대로 써 커넥션 풀은 유지한다.
        let admin_token_provider: Arc<dyn TokenProvider> = Arc::new(
            ClientCredentialsTokenProvider::new(config.clone(), http.clone()),
        );
        let admin = AdminClient::new(&config, http.clone(), admin_token_provider);
        Ok(Self { auth, admin })
    }

    pub fn auth(&self) -> &AuthClient {
        &self.auth
    }
    pub fn admin(&self) -> &AdminClient {
        &self.admin
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn builds_client() {
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s");
        let client = KeycloakClient::new(cfg).unwrap();
        // auth/admin 접근자가 동작(네트워크 없음 — 조립만 검증)
        let _ = client.auth();
        let _ = client.admin();
    }

    /// 공유 HTTP 클라이언트가 3xx를 따라가지 않는다(SSRF 하드닝 회귀).
    /// `.redirect(Policy::none())` 가 빠지면 reqwest 기본 정책이 최대 10회 따라가
    /// status 200 + /redirect-target 히트가 되어 이 테스트가 실패해야 한다.
    #[tokio::test]
    async fn shared_http_client_does_not_follow_redirects() {
        let server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/start"))
            .respond_with(
                ResponseTemplate::new(302)
                    .insert_header("location", format!("{}/redirect-target", server.uri())),
            )
            .expect(1)
            .mount(&server)
            .await;

        Mock::given(method("GET"))
            .and(path("/redirect-target"))
            .respond_with(ResponseTemplate::new(200))
            .expect(0)
            .mount(&server)
            .await;

        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s");
        let http = build_http(&cfg).unwrap();

        let resp = http
            .get(format!("{}/start", server.uri()))
            .send()
            .await
            .expect("request should complete without following the redirect");
        assert_eq!(
            resp.status().as_u16(),
            302,
            "redirect must surface to the caller, not be followed"
        );

        // drop-time expect(0) 외에 명시적으로 경로 부재를 확인한다.
        let received = server
            .received_requests()
            .await
            .expect("received_requests available");
        assert!(
            received.iter().all(|r| r.url.path() != "/redirect-target"),
            "redirect target must never be requested; got paths: {:?}",
            received.iter().map(|r| r.url.path()).collect::<Vec<_>>()
        );
    }
}
