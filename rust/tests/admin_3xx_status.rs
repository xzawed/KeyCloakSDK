//! Location 없는 3xx 는 admin 파사드 호출의 성공이 아니다 — 등록부 `go-admin-3xx-read-as-success` 의 부류 재스캔(rust).
//!
//! 그 항목에서 go 는 파사드 호출 25 중 24 가 Location 없는 3xx 에 영값을 돌려줬고, php 는 302 에 User 를 돌려줬다. rust 의
//! 3xx 는 `admin_response_body.rs` 의 오류 본문 열(64 MiB 공백 본문 · 호출 다섯)에서만 쟀다 — 성공 본문 모양이 아니었다.
//!
//! 계약: 파사드 호출 스물다섯(users · clients · realms · roles · groups × 생성 · 단건 · 목록/검색 · 갱신 · 삭제 — 통합 admin
//! 표면 스위트가 도는 그 스물다섯) 각각이 300 · 302(Location 없음) · 399 에 **그 호출의 성공 본문 모양인 JSON**(목록 · 검색은
//! 배열, 나머지는 객체)을 받으면 `KeycloakError::Admin(AdminError::Other { status })` — 그 상태 그대로 — 로 실패한다. 값 ·
//! `None` · 빈 목록 · id 를 돌려주면 그 칸은 실패다. 다른 갈래(`Transport` · `Auth` · 404 의 `NotFound` …)도 실패다 — 본문
//! 모양이 어긋나 난 해석 오류(`Transport("admin request: …")`)를 「오류」로 받으면 상태를 안 보고도 초록이 된다.
//!
//! 토큰은 SDK 기본 경로(`KeycloakClient::new` 의 `ClientCredentialsTokenProvider`)가 wiremock 의 토큰 엔드포인트에서 정상으로
//! 받는다. 칸마다 admin 요청이 정확히 하나 나갔는지도 본다 — 요청 없이 난 오류는 그 응답의 판정이 아니다. 전제(서버의 3xx 에
//! `Location` 이 없다)는 리다이렉트를 따르지 않는 클라이언트로 상태마다 한 번 잰다. `TC_PRINT=1` 이면 상태마다 통과 수와 칸마다의
//! 결과를 찍는다.

use keycloak_sdk::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak_sdk::{
    AdminClient, AdminError, KeycloakClient, KeycloakConfig, KeycloakError, reqwest,
};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

const STATUSES: [u16; 3] = [300, 302, 399];

/// 파사드 호출 스물다섯.
#[derive(Clone, Copy, Debug)]
enum Op {
    CreateUser,
    GetUser,
    SearchUsers,
    UpdateUser,
    DeleteUser,
    CreateClient,
    GetClient,
    ListClients,
    UpdateClient,
    DeleteClient,
    CreateRealm,
    GetRealm,
    ListRealms,
    UpdateRealm,
    DeleteRealm,
    CreateRole,
    GetRole,
    ListRoles,
    UpdateRole,
    DeleteRole,
    CreateGroup,
    GetGroup,
    ListGroups,
    UpdateGroup,
    DeleteGroup,
}

const OPS: [Op; 25] = [
    Op::CreateUser,
    Op::GetUser,
    Op::SearchUsers,
    Op::UpdateUser,
    Op::DeleteUser,
    Op::CreateClient,
    Op::GetClient,
    Op::ListClients,
    Op::UpdateClient,
    Op::DeleteClient,
    Op::CreateRealm,
    Op::GetRealm,
    Op::ListRealms,
    Op::UpdateRealm,
    Op::DeleteRealm,
    Op::CreateRole,
    Op::GetRole,
    Op::ListRoles,
    Op::UpdateRole,
    Op::DeleteRole,
    Op::CreateGroup,
    Op::GetGroup,
    Op::ListGroups,
    Op::UpdateGroup,
    Op::DeleteGroup,
];

/// 그 호출의 성공 본문 — 리소스 모양의 객체(단건 · 생성 · 갱신 · 삭제)와 그 배열(목록 · 검색).
fn success_body(op: Op) -> Value {
    let user = json!({"id": "u1", "username": "alice", "enabled": true});
    let client = json!({"id": "c1", "clientId": "app", "enabled": true});
    let realm = json!({"id": "r", "realm": "r", "enabled": true});
    let role = json!({"id": "role-1", "name": "reader", "composite": false});
    let group = json!({"id": "g1", "name": "staff", "path": "/staff"});
    match op {
        Op::SearchUsers => json!([user]),
        Op::ListClients => json!([client]),
        Op::ListRealms => json!([realm]),
        Op::ListRoles => json!([role]),
        Op::ListGroups => json!([group]),
        Op::CreateUser | Op::GetUser | Op::UpdateUser | Op::DeleteUser => user,
        Op::CreateClient | Op::GetClient | Op::UpdateClient | Op::DeleteClient => client,
        Op::CreateRealm | Op::GetRealm | Op::UpdateRealm | Op::DeleteRealm => realm,
        Op::CreateRole | Op::GetRole | Op::UpdateRole | Op::DeleteRole => role,
        Op::CreateGroup | Op::GetGroup | Op::UpdateGroup | Op::DeleteGroup => group,
    }
}

fn d<T: std::fmt::Debug>(v: T) -> String {
    format!("{v:?}")
}

/// 호출 하나 — 성공이면 돌려준 값의 `Debug`.
async fn run(a: &AdminClient, op: Op) -> Result<String, KeycloakError> {
    Ok(match op {
        Op::CreateUser => d(a
            .create_user(UserRepresentation {
                username: Some("alice".into()),
                ..Default::default()
            })
            .await?),
        Op::GetUser => d(a.get_user("u1").await?),
        Op::SearchUsers => d(a.search_users(Some("alice"), 0, 100).await?),
        Op::UpdateUser => d(a
            .update_user(
                "u1",
                UserRepresentation {
                    first_name: Some("Alice".into()),
                    ..Default::default()
                },
            )
            .await?),
        Op::DeleteUser => d(a.delete_user("u1").await?),
        Op::CreateClient => d(a
            .create_client(ClientRepresentation {
                client_id: Some("app".into()),
                ..Default::default()
            })
            .await?),
        Op::GetClient => d(a.get_client("c1").await?),
        Op::ListClients => d(a.list_clients(0, 100).await?),
        Op::UpdateClient => d(a
            .update_client(
                "c1",
                ClientRepresentation {
                    enabled: Some(false),
                    ..Default::default()
                },
            )
            .await?),
        Op::DeleteClient => d(a.delete_client("c1").await?),
        Op::CreateRealm => d(a
            .create_realm(RealmRepresentation {
                realm: Some("r2".into()),
                ..Default::default()
            })
            .await?),
        Op::GetRealm => d(a.get_realm().await?),
        Op::ListRealms => d(a.list_realms().await?),
        Op::UpdateRealm => d(a
            .update_realm(
                "r",
                RealmRepresentation {
                    enabled: Some(true),
                    ..Default::default()
                },
            )
            .await?),
        Op::DeleteRealm => d(a.delete_realm("r2").await?),
        Op::CreateRole => d(a
            .create_role(RoleRepresentation {
                name: Some("reader".into()),
                ..Default::default()
            })
            .await?),
        Op::GetRole => d(a.get_role("reader").await?),
        Op::ListRoles => d(a.list_roles(0, 100).await?),
        Op::UpdateRole => d(a
            .update_role(
                "reader",
                RoleRepresentation {
                    description: Some("d".into()),
                    ..Default::default()
                },
            )
            .await?),
        Op::DeleteRole => d(a.delete_role("reader").await?),
        Op::CreateGroup => d(a
            .create_group(GroupRepresentation {
                name: Some("staff".into()),
                ..Default::default()
            })
            .await?),
        Op::GetGroup => d(a.get_group("g1").await?),
        Op::ListGroups => d(a.list_groups(0, 100).await?),
        Op::UpdateGroup => d(a
            .update_group(
                "g1",
                GroupRepresentation {
                    name: Some("staff2".into()),
                    ..Default::default()
                },
            )
            .await?),
        Op::DeleteGroup => d(a.delete_group("g1").await?),
    })
}

/// admin 경로의 응답 — 칸마다 바꾼다(상태와 본문). `Location` 은 달지 않는다.
#[derive(Clone)]
struct Plan(Arc<Mutex<(u16, Value)>>);

impl Respond for Plan {
    fn respond(&self, _: &Request) -> ResponseTemplate {
        let (status, body) = self.0.lock().expect("plan").clone();
        ResponseTemplate::new(status).set_body_json(body)
    }
}

async fn admin_requests(server: &MockServer) -> usize {
    server
        .received_requests()
        .await
        .expect("wiremock records requests")
        .iter()
        .filter(|r| r.url.path().starts_with("/admin/"))
        .count()
}

fn note(line: String) {
    if std::env::var("TC_PRINT").as_deref() == Ok("1") {
        eprintln!("{line}");
    }
}

#[tokio::test]
async fn a_location_less_3xx_fails_every_facade_call_with_its_status() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/realms/r/protocol/openid-connect/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"access_token": "AT", "token_type": "Bearer", "expires_in": 300}),
        ))
        .mount(&server)
        .await;
    let plan = Plan(Arc::new(Mutex::new((200, json!({})))));
    Mock::given(path_regex("^/admin/"))
        .respond_with(plan.clone())
        .mount(&server)
        .await;
    let config = KeycloakConfig::new(server.uri(), "r", "c")
        .expect("config")
        .with_client_secret("s");
    let kc = KeycloakClient::new(config).expect("client");
    let admin = kc.admin();
    let direct = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("direct client");

    let mut wrong = Vec::new();
    for status in STATUSES {
        // 전제 — 이 상태의 응답에 `Location` 이 없다(있으면 「Location 없는 3xx」를 잰 것이 아니다).
        *plan.0.lock().expect("plan") = (status, json!({}));
        let probe = direct
            .get(format!("{}/admin/realms/r/users/u1", server.uri()))
            .send()
            .await
            .expect("probe");
        if probe.status().as_u16() != status
            || probe.headers().contains_key(reqwest::header::LOCATION)
        {
            wrong.push(format!(
                "{status} premise: the server answered {} with Location {:?}",
                probe.status(),
                probe.headers().get(reqwest::header::LOCATION)
            ));
        }

        let mut passed = 0;
        for op in OPS {
            *plan.0.lock().expect("plan") = (status, success_body(op));
            let before = admin_requests(&server).await;
            let r = run(admin, op).await;
            let sent = admin_requests(&server).await - before;
            let got = match &r {
                Ok(v) => format!("returned {v}"),
                Err(e) => format!("{e:?}"),
            };
            note(format!(
                "[3xx] {status} {op:?}: {got} · admin requests {sent}"
            ));
            let ok = matches!(&r, Err(KeycloakError::Admin(AdminError::Other { status: s })) if *s == status)
                && sent == 1;
            if ok {
                passed += 1;
            } else {
                wrong.push(format!("{status} {op:?}: {got} · admin requests {sent}"));
            }
        }
        note(format!("[3xx] {status}: {passed}/{} cells pass", OPS.len()));
    }
    let token_requests = server
        .received_requests()
        .await
        .expect("wiremock records requests")
        .iter()
        .filter(|r| r.url.path() == "/realms/r/protocol/openid-connect/token")
        .count();
    note(format!("[3xx] token endpoint requests: {token_requests}"));
    assert!(
        wrong.is_empty(),
        "{} cell(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}
