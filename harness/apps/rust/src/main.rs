//! 하네스 계약 v2 샘플 앱 — axum + keycloak-sdk(Rust). app-ruby(Task 1.3)와 동일 계약 표면.
//! SDK 소스는 수정하지 않는다(client.auth()/client.admin()만 소비, .raw() 미사용).
use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use keycloak::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak_sdk::{AdminError, KeycloakClient, KeycloakConfig, KeycloakError};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Clone)]
struct AppState {
    kc: Arc<KeycloakClient>,
    // ROPC(password grant)로 얻은 refresh_token의 서버측 보관 — 단일 프로세스 데모 하네스 전용
    // (SESS 상당, ruby app.rb와 동형). /refresh·/logout이 이 값을 소비한다.
    refresh: Arc<Mutex<Option<String>>>,
    // ROPC 전용 reqwest 클라이언트 — SDK 표면에 password grant가 없어(SDK 표면 불변 원칙)
    // 앱이 Keycloak 토큰 엔드포인트로 직접 POST한다(8개 앱 동일 패턴).
    ropc_http: reqwest::Client,
    token_url: String,
    client_id: String,
    client_secret: String,
}

fn err_json(code: StatusCode, msg: impl std::fmt::Display) -> Response {
    (code, Json(json!({ "error": msg.to_string() }))).into_response()
}

/// SDK `KeycloakError` → HTTP 상태(계약 오류 매핑 규약). admin 호출에서만 사용.
fn map_admin(e: &KeycloakError) -> StatusCode {
    match e {
        KeycloakError::Admin(AdminError::NotFound) => StatusCode::NOT_FOUND,
        KeycloakError::Admin(AdminError::Conflict) => StatusCode::CONFLICT,
        KeycloakError::Admin(AdminError::Forbidden) => StatusCode::FORBIDDEN,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

/// 요청 바디를 관대하게 JSON으로 파싱(ruby `body_json`과 동형 — 실패 시 빈 객체).
fn body_json(bytes: &Bytes) -> Value {
    serde_json::from_slice(bytes).unwrap_or_else(|_| json!({}))
}

async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, Json(json!({ "status": "ok" })))
}

async fn token(State(state): State<AppState>) -> Response {
    match state.kc.auth().client_credentials_token().await {
        Ok(t) => (
            StatusCode::OK,
            Json(json!({ "tokenType": t.token_type, "expiresIn": t.expires_in })),
        )
            .into_response(),
        Err(e) => err_json(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

/// ROPC(password grant) — 앱-로컬 구현(주석 (b) 경로). 성공 시 refresh_token을 서버측에 보관한다.
async fn token_password(State(state): State<AppState>, body: Bytes) -> Response {
    let v = body_json(&body);
    let username = v.get("username").and_then(|s| s.as_str()).unwrap_or("");
    let password = v.get("password").and_then(|s| s.as_str()).unwrap_or("");
    let params = [
        ("grant_type", "password"),
        ("client_id", state.client_id.as_str()),
        ("client_secret", state.client_secret.as_str()),
        ("username", username),
        ("password", password),
    ];
    let resp = state.ropc_http.post(&state.token_url).form(&params).send().await;
    match resp {
        Ok(r) if r.status().is_success() => match r.json::<Value>().await {
            Ok(body) => {
                let refresh_token = body
                    .get("refresh_token")
                    .and_then(|v| v.as_str())
                    .map(str::to_string);
                let has_refresh = refresh_token.is_some();
                *state.refresh.lock().await = refresh_token;
                (
                    StatusCode::OK,
                    Json(json!({
                        "tokenType": body.get("token_type").and_then(|v| v.as_str()).unwrap_or("Bearer"),
                        "expiresIn": body.get("expires_in").and_then(|v| v.as_i64()).unwrap_or(0),
                        "hasRefresh": has_refresh,
                    })),
                )
                    .into_response()
            }
            Err(e) => err_json(StatusCode::UNAUTHORIZED, format!("ROPC response parse error: {e}")),
        },
        Ok(r) => err_json(
            StatusCode::UNAUTHORIZED,
            format!("ROPC(password) grant failed: HTTP {}", r.status()),
        ),
        Err(e) => err_json(StatusCode::UNAUTHORIZED, format!("ROPC transport error: {e}")),
    }
}

async fn refresh(State(state): State<AppState>) -> Response {
    let current = state.refresh.lock().await.clone();
    let Some(rt) = current else {
        return err_json(StatusCode::UNAUTHORIZED, "no refresh token available (call /token/password first)");
    };
    match state.kc.auth().refresh(&rt).await {
        Ok(t) => {
            if let Some(new_rt) = &t.refresh_token {
                *state.refresh.lock().await = Some(new_rt.clone());
            }
            (
                StatusCode::OK,
                Json(json!({ "tokenType": t.token_type, "expiresIn": t.expires_in })),
            )
                .into_response()
        }
        Err(e) => err_json(StatusCode::UNAUTHORIZED, e),
    }
}

async fn logout(State(state): State<AppState>) -> Response {
    let current = state.refresh.lock().await.clone().unwrap_or_default();
    match state.kc.auth().logout(&current).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => err_json(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

/// 오프라인 URL 조립만(브라우저 왕복·code 교환 없음).
/// ⚠️ Rust SDK의 `create_authorization_request()`는 인자를 받지 않는다 — redirect_uri는
/// `KeycloakConfig` 구성 시점에 고정된다(Ruby/Node/Go는 호출별 override 가능 — SDK 표면 차이,
/// task-1.4-report.md 참고). 계약 호환을 위해 쿼리파라미터는 받되 사용하지 않는다.
async fn authz_url(State(state): State<AppState>, Query(_params): Query<HashMap<String, String>>) -> Response {
    let r = state.kc.auth().create_authorization_request();
    (StatusCode::OK, Json(json!({ "url": r.url, "state": r.state }))).into_response()
}

async fn validate(State(state): State<AppState>, body: Bytes) -> Response {
    let v = body_json(&body);
    let token = v.get("token").and_then(|s| s.as_str()).unwrap_or("");
    match state.kc.auth().validate(token).await {
        Ok(vt) => (
            StatusCode::OK,
            Json(json!({
                "subject": vt.subject,
                "audience": vt.audience,
                "issuer": vt.issuer,
                "expiresAt": vt.expires_at,
            })),
        )
            .into_response(),
        Err(e) => err_json(StatusCode::UNAUTHORIZED, e),
    }
}

async fn introspect(State(state): State<AppState>, body: Bytes) -> Response {
    let v = body_json(&body);
    let token = v.get("token").and_then(|s| s.as_str()).unwrap_or("");
    match state.kc.auth().introspect(token).await {
        Ok(r) => (
            StatusCode::OK,
            Json(json!({ "active": r.active, "username": r.username, "clientId": r.client_id })),
        )
            .into_response(),
        Err(e) => err_json(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

// ---- admin: users ----

async fn create_user(State(state): State<AppState>, body: Bytes) -> Response {
    let v = body_json(&body);
    let username = v.get("username").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let email = v.get("email").and_then(|s| s.as_str()).map(str::to_string);
    let rep = UserRepresentation {
        username: Some(username.clone()),
        email,
        enabled: Some(true),
        ..Default::default()
    };
    match state.kc.admin().create_user(rep).await {
        Ok(Some(id)) => (StatusCode::CREATED, Json(json!({ "id": id }))).into_response(),
        // Location 헤더 부재 — username으로 후속 조회(fschmtt/PHP 자매 SDK와 동형 폴백).
        Ok(None) => match state.kc.admin().search_users(&username).await {
            Ok(found) if !found.is_empty() => {
                let id = found[0].id.clone().unwrap_or_default();
                (StatusCode::CREATED, Json(json!({ "id": id }))).into_response()
            }
            Ok(_) => err_json(StatusCode::INTERNAL_SERVER_ERROR, "user created but id not resolvable"),
            Err(e) => err_json(map_admin(&e), e),
        },
        Err(e) => err_json(map_admin(&e), e),
    }
}

async fn get_user(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.kc.admin().get_user(&id).await {
        Ok(u) => (StatusCode::OK, Json(json!({ "id": u.id, "username": u.username }))).into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

/// ⚠️ Rust SDK의 admin 표면에는 list-all이 없다 — `search_users(username)`만 존재(exact-match 전용,
/// username 필수). username 쿼리파라미터가 없으면 빈 배열로 응답한다(SDK 표면 불변 원칙 —
/// k6 드라이버는 이 목록 엔드포인트를 실제로 호출하지 않는다, CONTRACT.md 참고).
async fn list_users(State(state): State<AppState>, Query(params): Query<HashMap<String, String>>) -> Response {
    let username = params.get("username").map(String::as_str).unwrap_or("");
    if username.is_empty() {
        return (StatusCode::OK, Json(Value::Array(vec![]))).into_response();
    }
    match state.kc.admin().search_users(username).await {
        Ok(users) => {
            let out: Vec<Value> = users
                .iter()
                .map(|u| json!({ "id": u.id, "username": u.username }))
                .collect();
            (StatusCode::OK, Json(Value::Array(out))).into_response()
        }
        Err(e) => err_json(map_admin(&e), e),
    }
}

async fn delete_user(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.kc.admin().delete_user(&id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

// ---- admin: clients ----

async fn create_client(State(state): State<AppState>, body: Bytes) -> Response {
    let v = body_json(&body);
    let client_id = v.get("clientId").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let rep = ClientRepresentation {
        client_id: Some(client_id),
        enabled: Some(true),
        ..Default::default()
    };
    match state.kc.admin().create_client(rep).await {
        Ok(Some(id)) => (StatusCode::CREATED, Json(json!({ "id": id }))).into_response(),
        Ok(None) => err_json(StatusCode::INTERNAL_SERVER_ERROR, "client created but id not resolvable"),
        Err(e) => err_json(map_admin(&e), e),
    }
}

async fn get_client(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.kc.admin().get_client(&id).await {
        Ok(c) => (StatusCode::OK, Json(json!({ "id": c.id, "clientId": c.client_id }))).into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

async fn delete_client(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.kc.admin().delete_client(&id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

// ---- admin: roles (realm role — client role 아님·name 키) ----

async fn create_role(State(state): State<AppState>, body: Bytes) -> Response {
    let v = body_json(&body);
    let name = v.get("name").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let rep = RoleRepresentation {
        name: Some(name.clone()),
        ..Default::default()
    };
    match state.kc.admin().create_role(rep).await {
        Ok(()) => (StatusCode::CREATED, Json(json!({ "name": name }))).into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

async fn get_role(State(state): State<AppState>, Path(name): Path<String>) -> Response {
    match state.kc.admin().get_role(&name).await {
        Ok(r) => (StatusCode::OK, Json(json!({ "name": r.name }))).into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

async fn delete_role(State(state): State<AppState>, Path(name): Path<String>) -> Response {
    match state.kc.admin().delete_role(&name).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

// ---- admin: groups ----

async fn create_group(State(state): State<AppState>, body: Bytes) -> Response {
    let v = body_json(&body);
    let name = v.get("name").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let rep = GroupRepresentation {
        name: Some(name),
        ..Default::default()
    };
    match state.kc.admin().create_group(rep).await {
        Ok(Some(id)) => (StatusCode::CREATED, Json(json!({ "id": id }))).into_response(),
        Ok(None) => err_json(StatusCode::INTERNAL_SERVER_ERROR, "group created but id not resolvable"),
        Err(e) => err_json(map_admin(&e), e),
    }
}

async fn get_group(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.kc.admin().get_group(&id).await {
        Ok(g) => (StatusCode::OK, Json(json!({ "id": g.id, "name": g.name }))).into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

async fn delete_group(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.kc.admin().delete_group(&id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

// ---- admin: realms (master 전용 — 하네스는 realm SA라 항상 403, CONTRACT.md 참고) ----

async fn create_realm(State(state): State<AppState>, body: Bytes) -> Response {
    let v = body_json(&body);
    let realm = v.get("realm").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let rep = RealmRepresentation {
        realm: Some(realm.clone()),
        enabled: Some(true),
        ..Default::default()
    };
    match state.kc.admin().create_realm(rep).await {
        Ok(()) => (StatusCode::CREATED, Json(json!({ "realm": realm }))).into_response(),
        Err(e) => err_json(map_admin(&e), e),
    }
}

#[tokio::main]
async fn main() {
    let server_url = std::env::var("KC_SERVER_URL").expect("KC_SERVER_URL is required");
    let realm = std::env::var("KC_REALM").expect("KC_REALM is required");
    let client_id = std::env::var("KC_CLIENT_ID").expect("KC_CLIENT_ID is required");
    let client_secret = std::env::var("KC_CLIENT_SECRET").expect("KC_CLIENT_SECRET is required");
    let port: u16 = std::env::var("APP_PORT")
        .unwrap_or_else(|_| "8090".to_string())
        .parse()
        .expect("APP_PORT must be a valid port number");

    let cfg = KeycloakConfig::new(server_url.clone(), realm.clone(), client_id.clone())
        .expect("valid KeycloakConfig")
        .with_client_secret(client_secret.clone())
        .with_redirect_uri("http://x/cb");

    let kc = Arc::new(KeycloakClient::new(cfg).expect("KeycloakClient must build"));

    let ropc_http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("reqwest client must build");

    let token_url = format!("{server_url}/realms/{realm}/protocol/openid-connect/token");

    let state = AppState {
        kc,
        refresh: Arc::new(Mutex::new(None)),
        ropc_http,
        token_url,
        client_id,
        client_secret,
    };

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/token", post(token))
        .route("/token/password", post(token_password))
        .route("/refresh", post(refresh))
        .route("/logout", post(logout))
        .route("/authz-url", get(authz_url))
        .route("/validate", post(validate))
        .route("/introspect", post(introspect))
        .route("/admin/users", post(create_user).get(list_users))
        .route("/admin/users/{id}", get(get_user).delete(delete_user))
        .route("/admin/clients", post(create_client))
        .route("/admin/clients/{id}", get(get_client).delete(delete_client))
        .route("/admin/roles", post(create_role))
        .route("/admin/roles/{name}", get(get_role).delete(delete_role))
        .route("/admin/groups", post(create_group))
        .route("/admin/groups/{id}", get(get_group).delete(delete_group))
        .route("/admin/realms", post(create_realm))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .expect("bind APP_PORT");
    axum::serve(listener, app).await.expect("server must run");
}
