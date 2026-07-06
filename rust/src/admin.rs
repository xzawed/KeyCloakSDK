//! AdminClient — keycloak crate 래핑. TokenProvider를 KeycloakTokenSupplier로 어댑트(admin↔auth 결합=TokenProvider).
//!
//! `admin`은 `auth`를 직접 알지 못한다 — 유일한 접착제는 `TokenProvider`다. `SdkTokenSupplier`가
//! 우리 `TokenProvider`를 keycloak crate의 `KeycloakTokenSupplier`로 어댑트(우리→그들 오류 변환)한다.
//! 하위 crate 오류(`keycloak::KeycloakError`)는 경계(`map_admin`)에서 우리 `KeycloakError`로 변환되어
//! 공개 API로 누출되지 않는다. `raw()`가 반환하는 `&KeycloakAdmin`과 representation 타입은
//! 문서화된 은닉성 예외(모든 SDK에서 admin representation은 leaked-by-design)다.
//! 커버리지 omit(네트워크 경계) — CRUD는 Task 11 통합테스트로 검증, 여기선 `map_admin` 매핑만 단위테스트.
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::token_provider::TokenProvider;
use async_trait::async_trait;
use keycloak::prelude::reqwest;
use keycloak::types::{ClientRepresentation, UserRepresentation};
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
    /// username 정확일치(exact=true) 검색. 인자 순서: brief_representation·created_after·created_before·
    /// email·email_verified·enabled·`exact`·`first`·first_name·idp_alias·idp_user_id·last_name·`max`·q·search·`username`.
    pub async fn search_users(&self, username: &str) -> Result<Vec<UserRepresentation>> {
        self.admin
            .realm_users_get(
                &self.realm,
                None,                       // brief_representation
                None,                       // created_after
                None,                       // created_before
                None,                       // email
                None,                       // email_verified
                None,                       // enabled
                Some(true),                 // exact = true(정확일치)
                Some(0),                    // first(페이징 오프셋)
                None,                       // first_name
                None,                       // idp_alias
                None,                       // idp_user_id
                None,                       // last_name
                Some(20),                   // max(합리적 페이지 크기)
                None,                       // q
                None,                       // search
                Some(username.to_string()), // username
            )
            .await
            .map_err(map_admin)
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

    /// 탈출구 — 내부 `KeycloakAdmin`(모든 생성 메서드·representation 접근). 문서화된 은닉성 예외.
    pub fn raw(&self) -> &KeycloakAdmin<SdkTokenSupplier> {
        &self.admin
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::AdminError;

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
}
