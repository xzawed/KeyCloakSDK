//! AdminClient — admin REST 파사드. 요청은 SDK 가 보내고, `keycloak` crate 에서는 representation 타입만 빌린다.
//!
//! ⚠️ **파사드는 crate 의 생성 메서드를 부르지 않는다** — 그 메서드는 2xx 가 아니면 `error_check` 에서 본문을 통째로
//! `text()` 로 읽는다(64 MiB 오류 본문 하나에 서버가 끝까지 쓰고 할당이 그 몇 배로 는다 — 실측은
//! `tests/admin_response_body.rs`). 파사드의 오류는 상태로만 고르므로 그 본문은 쓰이지 않는다. 그래서 crate 와 **같은
//! 요청**(경로 조각 인코딩 [`p`] · 쿼리와 그 순서 · Bearer · JSON 본문)을 직접 보내고, 오류 본문은 상한까지만 비운다
//! ([`reject`]). 같은 요청인지는 그 파일의 `the_facade_sends_what_the_crate_sends` 가 `raw()` 의 crate 메서드와 와이어로
//! 대조한다 — crate 를 올리면 거기부터 본다.
//!
//! `admin`은 `auth`를 직접 알지 못한다 — 유일한 접착제는 `TokenProvider`다. 하위 오류(`reqwest::Error`)는 경계에서
//! 우리 `KeycloakError`로 바뀌어 공개 API로 누출되지 않는다. `raw()`가 반환하는 `&KeycloakAdmin`과 representation
//! 타입은 문서화된 은닉성 예외(모든 SDK에서 admin representation은 leaked-by-design)다. ⚠️ `raw()` 는 crate 그대로라
//! 그 오류 본문은 **여전히 끝까지 읽힌다** — reqwest 0.12 에는 응답을 가로챌 자리가 없다.
//! 커버리지 omit(네트워크 경계) — CRUD는 Task 11 통합테스트로, 요청 모양은 아래 단위테스트와 `tests/admin_response_body.rs` 로 검증.
use crate::config::KeycloakConfig;
use crate::error::{AdminError, KeycloakError, Result};
use crate::jwks::TOKEN_RESPONSE_MAX_BYTES;
use crate::token_provider::TokenProvider;
use async_trait::async_trait;
use keycloak::prelude::reqwest;
use keycloak::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak::{KeycloakAdmin, KeycloakError as KcError, KeycloakTokenSupplier};
use serde::de::DeserializeOwned;
use std::sync::Arc;

/// 우리 `TokenProvider` → keycloak crate의 `KeycloakTokenSupplier`(`#[async_trait]`) 어댑터 — `raw()` 의 crate 가 쓴다.
/// admin↔auth의 유일한 접착제(admin은 AuthClient를 직접 참조하지 않는다). 파사드는 `TokenProvider` 를 직접 부른다.
pub struct SdkTokenSupplier {
    inner: Arc<dyn TokenProvider>,
}

#[async_trait]
impl KeycloakTokenSupplier for SdkTokenSupplier {
    async fn get(&self, _url: &str) -> std::result::Result<String, KcError> {
        // 우리 오류를 keycloak::KeycloakError로 변환(어댑터 경계, 우리→그들).
        // 토큰 획득 실패는 인증 문제이므로 401 HttpFailure로 표면화(파사드도 같은 401 이다 — `AdminClient::send`).
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
    /// `raw()` 탈출구 — crate 그대로다. 파사드는 이것을 거치지 않는다(같은 `http` 연결 풀을 쓴다).
    admin: KeycloakAdmin<SdkTokenSupplier>,
    http: reqwest::Client,
    token_provider: Arc<dyn TokenProvider>,
    /// crate 에 준 것과 같은 server_url — 요청 URL 이 crate 의 것과 같은 문자열이 된다.
    url: String,
    realm: String,
}

/// 경로 조각 하나를 퍼센트 인코딩한다 — `keycloak` crate 의 `encode_url_param`(26.6.2 `src/rest/url_enc.rs`)과 같은
/// 집합이다: 제어 문자 · 비ASCII 바이트 · 공백 `"` `<` `>` `` ` `` `#` `?` `{` `}` `/` `%`(16진은 대문자).
fn p(segment: &str) -> String {
    const ESCAPED: &[u8] = b" \"<>`#?{}/%";
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(segment.len());
    for &b in segment.as_bytes() {
        if !(0x20..0x7F).contains(&b) || ESCAPED.contains(&b) {
            out.push('%');
            out.push(char::from(HEX[usize::from(b >> 4)]));
            out.push(char::from(HEX[usize::from(b & 0x0F)]));
        } else {
            out.push(char::from(b));
        }
    }
    out
}

fn transport(e: reqwest::Error) -> KeycloakError {
    KeycloakError::Transport(format!("admin request: {e}"))
}

/// 생성된 리소스의 id — `Location` 머리의 마지막 `/` 조각(crate 의 `DefaultResponse::to_id` 와 같다). 없으면 `None`.
fn created_id(resp: &reqwest::Response) -> Option<String> {
    resp.headers()
        .get(reqwest::header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split('/').next_back())
        .map(str::to_string)
}

/// 2xx 가 아닌 응답의 오류 — **상태로 고른다**(404→NotFound·409→Conflict·403→Forbidden·else→Other). 본문은 쓰지 않는다.
///
/// 본문은 HTTP/1.1 연결을 다음 요청이 다시 쓰도록 [`TOKEN_RESPONSE_MAX_BYTES`] 까지만 비워 버린다 — 그보다 길다고 알린
/// 본문은 읽지 않고, 길이를 알리지 않은 본문은 상한을 넘는 순간 버린다(그 연결은 닫힌다). 비우다 난 오류는 삼킨다 —
/// 머리가 왔으니 상태가 답이다. ⚠️ 받은 바이트를 모으지 않는다 — 청크마다 세고 버린다.
/// ⚠️ reqwest 가 압축을 풀면(이 crate 는 그 기능을 켜지 않는다 — 소비자 빌드의 기능 통합) `Content-Length` 를 지워
/// `content_length()` 가 `None` 이다 — 그 본문은 푼 바이트로 상한까지 비우고, 그 안에서 멈추면 기한까지 기다린다.
async fn reject(mut resp: reqwest::Response) -> KeycloakError {
    let status = resp.status().as_u16();
    if resp
        .content_length()
        .is_none_or(|declared| declared <= TOKEN_RESPONSE_MAX_BYTES as u64)
    {
        let mut seen = 0usize;
        while let Ok(Some(chunk)) = resp.chunk().await {
            seen = seen.saturating_add(chunk.len());
            if seen > TOKEN_RESPONSE_MAX_BYTES {
                break;
            }
        }
    }
    KeycloakError::from_admin_status(status)
}

impl AdminClient {
    /// 공유 `http`(TLS·타임아웃·SSRF 정책이 주입된)와 `TokenProvider`로 파사드를 만들고, 같은 둘로 `raw()` 의
    /// `KeycloakAdmin`을 조립한다.
    pub fn new(
        config: &KeycloakConfig,
        http: reqwest::Client,
        token_provider: Arc<dyn TokenProvider>,
    ) -> Self {
        let admin = KeycloakAdmin::new(
            &config.server_url,
            SdkTokenSupplier {
                inner: token_provider.clone(),
            },
            http.clone(),
        );
        Self {
            admin,
            http,
            token_provider,
            url: config.server_url.clone(),
            realm: config.realm.clone(),
        }
    }

    /// `{server}/admin/realms/{realm}` — 설정된 realm 의 주소.
    fn realm_url(&self) -> String {
        format!("{}/admin/realms/{}", self.url, p(&self.realm))
    }

    /// 보낸다 — 토큰 → Bearer → 전송. 2xx 면 본문을 **읽지 않은** 응답을, 아니면 상태로 고른 오류([`reject`])를 낸다.
    /// 토큰을 못 얻으면 요청을 보내지 않고 `Admin(Other { status: 401 })` 이다 — crate 를 거치던 때와 같다
    /// (`tests/token_response_cap.rs` 의 `rejected_over_cap`).
    async fn send(&self, req: reqwest::RequestBuilder) -> Result<reqwest::Response> {
        let token = self
            .token_provider
            .access_token()
            .await
            .map_err(|_| KeycloakError::from_admin_status(401))?;
        let resp = req.bearer_auth(token).send().await.map_err(transport)?;
        if resp.status().is_success() {
            Ok(resp)
        } else {
            Err(reject(resp).await)
        }
    }

    /// GET — 2xx 본문을 JSON 으로 읽는다. 상한은 없다(정책 — `tests/token_response_cap.rs` 의
    /// `admin_rest_response_is_not_capped`).
    async fn fetch<T: DeserializeOwned>(&self, req: reqwest::RequestBuilder) -> Result<T> {
        self.send(req).await?.json().await.map_err(transport)
    }

    // ── Users ──
    /// 사용자 생성. 생성된 id는 응답 `Location` 헤더의 마지막 조각 — 없으면 `None`. 응답 본문은 읽지 않는다.
    pub async fn create_user(&self, user: UserRepresentation) -> Result<Option<String>> {
        let url = format!("{}/users", self.realm_url());
        let resp = self.send(self.http.post(url).json(&user)).await?;
        Ok(created_id(&resp))
    }
    /// id로 사용자 단건 조회(부재 시 404→`AdminError::NotFound`).
    pub async fn get_user(&self, user_id: &str) -> Result<UserRepresentation> {
        let url = format!("{}/users/{}", self.realm_url(), p(user_id));
        self.fetch(self.http.get(url)).await
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
    /// 쿼리는 crate 의 `realm_users_get` 과 같은 순서로 싣는다(`exact`·`first`·`max`·`username` — 쓰지 않는 것은
    /// 싣지 않는다). `exact` 미전송 = Keycloak 기본(부분일치).
    pub async fn search_users(
        &self,
        username: Option<&str>,
        first: i32,
        max: i32,
    ) -> Result<Vec<UserRepresentation>> {
        let mut req = self
            .http
            .get(format!("{}/users", self.realm_url()))
            .query(&[("first", first)]) // 페이징 오프셋
            .query(&[("max", max)]); // 페이지 크기 — 호출자 소유
        if let Some(username) = username {
            req = req.query(&[("username", username)]);
        }
        self.fetch(req).await
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
        let req = self
            .http
            .get(format!("{}/users", self.realm_url()))
            .query(&[("exact", true)]) // 정확일치
            .query(&[("first", 0)])
            .query(&[("max", 2)]) // 유일성 위반 탐지용(1이면 잘림과 구분 불가)
            .query(&[("username", username)]);
        let found: Vec<UserRepresentation> = self.fetch(req).await?;
        if found.len() > 1 {
            return Err(KeycloakError::Admin(AdminError::Conflict));
        }
        Ok(found.into_iter().next())
    }
    /// id로 사용자 갱신. `user`는 **부분(sparse) representation**이어도 된다.
    ///
    /// ⚠️ 경로(`user_id`)와 body(`user`)는 별개다 — 합치지 말 것(아래 `update_realm` 참고).
    pub async fn update_user(&self, user_id: &str, user: UserRepresentation) -> Result<()> {
        let url = format!("{}/users/{}", self.realm_url(), p(user_id));
        self.send(self.http.put(url).json(&user)).await?;
        Ok(())
    }
    /// id로 사용자 삭제.
    pub async fn delete_user(&self, user_id: &str) -> Result<()> {
        let url = format!("{}/users/{}", self.realm_url(), p(user_id));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    // ── Clients ──
    /// 클라이언트 생성. 생성된 uuid는 응답 `Location` 헤더의 마지막 조각 — 없으면 `None`.
    pub async fn create_client(&self, client: ClientRepresentation) -> Result<Option<String>> {
        let url = format!("{}/clients", self.realm_url());
        let resp = self.send(self.http.post(url).json(&client)).await?;
        Ok(created_id(&resp))
    }
    /// uuid로 클라이언트 단건 조회(부재 시 404→`AdminError::NotFound`).
    pub async fn get_client(&self, client_uuid: &str) -> Result<ClientRepresentation> {
        let url = format!("{}/clients/{}", self.realm_url(), p(client_uuid));
        self.fetch(self.http.get(url)).await
    }
    /// 클라이언트 목록. **페이지 경계는 호출자가 정한다**([`Self::search_users`]와 같은 이유로
    /// `max`는 `Option`이 아니다 — 상한은 항상 호출부에 보이는 값이어야 한다).
    ///
    /// 반환 길이가 `max`와 같다면 다음 페이지가 있을 수 있다(총건수는 응답에 없다).
    /// `clientId` 필터는 싣지 않는다(clientId 정확일치 단건은 `raw()`로).
    pub async fn list_clients(&self, first: i32, max: i32) -> Result<Vec<ClientRepresentation>> {
        let req = self
            .http
            .get(format!("{}/clients", self.realm_url()))
            .query(&[("first", first)])
            .query(&[("max", max)]);
        self.fetch(req).await
    }
    /// uuid로 주소를 잡아 클라이언트를 갱신한다. `client.client_id`에 새 값을 주면 rename이다.
    ///
    /// ⚠️ 경로(`client_uuid`)와 body(`client`)는 별개다.
    pub async fn update_client(
        &self,
        client_uuid: &str,
        client: ClientRepresentation,
    ) -> Result<()> {
        let url = format!("{}/clients/{}", self.realm_url(), p(client_uuid));
        self.send(self.http.put(url).json(&client)).await?;
        Ok(())
    }
    /// uuid로 클라이언트 삭제.
    pub async fn delete_client(&self, client_uuid: &str) -> Result<()> {
        let url = format!("{}/clients/{}", self.realm_url(), p(client_uuid));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    // ── Realms ──
    /// 설정된 realm의 최상위 representation 조회(중첩 User/Client 미포함).
    pub async fn get_realm(&self) -> Result<RealmRepresentation> {
        self.fetch(self.http.get(self.realm_url())).await
    }
    /// 신규 realm 생성(`POST /admin/realms`).
    /// ⚠️ 이 연산은 **master-realm 권한**을 요구한다 — realm 서비스계정으로는 403(Forbidden)이다.
    /// (realm-scoped 연산이 아니라 전역 부트스트랩 권한이므로 모든 Keycloak에서 master 전용.)
    /// 타입드 메서드는 런타임 권한과 무관하게 파사드에 존재한다.
    pub async fn create_realm(&self, realm: RealmRepresentation) -> Result<()> {
        let url = format!("{}/admin/realms", self.url);
        self.send(self.http.post(url).json(&realm)).await?;
        Ok(())
    }
    /// 호출한 서비스 계정이 볼 수 있는 realm 목록(`GET /admin/realms` — realm-scoped가 아닌 전역).
    /// 보통 자기 realm 하나만 돌아온다. 페이지네이션 파라미터는 이 엔드포인트에 없다.
    pub async fn list_realms(&self) -> Result<Vec<RealmRepresentation>> {
        self.fetch(self.http.get(format!("{}/admin/realms", self.url)))
            .await
    }
    /// **현재 이름**으로 주소를 잡아 realm을 갱신한다(`PUT /admin/realms/{name}`).
    /// `realm.realm`에 새 이름을 주면 rename이다.
    ///
    /// ⚠️ **경로(`name`)와 body(`realm`)를 합치지 말 것.** Keycloak의 rename은
    /// "현재 주소에 새 값을 PUT"이므로, 경로를 representation에서 만들면 rename 요청이
    /// 새 이름을 가리켜 **조용한 no-op**이 된다(응답은 2xx인데 아무것도 안 바뀐다).
    /// 자매 Go SDK는 gocloak이 정확히 그렇게 동작해 이 한 자리만 raw REST로 우회해야 했다 —
    /// 여기선 경로를 `name` 으로, body 를 `realm` 으로 따로 만든다(crate 의 `realm_put(realm, body)` 와 같다).
    pub async fn update_realm(&self, name: &str, realm: RealmRepresentation) -> Result<()> {
        let url = format!("{}/admin/realms/{}", self.url, p(name));
        self.send(self.http.put(url).json(&realm)).await?;
        Ok(())
    }
    /// realm 삭제(`DELETE /admin/realms/{realm}`).
    /// ⚠️ `create_realm`과 동일하게 **master-realm 권한**을 요구한다(realm 서비스계정 403).
    pub async fn delete_realm(&self, name: &str) -> Result<()> {
        let url = format!("{}/admin/realms/{}", self.url, p(name));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    // ── Roles (realm-level) ──
    /// realm 롤 생성.
    pub async fn create_role(&self, role: RoleRepresentation) -> Result<()> {
        let url = format!("{}/roles", self.realm_url());
        self.send(self.http.post(url).json(&role)).await?;
        Ok(())
    }
    /// name으로 realm 롤 단건 조회(부재 시 404→`AdminError::NotFound`).
    pub async fn get_role(&self, name: &str) -> Result<RoleRepresentation> {
        let url = format!("{}/roles/{}", self.realm_url(), p(name));
        self.fetch(self.http.get(url)).await
    }
    /// realm 롤 목록. 페이지 경계는 호출자가 정한다([`Self::list_clients`]와 같은 계약).
    pub async fn list_roles(&self, first: i32, max: i32) -> Result<Vec<RoleRepresentation>> {
        let req = self
            .http
            .get(format!("{}/roles", self.realm_url()))
            .query(&[("first", first)])
            .query(&[("max", max)]);
        self.fetch(req).await
    }
    /// **현재 이름**으로 주소를 잡아 realm 롤을 갱신한다. `role.name`에 새 이름을 주면 rename이다.
    ///
    /// ⚠️ 경로(`name`)와 body(`role`)를 합치지 말 것 — 사유는 [`Self::update_realm`].
    pub async fn update_role(&self, name: &str, role: RoleRepresentation) -> Result<()> {
        let url = format!("{}/roles/{}", self.realm_url(), p(name));
        self.send(self.http.put(url).json(&role)).await?;
        Ok(())
    }
    /// name으로 realm 롤 삭제.
    pub async fn delete_role(&self, name: &str) -> Result<()> {
        let url = format!("{}/roles/{}", self.realm_url(), p(name));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    // ── Groups ──
    /// 그룹 생성. 생성된 id는 응답 `Location` 헤더의 마지막 조각 — 없으면 `None`.
    pub async fn create_group(&self, group: GroupRepresentation) -> Result<Option<String>> {
        let url = format!("{}/groups", self.realm_url());
        let resp = self.send(self.http.post(url).json(&group)).await?;
        Ok(created_id(&resp))
    }
    /// id로 그룹 단건 조회(부재 시 404→`AdminError::NotFound`).
    pub async fn get_group(&self, id: &str) -> Result<GroupRepresentation> {
        let url = format!("{}/groups/{}", self.realm_url(), p(id));
        self.fetch(self.http.get(url)).await
    }
    /// 그룹 목록(최상위). 페이지 경계는 호출자가 정한다([`Self::list_clients`]와 같은 계약).
    pub async fn list_groups(&self, first: i32, max: i32) -> Result<Vec<GroupRepresentation>> {
        let req = self
            .http
            .get(format!("{}/groups", self.realm_url()))
            .query(&[("first", first)])
            .query(&[("max", max)]);
        self.fetch(req).await
    }
    /// id로 주소를 잡아 그룹을 갱신한다. `group.name`에 새 이름을 주면 rename이다.
    ///
    /// ⚠️ 경로(`id`)와 body(`group`)를 합치지 말 것 — 사유는 [`Self::update_realm`].
    pub async fn update_group(&self, id: &str, group: GroupRepresentation) -> Result<()> {
        let url = format!("{}/groups/{}", self.realm_url(), p(id));
        self.send(self.http.put(url).json(&group)).await?;
        Ok(())
    }
    /// id로 그룹 삭제.
    pub async fn delete_group(&self, id: &str) -> Result<()> {
        let url = format!("{}/groups/{}", self.realm_url(), p(id));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    /// 탈출구 — 내부 `KeycloakAdmin`(모든 생성 메서드·representation 접근). 문서화된 은닉성 예외.
    /// ⚠️ crate 그대로다 — 그 메서드는 2xx 가 아닌 응답의 본문을 끝까지 읽어 `RawKeycloakError` 에 싣는다(상한 없음).
    pub fn raw(&self) -> &KeycloakAdmin<SdkTokenSupplier> {
        &self.admin
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{
        body_partial_json, method, path, query_param, query_param_is_missing,
    };
    use wiremock::{Mock, MockServer, ResponseTemplate};

    // 네트워크 경계는 omit이므로 CRUD는 Task 11 통합에서 검증. 오류 분류·본문 비우기·crate 와의 요청 동등성은
    // `tests/admin_response_body.rs`. 여기선 경로 조각 인코딩과 와이어에 실리는 쿼리·경로·body 를 본다.

    /// 경로 조각 인코딩은 crate 의 `encode_url_param` 과 같다 — 첫 줄은 crate 자신의 시험 벡터(26.6.2
    /// `src/rest/url_enc.rs` 의 `non_alphanumerics`)다.
    #[test]
    fn path_segments_are_encoded_like_the_crate() {
        assert_eq!(p("group / element -+?*"), "group%20%2F%20element%20-+%3F*");
        assert_eq!(p("a\"<>`#{}%b"), "a%22%3C%3E%60%23%7B%7D%25b");
        assert_eq!(p("\u{0}\t\u{7F}é"), "%00%09%7F%C3%A9");
        assert_eq!(
            p("!$&'()*+,-.:;=@[\\]^_|~AZaz09"),
            "!$&'()*+,-.:;=@[\\]^_|~AZaz09"
        );
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
    // wiremock은 매치되지 않은 요청에 404를 돌려준다 → 파사드가 그 상태로 Admin(NotFound)를 낸다.
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

    // ── update_*: 경로(주소)와 body(새 값)가 분리되는지 ──
    //
    // Keycloak의 rename은 `PUT /{현재 주소}` + body에 **새** 이름이다. 경로를 body에서 만들면
    // rename이 조용한 no-op이 된다(2xx인데 아무것도 안 바뀜). 아래 넷은 전부 body의 이름을
    // 경로와 **다르게** 두어, 둘을 합치는 구현에서는 경로가 어긋나 wiremock이 404를 돌려주고
    // 파사드가 그 상태로 Err를 낸다 — 즉 이 어서션은 합침을 구조적으로 잡는다.
    // (자매 Go SDK는 gocloak이 경로를 body에서 만들어 realms.Update만 raw REST로 우회해야 했다.)

    #[tokio::test]
    async fn update_realm_addresses_by_current_name_not_by_the_body() {
        let server = MockServer::start().await;
        Mock::given(method("PUT"))
            .and(path("/admin/realms/it-realm")) // 현재 이름
            .and(body_partial_json(serde_json::json!({"realm": "renamed"}))) // 새 이름은 body
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;

        admin_against(&server)
            .update_realm(
                "it-realm",
                RealmRepresentation {
                    realm: Some("renamed".into()),
                    ..Default::default()
                },
            )
            .await
            .expect("경로는 현재 이름, body는 새 이름이어야 한다");
    }

    #[tokio::test]
    async fn update_role_addresses_by_current_name_not_by_the_body() {
        let server = MockServer::start().await;
        Mock::given(method("PUT"))
            .and(path("/admin/realms/it-realm/roles/old-role"))
            .and(body_partial_json(serde_json::json!({"name": "new-role"})))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;

        admin_against(&server)
            .update_role(
                "old-role",
                RoleRepresentation {
                    name: Some("new-role".into()),
                    ..Default::default()
                },
            )
            .await
            .expect("경로는 현재 이름, body는 새 이름이어야 한다");
    }

    #[tokio::test]
    async fn update_group_addresses_by_id_not_by_the_body() {
        let server = MockServer::start().await;
        Mock::given(method("PUT"))
            .and(path("/admin/realms/it-realm/groups/g-1"))
            .and(body_partial_json(serde_json::json!({"name": "renamed"})))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;

        admin_against(&server)
            .update_group(
                "g-1",
                GroupRepresentation {
                    name: Some("renamed".into()),
                    ..Default::default()
                },
            )
            .await
            .expect("경로는 id, body는 새 이름이어야 한다");
    }

    #[tokio::test]
    async fn update_client_addresses_by_uuid_not_by_the_body() {
        let server = MockServer::start().await;
        Mock::given(method("PUT"))
            .and(path("/admin/realms/it-realm/clients/c-uuid"))
            .and(body_partial_json(
                serde_json::json!({"clientId": "renamed"}),
            ))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;

        admin_against(&server)
            .update_client(
                "c-uuid",
                ClientRepresentation {
                    client_id: Some("renamed".into()),
                    ..Default::default()
                },
            )
            .await
            .expect("경로는 uuid, body는 새 clientId여야 한다");
    }

    #[tokio::test]
    async fn update_user_addresses_by_id_and_sends_the_sparse_body() {
        let server = MockServer::start().await;
        Mock::given(method("PUT"))
            .and(path("/admin/realms/it-realm/users/u-1"))
            .and(body_partial_json(serde_json::json!({"firstName": "Ada"})))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;

        admin_against(&server)
            .update_user(
                "u-1",
                UserRepresentation {
                    first_name: Some("Ada".into()),
                    ..Default::default()
                },
            )
            .await
            .expect("경로는 id, body는 부분 representation이어야 한다");
    }

    // ── list_*: 호출자의 페이지 경계가 와이어에 실리는지 ──
    // search_users와 같은 이유로 `max`는 Option이 아니다 — 상한은 항상 호출부에 보여야 한다.

    #[tokio::test]
    async fn list_realms_hits_the_global_realms_endpoint() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms")) // realm-scoped가 아니라 전역
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!([{"realm":"it-realm"}])),
            )
            .expect(1)
            .mount(&server)
            .await;

        let realms = admin_against(&server)
            .list_realms()
            .await
            .expect("GET /admin/realms를 쳐야 한다");
        assert_eq!(realms.len(), 1);
    }

    #[tokio::test]
    async fn list_clients_puts_caller_pagination_on_the_wire() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/clients"))
            .and(query_param("first", "10"))
            .and(query_param("max", "5"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!([{"id":"c1"}])),
            )
            .expect(1)
            .mount(&server)
            .await;

        assert_eq!(
            admin_against(&server)
                .list_clients(10, 5)
                .await
                .expect("first/max는 호출자 값이어야 한다")
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn list_roles_puts_caller_pagination_on_the_wire() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/roles"))
            .and(query_param("first", "10"))
            .and(query_param("max", "5"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!([{"name":"r1"}])),
            )
            .expect(1)
            .mount(&server)
            .await;

        assert_eq!(
            admin_against(&server)
                .list_roles(10, 5)
                .await
                .expect("first/max는 호출자 값이어야 한다")
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn list_groups_puts_caller_pagination_on_the_wire() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/admin/realms/it-realm/groups"))
            .and(query_param("first", "10"))
            .and(query_param("max", "5"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!([{"id":"g1"}])),
            )
            .expect(1)
            .mount(&server)
            .await;

        assert_eq!(
            admin_against(&server)
                .list_groups(10, 5)
                .await
                .expect("first/max는 호출자 값이어야 한다")
                .len(),
            1
        );
    }
}
