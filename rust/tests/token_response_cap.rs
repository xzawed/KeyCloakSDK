//! 토큰 엔드포인트·introspection 응답 본문의 바이트 상한(1 MiB) — **모든 레인**이 같은 상한으로 읽는가.
//!
//! 레인 여섯: `client_credentials_token` · `refresh` · `exchange_code`(셋 다 token 엔드포인트) ·
//! `introspect` · admin 이 쓰는 `ClientCredentialsTokenProvider` 단독 · admin 파사드(`list_realms` — 그 provider 가
//! 토큰을 먼저 얻는다).
//!
//! ⚠️ 상한이 없을 때(실측 2026-10-05): 다섯 레인 모두 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을
//! **받아들였고**, 힙 피크가 ~95 MiB(본문의 ~2.9 배 — reqwest `bytes()` 의 수집 + 연속 사본 + oauth2 의
//! `to_vec`)였다. 이 파일도 상한 전에는 여섯 레인 × 두 프레이밍 전부가 1,048,577 바이트를 받아들였고, 16 MiB 에
//! 47–56 MB 를 잡았다. 그래서 여기는 결과 분류만이 아니라 **할당 피크**를 잰다.
//!
//! ⚠️ **할당은 이 프로세스 전체를 센다**(`#[global_allocator]`) — 이 바이너리의 시험은 `SERIAL` 로 하나씩 돈다.
//! 가짜 IdP 는 큰 본문을 **만들지 않는다**: 정적 공백 버퍼를 조각내 흘려보낸다(wiremock 은 응답마다 본문을
//! 복제해 그 할당이 잰 값에 섞인다).
//!
//! 상한 1,048,576 은 Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트, 2026-10-03 실측 —
//! java `AdminTokenResponseTest`)의 16 배다. 아래 `KEYCLOAK_MAX_BEARER` 시험이 그 아래쪽을, 16 MiB 시험이 위쪽을 지킨다.

use keycloak_sdk::{
    AdminError, ClientCredentialsTokenProvider, KeycloakClient, KeycloakConfig, KeycloakError,
    TokenProvider, reqwest,
};
use std::alloc::{GlobalAlloc, Layout, System};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::sync::{Arc, Mutex};

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
/// Keycloak 26.6(start-dev 기본)이 받아들이는 가장 긴 Bearer — 한 바이트 더 길면 HTTP 431(2026-10-03 실측).
const KEYCLOAK_MAX_BEARER: usize = 65_459;
const MIB: usize = 1024 * 1024;

// ── 가짜 IdP: 큰 본문을 정적 버퍼에서 흘려보낸다 ───────────────────────────────────────────

static PAD: [u8; 64 * 1024] = [b' '; 64 * 1024];

/// 응답 하나 — `head` 뒤에 JSON 공백을 붙여 전체 `total` 바이트로 만든다.
#[derive(Clone)]
struct Reply {
    head: Arc<str>,
    total: usize,
    chunked: bool,
}

impl Reply {
    fn padded(head: &str, total: usize, chunked: bool) -> Self {
        assert!(head.len() <= total, "head {} > total {total}", head.len());
        Self {
            head: head.into(),
            total,
            chunked,
        }
    }
    fn exact(head: &str) -> Self {
        Self::padded(head, head.len(), false)
    }
}

#[derive(Default)]
struct State {
    token: Option<Reply>,
    introspect: Option<Reply>,
    admin_hits: usize,
    admin_auth_len: Option<usize>,
}

struct Fake {
    addr: SocketAddr,
    state: Arc<Mutex<State>>,
}

impl Fake {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let state = Arc::new(Mutex::new(State::default()));
        let st = state.clone();
        std::thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let st = st.clone();
                std::thread::spawn(move || {
                    // 클라이언트가 상한에서 끊으면 쓰기가 실패한다 — 그것이 정상 경로다.
                    let _ = serve(conn, &st);
                });
            }
        });
        Self { addr, state }
    }

    fn base(&self) -> String {
        format!("http://{}", self.addr)
    }

    fn serve_token(&self, r: Reply) {
        self.state.lock().unwrap().token = Some(r);
    }

    fn serve_introspect(&self, r: Reply) {
        self.state.lock().unwrap().introspect = Some(r);
    }

    fn admin_hits(&self) -> usize {
        self.state.lock().unwrap().admin_hits
    }

    fn admin_auth_len(&self) -> Option<usize> {
        self.state.lock().unwrap().admin_auth_len
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn serve(mut s: TcpStream, st: &Mutex<State>) -> std::io::Result<()> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 8192];
    let head_end = loop {
        let n = s.read(&mut tmp)?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(i) = find(&buf, b"\r\n\r\n") {
            break i + 4;
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let path = head.split(' ').nth(1).unwrap_or("").to_string();
    let header = |name: &str| {
        head.split("\r\n").find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.trim()
                .eq_ignore_ascii_case(name)
                .then(|| v.trim().to_string())
        })
    };
    let content_length: usize = header("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    // 요청 본문은 버린다(읽기만 한다) — 65,459 바이트 토큰을 실은 introspect 요청도 있다.
    let mut have = buf.len() - head_end;
    while have < content_length {
        let n = s.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        have += n;
    }
    let reply = {
        let mut g = st.lock().unwrap();
        if path.ends_with("/token/introspect") {
            g.introspect.clone()
        } else if path.ends_with("/token") {
            g.token.clone()
        } else if path == "/admin/realms" {
            g.admin_hits += 1;
            g.admin_auth_len = header("authorization").map(|v| v.len());
            Some(Reply::exact("[]"))
        } else {
            None
        }
    };
    let Some(r) = reply else {
        return s.write_all(
            b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
        );
    };
    let framing = if r.chunked {
        "transfer-encoding: chunked".to_string()
    } else {
        format!("content-length: {}", r.total)
    };
    write!(
        s,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\n{framing}\r\n\r\n"
    )?;
    let piece = |s: &mut TcpStream, data: &[u8]| -> std::io::Result<()> {
        if r.chunked {
            write!(s, "{:x}\r\n", data.len())?;
            s.write_all(data)?;
            s.write_all(b"\r\n")
        } else {
            s.write_all(data)
        }
    };
    piece(&mut s, r.head.as_bytes())?;
    let mut left = r.total - r.head.len();
    while left > 0 {
        let n = left.min(PAD.len());
        piece(&mut s, &PAD[..n])?;
        left -= n;
    }
    if r.chunked {
        s.write_all(b"0\r\n\r\n")?;
    }
    s.flush()
}

// ── 레인 ─────────────────────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq)]
enum Lane {
    ClientCredentials,
    Refresh,
    Code,
    Introspect,
    Provider,
    Admin,
}

const LANES: [Lane; 6] = [
    Lane::ClientCredentials,
    Lane::Refresh,
    Lane::Code,
    Lane::Introspect,
    Lane::Provider,
    Lane::Admin,
];

/// 레인마다 새로 만든다 — admin 의 provider 는 토큰을 캐시하므로 재사용하면 두 번째부터 토큰 엔드포인트에 안 간다.
/// ⚠️ 만드는 일(rustls 설정 등)의 할당은 `mark()` **앞**에 끝난다 — 재는 것은 호출 하나다.
struct Sdk {
    client: KeycloakClient,
    provider: ClientCredentialsTokenProvider,
}

impl Sdk {
    fn new(fake: &Fake) -> Self {
        let cfg = KeycloakConfig::new(fake.base(), "it-realm", "it-client")
            .unwrap()
            .with_client_secret("s");
        Self {
            client: KeycloakClient::new(cfg.clone()).unwrap(),
            provider: ClientCredentialsTokenProvider::new(cfg, reqwest::Client::new()),
        }
    }

    /// 성공이면 받은 access_token 의 길이(토큰을 돌려주는 레인만).
    async fn call(&self, lane: Lane, token_arg: &str) -> Result<Option<usize>, KeycloakError> {
        let auth = self.client.auth();
        match lane {
            Lane::ClientCredentials => auth
                .client_credentials_token()
                .await
                .map(|t| Some(t.access_token.len())),
            Lane::Refresh => auth
                .refresh(token_arg)
                .await
                .map(|t| Some(t.access_token.len())),
            Lane::Code => auth
                .exchange_code("code", "verifier-0123456789-0123456789-0123456789", None)
                .await
                .map(|t| Some(t.access_token.len())),
            Lane::Introspect => auth.introspect(token_arg).await.map(|r| {
                assert!(r.active, "introspection must still be read as active");
                None
            }),
            Lane::Provider => self.provider.access_token().await.map(|t| Some(t.len())),
            Lane::Admin => self.client.admin().list_realms().await.map(|_| None),
        }
    }
}

/// 런타임마다 한 번 드는 할당(첫 연결 언저리)을 재기 **전에** 치른다 — 실측: 이것 없이는 시험의 첫 레인만
/// 본문과 무관하게 ~0.5 MB 를 더 쟀다(나머지 레인은 그대로였다).
async fn warm_up() {
    let fake = Fake::start();
    serve_unpadded(&fake, "warm-up");
    Sdk::new(&fake)
        .call(Lane::ClientCredentials, "rt")
        .await
        .expect("warm-up call");
}

fn token_head(access_token: &str) -> String {
    serde_json::json!({
        "access_token": access_token, "token_type": "Bearer", "expires_in": 300, "refresh_token": "rt",
    })
    .to_string()
}

fn introspect_head() -> String {
    serde_json::json!({ "active": true, "username": "u", "client_id": "it-client" }).to_string()
}

/// 두 엔드포인트가 같은 크기(`total`)·같은 프레이밍으로 답하게 한다.
fn serve_both(fake: &Fake, access_token: &str, total: usize, chunked: bool) {
    fake.serve_token(Reply::padded(&token_head(access_token), total, chunked));
    fake.serve_introspect(Reply::padded(&introspect_head(), total, chunked));
}

/// 덧붙임 없는 정상 응답.
fn serve_unpadded(fake: &Fake, access_token: &str) {
    fake.serve_token(Reply::exact(&token_head(access_token)));
    fake.serve_introspect(Reply::exact(&introspect_head()));
}

/// 상한을 넘긴 응답의 기대 분류 — 레인마다 그 레인의 「실패한 토큰(·introspection) 응답」 타입이다.
/// 어긋나면 그 사유를 돌려준다 — 시험은 레인 전부를 돈 뒤 한꺼번에 실패한다(첫 레인에서 멈추면 RED 가 한 칸만 보인다).
fn rejected_over_cap(
    lane: Lane,
    r: &Result<Option<usize>, KeycloakError>,
    fake: &Fake,
) -> Result<(), String> {
    let want = match lane {
        Lane::Introspect => "introspection response exceeds 1048576 bytes",
        _ => "token response exceeds 1048576 bytes",
    };
    match (lane, r) {
        // admin 은 provider 의 실패를 기존 매핑 그대로 401 로 낸다 — 그리고 admin 요청을 **보내지 않는다**.
        (Lane::Admin, Err(KeycloakError::Admin(AdminError::Other { status: 401 }))) => {
            match fake.admin_hits() {
                0 => Ok(()),
                n => Err(format!(
                    "{lane:?}: {n} admin request(s) sent after a rejected token response"
                )),
            }
        }
        (Lane::Admin, other) => Err(format!(
            "{lane:?}: expected Admin(Other {{ status: 401 }}), got {other:?}"
        )),
        (_, Err(KeycloakError::Transport(m))) if m == want => Ok(()),
        (_, other) => Err(format!(
            "{lane:?}: expected Transport({want:?}), got {other:?}"
        )),
    }
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────

/// 아래쪽 — Keycloak 이 받아들이는 가장 긴 Bearer 는 모든 레인에서 통과한다(상한을 너무 낮게 잡으면 여기서 깨진다).
#[tokio::test]
async fn keycloak_max_bearer_of_65459_bytes_passes_every_lane() {
    let _serial = SERIAL.lock().await;
    let bearer = "a".repeat(KEYCLOAK_MAX_BEARER);
    for lane in LANES {
        let fake = Fake::start();
        serve_unpadded(&fake, &bearer);
        // introspect 는 응답이 아니라 **요청**에 그 토큰을 싣는다.
        let got = Sdk::new(&fake)
            .call(lane, &bearer)
            .await
            .unwrap_or_else(|e| panic!("{lane:?}: a 65,459-byte bearer must pass, got {e:?}"));
        match lane {
            Lane::Introspect => {}
            Lane::Admin => assert_eq!(
                fake.admin_auth_len(),
                Some("Bearer ".len() + KEYCLOAK_MAX_BEARER),
                "admin must send the whole 65,459-byte bearer"
            ),
            _ => assert_eq!(got, Some(KEYCLOAK_MAX_BEARER), "{lane:?}"),
        }
    }
}

/// 경계 — 정확히 상한(1,048,576 바이트)인 본문은 지금처럼 통과한다. 두 프레이밍 다.
#[tokio::test]
async fn body_of_exactly_the_cap_passes_every_lane() {
    let _serial = SERIAL.lock().await;
    for chunked in [false, true] {
        for lane in LANES {
            let fake = Fake::start();
            serve_both(&fake, "usable-access-token", CAP, chunked);
            let got = Sdk::new(&fake).call(lane, "rt").await.unwrap_or_else(|e| {
                panic!("{lane:?} chunked={chunked}: exactly the cap must pass, got {e:?}")
            });
            match lane {
                Lane::Introspect => {}
                Lane::Admin => assert_eq!(fake.admin_hits(), 1, "chunked={chunked}"),
                _ => assert_eq!(
                    got,
                    Some("usable-access-token".len()),
                    "{lane:?} chunked={chunked}"
                ),
            }
        }
    }
}

/// 경계 — 한 바이트 넘으면 쓸 수 있는 토큰을 담았어도 레인의 SDK 오류로 실패한다(admin 은 admin 요청 0 건).
#[tokio::test]
async fn body_one_byte_over_the_cap_fails_every_lane() {
    let _serial = SERIAL.lock().await;
    let mut wrong = Vec::new();
    for chunked in [false, true] {
        for lane in LANES {
            let fake = Fake::start();
            serve_both(&fake, "usable-access-token", CAP + 1, chunked);
            let r = Sdk::new(&fake).call(lane, "rt").await;
            if let Err(why) = rejected_over_cap(lane, &r, &fake) {
                wrong.push(format!("chunked={chunked} {why}"));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} lane(s) wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// 위쪽 — 16 MiB 본문은 실패하고, 그 판정이 잡는 메모리는 상한 언저리에서 멈춘다(본문 크기에 비례하지 않는다).
///
/// 한도 `3 × CAP`: 쥐는 본문은 많아야 `CAP` 이고, 그 위에 hyper 의 읽기 버퍼(최대 417,792 바이트 =
/// `8192 + 4096 × 100`, `BytesMut` 가 키울 때 두 배까지 잡을 수 있다)와 요청 조립이 얹힌다. 실측(2026-10-05): 이
/// 시험 240 표본 최대 1,588,308 · 새 프로세스의 32 MiB 프로브 최대 ~2.0 MiB — `2 × CAP` 은 러너에 따라 깨질 수
/// 있다. 상한이 없던 때는 16 MiB 에 47–56 MB 였다.
#[tokio::test]
async fn sixteen_mib_body_fails_every_lane_with_bounded_allocation() {
    let _serial = SERIAL.lock().await;
    warm_up().await;
    let mut wrong = Vec::new();
    for chunked in [false, true] {
        for lane in LANES {
            let fake = Fake::start();
            serve_both(&fake, "usable-access-token", 16 * MIB, chunked);
            let sdk = Sdk::new(&fake);
            let before = mark();
            let r = sdk.call(lane, "rt").await;
            let grown = PEAK.load(Relaxed).saturating_sub(before);
            println!("{lane:?} chunked={chunked}: peak +{grown} bytes, {r:?}");
            if grown >= 3 * CAP {
                wrong.push(format!(
                    "chunked={chunked} {lane:?}: judging a 16 MiB body grew the heap by {grown} bytes ({r:?})"
                ));
            }
            if let Err(why) = rejected_over_cap(lane, &r, &fake) {
                wrong.push(format!("chunked={chunked} {why}"));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} finding(s):\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// 메모리는 **읽은 만큼만** 자란다 — 2 KiB 남짓한 정상 응답의 판정이 상한 크기의 버퍼를 미리 잡지 않는다
/// (`Vec::with_capacity(CAP)` 같은 선할당이 여기서 깨진다).
#[tokio::test]
async fn small_body_does_not_allocate_anywhere_near_the_cap() {
    let _serial = SERIAL.lock().await;
    warm_up().await;
    let token = "t".repeat(2000);
    for lane in LANES {
        let fake = Fake::start();
        serve_unpadded(&fake, &token);
        let sdk = Sdk::new(&fake);
        let before = mark();
        let r = sdk.call(lane, "rt").await;
        let grown = PEAK.load(Relaxed).saturating_sub(before);
        println!("{lane:?}: peak +{grown} bytes, {r:?}");
        assert!(r.is_ok(), "{lane:?}: {r:?}");
        assert!(
            grown < CAP / 4,
            "{lane:?}: judging a ~2 KiB body grew the heap by {grown} bytes — that is near the cap"
        );
    }
}
