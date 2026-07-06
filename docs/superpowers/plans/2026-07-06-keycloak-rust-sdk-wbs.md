# Keycloak Rust SDK Implementation Plan (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 7번째 언어 Rust Keycloak SDK를 다른 6개 언어와 동형(§4 계약)으로 손수 구현 — async-only(tokio), 자체강화 JWT 검증, 단위 + 실제 Keycloak 26.6 Testcontainers 통합테스트, `clippy -D warnings`·`rustfmt`·`cargo-llvm-cov` 커버리지 게이트.

**Architecture:** `rust/` 단일 크레이트 `keycloak-sdk`(Cargo). 계층 `config → auth → jwt → admin → client`(async). admin은 `keycloak` crate 래핑, auth는 `openidconnect` 래핑 + introspect/logout 손수, JWT는 `jsonwebtoken` + 자체 DoS-safe `JwksStore`. 하위 오류는 경계에서 `KeycloakError` enum(thiserror)으로 변환. **공유 reqwest 0.12 클라이언트 1개**(SSRF `redirect::none()`·타임아웃·rustls)를 auth·jwks·admin에 주입.

**Tech Stack:** Rust **1.88+**(edition 2024) · tokio 1.52 · reqwest **0.12**(rustls) · keycloak =26.6.2(reqwest12 feature) · openidconnect =4.0.1 · jsonwebtoken =10.4(rust_crypto) · thiserror 2.0 · async-trait 0.1 · serde · dev: testcontainers 0.27.3 · wiremock 0.6 · rsa(테스트 키생성).

## Global Constraints

- **설계 스펙**: [docs/superpowers/specs/2026-07-06-keycloak-rust-sdk-design.md](../specs/2026-07-06-keycloak-rust-sdk-design.md) — 진실 원천(§4 계약).
- **런타임**: Rust **1.88**(edition 2024). 로컬 툴체인 1.89.0(설치됨). CI 매트릭스 1.88(MSRV)+stable. 배포 crates.io `keycloak-sdk`, 태그 `rust-v*`.
- **⚠️ reqwest 버전 정렬(핵심)**: openidconnect 4.0.1은 **reqwest 0.12**에 고정. keycloak crate는 기본 reqwest 0.13이나 **`reqwest12` feature**로 0.12 사용. → **전 크레이트 reqwest 0.12**로 통일해 공유 `reqwest::Client` 1개(타입 통일). `keycloak = { version="=26.6.2", default-features=false, features=["tags-all","resource-builder","reqwest12"] }`. reqwest 0.12의 rustls feature명은 `rustls-tls`.
- **의존성 핀**: `keycloak "=26.6.2"` · `openidconnect "=4.0.1"`(feature `reqwest`) · `jsonwebtoken "=10.4.0"`(default-features=false, features `rust_crypto`,`use_pem`) · `reqwest "0.12"`(default-features=false, features `json`,`rustls-tls`) · `tokio "1.52"`(features `rt-multi-thread`,`macros`,`time`,`sync`) · `thiserror "2.0"` · `async-trait "0.1"` · `serde "1"`(derive) · `serde_json "1"` · `url "2"`. dev: `testcontainers "0.27.3"` · `wiremock "0.6"` · `rsa "0.9"` · `base64 "0.22"`.
- **§4 계약**: 계층·명명·오류 enum·값타입(`TokenSet`/`ValidatedToken`/`IntrospectionResult`)·보안 불변식을 다른 6개 SDK와 동형. 하위 crate 타입은 파사드 뒤에 숨긴다(문서화된 은닉성 예외: admin representation 노출, raw() 탈출구).
- **오류 경계 변환**: 하위 오류(reqwest·openidconnect `RequestTokenError`·jsonwebtoken `errors::Error`·keycloak `KeycloakError`)를 경계에서 `crate::error::KeycloakError`로 변환. 하위 타입 공개 API 누출 금지.
- **결합 규칙**: `admin`은 `auth`를 직접 알지 못한다 — `keycloak` crate의 `KeycloakTokenSupplier`(async-trait)에 우리 `TokenProvider`를 어댑터로 연결.
- **보안 불변식**(CI 강제): JWT 자체강화(RS256 핀·`none` 구조적 거부·iss 정확·aud 포함·exp 필수·nbf 활성·클록 스큐 30s·DoS-safe JWKS) · 토큰/시크릿 완전 마스킹(수동 `Debug`) · SSRF `redirect::Policy::none()` · TLS on(rustls) · 타임아웃 주입.
- **커버리지 게이트**: `cargo-llvm-cov --fail-under-lines 90`, 네트워크 경계 omit `--ignore-filename-regex '(auth|admin|client)\.rs'`.
- **툴체인**: Rust는 시스템 설치(cargo 1.89.0). 명령은 `rust/`에서 실행. Docker는 통합테스트용(Task 11).

### 확정 crate API (딥리서치 byte-검증 — 아래 코드의 근거)

- **keycloak =26.6.2**: `use keycloak::prelude::reqwest;`(=reqwest 0.12 with reqwest12). `KeycloakAdmin::new(url:&str, token_supplier:TS, client:reqwest::Client)`(client by value). `#[async_trait] trait KeycloakTokenSupplier { async fn get(&self, url:&str) -> Result<String, keycloak::KeycloakError>; }` — 우리 어댑터가 구현(access_token 문자열 반환). 리소스 flat, `realm:&str` 첫 인자: `realm_users_get(realm, brief, ...17 Option..., username, ...) -> Result<Vec<UserRepresentation>, KeycloakError>`, `realm_users_post(realm, UserRepresentation) -> Result<DefaultResponse, KeycloakError>`(`.to_id()->Option<&str>` = 새 id), `realm_users_with_user_id_get(realm, user_id, Option<bool>)`, `realm_users_with_user_id_delete(realm, user_id)`, `realm_clients_get/post/with_client_uuid_get/delete`. `UserRepresentation{ username:Some(..), email:Some(..), enabled:Some(true), ..Default::default() }`, 읽기 `user.id.as_deref()`. 오류 `KeycloakError::{ReqwestFailure(reqwest::Error), HttpFailure{status:u16, body, text}}`. **generic raw get/post 없음** → raw()는 우리 파사드가 내부 `KeycloakAdmin` 노출.
- **openidconnect =4.0.1**(reqwest 0.12): 수동 `CoreClient::new(ClientId, IssuerUrl, JsonWebKeySet::new(vec![])).set_client_secret().set_auth_uri().set_token_uri().set_introspection_url().set_redirect_uri()` → 타입 별칭 `CoreClient<EndpointSet,EndpointNotSet,EndpointSet,EndpointNotSet,EndpointSet,EndpointNotSet>`(exchange 빌더 infallible·no `?`). PKCE `PkceCodeChallenge::new_random_sha256()`. `exchange_client_credentials().request_async(&http).await`, `exchange_code(AuthorizationCode).set_pkce_verifier(v).request_async(&http).await`, `exchange_refresh_token(&RefreshToken).request_async(&http).await`, `introspect(&AccessToken).request_async(&http).await`. `use openidconnect::TokenResponse;` → `.access_token().secret()`·`.refresh_token()`·`.expires_in():Option<Duration>`·`.extra_fields().id_token().map(|t| t.to_string())`. 오류 `RequestTokenError::{ServerResponse(resp), Request(transport), Parse, Other}`(HTTP status 없음·`resp.error()`/`resp.error_description()`). logout는 손수(reqwest POST).
- **jsonwebtoken =10.4.0**(rust_crypto,use_pem): `decode_header(token)->Header`(`header.kid:Option<String>`·`header.alg`). `Validation::new(Algorithm::RS256)`(algorithms=[RS256]·validate_exp=true·**validate_nbf=false→true**·validate_aud=true·**leeway=60→30**·required_spec_claims={exp}). `set_issuer(&[iss])`·`set_audience(&[aud])`. `DecodingKey::from_jwk(&Jwk)`. `jwk::JwkSet{keys:Vec<Jwk>}`·`.find(kid)->Option<&Jwk>`·`jwk.common.key_id`. `decode::<Claims>(token,&key,&validation)->TokenData<Claims>`(`.claims`·`.header`). 테스트 서명: `EncodingKey::from_rsa_pem`·`Header::new(RS256)`+`h.kid`·`encode(&h,&claims,&ek)`. mock JWK: `Jwk{common:CommonParameters{key_id:Some(..),..Default::default()}, algorithm:AlgorithmParameters::RSA(RSAKeyParameters{key_type:RSAKeyType::RSA, n, e})}`. 오류 `errors::Error::kind()->&ErrorKind`(#[non_exhaustive]: ExpiredSignature·InvalidSignature·InvalidIssuer·InvalidAudience·ImmatureSignature·MissingRequiredClaim·InvalidAlgorithm·...).

---

### Task 1: 스캐폴딩 (rust/ · Cargo.toml · 툴 설정)

**Files:**
- Create: `rust/Cargo.toml`
- Create: `rust/src/lib.rs`
- Create: `rust/rustfmt.toml`
- Create: `rust/.gitignore`

**Interfaces:**
- Produces: 크레이트 `keycloak-sdk`(edition 2024·rust-version 1.88). `cargo build`/`clippy`/`fmt`/`test` 실행 가능.

- [ ] **Step 1: `Cargo.toml` 작성**

```toml
[package]
name = "keycloak-sdk"
version = "0.1.0"
edition = "2024"
rust-version = "1.88"
license = "Apache-2.0"
description = "Keycloak SDK for Rust — async OIDC auth + Admin REST, isomorphic with the Java/Python/Node/Go/C#/PHP SDKs"
repository = "https://github.com/xzawed/KeyCloakSDK"

[dependencies]
# ⚠️ reqwest 0.12 everywhere: openidconnect 4.0.1 pins reqwest 0.12; keycloak uses its reqwest12 feature to match.
keycloak = { version = "=26.6.2", default-features = false, features = ["tags-all", "resource-builder", "reqwest12"] }
openidconnect = { version = "=4.0.1", default-features = false, features = ["reqwest"] }
jsonwebtoken = { version = "=10.4.0", default-features = false, features = ["rust_crypto", "use_pem"] }
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
tokio = { version = "1.52", features = ["rt-multi-thread", "macros", "time", "sync"] }
thiserror = "2.0"
async-trait = "0.1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
url = "2"

[dev-dependencies]
tokio = { version = "1.52", features = ["rt-multi-thread", "macros", "time", "sync", "test-util"] }
wiremock = "0.6"
testcontainers = "0.27.3"
rsa = "0.9"
base64 = "0.22"
```

- [ ] **Step 2: `src/lib.rs` 초기 작성 (모듈 선언 + 재수출 스텁)**

```rust
//! Keycloak SDK for Rust — async OIDC auth + Admin REST.
#![forbid(unsafe_code)]

pub mod config;
pub mod error;
pub mod tokens;
pub mod oidc;
pub mod token_provider;
pub mod jwks;
pub mod jwt;
pub mod auth;
pub mod admin;
pub mod client;

pub use config::KeycloakConfig;
pub use error::{AdminError, KeycloakError};
pub use tokens::{AuthorizationRequest, IntrospectionResult, TokenSet, ValidatedToken};
pub use token_provider::{ClientCredentialsTokenProvider, TokenProvider};
pub use client::KeycloakClient;
```

> 주: 이후 태스크가 각 모듈을 채운다. Task 1에서는 빈 모듈 파일을 만들어 컴파일되게 한다(각 `pub mod`에 대응하는 `src/<name>.rs`를 빈 파일 또는 최소 스텁으로 생성). 실제로는 Task 2~10이 채우므로, Task 1은 `error.rs`·`config.rs` 등 빈 파일 + `lib.rs`의 `pub use`를 주석 처리한 상태로 시작해 `cargo build`가 통과하게 하고, 각 태스크가 해당 모듈과 재수출을 활성화한다.

- [ ] **Step 3: 빈 모듈 스텁 생성**

각 모듈을 빈 파일로 생성(Task별로 채움): `rust/src/{config,error,tokens,oidc,token_provider,jwks,jwt,auth,admin,client}.rs`. `lib.rs`의 `pub use`는 해당 타입이 생기기 전까지 컴파일 에러가 나므로, **Task 1에서는 `lib.rs`를 모듈 선언만 남기고 `pub use`를 주석 처리**한다:

```rust
#![forbid(unsafe_code)]
pub mod config;
pub mod error;
pub mod tokens;
pub mod oidc;
pub mod token_provider;
pub mod jwks;
pub mod jwt;
pub mod auth;
pub mod admin;
pub mod client;
// re-exports 활성화는 각 타입 구현 후(Task 2~10)
```

- [ ] **Step 4: `rustfmt.toml` + `.gitignore`**

`rust/rustfmt.toml`:
```toml
edition = "2024"
```
`rust/.gitignore`:
```
/target
Cargo.lock
```

- [ ] **Step 5: 스캐폴딩 검증**

Run:
```bash
cd rust && cargo build 2>&1 | tail -20
cargo fmt --all --check && cargo clippy --all-targets -- -D warnings 2>&1 | tail -5
```
Expected: `cargo build`가 의존성 해석 + 빈 모듈로 컴파일 성공(첫 빌드는 크레이트 다운로드로 수 분). fmt·clippy 통과. (edition 2024 + rust-version 1.88은 로컬 1.89.0로 충족.)

- [ ] **Step 6: Commit**

```bash
git add rust/Cargo.toml rust/src/lib.rs rust/src/*.rs rust/rustfmt.toml rust/.gitignore
git commit -m "feat(rust): 스캐폴딩 — Cargo(keycloak-sdk·edition 2024·MSRV 1.88)·reqwest 0.12 정렬·빈 모듈"
```

---

### Task 2: error.rs (KeycloakError enum)

**Files:**
- Create/Fill: `rust/src/error.rs`

**Interfaces:**
- Produces: `pub enum KeycloakError`(thiserror) 변형 `Config(String)`·`Auth{message:String, oauth_error:Option<String>}`·`Transport(String)`·`Admin(AdminError)`·`TokenValidation(String)`. `pub enum AdminError { NotFound, Conflict, Forbidden, Other{status:u16} }`. `KeycloakError::from_admin_status(status:u16, detail:String) -> Self`. `pub type Result<T> = std::result::Result<T, KeycloakError>`.

- [ ] **Step 1: 구현 + 단위 테스트 (inline)**

`rust/src/error.rs`:
```rust
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
        assert!(matches!(KeycloakError::from_admin_status(404), KeycloakError::Admin(AdminError::NotFound)));
        assert!(matches!(KeycloakError::from_admin_status(409), KeycloakError::Admin(AdminError::Conflict)));
        assert!(matches!(KeycloakError::from_admin_status(403), KeycloakError::Admin(AdminError::Forbidden)));
        assert!(matches!(KeycloakError::from_admin_status(500), KeycloakError::Admin(AdminError::Other { status: 500 })));
    }

    #[test]
    fn auth_carries_oauth_error() {
        let e = KeycloakError::Auth { message: "bad".into(), oauth_error: Some("invalid_client".into()) };
        assert!(matches!(e, KeycloakError::Auth { oauth_error: Some(_), .. }));
    }
}
```

- [ ] **Step 2: lib.rs 재수출 활성화 + 테스트/린트**

`lib.rs`에 `pub use error::{AdminError, KeycloakError};` 추가(주석 해제). Run:
```bash
cd rust && cargo test error:: 2>&1 | tail -5 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -3
```
Expected: error 단위테스트 2개 PASS, clippy 0 warning.

- [ ] **Step 3: Commit**

```bash
git add rust/src/error.rs rust/src/lib.rs
git commit -m "feat(rust): KeycloakError enum(thiserror) — Config/Auth/Transport/Admin(NotFound/Conflict/Forbidden/Other)/TokenValidation + from_admin_status"
```

---

### Task 3: config.rs (KeycloakConfig)

**Files:**
- Create/Fill: `rust/src/config.rs`

**Interfaces:**
- Consumes: `KeycloakError`.
- Produces: `pub struct KeycloakConfig`(Clone) 필드 `server_url, realm, client_id, client_secret:Option<String>, scopes:Vec<String>, connect_timeout:Duration, read_timeout:Duration, clock_skew:u64, redirect_uri:Option<String>`. `KeycloakConfig::builder(server_url, realm, client_id) -> KeycloakConfigBuilder` 또는 `new(...) -> Result<Self>`(필수 검증·후행 슬래시 제거). **수동 `Debug` impl로 client_secret 마스킹**.

- [ ] **Step 1: 구현 + 테스트**

`rust/src/config.rs`:
```rust
//! 불변 설정. client_secret은 수동 Debug로 마스킹(derive는 노출).
use crate::error::{KeycloakError, Result};
use std::time::Duration;

#[derive(Clone)]
pub struct KeycloakConfig {
    pub server_url: String,
    pub realm: String,
    pub client_id: String,
    pub client_secret: Option<String>,
    pub scopes: Vec<String>,
    pub connect_timeout: Duration,
    pub read_timeout: Duration,
    pub clock_skew: u64,
    pub redirect_uri: Option<String>,
}

impl KeycloakConfig {
    /// 필수값 검증 + server_url 후행 슬래시 제거. 기본값: scopes=["openid"], connect 5s, read 30s, skew 30s.
    pub fn new(
        server_url: impl Into<String>,
        realm: impl Into<String>,
        client_id: impl Into<String>,
    ) -> Result<Self> {
        let server_url = server_url.into();
        let realm = realm.into();
        let client_id = client_id.into();
        if server_url.trim().is_empty() {
            return Err(KeycloakError::Config("server_url is required".into()));
        }
        if realm.trim().is_empty() {
            return Err(KeycloakError::Config("realm is required".into()));
        }
        if client_id.trim().is_empty() {
            return Err(KeycloakError::Config("client_id is required".into()));
        }
        Ok(Self {
            server_url: server_url.trim_end_matches('/').to_string(),
            realm,
            client_id,
            client_secret: None,
            scopes: vec!["openid".to_string()],
            connect_timeout: Duration::from_secs(5),
            read_timeout: Duration::from_secs(30),
            clock_skew: 30,
            redirect_uri: None,
        })
    }

    #[must_use]
    pub fn with_client_secret(mut self, secret: impl Into<String>) -> Self {
        self.client_secret = Some(secret.into());
        self
    }
    #[must_use]
    pub fn with_redirect_uri(mut self, uri: impl Into<String>) -> Self {
        self.redirect_uri = Some(uri.into());
        self
    }
}

// 수동 Debug — 시크릿을 절대 노출하지 않는다.
impl std::fmt::Debug for KeycloakConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeycloakConfig")
            .field("server_url", &self.server_url)
            .field("realm", &self.realm)
            .field("client_id", &self.client_id)
            .field("client_secret", &self.client_secret.as_ref().map(|_| "***"))
            .field("scopes", &self.scopes)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_and_trims() {
        let c = KeycloakConfig::new("http://kc:8080/", "it-realm", "it-client").unwrap();
        assert_eq!(c.server_url, "http://kc:8080");
        assert_eq!(c.scopes, vec!["openid".to_string()]);
        assert_eq!(c.clock_skew, 30);
    }

    #[test]
    fn missing_required_fields_err() {
        assert!(KeycloakConfig::new("", "r", "c").is_err());
        assert!(KeycloakConfig::new("http://kc:8080", "", "c").is_err());
        assert!(KeycloakConfig::new("http://kc:8080", "r", "").is_err());
    }

    #[test]
    fn debug_masks_secret() {
        let c = KeycloakConfig::new("http://kc:8080", "r", "c").unwrap().with_client_secret("super-secret");
        let s = format!("{c:?}");
        assert!(!s.contains("super-secret"));
        assert!(s.contains("***"));
    }
}
```

- [ ] **Step 2: 재수출 + 테스트/린트**

`lib.rs`에 `pub use config::KeycloakConfig;`. Run: `cd rust && cargo test config:: 2>&1 | tail -5 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -3`
Expected: config 3개 PASS, clippy 0.

- [ ] **Step 3: Commit**

```bash
git add rust/src/config.rs rust/src/lib.rs
git commit -m "feat(rust): KeycloakConfig(불변·검증·후행슬래시·수동 Debug 마스킹·기본값)"
```

---

### Task 4: tokens.rs + oidc.rs (값타입 + 엔드포인트)

**Files:**
- Create/Fill: `rust/src/tokens.rs`, `rust/src/oidc.rs`

**Interfaces:**
- Produces:
  - `TokenSet`(access_token·token_type·expires_in:u64·refresh_token:Option·id_token:Option·scope:Option·expires_at:Option<u64>) — `is_expired(now:u64, skew:u64)->bool`, 수동 Debug 마스킹. `ValidatedToken`(subject·audience:Vec<String>·issuer·expires_at:Option<u64>·issued_at:Option<u64>). `IntrospectionResult`(active:bool·username:Option·client_id:Option). `AuthorizationRequest`(url:String·state:String·code_verifier:String, 수동 Debug 마스킹).
  - `OidcEndpoints::new(&KeycloakConfig)` → `issuer()`/`token()`/`authorization()`/`introspection()`/`end_session()`/`jwks()` (String).

- [ ] **Step 1: tokens.rs 구현 + 테스트**

`rust/src/tokens.rs`:
```rust
//! 값 타입 — 시크릿 필드는 수동 Debug로 마스킹.
#[derive(Clone)]
pub struct TokenSet {
    pub access_token: String,
    pub token_type: String,
    pub expires_in: u64,
    pub refresh_token: Option<String>,
    pub id_token: Option<String>,
    pub scope: Option<String>,
    pub expires_at: Option<u64>,
}

impl TokenSet {
    /// expires_at(절대 epoch) 기준 만료(스큐 적용). expires_at 없으면 false.
    pub fn is_expired(&self, now: u64, skew: u64) -> bool {
        match self.expires_at {
            Some(at) => now + skew >= at,
            None => false,
        }
    }
}

impl std::fmt::Debug for TokenSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TokenSet")
            .field("token_type", &self.token_type)
            .field("expires_in", &self.expires_in)
            .field("access_token", &"***")
            .field("refresh_token", &self.refresh_token.as_ref().map(|_| "***"))
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug)]
pub struct ValidatedToken {
    pub subject: String,
    pub audience: Vec<String>,
    pub issuer: String,
    pub expires_at: Option<u64>,
    pub issued_at: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct IntrospectionResult {
    pub active: bool,
    pub username: Option<String>,
    pub client_id: Option<String>,
}

#[derive(Clone)]
pub struct AuthorizationRequest {
    pub url: String,
    pub state: String,
    pub code_verifier: String,
}

impl std::fmt::Debug for AuthorizationRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthorizationRequest")
            .field("url", &self.url)
            .field("state", &self.state)
            .field("code_verifier", &"***")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_expired_with_skew() {
        let ts = TokenSet { access_token: "a".into(), token_type: "Bearer".into(), expires_in: 300,
            refresh_token: None, id_token: None, scope: None, expires_at: Some(1300) };
        assert!(!ts.is_expired(1200, 30));
        assert!(ts.is_expired(1290, 30)); // 1290+30 >= 1300
    }

    #[test]
    fn no_expiry_never_expired() {
        let ts = TokenSet { access_token: "a".into(), token_type: "Bearer".into(), expires_in: 0,
            refresh_token: None, id_token: None, scope: None, expires_at: None };
        assert!(!ts.is_expired(9_999_999, 30));
    }

    #[test]
    fn debug_masks_tokens() {
        let ts = TokenSet { access_token: "secret-at".into(), token_type: "Bearer".into(), expires_in: 60,
            refresh_token: Some("secret-rt".into()), id_token: None, scope: None, expires_at: None };
        let s = format!("{ts:?}");
        assert!(!s.contains("secret-at") && !s.contains("secret-rt") && s.contains("***"));
    }
}
```

- [ ] **Step 2: oidc.rs 구현 + 테스트**

`rust/src/oidc.rs`:
```rust
//! OIDC 엔드포인트 조립(네트워크 없음).
use crate::config::KeycloakConfig;

pub struct OidcEndpoints {
    base: String,
}

impl OidcEndpoints {
    pub fn new(config: &KeycloakConfig) -> Self {
        Self { base: format!("{}/realms/{}", config.server_url, config.realm) }
    }
    pub fn issuer(&self) -> String { self.base.clone() }
    pub fn token(&self) -> String { format!("{}/protocol/openid-connect/token", self.base) }
    pub fn authorization(&self) -> String { format!("{}/protocol/openid-connect/auth", self.base) }
    pub fn introspection(&self) -> String { format!("{}/protocol/openid-connect/token/introspect", self.base) }
    pub fn end_session(&self) -> String { format!("{}/protocol/openid-connect/logout", self.base) }
    pub fn jwks(&self) -> String { format!("{}/protocol/openid-connect/certs", self.base) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::KeycloakConfig;

    #[test]
    fn assembly() {
        let c = KeycloakConfig::new("http://kc:8080", "it-realm", "c").unwrap();
        let e = OidcEndpoints::new(&c);
        assert_eq!(e.issuer(), "http://kc:8080/realms/it-realm");
        assert_eq!(e.token(), "http://kc:8080/realms/it-realm/protocol/openid-connect/token");
        assert_eq!(e.introspection(), "http://kc:8080/realms/it-realm/protocol/openid-connect/token/introspect");
        assert_eq!(e.end_session(), "http://kc:8080/realms/it-realm/protocol/openid-connect/logout");
        assert_eq!(e.jwks(), "http://kc:8080/realms/it-realm/protocol/openid-connect/certs");
    }
}
```

- [ ] **Step 3: 재수출 + 테스트/린트 + Commit**

`lib.rs`에 `pub use tokens::{AuthorizationRequest, IntrospectionResult, TokenSet, ValidatedToken};` 및 `pub use oidc::OidcEndpoints;`(oidc 재수출 추가). Run: `cd rust && cargo test tokens:: oidc:: 2>&1 | tail -6 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -3`
Expected: 4개 PASS, clippy 0.
```bash
git add rust/src/tokens.rs rust/src/oidc.rs rust/src/lib.rs
git commit -m "feat(rust): 값타입 TokenSet/ValidatedToken/IntrospectionResult/AuthorizationRequest(수동 Debug 마스킹) + OidcEndpoints"
```

---

### Task 5: token_provider.rs (TokenProvider + ClientCredentialsTokenProvider)

**Files:**
- Create/Fill: `rust/src/token_provider.rs`

**Interfaces:**
- Consumes: `KeycloakConfig`, `OidcEndpoints`, `TokenSet`, `KeycloakError`, `reqwest::Client`.
- Produces: `#[async_trait] pub trait TokenProvider: Send + Sync { async fn access_token(&self) -> Result<String>; }`. `pub struct ClientCredentialsTokenProvider`(config·endpoints·http:reqwest::Client·cache:tokio::sync::Mutex<Option<TokenSet>>). `ClientCredentialsTokenProvider::new(config, http) -> Self`. `access_token()` = 캐시된 토큰(만료 전 재사용, single-flight via Mutex), 만료 시 client-credentials POST.

- [ ] **Step 1: 구현 + 테스트(wiremock)**

`rust/src/token_provider.rs`:
```rust
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
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl ClientCredentialsTokenProvider {
    pub fn new(config: KeycloakConfig, http: reqwest::Client) -> Self {
        let token_url = OidcEndpoints::new(&config).token();
        Self { config, token_url, http, cache: Mutex::new(None) }
    }

    async fn fetch(&self) -> Result<TokenSet> {
        let params = [
            ("grant_type", "client_credentials"),
            ("client_id", self.config.client_id.as_str()),
            ("client_secret", self.config.client_secret.as_deref().unwrap_or("")),
            ("scope", "openid"),
        ];
        let resp = self.http.post(&self.token_url).form(&params).send().await
            .map_err(|e| KeycloakError::Transport(format!("token endpoint: {e}")))?;
        let status = resp.status();
        let body: serde_json::Value = resp.json().await
            .map_err(|e| KeycloakError::Transport(format!("token response: {e}")))?;
        if !status.is_success() || body.get("access_token").is_none() {
            let oauth = body.get("error").and_then(|v| v.as_str()).map(str::to_string);
            return Err(KeycloakError::Auth { message: "client-credentials failed".into(), oauth_error: oauth });
        }
        let expires_in = body.get("expires_in").and_then(serde_json::Value::as_u64).unwrap_or(0);
        Ok(TokenSet {
            access_token: body["access_token"].as_str().unwrap_or_default().to_string(),
            token_type: body.get("token_type").and_then(|v| v.as_str()).unwrap_or("Bearer").to_string(),
            expires_in,
            refresh_token: body.get("refresh_token").and_then(|v| v.as_str()).map(str::to_string),
            id_token: None,
            scope: body.get("scope").and_then(|v| v.as_str()).map(str::to_string),
            expires_at: if expires_in > 0 { Some(now_secs() + expires_in) } else { None },
        })
    }
}

#[async_trait]
impl TokenProvider for ClientCredentialsTokenProvider {
    async fn access_token(&self) -> Result<String> {
        let mut guard = self.cache.lock().await; // single-flight: 동시 호출 직렬화
        if let Some(ts) = guard.as_ref() {
            if !ts.is_expired(now_secs(), self.config.clock_skew) {
                return Ok(ts.access_token.clone());
            }
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
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn cfg(server: &str) -> KeycloakConfig {
        KeycloakConfig::new(server, "it-realm", "it-client").unwrap().with_client_secret("s")
    }

    #[tokio::test]
    async fn fetches_and_caches() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "AT", "token_type": "Bearer", "expires_in": 300
            })))
            .expect(1) // 두 번째 access_token()은 캐시 → 네트워크 1회만
            .mount(&server).await;
        let p = ClientCredentialsTokenProvider::new(cfg(&server.uri()), reqwest::Client::new());
        assert_eq!(p.access_token().await.unwrap(), "AT");
        assert_eq!(p.access_token().await.unwrap(), "AT");
    }

    #[tokio::test]
    async fn oauth_error_mapped() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path("/realms/it-realm/protocol/openid-connect/token"))
            .respond_with(ResponseTemplate::new(401).set_body_json(serde_json::json!({"error":"invalid_client"})))
            .mount(&server).await;
        let p = ClientCredentialsTokenProvider::new(cfg(&server.uri()), reqwest::Client::new());
        assert!(matches!(p.access_token().await, Err(KeycloakError::Auth { .. })));
    }
}
```

- [ ] **Step 2: 재수출 + 테스트/린트 + Commit**

`lib.rs`에 `pub use token_provider::{ClientCredentialsTokenProvider, TokenProvider};`. Run: `cd rust && cargo test token_provider:: 2>&1 | tail -6 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -3`
Expected: 2개 PASS(캐시=네트워크 1회 검증), clippy 0.
```bash
git add rust/src/token_provider.rs rust/src/lib.rs
git commit -m "feat(rust): TokenProvider trait(async) + ClientCredentialsTokenProvider(캐시·single-flight·오류변환)"
```

---

### Task 6: jwks.rs (DoS-safe JWKS 스토어)

**Files:**
- Create/Fill: `rust/src/jwks.rs`

**Interfaces:**
- Consumes: `KeycloakError`, `reqwest::Client`, `jsonwebtoken::jwk::{Jwk, JwkSet}`.
- Produces: `pub struct JwksStore`(jwks_uri·http·cache:RwLock<Option<Arc<JwkSet>>>·refetch:Mutex<Option<u64>>·min_refetch:u64). `JwksStore::new(jwks_uri, http, min_refetch_secs) -> Self`. `async fn get_key(&self, kid:&str) -> Result<Jwk>` — 캐시 히트=네트워크 0, 미해결 kid만 재조회(rate-limit + single-flight via Mutex), 위조 서명은 재조회 안 함(kid만 봄).

- [ ] **Step 1: 구현 + 테스트(wiremock, 호출 카운트)**

`rust/src/jwks.rs`:
```rust
//! DoS-safe JWKS: kid 캐시, 미해결 kid만 재조회, rate-limit + single-flight.
use crate::error::{KeycloakError, Result};
use jsonwebtoken::jwk::{Jwk, JwkSet};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex, RwLock};

pub struct JwksStore {
    jwks_uri: String,
    http: reqwest::Client,
    cache: RwLock<Option<Arc<JwkSet>>>,
    refetch_gate: Mutex<Option<u64>>, // 마지막 재조회 시각(초); single-flight + rate-limit
    min_refetch: u64,
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl JwksStore {
    pub fn new(jwks_uri: impl Into<String>, http: reqwest::Client, min_refetch_secs: u64) -> Self {
        Self { jwks_uri: jwks_uri.into(), http, cache: RwLock::new(None),
               refetch_gate: Mutex::new(None), min_refetch: min_refetch_secs }
    }

    async fn fetch(&self) -> Result<Arc<JwkSet>> {
        let resp = self.http.get(&self.jwks_uri).send().await
            .map_err(|e| KeycloakError::Transport(format!("JWKS fetch: {e}")))?;
        let set: JwkSet = resp.json().await
            .map_err(|e| KeycloakError::Transport(format!("JWKS parse: {e}")))?;
        let arc = Arc::new(set);
        *self.cache.write().await = Some(arc.clone());
        Ok(arc)
    }

    /// kid로 JWK 조회. 캐시 히트=네트워크 0. 미해결 kid만 rate-limited 재조회.
    pub async fn get_key(&self, kid: &str) -> Result<Jwk> {
        // 초기 로드(캐시 없음) — rate-limit 예산 미소모
        {
            let c = self.cache.read().await;
            if let Some(set) = c.as_ref() {
                if let Some(jwk) = set.find(kid) {
                    return Ok(jwk.clone());
                }
            }
        }
        if self.cache.read().await.is_none() {
            let set = self.fetch().await?;
            if let Some(jwk) = set.find(kid) {
                return Ok(jwk.clone());
            }
        }
        // 미해결 kid → single-flight + rate-limit 재조회
        let mut gate = self.refetch_gate.lock().await;
        // gate 획득 후 재확인(다른 태스크가 방금 갱신했을 수 있음)
        if let Some(set) = self.cache.read().await.as_ref() {
            if let Some(jwk) = set.find(kid) {
                return Ok(jwk.clone());
            }
        }
        let now = now_secs();
        if let Some(last) = *gate {
            if now.saturating_sub(last) < self.min_refetch {
                return Err(KeycloakError::TokenValidation(format!("unknown kid '{kid}' (refetch rate-limited)")));
            }
        }
        let set = self.fetch().await?;
        *gate = Some(now);
        set.find(kid).cloned()
            .ok_or_else(|| KeycloakError::TokenValidation(format!("unknown kid '{kid}'")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn jwks_json(kid: &str) -> serde_json::Value {
        serde_json::json!({ "keys": [ { "kty":"RSA","kid":kid,"use":"sig","alg":"RS256",
            "n":"sXchg","e":"AQAB" } ] })
    }

    #[tokio::test]
    async fn cache_hit_no_network_after_first() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .expect(1) // 두 번째 get_key는 캐시
            .mount(&server).await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), reqwest::Client::new(), 60);
        assert_eq!(store.get_key("k1").await.unwrap().common.key_id.as_deref(), Some("k1"));
        assert_eq!(store.get_key("k1").await.unwrap().common.key_id.as_deref(), Some("k1"));
    }

    #[tokio::test]
    async fn unresolved_kid_refetches_once_then_rate_limited() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json("k1")))
            .expect(2) // 초기 로드 + k2 미해결 1회. k3는 rate-limit로 재조회 없음
            .mount(&server).await;
        let store = JwksStore::new(format!("{}/certs", server.uri()), reqwest::Client::new(), 60);
        store.get_key("k1").await.unwrap();        // fetch #1(초기)
        let _ = store.get_key("k2").await;         // 미해결 → refetch #2
        let _ = store.get_key("k3").await;         // rate-limit → refetch 없음
    }
}
```

> 주(테스트 n/e): wiremock의 JWKS는 `find(kid)`가 kid로만 매칭하므로 n/e 값은 실제 유효할 필요가 없다(JwkSet::find는 kid만 본다). JwtValidator 테스트(Task 7)에서 실제 RSA 키로 유효 JWK를 만든다.

- [ ] **Step 2: 재수출(내부 사용이므로 pub(crate)로 충분) + 테스트/린트 + Commit**

`lib.rs`는 `pub mod jwks;`만(공개 재수출 불필요 — JwksStore는 내부). Run: `cd rust && cargo test jwks:: 2>&1 | tail -6 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -3`
Expected: 2개 PASS(캐시 히트·미해결 kid rate-limit 호출카운트), clippy 0.
```bash
git add rust/src/jwks.rs rust/src/lib.rs
git commit -m "feat(rust): JwksStore — DoS-safe JWKS(kid 캐시·미해결만 재조회·rate-limit·single-flight)"
```

---

### Task 7: jwt.rs (JwtValidator — 자체강화, 🔴 보안 핵심)

**Files:**
- Create/Fill: `rust/src/jwt.rs`

**Interfaces:**
- Consumes: `KeycloakConfig`, `OidcEndpoints`, `JwksStore`, `ValidatedToken`, `KeycloakError`, jsonwebtoken.
- Produces: `pub struct JwtValidator`(issuer·audience·clock_skew·jwks:JwksStore). `JwtValidator::new(config, endpoints, jwks) -> Self`. `async fn validate(&self, token:&str) -> Result<ValidatedToken>` — decode_header로 kid → JwksStore → `DecodingKey::from_jwk` → `Validation::new(RS256)`(iss/aud/exp/nbf/skew) → decode → ValidatedToken. jsonwebtoken 오류를 TokenValidation으로 변환.

- [ ] **Step 1: 구현 + 테스트(RSA 키로 실제 서명 — 강화 불변식 전부)**

`rust/src/jwt.rs`:
```rust
//! 자체강화 JWT 검증: RS256 핀(헤더 alg 미신뢰)·none 구조적 거부·iss 정확·aud 포함·exp 필수·nbf·스큐·DoS-safe JWKS.
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::jwks::JwksStore;
use crate::oidc::OidcEndpoints;
use crate::tokens::ValidatedToken;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde::Deserialize;

#[derive(Deserialize)]
struct Claims {
    sub: Option<String>,
    iss: Option<String>,
    #[serde(default)]
    aud: AudField,
    exp: Option<u64>,
    iat: Option<u64>,
}

// aud는 string 또는 array — jsonwebtoken이 aud 포함검사를 하지만, ValidatedToken 매핑용으로 벡터화.
#[derive(Deserialize, Default)]
#[serde(untagged)]
enum AudField {
    One(String),
    Many(Vec<String>),
    #[default]
    None,
}
impl AudField {
    fn into_vec(self) -> Vec<String> {
        match self {
            AudField::One(s) => vec![s],
            AudField::Many(v) => v,
            AudField::None => vec![],
        }
    }
}

pub struct JwtValidator {
    issuer: String,
    audience: String,
    clock_skew: u64,
    jwks: JwksStore,
}

impl JwtValidator {
    pub fn new(config: &KeycloakConfig, endpoints: &OidcEndpoints, jwks: JwksStore) -> Self {
        Self { issuer: endpoints.issuer(), audience: config.client_id.clone(),
               clock_skew: config.clock_skew, jwks }
    }

    pub async fn validate(&self, token: &str) -> Result<ValidatedToken> {
        // (1) 헤더에서 kid만 추출(alg는 검증 선택에 미사용 — RS256 고정 핀)
        let header = jsonwebtoken::decode_header(token)
            .map_err(|e| KeycloakError::TokenValidation(format!("malformed JWT header: {e}")))?;
        let kid = header.kid.as_deref()
            .ok_or_else(|| KeycloakError::TokenValidation("missing kid".into()))?;

        // (2) JWKS에서 kid로 키 → DecodingKey
        let jwk = self.jwks.get_key(kid).await?;
        let key = DecodingKey::from_jwk(&jwk)
            .map_err(|e| KeycloakError::TokenValidation(format!("bad JWKS key: {e}")))?;

        // (3) 강화 Validation: RS256 핀·iss 정확·aud 포함·exp 필수·nbf·스큐
        let mut v = Validation::new(Algorithm::RS256);
        v.algorithms = vec![Algorithm::RS256];
        v.set_issuer(&[self.issuer.as_str()]);
        v.set_audience(&[self.audience.as_str()]);
        v.validate_exp = true;
        v.validate_nbf = true; // 기본 false → 강화
        v.leeway = self.clock_skew; // 기본 60 → config(30)
        v.set_required_spec_claims(&["exp", "iss", "aud"]);

        let data = jsonwebtoken::decode::<Claims>(token, &key, &v)
            .map_err(|e| KeycloakError::TokenValidation(format!("token verification failed: {}", e.kind_str())))?;

        let claims = data.claims;
        Ok(ValidatedToken {
            subject: claims.sub.unwrap_or_default(),
            audience: claims.aud.into_vec(),
            issuer: claims.iss.unwrap_or_default(),
            expires_at: claims.exp,
            issued_at: claims.iat,
        })
    }
}

// jsonwebtoken ErrorKind → 짧은 메시지(원문 노출 최소화). ErrorKind는 #[non_exhaustive].
trait KindStr {
    fn kind_str(&self) -> &'static str;
}
impl KindStr for jsonwebtoken::errors::Error {
    fn kind_str(&self) -> &'static str {
        use jsonwebtoken::errors::ErrorKind as K;
        match self.kind() {
            K::ExpiredSignature => "expired",
            K::ImmatureSignature => "not yet valid (nbf)",
            K::InvalidSignature => "invalid signature",
            K::InvalidIssuer => "issuer mismatch",
            K::InvalidAudience => "audience mismatch",
            K::MissingRequiredClaim(_) => "missing required claim",
            K::InvalidAlgorithm | K::InvalidAlgorithmName | K::MissingAlgorithm => "algorithm not allowed",
            _ => "invalid token",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::KeycloakConfig;
    use base64::Engine;
    use jsonwebtoken::{encode, EncodingKey, Header};
    use rsa::pkcs1::EncodeRsaPrivateKey;
    use rsa::traits::PublicKeyParts;
    use rsa::{RsaPrivateKey, RsaPublicKey};
    use serde_json::json;
    use std::time::{SystemTime, UNIX_EPOCH};
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() }
    fn b64(b: &[u8]) -> String { base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b) }

    struct Fixture { priv_pem: String, jwk: serde_json::Value }

    fn make_key() -> Fixture {
        let mut rng = rand::thread_rng();
        let sk = RsaPrivateKey::new(&mut rng, 2048).unwrap();
        let pk = RsaPublicKey::from(&sk);
        let n = b64(&pk.n().to_bytes_be());
        let e = b64(&pk.e().to_bytes_be());
        let priv_pem = sk.to_pkcs1_pem(rsa::pkcs1::LineEnding::LF).unwrap().to_string();
        let jwk = json!({ "kty":"RSA","kid":"test-kid","use":"sig","alg":"RS256","n":n,"e":e });
        Fixture { priv_pem, jwk }
    }

    async fn validator_for(fx: &Fixture) -> JwtValidator {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"keys":[fx.jwk]})))
            .mount(&server).await;
        // server 수명: MockServer는 drop되면 종료되므로, 테스트에서 store가 즉시 fetch하도록 leak 방지 위해
        // 여기서는 Box::leak로 server를 유지(테스트 전용). 실제로는 각 테스트가 server를 소유.
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client").unwrap();
        let endpoints = OidcEndpoints::new(&cfg);
        let jwks_uri = format!("{}/certs", Box::leak(Box::new(server)).uri());
        let store = JwksStore::new(jwks_uri, reqwest::Client::new(), 60);
        JwtValidator::new(&cfg, &endpoints, store)
    }

    fn sign(fx: &Fixture, claims: serde_json::Value, kid: &str) -> String {
        let mut h = Header::new(Algorithm::RS256);
        h.kid = Some(kid.into());
        let ek = EncodingKey::from_rsa_pem(fx.priv_pem.as_bytes()).unwrap();
        encode(&h, &claims, &ek).unwrap()
    }

    fn good_claims() -> serde_json::Value {
        json!({ "sub":"s1", "iss":"http://kc:8080/realms/it-realm",
                "aud":["it-client","account"], "exp": now()+300, "iat": now() })
    }

    #[tokio::test]
    async fn valid_token_passes() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let vt = v.validate(&sign(&fx, good_claims(), "test-kid")).await.unwrap();
        assert_eq!(vt.subject, "s1");
        assert!(vt.audience.contains(&"it-client".to_string()));
        assert_eq!(vt.issuer, "http://kc:8080/realms/it-realm");
    }

    #[tokio::test]
    async fn rejects_wrong_issuer() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims(); c["iss"] = json!("http://evil/realms/it-realm");
        assert!(matches!(v.validate(&sign(&fx, c, "test-kid")).await, Err(KeycloakError::TokenValidation(_))));
    }

    #[tokio::test]
    async fn rejects_aud_not_containing_client() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims(); c["aud"] = json!(["other-client"]);
        assert!(matches!(v.validate(&sign(&fx, c, "test-kid")).await, Err(KeycloakError::TokenValidation(_))));
    }

    #[tokio::test]
    async fn rejects_expired() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims(); c["exp"] = json!(now()-100);
        assert!(matches!(v.validate(&sign(&fx, c, "test-kid")).await, Err(KeycloakError::TokenValidation(_))));
    }

    #[tokio::test]
    async fn rejects_missing_exp() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims(); c.as_object_mut().unwrap().remove("exp");
        assert!(matches!(v.validate(&sign(&fx, c, "test-kid")).await, Err(KeycloakError::TokenValidation(_))));
    }

    #[tokio::test]
    async fn rejects_unknown_kid() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        assert!(matches!(v.validate(&sign(&fx, good_claims(), "other-kid")).await, Err(KeycloakError::TokenValidation(_))));
    }

    #[tokio::test]
    async fn rejects_tampered_signature() {
        let fx = make_key();
        let other = make_key(); // 다른 키로 서명 → JWKS의 키로 검증 실패
        let v = validator_for(&fx).await;
        let tampered = sign(&other, good_claims(), "test-kid");
        assert!(matches!(v.validate(&tampered).await, Err(KeycloakError::TokenValidation(_))));
    }
}
```

> ⚠️ 구현 주의(테스트): `rsa` 0.9 + `rand` 사용. `Cargo.toml` dev-deps에 `rand = "0.8"` 추가 필요(rsa가 rng를 요구). `rsa::pkcs1::EncodeRsaPrivateKey`·`PublicKeyParts` trait import. `MockServer` 수명은 `Box::leak`로 유지(테스트 전용 — 실제 코드 아님). alg-confusion(HS256 등)·none은 jsonwebtoken이 `Algorithm::RS256` 핀으로 구조적 거부하므로 별도 위조 토큰 구성 불필요하나, 최종 보안리뷰에서 HS256-with-pubkey 공격 프로브를 추가한다.

- [ ] **Step 2: dev-dep 추가 + 테스트/린트 + Commit**

`Cargo.toml` dev-dependencies에 `rand = "0.8"` 추가. Run: `cd rust && cargo test jwt:: 2>&1 | tail -12 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -3`
Expected: 7개 PASS(valid·wrong-iss·aud·expired·missing-exp·unknown-kid·tampered-sig), clippy 0.
```bash
git add rust/src/jwt.rs rust/src/lib.rs rust/Cargo.toml
git commit -m "feat(rust): JwtValidator 자체강화 — RS256 핀·none 거부·iss 정확·aud 포함·exp 필수·nbf·JwksStore(보안 핵심)"
```

---

### Task 8: auth.rs (AuthClient — openidconnect 래핑 + introspect/logout 손수)

**Files:**
- Create/Fill: `rust/src/auth.rs`

**Interfaces:**
- Consumes: openidconnect(CoreClient 등), `KeycloakConfig`, `OidcEndpoints`, `JwtValidator`, `TokenSet`/`IntrospectionResult`/`AuthorizationRequest`/`ValidatedToken`, `TokenProvider`, `KeycloakError`, 공유 `reqwest::Client`.
- Produces: `pub struct AuthClient` — `new(config, endpoints, http, validator) -> Result<Self>`. 메서드: `create_authorization_request()`, `exchange_code(code, code_verifier)`, `client_credentials_token()`, `refresh(refresh_token)`, `validate(access_token)`(→JwtValidator), `introspect(token)`(손수 RFC7662), `logout(refresh_token)`(손수 POST). `AuthClient`가 `TokenProvider` 구현(client-credentials).

> **주(네트워크 경계·커버리지 omit)**: `auth.rs`는 커버리지 게이트에서 omit. 단위 테스트는 introspect 매핑(wiremock)만; 전 흐름은 Task 11 통합.

- [ ] **Step 1: openidconnect CoreClient 타입 별칭 + AuthClient 구현**

`rust/src/auth.rs` — 핵심 구조(딥리서치 byte-검증 API 기반). 구현자는 `cargo check`로 typestate를 확정한다:
```rust
//! AuthClient — openidconnect(auth flows) 래핑 + introspect/logout 손수. 커버리지 omit(네트워크 경계).
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::jwt::JwtValidator;
use crate::oidc::OidcEndpoints;
use crate::token_provider::TokenProvider;
use crate::tokens::{AuthorizationRequest, IntrospectionResult, TokenSet, ValidatedToken};
use async_trait::async_trait;
use openidconnect::core::{CoreClient, CoreJsonWebKey};
use openidconnect::{
    AccessToken, AuthUrl, AuthorizationCode, ClientId, ClientSecret, CsrfToken, EndpointNotSet,
    EndpointSet, IntrospectionUrl, IssuerUrl, JsonWebKeySet, Nonce, PkceCodeChallenge,
    PkceCodeVerifier, RedirectUrl, RefreshToken, Scope, TokenIntrospectionResponse, TokenResponse,
    TokenUrl,
};
use openidconnect::core::CoreResponseType;
use openidconnect::AuthenticationFlow;
use std::time::{SystemTime, UNIX_EPOCH};

// 수동 EndpointSet 구성(exchange 빌더 infallible) — 마커 순서: auth,device,introspection,revocation,token,userinfo.
type KcOidcClient = CoreClient<EndpointSet, EndpointNotSet, EndpointSet, EndpointNotSet, EndpointSet, EndpointNotSet>;

pub struct AuthClient {
    config: KeycloakConfig,
    endpoints: OidcEndpoints,
    http: reqwest::Client,
    oidc: KcOidcClient,
    validator: JwtValidator,
}

fn now_secs() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) }

impl AuthClient {
    pub fn new(config: KeycloakConfig, endpoints: OidcEndpoints, http: reqwest::Client, validator: JwtValidator) -> Result<Self> {
        let base = endpoints.issuer();
        let oidc = CoreClient::new(
            ClientId::new(config.client_id.clone()),
            IssuerUrl::new(base.clone()).map_err(|e| KeycloakError::Config(format!("issuer url: {e}")))?,
            JsonWebKeySet::<CoreJsonWebKey>::new(Vec::new()), // 비어있음: id_token 검증에 미사용(자체 validator)
        )
        .set_client_secret(ClientSecret::new(config.client_secret.clone().unwrap_or_default()))
        .set_auth_uri(AuthUrl::new(endpoints.authorization()).map_err(|e| KeycloakError::Config(format!("auth url: {e}")))?)
        .set_token_uri(TokenUrl::new(endpoints.token()).map_err(|e| KeycloakError::Config(format!("token url: {e}")))?)
        .set_introspection_url(IntrospectionUrl::new(endpoints.introspection()).map_err(|e| KeycloakError::Config(format!("introspect url: {e}")))?)
        .set_redirect_uri(RedirectUrl::new(config.redirect_uri.clone().unwrap_or_else(|| base.clone())).map_err(|e| KeycloakError::Config(format!("redirect uri: {e}")))?);
        Ok(Self { config, endpoints, http, oidc, validator })
    }

    pub fn create_authorization_request(&self) -> AuthorizationRequest {
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        let (url, csrf, _nonce) = self.oidc
            .authorize_url(AuthenticationFlow::<CoreResponseType>::AuthorizationCode, CsrfToken::new_random, Nonce::new_random)
            .add_scope(Scope::new("openid".to_string()))
            .set_pkce_challenge(challenge)
            .url();
        AuthorizationRequest { url: url.to_string(), state: csrf.secret().clone(), code_verifier: verifier.into_secret() }
    }

    pub async fn exchange_code(&self, code: &str, code_verifier: &str) -> Result<TokenSet> {
        let resp = self.oidc
            .exchange_code(AuthorizationCode::new(code.to_string()))
            .set_pkce_verifier(PkceCodeVerifier::new(code_verifier.to_string()))
            .request_async(&self.http).await
            .map_err(map_token_err)?;
        Ok(to_token_set(&resp))
    }

    pub async fn client_credentials_token(&self) -> Result<TokenSet> {
        let resp = self.oidc.exchange_client_credentials().request_async(&self.http).await.map_err(map_token_err)?;
        Ok(to_token_set(&resp))
    }

    pub async fn refresh(&self, refresh_token: &str) -> Result<TokenSet> {
        let rt = RefreshToken::new(refresh_token.to_string());
        let resp = self.oidc.exchange_refresh_token(&rt).request_async(&self.http).await.map_err(map_token_err)?;
        Ok(to_token_set(&resp))
    }

    pub async fn validate(&self, access_token: &str) -> Result<ValidatedToken> {
        self.validator.validate(access_token).await
    }

    pub async fn introspect(&self, token: &str) -> Result<IntrospectionResult> {
        let at = AccessToken::new(token.to_string());
        let resp = self.oidc.introspect(&at).request_async(&self.http).await.map_err(map_token_err)?;
        Ok(IntrospectionResult {
            active: resp.active(),
            username: resp.username().map(str::to_string),
            client_id: resp.client_id().map(|c| c.as_str().to_string()),
        })
    }

    /// 백채널 로그아웃(refresh_token 무효화). openidconnect에 빌더가 없어 손수 POST.
    pub async fn logout(&self, refresh_token: &str) -> Result<()> {
        let params = [
            ("client_id", self.config.client_id.as_str()),
            ("client_secret", self.config.client_secret.as_deref().unwrap_or("")),
            ("refresh_token", refresh_token),
        ];
        self.http.post(self.endpoints.end_session()).form(&params).send().await
            .map_err(|e| KeycloakError::Transport(format!("logout: {e}")))?;
        Ok(())
    }
}

fn to_token_set(resp: &openidconnect::core::CoreTokenResponse) -> TokenSet {
    let expires_in = resp.expires_in().map(|d| d.as_secs()).unwrap_or(0);
    TokenSet {
        access_token: resp.access_token().secret().clone(),
        token_type: format!("{:?}", resp.token_type()),
        expires_in,
        refresh_token: resp.refresh_token().map(|r| r.secret().clone()),
        id_token: resp.extra_fields().id_token().map(|t| t.to_string()),
        scope: resp.scopes().map(|s| s.iter().map(|x| x.as_str()).collect::<Vec<_>>().join(" ")),
        expires_at: if expires_in > 0 { Some(now_secs() + expires_in) } else { None },
    }
}

fn map_token_err<RE, T>(e: openidconnect::RequestTokenError<RE, T>) -> KeycloakError
where
    RE: std::error::Error,
    T: openidconnect::ErrorResponse,
{
    use openidconnect::RequestTokenError as RTE;
    match e {
        RTE::ServerResponse(resp) => KeycloakError::Auth {
            message: "token endpoint rejected".into(),
            oauth_error: Some(format!("{}", resp.error())),
        },
        RTE::Request(re) => KeycloakError::Transport(format!("token request: {re}")),
        other => KeycloakError::Transport(format!("token request failed: {other}")),
    }
}

// AuthClient는 client-credentials 소스로서 TokenProvider 구현(admin 접착).
#[async_trait]
impl TokenProvider for AuthClient {
    async fn access_token(&self) -> Result<String> {
        Ok(self.client_credentials_token().await?.access_token)
    }
}

#[cfg(test)]
mod tests {
    // introspect 매핑 스모크(wiremock). 전 흐름은 Task 11 통합.
    // 구현자: openidconnect introspect가 wiremock 응답을 파싱하는지 확인.
}
```

> ⚠️ 구현 주의(auth): openidconnect 4.0 API는 제네릭·typestate가 무거우므로 **각 메서드를 `cargo check`로 확정**하라(특히 `map_token_err`의 제네릭 바운드 `T: ErrorResponse`, `CoreTokenResponse` 경로, `token_type()`의 Display/Debug). `map_token_err`가 컴파일 문제 시 구체 타입으로 단순화. introspect 단위테스트는 wiremock으로 token/introspect 200 응답(`{"active":true,...}`)을 목킹해 `IntrospectionResult{active:true}` 확인(선택). SSRF·타임아웃은 공유 http(Task 10)에서 주입.

- [ ] **Step 2: 컴파일 확인 + 재수출 + Commit**

`lib.rs`에 `pub use auth::AuthClient;`. Run: `cd rust && cargo build 2>&1 | tail -20 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -5`
Expected: 컴파일 성공(typestate·제네릭 해결), clippy 0. (introspect 매핑 테스트가 있으면 wiremock으로 PASS.)
```bash
git add rust/src/auth.rs rust/src/lib.rs
git commit -m "feat(rust): AuthClient — openidconnect 래핑(수동 EndpointSet·PKCE S256) + introspect/logout 손수 + TokenProvider 구현"
```

---

### Task 9: admin.rs (AdminClient — keycloak crate 래핑 + KeycloakTokenSupplier 어댑터 + raw())

**Files:**
- Create/Fill: `rust/src/admin.rs`

**Interfaces:**
- Consumes: `keycloak::{KeycloakAdmin, KeycloakTokenSupplier, KeycloakError as KcError}`, `keycloak::types::{UserRepresentation, ClientRepresentation}`, `KeycloakConfig`, `TokenProvider`, `crate::error::KeycloakError`, 공유 `reqwest::Client`(keycloak::prelude::reqwest).
- Produces: `pub struct AdminClient` — `new(config, http, token_provider:Arc<dyn TokenProvider>) -> Self`. `users()`·`clients()` 등 얇은 래퍼(keycloak crate 호출 + 오류 경계 변환). `raw() -> &KeycloakAdmin<SdkTokenSupplier>`(탈출구). `SdkTokenSupplier`(우리 TokenProvider를 keycloak `KeycloakTokenSupplier`로 어댑트).

> **주(네트워크 경계·커버리지 omit)**: `admin.rs`는 omit. 오류 변환 헬퍼는 단위 테스트(keycloak::KeycloakError 구성)로 검증하되, CRUD는 Task 11 통합.

- [ ] **Step 1: 구현**

`rust/src/admin.rs`:
```rust
//! AdminClient — keycloak crate 래핑. TokenProvider를 KeycloakTokenSupplier로 어댑트(admin↔auth 결합=TokenProvider).
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::token_provider::TokenProvider;
use async_trait::async_trait;
use keycloak::prelude::reqwest;
use keycloak::types::{ClientRepresentation, UserRepresentation};
use keycloak::{KeycloakAdmin, KeycloakError as KcError, KeycloakTokenSupplier};
use std::sync::Arc;

// 우리 TokenProvider → keycloak crate의 KeycloakTokenSupplier(#[async_trait]).
pub struct SdkTokenSupplier {
    inner: Arc<dyn TokenProvider>,
}

#[async_trait]
impl KeycloakTokenSupplier for SdkTokenSupplier {
    async fn get(&self, _url: &str) -> std::result::Result<String, KcError> {
        // 우리 오류를 keycloak::KeycloakError로 변환(어댑터 경계). 토큰 획득 실패는 transport로 취급.
        self.inner.access_token().await
            .map_err(|e| KcError::HttpFailure { status: 401, body: None, text: format!("token supplier: {e}") })
    }
}

pub struct AdminClient {
    admin: KeycloakAdmin<SdkTokenSupplier>,
    realm: String,
}

/// keycloak::KeycloakError → 우리 KeycloakError(중앙 변환기).
fn map_admin(e: KcError) -> KeycloakError {
    match e {
        KcError::HttpFailure { status, .. } => KeycloakError::from_admin_status(status),
        KcError::ReqwestFailure(re) => {
            if re.is_timeout() || re.is_connect() {
                KeycloakError::Transport(format!("admin request: {re}"))
            } else {
                KeycloakError::Transport(format!("admin request failed: {re}"))
            }
        }
    }
}

impl AdminClient {
    pub fn new(config: &KeycloakConfig, http: reqwest::Client, token_provider: Arc<dyn TokenProvider>) -> Self {
        let admin = KeycloakAdmin::new(&config.server_url, SdkTokenSupplier { inner: token_provider }, http);
        Self { admin, realm: config.realm.clone() }
    }

    // ── Users ──
    pub async fn create_user(&self, user: UserRepresentation) -> Result<Option<String>> {
        let resp = self.admin.realm_users_post(&self.realm, user).await.map_err(map_admin)?;
        Ok(resp.to_id().map(str::to_string))
    }
    pub async fn get_user(&self, user_id: &str) -> Result<UserRepresentation> {
        self.admin.realm_users_with_user_id_get(&self.realm, user_id, None).await.map_err(map_admin)
    }
    pub async fn search_users(&self, username: &str) -> Result<Vec<UserRepresentation>> {
        self.admin.realm_users_get(&self.realm,
            None, None, None, None, None, None, Some(true), // exact=true
            Some(0), None, None, None, None, Some(20), None, None, Some(username.to_string())).await.map_err(map_admin)
    }
    pub async fn delete_user(&self, user_id: &str) -> Result<()> {
        self.admin.realm_users_with_user_id_delete(&self.realm, user_id).await.map_err(map_admin)?;
        Ok(())
    }

    // ── Clients ──
    pub async fn create_client(&self, client: ClientRepresentation) -> Result<Option<String>> {
        let resp = self.admin.realm_clients_post(&self.realm, client).await.map_err(map_admin)?;
        Ok(resp.to_id().map(str::to_string))
    }
    pub async fn get_client(&self, client_uuid: &str) -> Result<ClientRepresentation> {
        self.admin.realm_clients_with_client_uuid_get(&self.realm, client_uuid).await.map_err(map_admin)
    }
    pub async fn delete_client(&self, client_uuid: &str) -> Result<()> {
        self.admin.realm_clients_with_client_uuid_delete(&self.realm, client_uuid).await.map_err(map_admin)?;
        Ok(())
    }

    /// 탈출구 — 내부 KeycloakAdmin(모든 생성 메서드·representation 접근). 문서화된 은닉성 예외.
    pub fn raw(&self) -> &KeycloakAdmin<SdkTokenSupplier> {
        &self.admin
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use keycloak::KeycloakError as KcError;

    #[test]
    fn maps_admin_status_codes() {
        assert!(matches!(map_admin(KcError::HttpFailure { status: 404, body: None, text: String::new() }),
            KeycloakError::Admin(crate::error::AdminError::NotFound)));
        assert!(matches!(map_admin(KcError::HttpFailure { status: 409, body: None, text: String::new() }),
            KeycloakError::Admin(crate::error::AdminError::Conflict)));
        assert!(matches!(map_admin(KcError::HttpFailure { status: 403, body: None, text: String::new() }),
            KeycloakError::Admin(crate::error::AdminError::Forbidden)));
        assert!(matches!(map_admin(KcError::HttpFailure { status: 500, body: None, text: String::new() }),
            KeycloakError::Admin(crate::error::AdminError::Other { status: 500 })));
    }
}
```

> ⚠️ 구현 주의(admin): `keycloak::prelude::reqwest`를 써서 reqwest 0.13/0.12 타입 정합을 보장(Cargo에서 `reqwest12` feature 활성). `KeycloakTokenSupplier`는 `#[async_trait]`이므로 impl에 `#[async_trait]` 필요. `KcError::HttpFailure`의 `body` 필드 타입은 `Option<KeycloakHttpError>` — 테스트에서 `body: None`. `realm_users_get`의 17개 Option 인자 순서는 딥리서치 시그니처대로(구현자가 `cargo check`로 확정). `map_admin`의 `map_err` 클로저는 각 호출에 인라인. `SdkTokenSupplier::get`의 오류 변환은 어댑터 경계(우리→keycloak).

- [ ] **Step 2: 재수출 + 컴파일/테스트/린트 + Commit**

`lib.rs`에 `pub use admin::AdminClient;`. Run: `cd rust && cargo test admin:: 2>&1 | tail -6 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -5`
Expected: admin 상태매핑 테스트 PASS, 컴파일 성공, clippy 0.
```bash
git add rust/src/admin.rs rust/src/lib.rs
git commit -m "feat(rust): AdminClient — keycloak crate 래핑 + KeycloakTokenSupplier 어댑터 + u16 오류 경계변환 + raw()"
```

---

### Task 10: client.rs (KeycloakClient 통합 진입점)

**Files:**
- Create/Fill: `rust/src/client.rs`

**Interfaces:**
- Consumes: 모든 계층 + 공유 `reqwest::Client`.
- Produces: `pub struct KeycloakClient`. `KeycloakClient::new(config) -> Result<Self>` — **공유 reqwest 1개**(SSRF `redirect::none()`·타임아웃·rustls) 빌드 → JwksStore·JwtValidator·AuthClient(즉시) 조립, AdminClient는 지연. `auth() -> &AuthClient`, `admin() -> &AdminClient`(지연 초기화 OnceCell 또는 즉시). `TokenProvider`(AuthClient)를 admin에 주입.

- [ ] **Step 1: 구현 + 테스트**

`rust/src/client.rs`:
```rust
//! 통합 진입점 — 공유 reqwest 1개(SSRF·타임아웃·TLS)를 auth·jwks·admin에 주입.
use crate::admin::AdminClient;
use crate::auth::AuthClient;
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::jwks::JwksStore;
use crate::jwt::JwtValidator;
use crate::oidc::OidcEndpoints;
use crate::token_provider::TokenProvider;
use keycloak::prelude::reqwest;
use std::sync::Arc;

pub struct KeycloakClient {
    auth: Arc<AuthClient>,
    admin: AdminClient,
}

impl KeycloakClient {
    pub fn new(config: KeycloakConfig) -> Result<Self> {
        let endpoints = OidcEndpoints::new(&config);
        // 공유 reqwest — SSRF 하드닝(redirect none) + 타임아웃 + rustls(TLS on).
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(config.connect_timeout)
            .timeout(config.read_timeout)
            .build()
            .map_err(|e| KeycloakError::Config(format!("http client: {e}")))?;

        let jwks = JwksStore::new(endpoints.jwks(), http.clone(), 60);
        let validator = JwtValidator::new(&config, &endpoints, jwks);
        let auth = Arc::new(AuthClient::new(config.clone(), OidcEndpoints::new(&config), http.clone(), validator)?);
        let admin = AdminClient::new(&config, http.clone(), auth.clone() as Arc<dyn TokenProvider>);
        Ok(Self { auth, admin })
    }

    pub fn auth(&self) -> &AuthClient { &self.auth }
    pub fn admin(&self) -> &AdminClient { &self.admin }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_client() {
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client").unwrap().with_client_secret("s");
        let client = KeycloakClient::new(cfg).unwrap();
        // auth/admin 접근자가 동작(네트워크 없음 — 조립만 검증)
        let _ = client.auth();
        let _ = client.admin();
    }
}
```

> 주: `reqwest::redirect::Policy` 경로는 `keycloak::prelude::reqwest::redirect::Policy`. `AuthClient`를 `Arc<dyn TokenProvider>`로 admin에 주입(AuthClient가 TokenProvider 구현). admin은 즉시 조립(지연이 필요하면 `OnceCell`; 여기선 단순 즉시 — client-secret 있으면 안전).

- [ ] **Step 2: 재수출 + 테스트/린트 + 전체 단위 스위트 + Commit**

`lib.rs`에 `pub use client::KeycloakClient;`. Run:
```bash
cd rust && cargo test 2>&1 | tail -8 && cargo clippy --all-targets -- -D warnings 2>&1 | tail -3 && cargo fmt --all --check
```
Expected: 전체 단위테스트 PASS(config·error·tokens·oidc·token_provider·jwks·jwt·admin·client), clippy 0, fmt 통과.
```bash
git add rust/src/client.rs rust/src/lib.rs
git commit -m "feat(rust): KeycloakClient 통합 진입점(공유 reqwest·SSRF redirect none·auth 즉시·admin 주입)"
```

- [ ] **Step 3: 커버리지 게이트 확인**

Run: `cd rust && cargo install cargo-llvm-cov --locked 2>&1 | tail -2; cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90 2>&1 | tail -15`
Expected: 로직 모듈(config·error·tokens·oidc·token_provider·jwks·jwt) 라인 커버리지 ≥90%, 게이트 통과.

---

### Task 11: 통합 테스트 (Testcontainers, 실제 Keycloak 26.6)

**Files:**
- Create: `rust/tests/integration_test.rs`
- Create: `rust/tests/testdata/it-realm-realm.json` (다른 언어에서 복사)

**Interfaces:**
- Consumes: `testcontainers`(GenericImage), `keycloak_sdk::{KeycloakClient, KeycloakConfig}`, `keycloak::types::UserRepresentation`.
- Produces: E2E `#[ignore]` 테스트 — 실제 KC 26.6: client-credentials → validate(다중 aud) → introspect → user create/search/get/delete → delete 후 get→NotFound → raw() 스모크.

- [ ] **Step 1: realm JSON 복사**

Run: `cp go/testdata/it-realm-realm.json rust/tests/testdata/it-realm-realm.json`
Expected: 파일 존재(confidential client `it-client` + service account + audience 매퍼).

- [ ] **Step 2: 통합 테스트 작성**

`rust/tests/integration_test.rs` — testcontainers 0.27.3 GenericImage로 KC 26.6 기동. **정확한 testcontainers API는 `cargo doc --open`/vendor로 확인**(0.27 빌더). 골격:
```rust
//! 실제 Keycloak 26.6 E2E. 실행: cargo test --test integration_test -- --ignored (Docker 필요)
use keycloak::types::UserRepresentation;
use keycloak_sdk::{KeycloakClient, KeycloakConfig};
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{GenericImage, ImageExt};

async fn start_keycloak() -> (testcontainers::ContainerAsync<GenericImage>, String) {
    let realm = std::fs::read_to_string("tests/testdata/it-realm-realm.json").unwrap();
    let image = GenericImage::new("quay.io/keycloak/keycloak", "26.6")
        .with_exposed_port(8080.tcp())
        .with_wait_for(WaitFor::message_on_stdout("Listening on:"))
        .with_env_var("KC_BOOTSTRAP_ADMIN_USERNAME", "admin")
        .with_env_var("KC_BOOTSTRAP_ADMIN_PASSWORD", "admin")
        .with_env_var("KC_HEALTH_ENABLED", "true")
        .with_cmd(vec!["start-dev", "--import-realm"])
        .with_copy_to("/opt/keycloak/data/import/it-realm-realm.json", realm.into_bytes());
    let container = image.start().await.unwrap();
    let port = container.get_host_port_ipv4(8080).await.unwrap();
    (container, format!("http://localhost:{port}"))
}

#[tokio::test]
#[ignore] // Docker 필요
async fn full_flow() {
    let (_c, base) = start_keycloak().await;
    let cfg = KeycloakConfig::new(base, "it-realm", "it-client").unwrap().with_client_secret("it-secret");
    let client = KeycloakClient::new(cfg).unwrap();

    // 1) client-credentials
    let token = client.auth().client_credentials_token().await.unwrap();
    assert!(!token.access_token.is_empty());

    // 2) validate(실 JWKS·RS256 강화)
    let vt = client.auth().validate(&token.access_token).await.unwrap();
    assert!(vt.audience.contains(&"it-client".to_string()));
    assert!(vt.issuer.ends_with("/realms/it-realm"));

    // 3) introspect
    let ir = client.auth().introspect(&token.access_token).await.unwrap();
    assert!(ir.active);

    // 4) user CRUD
    let uname = format!("rust-it-{}", &token.access_token[..6].replace('.', ""));
    client.admin().create_user(UserRepresentation {
        username: Some(uname.clone()), email: Some(format!("{uname}@e.com")),
        enabled: Some(true), ..Default::default() }).await.unwrap();
    let found = client.admin().search_users(&uname).await.unwrap();
    let id = found.first().and_then(|u| u.id.clone()).unwrap();
    let got = client.admin().get_user(&id).await.unwrap();
    assert_eq!(got.username.as_deref(), Some(uname.as_str()));
    client.admin().delete_user(&id).await.unwrap();

    // 5) delete 후 조회 → NotFound
    let err = client.admin().get_user(&id).await.unwrap_err();
    assert!(matches!(err, keycloak_sdk::KeycloakError::Admin(keycloak_sdk::AdminError::NotFound)));
}
```

> ⚠️ 구현 주의(통합): testcontainers 0.27.3의 정확한 API(`GenericImage::new`·`with_exposed_port(8080.tcp())`·`with_wait_for`·`with_copy_to`·`start()`·`get_host_port_ipv4`)를 vendor 소스로 확인해 조정(0.27은 pre-1.0). WaitFor는 KC start-dev 준비 로그(예: "Listening on:") 또는 health 엔드포인트 폴링. 첫 실행은 이미지 pull로 수 분(사전 `docker pull quay.io/keycloak/keycloak:26.6` 권장). realm import는 `--import-realm` + `with_copy_to`. **SDK 코드는 수정 금지** — 실 KC로 버그 발견 시 보고.

- [ ] **Step 3: 통합 실행(Docker 필요) + Commit**

Run: `cd rust && cargo test --test integration_test -- --ignored 2>&1 | tail -10`
Expected: `full_flow` PASS(실제 KC 26.6, 전 흐름). Docker Desktop 실행 필요.
```bash
git add rust/tests
git commit -m "feat(rust): 통합테스트 — testcontainers 실제 KC 26.6 E2E(토큰·validate·introspect·user CRUD·raw·delete→NotFound)"
```

---

### Task 12: CI · 릴리스 · 문서

**Files:**
- Create: `.github/workflows/rust-ci.yml`, `.github/workflows/rust-release.yml`
- Create: `rust/examples/quickstart.rs`
- Create: `docs/governance/verification-log-rust.md`
- Modify: `docs/guides/getting-started.md`, `README.md`, `CLAUDE.md`, `docs/roadmap/language-support.md`

- [ ] **Step 1: `rust-ci.yml` 작성**

```yaml
name: rust-ci
on:
  push: { paths: ['rust/**', '.github/workflows/rust-ci.yml'] }
  pull_request: { paths: ['rust/**', '.github/workflows/rust-ci.yml'] }
permissions: { contents: read }
jobs:
  build-test:
    runs-on: ubuntu-latest
    strategy: { matrix: { rust: ['1.88', 'stable'] } }
    defaults: { run: { working-directory: rust } }
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@master
        with: { toolchain: '${{ matrix.rust }}', components: 'clippy,rustfmt' }
      - run: cargo build --all-targets
      - run: cargo fmt --all --check
      - run: cargo clippy --all-targets -- -D warnings
      - run: cargo test
  coverage:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: rust } }
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: taiki-e/install-action@cargo-llvm-cov
      - run: cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90
  integration:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: rust } }
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo test --test integration_test -- --ignored
```

- [ ] **Step 2: `rust-release.yml` (human-gated)**

```yaml
name: rust-release
on:
  push: { tags: ['rust-v*'] }
permissions: { contents: read }
jobs:
  publish:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: rust } }
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo build && cargo test
      - run: cargo publish --token "${CARGO_REGISTRY_TOKEN}"
        env: { CARGO_REGISTRY_TOKEN: '${{ secrets.CARGO_REGISTRY_TOKEN }}' }
```

> 주: `cargo publish`는 crates.io에 실배포 — `CARGO_REGISTRY_TOKEN` 시크릿 필요(human-gated; 미설정 시 실패). 태그 push는 사람이.

- [ ] **Step 3: `examples/quickstart.rs`**

```rust
//! cargo run --example quickstart (KC 필요)
use keycloak::types::UserRepresentation;
use keycloak_sdk::{KeycloakClient, KeycloakConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = KeycloakConfig::new(
        std::env::var("KC_SERVER_URL").unwrap_or_else(|_| "http://localhost:8080".into()),
        std::env::var("KC_REALM").unwrap_or_else(|_| "it-realm".into()),
        std::env::var("KC_CLIENT_ID").unwrap_or_else(|_| "it-client".into()),
    )?.with_client_secret(std::env::var("KC_CLIENT_SECRET").unwrap_or_else(|_| "it-secret".into()));

    let client = KeycloakClient::new(cfg)?;
    let token = client.auth().client_credentials_token().await?;
    println!("token type: {}, expires in: {}s", token.token_type, token.expires_in);
    let validated = client.auth().validate(&token.access_token).await?;
    println!("subject: {}, issuer: {}", validated.subject, validated.issuer);
    client.admin().create_user(UserRepresentation {
        username: Some("demo-user".into()), email: Some("demo@example.com".into()),
        enabled: Some(true), ..Default::default() }).await?;
    println!("created demo-user");
    Ok(())
}
```

- [ ] **Step 4: 빌드 검증**

Run: `cd rust && cargo build --examples 2>&1 | tail -5`
Expected: quickstart 예제 컴파일 성공.

- [ ] **Step 5: 문서 갱신**

- `docs/guides/getting-started.md`: Rust 섹션(설치 `cargo add keycloak-sdk`[미배포—로컬 path], QuickStart, 언어 매핑표에 Rust 열).
- `README.md`: 지원 언어에 Rust 추가(7번째), 매트릭스 행.
- `CLAUDE.md`: "7번째 언어: Rust 1.88+ · `keycloak` crate 래핑(admin) + `openidconnect`(auth) + `jsonwebtoken` 자체 JWT 검증(async-only)" · 프로젝트 구조 `rust/` · Rust 툴체인 섹션(cargo 명령·MSRV 1.88·llvm-cov·⚠️reqwest 0.12 정렬) · 게차(reqwest 버전 정렬·openidconnect typestate/access-token 미검증·jsonwebtoken nbf/leeway 기본값·JWKS DoS 자체·SSRF·RUSTSEC rsa Marvin 무영향·testcontainers pre-1.0) · 테스트 수 · 배포명 crates.io `keycloak-sdk`.
- `docs/roadmap/language-support.md`: Rust 행 계획→완료, 현황 매트릭스 채움("일곱 가지").
- `docs/governance/verification-log-rust.md`(신규): 태스크별 게이트 이력.

- [ ] **Step 6: 최종 검증 + Commit**

Run:
```bash
cd rust && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings && cargo test && cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90 2>&1 | tail -5
```
Expected: fmt·clippy·test·커버리지 게이트 전부 통과.
```bash
git add .github/workflows/rust-ci.yml .github/workflows/rust-release.yml rust/examples docs/guides/getting-started.md README.md CLAUDE.md docs/roadmap/language-support.md docs/governance/verification-log-rust.md
git commit -m "ci+docs(rust): rust-ci(매트릭스 1.88·stable·clippy·llvm-cov 게이트·Docker 통합)·rust-release(crates.io human-gated)·getting-started·README·CLAUDE·로드맵·verification-log"
```

---

## Self-Review (작성자 체크)

**Spec coverage(스펙 §별 대응):**
- §2 크레이트 → Task 1 Cargo + 전 태스크 사용. ✅
- §3 아키텍처/계층 → Task 2(error)·3(config)·4(tokens/oidc)·5(token_provider)·6(jwks)·7(jwt)·8(auth)·9(admin)·10(client). ✅
- §4 오류 경계 변환 → Task 2(enum)·5·6·7·8(map_token_err)·9(map_admin). ✅
- §5 보안 불변식 → Task 6(JWKS DoS)·7(alg핀·none·iss·aud·exp/nbf)·3(마스킹)·10(SSRF redirect none·타임아웃). ✅
- §6 툴체인/테스트/CI → Task 1·10(coverage)·11(통합)·12(CI/release). ✅
- §7 테스트 패리티 → Task 7(강화 전부)·11(통합 시나리오). ✅
- §8 게차 → Task 1(reqwest 0.12 정렬)·8(openidconnect typestate)·7(jsonwebtoken 기본값)·9(u16). ✅
- §9 DoD → Task 12 최종검증 + 문서. ✅

**Placeholder scan:** 로직 계층(error/config/tokens/oidc/token_provider/jwks/jwt/client) 완전 코드 + 실 테스트. 네트워크 경계(auth/admin)는 정확 API 코드 + "cargo check로 typestate 확정" 지시(외부 crate 제네릭 검증 — placeholder 아님). 통합·CI·문서 구체. ✅

**Type consistency:** `KeycloakError`/`AdminError` 변형 일관, `TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest` 필드 일관, `TokenProvider::access_token`·`JwksStore::get_key`·`JwtValidator::validate` 시그니처 태스크 간 일치. keycloak/openidconnect/jsonwebtoken API는 딥리서치 byte-검증값. reqwest 0.12 전역 일관. ✅
