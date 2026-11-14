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
//!
//! 같은 스물다섯으로 두 갈래를 더 잰다.
//! - 오류 본문 모양(등록부 `python-admin-list-error-array-body` 의 부류 재스캔 — python 목록 다섯은 배열 본문의 4xx · 5xx 에
//!   상태 없는 전송 오류였다): 404 · 500 에 객체가 아닌 JSON 여섯(`[]` · `"boom"` · `42` · `true` · `null` · `[` 100000 개 뒤
//!   `]` 100000 개)이나 객체 대조 `{"error":"x"}` 를 받으면 그 상태의 admin 오류다 — 404 는 `Admin(NotFound)`, 500 은
//!   `Admin(Other { status: 500 })`.
//! - 따라갈 수 있는 리다이렉트(등록부 `admin-followable-redirect-class-divergent` — go 는 `*TransportError` 였다): 302 의
//!   `Location` 이 그 호출의 성공 본문을 200 으로 내는 `/redirected-target` 을 가리켜도 따라가지 않는다 —
//!   `Admin(Other { status: 302 })` 이고 대상에는 요청이 가지 않는다.
//!
//! 두 갈래 모두 칸마다 admin 요청은 정확히 하나다. 전제(본문이 그 바이트 그대로 `application/json` 으로 나간다 · 302 에 그
//! `Location` 이 있고 대상이 200 과 성공 본문을 낸다)는 리다이렉트를 따르지 않는 클라이언트로 잰다. 실측 2026-11-14(main
//! ad16554d): 오류 본문 300/300(대조 50/50) · 리다이렉트 25/25 — 이미 옳았다.

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

// ── 오류 본문 모양 · 따라갈 수 있는 리다이렉트 ──

/// 오류 본문 칸의 상태 둘.
const ERROR_STATUSES: [u16; 2] = [404, 500];
/// 302 의 `Location` 이 가리키는 자리 — 그 호출의 성공 본문을 200 으로 낸다.
const TARGET: &str = "/redirected-target";

/// 오류 상태에 실을 본문 — 객체 대조, 그다음 객체가 아닌 JSON 여섯(마지막은 `[` 100000 개 뒤 `]` 100000 개, 200,000 B).
fn error_bodies() -> Vec<(&'static str, Vec<u8>)> {
    let deep = format!("{}{}", "[".repeat(100_000), "]".repeat(100_000));
    vec![
        (r#"{"error":"x"}"#, br#"{"error":"x"}"#.to_vec()),
        ("[]", b"[]".to_vec()),
        (r#""boom""#, br#""boom""#.to_vec()),
        ("42", b"42".to_vec()),
        ("true", b"true".to_vec()),
        ("null", b"null".to_vec()),
        ("deep", deep.into_bytes()),
    ]
}

/// 두 갈래의 응답 — `Plan` 과 달리 본문을 바이트 그대로 싣고(`Value` 를 거치지 않는다), `location` 이 있으면 그 `Location` 을
/// 단다. `TARGET` 에는 200 과 `target` 을 낸다.
#[derive(Clone, Default)]
struct RawAnswer {
    status: u16,
    body: Vec<u8>,
    location: Option<String>,
    target: Vec<u8>,
}

#[derive(Clone, Default)]
struct RawPlan(Arc<Mutex<RawAnswer>>);

impl RawPlan {
    fn set(&self, answer: RawAnswer) {
        *self.0.lock().expect("plan") = answer;
    }
}

impl Respond for RawPlan {
    fn respond(&self, request: &Request) -> ResponseTemplate {
        let answer = self.0.lock().expect("plan").clone();
        if request.url.path() == TARGET {
            return ResponseTemplate::new(200).set_body_raw(answer.target, "application/json");
        }
        let reply =
            ResponseTemplate::new(answer.status).set_body_raw(answer.body, "application/json");
        match answer.location {
            Some(location) => reply.insert_header("Location", location.as_str()),
            None => reply,
        }
    }
}

/// 토큰 엔드포인트는 정상으로 답하고 admin 경로와 `TARGET` 은 `RawPlan` 이 답하는 wiremock, 그 앞의 SDK 기본 클라이언트(토큰은
/// `KeycloakClient::new` 의 공급자가 받는다), 리다이렉트를 따르지 않는 직접 클라이언트(전제를 잰다).
async fn raw_setup() -> (MockServer, RawPlan, KeycloakClient, reqwest::Client) {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/realms/r/protocol/openid-connect/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"access_token": "AT", "token_type": "Bearer", "expires_in": 300}),
        ))
        .mount(&server)
        .await;
    let plan = RawPlan::default();
    Mock::given(path_regex("^(/admin/|/redirected-target$)"))
        .respond_with(plan.clone())
        .mount(&server)
        .await;
    let config = KeycloakConfig::new(server.uri(), "r", "c")
        .expect("config")
        .with_client_secret("s");
    let kc = KeycloakClient::new(config).expect("client");
    let direct = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("direct client");
    (server, plan, kc, direct)
}

async fn target_requests(server: &MockServer) -> usize {
    server
        .received_requests()
        .await
        .expect("wiremock records requests")
        .iter()
        .filter(|r| r.url.path() == TARGET)
        .count()
}

/// 이 언어가 그 상태에 내는 admin 오류인가 — 404 는 `NotFound`, 그 밖(500 · 302)은 그 상태를 지닌 `Other`.
fn is_admin_error_of(r: &Result<String, KeycloakError>, status: u16) -> bool {
    match status {
        404 => matches!(r, Err(KeycloakError::Admin(AdminError::NotFound))),
        _ => {
            matches!(r, Err(KeycloakError::Admin(AdminError::Other { status: s })) if *s == status)
        }
    }
}

/// 칸의 결과 — 길면 앞 300 B 와 길이만 적는다(오류가 본문을 싣게 되더라도 실패 메시지가 칸마다 200,000 B 씩 불지 않게).
fn brief(r: &Result<String, KeycloakError>) -> String {
    let full = match r {
        Ok(v) => format!("returned {v}"),
        Err(e) => format!("{e:?}"),
    };
    if full.len() <= 300 {
        return full;
    }
    let mut cut = 300;
    while !full.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}… ({} B)", &full[..cut], full.len())
}

/// 오류 상태(404 · 500)의 본문이 객체가 아닌 JSON 이어도 스물다섯 각각은 그 상태의 admin 오류다.
#[tokio::test]
async fn a_non_object_json_error_body_fails_every_facade_call_with_that_status_admin_error() {
    let (server, plan, kc, direct) = raw_setup().await;
    let admin = kc.admin();
    let bodies = error_bodies();

    let mut wrong = Vec::new();
    for status in ERROR_STATUSES {
        for (label, body) in &bodies {
            // 전제 — 이 상태로 이 본문이 바이트 그대로 `application/json` 으로 나간다.
            plan.set(RawAnswer {
                status,
                body: body.clone(),
                ..RawAnswer::default()
            });
            let probe = direct
                .get(format!("{}/admin/realms/r/users/u1", server.uri()))
                .send()
                .await
                .expect("probe");
            let answered = probe.status().as_u16();
            let content_type = probe
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned);
            let sent_body = probe.bytes().await.expect("probe body");
            if answered != status
                || content_type.as_deref() != Some("application/json")
                || sent_body.as_ref() != body.as_slice()
            {
                wrong.push(format!(
                    "{status} {label} premise: the server answered {answered} · {content_type:?} · {} B",
                    sent_body.len()
                ));
            }

            let mut passed = 0;
            for op in OPS {
                let before = admin_requests(&server).await;
                let r = run(admin, op).await;
                let sent = admin_requests(&server).await - before;
                let got = brief(&r);
                note(format!(
                    "[error body] {status} {label} {op:?}: {got} · admin requests {sent}"
                ));
                if is_admin_error_of(&r, status) && sent == 1 {
                    passed += 1;
                } else {
                    wrong.push(format!(
                        "{status} {label} {op:?}: {got} · admin requests {sent}"
                    ));
                }
            }
            note(format!(
                "[error body] {status} {label}: {passed}/{} cells pass",
                OPS.len()
            ));
        }
    }
    assert!(
        wrong.is_empty(),
        "{} cell(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// `Location` 이 있는 302 — 따라가면 성공할 자리를 가리켜도 따라가지 않고, 스물다섯 각각이 302 의 admin 오류다.
#[tokio::test]
async fn a_followable_redirect_is_not_followed_and_fails_every_facade_call_with_302() {
    let (server, plan, kc, direct) = raw_setup().await;
    let admin = kc.admin();
    let location = format!("{}{TARGET}", server.uri());
    let answer = |op: Op| RawAnswer {
        status: 302,
        body: b"{}".to_vec(),
        location: Some(location.clone()),
        target: serde_json::to_vec(&success_body(op)).expect("success body"),
    };

    let mut wrong = Vec::new();
    // 전제 — 302 에 그 `Location` 이 있고, 대상은 200 과 성공 본문을 낸다(따라갔다면 성공했을 자리다).
    plan.set(answer(Op::GetUser));
    let probe = direct
        .get(format!("{}/admin/realms/r/users/u1", server.uri()))
        .send()
        .await
        .expect("probe");
    let answered = probe.status().as_u16();
    let pointed = probe
        .headers()
        .get(reqwest::header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    if answered != 302 || pointed.as_deref() != Some(location.as_str()) {
        wrong.push(format!(
            "premise: the server answered {answered} with Location {pointed:?}"
        ));
    }
    let followed = direct
        .get(location.as_str())
        .send()
        .await
        .expect("target probe");
    let followed_status = followed.status().as_u16();
    let followed_body = followed.bytes().await.expect("target body");
    let user = serde_json::to_vec(&success_body(Op::GetUser)).expect("success body");
    if followed_status != 200 || followed_body.as_ref() != user.as_slice() {
        wrong.push(format!(
            "premise: the target answered {followed_status} with {} B",
            followed_body.len()
        ));
    }

    let mut passed = 0;
    for op in OPS {
        plan.set(answer(op));
        let before = admin_requests(&server).await;
        let reached_before = target_requests(&server).await;
        let r = run(admin, op).await;
        let sent = admin_requests(&server).await - before;
        let reached = target_requests(&server).await - reached_before;
        let got = brief(&r);
        note(format!(
            "[redirect] 302 {op:?}: {got} · admin requests {sent} · target requests {reached}"
        ));
        if is_admin_error_of(&r, 302) && sent == 1 && reached == 0 {
            passed += 1;
        } else {
            wrong.push(format!(
                "302 {op:?}: {got} · admin requests {sent} · target requests {reached}"
            ));
        }
    }
    note(format!("[redirect] 302: {passed}/{} cells pass", OPS.len()));
    assert!(
        wrong.is_empty(),
        "{} cell(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}
