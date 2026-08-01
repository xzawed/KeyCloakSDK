//! 실제 Keycloak 26.6 E2E (testcontainers). 실행:
//!   cargo test --test integration_test -- --ignored --nocapture   (Docker 필요)
//!
//! 5 admin 리소스 전부 커버 — client-credentials → validate(실 JWKS·RS256 강화) → introspect →
//! user/client/role/group CRUD(+ delete 후 조회 → NotFound) → raw() 스모크 → realm CRUD(master-admin).
//! SDK 소스는 수정하지 않는다(공개 API만 소비). 실 KC로 버그 발견 시 보고.

use async_trait::async_trait;
use keycloak::prelude::reqwest;
use keycloak::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak_sdk::error::Result as SdkResult;
use keycloak_sdk::{
    AdminClient, AdminError, KeycloakClient, KeycloakConfig, KeycloakError, TokenProvider,
};
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
    client.admin().delete_group(&gid).await.unwrap();

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
