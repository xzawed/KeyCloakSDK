//! 실제 Keycloak 26.6 E2E (testcontainers). 실행:
//!   cargo test --test integration_test -- --ignored --nocapture   (Docker 필요)
//!
//! `full_flow` — 5 admin 리소스 전부 커버 — client-credentials → validate(실 JWKS·RS256 강화) →
//! introspect → user/client/role/group CRUD(+ delete 후 조회 → NotFound) → raw() 스모크 → realm
//! CRUD(master-admin).
//! `code_exchange` — 브라우저 없는 로그인으로 받은 **실서버의** 인가 코드를 교환한다(nonce·서명·재사용).
//! SDK 소스는 수정하지 않는다(공개 API만 소비). 실 KC로 버그 발견 시 보고.

mod browser_login;

use async_trait::async_trait;
use browser_login::browser_login;
use keycloak::prelude::reqwest;
use keycloak::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak_sdk::error::Result as SdkResult;
use keycloak_sdk::{
    AdminClient, AdminError, AuthorizationRequest, KeycloakClient, KeycloakConfig, KeycloakError,
    TokenProvider, TokenSet,
};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

/// 테스트 전용 master-admin 토큰 소스 — master realm의 `admin-cli`에 password grant(admin/admin).
/// `POST /admin/realms`(신규 realm 생성)는 master-realm 전용이므로 realm 서비스계정으로는 403이다.
/// (C# 자매 `MasterPasswordTokenSource`와 동형 — 매 호출 발급, 캐시 불필요.)
struct MasterTokenProvider {
    token_url: String,
    http: reqwest::Client,
}

impl MasterTokenProvider {
    fn new(base: &str) -> Self {
        Self {
            token_url: format!("{base}/realms/master/protocol/openid-connect/token"),
            http: reqwest::Client::new(),
        }
    }
}

#[async_trait]
impl TokenProvider for MasterTokenProvider {
    async fn access_token(&self) -> SdkResult<String> {
        let params = [
            ("grant_type", "password"),
            ("client_id", "admin-cli"),
            ("username", "admin"),
            ("password", "admin"),
        ];
        let resp = self
            .http
            .post(&self.token_url)
            .form(&params)
            .send()
            .await
            .map_err(|e| KeycloakError::Transport(format!("master token request: {e}")))?;
        let status = resp.status();
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| KeycloakError::Transport(format!("master token body: {e}")))?;
        if !status.is_success() {
            return Err(KeycloakError::Auth {
                message: "master password grant failed".into(),
                oauth_error: body
                    .get("error")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
            });
        }
        body.get("access_token")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| KeycloakError::Auth {
                message: "master token response missing access_token".into(),
                oauth_error: None,
            })
    }
}

/// KC 26.6 기동 — it-realm import(`--import-realm` + copy_to) 후 매핑된 호스트 포트로 base URL 조립.
async fn start_keycloak() -> (ContainerAsync<GenericImage>, String) {
    let realm = std::fs::read("tests/testdata/it-realm-realm.json")
        .expect("realm import json must exist at tests/testdata/it-realm-realm.json");
    let container = GenericImage::new("quay.io/keycloak/keycloak", "26.6")
        .with_exposed_port(8080.tcp())
        .with_wait_for(WaitFor::message_on_stdout("Listening on:"))
        .with_env_var("KC_BOOTSTRAP_ADMIN_USERNAME", "admin")
        .with_env_var("KC_BOOTSTRAP_ADMIN_PASSWORD", "admin")
        .with_env_var("KC_HEALTH_ENABLED", "true")
        .with_cmd(["start-dev", "--import-realm"])
        .with_copy_to("/opt/keycloak/data/import/it-realm-realm.json", realm)
        // ⚠️ 기본 60초는 Docker 가 붐비면 모자란다 — 다른 KC 컨테이너 넷과 함께 뜰 때
        // `WaitContainer(StartupTimeout)` 로 죽었다(실측). 그 실패는 SDK 가 아니라 계측기의 죽음이다.
        .with_startup_timeout(Duration::from_secs(180))
        .start()
        .await
        .expect("keycloak container must start");
    let port = container
        .get_host_port_ipv4(8080.tcp())
        .await
        .expect("mapped 8080 host port");
    (container, format!("http://localhost:{port}"))
}

/// 준비 상태 폴링 — stdout 마커 이후에도 imported realm 라우트가 200을 줄 때까지 대기
/// (too-early connect의 flaky 000/connection-refused 방지). 최대 60초 유한 재시도.
async fn wait_until_realm_ready(base: &str) {
    let http = reqwest::Client::new();
    let url = format!("{base}/realms/it-realm/.well-known/openid-configuration");
    for _ in 0..60 {
        if let Ok(resp) = http.get(&url).send().await
            && resp.status().is_success()
        {
            return;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    panic!("keycloak it-realm not ready after 60s: {url}");
}

#[tokio::test]
#[ignore = "Docker 필요 — 실제 Keycloak 26.6 기동"]
async fn full_flow() {
    let (_container, base) = start_keycloak().await;
    wait_until_realm_ready(&base).await;

    // 리소스 이름 고유화(런당 유일) — 나노초 접미사.
    let suffix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();

    let cfg = KeycloakConfig::new(base.as_str(), "it-realm", "it-client")
        .unwrap()
        .with_client_secret("it-secret");
    let client = KeycloakClient::new(cfg).unwrap();

    // ── 1) client-credentials ──
    let token = client.auth().client_credentials_token().await.unwrap();
    assert!(
        !token.access_token.is_empty(),
        "access token must be non-empty"
    );

    // ── 2) validate(실 JWKS·RS256 강화) ──
    let vt = client.auth().validate(&token.access_token).await.unwrap();
    assert!(
        vt.audience.contains(&"it-client".to_string()),
        "aud must contain it-client (audience mapper), got {:?}",
        vt.audience
    );
    assert!(
        vt.issuer.ends_with("/realms/it-realm"),
        "issuer must end with /realms/it-realm, got {}",
        vt.issuer
    );

    // ── 3) introspect ──
    let ir = client.auth().introspect(&token.access_token).await.unwrap();
    assert!(ir.active, "introspection must report active=true");

    // ── 4) user CRUD ──
    let uname = format!("rust-it-user-{suffix}");
    client
        .admin()
        .create_user(UserRepresentation {
            username: Some(uname.clone()),
            email: Some(format!("{uname}@example.com")),
            enabled: Some(true),
            ..Default::default()
        })
        .await
        .unwrap();
    // 정확일치 단건 조회 — 잘림이 구조적으로 불가능한 경로다(username은 realm 안에서 유일).
    let uid = client
        .admin()
        .find_user_by_username(&uname)
        .await
        .unwrap()
        .and_then(|u| u.id.clone())
        .expect("created user must be found by exact search");

    // 페이지 경계가 실제로 서버에 전달되는지는 실 Keycloak만 증명할 수 있다 —
    // 단위테스트는 우리가 **무엇을 보내는지**만 잠그고, 여기서는 **서버가 지키는지**를 본다.
    // (이전 구현은 max=20을 하드코딩해 21번째부터 조용히 잘렸고, 그 사실을 알 방법이 없었다.)
    let page = client
        .admin()
        .search_users(Some(&uname), 0, 1)
        .await
        .unwrap();
    assert_eq!(page.len(), 1, "max=1을 보냈으면 서버도 1건만 돌려줘야 한다");
    let got = client.admin().get_user(&uid).await.unwrap();
    assert_eq!(got.username.as_deref(), Some(uname.as_str()));

    // 부분(sparse) 갱신 — first_name만 보내고 신원 필드가 보존되는지 본다.
    client
        .admin()
        .update_user(
            &uid,
            UserRepresentation {
                first_name: Some("Ada".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    let after = client.admin().get_user(&uid).await.unwrap();
    assert_eq!(after.first_name.as_deref(), Some("Ada"));
    assert_eq!(
        after.username.as_deref(),
        Some(uname.as_str()),
        "sparse update must not clobber username"
    );

    client.admin().delete_user(&uid).await.unwrap();

    // ── 5) delete 후 조회 → NotFound ──
    let err = client.admin().get_user(&uid).await.unwrap_err();
    assert!(
        matches!(err, KeycloakError::Admin(AdminError::NotFound)),
        "deleted user get must map to Admin(NotFound), got {err:?}"
    );

    // ── 6) client CRUD (create → get by uuid → delete) ──
    let client_id = format!("rust-it-cli-{suffix}");
    let client_uuid = client
        .admin()
        .create_client(ClientRepresentation {
            client_id: Some(client_id.clone()),
            ..Default::default()
        })
        .await
        .unwrap()
        .expect("create_client must return internal uuid via Location header");
    let gc = client.admin().get_client(&client_uuid).await.unwrap();
    assert_eq!(gc.client_id.as_deref(), Some(client_id.as_str()));
    // ⚠️ update 넷은 전부 경로(주소)와 body(새 값)를 분리해 넘긴다 — 합치면 rename이 조용한 no-op이 된다.
    client
        .admin()
        .update_client(
            &client_uuid,
            ClientRepresentation {
                client_id: Some(client_id.clone()),
                description: Some("updated by e2e".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(
        client
            .admin()
            .get_client(&client_uuid)
            .await
            .unwrap()
            .description
            .as_deref(),
        Some("updated by e2e")
    );
    assert!(
        client
            .admin()
            .list_clients(0, 200)
            .await
            .unwrap()
            .iter()
            .any(|c| c.id.as_deref() == Some(client_uuid.as_str())),
        "list_clients must include the client we just created"
    );
    client.admin().delete_client(&client_uuid).await.unwrap();

    // ── 7) role CRUD (realm role by name) ──
    let role_name = format!("rust-it-role-{suffix}");
    client
        .admin()
        .create_role(RoleRepresentation {
            name: Some(role_name.clone()),
            ..Default::default()
        })
        .await
        .unwrap();
    let gr = client.admin().get_role(&role_name).await.unwrap();
    assert_eq!(gr.name.as_deref(), Some(role_name.as_str()));
    client
        .admin()
        .update_role(
            &role_name,
            RoleRepresentation {
                name: Some(role_name.clone()),
                description: Some("updated by e2e".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(
        client
            .admin()
            .get_role(&role_name)
            .await
            .unwrap()
            .description
            .as_deref(),
        Some("updated by e2e")
    );
    assert!(
        client
            .admin()
            .list_roles(0, 200)
            .await
            .unwrap()
            .iter()
            .any(|r| r.name.as_deref() == Some(role_name.as_str())),
        "list_roles must include the role we just created"
    );
    client.admin().delete_role(&role_name).await.unwrap();

    // ── 8) group CRUD (create → get by id → delete) ──
    let group_name = format!("rust-it-grp-{suffix}");
    let gid = client
        .admin()
        .create_group(GroupRepresentation {
            name: Some(group_name.clone()),
            ..Default::default()
        })
        .await
        .unwrap()
        .expect("create_group must return id via Location header");
    let gg = client.admin().get_group(&gid).await.unwrap();
    assert_eq!(gg.name.as_deref(), Some(group_name.as_str()));
    assert!(
        client
            .admin()
            .list_groups(0, 200)
            .await
            .unwrap()
            .iter()
            .any(|g| g.id.as_deref() == Some(gid.as_str())),
        "list_groups must include the group we just created"
    );
    // rename — 경로는 id, body에 **새** 이름. 둘을 합치는 구현에서는 이 단언이 깨진다.
    let renamed = format!("{group_name}-renamed");
    client
        .admin()
        .update_group(
            &gid,
            GroupRepresentation {
                name: Some(renamed.clone()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(
        client
            .admin()
            .get_group(&gid)
            .await
            .unwrap()
            .name
            .as_deref(),
        Some(renamed.as_str()),
        "rename must take effect — a no-op here means path was built from the body"
    );
    client.admin().delete_group(&gid).await.unwrap();

    // ── 8b) realms list/update — it-client 서비스계정은 픽스처에서 view-realm·manage-realm을 갖는다.
    // (신규 realm **생성**만 master 전용이라 아래 10)에서 403을 확인한다.)
    assert!(
        client
            .admin()
            .list_realms()
            .await
            .unwrap()
            .iter()
            .any(|r| r.realm.as_deref() == Some("it-realm")),
        "list_realms must include the realm this service account lives in"
    );
    client
        .admin()
        .update_realm(
            "it-realm",
            RealmRepresentation {
                realm: Some("it-realm".into()),
                display_name: Some("updated by e2e".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(
        client
            .admin()
            .get_realm()
            .await
            .unwrap()
            .display_name
            .as_deref(),
        Some("updated by e2e")
    );

    // ── 9) raw() 스모크 — 내부 KeycloakAdmin 노출(탈출구, 문서화된 은닉성 예외) ──
    let _raw = client.admin().raw();

    // ── 10) it-client 서비스계정으로 realm 생성 시도 → 403(master 전용, 문서화된 실서버 동작) ──
    let denied = client
        .admin()
        .create_realm(RealmRepresentation {
            realm: Some(format!("rust-it-denied-{suffix}")),
            enabled: Some(true),
            ..Default::default()
        })
        .await;
    assert!(
        matches!(denied, Err(KeycloakError::Admin(AdminError::Forbidden))),
        "realm create via it-client service account must be 403 Forbidden, got {denied:?}"
    );

    // ── 11) realm CRUD via master-admin (POST /admin/realms는 master 전용) ──
    let master_provider: Arc<dyn TokenProvider> = Arc::new(MasterTokenProvider::new(&base));
    let master_cfg = KeycloakConfig::new(base.as_str(), "master", "admin-cli").unwrap();
    let master_admin =
        AdminClient::new(&master_cfg, reqwest::Client::new(), master_provider.clone());

    let new_realm = format!("rust-it-realm-{suffix}");
    master_admin
        .create_realm(RealmRepresentation {
            realm: Some(new_realm.clone()),
            enabled: Some(true),
            ..Default::default()
        })
        .await
        .unwrap();

    // 존재 확인 — 새 realm 스코프 AdminClient로 get_realm(master 토큰은 전역 admin이라 어느 realm이든 조회).
    let verify_cfg = KeycloakConfig::new(base.as_str(), new_realm.as_str(), "admin-cli").unwrap();
    let verify_admin =
        AdminClient::new(&verify_cfg, reqwest::Client::new(), master_provider.clone());
    let got_realm = verify_admin.get_realm().await.unwrap();
    assert_eq!(
        got_realm.realm.as_deref(),
        Some(new_realm.as_str()),
        "created realm must be retrievable via master admin"
    );

    master_admin.delete_realm(&new_realm).await.unwrap();

    // realm delete 후 조회 → NotFound(realm CRUD 완주 증명).
    let realm_err = verify_admin.get_realm().await.unwrap_err();
    assert!(
        matches!(realm_err, KeycloakError::Admin(AdminError::NotFound)),
        "deleted realm get must map to Admin(NotFound), got {realm_err:?}"
    );
}

// ══ 인가 코드 교환 E2E ══════════════════════════════════════════════════════════════════════
//
// `exchange_code*` 의 nonce 대조와 id_token 서명 검증은 지금까지 wiremock 토큰으로만 돌았다. 여기서는
// `browser_login` 으로 실제 로그인해 받은 코드를 교환하고, **서버가 서명한** 토큰에 대고 거부 경로까지
// 돈다. 모양은 python `tests/integration/test_code_exchange_it.py` 와 같다. 서명만 틀린 RS256 은
// 실서버가 못 만든다 — `tests/forged_id_token.rs`(단위) 가 맡는다.
//
// ⚠️ 컨테이너 하나를 시나리오 전부가 쓴다. `#[tokio::test]` 마다 런타임이 따로라 테스트 사이에서
// 컨테이너를 나눌 수 없고(정적 보관은 Drop 이 안 돌아 컨테이너가 샌다), 시나리오마다 띄우면 KC 가
// 열여덟 번 뜬다. 그래서 시나리오를 `tokio::spawn` 으로 하나씩 돌려 panic 을 잡고 **이름을 모아**
// 실패시킨다 — 하나가 빨개도 나머지가 돌고, 실패 목록이 곧 「어느 시나리오가 잡았나」다.

const REDIRECT_URI: &str = "http://localhost/it-callback";
const ALICE: (&str, &str) = ("alice", "alice-password");
/// realm JSON 의 `it-web` — 표준 흐름 · PKCE S256 강제 · RS256.
/// ⚠️ audience 매퍼는 introspect 용이다 — `aud` 가 없는 접근 토큰을 Keycloak 26.6 은 발급한 그
/// 클라이언트가 물어도 `{"active": false}` 로 답한다(python 파일럿 실측).
const IT_WEB: (&str, &str) = ("it-web", "it-web-secret");
/// realm JSON 의 `it-web-hs256` — id_token 을 realm 의 HMAC 키로 서명한다(대칭키는 JWKS 에 없다).
const IT_WEB_HS256: (&str, &str) = ("it-web-hs256", "it-web-hs256-secret");
const RS256_ONLY: &[&str] = &["RS256"];
const RS256_AND_HS256: &[&str] = &["RS256", "HS256"];
const UNEXPECTED_NONCE: &str = "authorization code exchange failed: unexpected nonce";
/// ⚠️ rust 는 kid 를 **먼저** 푼다(`JwtValidator::validate` 의 (2) → (3)). HMAC 키의 kid 는 JWKS 에
/// 없으므로 핀을 RS256 으로 두든 HS256 을 더하든 여기서 거부된다 — python 은 핀이 먼저 거부한다.
const KID_OUTSIDE_JWKS: &str =
    "authorization code exchange failed: invalid id_token: token validation error: unknown kid";
const MISSING_ID_TOKEN: &str =
    "authorization code exchange failed: missing id_token for nonce validation";
const AUDIENCE_MISMATCH: &str = "authorization code exchange failed: invalid id_token: \
     token validation error: token verification failed: audience mismatch";
const ALGORITHM_NOT_PINNED: &str = "authorization code exchange failed: invalid id_token: \
     token validation error: token verification failed: algorithm not allowed";
/// 서명이 깨진 refresh token 으로 로그아웃할 때 — Keycloak 26.6 의 상태코드는 실측으로 고정한다.
const LOGOUT_REFUSED: &str = "authentication error: logout failed (HTTP 400)";

/// rust 의 인가 요청·교환은 두 짝이다 — config 의 redirect_uri 를 쓰는 짝과 호출마다 받는 짝.
#[derive(Clone, Copy, Debug)]
enum Redirect {
    /// `with_redirect_uri` + `create_authorization_request` + `exchange_code`.
    Config,
    /// config 에 redirect_uri 가 **없다** + `*_with_redirect` 둘. config 값이 없으면 상류가 issuer URL
    /// 을 기본값으로 쓰는데 그것은 등록된 콜백이 아니다 — 두 메서드가 인자를 안 실으면 로그인 페이지가
    /// 안 뜨거나(인가) `invalid_grant`(교환)로 빨개진다.
    PerCall,
}

struct Env {
    base: String,
    alice_id: String,
}

fn web_config(
    base: &str,
    (client_id, secret): (&str, &str),
    algorithms: &[&str],
    redirect: Redirect,
) -> KeycloakConfig {
    let cfg = KeycloakConfig::new(base, "it-realm", client_id)
        .unwrap()
        .with_client_secret(secret)
        .with_signature_algorithms(algorithms.iter().map(|a| a.to_string()).collect());
    match redirect {
        Redirect::Config => cfg.with_redirect_uri(REDIRECT_URI),
        Redirect::PerCall => cfg,
    }
}

fn web_client(
    base: &str,
    client: (&str, &str),
    algorithms: &[&str],
    redirect: Redirect,
) -> KeycloakClient {
    KeycloakClient::new(web_config(base, client, algorithms, redirect)).unwrap()
}

fn authorization_request(kc: &KeycloakClient, redirect: Redirect) -> AuthorizationRequest {
    match redirect {
        Redirect::Config => kc.auth().create_authorization_request(),
        Redirect::PerCall => kc
            .auth()
            .create_authorization_request_with_redirect(REDIRECT_URI)
            .unwrap(),
    }
}

async fn exchange(
    kc: &KeycloakClient,
    redirect: Redirect,
    code: &str,
    request: &AuthorizationRequest,
    nonce: Option<&str>,
) -> SdkResult<TokenSet> {
    let verifier = request.code_verifier.as_str();
    match redirect {
        Redirect::Config => kc.auth().exchange_code(code, verifier, nonce).await,
        Redirect::PerCall => {
            kc.auth()
                .exchange_code_with_redirect(code, verifier, REDIRECT_URI, nonce)
                .await
        }
    }
}

async fn login(kc: &KeycloakClient, redirect: Redirect) -> (AuthorizationRequest, String) {
    let request = authorization_request(kc, redirect);
    let code = browser_login(&request, REDIRECT_URI, ALICE.0, ALICE.1).await;
    (request, code)
}

/// 인가 URL 의 쿼리 한 자리를 고친다 — `edit` 가 `None` 을 주면 그 자리를 뺀다. 그 자리가 원래
/// 있었는지 먼저 본다(없던 것을 「뺐다」고 믿으면 아래 전제가 공허해진다).
fn rewrite_query(
    request: AuthorizationRequest,
    key: &str,
    edit: impl Fn(&str) -> Option<String>,
) -> AuthorizationRequest {
    let mut url = url::Url::parse(&request.url).unwrap();
    let pairs: Vec<(String, String)> = url
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    assert!(
        pairs.iter().any(|(k, _)| k == key),
        "the SDK must put `{key}` on the authorization URL: {}",
        request.url
    );
    url.query_pairs_mut()
        .clear()
        .extend_pairs(pairs.into_iter().filter_map(|(k, v)| {
            if k == key {
                edit(&v).map(|v| (k, v))
            } else {
                Some((k, v))
            }
        }));
    AuthorizationRequest {
        url: url.to_string(),
        ..request
    }
}

/// 인가 URL 에서 `nonce` 만 뺀다 — 서버가 nonce 클레임 **없는** id_token 을 서명하게 한다.
fn strip_nonce(request: AuthorizationRequest) -> AuthorizationRequest {
    rewrite_query(request, "nonce", |_| None)
}

/// scope 에서 `openid` 를 뺀다 — OIDC 가 아닌 OAuth2 요청이 되어 서버가 id_token 을 **안 준다**.
fn strip_openid_scope(request: AuthorizationRequest) -> AuthorizationRequest {
    rewrite_query(request, "scope", |scope| {
        let kept: Vec<&str> = scope.split(' ').filter(|s| *s != "openid").collect();
        Some(if kept.is_empty() {
            "profile".to_string()
        } else {
            kept.join(" ")
        })
    })
}

/// 로거가 찍을 모든 모양 — Display · Debug · 예쁜 Debug · `source()` 사슬 — 에 비밀이 없다.
/// SDK 스스로는 로그도 stdout 도 쓰지 않는다(`rust/src` 에 log·tracing·print 가 없다) — 소비자가
/// 오류를 찍는 이 경로가 전부다. 원문과 앞 10자(접두 노출)를 본다.
fn assert_secrets_absent(err: &KeycloakError, hidden: &[(&str, &str)]) {
    let mut printed = format!("{err}\n{err:?}\n{err:#?}");
    let mut cause = std::error::Error::source(err);
    while let Some(link) = cause {
        printed.push_str(&format!("\n{link}\n{link:?}"));
        cause = link.source();
    }
    for (name, secret) in hidden {
        assert!(secret.len() >= 10, "{name} is too short to be a canary");
        // ⚠️ 실패 문구에 비밀을 싣지 않는다 — 이름만.
        assert!(!printed.contains(secret), "{name} leaked into the error");
        assert!(
            !printed.contains(&secret[..10]),
            "a prefix of {name} leaked into the error"
        );
    }
}

/// SDK 가 거부한 교환 — 서버 OAuth 오류가 아니라(`oauth_error: None`) 정확히 이 문구의 `Auth` 다.
fn assert_refused(result: SdkResult<TokenSet>, expected: &str) {
    match result {
        Err(KeycloakError::Auth {
            message,
            oauth_error,
        }) => {
            assert_eq!(message, expected);
            assert_eq!(oauth_error, None, "the SDK refused, not the server");
        }
        other => panic!("expected Auth({expected:?}), got {other:?}"),
    }
}

/// 서버가 거부한 호출 — `invalid_grant` 코드를 실은 `Auth` 다.
fn assert_invalid_grant<T: std::fmt::Debug>(result: &SdkResult<T>, what: &str) {
    match result {
        Err(KeycloakError::Auth { oauth_error, .. }) => {
            assert_eq!(oauth_error.as_deref(), Some("invalid_grant"), "{what}")
        }
        other => panic!("{what}: expected Auth(invalid_grant), got {other:?}"),
    }
}

async fn exchange_binds_tokens_to_the_nonce_and_user(env: Arc<Env>, redirect: Redirect) {
    let kc = web_client(&env.base, IT_WEB, RS256_ONLY, redirect);
    let (request, code) = login(&kc, redirect).await;
    let tokens = exchange(&kc, redirect, &code, &request, Some(&request.nonce))
        .await
        .expect("the exchange must succeed with the nonce the SDK issued");
    assert!(!tokens.access_token.is_empty());
    let refresh_token = tokens.refresh_token.clone().expect("a refresh token");
    let id_token = tokens.id_token.clone().expect("an id_token");
    let id = kc
        .auth()
        .validate(&id_token)
        .await
        .expect("the server-signed id_token validates");
    assert_eq!(
        id.claims.get("nonce").and_then(|v| v.as_str()),
        Some(request.nonce.as_str())
    );
    // sub 는 **독립 원천**(admin API 로 읽은 alice 의 id)과 대조한다.
    assert_eq!(id.subject, env.alice_id);

    // refresh: 새 접근 토큰을 준다 — 같은 사용자의 활성 토큰이다.
    let refreshed = kc.auth().refresh(&refresh_token).await.expect("refresh");
    assert!(!refreshed.access_token.is_empty());
    assert_ne!(refreshed.access_token, tokens.access_token);
    let refreshed_rt = refreshed
        .refresh_token
        .clone()
        .expect("refresh returns a refresh token");
    let active = kc.auth().introspect(&refreshed.access_token).await.unwrap();
    assert!(active.active, "the refreshed access token must be active");
    assert_eq!(active.username.as_deref(), Some(ALICE.0));

    // logout: 세션을 끝낸다 — 그 refresh token 은 더는 갱신되지 않고 접근 토큰은 비활성이 된다.
    kc.auth().logout(&refreshed_rt).await.expect("logout");
    let hidden = [
        ("refresh_token", refresh_token.as_str()),
        ("refreshed refresh_token", refreshed_rt.as_str()),
        ("client_secret", IT_WEB.1),
    ];
    let ended = kc.auth().refresh(&refreshed_rt).await;
    assert_invalid_grant(&ended, "refresh after logout");
    assert_secrets_absent(&ended.unwrap_err(), &hidden);
    let after = kc.auth().introspect(&refreshed.access_token).await.unwrap();
    assert!(
        !after.active,
        "the access token must be inactive after logout"
    );
    // 서버가 거부한 로그아웃은 성공으로 삼켜지면 안 된다. ⚠️ 끝난 세션을 **같은** refresh token 으로
    // 또 끝내는 것은 거부가 아니다 — Keycloak 26.6 은 204 로 받는다(실측). 서명이 깨진 토큰을 쓴다.
    let tampered = tamper_signature(&refreshed_rt);
    match kc.auth().logout(&tampered).await {
        Err(err @ KeycloakError::Auth { .. }) => {
            assert_eq!(err.to_string(), LOGOUT_REFUSED);
            assert_secrets_absent(&err, &hidden);
            assert_secrets_absent(&err, &[("tampered refresh_token", tampered.as_str())]);
        }
        other => panic!("a logout the server refuses must be an error, got {other:?}"),
    }
}

/// JWT 서명 부분의 **첫** 글자를 바꾼다 — 마지막 글자는 패딩 비트만 바뀌어 같은 바이트로 풀릴 수 있다.
fn tamper_signature(jwt: &str) -> String {
    let at = jwt.rfind('.').expect("a JWT") + 1;
    let swapped = if jwt.as_bytes()[at] == b'A' { "B" } else { "A" };
    format!("{}{swapped}{}", &jwt[..at], &jwt[at + 1..])
}

async fn exchange_refuses_a_nonce_the_server_did_not_sign(env: Arc<Env>, redirect: Redirect) {
    let kc = web_client(&env.base, IT_WEB, RS256_ONLY, redirect);
    let (request, code) = login(&kc, redirect).await;
    let wrong = format!("x{}", request.nonce);
    assert_refused(
        exchange(&kc, redirect, &code, &request, Some(&wrong)).await,
        UNEXPECTED_NONCE,
    );
}

/// nonce 를 빼고 인가받은 코드 — 서버는 nonce 없는 id_token 을 낸다. 부재도 거부다.
async fn exchange_refuses_an_id_token_that_carries_no_nonce(env: Arc<Env>, redirect: Redirect) {
    let kc = web_client(&env.base, IT_WEB, RS256_ONLY, redirect);
    let request = strip_nonce(authorization_request(&kc, redirect));
    // 전제: 서버가 정말 nonce 없이 서명한다(아니면 아래는 부재가 아니라 불일치를 잰다).
    let code = browser_login(&request, REDIRECT_URI, ALICE.0, ALICE.1).await;
    let unchecked = exchange(&kc, redirect, &code, &request, None)
        .await
        .expect("without an expected nonce the exchange succeeds");
    let id_token = unchecked.id_token.expect("an id_token");
    let claims = kc.auth().validate(&id_token).await.unwrap().claims;
    assert!(
        !claims.contains_key("nonce"),
        "precondition: the server signed an id_token without a nonce claim"
    );

    let code = browser_login(&request, REDIRECT_URI, ALICE.0, ALICE.1).await;
    assert_refused(
        exchange(&kc, redirect, &code, &request, Some(&request.nonce)).await,
        UNEXPECTED_NONCE,
    );
}

async fn reused_code_is_refused_without_leaking_it(env: Arc<Env>, redirect: Redirect) {
    let kc = web_client(&env.base, IT_WEB, RS256_ONLY, redirect);
    let (request, code) = login(&kc, redirect).await;
    let tokens = exchange(&kc, redirect, &code, &request, Some(&request.nonce))
        .await
        .expect("the first exchange succeeds");
    let reused = exchange(&kc, redirect, &code, &request, Some(&request.nonce)).await;
    assert_invalid_grant(&reused, "a used code");
    assert_secrets_absent(
        &reused.unwrap_err(),
        &[
            ("code", code.as_str()),
            ("code_verifier", request.code_verifier.as_str()),
            ("client_secret", IT_WEB.1),
            ("access_token", tokens.access_token.as_str()),
            ("refresh_token", tokens.refresh_token.as_deref().unwrap()),
            ("id_token", tokens.id_token.as_deref().unwrap()),
        ],
    );
}

/// `openid` 없이 인가받은 코드 — 서버는 id_token 을 주지 않는다. nonce 를 기대했으면 부재도 거부다.
async fn exchange_refuses_a_response_that_carries_no_id_token(env: Arc<Env>, redirect: Redirect) {
    let kc = web_client(&env.base, IT_WEB, RS256_ONLY, redirect);
    let request = strip_openid_scope(authorization_request(&kc, redirect));
    // 전제: 서버가 정말 id_token 없이 답한다(아니면 아래는 부재가 아니라 다른 것을 잰다).
    let code = browser_login(&request, REDIRECT_URI, ALICE.0, ALICE.1).await;
    let unchecked = exchange(&kc, redirect, &code, &request, None)
        .await
        .expect("without an expected nonce the exchange succeeds");
    assert!(
        unchecked.id_token.is_none(),
        "precondition: no id_token without the openid scope"
    );

    let code = browser_login(&request, REDIRECT_URI, ALICE.0, ALICE.1).await;
    assert_refused(
        exchange(&kc, redirect, &code, &request, Some(&request.nonce)).await,
        MISSING_ID_TOKEN,
    );
}

/// 서명·kid 는 맞는 **실서버** id_token 이 클레임 검사에서 떨어지는 유일한 길 — 기대 aud 를 바꾼다.
/// (위조 RS256 은 서명에서, HS256 은 kid 에서 멈춘다. 이것만 서명 **뒤**의 검사에 닿는다.)
async fn id_token_for_another_audience_is_refused(env: Arc<Env>, redirect: Redirect) {
    let cfg =
        web_config(&env.base, IT_WEB, RS256_ONLY, redirect).with_expected_audience("it-client");
    let kc = KeycloakClient::new(cfg).unwrap();
    let (request, code) = login(&kc, redirect).await;
    assert_refused(
        exchange(&kc, redirect, &code, &request, Some(&request.nonce)).await,
        AUDIENCE_MISMATCH,
    );
}

/// RS256 로 서명된 실서버 id_token 을 핀 밖(`ES256` 만 허용)에 두면 거부된다 — kid 는 JWKS 에 **있다.**
/// HS256 시나리오는 kid 해석에서 먼저 멈춰 핀을 관찰하지 못한다. 이것이 핀을 관찰하는 자리다.
async fn id_token_signed_outside_the_algorithm_pin_is_refused(env: Arc<Env>, redirect: Redirect) {
    let kc = web_client(&env.base, IT_WEB, &["ES256"], redirect);
    let (request, code) = login(&kc, redirect).await;
    let unchecked = exchange(&kc, redirect, &code, &request, None)
        .await
        .expect("without an expected nonce the id_token is not validated");
    let header = jsonwebtoken::decode_header(unchecked.id_token.as_deref().expect("an id_token"))
        .expect("a JWT header");
    assert_eq!(header.alg, jsonwebtoken::Algorithm::RS256, "precondition");
    let kid = header.kid.expect("precondition: a kid");
    assert!(
        realm_jwks_kids(&env.base).await.contains(&kid),
        "precondition: the signing key IS in the JWKS, so only the pin can refuse"
    );

    let (request, code) = login(&kc, redirect).await;
    assert_refused(
        exchange(&kc, redirect, &code, &request, Some(&request.nonce)).await,
        ALGORITHM_NOT_PINNED,
    );
}

async fn realm_jwks_kids(base: &str) -> Vec<String> {
    let url = format!("{base}/realms/it-realm/protocol/openid-connect/certs");
    let jwks: serde_json::Value = reqwest::get(&url).await.unwrap().json().await.unwrap();
    jwks["keys"]
        .as_array()
        .expect("a JWKS")
        .iter()
        .filter_map(|k| k["kid"].as_str().map(str::to_string))
        .collect()
}

/// `it-web-hs256` 의 id_token 은 realm 의 HMAC 키로 서명된다 — 대칭키는 JWKS 에 없다.
async fn id_token_signed_by_a_key_outside_the_jwks_is_refused(
    env: Arc<Env>,
    redirect: Redirect,
    algorithms: &'static [&'static str],
) {
    let kc = web_client(&env.base, IT_WEB_HS256, algorithms, redirect);
    // 전제: 서버가 정말 HS256 으로 서명했고, 그 kid 는 realm JWKS 에 없다. `None` 이면 교환은
    // id_token 을 검증하지 않는다(문서화된 계약) — 그래서 머리글을 볼 수 있다.
    let (request, code) = login(&kc, redirect).await;
    let unchecked = exchange(&kc, redirect, &code, &request, None)
        .await
        .expect("without an expected nonce the id_token is not validated");
    let header = jsonwebtoken::decode_header(unchecked.id_token.as_deref().expect("an id_token"))
        .expect("a JWT header");
    assert_eq!(header.alg, jsonwebtoken::Algorithm::HS256, "precondition");
    let kid = header
        .kid
        .expect("precondition: Keycloak names the HMAC key");
    assert!(
        !realm_jwks_kids(&env.base).await.contains(&kid),
        "precondition: the HMAC key is not published in the JWKS"
    );

    let (request, code) = login(&kc, redirect).await;
    assert_refused(
        exchange(&kc, redirect, &code, &request, Some(&request.nonce)).await,
        KID_OUTSIDE_JWKS,
    );
}

/// `alice` 의 사용자 id — 토큰의 `sub` 와 대조할 **독립 원천**(admin API)에서 읽는다.
async fn alice_id(base: &str) -> String {
    let cfg = KeycloakConfig::new(base, "it-realm", "it-client")
        .unwrap()
        .with_client_secret("it-secret");
    KeycloakClient::new(cfg)
        .unwrap()
        .admin()
        .find_user_by_username(ALICE.0)
        .await
        .unwrap()
        .and_then(|u| u.id)
        .expect("alice exists in the imported realm")
}

fn panic_text(join: tokio::task::JoinError) -> String {
    match join.try_into_panic() {
        Ok(payload) => payload
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_else(|| "non-string panic payload".into()),
        Err(join) => join.to_string(),
    }
}

type Scenario = Pin<Box<dyn Future<Output = ()> + Send>>;

#[tokio::test]
#[ignore = "Docker 필요 — 실제 Keycloak 26.6 기동"]
async fn code_exchange() {
    let (_container, base) = start_keycloak().await;
    wait_until_realm_ready(&base).await;
    let env = Arc::new(Env {
        alice_id: alice_id(&base).await,
        base,
    });

    let mut scenarios: Vec<(String, Scenario)> = Vec::new();
    for redirect in [Redirect::Config, Redirect::PerCall] {
        let mut add = |name: &str, scenario: Scenario| {
            scenarios.push((format!("{name}[{redirect:?}]"), scenario));
        };
        add(
            "exchange_binds_tokens_to_the_nonce_and_user",
            Box::pin(exchange_binds_tokens_to_the_nonce_and_user(
                env.clone(),
                redirect,
            )),
        );
        add(
            "exchange_refuses_a_nonce_the_server_did_not_sign",
            Box::pin(exchange_refuses_a_nonce_the_server_did_not_sign(
                env.clone(),
                redirect,
            )),
        );
        add(
            "exchange_refuses_an_id_token_that_carries_no_nonce",
            Box::pin(exchange_refuses_an_id_token_that_carries_no_nonce(
                env.clone(),
                redirect,
            )),
        );
        add(
            "reused_code_is_refused_without_leaking_it",
            Box::pin(reused_code_is_refused_without_leaking_it(
                env.clone(),
                redirect,
            )),
        );
        add(
            "exchange_refuses_a_response_that_carries_no_id_token",
            Box::pin(exchange_refuses_a_response_that_carries_no_id_token(
                env.clone(),
                redirect,
            )),
        );
        add(
            "id_token_for_another_audience_is_refused",
            Box::pin(id_token_for_another_audience_is_refused(
                env.clone(),
                redirect,
            )),
        );
        add(
            "id_token_signed_outside_the_algorithm_pin_is_refused",
            Box::pin(id_token_signed_outside_the_algorithm_pin_is_refused(
                env.clone(),
                redirect,
            )),
        );
        add(
            "id_token_signed_by_a_key_outside_the_jwks_is_refused/RS256",
            Box::pin(id_token_signed_by_a_key_outside_the_jwks_is_refused(
                env.clone(),
                redirect,
                RS256_ONLY,
            )),
        );
        add(
            "id_token_signed_by_a_key_outside_the_jwks_is_refused/RS256+HS256",
            Box::pin(id_token_signed_by_a_key_outside_the_jwks_is_refused(
                env.clone(),
                redirect,
                RS256_AND_HS256,
            )),
        );
    }

    let mut failed = Vec::new();
    for (name, scenario) in scenarios {
        match tokio::spawn(scenario).await {
            Ok(()) => println!("scenario {name} ... ok"),
            Err(join) => {
                println!("scenario {name} ... FAILED: {}", panic_text(join));
                failed.push(name);
            }
        }
    }
    assert!(failed.is_empty(), "failed scenarios: {failed:#?}");
}
