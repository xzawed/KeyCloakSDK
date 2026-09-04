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
        // nonce는 openidconnect가 auth URL에 실어 Keycloak이 id_token에 담아 돌려준다. 호출자에게
        // 함께 돌려줘 콜백 후 exchange_code(expected_nonce)로 넘기면 id_token 재생을 막는다.
        // config.scopes를 반영(사용자 커스텀 스코프). 비면 "openid" 폴백.
        let scopes = self.scopes();
        let (url, csrf, nonce) = self
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
            nonce: nonce.secret().clone(),
        }
    }

    /// Authorization Code → 토큰 교환. PKCE verifier를 반드시 전달(S256 증명).
    ///
    /// `expected_nonce`가 `Some`이면(create_authorization_request가 돌려준 nonce) 응답 id_token을
    /// 강화 `JwtValidator`로 서명·iss·aud·exp까지 검증한 뒤 nonce 클레임을 대조한다 — OIDC nonce
    /// 재생 방지. 불일치·부재·검증실패는 모두 거부(fail-closed). `None`이면 id_token 검증을 건너뛴다.
    pub async fn exchange_code(
        &self,
        code: &str,
        code_verifier: &str,
        expected_nonce: Option<&str>,
    ) -> Result<TokenSet> {
        let resp = self
            .oidc
            .exchange_code(AuthorizationCode::new(code.to_string()))
            .set_pkce_verifier(PkceCodeVerifier::new(code_verifier.to_string()))
            .request_async(&self.http)
            .await
            .map_err(map_token_err)?;
        let token_set = to_token_set(&resp);
        if let Some(nonce) = expected_nonce {
            self.verify_nonce(token_set.id_token.as_deref(), nonce)
                .await?;
        }
        Ok(token_set)
    }

    // id_token의 nonce 클레임을 대조하기 전에 강화 JwtValidator로 서명·iss·aud·exp까지 검증한다
    // (액세스 토큰과 id_token 모두 aud=client_id라 검증기를 공유해도 안전 — config.expected_audience로
    // 기대 aud를 바꾸면 그 값이 id_token 검사에도 함께 적용된다).
    async fn verify_nonce(&self, id_token: Option<&str>, expected_nonce: &str) -> Result<()> {
        let id_token = id_token.ok_or_else(|| KeycloakError::Auth {
            message: "authorization code exchange failed: missing id_token for nonce validation"
                .to_string(),
            oauth_error: None,
        })?;
        let validated =
            self.validator
                .validate(id_token)
                .await
                .map_err(|e| KeycloakError::Auth {
                    message: format!("authorization code exchange failed: invalid id_token: {e}"),
                    oauth_error: None,
                })?;
        let actual = validated.claims.get("nonce").and_then(|v| v.as_str());
        if actual != Some(expected_nonce) {
            return Err(KeycloakError::Auth {
                message: "authorization code exchange failed: unexpected nonce".to_string(),
                oauth_error: None,
            });
        }
        Ok(())
    }

    /// config.scopes를 openidconnect `Scope` 벡터로 변환한다(authz-url·client-credentials 공용).
    /// 비면 "openid" 폴백 — token_provider(admin 경로)와 동형.
    fn scopes(&self) -> Vec<Scope> {
        if self.config.scopes.is_empty() {
            vec![Scope::new("openid".to_string())]
        } else {
            self.config
                .scopes
                .iter()
                .map(|s| Scope::new(s.clone()))
                .collect()
        }
    }

    /// Client Credentials 흐름(admin 접착·서비스 계정). config.scopes를 요청에 반영한다
    /// (누락 시 커스텀 스코프가 무시돼 언더스코프 토큰 발급 — authz-url·token_provider와 동형).
    pub async fn client_credentials_token(&self) -> Result<TokenSet> {
        let resp = self
            .oidc
            .exchange_client_credentials()
            .add_scopes(self.scopes())
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
    ///
    /// ⚠️ **상태코드를 반드시 본다.** `reqwest`의 `send()`는 **전송 실패에만** `Err`를 주고
    /// 400/401/404 는 `Ok(Response)` 로 돌려준다 — 그래서 `send().await?; Ok(())` 로 쓰면
    /// 세션이 그대로 살아있는데 호출자는 로그아웃이 성공했다고 믿는다. 자매 여덟 언어는
    /// 전부 비-2xx 를 오류로 표면화한다(Node·.NET·Ruby·PHP·Go 실측). 여기만 그러지 않았다.
    ///
    /// ⚠️ **어떤 상태코드도 특별대우하지 않는다.** 404 는 대개 end-session 경로/realm 오설정이라
    /// 삼키면 오설정이 영원히 안 보이고, 400("이미 무효화된 refresh_token")을 통과시키면 같은
    /// 분류의 진짜 클라이언트 오류까지 함께 통과한다.
    pub async fn logout(&self, refresh_token: &str) -> Result<()> {
        let params = [
            ("client_id", self.config.client_id.as_str()),
            (
                "client_secret",
                self.config.client_secret.as_deref().unwrap_or(""),
            ),
            ("refresh_token", refresh_token),
        ];
        let resp = self
            .http
            .post(self.endpoints.end_session())
            .form(&params)
            .send()
            .await
            .map_err(|e| KeycloakError::Transport(format!("logout: {e}")))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(KeycloakError::Auth {
                message: format!("logout failed (HTTP {})", status.as_u16()),
                oauth_error: None,
            });
        }
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
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
    use rsa::pkcs1::{EncodeRsaPrivateKey, LineEnding};
    use rsa::traits::PublicKeyParts;
    use rsa::{RsaPrivateKey, RsaPublicKey};
    use serde_json::json;
    use std::time::{SystemTime, UNIX_EPOCH};
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    // (priv_pem, jwk) 픽스처 — jwt.rs 테스트와 동일 패턴. kid="test-kid".
    fn make_rsa() -> (String, serde_json::Value) {
        let mut rng = rand::thread_rng();
        let sk = RsaPrivateKey::new(&mut rng, 2048).unwrap();
        let pk = RsaPublicKey::from(&sk);
        let n = URL_SAFE_NO_PAD.encode(pk.n().to_bytes_be());
        let e = URL_SAFE_NO_PAD.encode(pk.e().to_bytes_be());
        let priv_pem = sk.to_pkcs1_pem(LineEnding::LF).unwrap().to_string();
        let jwk = json!({"kty":"RSA","kid":"test-kid","use":"sig","alg":"RS256","n":n,"e":e});
        (priv_pem, jwk)
    }

    fn sign_id_token(priv_pem: &str, iss: &str, aud: &str, nonce: &str) -> String {
        let mut h = Header::new(Algorithm::RS256);
        h.kid = Some("test-kid".into());
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let claims = json!({"sub":"u","iss":iss,"aud":aud,"exp":now+300,"iat":now,"nonce":nonce});
        let ek = EncodingKey::from_rsa_pem(priv_pem.as_bytes()).unwrap();
        encode(&h, &claims, &ek).unwrap()
    }

    // AuthClient + JWKS(/certs)를 mount한 MockServer + issuer를 돌려준다. jwk를 서명 키의 공개키로
    // mount하므로 sign_id_token(priv_pem, ...)이 만든 id_token이 검증을 통과한다.
    async fn nonce_fixture() -> (AuthClient, String, String) {
        let (priv_pem, jwk) = make_rsa();
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/realms/it-realm/protocol/openid-connect/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"keys":[jwk]})))
            .mount(&server)
            .await;
        let uri = Box::leak(Box::new(server)).uri();
        let config = KeycloakConfig::new(uri, "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s");
        let endpoints = OidcEndpoints::new(&config);
        let issuer = endpoints.issuer();
        let jwks = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks).unwrap();
        let auth = AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap();
        (auth, priv_pem, issuer)
    }

    #[tokio::test]
    async fn create_authorization_request_returns_nonce() {
        let config = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client").unwrap();
        let endpoints = OidcEndpoints::new(&config);
        let jwks = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks).unwrap();
        let auth = AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap();
        let req = auth.create_authorization_request();
        assert!(
            !req.nonce.is_empty(),
            "nonce must be returned to the caller"
        );
        assert!(
            req.url.contains("nonce="),
            "nonce must be on the authorization URL"
        );
    }

    #[tokio::test]
    async fn verify_nonce_accepts_match_rejects_mismatch_and_missing() {
        let (auth, priv_pem, issuer) = nonce_fixture().await;
        let id_token = sign_id_token(&priv_pem, &issuer, "it-client", "server-nonce");

        // Matching nonce → accepted.
        assert!(
            auth.verify_nonce(Some(&id_token), "server-nonce")
                .await
                .is_ok()
        );
        // Mismatched nonce → rejected.
        assert!(matches!(
            auth.verify_nonce(Some(&id_token), "attacker-nonce").await,
            Err(KeycloakError::Auth { .. })
        ));
        // Missing id_token while a nonce is expected → rejected (fail-closed).
        assert!(matches!(
            auth.verify_nonce(None, "server-nonce").await,
            Err(KeycloakError::Auth { .. })
        ));
    }

    #[tokio::test]
    async fn verify_nonce_rejects_untrusted_id_token() {
        let (auth, _priv_pem, issuer) = nonce_fixture().await;
        // Signed by a key that is NOT in the served JWKS → signature verification fails.
        let (other_pem, _) = make_rsa();
        let forged = sign_id_token(&other_pem, &issuer, "it-client", "server-nonce");
        assert!(matches!(
            auth.verify_nonce(Some(&forged), "server-nonce").await,
            Err(KeycloakError::Auth { .. })
        ));
    }

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
        let validator = JwtValidator::new(&config, &endpoints, jwks).unwrap();
        let auth = AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap();

        let r = auth.introspect("some-token").await.unwrap();
        assert!(r.active);
        assert_eq!(r.username.as_deref(), Some("alice"));
        assert_eq!(r.client_id.as_deref(), Some("it-client"));
    }

    // end_session 이 `status` 를 돌려주도록 mount 한 AuthClient.
    async fn logout_fixture(status: u16) -> (AuthClient, MockServer) {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/logout"))
            .respond_with(ResponseTemplate::new(status))
            .mount(&server)
            .await;
        let config = KeycloakConfig::new(server.uri(), "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s");
        let endpoints = OidcEndpoints::new(&config);
        let jwks = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks).unwrap();
        let auth = AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap();
        (auth, server)
    }

    // `reqwest`의 send()는 4xx/5xx에 Err를 주지 않는다 — 상태코드를 직접 보지 않으면 이 셋이
    // 전부 Ok(())가 되어 "세션이 살아있는데 로그아웃 성공"이 된다.
    #[tokio::test]
    async fn logout_surfaces_non_2xx_status() {
        for status in [400_u16, 401, 404, 500] {
            let (auth, _server) = logout_fixture(status).await;
            let err = auth.logout("rt").await.expect_err(
                "비-2xx 는 오류여야 한다 — Ok(())면 호출자가 무효화되지 않은 세션을 무효화됐다고 믿는다",
            );
            match err {
                KeycloakError::Auth { message, .. } => assert!(
                    message.contains(&status.to_string()),
                    "오류 메시지가 실제 상태코드를 담아야 한다: {message}",
                ),
                other => panic!("Auth 오류를 기대했다(HTTP {status}), 실제: {other:?}"),
            }
        }
    }

    // ⚠️ 대조군을 지우지 말 것 — 위 테스트가 "logout이 늘 실패한다"로도 통과하는 것을 막는
    // 유일한 수단이다. 204(Keycloak의 실제 성공 응답)와 200 둘 다 Ok여야 한다.
    #[tokio::test]
    async fn logout_accepts_2xx_status() {
        for status in [200_u16, 204] {
            let (auth, _server) = logout_fixture(status).await;
            auth.logout("rt")
                .await
                .unwrap_or_else(|e| panic!("HTTP {status}는 성공이어야 한다, 실제: {e:?}"));
        }
    }
}
