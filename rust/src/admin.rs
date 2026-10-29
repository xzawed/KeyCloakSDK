//! AdminClient — the admin REST facade. The SDK sends the requests itself and borrows only the representation types
//! from the `keycloak` crate.
//!
//! ⚠️ **The facade does not call the crate's generated methods** — on a non-2xx response those read the whole body
//! with `text()` in `error_check` (a single 64 MiB error body makes the server write all of it and allocation grows to
//! several times that — measured in `tests/admin_response_body.rs`). The facade picks its errors by status alone, so
//! that body is never used. So the facade itself sends **the same request** as the crate (path-segment encoding [`p`] ·
//! the query and its order · Bearer · JSON body) and drains an error body only up to the cap ([`reject`]). That it is
//! the same request is checked on the wire by that file's `the_facade_sends_what_the_crate_sends` against `raw()`'s
//! crate methods — when upgrading the crate, start there.
//!
//! `admin` does not know `auth` directly — the only glue is `TokenProvider`. Underlying errors (`reqwest::Error`) become
//! our `KeycloakError` at the boundary and do not leak into the public API. The `&KeycloakAdmin` that `raw()` returns
//! and the representation types are documented hiding exceptions (in every SDK the admin representations are
//! leaked-by-design). ⚠️ `raw()` is the crate as-is, so its error bodies **are still read to the end** — reqwest 0.12
//! has no place to intercept the response.
//! Coverage omit (network boundary) — CRUD is verified by the Task 11 integration test, and the request shape by the
//! unit tests below and `tests/admin_response_body.rs`.
use crate::config::KeycloakConfig;
use crate::error::{AdminError, KeycloakError, Result};
use crate::jwks::TOKEN_RESPONSE_MAX_BYTES;
use crate::token_provider::{TokenProvider, sendable_bearer};
use async_trait::async_trait;
use keycloak::prelude::reqwest;
use keycloak::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak::{KeycloakAdmin, KeycloakError as KcError, KeycloakTokenSupplier};
use serde::de::DeserializeOwned;
use std::sync::Arc;

/// Adapter from our `TokenProvider` to the keycloak crate's `KeycloakTokenSupplier` (`#[async_trait]`) — used by the
/// crate behind `raw()`.
/// The only admin↔auth glue (admin does not reference AuthClient directly). The facade calls `TokenProvider` directly.
/// What the crate is given is the value `sendable_bearer` returned — an unsendable token fails before the crate builds
/// the request.
pub struct SdkTokenSupplier {
    inner: Arc<dyn TokenProvider>,
}

#[async_trait]
impl KeycloakTokenSupplier for SdkTokenSupplier {
    async fn get(&self, _url: &str) -> std::result::Result<String, KcError> {
        // 우리 오류를 keycloak::KeycloakError로 변환(어댑터 경계, 우리→그들).
        // 토큰 획득 실패는 인증 문제이므로 401 HttpFailure로 표면화(파사드도 같은 401 이다 — `AdminClient::send`).
        // 보낼 수 없는 Bearer 도 같은 모양이다 — crate 의 헤더 검사가 내던 `ReqwestFailure` 는 공개 생성자가 없다.
        let failure = |e: KeycloakError| KcError::HttpFailure {
            status: 401,
            body: None,
            text: format!("token supplier: {e}"),
        };
        let token = self.inner.access_token().await.map_err(failure)?;
        sendable_bearer(&token)
            .map(str::to_string)
            .ok_or_else(|| failure(unsendable()))
    }
}

/// 보낼 수 없는 Bearer — 요청을 짓기 전에 거부한다([`sendable_bearer`]). 파사드의 오류는 전에 reqwest 의 헤더 검사가
/// CR·LF·NUL·DEL·VT 에서 내던 것과 같은 `Transport`(`admin request: …`)이고, 토큰을 담지 않는다.
fn unsendable() -> KeycloakError {
    KeycloakError::Transport(
        "admin request: access token is not an RFC 6750 bearer token (b64token)".into(),
    )
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
/// ⚠️ reqwest 가 압축을 풀면(이 crate 는 그 기능을 켜지 않는다 — 소비자 빌드의 기능 통합) 푼 본문의 길이를 미리 알 수
/// 없어 `content_length()` 가 `None` 이다(`size_hint` 가 정확하지 않다) — 그 본문은 푼 바이트로 상한까지 비우고, 그
/// 안에서 멈추면 기한까지 기다린다.
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
    /// Builds the facade from the shared `http` (with the TLS, timeout and SSRF policies injected) and the
    /// `TokenProvider`, and assembles `raw()`'s `KeycloakAdmin` from the same two.
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
    /// (`tests/token_response_cap.rs` 의 `rejected_over_cap`). Bearer 는 [`sendable_bearer`] 가 돌려준 값이고, 보낼 수
    /// 없는 토큰이면 요청 없이 [`unsendable`] 이다(`tests/bearer_grammar.rs`).
    async fn send(&self, req: reqwest::RequestBuilder) -> Result<reqwest::Response> {
        let token = self
            .token_provider
            .access_token()
            .await
            .map_err(|_| KeycloakError::from_admin_status(401))?;
        let bearer = sendable_bearer(&token).ok_or_else(unsendable)?;
        let resp = req.bearer_auth(bearer).send().await.map_err(transport)?;
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
    /// Creates a user. The created id is the last segment of the response's `Location` header — `None` when absent. The
    /// response body is not read.
    pub async fn create_user(&self, user: UserRepresentation) -> Result<Option<String>> {
        let url = format!("{}/users", self.realm_url());
        let resp = self.send(self.http.post(url).json(&user)).await?;
        Ok(created_id(&resp))
    }
    /// Gets a single user by id (404→`AdminError::NotFound` when absent).
    pub async fn get_user(&self, user_id: &str) -> Result<UserRepresentation> {
        let url = format!("{}/users/{}", self.realm_url(), p(user_id));
        self.fetch(self.http.get(url)).await
    }
    /// Searches users (substring match — Keycloak's default matching). **The caller sets the page bounds.**
    ///
    /// - `username`: `None` walks the whole realm page by page with no filter (= users.list).
    ///   `Some(u)` finds users whose username **contains** `u` (for an exact match, [`Self::find_user_by_username`]).
    /// - `first`: 0-based page offset. Keycloak ignores a negative value, treating it as "no offset".
    /// - `max`: the maximum number of results on this page. **A negative value (`-1`) means "no server-side cap"**.
    ///
    /// ⚠️ `max` is deliberately not an `Option` — when `max` is absent, Keycloak silently applies
    /// `Constants.DEFAULT_MAX_RESULTS` (**100**). If it could be omitted, a call that reads as "no cap" would actually
    /// be truncated at 100. The cap must always be a value **visible** at the call site.
    ///
    /// ⚠️ If the returned length equals `max`, **there may be a next page** (the total count is not in this response).
    /// To walk to the end, keep increasing `first` by `max` until the length is < `max`.
    ///
    /// The query is sent in the same order as the crate's `realm_users_get` (`exact`·`first`·`max`·`username` — the
    /// unused ones are not sent). `exact` not sent = Keycloak's default (substring match).
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
    /// Gets a single user by **exact** username match (`exact=true`). `Ok(None)` when there is none.
    ///
    /// There are no pagination arguments because truncation is **structurally impossible** — Keycloak enforces
    /// username uniqueness within a realm, so an `exact=true` result is either 0 or 1 entries. It still asks for
    /// `max=2`: with `max=1`, "1 result returned" cannot tell whether there really is 1 or the result was truncated. If 2
    /// arrive, that invariant is broken, so instead of silently picking the first one it surfaces
    /// [`AdminError::Conflict`].
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
    /// Updates a user by id. `user` may be a **partial (sparse) representation**.
    ///
    /// ⚠️ The path (`user_id`) and the body (`user`) are separate — do not merge them (see `update_realm` below).
    pub async fn update_user(&self, user_id: &str, user: UserRepresentation) -> Result<()> {
        let url = format!("{}/users/{}", self.realm_url(), p(user_id));
        self.send(self.http.put(url).json(&user)).await?;
        Ok(())
    }
    /// Deletes a user by id.
    pub async fn delete_user(&self, user_id: &str) -> Result<()> {
        let url = format!("{}/users/{}", self.realm_url(), p(user_id));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    // ── Clients ──
    /// Creates a client. The created uuid is the last segment of the response's `Location` header — `None` when absent.
    pub async fn create_client(&self, client: ClientRepresentation) -> Result<Option<String>> {
        let url = format!("{}/clients", self.realm_url());
        let resp = self.send(self.http.post(url).json(&client)).await?;
        Ok(created_id(&resp))
    }
    /// Gets a single client by uuid (404→`AdminError::NotFound` when absent).
    pub async fn get_client(&self, client_uuid: &str) -> Result<ClientRepresentation> {
        let url = format!("{}/clients/{}", self.realm_url(), p(client_uuid));
        self.fetch(self.http.get(url)).await
    }
    /// Lists clients. **The caller sets the page bounds** (`max` is not an `Option` for the same reason as in
    /// [`Self::search_users`] — the cap must always be a value visible at the call site).
    ///
    /// If the returned length equals `max`, there may be a next page (the total count is not in the response).
    /// No `clientId` filter is sent (for a single exact clientId match, use `raw()`).
    pub async fn list_clients(&self, first: i32, max: i32) -> Result<Vec<ClientRepresentation>> {
        let req = self
            .http
            .get(format!("{}/clients", self.realm_url()))
            .query(&[("first", first)])
            .query(&[("max", max)]);
        self.fetch(req).await
    }
    /// Updates a client, addressed by uuid. A new value in `client.client_id` is a rename.
    ///
    /// ⚠️ The path (`client_uuid`) and the body (`client`) are separate.
    pub async fn update_client(
        &self,
        client_uuid: &str,
        client: ClientRepresentation,
    ) -> Result<()> {
        let url = format!("{}/clients/{}", self.realm_url(), p(client_uuid));
        self.send(self.http.put(url).json(&client)).await?;
        Ok(())
    }
    /// Deletes a client by uuid.
    pub async fn delete_client(&self, client_uuid: &str) -> Result<()> {
        let url = format!("{}/clients/{}", self.realm_url(), p(client_uuid));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    // ── Realms ──
    /// Gets the configured realm's top-level representation (nested Users/Clients not included).
    pub async fn get_realm(&self) -> Result<RealmRepresentation> {
        self.fetch(self.http.get(self.realm_url())).await
    }
    /// Creates a new realm (`POST /admin/realms`).
    /// ⚠️ This operation requires **master-realm permissions** — with a realm service account it is 403 (Forbidden).
    /// (It is a global bootstrap permission, not a realm-scoped operation, so it is master-only on every Keycloak.)
    /// The typed method exists on the facade regardless of runtime permissions.
    pub async fn create_realm(&self, realm: RealmRepresentation) -> Result<()> {
        let url = format!("{}/admin/realms", self.url);
        self.send(self.http.post(url).json(&realm)).await?;
        Ok(())
    }
    /// Lists the realms the calling service account can see (`GET /admin/realms` — global, not realm-scoped).
    /// Usually only its own realm comes back. This endpoint has no pagination parameters.
    pub async fn list_realms(&self) -> Result<Vec<RealmRepresentation>> {
        self.fetch(self.http.get(format!("{}/admin/realms", self.url)))
            .await
    }
    /// Updates a realm, addressed by its **current name** (`PUT /admin/realms/{name}`).
    /// A new name in `realm.realm` is a rename.
    ///
    /// ⚠️ **Do not merge the path (`name`) and the body (`realm`).** A Keycloak rename is
    /// "PUT the new value at the current address", so building the path from the representation points the rename
    /// request at the new name and makes it a **silent no-op** (the response is 2xx, yet nothing changes).
    /// In the sibling Go SDK, gocloak behaves exactly that way, so that SDK had to route this one spot around it with raw
    /// REST — here the path is built from `name` and the body from `realm`, separately (as the crate's
    /// `realm_put(realm, body)` does).
    pub async fn update_realm(&self, name: &str, realm: RealmRepresentation) -> Result<()> {
        let url = format!("{}/admin/realms/{}", self.url, p(name));
        self.send(self.http.put(url).json(&realm)).await?;
        Ok(())
    }
    /// Deletes a realm (`DELETE /admin/realms/{realm}`).
    /// ⚠️ Like `create_realm`, this requires **master-realm permissions** (403 with a realm service account).
    pub async fn delete_realm(&self, name: &str) -> Result<()> {
        let url = format!("{}/admin/realms/{}", self.url, p(name));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    // ── Roles (realm-level) ──
    /// Creates a realm role.
    pub async fn create_role(&self, role: RoleRepresentation) -> Result<()> {
        let url = format!("{}/roles", self.realm_url());
        self.send(self.http.post(url).json(&role)).await?;
        Ok(())
    }
    /// Gets a single realm role by name (404→`AdminError::NotFound` when absent).
    pub async fn get_role(&self, name: &str) -> Result<RoleRepresentation> {
        let url = format!("{}/roles/{}", self.realm_url(), p(name));
        self.fetch(self.http.get(url)).await
    }
    /// Lists realm roles. The caller sets the page bounds (the same contract as [`Self::list_clients`]).
    pub async fn list_roles(&self, first: i32, max: i32) -> Result<Vec<RoleRepresentation>> {
        let req = self
            .http
            .get(format!("{}/roles", self.realm_url()))
            .query(&[("first", first)])
            .query(&[("max", max)]);
        self.fetch(req).await
    }
    /// Updates a realm role, addressed by its **current name**. A new name in `role.name` is a rename.
    ///
    /// ⚠️ Do not merge the path (`name`) and the body (`role`) — see [`Self::update_realm`] for why.
    pub async fn update_role(&self, name: &str, role: RoleRepresentation) -> Result<()> {
        let url = format!("{}/roles/{}", self.realm_url(), p(name));
        self.send(self.http.put(url).json(&role)).await?;
        Ok(())
    }
    /// Deletes a realm role by name.
    pub async fn delete_role(&self, name: &str) -> Result<()> {
        let url = format!("{}/roles/{}", self.realm_url(), p(name));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    // ── Groups ──
    /// Creates a group. The created id is the last segment of the response's `Location` header — `None` when absent.
    pub async fn create_group(&self, group: GroupRepresentation) -> Result<Option<String>> {
        let url = format!("{}/groups", self.realm_url());
        let resp = self.send(self.http.post(url).json(&group)).await?;
        Ok(created_id(&resp))
    }
    /// Gets a single group by id (404→`AdminError::NotFound` when absent).
    pub async fn get_group(&self, id: &str) -> Result<GroupRepresentation> {
        let url = format!("{}/groups/{}", self.realm_url(), p(id));
        self.fetch(self.http.get(url)).await
    }
    /// Lists groups (top level). The caller sets the page bounds (the same contract as [`Self::list_clients`]).
    pub async fn list_groups(&self, first: i32, max: i32) -> Result<Vec<GroupRepresentation>> {
        let req = self
            .http
            .get(format!("{}/groups", self.realm_url()))
            .query(&[("first", first)])
            .query(&[("max", max)]);
        self.fetch(req).await
    }
    /// Updates a group, addressed by id. A new name in `group.name` is a rename.
    ///
    /// ⚠️ Do not merge the path (`id`) and the body (`group`) — see [`Self::update_realm`] for why.
    pub async fn update_group(&self, id: &str, group: GroupRepresentation) -> Result<()> {
        let url = format!("{}/groups/{}", self.realm_url(), p(id));
        self.send(self.http.put(url).json(&group)).await?;
        Ok(())
    }
    /// Deletes a group by id.
    pub async fn delete_group(&self, id: &str) -> Result<()> {
        let url = format!("{}/groups/{}", self.realm_url(), p(id));
        self.send(self.http.delete(url)).await?;
        Ok(())
    }

    /// Escape hatch — the inner `KeycloakAdmin` (every generated method, representation access). A documented hiding
    /// exception.
    /// ⚠️ It is the crate as-is — its methods read the body of a non-2xx response to the end and carry it in
    /// `RawKeycloakError` (no cap).
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
