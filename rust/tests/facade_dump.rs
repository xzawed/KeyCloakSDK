//! 바닥 계약 — 기본 표현(`{:?}`·`{:#?}`·`{}`)이 비밀을 찍지 않는다 — 을 **손으로 고른 값 타입이
//! 아니라 이 크레이트가 선언한 타입 전부**에 건다. go `facade_dump_test.go`·php `FacadeDumpTest.php`
//! 의 rust 판이다.
//!
//! ⚠️ rust 에는 런타임 리플렉션이 없어서 그 둘의 「비공개 필드까지 걷기」가 옮겨지지 않는다. 대신 셋이다.
//!
//! 1. **파생** — `rust/src/**/*.rs` 의 소스 텍스트에서 struct/enum 선언과, 그중 바닥(`Debug`·`Display`)
//!    을 가진 것(derive · 손 impl · thiserror `derive(Error)`)을 뽑는다. 손 목록이 아니다.
//! 2. **걷기** — 공개 API 로 카나리아를 심어 만든 뿌리에서 공개 접근자로 닿는 SDK 값을 따라가며, 각 값을
//!    **컴파일러가 허락하는** 바닥 경로 전부로 찍는다(autoref 특수화 — 바닥이 없는 타입은 `{:?}` 가
//!    컴파일되지 않으므로 그 자체가 판정이다). 비공개 필드는 그 타입의 `Debug` 출력이 대신 걷는다.
//! 3. **대조** — 바닥이 있는 선언 타입은 전부 걷기에서 찍혀야 하고(열거형은 **변형마다**), 아니면 이유와
//!    함께 면제한다. 바닥이 없는 공개 선언 타입은 전부 프로브 표에 올라 「바닥 없음」이 컴파일 수준에서
//!    단언돼야 한다. 파사드 넷(`AuthClient`·`KeycloakClient`·`AdminClient`·`ClientCredentialsTokenProvider`)
//!    에 `derive(Debug)` 한 줄이 붙으면 — 안의 필드가 스스로 가려 누출이 없더라도 — 여기서 떨어진다.
//!
//! ⚠️ 한계: 카나리아는 뿌리를 만드는 호출이 흘려 넣은 비밀뿐이다. 부분 노출은 8자 조각부터 본다(앞 4자만
//! 보이는 마스킹은 우연 일치와 구분할 수 없다). `macro_rules!` 가 찍어 내는 타입과 `Serialize` 경로는 파생이
//! 보지 않는다(지금 SDK 타입 중 `Serialize` 를 가진 것은 없다).

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use keycloak_sdk::jwks::JwksStore;
use keycloak_sdk::types::UserRepresentation;
use keycloak_sdk::{
    AdminClient, AdminError, AuthClient, AuthorizationRequest, ClientCredentialsTokenProvider,
    IntrospectionResult, JwtValidator, KeycloakAdmin, KeycloakClient, KeycloakConfig,
    KeycloakError, OidcEndpoints, SdkTokenSupplier, TokenProvider, TokenSet, ValidatedToken,
    reqwest,
};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::marker::PhantomData;
use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── 카나리아 ─────────────────────────────────────────────────────────────────────────────
// ⚠️ 원문뿐 아니라 **어느 8자 조각**이든 찍히면 누출로 본다(마스킹 계약: 「접두 노출 없음」). 그래서
// 대문자·하이픈으로 지었다 — 필드 이름(소문자 snake)이나 오류 문구의 8자 조각과 겹치면 안 된다.
const SECRET: &str = "CLIENT-SECRET-CANARY-DUMP";
const ACCESS: &str = "ACCESS-TOKEN-CANARY-DUMP";
const REFRESH: &str = "REFRESH-TOKEN-CANARY-DUMP";
const GARBAGE: &str = "GARBAGE-TOKEN-CANARY-DUMP";
const PASSWORD: &str = "ADMIN-PASSWORD-CANARY-DUMP";
const REALM: &str = "r";
const CLIENT_ID: &str = "c";

/// 걷기에 안 닿아도 되는 **SDK 선언** 바닥 타입과 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다.
const EXEMPT: &[(&str, &str)] = &[];

/// 루트가 재노출하는 foreign 타입(§4(b) 문서화된 은닉성 예외)과 그 이유. 이 타입들의 바닥은 하위
/// crate 의 것이라 이 SDK 가 소유하지 않는다 — 대신 **SDK 가 그 안에 비밀을 심지 않는다**를 이유로 적는다.
const FOREIGN_EXEMPT: &[(&str, &str)] = &[
    (
        "ClientRepresentation",
        "§4(b) admin 데이터 모델 — keycloak crate derive(Debug). SDK 는 소비자 입력·서버 응답을 그대로 옮길 뿐 비밀을 심지 않는다",
    ),
    (
        "GroupRepresentation",
        "§4(b) admin 데이터 모델 — keycloak crate derive(Debug). SDK 가 비밀을 심지 않는다",
    ),
    (
        "RealmRepresentation",
        "§4(b) admin 데이터 모델 — keycloak crate derive(Debug). SDK 가 비밀을 심지 않는다",
    ),
    (
        "RoleRepresentation",
        "§4(b) admin 데이터 모델 — keycloak crate derive(Debug). SDK 가 비밀을 심지 않는다",
    ),
    (
        "UserRepresentation",
        "§4(b) admin 데이터 모델 — keycloak crate derive(Debug) 라 소비자가 넣은 credentials[].value 를 원문으로 찍는다. SDK 는 그 값을 요청으로 옮길 뿐 돌려주지 않는다",
    ),
    (
        "KeycloakAdmin",
        "§4(b) raw() 탈출구 — 바닥이 없다(아래 FOREIGN 프로브가 컴파일 수준에서 단언)",
    ),
    (
        "RawKeycloakError",
        "§4(b) raw() 가 돌려주는 하위 오류 — SDK 경로는 map_admin 이 KeycloakError 로 바꾼다",
    ),
    (
        "Jwk",
        "§4(b) JwksStore::get_key() 의 공개키 JWK — 비밀 재료가 없다",
    ),
];

/// 알려진 누출 — `"뿌리|카나리아"` → 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
const KNOWN_LEAKS: &[(&str, &str)] = &[];

/// 뿌리가 낼 수 없는 **열거형 변형**(`"타입::변형"`)과 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다.
const EXEMPT_VARIANTS: &[(&str, &str)] = &[];

// ── 바닥 프로브(autoref 특수화) ─────────────────────────────────────────────────────────────
// `(&Floor(v)).debug_floor()` 는 `T: Debug` 이면 by-value 단계에서 `Floor<T>` impl 을, 아니면 autoref
// 단계에서 `&Floor<T>` 의 폴백을 고른다. 호출 자리의 **구체 타입**으로 풀리므로 매크로 안에서만 쓴다.

struct Floor<'a, T: ?Sized>(&'a T);

trait DebugFloor {
    fn debug_floor(&self) -> Option<[String; 2]>;
}
impl<T: fmt::Debug + ?Sized> DebugFloor for Floor<'_, T> {
    fn debug_floor(&self) -> Option<[String; 2]> {
        Some([format!("{:?}", self.0), format!("{:#?}", self.0)])
    }
}
trait NoDebugFloor {
    fn debug_floor(&self) -> Option<[String; 2]> {
        None
    }
}
impl<T: ?Sized> NoDebugFloor for &Floor<'_, T> {}

trait DisplayFloor {
    fn display_floor(&self) -> Option<[String; 2]>;
}
impl<T: fmt::Display + ?Sized> DisplayFloor for Floor<'_, T> {
    fn display_floor(&self) -> Option<[String; 2]> {
        Some([format!("{}", self.0), format!("{:#}", self.0)])
    }
}
trait NoDisplayFloor {
    fn display_floor(&self) -> Option<[String; 2]> {
        None
    }
}
impl<T: ?Sized> NoDisplayFloor for &Floor<'_, T> {}

/// 값 → (타입 이름, Debug 두 형태, Display 두 형태). 바닥이 없으면 `None`.
macro_rules! floors {
    ($v:expr) => {{
        let v = $v;
        (
            std::any::type_name_of_val(v),
            (&Floor(v)).debug_floor(),
            (&Floor(v)).display_floor(),
        )
    }};
}

/// 타입 → (타입 이름, Debug 있음, Display 있음). 값이 필요 없다 — 생성 경로가 없는 타입도 잰다.
macro_rules! probe {
    ($t:ty) => {
        (
            std::any::type_name::<$t>(),
            (&TypeFloor::<$t>(PhantomData)).has_debug(),
            (&TypeFloor::<$t>(PhantomData)).has_display(),
        )
    };
}

struct TypeFloor<T: ?Sized>(PhantomData<T>);
trait HasDebug {
    fn has_debug(&self) -> bool;
}
impl<T: fmt::Debug + ?Sized> HasDebug for TypeFloor<T> {
    fn has_debug(&self) -> bool {
        true
    }
}
trait LacksDebug {
    fn has_debug(&self) -> bool {
        false
    }
}
impl<T: ?Sized> LacksDebug for &TypeFloor<T> {}
trait HasDisplay {
    fn has_display(&self) -> bool;
}
impl<T: fmt::Display + ?Sized> HasDisplay for TypeFloor<T> {
    fn has_display(&self) -> bool {
        true
    }
}
trait LacksDisplay {
    fn has_display(&self) -> bool {
        false
    }
}
impl<T: ?Sized> LacksDisplay for &TypeFloor<T> {}

/// 바닥이 **없어야** 하는 공개 SDK 타입. ⚠️ 이 목록은 손으로 쓰지만 아래 대조가 소스에서 파생한
/// 「공개·무바닥 선언」 집합과 **같기**를 요구한다 — 새 공개 타입이 생기면 여기 한 줄이 강제된다.
fn floorless_probes() -> Vec<(&'static str, bool, bool)> {
    vec![
        // 과제가 명시한 파사드 넷 — 비밀(클라이언트 시크릿·캐시된 토큰)을 품는다.
        probe!(AuthClient),
        probe!(KeycloakClient),
        probe!(AdminClient),
        probe!(ClientCredentialsTokenProvider),
        // 나머지 공개 무바닥 선언.
        probe!(JwksStore),
        probe!(JwtValidator),
        probe!(OidcEndpoints),
        probe!(SdkTokenSupplier),
    ]
}

/// `AdminClient::raw()` 가 돌려주는 foreign 타입도 바닥이 없어야 한다 — 안에 `SdkTokenSupplier`(→ 캐시된
/// 토큰을 쥔 provider)가 있다.
fn foreign_probes() -> Vec<(&'static str, bool, bool)> {
    vec![probe!(KeycloakAdmin<SdkTokenSupplier>)]
}

// ── 가짜 IdP ────────────────────────────────────────────────────────────────────────────

struct Key {
    pem: String,
    jwk: serde_json::Value,
}

fn rsa_key() -> Key {
    use rsa::pkcs1::{EncodeRsaPrivateKey, LineEnding};
    use rsa::traits::PublicKeyParts;
    let sk = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).expect("rsa key");
    let pk = rsa::RsaPublicKey::from(&sk);
    Key {
        pem: sk.to_pkcs1_pem(LineEnding::LF).expect("pem").to_string(),
        jwk: json!({"kty":"RSA","kid":"k1","use":"sig","alg":"RS256",
            "n": URL_SAFE_NO_PAD.encode(pk.n().to_bytes_be()),
            "e": URL_SAFE_NO_PAD.encode(pk.e().to_bytes_be())}),
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_secs()
}

fn sign(key: &Key, claims: &serde_json::Value) -> String {
    let mut h = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256);
    h.kid = Some("k1".into());
    let ek = jsonwebtoken::EncodingKey::from_rsa_pem(key.pem.as_bytes()).expect("encoding key");
    jsonwebtoken::encode(&h, claims, &ek).expect("sign")
}

/// 경로로 응답을 고른다(순서 큐가 아니라 호출 순서가 바뀌어도 안 깨진다). 매치되지 않으면 wiremock 404.
async fn mount_idp(server: &MockServer, key: &Key, id_token: &str) {
    let oidc = format!("/realms/{REALM}/protocol/openid-connect");
    let ok = |body: serde_json::Value| ResponseTemplate::new(200).set_body_json(body);
    let mounts = [
        (
            "POST",
            format!("{oidc}/token"),
            ok(json!({
                "access_token": ACCESS, "token_type": "Bearer", "expires_in": 300,
                "refresh_token": REFRESH, "id_token": id_token, "scope": "openid",
            })),
        ),
        (
            "POST",
            format!("{oidc}/token/introspect"),
            ok(json!({"active": true, "username": "svc", "client_id": CLIENT_ID})),
        ),
        (
            "GET",
            format!("{oidc}/certs"),
            ok(json!({"keys": [key.jwk]})),
        ),
        (
            "POST",
            format!("{oidc}/logout"),
            ResponseTemplate::new(401),
        ),
        (
            "POST",
            "/realms/bad/protocol/openid-connect/token".to_string(),
            ResponseTemplate::new(401).set_body_json(
                json!({"error": "invalid_client", "error_description": "Invalid client credentials"}),
            ),
        ),
        (
            "GET",
            format!("/admin/realms/{REALM}/users/missing"),
            ResponseTemplate::new(404),
        ),
        (
            "POST",
            format!("/admin/realms/{REALM}/users"),
            ResponseTemplate::new(409),
        ),
        (
            "GET",
            format!("/admin/realms/{REALM}/roles/forbidden"),
            ResponseTemplate::new(403),
        ),
        (
            "GET",
            format!("/admin/realms/{REALM}/groups/boom"),
            ResponseTemplate::new(500),
        ),
    ];
    for (m, p, resp) in mounts {
        Mock::given(method(m))
            .and(path(p))
            .respond_with(resp)
            .mount(server)
            .await;
    }
}

// ── 뿌리 ─────────────────────────────────────────────────────────────────────────────────

/// 공개 API 로 만든 뿌리와, 그 과정이 흘려 넣은 비밀 전부. 하네스 자신의 객체는 여기 없다 —
/// 뿌리는 전부 SDK 값이고 카나리아는 이름·값 쌍으로만 들고 간다.
struct Fixture {
    cfg: KeycloakConfig,
    client: KeycloakClient,
    injected: AdminClient,
    provider: Arc<ClientCredentialsTokenProvider>,
    low_auth: AuthClient,
    validator: JwtValidator,
    jwks: JwksStore,
    endpoints: OidcEndpoints,
    tokens: Vec<(&'static str, TokenSet)>,
    requests: Vec<(&'static str, AuthorizationRequest)>,
    introspection: IntrospectionResult,
    validated: Vec<(&'static str, ValidatedToken)>,
    errors: Vec<(&'static str, KeycloakError)>,
    canaries: Vec<(&'static str, String)>,
}

/// 실패 호출에서 오류 뿌리를 꺼낸다. 성공하거나 다른 변형이 나면 뿌리를 못 만든 것이다.
macro_rules! fail_as {
    ($what:expr, $call:expr, $pat:pat) => {{
        match $call {
            Err(e @ $pat) => ($what, e),
            Err(other) => panic!("{}: 기대와 다른 실패 — {other:?}", $what),
            Ok(_) => panic!(
                "{}: 실패 뿌리를 못 만들었다 — 가짜 IdP 가 실패를 안 냈다",
                $what
            ),
        }
    }};
}

fn bearer_seen(reqs: &[wiremock::Request], p: &str) -> bool {
    reqs.iter().any(|r| {
        r.url.path() == p
            && r.headers.get("authorization").and_then(|v| v.to_str().ok())
                == Some(format!("Bearer {ACCESS}").as_str())
    })
}

async fn fixture() -> Fixture {
    let key = rsa_key();
    let server = MockServer::start().await;
    let issuer = format!("{}/realms/{REALM}", server.uri());
    let claims = |extra: serde_json::Value| {
        let mut c =
            json!({"iss": issuer, "sub": "u1", "aud": CLIENT_ID, "exp": now() + 300, "iat": now()});
        c.as_object_mut()
            .expect("object")
            .extend(extra.as_object().expect("object").clone());
        c
    };
    // id_token 은 openidconnect 가 JWT 로 파싱하므로 형식이 맞아야 한다 — 그 JWT 문자열 전체가 카나리아다.
    let id_jwt = sign(&key, &claims(json!({"nonce": "server-nonce"})));
    let raw_jwt = sign(&key, &claims(json!({})));
    mount_idp(&server, &key, &id_jwt).await;

    let cfg = KeycloakConfig::new(server.uri(), REALM, CLIENT_ID)
        .expect("config")
        .with_client_secret(SECRET)
        .with_redirect_uri("https://app.example/cb");
    let client = KeycloakClient::new(cfg.clone()).expect("client");
    let http = reqwest::Client::new();
    let mut errors = Vec::new();

    // ── 기본 경로 admin: 내부 provider 가 토큰을 캐시한 **뒤**라야 그 캐시가 뿌리에 들어 있다.
    errors.push(fail_as!(
        "admin get_user 404 (default)",
        client.admin().get_user("missing").await,
        KeycloakError::Admin(AdminError::NotFound)
    ));
    errors.push(fail_as!(
        "admin get_role 403 (default)",
        client.admin().get_role("forbidden").await,
        KeycloakError::Admin(AdminError::Forbidden)
    ));
    errors.push(fail_as!(
        "admin get_group 500 (default)",
        client.admin().get_group("boom").await,
        KeycloakError::Admin(AdminError::Other { .. })
    ));
    // 관리자 비밀번호 — 소비자가 representation 에 넣는 비밀. foreign 이름 없이 공개 API 로만 만든다.
    let mut user = UserRepresentation {
        username: Some("dump-user".into()),
        ..Default::default()
    };
    user.credentials = Some(vec![Default::default()]);
    if let Some(c) = user.credentials.as_mut().and_then(|v| v.first_mut()) {
        c.type_ = Some("password".into());
        c.value = Some(PASSWORD.into());
    }
    errors.push(fail_as!(
        "admin create_user 409 (password)",
        client.admin().create_user(user).await,
        KeycloakError::Admin(AdminError::Conflict)
    ));

    // ── 소비자 주입 경로: SDK 의 캐싱 provider 를 소비자가 직접 만들어 admin 에 꽂는다.
    let provider = Arc::new(ClientCredentialsTokenProvider::new(
        cfg.clone(),
        http.clone(),
    ));
    let provided = provider.access_token().await.expect("provider token");
    let injected = AdminClient::new(&cfg, http.clone(), provider.clone());
    errors.push(fail_as!(
        "admin get_user 404 (injected)",
        injected.get_user("missing").await,
        KeycloakError::Admin(AdminError::NotFound)
    ));

    // ── 인증 표면.
    let auth = client.auth();
    let cc = auth
        .client_credentials_token()
        .await
        .expect("client credentials");
    let refreshed = auth.refresh(REFRESH).await.expect("refresh");
    let ar = auth.create_authorization_request();
    let ar2 = auth
        .create_authorization_request_with_redirect("https://tenant-b.example/cb")
        .expect("per-call redirect");
    let exchanged = auth
        .exchange_code("code", &ar.code_verifier, None)
        .await
        .expect("exchange");
    let introspection = auth.introspect(ACCESS).await.expect("introspect");
    let vt = auth.validate(&raw_jwt).await.expect("validate");

    // ── 저수준 주입 지점(문서화된 공개 생성자).
    let endpoints = OidcEndpoints::new(&cfg);
    let jwks = JwksStore::new(endpoints.jwks(), http.clone(), 30);
    let jwk = jwks.get_key("k1").await.expect("jwks get_key");
    let validator = JwtValidator::new(
        &cfg,
        &endpoints,
        JwksStore::new(endpoints.jwks(), http.clone(), 30),
    )
    .expect("validator");
    let vt_low = validator.validate(&raw_jwt).await.expect("low validate");
    let low_auth = AuthClient::new(
        cfg.clone(),
        OidcEndpoints::new(&cfg),
        http.clone(),
        JwtValidator::new(
            &cfg,
            &endpoints,
            JwksStore::new(endpoints.jwks(), http.clone(), 30),
        )
        .expect("validator"),
    )
    .expect("low-level auth");

    // ── 오류 — 실제 실패 호출에서 얻는다.
    let bad_cfg = KeycloakConfig::new(server.uri(), "bad", CLIENT_ID)
        .expect("config")
        .with_client_secret(SECRET);
    let bad = KeycloakClient::new(bad_cfg.clone()).expect("bad client");
    errors.push(fail_as!(
        "client_credentials_token 401",
        bad.auth().client_credentials_token().await,
        KeycloakError::Auth { .. }
    ));
    errors.push(fail_as!(
        "refresh 401",
        bad.auth().refresh(REFRESH).await,
        KeycloakError::Auth { .. }
    ));
    errors.push(fail_as!(
        "provider access_token 401",
        ClientCredentialsTokenProvider::new(bad_cfg, http.clone())
            .access_token()
            .await,
        KeycloakError::Auth { .. }
    ));
    errors.push(fail_as!(
        "validate garbage",
        auth.validate(GARBAGE).await,
        KeycloakError::TokenValidation(_)
    ));
    errors.push(fail_as!(
        "exchange_code nonce mismatch",
        auth.exchange_code("code", &ar.code_verifier, Some("other-nonce"))
            .await,
        KeycloakError::Auth { .. }
    ));
    errors.push(fail_as!(
        "logout 401",
        auth.logout(REFRESH).await,
        KeycloakError::Auth { .. }
    ));
    errors.push(fail_as!(
        "invalid redirect_uri",
        auth.create_authorization_request_with_redirect("not a url"),
        KeycloakError::Config(_)
    ));
    errors.push(fail_as!(
        "config missing server_url",
        KeycloakConfig::new("", REALM, CLIENT_ID),
        KeycloakError::Config(_)
    ));
    errors.push(fail_as!(
        "client unsupported algorithm",
        KeycloakClient::new(
            cfg.clone()
                .with_signature_algorithms(vec!["NOPE999".to_string()])
        ),
        KeycloakError::Config(_)
    ));
    // 도달 불가 서버 — 동시에 부른다(윈도에서 거부된 연결은 한 번에 수 초가 걸린다).
    let down_cfg = KeycloakConfig::new("http://127.0.0.1:1", REALM, CLIENT_ID)
        .expect("config")
        .with_client_secret(SECRET);
    let down = KeycloakClient::new(down_cfg.clone()).expect("down client");
    let down_provider = ClientCredentialsTokenProvider::new(down_cfg, http.clone());
    let (d_introspect, d_logout, d_cc, d_provider, d_admin) = tokio::join!(
        down.auth().introspect(ACCESS),
        down.auth().logout(REFRESH),
        down.auth().client_credentials_token(),
        down_provider.access_token(),
        down.admin().get_user("u"),
    );
    errors.push(fail_as!(
        "introspect unreachable",
        d_introspect,
        KeycloakError::Transport(_)
    ));
    errors.push(fail_as!(
        "logout unreachable",
        d_logout,
        KeycloakError::Transport(_)
    ));
    errors.push(fail_as!(
        "client_credentials_token unreachable",
        d_cc,
        KeycloakError::Transport(_)
    ));
    errors.push(fail_as!(
        "provider access_token unreachable",
        d_provider,
        KeycloakError::Transport(_)
    ));
    errors.push(fail_as!(
        "admin get_user unreachable",
        d_admin,
        KeycloakError::Admin(_)
    ));

    // ── ⚠️ 흐름 검사 — 카나리아가 실제로 뿌리에 흘렀는가. 안 흘렀으면 누출 검사는 없는 것을 찾으며 통과한다.
    let basic = STANDARD.encode(format!("{CLIENT_ID}:{SECRET}"));
    let reqs = server.received_requests().await.expect("recording");
    let flow = [
        (
            "config.client_secret",
            cfg.client_secret.as_deref() == Some(SECRET),
        ),
        ("client_credentials.access_token", cc.access_token == ACCESS),
        (
            "client_credentials.refresh_token",
            cc.refresh_token.as_deref() == Some(REFRESH),
        ),
        (
            "client_credentials.id_token",
            cc.id_token.as_deref() == Some(id_jwt.as_str()),
        ),
        ("refresh.access_token", refreshed.access_token == ACCESS),
        (
            "exchange_code.id_token",
            exchanged.id_token.as_deref() == Some(id_jwt.as_str()),
        ),
        ("provider.access_token", provided == ACCESS),
        (
            "authorization_request.code_verifier",
            ar.code_verifier.len() >= 43 && ar2.code_verifier.len() >= 43,
        ),
        (
            "introspect.username",
            introspection.active && introspection.username.as_deref() == Some("svc"),
        ),
        (
            "validate.subject",
            vt.subject == "u1" && vt_low.subject == "u1",
        ),
        ("jwks.get_key", jwk.common.key_id.as_deref() == Some("k1")),
        // 기본 경로·주입 경로 admin 의 캐시가 실제로 카나리아 토큰을 쥐었다 — 그 토큰이 Bearer 로 나갔다.
        (
            "default admin cached token",
            bearer_seen(&reqs, &format!("/admin/realms/{REALM}/roles/forbidden")),
        ),
        (
            // users/missing 은 기본 경로와 주입 경로가 한 번씩 친다 — 둘 다 카나리아 Bearer 여야 2 다.
            "default+injected admin cached token (users/missing x2)",
            reqs.iter()
                .filter(|r| r.url.path() == format!("/admin/realms/{REALM}/users/missing"))
                .filter(|r| {
                    r.headers.get("authorization").and_then(|v| v.to_str().ok())
                        == Some(format!("Bearer {ACCESS}").as_str())
                })
                .count()
                == 2,
        ),
        // 비밀번호·시크릿이 실패한 요청에 실제로 실렸다 — 오류가 요청을 품었다면 여기서 샜을 것이다.
        (
            "admin create_user carried password",
            reqs.iter().any(|r| {
                r.url.path() == format!("/admin/realms/{REALM}/users")
                    && String::from_utf8_lossy(&r.body).contains(PASSWORD)
            }),
        ),
        (
            "401 token request carried basic secret",
            reqs.iter().any(|r| {
                r.url.path() == "/realms/bad/protocol/openid-connect/token"
                    && r.headers.get("authorization").and_then(|v| v.to_str().ok())
                        == Some(format!("Basic {basic}").as_str())
            }),
        ),
    ];
    let dry: Vec<_> = flow.iter().filter(|(_, ok)| !ok).map(|(n, _)| *n).collect();
    assert!(
        dry.is_empty(),
        "카나리아가 뿌리에 안 흘렀다 — 가짜 IdP 응답이나 매핑이 바뀌었다: {dry:?}"
    );

    Fixture {
        canaries: vec![
            ("SECRET", SECRET.to_string()),
            ("BASIC", basic),
            ("ACCESS", ACCESS.to_string()),
            ("REFRESH", REFRESH.to_string()),
            ("ID", id_jwt),
            ("JWT", raw_jwt),
            ("GARBAGE", GARBAGE.to_string()),
            ("PASSWORD", PASSWORD.to_string()),
            ("VERIFIER", ar.code_verifier.clone()),
            ("VERIFIER2", ar2.code_verifier.clone()),
        ],
        cfg,
        client,
        injected,
        provider,
        low_auth,
        validator,
        jwks,
        endpoints,
        tokens: vec![
            ("client_credentials_token", cc),
            ("refresh", refreshed),
            ("exchange_code", exchanged),
        ],
        requests: vec![
            ("create_authorization_request", ar),
            ("create_authorization_request_with_redirect", ar2),
        ],
        introspection,
        validated: vec![
            ("AuthClient::validate", vt),
            ("JwtValidator::validate", vt_low),
        ],
        errors,
    }
}

// ── 걷기 ─────────────────────────────────────────────────────────────────────────────────

/// 걷기가 아는 SDK 값. ⚠️ 새 SDK 타입이 생기면 아래 대조가 여기 변형을 더하라고 요구한다.
#[derive(Clone, Copy)]
enum Node<'a> {
    Config(&'a KeycloakConfig),
    Tokens(&'a TokenSet),
    Validated(&'a ValidatedToken),
    Introspection(&'a IntrospectionResult),
    AuthRequest(&'a AuthorizationRequest),
    Error(&'a KeycloakError),
    AdminError(&'a AdminError),
    Client(&'a KeycloakClient),
    Auth(&'a AuthClient),
    Admin(&'a AdminClient),
    Provider(&'a ClientCredentialsTokenProvider),
    Validator(&'a JwtValidator),
    Jwks(&'a JwksStore),
    Endpoints(&'a OidcEndpoints),
}

fn roots(fx: &Fixture) -> Vec<(String, Node<'_>)> {
    let mut out: Vec<(String, Node<'_>)> = vec![
        ("KeycloakConfig::new".into(), Node::Config(&fx.cfg)),
        ("KeycloakClient::new".into(), Node::Client(&fx.client)),
        (
            "AdminClient::new (injected)".into(),
            Node::Admin(&fx.injected),
        ),
        (
            "ClientCredentialsTokenProvider::new".into(),
            Node::Provider(&fx.provider),
        ),
        (
            "AuthClient::new (low-level)".into(),
            Node::Auth(&fx.low_auth),
        ),
        ("JwtValidator::new".into(), Node::Validator(&fx.validator)),
        ("JwksStore::new".into(), Node::Jwks(&fx.jwks)),
        ("OidcEndpoints::new".into(), Node::Endpoints(&fx.endpoints)),
        ("introspect".into(), Node::Introspection(&fx.introspection)),
    ];
    out.extend(
        fx.tokens
            .iter()
            .map(|(n, v)| (n.to_string(), Node::Tokens(v))),
    );
    out.extend(
        fx.requests
            .iter()
            .map(|(n, v)| (n.to_string(), Node::AuthRequest(v))),
    );
    out.extend(
        fx.validated
            .iter()
            .map(|(n, v)| (n.to_string(), Node::Validated(v))),
    );
    out.extend(
        fx.errors
            .iter()
            .map(|(n, v)| (n.to_string(), Node::Error(v))),
    );
    out
}

/// 공개 접근자로 닿는 SDK 하위 값. 비공개 필드는 소비자가 못 꺼내고, 찍힌다면 그 소유 타입의 `Debug`
/// 로만 찍히므로 소유 타입을 찍는 것이 곧 그 필드를 찍는 것이다.
fn children(node: Node<'_>) -> Vec<(&'static str, Node<'_>)> {
    match node {
        Node::Error(KeycloakError::Admin(inner)) => vec![(".Admin.0", Node::AdminError(inner))],
        Node::Client(c) => vec![
            (".auth()", Node::Auth(c.auth())),
            (".admin()", Node::Admin(c.admin())),
        ],
        _ => Vec::new(),
    }
}

#[derive(Default)]
struct Walker {
    canaries: Vec<(&'static str, String)>,
    /// 카나리아마다 **그 카나리아에만 있는** 8자 조각(부분 노출 판정용).
    partial: Vec<BTreeSet<String>>,
    /// 짧은 타입 이름 → 컴파일러가 허락한 바닥 (Debug, Display).
    rendered: BTreeMap<String, (bool, bool)>,
    /// 걷기가 닿았지만 컴파일러가 바닥이 없다고 한 타입.
    floorless: BTreeSet<String>,
    leaks: Vec<String>,
    known_seen: BTreeSet<String>,
    shape_errors: Vec<String>,
    /// 짧은 타입 이름 → `{:?}` 출력의 첫 식별자(열거형이면 변형 이름). 변형 대조에 쓴다.
    variants: BTreeMap<String, BTreeSet<String>>,
}

/// ⚠️ 짧은 이름으로 대조한다 — 그래서 `scan` 이 같은 짧은 이름의 두 선언을 판독 불가로 떨어뜨린다.
fn short_name(type_name: &str) -> String {
    let base = type_name.split('<').next().unwrap_or(type_name);
    base.rsplit("::").next().unwrap_or(base).to_string()
}

/// 부분 노출 창. 원문이 아니라 **어느 8자 조각**이든 찍히면 누출이다(앞·뒤·가운데 부분 마스킹).
/// ⚠️ 8자 미만(예: 앞 4자만 보이기)은 우연 일치와 구분할 수 없어 여기서 보지 않는다.
const WINDOW: usize = 8;

/// 카나리아마다 그 카나리아에만 있는 8자 조각. ⚠️ 둘 이상이 공유하는 조각(`-CANARY-DUMP`·JWT 머리
/// `eyJ0eXAi…`)은 빼야 한다 — 안 빼면 ACCESS 하나가 새도 SECRET·REFRESH… 가 「부분」으로 함께 잡혀
/// 어느 비밀이 샜는지 가를 수 없다(실측: 변이 (a) 가 다섯 카나리아를 보고했다). 원문 판정과는 무관하다.
fn unique_windows(canaries: &[(&'static str, String)]) -> Vec<BTreeSet<String>> {
    let windows = |v: &str| -> BTreeSet<String> {
        v.as_bytes()
            .windows(WINDOW)
            .filter_map(|w| std::str::from_utf8(w).ok())
            .map(str::to_string)
            .collect()
    };
    let all: Vec<BTreeSet<String>> = canaries.iter().map(|(_, v)| windows(v)).collect();
    all.iter()
        .map(|mine| {
            mine.iter()
                .filter(|w| all.iter().filter(|o| o.contains(*w)).count() == 1)
                .cloned()
                .collect()
        })
        .collect()
}

/// `{:?}` 출력의 첫 식별자 — derive(Debug) 열거형이면 변형 이름이다.
fn leading_ident(out: &str) -> String {
    out.chars().take_while(|c| is_ident_char(*c)).collect()
}

impl Walker {
    fn new(canaries: Vec<(&'static str, String)>) -> Self {
        Self {
            partial: unique_windows(&canaries),
            canaries,
            ..Self::default()
        }
    }

    fn visit(&mut self, root: &str, path: &str, node: Node<'_>, depth: usize) {
        assert!(depth < 8, "{path}: 걷기가 8단을 넘었다 — 순환이다");
        let (ty, dbg, disp) = match node {
            Node::Config(v) => floors!(v),
            Node::Tokens(v) => floors!(v),
            Node::Validated(v) => floors!(v),
            Node::Introspection(v) => floors!(v),
            Node::AuthRequest(v) => floors!(v),
            Node::Error(v) => floors!(v),
            Node::AdminError(v) => floors!(v),
            Node::Client(v) => floors!(v),
            Node::Auth(v) => floors!(v),
            Node::Admin(v) => floors!(v),
            Node::Provider(v) => floors!(v),
            Node::Validator(v) => floors!(v),
            Node::Jwks(v) => floors!(v),
            Node::Endpoints(v) => floors!(v),
        };
        self.record(root, path, ty, dbg, disp);
        if let Node::Error(e) = node {
            // 오류의 source() 사슬 — 타입을 모르는 `dyn Error` 로도 찍어 본다.
            let mut src = std::error::Error::source(e);
            let mut n = 0;
            while let Some(s) = src {
                n += 1;
                let p = format!("{path}.source()#{n}");
                let outs = [
                    ("{}", format!("{s}")),
                    ("{:#}", format!("{s:#}")),
                    ("{:?}", format!("{s:?}")),
                    ("{:#?}", format!("{s:#?}")),
                ];
                for (how, out) in outs {
                    self.check(root, &p, "dyn Error", how, &out);
                }
                src = s.source();
            }
        }
        for (step, child) in children(node) {
            self.visit(root, &format!("{path}{step}"), child, depth + 1);
        }
    }

    fn record(
        &mut self,
        root: &str,
        path: &str,
        type_name: &str,
        dbg: Option<[String; 2]>,
        disp: Option<[String; 2]>,
    ) {
        let ty = short_name(type_name);
        let floors = (dbg.is_some(), disp.is_some());
        if floors == (false, false) {
            self.floorless.insert(ty);
            return;
        }
        if let Some(prev) = self.rendered.insert(ty.clone(), floors)
            && prev != floors
        {
            self.shape_errors.push(format!(
                "{ty}: 같은 타입의 바닥이 뿌리마다 다르다 {prev:?} → {floors:?}"
            ));
        }
        if let Some([plain, _]) = &dbg {
            self.variants
                .entry(ty.clone())
                .or_default()
                .insert(leading_ident(plain));
        }
        let outs = dbg
            .into_iter()
            .flat_map(|[a, b]| [("{:?}", a), ("{:#?}", b)])
            .chain(disp.into_iter().flat_map(|[a, b]| [("{}", a), ("{:#}", b)]));
        for (how, out) in outs {
            self.check(root, path, &ty, how, &out);
        }
    }

    fn check(&mut self, root: &str, path: &str, ty: &str, how: &str, out: &str) {
        let hits: Vec<(&'static str, &'static str)> = self
            .canaries
            .iter()
            .zip(&self.partial)
            .filter_map(|((name, value), windows)| {
                if out.contains(value.as_str()) {
                    Some((*name, "원문"))
                } else if windows.iter().any(|w| out.contains(w.as_str())) {
                    Some((*name, "부분"))
                } else {
                    None
                }
            })
            .collect();
        for (name, kind) in hits {
            let key = format!("{root}|{name}");
            if KNOWN_LEAKS.iter().any(|(k, _)| *k == key) {
                self.known_seen.insert(key);
                continue;
            }
            self.leaks.push(format!(
                "{path} [{ty}] {how}: 비밀 {name} 이(가) {kind}으로 찍혔다"
            ));
        }
    }
}

// ── 소스 파생 ───────────────────────────────────────────────────────────────────────────
// 문자열·문자·주석을 걷어 낸 토큰 위에서 선언·impl·`pub use` 를 읽는다. `syn` 을 들이지 않는 대신
// 아래 `scanner_*` 테스트가 이 판독기가 기대는 모양을 고정한다.

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Id(String),
    P(char),
    Lit,
    Life,
}

fn is_ident_start(c: char) -> bool {
    c == '_' || c.is_alphabetic()
}
fn is_ident_char(c: char) -> bool {
    c == '_' || c.is_alphanumeric()
}
fn at(c: &[char], k: usize) -> char {
    c.get(k).copied().unwrap_or('\0')
}
fn find(c: &[char], from: usize, ch: char) -> usize {
    (from..c.len()).find(|&k| c[k] == ch).unwrap_or(c.len())
}
fn skip_ident(c: &[char], mut k: usize) -> usize {
    while k < c.len() && is_ident_char(c[k]) {
        k += 1;
    }
    k
}

fn lex(src: &str) -> Vec<Tok> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < c.len() {
        let (next, tok) = lex_one(&c, i);
        out.extend(tok);
        i = next;
    }
    out
}

/// 토큰 하나(또는 공백·주석)를 읽고 다음 위치를 돌려준다.
fn lex_one(c: &[char], i: usize) -> (usize, Option<Tok>) {
    let ch = c[i];
    match ch {
        _ if ch.is_whitespace() => (i + 1, None),
        '/' if at(c, i + 1) == '/' => (find(c, i, '\n'), None),
        '/' if at(c, i + 1) == '*' => (skip_block_comment(c, i), None),
        '"' => (skip_str(c, i), Some(Tok::Lit)),
        '\'' => lex_quote(c, i),
        _ if is_ident_start(ch) => lex_word(c, i),
        _ if ch.is_ascii_digit() => (skip_number(c, i), Some(Tok::Lit)),
        _ => (i + 1, Some(Tok::P(ch))),
    }
}

/// 중첩되는 `/* … */`.
fn skip_block_comment(c: &[char], mut i: usize) -> usize {
    let mut depth = 0;
    while i < c.len() {
        if c[i] == '/' && at(c, i + 1) == '*' {
            depth += 1;
            i += 2;
        } else if c[i] == '*' && at(c, i + 1) == '/' {
            depth -= 1;
            i += 2;
            if depth == 0 {
                return i;
            }
        } else {
            i += 1;
        }
    }
    i
}

fn skip_str(c: &[char], mut k: usize) -> usize {
    k += 1; // 여는 따옴표
    while k < c.len() {
        match c[k] {
            '\\' => k += 2,
            '"' => return k + 1,
            _ => k += 1,
        }
    }
    k
}

/// 원시 문자열 몸통 — 같은 수의 `#` 가 붙은 닫는 따옴표까지.
fn skip_raw_str(c: &[char], mut k: usize, hashes: usize) -> usize {
    while k < c.len() && !(c[k] == '"' && (1..=hashes).all(|h| at(c, k + h) == '#')) {
        k += 1;
    }
    k + hashes + 1
}

fn skip_number(c: &[char], i: usize) -> usize {
    let alnum = |mut k: usize| {
        while k < c.len() && (c[k].is_ascii_alphanumeric() || c[k] == '_') {
            k += 1;
        }
        k
    };
    let k = alnum(i);
    if at(c, k) == '.' && at(c, k + 1).is_ascii_digit() {
        alnum(k + 1)
    } else {
        k
    }
}

/// `'x'`·`'\n'`·`'\u{..}'` 문자 리터럴, 아니면 `'a` 수명.
fn lex_quote(c: &[char], i: usize) -> (usize, Option<Tok>) {
    if at(c, i + 1) == '\\' {
        // 이스케이프된 한 글자(닫는 따옴표일 수도 있다)를 건너뛴 뒤 닫는 따옴표까지.
        (find(c, i + 3, '\'') + 1, Some(Tok::Lit))
    } else if at(c, i + 2) == '\'' {
        (i + 3, Some(Tok::Lit))
    } else {
        (skip_ident(c, i + 1), Some(Tok::Life))
    }
}

/// 식별자. 원시 문자열(`r#"…"#`)·바이트/C 문자열(`b"…"`)·바이트 문자(`b'x'`)·원시 식별자(`r#type`)
/// 접두사를 여기서 가른다.
fn lex_word(c: &[char], i: usize) -> (usize, Option<Tok>) {
    let end = skip_ident(c, i);
    let word: String = c[i..end].iter().collect();
    let hashes = c[end..].iter().take_while(|&&x| x == '#').count();
    match word.as_str() {
        "r" | "br" | "cr" if at(c, end + hashes) == '"' => {
            (skip_raw_str(c, end + hashes + 1, hashes), Some(Tok::Lit))
        }
        "b" | "c" if at(c, end) == '"' => (skip_str(c, end), Some(Tok::Lit)),
        "b" if at(c, end) == '\'' => (lex_quote(c, end).0, Some(Tok::Lit)),
        "r" if hashes == 1 && is_ident_start(at(c, end + 1)) => {
            let e = skip_ident(c, end + 1);
            (e, Some(Tok::Id(c[end + 1..e].iter().collect())))
        }
        _ => (end, Some(Tok::Id(word))),
    }
}

fn id(t: Option<&Tok>) -> Option<&str> {
    match t {
        Some(Tok::Id(s)) => Some(s.as_str()),
        _ => None,
    }
}

/// `toks[open]` 의 여는 괄호와 짝인 닫는 괄호의 위치.
fn matching(toks: &[Tok], open: usize) -> usize {
    let (o, c) = match toks[open] {
        Tok::P('(') => ('(', ')'),
        Tok::P('[') => ('[', ']'),
        _ => ('{', '}'),
    };
    let mut depth = 0;
    for (k, t) in toks.iter().enumerate().skip(open) {
        if *t == Tok::P(o) {
            depth += 1;
        } else if *t == Tok::P(c) {
            depth -= 1;
            if depth == 0 {
                return k;
            }
        }
    }
    toks.len() - 1
}

/// 항목 하나를 통째로 건너뛴다 — `;` 로 끝나거나 `{ … }` 몸통의 끝까지.
fn skip_item(toks: &[Tok], mut k: usize) -> usize {
    let mut depth = 0;
    while k < toks.len() {
        match toks[k] {
            Tok::P('(' | '[') => depth += 1,
            Tok::P(')' | ']') => depth -= 1,
            Tok::P(';') if depth == 0 => return k + 1,
            Tok::P('{') if depth == 0 => return matching(toks, k) + 1,
            _ => {}
        }
        k += 1;
    }
    k
}

/// `->` 의 `>` 는 꺾쇠가 아니다.
fn closes_angle(toks: &[Tok], k: usize) -> bool {
    toks[k] == Tok::P('>') && (k == 0 || toks[k - 1] != Tok::P('-'))
}

/// `toks[k]` 가 `<` 이면 짝인 `>` 다음 위치, 아니면 `k`.
fn skip_angles(toks: &[Tok], mut k: usize) -> usize {
    if toks.get(k) != Some(&Tok::P('<')) {
        return k;
    }
    let mut angle = 0;
    while k < toks.len() {
        if toks[k] == Tok::P('<') {
            angle += 1;
        } else if closes_angle(toks, k) {
            angle -= 1;
            if angle == 0 {
                return k + 1;
            }
        }
        k += 1;
    }
    k
}

/// 꺾쇠 깊이 0 에 있는 마지막 식별자 — `std::fmt::Debug` → `Debug`, `Wrapper<T>` → `Wrapper`.
fn last_top_ident(toks: &[Tok]) -> Option<String> {
    let mut angle = 0i32;
    let mut last = None;
    for (k, t) in toks.iter().enumerate() {
        match t {
            Tok::P('<') => angle += 1,
            Tok::P('>') if closes_angle(toks, k) => angle -= 1,
            Tok::Id(s) if angle == 0 && !matches!(s.as_str(), "dyn" | "mut" | "impl") => {
                last = Some(s.clone())
            }
            _ => {}
        }
    }
    last
}

/// `impl` 뒤 머리를 읽어 `(트레이트 끝 이름, 대상 타입 끝 이름)` 을 낸다. 인자 위치의 `impl Trait`
/// 처럼 `for` 가 없거나 몸통 `{` 로 끝나지 않으면 사실이 아니다. 몸통은 건너뛰지 않는다(안의 선언도 읽는다).
fn impl_header(toks: &[Tok], k: usize) -> (usize, Option<(String, String)>) {
    let start = skip_angles(toks, k);
    let mut k = start;
    let (mut depth, mut angle, mut for_at) = (0i32, 0i32, None);
    while let Some(t) = toks.get(k) {
        match t {
            Tok::P('(' | '[') => depth += 1,
            Tok::P(')' | ']') if depth == 0 => break,
            Tok::P(')' | ']') => depth -= 1,
            Tok::P('<') => angle += 1,
            Tok::P('>') if closes_angle(toks, k) => angle -= 1,
            Tok::P('{' | ';') if depth == 0 => break,
            Tok::P(',' | '=') if depth == 0 && angle == 0 => break,
            Tok::Id(s) if s == "for" && depth == 0 && angle == 0 && for_at.is_none() => {
                for_at = Some(k)
            }
            _ => {}
        }
        k += 1;
    }
    let Some(f) = for_at.filter(|_| toks.get(k) == Some(&Tok::P('{'))) else {
        return (k, None);
    };
    let ty_end = toks[f + 1..k]
        .iter()
        .position(|t| *t == Tok::Id("where".into()))
        .map_or(k, |p| f + 1 + p);
    let fact = last_top_ident(&toks[start..f]).zip(last_top_ident(&toks[f + 1..ty_end]));
    (k, fact)
}

/// `use` 트리를 펴서 `(경로, 드러나는 이름)` 을 모은다 — `a::{b::C, D as E, *}`.
fn use_tree(
    toks: &[Tok],
    mut k: usize,
    prefix: &mut Vec<String>,
    out: &mut Vec<(Vec<String>, String)>,
) -> usize {
    let base = prefix.len();
    loop {
        match toks.get(k) {
            Some(Tok::Id(s)) if s != "as" => {
                prefix.push(s.clone());
                k += 1;
                if toks.get(k) == Some(&Tok::P(':')) && toks.get(k + 1) == Some(&Tok::P(':')) {
                    k += 2;
                    continue;
                }
                let name = if id(toks.get(k)) == Some("as") {
                    k += 2;
                    id(toks.get(k - 1)).unwrap_or("_").to_string()
                } else {
                    s.clone()
                };
                out.push((prefix.clone(), name));
                break;
            }
            Some(Tok::P('{')) => {
                k += 1;
                while toks.get(k).is_some_and(|t| *t != Tok::P('}')) {
                    k = use_tree(toks, k, prefix, out);
                    if toks.get(k) == Some(&Tok::P(',')) {
                        k += 1;
                    }
                }
                k += 1;
                break;
            }
            Some(Tok::P('*')) => {
                out.push((prefix.clone(), "*".into()));
                k += 1;
                break;
            }
            Some(Tok::P(':')) => k += 1,
            _ => break,
        }
    }
    prefix.truncate(base);
    k
}

/// `enum` 이름 뒤에서 몸통을 찾아 변형 이름을 모은다(변형 속성·페이로드는 건너뛴다).
fn enum_variants(toks: &[Tok], from: usize) -> Vec<String> {
    let open = (from..toks.len()).find(|&k| toks[k] == Tok::P('{'));
    let Some(open) = open else {
        return Vec::new();
    };
    let body = &toks[open + 1..matching(toks, open)];
    let mut out = Vec::new();
    let mut k = 0;
    while k < body.len() {
        while body.get(k) == Some(&Tok::P('#')) && body.get(k + 1) == Some(&Tok::P('[')) {
            k = matching(body, k + 1) + 1;
        }
        out.extend(id(body.get(k)).map(str::to_string));
        let mut depth = 0i32;
        while k < body.len() {
            match body[k] {
                Tok::P('(' | '[' | '{') => depth += 1,
                Tok::P(')' | ']' | '}') => depth -= 1,
                Tok::P(',') if depth == 0 => break,
                _ => {}
            }
            k += 1;
        }
        k += 1;
    }
    out
}

/// `toks[i]` 에서 속성 하나를 읽는다 → `(바깥 속성의 몸통, 다음 위치)`. 안쪽 속성(`#![…]`)은 몸통 없이 건너뛴다.
fn attribute(toks: &[Tok], i: usize) -> Option<(Option<&[Tok]>, usize)> {
    if toks[i] != Tok::P('#') {
        return None;
    }
    let inner = toks.get(i + 1) == Some(&Tok::P('!'));
    let open = i + 1 + usize::from(inner);
    if toks.get(open) != Some(&Tok::P('[')) {
        return None;
    }
    let close = matching(toks, open);
    Some(((!inner).then(|| &toks[open + 1..close]), close + 1))
}

/// `pub` 을 읽어 `(키워드 위치, 크레이트 밖에서 이름 붙일 수 있는가)`. `pub(crate)` 등은 아니다.
fn visibility(toks: &[Tok], i: usize) -> (usize, bool) {
    if id(toks.get(i)) != Some("pub") {
        return (i, false);
    }
    if toks.get(i + 1) == Some(&Tok::P('(')) {
        (matching(toks, i + 1) + 1, false)
    } else {
        (i + 1, true)
    }
}

fn is_cfg_test(attr: &[Tok]) -> bool {
    id(attr.first()) == Some("cfg")
        && attr.contains(&Tok::Id("test".into()))
        && !attr.contains(&Tok::Id("not".into()))
}

/// 속성들의 `derive(…)`(+ `cfg_attr(…, derive(…))`) 이름 끝 조각.
fn derives(attrs: &[&[Tok]]) -> Vec<String> {
    let mut out = Vec::new();
    for a in attrs {
        for (k, t) in a.iter().enumerate() {
            if *t == Tok::Id("derive".into()) && a.get(k + 1) == Some(&Tok::P('(')) {
                let close = matching(a, k + 1);
                for seg in a[k + 2..close].split(|t| *t == Tok::P(',')) {
                    out.extend(last_top_ident(seg));
                }
            }
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq, Default)]
struct Decl {
    file: String,
    public: bool,
    debug: bool,
    display: bool,
    /// 열거형이면 선언된 변형 이름(구조체는 비어 있다).
    variants: Vec<String>,
}

#[derive(Debug, Default)]
struct Scan {
    decls: BTreeMap<String, Decl>,
    /// 루트가 재노출하는 foreign **타입** 이름 → 원 경로.
    foreign_reexports: BTreeMap<String, String>,
    /// 파생이 판독할 수 없어 사람이 봐야 하는 자리(글롭 재노출·같은 짧은 이름 둘).
    unreadable: Vec<String>,
    impls: Vec<(String, String)>,
    uses: Vec<(String, Vec<String>, String)>,
    local: BTreeSet<String>,
}

/// `(파일 줄기, 소스)` 목록에서 선언·바닥·변형·재노출을 파생한다.
fn scan(files: &[(String, String)]) -> Scan {
    let mut sc = Scan {
        local: ["crate", "self", "super"].map(String::from).into(),
        ..Scan::default()
    };
    for (stem, src) in files {
        sc.local.insert(stem.clone());
        sc.file(stem, &lex(src));
    }
    sc.resolve();
    sc
}

impl Scan {
    fn file(&mut self, stem: &str, toks: &[Tok]) {
        let mut attrs: Vec<&[Tok]> = Vec::new();
        let mut i = 0;
        while i < toks.len() {
            if let Some((attr, next)) = attribute(toks, i) {
                attrs.extend(attr);
                i = next;
                continue;
            }
            i = if attrs.iter().any(|a| is_cfg_test(a)) {
                skip_item(toks, i)
            } else {
                self.item(stem, toks, i, &attrs)
            };
            attrs.clear();
        }
    }

    /// 항목 머리 하나를 읽고 다음 위치를 돌려준다. 몸통은 건너뛰지 않는다(안의 선언도 읽는다).
    fn item(&mut self, stem: &str, toks: &[Tok], i: usize, attrs: &[&[Tok]]) -> usize {
        let (j, public) = visibility(toks, i);
        match id(toks.get(j)) {
            Some(kw @ ("struct" | "enum" | "union")) => {
                if let Some(name) = id(toks.get(j + 1)) {
                    let variants = if kw == "enum" {
                        enum_variants(toks, j + 2)
                    } else {
                        Vec::new()
                    };
                    self.declare(stem, name, public, &derives(attrs), variants);
                }
                j + 2
            }
            Some("impl") => {
                let (end, fact) = impl_header(toks, j + 1);
                self.impls.extend(fact);
                end
            }
            Some("use") if public => {
                let mut found = Vec::new();
                let end = use_tree(toks, j + 1, &mut Vec::new(), &mut found);
                self.uses
                    .extend(found.into_iter().map(|(p, n)| (stem.to_string(), p, n)));
                end
            }
            Some("mod") => {
                self.local.extend(id(toks.get(j + 1)).map(str::to_string));
                i + 1
            }
            _ => i + 1,
        }
    }

    fn declare(
        &mut self,
        stem: &str,
        name: &str,
        public: bool,
        derived: &[String],
        variants: Vec<String>,
    ) {
        // ⚠️ 대조는 짧은 이름으로 한다 — 같은 이름이 둘이면 하나가 찍힌 것으로 다른 하나가 통과한다.
        if let Some(prev) = self.decls.get(name) {
            self.unreadable.push(format!(
                "{name}: {} 와 {stem}.rs 에 같은 짧은 이름이 있다 — 대조가 둘을 구분할 수 없다",
                prev.file
            ));
        }
        let d = self.decls.entry(name.to_string()).or_default();
        d.file = format!("{stem}.rs");
        d.public |= public;
        // derive(Error) 는 std::error::Error 를 낳고, 그 상위 트레이트가 Debug + Display 다.
        d.debug |= derived.iter().any(|x| x == "Debug" || x == "Error");
        d.display |= derived.iter().any(|x| x == "Error");
        d.variants.extend(variants);
    }

    fn resolve(&mut self) {
        for (tr, ty) in std::mem::take(&mut self.impls) {
            if let Some(d) = self.decls.get_mut(&ty) {
                d.debug |= tr == "Debug" || tr == "Error";
                d.display |= tr == "Display" || tr == "Error";
            }
        }
        for (stem, p, name) in std::mem::take(&mut self.uses) {
            if p.first().is_some_and(|root| self.local.contains(root)) {
                continue;
            }
            if name == "*" {
                self.unreadable.push(format!(
                    "{stem}.rs: pub use {}::* — 글롭 재노출은 파생이 열거할 수 없다",
                    p.join("::")
                ));
            } else if name.starts_with(|c: char| c.is_ascii_uppercase()) {
                // 소문자는 모듈·함수·crate 다(러스트 명명 규약) — 타입이 아니므로 바닥이 없다.
                self.foreign_reexports.insert(name, p.join("::"));
            }
        }
    }
}

fn read_sources(dir: &Path, out: &mut Vec<(String, String)>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
        .map(|e| e.expect("dir entry").path())
        .collect();
    entries.sort();
    for p in entries {
        if p.is_dir() {
            read_sources(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            let stem = p.file_stem().expect("stem").to_string_lossy().into_owned();
            let src =
                std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
            out.push((stem, src));
        }
    }
}

// ── 대조 ─────────────────────────────────────────────────────────────────────────────────

/// 바닥 있는 선언 = 걷기가 찍은 타입 ∪ EXEMPT. 판독기 자기검사(소스 바닥 = 컴파일러 바닥)도 여기서 한다.
fn reconcile_floored(w: &Walker, sc: &Scan) -> Vec<String> {
    let exempt: BTreeMap<&str, &str> = EXEMPT.iter().copied().collect();
    let mut out = Vec::new();
    for (name, d) in sc.decls.iter().filter(|(_, d)| d.debug || d.display) {
        match (w.rendered.get(name), exempt.get(name.as_str())) {
            (Some(_), Some(reason)) => out.push(format!(
                "{name}: 걷기에 닿는데 면제 표에도 있다 — 면제를 지워라({reason})"
            )),
            (None, None) => out.push(format!(
                "{name} ({}): 바닥(Debug {}, Display {})이 있는데 공개 API 뿌리에서 찍히지 않았다 — 그 타입을 내는 경로를 뿌리와 Node 에 더하거나, 이유와 함께 EXEMPT 에 적어라",
                d.file, d.debug, d.display
            )),
            (Some(&(cd, cs)), None) if (cd, cs) != (d.debug, d.display) => out.push(format!(
                "{name}: 소스 파생 바닥 (Debug {}, Display {}) ≠ 컴파일러 (Debug {cd}, Display {cs}) — 판독기가 틀렸다",
                d.debug, d.display
            )),
            _ => {}
        }
    }
    for (name, _) in EXEMPT {
        if !sc.decls.contains_key(*name) {
            out.push(format!(
                "{name}: EXEMPT 에 있지만 선언이 없다 — 낡은 면제다"
            ));
        }
    }
    out
}

/// 열거형은 **변형마다** 바닥 출력이 다르다(메시지·페이로드). 타입이 한 번 찍혔다고 새 변형 —
/// 예: 응답 본문을 품은 `KeycloakError::Http { body }` — 이 찍힌 것이 아니므로 변형 단위로 대조한다.
fn reconcile_variants(w: &Walker, sc: &Scan) -> Vec<String> {
    let exempt: BTreeMap<&str, &str> = EXEMPT_VARIANTS.iter().copied().collect();
    let mut out = Vec::new();
    let mut declared = BTreeSet::new();
    let enums = sc
        .decls
        .iter()
        .filter(|(_, d)| (d.debug || d.display) && !d.variants.is_empty());
    for (name, d) in enums {
        let seen = w.variants.get(name);
        for v in &d.variants {
            let key = format!("{name}::{v}");
            let reached = seen.is_some_and(|s| s.contains(v));
            match (reached, exempt.get(key.as_str())) {
                (true, Some(reason)) => out.push(format!(
                    "{key}: 걷기에 닿는데 EXEMPT_VARIANTS 에도 있다 — 면제를 지워라({reason})"
                )),
                (false, None) => out.push(format!(
                    "{key} ({}): 이 변형을 내는 공개 API 뿌리가 없다 — 실패 호출을 뿌리에 더하거나 이유와 함께 EXEMPT_VARIANTS 에 적어라",
                    d.file
                )),
                _ => {}
            }
            declared.insert(key);
        }
        // 판독기 자기검사 — `{:?}` 의 첫 식별자는 선언된 변형이어야 한다.
        for v in seen.into_iter().flatten() {
            if !d.variants.contains(v) {
                out.push(format!(
                    "{name}: {{:?}} 의 첫 식별자 {v} 가 선언된 변형이 아니다 — 판독기가 틀렸거나 Debug 가 손 impl 이다"
                ));
            }
        }
    }
    for (key, _) in EXEMPT_VARIANTS {
        if !declared.contains(*key) {
            out.push(format!(
                "{key}: EXEMPT_VARIANTS 에 있지만 선언이 없다 — 낡은 면제다"
            ));
        }
    }
    out
}

/// 바닥 없는 공개 선언 = 프로브 표. 비공개·무바닥 선언(`Gate` 등)은 소비자가 이름 붙일 수도 찍을
/// 수도 없으므로 파생 규칙으로 빠진다.
fn reconcile_floorless(w: &Walker, sc: &Scan) -> Vec<String> {
    let mut out = Vec::new();
    // 프로브 대조군 — 프로브가 늘 「없음」을 내면 아래 「바닥 없음」 단언은 공허하다.
    let control = [probe!(TokenSet), probe!(KeycloakError)];
    if control.map(|(_, d, s)| (d, s)) != [(true, false), (true, true)] {
        out.push(format!(
            "autoref 프로브가 바닥 있는 타입을 못 알아본다 {control:?} — 「바닥 없음」 단언이 공허하다"
        ));
    }
    let floorless_public: BTreeSet<&str> = sc
        .decls
        .iter()
        .filter(|(_, d)| d.public && !d.debug && !d.display)
        .map(|(n, _)| n.as_str())
        .collect();
    let probes = floorless_probes();
    let probed: BTreeSet<String> = probes.iter().map(|(t, _, _)| short_name(t)).collect();
    for (t, has_debug, has_display) in probes.iter().chain(foreign_probes().iter()) {
        if *has_debug || *has_display {
            out.push(format!(
                "{t}: 바닥이 생겼다(Debug {has_debug}, Display {has_display}) — 비밀을 쥔 파사드는 기본 표현이 없어야 한다. 넣으려면 마스킹하는 손 impl 로 쓰고 걷기에 뿌리를 더하라"
            ));
        }
    }
    for name in &floorless_public {
        if !probed.contains(*name) {
            out.push(format!(
                "{name}: 바닥 없는 공개 선언인데 프로브 표에 없다 — floorless_probes() 에 한 줄 더하라"
            ));
        }
    }
    for name in &probed {
        if !floorless_public.contains(name.as_str()) {
            out.push(format!(
                "{name}: 프로브 표에 있지만 바닥 없는 공개 선언이 아니다 — 없어졌거나 바닥이 생겼다(낡은 항목)"
            ));
        }
    }
    for facade in [
        "AuthClient",
        "KeycloakClient",
        "AdminClient",
        "ClientCredentialsTokenProvider",
    ] {
        // 닿음 = 무바닥으로 닿았거나(정상) 바닥을 얻어 찍혔거나(위 프로브 단언이 따로 잡는다).
        if !w.floorless.contains(facade) && !w.rendered.contains_key(facade) {
            out.push(format!(
                "{facade}: 걷기가 이 파사드에 닿지 않았다 — 뿌리가 빠졌다"
            ));
        }
    }
    out
}

/// §4(b) foreign 재노출 — 면제 표와 정확히 같아야 하고, 걷기가 찍어서는 안 된다.
fn reconcile_foreign(w: &Walker, sc: &Scan) -> Vec<String> {
    let exempt: BTreeMap<&str, &str> = FOREIGN_EXEMPT.iter().copied().collect();
    let mut out = Vec::new();
    for (name, from) in &sc.foreign_reexports {
        if !exempt.contains_key(name.as_str()) {
            out.push(format!(
                "{name} (= {from}): 루트가 재노출하는 foreign 타입인데 FOREIGN_EXEMPT 에 없다 — 비밀을 쥘 수 있는지 보고 이유를 적어라"
            ));
        }
        if w.rendered.contains_key(name) {
            out.push(format!("{name}: foreign 면제 타입인데 걷기가 찍었다"));
        }
    }
    for (name, _) in FOREIGN_EXEMPT {
        if !sc.foreign_reexports.contains_key(*name) {
            out.push(format!(
                "{name}: FOREIGN_EXEMPT 에 있지만 재노출이 없다 — 낡은 면제다"
            ));
        }
    }
    out
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn reachable_objects_do_not_render_secrets() {
    let fx = fixture().await;
    let mut w = Walker::new(fx.canaries.clone());
    // 부분 노출 판정이 공허하지 않은가 — 고유 조각이 없는 카나리아는 원문으로만 잡힌다.
    let blind: Vec<_> = (w.canaries.iter().zip(&w.partial))
        .filter(|(_, windows)| windows.is_empty())
        .map(|((name, _), _)| *name)
        .collect();
    assert!(
        blind.is_empty(),
        "그 카나리아에만 있는 8자 조각이 없다 — 부분 노출을 못 본다: {blind:?}"
    );
    for (name, node) in roots(&fx) {
        w.visit(&name, &name, node, 0);
    }

    // (1) 누출
    assert!(
        w.leaks.is_empty(),
        "기본 표현이 비밀을 찍는다:\n{}",
        w.leaks.join("\n")
    );
    let stale: Vec<_> = KNOWN_LEAKS
        .iter()
        .filter(|(k, _)| !w.known_seen.contains(*k))
        .map(|(k, _)| *k)
        .collect();
    assert!(
        stale.is_empty(),
        "알려진 누출이 더 안 난다 — 고쳐졌으면 KNOWN_LEAKS 와 등록부 항목을 함께 닫아라: {stale:?}"
    );
    assert!(w.shape_errors.is_empty(), "{}", w.shape_errors.join("\n"));

    // (2) 대조 — 선언은 트리에서 파생한다.
    let mut files = Vec::new();
    read_sources(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    let sc = scan(&files);
    let floored = sc.decls.values().filter(|d| d.debug || d.display).count();
    assert!(
        sc.decls.len() >= 10 && floored >= 5,
        "src 파생이 선언을 거의 못 찾았다(선언 {} · 바닥 {floored}) — 파생이 공허하다",
        sc.decls.len()
    );
    let mut problems = sc.unreadable.clone();
    problems.extend(reconcile_floored(&w, &sc));
    problems.extend(reconcile_variants(&w, &sc));
    problems.extend(reconcile_floorless(&w, &sc));
    problems.extend(reconcile_foreign(&w, &sc));
    assert!(problems.is_empty(), "{}", problems.join("\n"));
    eprintln!(
        "선언 {} · 바닥 {floored} → 찍음 {:?} · 변형 {:?} · 걷기가 닿은 무바닥 {:?} · foreign 재노출 {} · 카나리아 {}",
        sc.decls.len(),
        w.rendered.keys().collect::<Vec<_>>(),
        sc.decls
            .iter()
            .filter(|(_, d)| !d.variants.is_empty())
            .map(|(n, d)| format!("{n}{:?}", d.variants))
            .collect::<Vec<_>>(),
        w.floorless,
        sc.foreign_reexports.len(),
        fx.canaries.len(),
    );
}

/// 판독기가 기대는 모양 — 문자열 속 가짜 선언·중괄호, cfg(test) 모듈, 인자 위치 `impl Trait`,
/// thiserror derive, `pub(crate)`, 열거형 변형, foreign/로컬 재노출 구분, 같은 짧은 이름.
#[test]
fn scanner_reads_the_shapes_the_reconcile_relies_on() {
    let src = r##"
        //! #[derive(Debug)] pub struct InDocComment;
        #[derive(Clone, Debug)]
        pub struct A { x: u8 }
        pub struct B;
        impl std::fmt::Display for B {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { write!(f, "{{") }
        }
        #[derive(Debug, thiserror::Error)]
        #[non_exhaustive]
        pub(crate) enum C { #[error("c {0}")] X(String) }
        struct D<'a> { s: &'a str }
        impl<'a> From<&'a str> for D<'a> { fn from(s: &'a str) -> Self { D { s } } }
        fn f(x: impl Into<String>) -> char {
            let _ = "struct Fake {";
            let _ = r#"impl Debug for D { "#;
            let _ = b'{';
            let _ = '\'';
            '{'
        }
        #[cfg(test)]
        mod tests { #[derive(Debug)] pub struct E; impl std::fmt::Debug for D<'_> {} }
        pub mod types { pub use keycloak::types::{UserRepresentation as U, RealmRepresentation}; }
        pub use admin::AdminClient;
        pub use reqwest;
        pub struct G<T: Clone>(T);
        impl<T: Clone + fmt::Debug> fmt::Debug for G<T> where T: Send { }
        #[derive(Debug)]
        pub enum V {
            #[doc = "x"]
            Plain,
            Tuple(Vec<u8>, String),
            Struct { a: std::collections::HashMap<u8, u8> },
        }
    "##;
    let sc = scan(&[("lib".into(), src.into()), ("admin".into(), String::new())]);
    let got: BTreeMap<&str, (bool, bool, bool)> = sc
        .decls
        .iter()
        .map(|(n, d)| (n.as_str(), (d.public, d.debug, d.display)))
        .collect();
    let want: BTreeMap<&str, (bool, bool, bool)> = [
        ("A", (true, true, false)),
        ("B", (true, false, true)),
        ("C", (false, true, true)),
        ("D", (false, false, false)),
        ("G", (true, true, false)),
        ("V", (true, true, false)),
    ]
    .into_iter()
    .collect();
    assert_eq!(got, want);
    assert_eq!(sc.decls["C"].variants, ["X"]);
    assert_eq!(sc.decls["V"].variants, ["Plain", "Tuple", "Struct"]);
    let foreign: Vec<&str> = sc.foreign_reexports.keys().map(String::as_str).collect();
    assert_eq!(foreign, ["RealmRepresentation", "U"]);
    assert!(sc.unreadable.is_empty(), "{:?}", sc.unreadable);

    // 같은 짧은 이름 둘은 판독 불가로 떨어진다 — 하나가 찍힌 것으로 다른 하나가 통과하지 않게.
    let dup = scan(&[
        ("a".into(), "pub struct Same;".into()),
        ("b".into(), "#[derive(Debug)] pub struct Same;".into()),
    ]);
    assert_eq!(dup.unreadable.len(), 1, "{:?}", dup.unreadable);
}
