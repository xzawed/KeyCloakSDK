//! admin 파사드가 응답 본문을 얼마나 읽는가 — 등록부 `admin-response-body-unbounded`(rust).
//!
//! `keycloak` crate 의 생성 메서드는 2xx 가 아니면 `error_check` 에서 본문을 **통째로** `text()` 로 읽는다. 파사드의 오류는
//! 상태로만 고르므로 그 본문은 쓰이지 않는다 — 그래서 파사드는 crate 와 같은 요청을 직접 보내고(`src/admin.rs`), 오류
//! 본문은 상한(1,048,576 바이트)까지만 비워 버린다. 여기서 재는 것:
//!
//! - 오류 본문을 읽지 않는다 — 상태 다섯 × 호출 다섯, 64 MiB 를 알린 본문(`an_error_body_is_not_read`).
//! - 머리 뒤에서 멈춘 오류 본문도 상태로 끝난다(`an_error_body_that_stalls_keeps_its_class`).
//! - 상한까지는 비워 연결을 다시 쓴다 — 정확히 상한이면 연결 하나, 한 바이트 넘으면 둘(`an_error_body_is_drained_up_to_the_cap`).
//! - 쓰기의 2xx 본문은 읽지 않는다(`a_write_does_not_read_its_2xx_body`).
//! - 파사드가 crate 와 **같은 요청**을 보낸다 — `raw()` 의 crate 메서드가 기준(`the_facade_sends_what_the_crate_sends`).
//!
//! ⚠️ **할당은 이 프로세스 전체를 센다**(`#[global_allocator]`) — 이 바이너리의 시험은 `SERIAL` 로 하나씩 돈다. 가짜 서버는
//! 큰 본문을 **만들지 않는다**: 정적 공백 버퍼를 조각내 흘려보낸다. `TC_PRINT=1` 이면 사례마다 잰 값을 찍는다.

use async_trait::async_trait;
use keycloak_sdk::types::{
    ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
    UserRepresentation,
};
use keycloak_sdk::{
    AdminClient, AdminError, KeycloakConfig, KeycloakError, TokenProvider, reqwest,
};
use std::alloc::{GlobalAlloc, Layout, System};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::time::{Duration, Instant};
use wiremock::matchers::any;
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

// ── 할당 계수 ────────────────────────────────────────────────────────────────────────────

struct Counting;
static CUR: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

fn grew(n: usize) {
    let now = CUR.fetch_add(n, Relaxed) + n;
    PEAK.fetch_max(now, Relaxed);
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(l) };
        if !p.is_null() {
            grew(l.size());
        }
        p
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc_zeroed(l) };
        if !p.is_null() {
            grew(l.size());
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) };
        CUR.fetch_sub(l.size(), Relaxed);
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let q = unsafe { System.realloc(p, l, new) };
        if !q.is_null() {
            if new >= l.size() {
                grew(new - l.size());
            } else {
                CUR.fetch_sub(l.size() - new, Relaxed);
            }
        }
        q
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

/// 피크를 지금 살아 있는 바이트로 되돌리고 그 값을 돌려준다 — 이후 `PEAK - 반환값` 이 그 구간의 증가분이다.
fn mark() -> usize {
    let now = CUR.load(Relaxed);
    PEAK.store(now, Relaxed);
    now
}

/// 할당을 재는 시험이 서로 섞이지 않게 — 런타임이 시험마다 달라 `tokio` 뮤텍스를 쓴다(런타임 무관).
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

const CAP: usize = 1_048_576;
const MIB: usize = 1024 * 1024;
const HUGE: usize = 64 * MIB;
static PAD: [u8; 64 * 1024] = [b' '; 64 * 1024];

struct Stub;
#[async_trait]
impl TokenProvider for Stub {
    async fn access_token(&self) -> Result<String, KeycloakError> {
        Ok("AT".to_string())
    }
}

/// `timeout` 은 SDK 가 `read_timeout` 으로 거는 것과 같은 reqwest 의 요청 전체 기한이다(`src/client.rs`).
fn admin_at(server_url: &str, realm: &str, timeout: Duration) -> AdminClient {
    let config = KeycloakConfig::new(server_url, realm, "it-client").unwrap();
    let http = reqwest::Client::builder()
        .timeout(timeout)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    AdminClient::new(&config, http, Arc::new(Stub))
}

fn admin(server_url: &str, timeout: Duration) -> AdminClient {
    admin_at(server_url, "r", timeout)
}

fn note(line: String) {
    if std::env::var("TC_PRINT").as_deref() == Ok("1") {
        eprintln!("{line}");
    }
}

// ── 원시 TCP 서버 ────────────────────────────────────────────────────────────────────────

/// 응답 하나 — 상태 줄과 머리(`extra` 는 덧붙일 머리 줄들, 각 줄 끝 `\r\n`) 뒤에 공백 본문 `body` 바이트를 알리고
/// `write` 바이트까지 쓴 다음 `hold` 동안 멈춘다. 청크 본문을 다 썼으면 종결 청크는 그 멈춤 뒤에 쓴다.
#[derive(Clone)]
struct Reply {
    status: u16,
    extra: String,
    body: usize,
    chunked: bool,
    write: usize,
    hold: Duration,
}

impl Reply {
    fn with(status: u16, body: usize) -> Self {
        Self {
            status,
            extra: String::new(),
            body,
            chunked: false,
            write: body,
            hold: Duration::ZERO,
        }
    }
    fn chunked(self, chunked: bool) -> Self {
        Self { chunked, ..self }
    }
    fn header(mut self, line: &str) -> Self {
        self.extra.push_str(line);
        self.extra.push_str("\r\n");
        self
    }
    fn stall_after(self, write: usize, hold: Duration) -> Self {
        Self {
            write,
            hold,
            ..self
        }
    }
}

/// 요청 하나를 끝까지 읽는다(머리 + 알린 길이만큼의 본문) — 남은 바이트는 `buf` 에 둔다. 연결이 끝나면 `None`.
fn read_request(s: &mut TcpStream, buf: &mut Vec<u8>) -> Option<()> {
    let mut tmp = [0u8; 8192];
    let head_end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        match s.read(&mut tmp) {
            Ok(0) | Err(_) => return None,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_ascii_lowercase();
    let declared = head
        .lines()
        .find_map(|l| {
            l.strip_prefix("content-length:")?
                .trim()
                .parse::<usize>()
                .ok()
        })
        .unwrap_or(0);
    while buf.len() < head_end + declared {
        match s.read(&mut tmp) {
            Ok(0) | Err(_) => return None,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
    }
    buf.drain(..head_end + declared);
    Some(())
}

/// `r` 을 쓴다 — 쓴 본문 바이트를 `wrote` 에 적는다(클라이언트가 끊으면 쓰기가 실패한다 — 그것이 정상 경로다).
fn write_reply(s: &mut TcpStream, r: &Reply, wrote: &AtomicUsize) -> std::io::Result<()> {
    let framing = if r.chunked {
        "Transfer-Encoding: chunked".to_string()
    } else {
        format!("Content-Length: {}", r.body)
    };
    write!(
        s,
        "HTTP/1.1 {} X\r\nContent-Type: application/json\r\n{}{framing}\r\n\r\n",
        r.status, r.extra
    )?;
    let mut sent = 0;
    while sent < r.write {
        let n = (r.write - sent).min(PAD.len());
        if r.chunked {
            write!(s, "{n:x}\r\n")?;
            s.write_all(&PAD[..n])?;
            s.write_all(b"\r\n")?;
        } else {
            s.write_all(&PAD[..n])?;
        }
        sent += n;
        wrote.store(sent, Relaxed);
    }
    s.flush()?;
    std::thread::sleep(r.hold);
    // 청크 본문의 끝(종결 청크)은 멈춘 **뒤에** 쓴다 — 클라이언트가 끝을 보기 전에 그만 읽는지를 가른다.
    if r.chunked && r.write == r.body {
        s.write_all(b"0\r\n\r\n")?;
        s.flush()?;
    }
    Ok(())
}

/// 원시 TCP 서버 — 연결을 닫지 않고 요청마다 응답한다(첫 요청은 `first`, 그 뒤는 `then`). 받은 연결 수와 `first` 의
/// 본문을 몇 바이트 썼는지 센다.
struct Server {
    url: String,
    conns: Arc<AtomicUsize>,
    wrote: Arc<AtomicUsize>,
}

fn serve(first: Reply, then: Reply) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let conns = Arc::new(AtomicUsize::new(0));
    let wrote = Arc::new(AtomicUsize::new(0));
    let served = Arc::new(AtomicUsize::new(0));
    let (c, w) = (conns.clone(), wrote.clone());
    std::thread::spawn(move || {
        for mut s in listener.incoming().flatten() {
            c.fetch_add(1, Relaxed);
            let (first, then, w, served) = (first.clone(), then.clone(), w.clone(), served.clone());
            std::thread::spawn(move || {
                let mut buf = Vec::new();
                let elsewhere = AtomicUsize::new(0);
                while read_request(&mut s, &mut buf).is_some() {
                    let ok = if served.fetch_add(1, Relaxed) == 0 {
                        write_reply(&mut s, &first, &w)
                    } else {
                        write_reply(&mut s, &then, &elsewhere)
                    };
                    if ok.is_err() {
                        return;
                    }
                }
            });
        }
    });
    Server { url, conns, wrote }
}

// ── 호출 ─────────────────────────────────────────────────────────────────────────────────

/// 파사드 호출 다섯 — 단건 GET · 목록 GET · PUT · POST · DELETE(다섯 리소스에 하나씩).
#[derive(Clone, Copy, Debug)]
enum Call {
    GetUser,
    ListClients,
    UpdateRealm,
    CreateRole,
    DeleteGroup,
}

const CALLS: [Call; 5] = [
    Call::GetUser,
    Call::ListClients,
    Call::UpdateRealm,
    Call::CreateRole,
    Call::DeleteGroup,
];

async fn run(a: &AdminClient, call: Call) -> Result<(), KeycloakError> {
    match call {
        Call::GetUser => a.get_user("u1").await.map(drop),
        Call::ListClients => a.list_clients(0, 10).await.map(drop),
        Call::UpdateRealm => a.update_realm("r", RealmRepresentation::default()).await,
        Call::CreateRole => a.create_role(RoleRepresentation::default()).await,
        Call::DeleteGroup => a.delete_group("g1").await,
    }
}

fn class(r: &Result<(), KeycloakError>) -> String {
    match r {
        Ok(()) => "ok".into(),
        Err(KeycloakError::Admin(AdminError::NotFound)) => "NotFound".into(),
        Err(KeycloakError::Admin(AdminError::Conflict)) => "Conflict".into(),
        Err(KeycloakError::Admin(AdminError::Forbidden)) => "Forbidden".into(),
        Err(KeycloakError::Admin(AdminError::Other { status })) => format!("Other({status})"),
        Err(e) => format!("{e:?}"),
    }
}

fn class_of(status: u16) -> String {
    match status {
        404 => "NotFound".into(),
        409 => "Conflict".into(),
        403 => "Forbidden".into(),
        _ => format!("Other({status})"),
    }
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────

/// 오류 상태(404 · 409 · 403 · 500 · 302)의 본문은 읽지 않는다 — 분류는 상태 그대로이고, 64 MiB 를 알린 본문을 서버가 다
/// 쓰지 못하며, 호출 하나의 할당 피크는 그 본문과 무관하다.
///
/// 한도 8 MiB(서버가 쓴 양)는 소켓 버퍼 몫이다 — 읽지 않은 응답이라도 커널 버퍼와 hyper 의 읽기 버퍼(최대 417,792
/// 바이트)는 찬다. 한도 16 MiB(피크)는 본문을 쥐면 넘고 쥐지 않으면 닿지 않는 자리다.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_error_body_is_not_read() {
    let _serial = SERIAL.lock().await;
    let mut wrong = Vec::new();
    for status in [404u16, 409, 403, 500, 302] {
        for call in CALLS {
            let server = serve(Reply::with(status, HUGE), Reply::with(status, 0));
            let a = admin(&server.url, Duration::from_secs(4));
            let base = mark();
            let start = Instant::now();
            let r = run(&a, call).await;
            let ms = start.elapsed().as_millis();
            let peak = PEAK.load(Relaxed).saturating_sub(base);
            drop(a);
            // 서버 스레드가 끊긴 쓰기를 마치게 한다.
            tokio::time::sleep(Duration::from_millis(100)).await;
            let sent = server.wrote.load(Relaxed);
            note(format!(
                "[error] {call:?} {status}: {ms} ms · server wrote {sent} · peak +{peak} · {}",
                class(&r)
            ));
            if class(&r) != class_of(status) || sent >= 8 * MIB || peak >= 16 * MIB {
                wrong.push(format!(
                    "{call:?} {status}: {} · server wrote {sent} · peak +{peak} · {ms} ms",
                    class(&r)
                ));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} case(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// 오류 본문이 머리 뒤에서 멈춰도 **상태로** 끝난다 — 고치기 전에는 crate 의 `text()` 가 기한 끝에 실패해 `NotFound`
/// 가 아니라 `Transport` 였다.
///
/// - 상한보다 길다고 알린 본문(2 MiB): 읽지 않으므로 기한(4 s)을 기다리지 않는다.
/// - 상한 안이라고 알린 본문(64 KiB): 연결을 다시 쓰려고 비우다 기한(1 s)에 걸린다 — 그래도 분류는 상태다.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_error_body_that_stalls_keeps_its_class() {
    let _serial = SERIAL.lock().await;
    let rows = [
        (
            "declared over the cap",
            Reply::with(404, 2 * MIB).stall_after(65_536, Duration::from_secs(6)),
            Duration::from_secs(4),
            Some(2000u128),
        ),
        (
            "declared within the cap",
            Reply::with(404, 65_536).stall_after(1024, Duration::from_secs(3)),
            Duration::from_secs(1),
            None,
        ),
    ];
    let mut wrong = Vec::new();
    for (row, reply, timeout, max_ms) in rows {
        for call in CALLS {
            let server = serve(reply.clone(), Reply::with(404, 0));
            let a = admin(&server.url, timeout);
            let start = Instant::now();
            let r = run(&a, call).await;
            let ms = start.elapsed().as_millis();
            note(format!("[stall] {row} · {call:?}: {ms} ms · {}", class(&r)));
            if class(&r) != "NotFound" || max_ms.is_some_and(|max| ms >= max) {
                wrong.push(format!("{row} · {call:?}: {} after {ms} ms", class(&r)));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} case(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// 오류 본문은 상한까지는 **비운다** — 그래야 HTTP/1.1 연결을 다음 요청이 다시 쓴다. 정확히 상한(1,048,576 바이트)이면
/// 두 호출이 연결 하나를 쓰고, 한 바이트 넘으면 둘을 쓴다 — 알린 길이면 읽지 않고, 청크면 상한을 넘는 순간 버린다.
/// 「읽지 않고 버린다」만으로 바꾸면 「연결 하나」 행들이 깨진다 — 오류마다 연결을 새로 맺는다.
///
/// ⚠️ 「끝을 늦춘」 행은 종결 청크를 2 s 늦춘다. 늦추지 않으면 마지막 데이터와 종결이 한 번에 와서, 우리가 버리기 전에
/// hyper 가 메시지 끝까지 읽어 연결이 산다(실측 2026-10-27 — 상한 위반이 아니다). 늦추면 경계가 갈린다 — 정확히 상한인
/// 본문은 끝까지 기다려 비우고(연결 하나 · 2 s), 한 바이트 넘는 본문은 기다리지 않는다(연결 둘 · 곧바로).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_error_body_is_drained_up_to_the_cap() {
    let _serial = SERIAL.lock().await;
    let late_end = Duration::from_secs(2);
    let waits = Some(late_end.as_millis() - 200);
    let rows = [
        (
            "exactly the cap · Content-Length",
            Reply::with(404, CAP),
            1,
            None,
        ),
        (
            "exactly the cap · chunked",
            Reply::with(404, CAP).chunked(true),
            1,
            None,
        ),
        (
            "exactly the cap · chunked, end withheld",
            Reply::with(404, CAP)
                .chunked(true)
                .stall_after(CAP, late_end),
            1,
            waits,
        ),
        (
            "one byte over · Content-Length",
            Reply::with(404, CAP + 1),
            2,
            None,
        ),
        (
            "one byte over · chunked, end withheld",
            Reply::with(404, CAP + 1)
                .chunked(true)
                .stall_after(CAP + 1, late_end),
            2,
            None,
        ),
    ];
    let mut wrong = Vec::new();
    for (row, reply, want_conns, waits_ms) in rows {
        let server = serve(reply, Reply::with(404, 2));
        let a = admin(&server.url, Duration::from_secs(4));
        let start = Instant::now();
        let first = a.get_user("u1").await.map(drop);
        let ms = start.elapsed().as_millis();
        let second = a.get_user("u2").await.map(drop);
        let conns = server.conns.load(Relaxed);
        note(format!(
            "[drain] {row}: {} in {ms} ms / {} · {conns} connection(s)",
            class(&first),
            class(&second)
        ));
        // 기다려야 하는 행은 끝을 기다렸는가, 나머지는 곧바로 끝났는가(1 s — 루프백 1 MiB 는 수 ms 다).
        let timing_ok = match waits_ms {
            Some(min) => ms >= min,
            None => ms < 1000,
        };
        if class(&first) != "NotFound"
            || class(&second) != "NotFound"
            || conns != want_conns
            || !timing_ok
        {
            wrong.push(format!(
                "{row}: {} in {ms} ms / {} · {conns} connection(s), want {want_conns}",
                class(&first),
                class(&second)
            ));
        }
    }
    assert!(
        wrong.is_empty(),
        "{} case(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// 쓰기의 2xx 본문은 읽지 않는다 — 생성은 `Location` 의 마지막 조각을 id 로 돌려주고(없으면 `None`), 갱신은 `Ok(())` 다.
/// 64 MiB 를 알린 본문을 서버가 다 쓰지 못하고, 본문이 오지 않아도 기한(4 s)을 기다리지 않는다.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_write_does_not_read_its_2xx_body() {
    let _serial = SERIAL.lock().await;
    let location = "Location: http://kc/admin/realms/r/users/abc-1";
    let mut wrong = Vec::new();

    let server = serve(Reply::with(201, HUGE).header(location), Reply::with(404, 0));
    let a = admin(&server.url, Duration::from_secs(4));
    let id = a.create_user(UserRepresentation::default()).await;
    drop(a);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let sent = server.wrote.load(Relaxed);
    note(format!(
        "[write] create 201 + 64 MiB: {id:?} · server wrote {sent}"
    ));
    if !matches!(&id, Ok(Some(v)) if v == "abc-1") || sent >= 8 * MIB {
        wrong.push(format!("create 201 + 64 MiB: {id:?} · server wrote {sent}"));
    }

    let server = serve(Reply::with(200, HUGE), Reply::with(404, 0));
    let a = admin(&server.url, Duration::from_secs(4));
    let updated = a.update_user("u1", UserRepresentation::default()).await;
    drop(a);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let sent = server.wrote.load(Relaxed);
    note(format!(
        "[write] update 200 + 64 MiB: {updated:?} · server wrote {sent}"
    ));
    if updated.is_err() || sent >= 8 * MIB {
        wrong.push(format!(
            "update 200 + 64 MiB: {updated:?} · server wrote {sent}"
        ));
    }

    let server = serve(
        Reply::with(201, CAP)
            .header(location)
            .stall_after(0, Duration::from_secs(6)),
        Reply::with(404, 0),
    );
    let a = admin(&server.url, Duration::from_secs(4));
    let start = Instant::now();
    let id = a.create_user(UserRepresentation::default()).await;
    let ms = start.elapsed().as_millis();
    note(format!(
        "[write] create 201 + stalled 1 MiB: {id:?} · {ms} ms"
    ));
    if !matches!(&id, Ok(Some(v)) if v == "abc-1") || ms >= 2000 {
        wrong.push(format!("create 201 + stalled 1 MiB: {id:?} after {ms} ms"));
    }

    let server = serve(Reply::with(201, 0), Reply::with(404, 0));
    let a = admin(&server.url, Duration::from_secs(4));
    let id = a.create_group(GroupRepresentation::default()).await;
    if !matches!(id, Ok(None)) {
        wrong.push(format!("create 201 without Location: {id:?}"));
    }

    assert!(
        wrong.is_empty(),
        "{} case(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

// ── 파사드 ↔ crate 요청 동등성 ─────────────────────────────────────────────────────────────

/// 받은 요청에 경로 모양대로 성공 응답을 준다(목록 `[]` · 단건 `{}` · 생성 201 + Location · 그 밖 204).
struct Echo;
impl Respond for Echo {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let path = req.url.path();
        let list = ["/users", "/clients", "/roles", "/groups", "/admin/realms"]
            .iter()
            .any(|tail| path.ends_with(tail));
        match req.method.as_str() {
            "GET" if list => ResponseTemplate::new(200).set_body_json(serde_json::json!([])),
            "GET" => ResponseTemplate::new(200).set_body_json(serde_json::json!({})),
            "POST" => ResponseTemplate::new(201)
                .insert_header("Location", format!("{}/new-id", req.url).as_str()),
            _ => ResponseTemplate::new(204),
        }
    }
}

/// 요청 하나의 와이어 — 메서드 · URL(경로 · 쿼리) · 머리 전부(이름순) · 본문 바이트.
fn wire(r: &Request) -> String {
    let mut headers: Vec<String> = r
        .headers
        .iter()
        .map(|(k, v)| format!("{k}: {}", String::from_utf8_lossy(v.as_bytes())))
        .collect();
    headers.sort();
    format!(
        "{} {} | {} | {}",
        r.method,
        r.url,
        headers.join(" ; "),
        String::from_utf8_lossy(&r.body)
    )
}

/// 바이트 0x00–0x7F 전부 + 비ASCII — 경로 조각 인코딩이 crate 와 한 바이트라도 다르면 와이어가 갈린다.
fn every_byte() -> String {
    let mut s: String = (0u8..=0x7F).map(char::from).collect();
    s.push_str("é한😀");
    s
}

fn user() -> UserRepresentation {
    UserRepresentation {
        username: Some("ali ce+é".into()),
        enabled: Some(true),
        ..Default::default()
    }
}
fn client() -> ClientRepresentation {
    ClientRepresentation {
        client_id: Some("c 1".into()),
        ..Default::default()
    }
}
fn realm_rep() -> RealmRepresentation {
    RealmRepresentation {
        realm: Some("new name".into()),
        ..Default::default()
    }
}
fn role() -> RoleRepresentation {
    RoleRepresentation {
        name: Some("new role".into()),
        ..Default::default()
    }
}
fn group() -> GroupRepresentation {
    GroupRepresentation {
        name: Some("g 1".into()),
        ..Default::default()
    }
}

fn d<T: std::fmt::Debug>(r: T) -> String {
    format!("{r:?}")
}

/// 파사드 메서드 스물여섯 — `search_users` 는 username 이 있을 때와 없을 때 둘이다.
#[derive(Clone, Copy, Debug)]
enum Method {
    CreateUser,
    GetUser,
    SearchUsers,
    SearchUsersWithoutUsername,
    FindUserByUsername,
    UpdateUser,
    DeleteUser,
    CreateClient,
    GetClient,
    ListClients,
    UpdateClient,
    DeleteClient,
    GetRealm,
    CreateRealm,
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

const METHODS: [Method; 27] = [
    Method::CreateUser,
    Method::GetUser,
    Method::SearchUsers,
    Method::SearchUsersWithoutUsername,
    Method::FindUserByUsername,
    Method::UpdateUser,
    Method::DeleteUser,
    Method::CreateClient,
    Method::GetClient,
    Method::ListClients,
    Method::UpdateClient,
    Method::DeleteClient,
    Method::GetRealm,
    Method::CreateRealm,
    Method::ListRealms,
    Method::UpdateRealm,
    Method::DeleteRealm,
    Method::CreateRole,
    Method::GetRole,
    Method::ListRoles,
    Method::UpdateRole,
    Method::DeleteRole,
    Method::CreateGroup,
    Method::GetGroup,
    Method::ListGroups,
    Method::UpdateGroup,
    Method::DeleteGroup,
];

/// 파사드로 부른 결과(성공이면 그 값의 `Debug`).
async fn via_facade(a: &AdminClient, m: Method, id: &str) -> String {
    match m {
        Method::CreateUser => d(a.create_user(user()).await),
        Method::GetUser => d(a.get_user(id).await),
        Method::SearchUsers => d(a.search_users(Some(id), 40, 25).await),
        Method::SearchUsersWithoutUsername => d(a.search_users(None, 0, -1).await),
        Method::FindUserByUsername => d(a.find_user_by_username(id).await),
        Method::UpdateUser => d(a.update_user(id, user()).await),
        Method::DeleteUser => d(a.delete_user(id).await),
        Method::CreateClient => d(a.create_client(client()).await),
        Method::GetClient => d(a.get_client(id).await),
        Method::ListClients => d(a.list_clients(5, 7).await),
        Method::UpdateClient => d(a.update_client(id, client()).await),
        Method::DeleteClient => d(a.delete_client(id).await),
        Method::GetRealm => d(a.get_realm().await),
        Method::CreateRealm => d(a.create_realm(realm_rep()).await),
        Method::ListRealms => d(a.list_realms().await),
        Method::UpdateRealm => d(a.update_realm(id, realm_rep()).await),
        Method::DeleteRealm => d(a.delete_realm(id).await),
        Method::CreateRole => d(a.create_role(role()).await),
        Method::GetRole => d(a.get_role(id).await),
        Method::ListRoles => d(a.list_roles(3, 9).await),
        Method::UpdateRole => d(a.update_role(id, role()).await),
        Method::DeleteRole => d(a.delete_role(id).await),
        Method::CreateGroup => d(a.create_group(group()).await),
        Method::GetGroup => d(a.get_group(id).await),
        Method::ListGroups => d(a.list_groups(1, 2).await),
        Method::UpdateGroup => d(a.update_group(id, group()).await),
        Method::DeleteGroup => d(a.delete_group(id).await),
    }
}

/// 같은 일을 `raw()` 의 crate 메서드로 — 인자는 파사드가 crate 를 부르던 때(main 03dd451)의 그대로이고, 결과는 파사드의
/// 반환 모양으로 맞춘다.
async fn via_crate(a: &AdminClient, m: Method, realm: &str, id: &str) -> String {
    let k = a.raw();
    match m {
        Method::CreateUser => d(k
            .realm_users_post(realm, user())
            .await
            .map(|r| r.to_id().map(str::to_string))),
        Method::GetUser => d(k.realm_users_with_user_id_get(realm, id, None).await),
        Method::SearchUsers => d(k
            .realm_users_get(
                realm,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                Some(40),
                None,
                None,
                None,
                None,
                Some(25),
                None,
                None,
                Some(id.to_string()),
            )
            .await),
        Method::SearchUsersWithoutUsername => d(k
            .realm_users_get(
                realm,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                Some(0),
                None,
                None,
                None,
                None,
                Some(-1),
                None,
                None,
                None,
            )
            .await),
        Method::FindUserByUsername => d(k
            .realm_users_get(
                realm,
                None,
                None,
                None,
                None,
                None,
                None,
                Some(true),
                Some(0),
                None,
                None,
                None,
                None,
                Some(2),
                None,
                None,
                Some(id.to_string()),
            )
            .await
            .map(|found| found.into_iter().next())),
        Method::UpdateUser => d(k
            .realm_users_with_user_id_put(realm, id, user())
            .await
            .map(drop)),
        Method::DeleteUser => d(k.realm_users_with_user_id_delete(realm, id).await.map(drop)),
        Method::CreateClient => d(k
            .realm_clients_post(realm, client())
            .await
            .map(|r| r.to_id().map(str::to_string))),
        Method::GetClient => d(k.realm_clients_with_client_uuid_get(realm, id).await),
        Method::ListClients => d(k
            .realm_clients_get(realm, None, Some(5), Some(7), None, None, None)
            .await),
        Method::UpdateClient => d(k
            .realm_clients_with_client_uuid_put(realm, id, client())
            .await
            .map(drop)),
        Method::DeleteClient => d(k
            .realm_clients_with_client_uuid_delete(realm, id)
            .await
            .map(drop)),
        Method::GetRealm => d(k.realm_get(realm).await),
        Method::CreateRealm => d(k.post(realm_rep()).await.map(drop)),
        Method::ListRealms => d(k.get(None).await),
        Method::UpdateRealm => d(k.realm_put(id, realm_rep()).await.map(drop)),
        Method::DeleteRealm => d(k.realm_delete(id).await.map(drop)),
        Method::CreateRole => d(k.realm_roles_post(realm, role()).await.map(drop)),
        Method::GetRole => d(k.realm_roles_with_role_name_get(realm, id).await),
        Method::ListRoles => d(k.realm_roles_get(realm, None, Some(3), Some(9), None).await),
        Method::UpdateRole => d(k
            .realm_roles_with_role_name_put(realm, id, role())
            .await
            .map(drop)),
        Method::DeleteRole => d(k
            .realm_roles_with_role_name_delete(realm, id)
            .await
            .map(drop)),
        Method::CreateGroup => d(k
            .realm_groups_post(realm, group())
            .await
            .map(|r| r.to_id().map(str::to_string))),
        Method::GetGroup => d(k.realm_groups_with_group_id_get(realm, id).await),
        Method::ListGroups => d(k
            .realm_groups_get(realm, None, None, Some(1), Some(2), None, None, None, None)
            .await),
        Method::UpdateGroup => d(k
            .realm_groups_with_group_id_put(realm, id, group())
            .await
            .map(drop)),
        Method::DeleteGroup => d(k
            .realm_groups_with_group_id_delete(realm, id)
            .await
            .map(drop)),
    }
}

/// 파사드 메서드 스물여섯(+ `search_users` 의 username 없는 갈래)이 `raw()` 의 crate 메서드와 **같은 요청**을 보내고
/// **같은 결과**를 낸다 — 메서드 · URL(경로의 퍼센트 인코딩 · 쿼리와 그 순서) · 머리 전부 · 본문 바이트. realm · id ·
/// 이름에 바이트 0x00–0x7F 전부와 비ASCII 를 넣고, server_url 에 경로 접두(`/auth/`)를 둔다.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_facade_sends_what_the_crate_sends() {
    let _serial = SERIAL.lock().await;
    let tricky = every_byte();
    let mut wrong = Vec::new();
    for m in METHODS {
        let server = MockServer::start().await;
        Mock::given(any()).respond_with(Echo).mount(&server).await;
        let a = admin_at(
            &format!("{}/auth/", server.uri()),
            &tricky,
            Duration::from_secs(4),
        );
        let facade = via_facade(&a, m, &tricky).await;
        let raw = via_crate(&a, m, &tricky, &tricky).await;
        let reqs = server.received_requests().await.unwrap_or_default();
        if reqs.len() != 2 {
            wrong.push(format!(
                "{m:?}: {} request(s) — facade {facade} · crate {raw}",
                reqs.len()
            ));
            continue;
        }
        let (f, c) = (wire(&reqs[0]), wire(&reqs[1]));
        note(format!("[wire] {m:?}: {f}"));
        if f != c {
            wrong.push(format!("{m:?} request:\n  facade {f}\n  crate  {c}"));
        }
        if facade != raw || facade.starts_with("Err") {
            wrong.push(format!("{m:?} result:\n  facade {facade}\n  crate  {raw}"));
        }
    }
    assert!(
        wrong.is_empty(),
        "{} case(s) differ:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}
