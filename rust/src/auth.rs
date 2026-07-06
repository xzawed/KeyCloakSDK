//! AuthClient — openidconnect(auth flows) 래핑 + introspect/logout 손수. 커버리지 omit(네트워크 경계).
//!
//! `openidconnect` 4.0의 `CoreClient`는 6개의 엔드포인트 typestate 파라미터를 갖는다. 여기서는
//! auth/introspection/token 을 명시적으로 세팅해 exchange 빌더(`exchange_*`·`introspect`)가
//! `?` 없이 호출 가능한(infallible) 구체 타입 `KcOidcClient`를 얻는다. id_token은 openidconnect의
//! 자체 검증기 대신 강화된 `JwtValidator`로 검증하므로 `JsonWebKeySet`은 비워 둔다.
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::jwt::JwtValidator;
use crate::oidc::OidcEndpoints;
use crate::token_provider::TokenProvider;
use crate::tokens::{AuthorizationRequest, IntrospectionResult, TokenSet, ValidatedToken};
use async_trait::async_trait;
use openidconnect::core::{CoreClient, CoreJsonWebKey, CoreResponseType, CoreTokenResponse};
use openidconnect::{
    AccessToken, AuthUrl, AuthenticationFlow, AuthorizationCode, ClientId, ClientSecret, CsrfToken,
    EndpointNotSet, EndpointSet, IntrospectionUrl, IssuerUrl, JsonWebKeySet, Nonce,
    OAuth2TokenResponse, PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, RefreshToken,
    RequestTokenError, Scope, TokenIntrospectionResponse, TokenResponse, TokenUrl,
};
use std::time::{SystemTime, UNIX_EPOCH};

// 수동 EndpointSet 구성으로 exchange 빌더를 infallible하게 만든다.
// CoreClient 타입 파라미터 순서: auth, device, introspection, revocation, token, userinfo.
// auth=Set · introspection=Set · token=Set (device/revocation/userinfo=NotSet).
type KcOidcClient = CoreClient<
    EndpointSet,    // HasAuthUrl
    EndpointNotSet, // HasDeviceAuthUrl
    EndpointSet,    // HasIntrospectionUrl
    EndpointNotSet, // HasRevocationUrl
    EndpointSet,    // HasTokenUrl
    EndpointNotSet, // HasUserInfoUrl
>;

pub struct AuthClient {
    config: KeycloakConfig,
    endpoints: OidcEndpoints,
    http: reqwest::Client,
    oidc: KcOidcClient,
    validator: JwtValidator,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl AuthClient {
    /// openidconnect 클라이언트를 조립한다. URL 파싱 실패는 `KeycloakError::Config`로 변환.
    /// 공유 `http`(TLS·타임아웃·SSRF 정책이 주입된)는 그대로 사용하고 자체 클라이언트를 만들지 않는다.
    pub fn new(
        config: KeycloakConfig,
        endpoints: OidcEndpoints,
        http: reqwest::Client,
        validator: JwtValidator,
    ) -> Result<Self> {
        let base = endpoints.issuer();
        let oidc = CoreClient::new(
            ClientId::new(config.client_id.clone()),
            IssuerUrl::new(base.clone())
                .map_err(|e| KeycloakError::Config(format!("issuer url: {e}")))?,
            // 비어있는 JWKS: id_token 검증에 미사용(자체 JwtValidator가 access_token을 강화 검증).
            JsonWebKeySet::<CoreJsonWebKey>::new(Vec::new()),
        )
        .set_client_secret(ClientSecret::new(
            config.client_secret.clone().unwrap_or_default(),
        ))
        .set_auth_uri(
            AuthUrl::new(endpoints.authorization())
                .map_err(|e| KeycloakError::Config(format!("auth url: {e}")))?,
        )
        .set_token_uri(
            TokenUrl::new(endpoints.token())
                .map_err(|e| KeycloakError::Config(format!("token url: {e}")))?,
        )
        .set_introspection_url(
            IntrospectionUrl::new(endpoints.introspection())
                .map_err(|e| KeycloakError::Config(format!("introspect url: {e}")))?,
        )
        .set_redirect_uri(
            RedirectUrl::new(config.redirect_uri.clone().unwrap_or_else(|| base.clone()))
                .map_err(|e| KeycloakError::Config(format!("redirect uri: {e}")))?,
        );
        Ok(Self {
            config,
            endpoints,
            http,
            oidc,
            validator,
        })
    }

    /// Authorization Code + PKCE(S256) 요청 조립. CSRF state·PKCE verifier를 호출자에게 돌려준다.
    /// state 검증(콜백 대조)은 무상태이므로 호출자 책임(다른 SDK와 동형).
    pub fn create_authorization_request(&self) -> AuthorizationRequest {
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        // nonce는 openidconnect가 auth URL에 실어 Keycloak이 id_token에 담아 돌려주지만,
        // 이 SDK는 id_token을 openidconnect 검증기로 검증하지 않고(JwtValidator가 access_token만
        // 강화 검증) exchange_code에서 nonce 검증 단계를 밟지 않으므로 여기서 소비하지 않는다.
        // config.scopes를 반영(사용자 커스텀 스코프). 비면 "openid" 폴백.
        let scopes: Vec<Scope> = if self.config.scopes.is_empty() {
            vec![Scope::new("openid".to_string())]
        } else {
            self.config
                .scopes
                .iter()
                .map(|s| Scope::new(s.clone()))
                .collect()
        };
        let (url, csrf, _nonce) = self
            .oidc
            .authorize_url(
                AuthenticationFlow::<CoreResponseType>::AuthorizationCode,
                CsrfToken::new_random,
                Nonce::new_random,
            )
            .add_scopes(scopes)
            .set_pkce_challenge(challenge)
            .url();
        AuthorizationRequest {
            url: url.to_string(),
            state: csrf.secret().clone(),
            code_verifier: verifier.into_secret(),
        }
    }

    /// Authorization Code → 토큰 교환. PKCE verifier를 반드시 전달(S256 증명).
    pub async fn exchange_code(&self, code: &str, code_verifier: &str) -> Result<TokenSet> {
        let resp = self
            .oidc
            .exchange_code(AuthorizationCode::new(code.to_string()))
            .set_pkce_verifier(PkceCodeVerifier::new(code_verifier.to_string()))
            .request_async(&self.http)
            .await
            .map_err(map_token_err)?;
        Ok(to_token_set(&resp))
    }

    /// Client Credentials 흐름(admin 접착·서비스 계정).
    pub async fn client_credentials_token(&self) -> Result<TokenSet> {
        let resp = self
            .oidc
            .exchange_client_credentials()
            .request_async(&self.http)
            .await
            .map_err(map_token_err)?;
        Ok(to_token_set(&resp))
    }

    /// Refresh Token → 새 토큰 셋.
    pub async fn refresh(&self, refresh_token: &str) -> Result<TokenSet> {
        let rt = RefreshToken::new(refresh_token.to_string());
        let resp = self
            .oidc
            .exchange_refresh_token(&rt)
            .request_async(&self.http)
            .await
            .map_err(map_token_err)?;
        Ok(to_token_set(&resp))
    }

    /// access_token 검증을 강화된 `JwtValidator`에 위임(RS256 핀·iss·aud·exp·nbf·스큐·DoS-safe JWKS).
    pub async fn validate(&self, access_token: &str) -> Result<ValidatedToken> {
        self.validator.validate(access_token).await
    }

    /// RFC7662 introspection. openidconnect 빌더가 응답을 파싱 → `IntrospectionResult`로 경계 변환.
    pub async fn introspect(&self, token: &str) -> Result<IntrospectionResult> {
        let at = AccessToken::new(token.to_string());
        let resp = self
            .oidc
            .introspect(&at)
            .request_async(&self.http)
            .await
            .map_err(map_token_err)?;
        Ok(IntrospectionResult {
            active: resp.active(),
            username: resp.username().map(str::to_string),
            client_id: resp.client_id().map(|c| c.as_str().to_string()),
        })
    }

    /// 백채널 로그아웃(refresh_token 무효화). openidconnect에 빌더가 없어 공유 http로 손수 POST.
    /// 전송 실패만 오류로 표면화(back-channel best-effort — 다른 SDK와 동형).
    pub async fn logout(&self, refresh_token: &str) -> Result<()> {
        let params = [
            ("client_id", self.config.client_id.as_str()),
            (
                "client_secret",
                self.config.client_secret.as_deref().unwrap_or(""),
            ),
            ("refresh_token", refresh_token),
        ];
        self.http
            .post(self.endpoints.end_session())
            .form(&params)
            .send()
            .await
            .map_err(|e| KeycloakError::Transport(format!("logout: {e}")))?;
        Ok(())
    }
}

/// openidconnect 토큰 응답 → SDK `TokenSet`(하위 타입을 공개 API에서 은닉).
fn to_token_set(resp: &CoreTokenResponse) -> TokenSet {
    let expires_in = resp.expires_in().map(|d| d.as_secs()).unwrap_or(0);
    TokenSet {
        access_token: resp.access_token().secret().clone(),
        token_type: format!("{:?}", resp.token_type()),
        expires_in,
        refresh_token: resp.refresh_token().map(|r| r.secret().clone()),
        id_token: resp.id_token().map(|t| t.to_string()),
        scope: resp
            .scopes()
            .map(|s| s.iter().map(|x| x.as_str()).collect::<Vec<_>>().join(" ")),
        expires_at: if expires_in > 0 {
            Some(now_secs() + expires_in)
        } else {
            None
        },
    }
}

/// openidconnect `RequestTokenError` → `KeycloakError`. 서버 OAuth 오류는 `Auth`, 전송/파싱은 `Transport`.
/// (`.error()`는 `StandardErrorResponse`의 고유 메서드이므로 제네릭 T에서는 `Display`로 접근한다 —
/// `ErrorResponse: Display`가 이를 보장하며 출력은 "code: description" 형태로 오류코드를 포함한다.)
fn map_token_err<RE, T>(e: RequestTokenError<RE, T>) -> KeycloakError
where
    RE: std::error::Error + 'static,
    T: openidconnect::ErrorResponse + 'static,
{
    use openidconnect::RequestTokenError as RTE;
    match e {
        RTE::ServerResponse(resp) => KeycloakError::Auth {
            message: "token endpoint rejected".into(),
            oauth_error: Some(resp.to_string()),
        },
        RTE::Request(re) => KeycloakError::Transport(format!("token request: {re}")),
        other => KeycloakError::Transport(format!("token request failed: {other}")),
    }
}

// AuthClient는 client-credentials 소스로서 TokenProvider를 구현(admin이 이 trait로만 토큰을 받는다).
#[async_trait]
impl TokenProvider for AuthClient {
    async fn access_token(&self) -> Result<String> {
        Ok(self.client_credentials_token().await?.access_token)
    }
}

#[cfg(test)]
mod tests {
    // introspect 매핑 스모크(wiremock): openidconnect introspect 빌더가 RFC7662 응답을
    // 파싱하고 경계에서 IntrospectionResult로 변환되는지 확인. 전 흐름은 Task 11 통합테스트.
    use super::*;
    use crate::jwks::JwksStore;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn introspect_maps_active_response() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(
                "/realms/it-realm/protocol/openid-connect/token/introspect",
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "active": true, "username": "alice", "client_id": "it-client"
            })))
            .mount(&server)
            .await;

        let config = KeycloakConfig::new(server.uri(), "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s");
        let endpoints = OidcEndpoints::new(&config);
        let jwks = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks);
        let auth = AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap();

        let r = auth.introspect("some-token").await.unwrap();
        assert!(r.active);
        assert_eq!(r.username.as_deref(), Some("alice"));
        assert_eq!(r.client_id.as_deref(), Some("it-client"));
    }
}
