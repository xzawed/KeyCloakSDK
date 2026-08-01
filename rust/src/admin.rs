//! AdminClient — keycloak crate 래핑. TokenProvider를 KeycloakTokenSupplier로 어댑트(admin↔auth 결합=TokenProvider).
//!
//! `admin`은 `auth`를 직접 알지 못한다 — 유일한 접착제는 `TokenProvider`다. `SdkTokenSupplier`가
//! 우리 `TokenProvider`를 keycloak crate의 `KeycloakTokenSupplier`로 어댑트(우리→그들 오류 변환)한다.
//! 하위 crate 오류(`keycloak::KeycloakError`)는 경계(`map_admin`)에서 우리 `KeycloakError`로 변환되어
//! 공개 API로 누출되지 않는다. `raw()`가 반환하는 `&KeycloakAdmin`과 representation 타입은
//! 문서화된 은닉성 예외(모든 SDK에서 admin representation은 leaked-by-design)다.
//! 커버리지 omit(네트워크 경계) — CRUD는 Task 11 통합테스트로 검증, 여기선 `map_admin` 매핑만 단위테스트.
use crate::config::KeycloakConfig;
use crate::error::{AdminError, KeycloakError, Result};
use crate::token_provider::TokenProvider;
use async_trait::async_trait;
use keycloak::prelude::reqwest;
use keycloak::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak::{KeycloakAdmin, KeycloakError as KcError, KeycloakTokenSupplier};
use std::sync::Arc;

/// 우리 `TokenProvider` → keycloak crate의 `KeycloakTokenSupplier`(`#[async_trait]`) 어댑터.
/// admin↔auth의 유일한 접착제(admin은 AuthClient를 직접 참조하지 않는다).
pub struct SdkTokenSupplier {
    inner: Arc<dyn TokenProvider>,
}

#[async_trait]
impl KeycloakTokenSupplier for SdkTokenSupplier {
    async fn get(&self, _url: &str) -> std::result::Result<String, KcError> {
        // 우리 오류를 keycloak::KeycloakError로 변환(어댑터 경계, 우리→그들).
        // 토큰 획득 실패는 인증 문제이므로 401 HttpFailure로 표면화(map_admin이 다시 우리 타입으로 변환).
        self.inner
            .access_token()
            .await
            .map_err(|e| KcError::HttpFailure {
                status: 401,
                body: None,
                text: format!("token supplier: {e}"),
            })
    }
}

pub struct AdminClient {
    admin: KeycloakAdmin<SdkTokenSupplier>,
    realm: String,
}

/// keycloak::KeycloakError → 우리 KeycloakError(중앙 경계 변환기).
/// HttpFailure는 상태코드로(404→NotFound·409→Conflict·403→Forbidden·else→Other), ReqwestFailure는 Transport.
fn map_admin(e: KcError) -> KeycloakError {
    match e {
        KcError::HttpFailure { status, .. } => KeycloakError::from_admin_status(status),
        KcError::ReqwestFailure(re) => KeycloakError::Transport(format!("admin request: {re}")),
    }
}

impl AdminClient {
    /// 공유 `http`(TLS·타임아웃·SSRF 정책이 주입된)와 `TokenProvider`를 어댑트해 `KeycloakAdmin`을 조립한다.
    pub fn new(
        config: &KeycloakConfig,
        http: reqwest::Client,
        token_provider: Arc<dyn TokenProvider>,
    ) -> Self {
        let admin = KeycloakAdmin::new(
            &config.server_url,
            SdkTokenSupplier {
                inner: token_provider,
            },
            http,
        );
        Self {
            admin,
            realm: config.realm.clone(),
        }
    }

    // ── Users ──
    /// 사용자 생성. 생성된 id는 응답 `Location` 헤더에서 추출(`to_id`) — 없으면 `None`.
    pub async fn create_user(&self, user: UserRepresentation) -> Result<Option<String>> {
        let resp = self
            .admin
            .realm_users_post(&self.realm, user)
            .await
            .map_err(map_admin)?;
        Ok(resp.to_id().map(str::to_string))
    }
    /// id로 사용자 단건 조회(부재 시 404→`AdminError::NotFound`).
    pub async fn get_user(&self, user_id: &str) -> Result<UserRepresentation> {
        self.admin
            .realm_users_with_user_id_get(&self.realm, user_id, None)
            .await
            .map_err(map_admin)
    }
    /// 사용자 검색(부분일치 — Keycloak 기본 매칭). **페이지 경계는 호출자가 정한다.**
    ///
    /// - `username`: `None`이면 필터 없이 realm 전체를 페이지 단위로 훑는다(= users.list).
    ///   `Some(u)`는 username에 `u`가 **포함된** 사용자를 찾는다(정확일치는 [`Self::find_user_by_username`]).
    /// - `first`: 0-based 페이지 오프셋. Keycloak은 음수를 "오프셋 없음"으로 무시한다.
    /// - `max`: 이 페이지의 최대 건수. **음수(`-1`)는 "서버 측 상한 없음"** 이다.
    ///
    /// ⚠️ `max`에 `Option`을 두지 않은 것은 의도다 — Keycloak은 `max`가 없으면
    /// `Constants.DEFAULT_MAX_RESULTS`(**100**)를 조용히 적용한다. 생략을 허용하면 "상한이 없다"고
    /// 읽히는 호출이 실제로는 100에서 잘린다. 상한은 항상 호출부에 **보이는** 값이어야 한다.
    ///
    /// ⚠️ 반환 길이가 `max`와 같다면 **다음 페이지가 있을 수 있다**(총건수는 이 응답에 없다).
    /// 끝까지 훑으려면 `first`를 `max`씩 늘리며 길이 < `max`가 될 때까지 반복한다.
    ///
    /// 인자 순서: brief_representation·created_after·created_before·email·email_verified·enabled·
    /// `exact`·`first`·first_name·idp_alias·idp_user_id·last_name·`max`·q·search·`username`.
    pub async fn search_users(
        &self,
        username: Option<&str>,
        first: i32,
        max: i32,
    ) -> Result<Vec<UserRepresentation>> {
        self.admin
            .realm_users_get(
                &self.realm,
                None,                         // brief_representation
                None,                         // created_after
                None,                         // created_before
                None,                         // email
                None,                         // email_verified
                None,                         // enabled
                None,                         // exact 미전송 = Keycloak 기본(부분일치)
                Some(first),                  // first(페이징 오프셋)
                None,                         // first_name
                None,                         // idp_alias
                None,                         // idp_user_id
                None,                         // last_name
                Some(max),                    // max(페이지 크기 — 호출자 소유)
                None,                         // q
                None,                         // search
                username.map(str::to_string), // username
            )
            .await
            .map_err(map_admin)
    }
    /// username **정확일치** 단건 조회(`exact=true`). 없으면 `Ok(None)`.
    ///
    /// 페이지네이션 인자가 없는 것은 잘림이 **구조적으로 불가능**하기 때문이다 — Keycloak은 realm 안에서
    /// username 유일성을 강제하므로 `exact=true` 결과는 0건 아니면 1건이다. 그래도 `max=2`를 요청한다:
    /// `max=1`이면 "1건 반환"이 정말 1건인지 잘린 것인지 구분할 수 없다. 2건이 오면 그 불변식이 깨진
    /// 것이므로 첫 건을 조용히 고르지 않고 [`AdminError::Conflict`]로 표면화한다.
    pub async fn find_user_by_username(
        &self,
        username: &str,
    ) -> Result<Option<UserRepresentation>> {
        let found = self
            .admin
            .realm_users_get(
                &self.realm,
                None,                       // brief_representation
                None,                       // created_after
                None,                       // created_before
                None,                       // email
                None,                       // email_verified
                None,                       // enabled
                Some(true),                 // exact = true(정확일치)
                Some(0),                    // first
                None,                       // first_name
                None,                       // idp_alias
                None,                       // idp_user_id
                None,                       // last_name
                Some(2),                    // max — 유일성 위반 탐지용(1이면 잘림과 구분 불가)
                None,                       // q
                None,                       // search
                Some(username.to_string()), // username
            )
            .await
            .map_err(map_admin)?;
        if found.len() > 1 {
            return Err(KeycloakError::Admin(AdminError::Conflict));
        }
        Ok(found.into_iter().next())
    }
    /// id로 사용자 삭제.
    pub async fn delete_user(&self, user_id: &str) -> Result<()> {
        self.admin
            .realm_users_with_user_id_delete(&self.realm, user_id)
            .await
            .map_err(map_admin)?;
        Ok(())
    }

    // ── Clients ──
    /// 클라이언트 생성. 생성된 uuid는 응답 `Location` 헤더에서 추출(`to_id`) — 없으면 `None`.
    pub async fn create_client(&self, client: ClientRepresentation) -> Result<Option<String>> {
        let resp = self
            .admin
            .realm_clients_post(&self.realm, client)
            .await
            .map_err(map_admin)?;
        Ok(resp.to_id().map(str::to_string))
    }
    /// uuid로 클라이언트 단건 조회(부재 시 404→`AdminError::NotFound`).
    pub async fn get_client(&self, client_uuid: &str) -> Result<ClientRepresentation> {
        self.admin
            .realm_clients_with_client_uuid_get(&self.realm, client_uuid)
            .await
            .map_err(map_admin)
    }
    /// uuid로 클라이언트 삭제.
    pub async fn delete_client(&self, client_uuid: &str) -> Result<()> {
        self.admin
            .realm_clients_with_client_uuid_delete(&self.realm, client_uuid)
            .await
            .map_err(map_admin)?;
        Ok(())
    }

    // ── Realms ──
    /// 설정된 realm의 최상위 representation 조회(중첩 User/Client 미포함).
    pub async fn get_realm(&self) -> Result<RealmRepresentation> {
        self.admin.realm_get(&self.realm).await.map_err(map_admin)
    }
    /// 신규 realm 생성(`POST /admin/realms`).
    /// ⚠️ 이 연산은 **master-realm 권한**을 요구한다 — realm 서비스계정으로는 403(Forbidden)이다.
    /// (realm-scoped 연산이 아니라 전역 부트스트랩 권한이므로 모든 Keycloak에서 master 전용.)
    /// 타입드 메서드는 런타임 권한과 무관하게 파사드에 존재한다.
    pub async fn create_realm(&self, realm: RealmRepresentation) -> Result<()> {
        self.admin.post(realm).await.map_err(map_admin)?;
        Ok(())
    }
    /// realm 삭제(`DELETE /admin/realms/{realm}`).
    /// ⚠️ `create_realm`과 동일하게 **master-realm 권한**을 요구한다(realm 서비스계정 403).
    pub async fn delete_realm(&self, name: &str) -> Result<()> {
        self.admin.realm_delete(name).await.map_err(map_admin)?;
        Ok(())
    }

    // ── Roles (realm-level) ──
    /// realm 롤 생성.
    pub async fn create_role(&self, role: RoleRepresentation) -> Result<()> {
        self.admin
            .realm_roles_post(&self.realm, role)
            .await
            .map_err(map_admin)?;
        Ok(())
    }
    /// name으로 realm 롤 단건 조회(부재 시 404→`AdminError::NotFound`).
    pub async fn get_role(&self, name: &str) -> Result<RoleRepresentation> {
        self.admin
            .realm_roles_with_role_name_get(&self.realm, name)
            .await
            .map_err(map_admin)
    }
    /// name으로 realm 롤 삭제.
    pub async fn delete_role(&self, name: &str) -> Result<()> {
        self.admin
            .realm_roles_with_role_name_delete(&self.realm, name)
            .await
            .map_err(map_admin)?;
        Ok(())
    }

    // ── Groups ──
    /// 그룹 생성. 생성된 id는 응답 `Location` 헤더에서 추출(`to_id`) — 없으면 `None`.
    pub async fn create_group(&self, group: GroupRepresentation) -> Result<Option<String>> {
        let resp = self
            .admin
            .realm_groups_post(&self.realm, group)
            .await
            .map_err(map_admin)?;
        Ok(resp.to_id().map(str::to_string))
    }
    /// id로 그룹 단건 조회(부재 시 404→`AdminError::NotFound`).
    pub async fn get_group(&self, id: &str) -> Result<GroupRepresentation> {
        self.admin
            .realm_groups_with_group_id_get(&self.realm, id)
            .await
            .map_err(map_admin)
    }
    /// id로 그룹 삭제.
    pub async fn delete_group(&self, id: &str) -> Result<()> {
        self.admin
            .realm_groups_with_group_id_delete(&self.realm, id)
            .await
            .map_err(map_admin)?;
        Ok(())
    }

    /// 탈출구 — 내부 `KeycloakAdmin`(모든 생성 메서드·representation 접근). 문서화된 은닉성 예외.
    pub fn raw(&self) -> &KeycloakAdmin<SdkTokenSupplier> {
        &self.admin
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path, query_param, query_param_is_missing};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    // 네트워크 경계는 omit이므로 CRUD는 Task 11 통합에서 검증. 여기선 map_admin 상태매핑만 단위테스트.
    #[test]
    fn maps_admin_status_codes() {
        assert!(matches!(
            map_admin(KcError::HttpFailure {
                status: 404,
                body: None,
                text: String::new()
            }),
            KeycloakError::Admin(AdminError::NotFound)
        ));
        assert!(matches!(
            map_admin(KcError::HttpFailure {
                status: 409,
                body: None,
                text: String::new()
            }),
            KeycloakError::Admin(AdminError::Conflict)
        ));
        assert!(matches!(
            map_admin(KcError::HttpFailure {
                status: 403,
                body: None,
                text: String::new()
            }),
            KeycloakError::Admin(AdminError::Forbidden)
        ));
        assert!(matches!(
            map_admin(KcError::HttpFailure {
                status: 500,
                body: None,
                text: String::new()
            }),
            KeycloakError::Admin(AdminError::Other { status: 500 })
        ));
    }

    struct StubProvider;
    #[async_trait]
    impl TokenProvider for StubProvider {
        async fn access_token(&self) -> Result<String> {
            Ok("AT".to_string())
        }
    }

    fn admin_against(server: &MockServer) -> AdminClient {
        let config = KeycloakConfig::new(server.uri(), "it-realm", "it-client").unwrap();
        AdminClient::new(&config, reqwest::Client::new(), Arc::new(StubProvider))
    }

    // ── search_users: 페이지 경계가 실제로 와이어에 실리는지 ──
    // wiremock은 매치되지 않은 요청에 404를 돌려준다 → map_admin이 Admin(NotFound)로 바꾼다.
    // 즉 쿼리스트링이 하나라도 어긋나면 이 테스트들은 Ok가 아니라 Err로 떨어져 실패한다.
    // "호출했더니 뭔가 돌아왔다"가 아니라 **서버가 무엇을 받았는지**를 단언하는 구조다.

    #[tokio::test]
    async fn search_users_puts_caller_pagination_on_the_wire() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/users"))
            .and(query_param("username", "ali"))
            .and(query_param("first", "40")) // 하드코딩 0이 아니라 호출자 값
            .and(query_param("max", "25")) // 하드코딩 20이 아니라 호출자 값
            .and(query_param_is_missing("exact")) // 부분일치 = Keycloak 기본
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!([{"id":"u1"}])),
            )
            .expect(1)
            .mount(&server)
            .await;

        let users = admin_against(&server)
            .search_users(Some("ali"), 40, 25)
            .await
            .expect("query string must match: first/max are the caller's, exact unset");
        assert_eq!(users.len(), 1);
    }

    #[tokio::test]
    async fn search_users_without_username_lists_the_realm() {
        // username=None은 필터를 통째로 빼야 한다(빈 문자열 필터가 아니라 users.list).
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/users"))
            .and(query_param_is_missing("username"))
            .and(query_param("first", "0"))
            .and(query_param("max", "100"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([])))
            .expect(1)
            .mount(&server)
            .await;

        assert!(
            admin_against(&server)
                .search_users(None, 0, 100)
                .await
                .expect("username=None이면 username 파라미터 자체가 없어야 한다")
                .is_empty()
        );
    }

    #[tokio::test]
    async fn search_users_forwards_negative_max_as_no_server_limit() {
        // Keycloak: max 생략 → Constants.DEFAULT_MAX_RESULTS(100), 음수 → 상한 미적용.
        // 그러므로 "상한 없음"은 max를 빼는 게 아니라 음수를 **보내야** 표현된다.
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/users"))
            .and(query_param("max", "-1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([])))
            .expect(1)
            .mount(&server)
            .await;

        admin_against(&server)
            .search_users(None, 0, -1)
            .await
            .expect("max=-1이 그대로 전달돼야 서버가 상한을 걸지 않는다");
    }

    #[tokio::test]
    async fn find_user_by_username_asks_for_an_exact_match() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/users"))
            .and(query_param("username", "alice"))
            .and(query_param("exact", "true")) // 부분일치로 새면 안 된다
            .and(query_param("max", "2")) // 유일성 위반 탐지분(1이면 잘림과 구분 불가)
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(serde_json::json!([{"id":"u1","username":"alice"}])),
            )
            .expect(1)
            .mount(&server)
            .await;

        let found = admin_against(&server)
            .find_user_by_username("alice")
            .await
            .expect("exact=true·max=2가 와이어에 실려야 한다");
        assert_eq!(found.and_then(|u| u.id).as_deref(), Some("u1"));
    }

    #[tokio::test]
    async fn find_user_by_username_returns_none_when_absent() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/users"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([])))
            .mount(&server)
            .await;

        assert!(
            admin_against(&server)
                .find_user_by_username("nobody")
                .await
                .unwrap()
                .is_none(),
            "빈 결과는 NotFound 오류가 아니라 Ok(None)이다"
        );
    }

    #[tokio::test]
    async fn find_user_by_username_surfaces_duplicates_instead_of_picking_one() {
        // exact 조회가 2건이면 username 유일성 불변식이 깨진 것이다 — 첫 건을 조용히 고르지 않는다.
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/users"))
            .respond_with(ResponseTemplate::new(200).set_body_json(
                serde_json::json!([{"id":"u1","username":"alice"},{"id":"u2","username":"alice"}]),
            ))
            .mount(&server)
            .await;

        match admin_against(&server).find_user_by_username("alice").await {
            Err(KeycloakError::Admin(AdminError::Conflict)) => {}
            other => panic!("중복 exact 매치는 Conflict여야 한다, got {other:?}"),
        }
    }
}
