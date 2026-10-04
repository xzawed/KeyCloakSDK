//! AuthClient — openidconnect(auth flows) 래핑 + introspect/logout 손수. 커버리지 omit(네트워크 경계).
//!
//! `openidconnect` 4.0의 `CoreClient`는 6개의 엔드포인트 typestate 파라미터를 갖는다. 여기서는
//! auth/introspection/token 을 명시적으로 세팅해 exchange 빌더(`exchange_*`·`introspect`)가
//! `?` 없이 호출 가능한(infallible) 구체 타입 `KcOidcClient`를 얻는다. id_token은 openidconnect의
//! 자체 검증기 대신 강화된 `JwtValidator`로 검증하므로 `JsonWebKeySet`은 비워 둔다.
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result, oauth_error_code};
use crate::jwks::{TOKEN_RESPONSE_MAX_BYTES, read_capped};
use crate::jwt::JwtValidator;
use crate::oidc::OidcEndpoints;
use crate::token_provider::TokenProvider;
use crate::tokens::{AuthorizationRequest, IntrospectionResult, TokenSet, ValidatedToken};
use async_trait::async_trait;
use openidconnect::core::{
    CoreClient, CoreErrorResponseType, CoreJsonWebKey, CoreResponseType, CoreTokenResponse,
};
use openidconnect::{
    AccessToken, AuthUrl, AuthenticationFlow, AuthorizationCode, ClientId, ClientSecret, CsrfToken,
    EndpointNotSet, EndpointSet, IntrospectionUrl, IssuerUrl, JsonWebKeySet, Nonce,
    OAuth2TokenResponse, PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, RefreshToken,
    RequestTokenError, Scope, StandardErrorResponse, TokenIntrospectionResponse, TokenResponse,
    TokenUrl,
};
use openidconnect::{AsyncHttpClient, HttpClientError, HttpRequest, HttpResponse};
use std::future::Future;
use std::pin::Pin;
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

/// openidconnect(oauth2) 에 넘기는 HTTP 클라이언트 — 공유 `reqwest::Client` 로 보내되 본문은
/// [`TOKEN_RESPONSE_MAX_BYTES`] 까지만 읽는다. ⚠️ `request_async(&self.http)` 로 되돌리지 말 것 — oauth2 5.0 의
/// reqwest 구현은 `response.bytes()` 로 통째로 읽는다(`reqwest_client.rs`). 비공개 타입이라 §4 표면은 그대로다.
struct CappedHttp<'a> {
    http: &'a reqwest::Client,
    /// 상한 초과 문구의 주어 — `"token response"` · `"introspection response"`.
    what: &'static str,
}

impl<'c> AsyncHttpClient<'c> for CappedHttp<'_> {
    // ⚠️ oauth2 reqwest 구현과 같은 오류 타입 — 전송 실패의 문구(`map_token_err`)가 그대로다. 다른 것은 본문 읽기뿐.
    type Error = HttpClientError<reqwest::Error>;
    type Future =
        Pin<Box<dyn Future<Output = std::result::Result<HttpResponse, Self::Error>> + Send + 'c>>;

    fn call(&'c self, request: HttpRequest) -> Self::Future {
        Box::pin(async move {
            let mut response = self
                .http
                .execute(request.try_into().map_err(Box::new)?)
                .await
                .map_err(Box::new)?;
            let mut builder = openidconnect::http::Response::builder()
                .status(response.status())
                .version(response.version());
            for (name, value) in response.headers() {
                builder = builder.header(name, value);
            }
            let body = read_capped(&mut response, TOKEN_RESPONSE_MAX_BYTES)
                .await
                .map_err(Box::new)?
                .ok_or_else(|| {
                    HttpClientError::Other(format!(
                        "{} exceeds {TOKEN_RESPONSE_MAX_BYTES} bytes",
                        self.what
                    ))
                })?;
            builder.body(body).map_err(HttpClientError::Http)
        })
    }
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
        let core = CoreClient::new(
            ClientId::new(config.client_id.clone()),
            IssuerUrl::new(base.clone())
                .map_err(|e| KeycloakError::Config(format!("issuer url: {e}")))?,
            // 비어있는 JWKS: id_token 검증에 미사용(자체 JwtValidator가 access_token을 강화 검증).
            JsonWebKeySet::<CoreJsonWebKey>::new(Vec::new()),
        );
        // ⚠️ **빈 시크릿은 「시크릿 없음」이 아니다 — 공개 클라이언트를 기밀처럼 인증시킨다.**
        // `oauth2` 5.0.0 은 `Some(ClientSecret(""))` 을 기본 `AuthType::BasicAuth` 로 처리해
        // `Authorization: Basic base64(client_id:)` 를 붙이고 `client_id` 를 본문에서 뺀다
        // (`endpoint.rs` 의 `match (auth_type, client_secret)`). 호출하지 않으면 그 크레이트가
        // 스스로 RequestBody 로 떨어져 `client_id` 만 싣는다 — 그것이 공개 클라이언트의 계약이다.
        // 자매 구현 동형: java 는 `getClientSecret() != null` 로 갈라 `ClientID` 만 싣고,
        // go 는 `if a.cfg.ClientSecret != ""` 로 감싼다.
        let core = match config.client_secret.as_deref() {
            Some(s) => core.set_client_secret(ClientSecret::new(s.to_string())),
            None => core,
        };
        let oidc = core
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
    ///
    /// `redirect_uri`는 config 값을 쓴다 — 콜백이 여럿인 앱은
    /// [`Self::create_authorization_request_with_redirect`]를 쓴다.
    pub fn create_authorization_request(&self) -> AuthorizationRequest {
        self.authorization_request(None)
    }

    /// 이 요청에만 쓸 콜백 URL을 받는 판. 콜백이 여럿인 앱(멀티테넌트·환경별)이 클라이언트
    /// 하나로 그것을 섬기기 위한 자리이고, 나머지 여덟 SDK와 동형이다.
    ///
    /// ⚠️ **같은 값을 [`Self::exchange_code_with_redirect`]에 넘겨야 한다** — OAuth는 토큰
    /// 교환의 `redirect_uri`가 인가 때 쓴 값과 같기를 요구한다(RFC 6749 §4.1.3).
    ///
    /// ⚠️ 잘못된 URL은 `KeycloakError::Config`다 — §4대로 하위 타입(`RedirectUrl`)과 그
    /// 파싱 오류는 파사드 밖으로 새지 않는다.
    pub fn create_authorization_request_with_redirect(
        &self,
        redirect_uri: &str,
    ) -> Result<AuthorizationRequest> {
        Ok(self.authorization_request(Some(Self::redirect_url(redirect_uri)?)))
    }

    /// 상류 `RedirectUrl` 조립 — 파싱 오류를 경계에서 SDK 타입으로 바꾼다(§4).
    fn redirect_url(redirect_uri: &str) -> Result<RedirectUrl> {
        RedirectUrl::new(redirect_uri.to_string())
            .map_err(|e| KeycloakError::Config(format!("invalid redirect_uri: {e}")))
    }

    fn authorization_request(&self, redirect_uri: Option<RedirectUrl>) -> AuthorizationRequest {
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        // nonce는 openidconnect가 auth URL에 실어 Keycloak이 id_token에 담아 돌려준다. 호출자에게
        // 함께 돌려줘 콜백 후 exchange_code(expected_nonce)로 넘기면 id_token 재생을 막는다.
        // config.scopes를 반영(사용자 커스텀 스코프). 비면 "openid" 폴백.
        let scopes = self.scopes();
        let mut builder = self
            .oidc
            .authorize_url(
                AuthenticationFlow::<CoreResponseType>::AuthorizationCode,
                CsrfToken::new_random,
                Nonce::new_random,
            )
            .add_scopes(scopes)
            .set_pkce_challenge(challenge);
        // ⚠️ `None`이면 **건드리지 않는다** — 상류가 생성 시 값(config)을 그대로 쓴다.
        if let Some(uri) = redirect_uri {
            builder = builder.set_redirect_uri(std::borrow::Cow::Owned(uri));
        }
        let (url, csrf, nonce) = builder.url();
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
    /// id_token 의 `aud` 는 `client_id` 로 본다 — `expected_audience` 는 [`Self::validate`] 에만 걸린다.
    pub async fn exchange_code(
        &self,
        code: &str,
        code_verifier: &str,
        expected_nonce: Option<&str>,
    ) -> Result<TokenSet> {
        self.code_exchange(code, code_verifier, None, expected_nonce)
            .await
    }

    /// 인가 때 쓴 콜백 URL을 그대로 넘기는 판 — [`Self::create_authorization_request_with_redirect`]
    /// 와 짝이다.
    ///
    /// ⚠️ **짝을 맞춰야 한다.** OAuth는 토큰 교환의 `redirect_uri`가 인가 때 쓴 값과 같기를
    /// 요구하고(RFC 6749 §4.1.3), 다르면 Keycloak이 `invalid_grant`로 거부한다.
    pub async fn exchange_code_with_redirect(
        &self,
        code: &str,
        code_verifier: &str,
        redirect_uri: &str,
        expected_nonce: Option<&str>,
    ) -> Result<TokenSet> {
        let uri = Self::redirect_url(redirect_uri)?;
        self.code_exchange(code, code_verifier, Some(uri), expected_nonce)
            .await
    }

    async fn code_exchange(
        &self,
        code: &str,
        code_verifier: &str,
        redirect_uri: Option<RedirectUrl>,
        expected_nonce: Option<&str>,
    ) -> Result<TokenSet> {
        let mut req = self
            .oidc
            .exchange_code(AuthorizationCode::new(code.to_string()))
            .set_pkce_verifier(PkceCodeVerifier::new(code_verifier.to_string()));
        // ⚠️ `None`이면 건드리지 않는다 — 상류가 생성 시 값(config)을 그대로 쓴다.
        if let Some(uri) = redirect_uri {
            req = req.set_redirect_uri(std::borrow::Cow::Owned(uri));
        }
        let resp = req
            .request_async(&self.capped("token response"))
            .await
            .map_err(map_token_err)?;
        let token_set = to_token_set(&resp)?;
        if let Some(nonce) = expected_nonce {
            self.verify_nonce(token_set.id_token.as_deref(), nonce)
                .await?;
        }
        Ok(token_set)
    }

    // id_token의 nonce 클레임을 대조하기 전에 강화 JwtValidator로 서명·iss·aud·exp까지 검증한다.
    // ⚠️ aud 는 `expected_audience` 가 아니라 **이 AuthClient 의 client_id**(토큰 엔드포인트에서 인증한
    // 신원)로 본다(OIDC Core §2 · §3.1.3.7) — 재정의는 access 토큰의 리소스 서버 제한이다. 검증기는 같은
    // 것을 쓴다(JWKS 상태가 하나로 남는다).
    async fn verify_nonce(&self, id_token: Option<&str>, expected_nonce: &str) -> Result<()> {
        let id_token = id_token.ok_or_else(|| KeycloakError::Auth {
            message: "authorization code exchange failed: missing id_token for nonce validation"
                .to_string(),
            oauth_error: None,
        })?;
        let validated = self
            .validator
            .validate_for_audience(id_token, &self.config.client_id)
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

    /// 토큰·introspection 요청에 넘길 상한 클라이언트(`CappedHttp`) — 공유 `http` 를 그대로 쓴다.
    fn capped(&self, what: &'static str) -> CappedHttp<'_> {
        CappedHttp {
            http: &self.http,
            what,
        }
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
            .request_async(&self.capped("token response"))
            .await
            .map_err(map_token_err)?;
        to_token_set(&resp)
    }

    /// Refresh Token → 새 토큰 셋.
    pub async fn refresh(&self, refresh_token: &str) -> Result<TokenSet> {
        let rt = RefreshToken::new(refresh_token.to_string());
        let resp = self
            .oidc
            .exchange_refresh_token(&rt)
            .request_async(&self.capped("token response"))
            .await
            .map_err(map_token_err)?;
        to_token_set(&resp)
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
            .request_async(&self.capped("introspection response"))
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
        // ⚠️ 공개 클라이언트에는 `client_secret` 를 **싣지 않는다**(빈 값도 아니다) — go 의
        // `if a.cfg.ClientSecret != ""` · .NET 의 `if (_cfg.ClientSecret is { } secret)` 와 동형.
        let mut params: Vec<(&str, &str)> = vec![
            ("client_id", self.config.client_id.as_str()),
            ("refresh_token", refresh_token),
        ];
        if let Some(secret) = self.config.client_secret.as_deref() {
            params.push(("client_secret", secret));
        }
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
/// ⚠️ **타입이 안전해도 빈 값은 남는다.** `CoreTokenResponse` 는 `access_token` 이 문자열이
/// 아니면 역직렬화에서 떨어지지만 **빈 문자열은 통과**시킨다. `token_provider` 와 같은 계약을
/// 여기서도 건다 — 쓸 수 없는 토큰으로 성공을 돌려주지 않는다.
fn to_token_set(resp: &CoreTokenResponse) -> Result<TokenSet> {
    let access_token = resp.access_token().secret();
    if access_token.is_empty() {
        return Err(KeycloakError::Auth {
            message: "token response has no usable access_token".into(),
            oauth_error: None,
        });
    }
    let expires_in = resp.expires_in().map(|d| d.as_secs()).unwrap_or(0);
    Ok(TokenSet {
        access_token: access_token.clone(),
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
    })
}

/// openidconnect `RequestTokenError` → `KeycloakError`. 서버 OAuth 오류는 `Auth`, 전송/파싱은 `Transport`.
///
/// ⚠️ **응답이 보낸 글자를 옮기지 않는다 — OAuth 오류 코드 하나만 옮긴다.** 예전에는 `oauth_error` 에
/// `StandardErrorResponse` 의 `Display`(`error: error_description (see error_uri)`)를 통째로 실어, 받은
/// 토큰을 되울리는 `error_description`·`error_uri` 가 `{:?}` 로 원문 그대로 찍혔고, `Other` 문구는 응답
/// Content-Type 헤더 값을 인용했다(실측 2026-09-26 — `tests/hostile_token_response.rs`). `Parse` 의 serde
/// 오류는 틀린 타입의 문자열 값을 인용하고 원 본문을 품으므로 그 문구도 옮기지 않는다.
fn map_token_err(
    e: RequestTokenError<HttpClientError<reqwest::Error>, TokenErrorResponse>,
) -> KeycloakError {
    use openidconnect::RequestTokenError as RTE;
    match e {
        RTE::ServerResponse(resp) => KeycloakError::Auth {
            message: "token endpoint rejected".into(),
            // RFC 6749 §5.2 의 `error` — 코드다. description·uri 는 서버의 자유 서술이라 싣지 않는다.
            // 코드 자리에 코드 아닌 값(되울린 토큰)이 오면 그것도 싣지 않는다(`oauth_error_code`).
            oauth_error: oauth_error_code(resp.error().as_ref()),
        },
        // `Other` 는 `CappedHttp` 만 만든다 — 상한 초과의 고정 문구(admin 레인과 같다)라 그대로 옮긴다.
        RTE::Request(HttpClientError::Other(msg)) => KeycloakError::Transport(msg),
        RTE::Request(re) => KeycloakError::Transport(format!("token request: {re}")),
        RTE::Parse(..) => {
            KeycloakError::Transport("token request failed: Failed to parse server response".into())
        }
        RTE::Other(msg) => KeycloakError::Transport(format!(
            "token request failed: Other error: {}",
            other_message(&msg)
        )),
    }
}

/// openidconnect `CoreClient` 의 토큰·introspect 오류 응답 타입.
type TokenErrorResponse = StandardErrorResponse<CoreErrorResponseType>;

/// oauth2 5.0 이 `RequestTokenError::Other` 에 싣는 문구 중 **응답 입력을 인용하지 않는 것**만 옮긴다.
/// ⚠️ 허용 목록이다 — 모르는 문구는 숨기는 쪽으로 떨어진다(상류가 문구를 바꿔도 새지 않는다).
fn other_message(msg: &str) -> &str {
    const FIXED: [&str; 2] = [
        "server returned empty error response",
        "server returned empty response body",
    ];
    if FIXED.contains(&msg) || msg.starts_with("failed to prepare request: ") {
        msg
    } else if msg.starts_with("unexpected response Content-Type") {
        // 원문은 헤더 값을 인용한다 — 값은 빼고 의미만 남긴다.
        "unexpected response Content-Type (value withheld), should be `application/json`"
    } else {
        "unexpected response (detail withheld)"
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

    // ── 인가요청·토큰교환의 redirect_uri 를 호출당 받는가 (나머지 여덟 SDK 와 동형) ──
    //
    // 왜: 콜백이 여럿인 앱(멀티테넌트·환경별)이 클라이언트 하나로 그것을 섬겨야 한다. rust 와 php
    // 만 생성 시 config 값에 묶여 있었고, 하네스 conformance 가 그 비대칭을 빨갛게 냈다.
    // ⚠️ rust 는 기본 인자가 없으므로 **새 메서드**다(가산적 — semver 파괴 아님).
    fn test_auth() -> AuthClient {
        let config = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client").unwrap();
        let endpoints = OidcEndpoints::new(&config);
        let jwks = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks).unwrap();
        AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap()
    }

    #[tokio::test]
    async fn authorization_request_uses_per_call_redirect_uri() {
        let auth = test_auth();
        let req = auth
            .create_authorization_request_with_redirect("https://tenant-b.app/callback")
            .expect("valid redirect uri must be accepted");
        assert!(
            req.url
                .contains("redirect_uri=https%3A%2F%2Ftenant-b.app%2Fcallback"),
            "per-call redirect_uri must land on the authorization URL, got: {}",
            req.url
        );
    }

    #[tokio::test]
    async fn authorization_request_without_redirect_keeps_config_value() {
        // 기존 메서드는 그대로다 — 가산적 변경임을 고정한다.
        let auth = test_auth();
        let req = auth.create_authorization_request();
        assert!(
            req.url.contains("redirect_uri="),
            "config redirect_uri must still be used by the existing method"
        );
        assert!(
            !req.url.contains("tenant-b"),
            "existing method must not pick up a per-call value"
        );
    }

    #[tokio::test]
    async fn per_call_redirect_uri_is_validated_at_the_boundary() {
        // ⚠️ §4 — 하위 타입(`RedirectUrl`)은 파사드 뒤에 숨는다. 잘못된 URL 은 상류 오류가
        // 새지 않고 `KeycloakError::Config` 로 변환돼야 한다.
        let auth = test_auth();
        let err = auth
            .create_authorization_request_with_redirect("not a url")
            .expect_err("invalid redirect uri must be rejected");
        assert!(
            matches!(err, KeycloakError::Config(_)),
            "boundary must translate to KeycloakError::Config, got: {err:?}"
        );
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

    // `verify_nonce` 단위 테스트는 `code_exchange` 안의 호출을 지우면 그대로 통과한다.
    // 토큰 응답의 id_token(있으면 서명)까지 거친 `exchange_code`가 nonce를 강제하는지 고정한다.
    /// 토큰 응답에 실을 id_token 의 모양.
    enum IdTok<'a> {
        Absent,
        Nonce(&'a str),
        /// 서명은 유효하지만 `nonce` 클레임이 **없다** — 「있고 다를 때만 거부」로 약해지면 통과한다.
        NoNonceClaim,
    }

    /// 거부가 **nonce 판정 때문**인지까지 본다 — 다른 `Auth` 실패가 초록을 대신 채우지 못하게.
    fn assert_auth_err(r: Result<TokenSet>, needle: &str) {
        match r {
            Err(KeycloakError::Auth { message, .. }) => {
                assert!(message.contains(needle), "{message}")
            }
            other => panic!("expected Auth error containing {needle:?}, got {other:?}"),
        }
    }

    async fn exchange_fixture(id_token: IdTok<'_>) -> AuthClient {
        exchange_fixture_with(ExchangeSpec::default(), |t| match id_token {
            IdTok::Absent => None,
            IdTok::Nonce(nonce) => Some(t.id_token(json!("it-client"), Some(nonce))),
            IdTok::NoNonceClaim => Some(t.id_token(json!("it-client"), None)),
        })
        .await
        .auth
    }

    /// 교환 픽스처의 손잡이 — 기본값은 재정의 없음 · JWKS 200.
    struct ExchangeSpec {
        expected_audience: Option<&'static str>,
        /// 토큰 응답 access_token(서명된 JWT)의 `aud`.
        access_aud: serde_json::Value,
        jwks_status: u16,
        /// `Some` 이면 검증기만 이 client id 의 config 로 만든다(AuthClient 는 `it-client`).
        validator_client_id: Option<&'static str>,
    }

    impl Default for ExchangeSpec {
        fn default() -> Self {
            Self {
                expected_audience: None,
                access_aud: json!(["it-client", "account"]),
                jwks_status: 200,
                validator_client_id: None,
            }
        }
    }

    /// id_token·access_token 을 서명하는 손 — 픽스처의 키와 issuer 를 안다.
    struct Signer {
        priv_pem: String,
        issuer: String,
    }

    impl Signer {
        fn claims(&self, aud: serde_json::Value, nonce: Option<&str>) -> serde_json::Value {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs();
            let mut c = json!({"sub":"u","iss":self.issuer,"aud":aud,"exp":now+300,"iat":now});
            if let Some(n) = nonce {
                c["nonce"] = json!(n);
            }
            c
        }

        fn sign(&self, claims: &serde_json::Value, kid: &str) -> String {
            let mut h = Header::new(Algorithm::RS256);
            h.kid = Some(kid.into());
            let ek = EncodingKey::from_rsa_pem(self.priv_pem.as_bytes()).unwrap();
            encode(&h, claims, &ek).unwrap()
        }

        fn id_token(&self, aud: serde_json::Value, nonce: Option<&str>) -> String {
            self.sign(&self.claims(aud, nonce), "test-kid")
        }
    }

    struct Exchange {
        auth: AuthClient,
        server: &'static MockServer,
        signer: Signer,
    }

    impl Exchange {
        /// 이 픽스처의 IdP 가 받은 JWKS 요청 수 — 키 저장소가 몇 개였는지의 관측값이다.
        async fn jwks_fetches(&self) -> usize {
            self.server
                .received_requests()
                .await
                .expect("request recording is on")
                .iter()
                .filter(|r| r.url.path().ends_with("/certs"))
                .count()
        }
    }

    /// `id_token` 은 토큰 응답에 실을 id_token 을 만든다(`None` = 싣지 않는다). access_token 은 같은
    /// 키로 서명한 JWT 라서 교환 뒤 `validate()` 로 이어 부를 수 있다 — 두 경로가 **한** JWKS 저장소를
    /// 쓰는지 재려면 둘 다 그 저장소에 닿아야 한다.
    async fn exchange_fixture_with(
        spec: ExchangeSpec,
        id_token: impl FnOnce(&Signer) -> Option<String>,
    ) -> Exchange {
        let (priv_pem, jwk) = make_rsa();
        let server: &'static MockServer = Box::leak(Box::new(MockServer::start().await));
        let jwks_body = if spec.jwks_status == 200 {
            json!({"keys": [jwk]})
        } else {
            json!({"error": "unavailable"})
        };
        Mock::given(method("GET"))
            .and(path("/realms/it-realm/protocol/openid-connect/certs"))
            .respond_with(ResponseTemplate::new(spec.jwks_status).set_body_json(jwks_body))
            .mount(server)
            .await;
        let mut config = KeycloakConfig::new(server.uri(), "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s");
        if let Some(aud) = spec.expected_audience {
            config = config.with_expected_audience(aud);
        }
        let endpoints = OidcEndpoints::new(&config);
        let signer = Signer {
            priv_pem,
            issuer: endpoints.issuer(),
        };
        let mut body = json!({
            "access_token": signer.sign(&signer.claims(spec.access_aud, None), "test-kid"),
            "token_type": "Bearer",
            "expires_in": 300,
        });
        if let Some(t) = id_token(&signer) {
            body["id_token"] = json!(t);
        }
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(body))
            .mount(server)
            .await;
        // `KeycloakClient::new` 와 같은 배선 — 저장소 **하나**를 검증기 하나가 소유한다.
        let jwks = JwksStore::new(
            endpoints.jwks(),
            reqwest::Client::new(),
            config.jwks_min_refetch_secs,
        );
        // 저수준 주입은 검증기와 AuthClient 에 **다른** config 를 줄 수 있다 — 그 갈래를 재는 손잡이.
        let validator_config = match spec.validator_client_id {
            Some(id) => KeycloakConfig {
                client_id: id.to_string(),
                ..config.clone()
            },
            None => config.clone(),
        };
        let validator = JwtValidator::new(&validator_config, &endpoints, jwks).unwrap();
        let auth = AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap();
        Exchange {
            auth,
            server,
            signer,
        }
    }

    /// 리소스 서버 재정의 — access 토큰의 aud 는 API 이름이고, id_token 의 aud 는 여전히 client id 다.
    fn override_spec() -> ExchangeSpec {
        ExchangeSpec {
            expected_audience: Some("api://orders"),
            access_aud: json!(["api://orders", "account"]),
            ..ExchangeSpec::default()
        }
    }

    // ── id_token audience 는 client id 로 본다 (OIDC Core §2 · §3.1.3.7) ─────────────────────
    //
    // 예전에는 id_token 을 access 검증기 그대로 검증해, `expected_audience` 를 재정의하면 client id 를
    // 담은 **진짜** id_token 이 거부됐다(nonce 교환이 막혔다). 재정의는 access 토큰의 리소스 서버
    // 제한이다(RFC 9700 §2.3 · §4.10.2) — id_token 의 aud 는 client id 를 담아야 한다.

    /// (A1) 재정의 아래에서도 aud 에 client id 가 있으면 교환이 통과한다 — 단일 값과 배열 둘 다.
    #[tokio::test]
    async fn exchange_code_accepts_client_id_audience_under_expected_audience_override() {
        for aud in [json!("it-client"), json!(["it-client", "api://orders"])] {
            let fx = exchange_fixture_with(override_spec(), |t| {
                Some(t.id_token(aud.clone(), Some("expected-nonce")))
            })
            .await;
            let ts = fx
                .auth
                .exchange_code("c", "v", Some("expected-nonce"))
                .await
                .unwrap_or_else(|e| panic!("aud={aud} carries the client id, got {e:?}"));
            assert!(ts.id_token.is_some());
        }
    }

    /// (A2) aud 에 client id 가 없는 id_token 은 거부한다 — aud 가 재정의 값과 **같아도**.
    #[tokio::test]
    async fn exchange_code_rejects_id_token_audienced_only_at_the_override() {
        for aud in [json!("api://orders"), json!(["api://orders", "account"])] {
            let fx = exchange_fixture_with(override_spec(), |t| {
                Some(t.id_token(aud.clone(), Some("expected-nonce")))
            })
            .await;
            assert_auth_err(
                fx.auth
                    .exchange_code("c", "v", Some("expected-nonce"))
                    .await,
                "invalid id_token: token validation error: token verification failed: audience mismatch",
            );
        }
        // 재정의가 없어도 같다 — client id 밖의 aud 는 거부.
        let fx = exchange_fixture_with(ExchangeSpec::default(), |t| {
            Some(t.id_token(json!(["other-client"]), Some("expected-nonce")))
        })
        .await;
        assert_auth_err(
            fx.auth
                .exchange_code("c", "v", Some("expected-nonce"))
                .await,
            "audience mismatch",
        );
    }

    /// (A3) 교환이 client id 로 id_token 을 본 뒤에도 `validate()` 는 재정의를 쓴다.
    #[tokio::test]
    async fn validate_keeps_the_expected_audience_override_after_an_exchange() {
        let fx = exchange_fixture_with(override_spec(), |t| {
            Some(t.id_token(json!("it-client"), Some("expected-nonce")))
        })
        .await;
        let ts = fx
            .auth
            .exchange_code("c", "v", Some("expected-nonce"))
            .await
            .expect("the id_token carries the client id");
        let vt = fx
            .auth
            .validate(&ts.access_token)
            .await
            .expect("the access token carries the override");
        assert!(vt.audience.contains(&"api://orders".to_string()));
        // client id 만 담은 토큰(여기선 id_token)은 access 검증에서 거부 — 재정의는 대체다.
        match fx.auth.validate(ts.id_token.as_deref().unwrap()).await {
            Err(KeycloakError::TokenValidation(m)) => {
                assert_eq!(m, "token verification failed: audience mismatch")
            }
            other => panic!("validate() must look for the override, got {other:?}"),
        }
    }

    /// 저수준 주입(`AuthClient::new` 에 검증기를 따로 만든 config)에서 id_token 의 aud 는 **코드를
    /// 교환한 클라이언트**(AuthClient config 의 client id — 토큰 엔드포인트에서 인증한 신원)를 따른다.
    /// OIDC Core §3.1.3.7 의 「its client_id」다. 검증기 config 의 client id 는 access 경로만 쓴다.
    #[tokio::test]
    async fn id_token_audience_follows_the_client_that_exchanged_the_code() {
        let spec = || ExchangeSpec {
            validator_client_id: Some("validator-only-client"),
            ..ExchangeSpec::default()
        };
        let fx = exchange_fixture_with(spec(), |t| {
            Some(t.id_token(json!("it-client"), Some("expected-nonce")))
        })
        .await;
        fx.auth
            .exchange_code("c", "v", Some("expected-nonce"))
            .await
            .expect("aud carries the client that exchanged the code");
        let fx = exchange_fixture_with(spec(), |t| {
            Some(t.id_token(json!("validator-only-client"), Some("expected-nonce")))
        })
        .await;
        assert_auth_err(
            fx.auth
                .exchange_code("c", "v", Some("expected-nonce"))
                .await,
            "audience mismatch",
        );
    }

    /// (A4) 재정의 아래의 교환도 iss · alg 핀 · exp/스큐 · nonce 대조를 그대로 건다.
    #[tokio::test]
    async fn exchange_code_under_override_keeps_issuer_alg_expiry_and_nonce_checks() {
        // ⚠️ 만료는 서명하는 순간의 `iat` 에서 잰다 — 테스트 머리의 시각을 쓰면 픽스처마다 도는
        // RSA 키 생성(디버그 빌드에서 수 초)이 그 사이에 쌓여 「스큐 안쪽」이 밖으로 밀려난다(실측).
        fn expired_by(t: &Signer, secs: u64) -> String {
            let mut c = t.claims(json!("it-client"), Some("expected-nonce"));
            c["exp"] = json!(c["iat"].as_u64().unwrap() - secs);
            t.sign(&c, "test-kid")
        }
        type Build = Box<dyn FnOnce(&Signer) -> Option<String>>;
        let cases: Vec<(&str, Build)> = vec![
            (
                "unexpected nonce",
                Box::new(|t: &Signer| Some(t.id_token(json!("it-client"), Some("attacker-nonce")))),
            ),
            (
                "issuer mismatch",
                Box::new(|t: &Signer| {
                    let mut c = t.claims(json!("it-client"), Some("expected-nonce"));
                    c["iss"] = json!(format!("{}-evil", t.issuer));
                    Some(t.sign(&c, "test-kid"))
                }),
            ),
            (
                "expired",
                Box::new(|t: &Signer| Some(expired_by(t, 45))), // 스큐 30 밖
            ),
            (
                "algorithm not allowed",
                Box::new(|t: &Signer| {
                    let mut h = Header::new(Algorithm::HS256);
                    h.kid = Some("test-kid".into());
                    let c = t.claims(json!("it-client"), Some("expected-nonce"));
                    Some(encode(&h, &c, &EncodingKey::from_secret(b"guessed")).unwrap())
                }),
            ),
        ];
        for (needle, build) in cases {
            let fx = exchange_fixture_with(override_spec(), build).await;
            assert_auth_err(
                fx.auth
                    .exchange_code("c", "v", Some("expected-nonce"))
                    .await,
                needle,
            );
        }
        // 스큐는 넓어지지도 좁아지지도 않았다 — 30초 안쪽 만료는 통과한다.
        let fx = exchange_fixture_with(override_spec(), |t| Some(expired_by(t, 10))).await;
        fx.auth
            .exchange_code("c", "v", Some("expected-nonce"))
            .await
            .expect("an expiry inside the 30s skew is tolerated");
    }

    // ── (A5) 두 경로는 JWKS 저장소 **하나**를 쓴다 ──────────────────────────────────────────
    //
    // 저장소가 둘로 갈리면(id_token 용 검증기를 따로 만들면) 캐시 · 30초 재조회 제한 · 콜드 실패
    // 백오프가 모두 둘이 되어 IdP 요청이 늘어난다. 셋 다 IdP 가 받은 `/certs` 요청 수로 잰다.

    /// 캐시: 교환이 채운 키로 `validate()` 가 검증한다 — JWKS 조회는 한 번.
    #[tokio::test]
    async fn exchange_and_validate_share_one_jwks_cache() {
        let fx = exchange_fixture_with(override_spec(), |t| {
            Some(t.id_token(json!("it-client"), Some("expected-nonce")))
        })
        .await;
        let ts = fx
            .auth
            .exchange_code("c", "v", Some("expected-nonce"))
            .await
            .unwrap();
        assert_eq!(fx.jwks_fetches().await, 1, "the exchange loads the key set");
        fx.auth.validate(&ts.access_token).await.unwrap();
        fx.auth.validate(&ts.access_token).await.unwrap();
        assert_eq!(
            fx.jwks_fetches().await,
            1,
            "validate() after an exchange must reuse the exchange's key set"
        );

        // 대조군 — 저장소를 하나 더 만들면 이 계수가 **보인다**(계수가 눈멀지 않았음을 증명).
        let config = KeycloakConfig::new(fx.server.uri(), "it-realm", "it-client")
            .unwrap()
            .with_expected_audience("api://orders");
        let endpoints = OidcEndpoints::new(&config);
        let second = JwtValidator::new(
            &config,
            &endpoints,
            JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 30),
        )
        .unwrap();
        second.validate(&ts.access_token).await.unwrap();
        assert_eq!(fx.jwks_fetches().await, 2, "a second store fetches again");
    }

    /// 30초 재조회 제한: 교환의 미해결 kid 가 게이트를 찍으면, 이어진 `validate()` 의 미해결 kid 는
    /// IdP 에 닿지 않는다.
    #[tokio::test]
    async fn exchange_and_validate_share_the_refetch_rate_limit() {
        let fx = exchange_fixture_with(override_spec(), |t| {
            let c = t.claims(json!("it-client"), Some("expected-nonce"));
            Some(t.sign(&c, "rotated-kid"))
        })
        .await;
        // 캐시를 채운다(콜드 로드는 재조회 예산을 쓰지 않는다).
        let warm = fx
            .signer
            .sign(&fx.signer.claims(json!("api://orders"), None), "test-kid");
        fx.auth.validate(&warm).await.unwrap();
        assert_eq!(fx.jwks_fetches().await, 1);
        // 교환: id_token 의 kid 가 캐시에 없다 → 강제 재조회 한 번(게이트를 찍는다).
        assert_auth_err(
            fx.auth
                .exchange_code("c", "v", Some("expected-nonce"))
                .await,
            "unknown kid",
        );
        assert_eq!(fx.jwks_fetches().await, 2);
        // 같은 창 안의 `validate()` 미해결 kid — 같은 게이트라 IdP 에 가지 않는다.
        let forged = fx
            .signer
            .sign(&fx.signer.claims(json!("api://orders"), None), "other-kid");
        match fx.auth.validate(&forged).await {
            Err(KeycloakError::TokenValidation(m)) => {
                assert_eq!(m, "unknown kid (refetch rate-limited)")
            }
            other => panic!("expected the shared rate limit to refuse, got {other:?}"),
        }
        assert_eq!(
            fx.jwks_fetches().await,
            2,
            "one refetch per window across both paths"
        );
    }

    /// 콜드 실패 백오프: 교환의 JWKS 실패가 백오프를 열면, 바로 이어진 `validate()` 는 IdP 에 가지 않고
    /// 즉시 실패한다.
    ///
    /// ⚠️ **`start_paused` 를 떼지 말 것 — 실시간 시계에서는 이 단언이 러너 속도를 잰다.** 첫 실패의 창은
    /// 0.2초 × jitter[0.5, 1.0) 라 0.1초까지 좁고, 그 사이의 RSA 서명이 느린 러너에서 창을 넘기면
    /// `validate()` 가 IdP 로 다시 나가 `JWKS fetch failed: HTTP 503` 으로 깨진다. 게이트 시계가
    /// `tokio::time::Instant` 라 멈춘 시계에서는 그 사이 경과가 0 이다(`jwks.rs` 의 백오프 시험과 같은 틀).
    /// 자동 전진이 터뜨릴 타임아웃은 없다 — 픽스처의 `reqwest::Client::new()` 는 요청·연결·읽기 타임아웃이
    /// 없고, 남는 타이머(풀 유휴 정리)는 유휴 연결을 닫을 뿐이다.
    #[tokio::test(start_paused = true)]
    async fn exchange_and_validate_share_the_cold_fetch_backoff() {
        let fx = exchange_fixture_with(
            ExchangeSpec {
                jwks_status: 503,
                ..override_spec()
            },
            |t| Some(t.id_token(json!("it-client"), Some("expected-nonce"))),
        )
        .await;
        assert_auth_err(
            fx.auth
                .exchange_code("c", "v", Some("expected-nonce"))
                .await,
            "JWKS fetch failed: HTTP 503",
        );
        assert_eq!(fx.jwks_fetches().await, 1);
        let access = fx
            .signer
            .sign(&fx.signer.claims(json!("api://orders"), None), "test-kid");
        match fx.auth.validate(&access).await {
            Err(KeycloakError::Transport(m)) => assert!(m.contains("backing off"), "{m}"),
            other => panic!("expected the shared backoff to fail fast, got {other:?}"),
        }
        assert_eq!(
            fx.jwks_fetches().await,
            1,
            "the backoff opened by the exchange must hold for validate()"
        );
    }

    #[tokio::test]
    async fn exchange_code_rejects_mismatched_nonce_end_to_end() {
        let auth = exchange_fixture(IdTok::Nonce("attacker-nonce")).await;
        assert_auth_err(
            auth.exchange_code("c", "v", Some("expected-nonce")).await,
            "unexpected nonce",
        );
    }

    #[tokio::test]
    async fn exchange_code_rejects_missing_id_token_when_nonce_expected() {
        let auth = exchange_fixture(IdTok::Absent).await;
        assert_auth_err(
            auth.exchange_code("c", "v", Some("expected-nonce")).await,
            "missing id_token",
        );
    }

    #[tokio::test]
    async fn exchange_code_rejects_id_token_without_nonce_claim() {
        let auth = exchange_fixture(IdTok::NoNonceClaim).await;
        assert_auth_err(
            auth.exchange_code("c", "v", Some("expected-nonce")).await,
            "unexpected nonce",
        );
    }

    #[tokio::test]
    async fn exchange_code_accepts_matching_nonce_end_to_end() {
        let auth = exchange_fixture(IdTok::Nonce("expected-nonce")).await;
        let ts = auth
            .exchange_code("c", "v", Some("expected-nonce"))
            .await
            .expect("matching nonce must be accepted");
        assert!(ts.id_token.is_some());
    }

    /// ⚠️ **타입이 안전해도 빈 값은 남는다.** `CoreTokenResponse` 는 `access_token` 이
    /// 문자열이 아니면 역직렬화에서 떨어지지만 **빈 문자열은 통과**시킨다 — 그러면
    /// `refresh()`/`exchange_code()` 가 쓸 수 없는 토큰으로 성공을 돌려주고, 소비자는
    /// 그것을 Bearer 로 실어 보내 매번 401 을 받는다. `token_provider` 와 같은 계약이다.
    #[tokio::test]
    async fn refresh_rejects_empty_access_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "", "token_type": "bearer", "expires_in": 300
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

        assert!(matches!(
            auth.refresh("RT").await,
            Err(KeycloakError::Auth { .. })
        ));
    }

    /// `Other` 문구는 허용 목록이다 — 응답 입력을 인용하지 않는 고정 문구만 옮기고, 나머지는 숨긴다.
    /// ⚠️ 마지막 줄(모르는 문구)을 지우지 말 것 — 상류가 새 문구에 응답을 인용해도 안 새게 하는 것이
    /// 그 갈래이고, 적대적 응답 시험(`tests/hostile_token_response.rs`)은 그 갈래에 닿지 못한다.
    #[test]
    fn other_message_passes_only_fixed_phrases() {
        for fixed in [
            "server returned empty error response",
            "server returned empty response body",
            "failed to prepare request: builder error",
        ] {
            assert_eq!(other_message(fixed), fixed);
        }
        let ct = other_message(
            "unexpected response Content-Type: \"text/plain; t=SECRET-TOKEN\", should be `application/json`",
        );
        assert!(ct.starts_with("unexpected response Content-Type") && !ct.contains("SECRET"));
        assert_eq!(
            other_message("some new upstream phrase quoting SECRET-TOKEN"),
            "unexpected response (detail withheld)"
        );
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

    // ── 공개 클라이언트(시크릿 없음)는 클라이언트 인증을 **보내지 않는다** ──────────────
    //
    // ⚠️ 빈 시크릿은 「시크릿 없음」이 아니다. `oauth2` 5.0.0 은 `Some(ClientSecret(""))` 을
    // 받으면 기본 `AuthType::BasicAuth` 분기를 타 `Authorization: Basic base64(client_id:)` 를
    // 붙이고 `client_id` 를 **본문에서 뺀다**(`oauth2-5.0.0/src/endpoint.rs` 의
    // `match (auth_type, client_secret)`). `None` 이면 그 크레이트가 스스로 RequestBody 로
    // 떨어져 `client_id` 만 싣는다. 즉 `unwrap_or_default()` 한 줄이 공개 클라이언트를
    // **기밀 클라이언트처럼 인증시킨다**.
    //
    // 자매 구현: java 는 `getClientSecret() != null` 로 갈라 `ClientID` 만 싣고
    // (`AuthClientPublicClientTest` 가 `assertNull(req.getAuthorization())` 로 못박는다),
    // go 는 `if a.cfg.ClientSecret != ""` 로 감싼다. rust 만 강제하고 있었다.
    async fn public_client_token_fixture() -> (AuthClient, MockServer) {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "AT", "token_type": "Bearer", "expires_in": 300
            })))
            .mount(&server)
            .await;
        // ⚠️ `with_client_secret` 를 **부르지 않는다** — 그것이 공개 클라이언트다.
        let config = KeycloakConfig::new(server.uri(), "it-realm", "it-client").unwrap();
        let endpoints = OidcEndpoints::new(&config);
        let jwks = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks).unwrap();
        let auth = AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap();
        (auth, server)
    }

    #[tokio::test]
    async fn public_client_sends_no_client_authentication() {
        let (auth, server) = public_client_token_fixture().await;
        let _ = auth.client_credentials_token().await;
        let reqs = server
            .received_requests()
            .await
            .expect("received_requests available");
        let token = reqs
            .iter()
            .find(|r| r.url.path().ends_with("/token"))
            .expect("token endpoint must have been called");
        assert!(
            token.headers.get("authorization").is_none(),
            "공개 클라이언트에 Authorization 이 붙었다: {:?}",
            token.headers.get("authorization")
        );
        let body = String::from_utf8_lossy(&token.body);
        assert!(
            !body.contains("client_secret"),
            "공개 클라이언트 본문에 client_secret 이 실렸다: {body}"
        );
        assert!(
            body.contains("client_id=it-client"),
            "인증을 안 보내면 client_id 는 본문에 실려야 한다: {body}"
        );
    }

    // 대조군 — 시크릿이 있으면 Basic 이 **붙어야** 한다. 없으면 위 테스트가
    // 「이 코드가 인증을 아예 안 보낸다」와 구분되지 않는다.
    #[tokio::test]
    async fn confidential_client_still_sends_basic_auth() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "AT", "token_type": "Bearer", "expires_in": 300
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
        let _ = auth.client_credentials_token().await;
        let reqs = server
            .received_requests()
            .await
            .expect("received_requests available");
        let token = reqs
            .iter()
            .find(|r| r.url.path().ends_with("/token"))
            .expect("token endpoint must have been called");
        assert!(
            token.headers.get("authorization").is_some(),
            "기밀 클라이언트에는 Basic 이 붙어야 한다"
        );
    }

    #[tokio::test]
    async fn public_client_logout_omits_client_secret() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/realms/it-realm/protocol/openid-connect/logout"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
        let config = KeycloakConfig::new(server.uri(), "it-realm", "it-client").unwrap();
        let endpoints = OidcEndpoints::new(&config);
        let jwks = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks).unwrap();
        let auth = AuthClient::new(config, endpoints, reqwest::Client::new(), validator).unwrap();
        auth.logout("rt").await.expect("204 는 성공이어야 한다");
        let reqs = server
            .received_requests()
            .await
            .expect("received_requests available");
        let body = String::from_utf8_lossy(&reqs[0].body).to_string();
        assert!(
            !body.contains("client_secret"),
            "공개 클라이언트 로그아웃에 client_secret 이 실렸다: {body}"
        );
        assert!(body.contains("refresh_token=rt"), "본문: {body}");
    }
}
