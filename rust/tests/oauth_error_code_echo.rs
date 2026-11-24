//! The OAuth `error` code an SDK error carries is a code, never a value the request sent (registry
//! `token-error-code-secret-echo`).
//!
//! The IdP's `error` is response body too. An endpoint (or a proxy) that echoes what the request sent puts the client
//! secret, the refresh token or the introspected token there. `oauth_error` already took code-shaped values only, but a
//! lowercase-only secret has that shape — it reached `oauth_error` and `{:?}` on the grants, introspection, the
//! provider and the admin facade (measured on main a7d0fdf3). One rule now (`oauth_error_code`): shaped like a code and
//! overlapping no non-empty secret the request sent — neither contains the other, so a truncated or extended echo is
//! withheld too. The price is pinned below: a secret that is a piece of a registered code (`client`) withholds it.

use base64::Engine as _;
use keycloak_sdk::{
    AuthClient, ClientCredentialsTokenProvider, KeycloakClient, KeycloakConfig, KeycloakError,
    TokenProvider,
};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

// Code-shaped on purpose (the shape alone cannot withhold them), and no two share a piece — an echo of one value must be
// withheld by comparing against THAT value, not a sibling's prefix.
const SECRET: &str = "zebrasecretjk";
const REFRESH: &str = "yakrefreshvq";
const TOKEN: &str = "walrustokenpx";
const CODE: &str = "vulturecodeby";
const VERIFIER: &str = "ocelotverifierocelotverifierocelotverifierxx";

type Sent = HashMap<String, String>;
type EchoFn = Arc<dyn Fn(&Sent) -> serde_json::Value + Send + Sync>;

/// Answers every POST with `status` `{"error": …}` — `fixed`, or built by `echo` from what the request sent (the form,
/// with the client secret from Basic when it came that way). Records each request's sent values.
#[derive(Clone)]
struct EchoIdp {
    fixed: serde_json::Value,
    echo: Option<EchoFn>,
    status: u16,
    seen: Arc<Mutex<Vec<Sent>>>,
}

fn form_decode(s: &str) -> String {
    url::form_urlencoded::parse(format!("v={s}").as_bytes())
        .next()
        .map(|(_, v)| v.into_owned())
        .unwrap_or_default()
}

impl Respond for EchoIdp {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let mut sent: Sent = url::form_urlencoded::parse(&req.body)
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        if let Some(auth) = req
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            && let Some(b64) = auth.strip_prefix("Basic ")
        {
            let pair = base64::engine::general_purpose::STANDARD
                .decode(b64)
                .unwrap_or_default();
            let pair = String::from_utf8_lossy(&pair).into_owned();
            if let Some((_, secret)) = pair.split_once(':') {
                sent.insert("client_secret".into(), form_decode(secret));
            }
        }
        let error = match &self.echo {
            Some(echo) => echo(&sent),
            None => self.fixed.clone(),
        };
        self.seen.lock().unwrap().push(sent);
        ResponseTemplate::new(self.status).set_body_json(serde_json::json!({ "error": error }))
    }
}

struct Run {
    server: MockServer,
    seen: Arc<Mutex<Vec<Sent>>>,
}

async fn idp(fixed: serde_json::Value, echo: Option<EchoFn>) -> Run {
    idp_with(400, fixed, echo).await
}

async fn idp_with(status: u16, fixed: serde_json::Value, echo: Option<EchoFn>) -> Run {
    let server = MockServer::start().await;
    let seen = Arc::new(Mutex::new(Vec::new()));
    Mock::given(method("POST"))
        .respond_with(EchoIdp {
            fixed,
            echo,
            status,
            seen: seen.clone(),
        })
        .mount(&server)
        .await;
    Run { server, seen }
}

fn config(uri: &str, secret: Option<&str>) -> KeycloakConfig {
    let cfg = KeycloakConfig::new(uri, "r", "c").expect("config");
    match secret {
        Some(s) => cfg.with_client_secret(s),
        None => cfg,
    }
}

const SURFACES: [&str; 7] = [
    "client_credentials_token",
    "refresh",
    "exchange_code",
    "introspect",
    "AuthClient as TokenProvider",
    "ClientCredentialsTokenProvider",
    "admin",
];

/// The secret form fields each surface sends besides the client secret.
fn params(surface: &str) -> &'static [&'static str] {
    match surface {
        "refresh" => &["refresh_token"],
        "exchange_code" => &["code", "code_verifier"],
        "introspect" => &["token"],
        _ => &[],
    }
}

async fn fail(surface: &str, cfg: &KeycloakConfig) -> KeycloakError {
    run(surface, cfg).await.expect_err(surface)
}

async fn run(surface: &str, cfg: &KeycloakConfig) -> Result<(), KeycloakError> {
    let client = KeycloakClient::new(cfg.clone()).expect("client");
    let auth: &AuthClient = client.auth();
    match surface {
        "client_credentials_token" => auth.client_credentials_token().await.map(|_| ()),
        "refresh" => auth.refresh(REFRESH).await.map(|_| ()),
        "exchange_code" => auth.exchange_code(CODE, VERIFIER, None).await.map(|_| ()),
        "introspect" => auth.introspect(TOKEN).await.map(|_| ()),
        "AuthClient as TokenProvider" => TokenProvider::access_token(auth).await.map(|_| ()),
        "ClientCredentialsTokenProvider" => {
            // As the SDK's own client: no redirects (registry rust-lowlevel-ctor-redirect-policy).
            let http = reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .expect("client");
            ClientCredentialsTokenProvider::new(cfg.clone(), http)
                .access_token()
                .await
                .map(|_| ())
        }
        "admin" => client.admin().get_user("u1").await.map(|_| ()),
        other => unreachable!("{other}"),
    }
}

fn oauth_error_of(e: &KeycloakError) -> Option<&str> {
    match e {
        KeycloakError::Auth { oauth_error, .. } => oauth_error.as_deref(),
        _ => None,
    }
}

fn renderings(e: &KeycloakError) -> Vec<String> {
    let mut out = vec![e.to_string(), format!("{e:?}"), format!("{e:#?}")];
    let mut source = std::error::Error::source(e);
    while let Some(s) = source {
        out.push(s.to_string());
        out.push(format!("{s:?}"));
        source = s.source();
    }
    out
}

fn assert_withheld(label: &str, e: &KeycloakError, value: &str) {
    assert!(matches!(e, KeycloakError::Auth { .. }), "{label}: {e:?}");
    assert_eq!(oauth_error_of(e), None, "{label}");
    for (i, text) in renderings(e).iter().enumerate() {
        assert!(
            !text.contains(value),
            "{label}: rendering #{i} shows {value:?}: {text}"
        );
    }
}

type Shape = fn(&str) -> String;
/// Every piece and every padding, so each direction of the overlap is pinned (the code inside the value · the value
/// inside the code).
const ECHO_FORMS: [(&str, Shape); 7] = [
    ("whole", |v| v.to_string()),
    ("prefix", |v| v[..11].to_string()),
    ("suffix", |v| v[v.len() - 11..].to_string()),
    ("middle", |v| v[2..11].to_string()),
    ("extended", |v| format!("{v}_x")),
    ("prefixed", |v| format!("x_{v}")),
    ("wrapped", |v| format!("x_{v}_x")),
];

/// Keycloak answers a bad client with 401, not 400 — an error status other than 400 takes the same rule.
#[tokio::test]
async fn an_echo_on_a_401_is_never_carried() {
    for surface in SURFACES {
        for param in std::iter::once(&"client_secret").chain(params(surface)) {
            let p = param.to_string();
            let run = idp_with(
                401,
                serde_json::Value::Null,
                Some(Arc::new(move |sent: &Sent| {
                    sent.get(&p).cloned().unwrap_or_default().into()
                })),
            )
            .await;
            let e = fail(surface, &config(&run.server.uri(), Some(SECRET))).await;
            let value = run.seen.lock().unwrap()[0]
                .get(*param)
                .cloned()
                .expect("sent");
            assert_withheld(&format!("{surface} · 401 · {param}"), &e, &value);
        }
    }
}

#[tokio::test]
async fn an_echoed_client_secret_is_never_carried() {
    for surface in SURFACES {
        for (form, shape) in ECHO_FORMS {
            let run = idp(
                serde_json::Value::Null,
                Some(Arc::new(move |sent: &Sent| {
                    shape(sent.get("client_secret").map(String::as_str).unwrap_or("")).into()
                })),
            )
            .await;
            let e = fail(surface, &config(&run.server.uri(), Some(SECRET))).await;
            let first = run.seen.lock().unwrap()[0].clone();
            assert_eq!(
                first.get("client_secret").map(String::as_str),
                Some(SECRET),
                "{surface}"
            );
            assert_withheld(&format!("{surface} · {form}"), &e, &shape(SECRET));
        }
    }
}

/// An IdP or proxy that echoes the secret lowercased — the overlap ignores ASCII case.
#[tokio::test]
async fn a_lowercased_echo_of_the_client_secret_is_never_carried() {
    for surface in SURFACES {
        let run = idp(
            serde_json::Value::Null,
            Some(Arc::new(|sent: &Sent| {
                sent.get("client_secret")
                    .map(|s| s.to_ascii_lowercase())
                    .unwrap_or_default()
                    .into()
            })),
        )
        .await;
        let e = fail(surface, &config(&run.server.uri(), Some("EchoMixedCase"))).await;
        let first = run.seen.lock().unwrap()[0].clone();
        assert_eq!(
            first.get("client_secret").map(String::as_str),
            Some("EchoMixedCase"),
            "{surface}"
        );
        assert_withheld(&format!("{surface} · lowercased"), &e, "echomixedcase");
    }
}

/// The same lowercased echo under a success status (registry `auth-2xx-error-code-divergent`): the body carries an `error`, so
/// every surface fails as it does for a 400 — and the overlap rule still withholds the code.
#[tokio::test]
async fn success_status_oauth_error_withholds_a_lowercased_echo_of_the_client_secret() {
    for surface in SURFACES {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_raw(
                r#"{"error":"echoedsecret","error_description":"d"}"#,
                "application/json",
            ))
            .mount(&server)
            .await;
        let e = fail(surface, &config(&server.uri(), Some("EchoedSecret"))).await;
        for value in ["echoedsecret", "EchoedSecret"] {
            assert_withheld(&format!("{surface} · 200 · lowercased"), &e, value);
        }
    }
}

#[tokio::test]
async fn an_echoed_grant_value_is_never_carried() {
    for surface in SURFACES {
        for param in params(surface) {
            for (form, shape) in ECHO_FORMS {
                let p = param.to_string();
                let run = idp(
                    serde_json::Value::Null,
                    Some(Arc::new(move |sent: &Sent| {
                        shape(sent.get(&p).map(String::as_str).unwrap_or("")).into()
                    })),
                )
                .await;
                let e = fail(surface, &config(&run.server.uri(), Some(SECRET))).await;
                let value = run.seen.lock().unwrap()[0]
                    .get(*param)
                    .cloned()
                    .expect("sent");
                assert_withheld(&format!("{surface} · {param} · {form}"), &e, &shape(&value));
            }
        }
    }
}

#[tokio::test]
async fn a_public_client_withholds_its_echoed_refresh_token_and_still_gets_a_code() {
    let run = idp(
        serde_json::Value::Null,
        Some(Arc::new(|sent: &Sent| {
            sent.get("refresh_token")
                .cloned()
                .unwrap_or_default()
                .into()
        })),
    )
    .await;
    let e = fail("refresh", &config(&run.server.uri(), None)).await;
    assert!(
        run.seen.lock().unwrap()[0]
            .get("client_secret")
            .is_none_or(String::is_empty)
    );
    assert_withheld("public · echo", &e, REFRESH);
    let run = idp(serde_json::json!("invalid_grant"), None).await;
    let e = fail("refresh", &config(&run.server.uri(), None)).await;
    assert_eq!(oauth_error_of(&e), Some("invalid_grant"));
}

#[tokio::test]
async fn a_value_that_is_not_a_code_is_never_carried() {
    let values = [
        serde_json::json!("Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5"),
        serde_json::json!("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl"),
        serde_json::json!("Invalid_client"),
        serde_json::json!("invalid client"),
        serde_json::json!("invalid_client2"),
        serde_json::json!("a".repeat(65)),
        serde_json::json!(["invalid_client"]),
        serde_json::json!(400),
    ];
    for surface in SURFACES {
        for value in &values {
            let run = idp(value.clone(), None).await;
            let e = fail(surface, &config(&run.server.uri(), Some(SECRET))).await;
            assert_eq!(oauth_error_of(&e), None, "{surface} · {value}");
            if let Some(s) = value.as_str() {
                for text in renderings(&e) {
                    assert!(!text.contains(s), "{surface} · {value}: {text}");
                }
            }
        }
    }
}

#[tokio::test]
async fn a_code_that_overlaps_nothing_sent_is_carried() {
    let long = "a".repeat(64);
    for surface in SURFACES {
        for code in [
            "invalid_client",
            "invalid_grant",
            "slow_down",
            long.as_str(),
        ] {
            let run = idp(serde_json::json!(code), None).await;
            let e = fail(surface, &config(&run.server.uri(), Some(SECRET))).await;
            assert_eq!(oauth_error_of(&e), Some(code), "{surface}");
        }
    }
}

#[tokio::test]
async fn the_price_a_secret_that_is_a_piece_of_the_code_withholds_it() {
    for surface in [
        "client_credentials_token",
        "ClientCredentialsTokenProvider",
        "admin",
    ] {
        let run = idp(serde_json::json!("invalid_client"), None).await;
        let e = fail(surface, &config(&run.server.uri(), Some("client"))).await;
        assert_eq!(oauth_error_of(&e), None, "{surface}");
    }
}

// The OAuth `error` at a 3xx and a 5xx (registry `node-5xx-oauth-error-code-empty`). The contract puts it in the code
// field "at any status"; that was measured at 400 · 401 (#1199) and the other 2xx (#1207) only. Pinned as the contract
// reads at 500 · 503 and at 302 (`Location` on this server — a 3xx is an error status too), which is never followed.
const B5: &str = r#"{"error":"temporarily_unavailable","error_description":"down"}"#;
const NO_ERROR: &str = r#"{"message":"down"}"#;
/// Where the 3xx cells point `Location` (this server, same origin) — a client that follows it shows up in the requests.
const REDIRECT_TARGET: &str = "/redirect-target";

/// One surface's outcome: `oauth_error`, one line, and every request the IdP saw.
struct Cell {
    code: Option<String>,
    line: String,
    requests: Vec<String>,
}

async fn error_status_cell(surface: &str, status: u16, body: &str, redirect: bool) -> Cell {
    let server = MockServer::start().await;
    Mock::given(path(REDIRECT_TARGET))
        .respond_with(
            ResponseTemplate::new(400)
                .set_body_raw(r#"{"error":"redirect_target_reached"}"#, "application/json"),
        )
        .with_priority(1)
        .mount(&server)
        .await;
    let mut answer = ResponseTemplate::new(status).set_body_raw(body, "application/json");
    if redirect {
        answer = answer.insert_header("Location", format!("{}{REDIRECT_TARGET}", server.uri()));
    }
    Mock::given(method("POST"))
        .respond_with(answer)
        .mount(&server)
        .await;
    let result = run(surface, &config(&server.uri(), Some(SECRET))).await;
    let requests: Vec<String> = server
        .received_requests()
        .await
        .unwrap_or_default()
        .iter()
        .map(|r| format!("{} {}", r.method, r.url.path()))
        .collect();
    let (code, outcome) = match &result {
        Ok(()) => (None, "success".to_string()),
        Err(e) => {
            let code = oauth_error_of(e).map(str::to_string);
            let debug = format!("{e:?}");
            let variant = debug
                .split([' ', '(', '{'])
                .next()
                .unwrap_or("?")
                .to_string();
            let shown = match e {
                KeycloakError::Auth { .. } => format!("{code:?}"),
                _ => "-".to_string(),
            };
            (code, format!("{variant}({e}) code={shown}"))
        }
    };
    let line = format!("{status} {surface} → {outcome} requests={requests:?}");
    Cell {
        code,
        line,
        requests,
    }
}

#[tokio::test]
async fn a_server_error_status_carries_the_oauth_error_on_every_surface() {
    let mut wrong = Vec::new();
    for status in [500, 503] {
        for surface in SURFACES {
            let c = error_status_cell(surface, status, B5, false).await;
            println!("{}", c.line);
            if c.code.as_deref() != Some("temporarily_unavailable") {
                wrong.push(c.line);
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} cells:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// Controls: the same body at 400 carries it; a 503 whose body names no `error` carries none.
#[tokio::test]
async fn the_error_status_controls_carry_it_at_400_and_none_without_one() {
    let mut wrong = Vec::new();
    for surface in SURFACES {
        let at400 = error_status_cell(surface, 400, B5, false).await;
        let none = error_status_cell(surface, 503, NO_ERROR, false).await;
        println!("{}\n{}", at400.line, none.line);
        if at400.code.as_deref() != Some("temporarily_unavailable") {
            wrong.push(at400.line);
        }
        if none.code.is_some() {
            wrong.push(none.line);
        }
    }
    assert!(
        wrong.is_empty(),
        "{} cells:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

#[tokio::test]
async fn a_redirect_error_status_carries_the_oauth_error_and_is_never_followed() {
    let mut wrong = Vec::new();
    for surface in SURFACES {
        let c = error_status_cell(surface, 302, B5, true).await;
        println!("{}", c.line);
        let followed = c
            .requests
            .iter()
            .any(|r| r.ends_with(&format!(" {REDIRECT_TARGET}")));
        if followed || c.code.as_deref() != Some("temporarily_unavailable") {
            wrong.push(c.line);
        }
    }
    assert!(
        wrong.is_empty(),
        "{} cells:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

// ── Residual divergence cells ────────────────────────────────────────────────────────────────────────────────────────
// Registry `token-response-residual-divergence`: (A) a 200 whose `error` is not a non-empty string, (B) a duplicated
// `error` key, (C) a non-200 2xx next to a 400 with the same unreadable body. A bare reqwest client first checks every
// cell's bytes come off the fake as written; then the targets: (A) a 200 whose `error` is present and neither null nor ""
// fails like a 400 carrying it — the lane's error class, no code unless a string the echo filter lets through, nothing in
// the body used (A1–A4 · B2); null and "" still succeed (A5 · A6). (C) a 2xx other than 200 gets the verdict the lane
// gives a 400 with the same body — class and code; the message may differ only by the status number (C1 ~ C2 · C3 ~ C4).
// Never asserted: which duplicated `error` an error status echoes (B1 · B3 · B4 — RFC 8259 §4 leaves it open) and B5 (a
// 200 whose duplicated `error` is a code, then "" — a parser differential the registry holds; `-- --nocapture` prints its
// outcome class).

const CELL_ADMIN_PATH: &str = "/admin/realms/r/users/u1";

/// (cell, status, token-lane body, introspection-lane body) — raw bytes, never a serializer: the duplicate keys and the
/// invalid UTF-8 (0xC3 0x28) must reach the client as written.
fn residual_cells() -> Vec<(&'static str, u16, Vec<u8>, Vec<u8>)> {
    let token = |x: &str| {
        format!(r#"{{"access_token":"AT-ok","token_type":"Bearer","expires_in":300,"error":{x}}}"#)
            .into_bytes()
    };
    let introspection =
        |x: &str| format!(r#"{{"active":true,"username":"svc","error":{x}}}"#).into_bytes();
    let mut bad_utf8 = br#"{"error":"invalid_grant","error_description":""#.to_vec();
    bad_utf8.extend_from_slice(&[0xC3, 0x28]);
    bad_utf8.extend_from_slice(br#""}"#);
    let b1 = br#"{"error":"invalid_grant","error":"temporarily_unavailable"}"#.to_vec();
    let b3 = br#"{"error":"invalid_grant","error":123}"#.to_vec();
    let b4 = br#"{"error":123,"error":"invalid_grant"}"#.to_vec();
    let mut cells = vec![(
        "A0",
        200,
        br#"{"access_token":"AT-ok","token_type":"Bearer","expires_in":300}"#.to_vec(),
        br#"{"active":true,"username":"svc"}"#.to_vec(),
    )];
    for (name, x) in [
        ("A1", "123"),
        ("A2", r#"{"a":1}"#),
        ("A3", r#"["x"]"#),
        ("A4", "true"),
        ("A5", "null"),
        ("A6", r#""""#),
    ] {
        cells.push((name, 200, token(x), introspection(x)));
    }
    cells.push(("B1", 400, b1.clone(), b1));
    cells.push((
        "B2",
        200,
        br#"{"access_token":"AT-ok","token_type":"Bearer","expires_in":300,"error":"invalid_grant","error":"temporarily_unavailable"}"#.to_vec(),
        br#"{"active":true,"error":"invalid_grant","error":"temporarily_unavailable"}"#.to_vec(),
    ));
    cells.push(("B3", 400, b3.clone(), b3));
    cells.push(("B4", 400, b4.clone(), b4));
    cells.push((
        "B5",
        200,
        br#"{"access_token":"AT-ok","token_type":"Bearer","expires_in":300,"error":"invalid_grant","error":""}"#.to_vec(),
        br#"{"active":true,"error":"invalid_grant","error":""}"#.to_vec(),
    ));
    cells.push(("C1", 201, bad_utf8.clone(), bad_utf8.clone()));
    cells.push(("C2", 400, bad_utf8.clone(), bad_utf8));
    cells.push(("C3", 201, b"not json".to_vec(), b"not json".to_vec()));
    cells.push(("C4", 400, b"not json".to_vec(), b"not json".to_vec()));
    cells
}

/// Every character outside printable ASCII as `\u{XXXX}` (a Rust `String` holds no invalid UTF-8, so `\x{HH}` never
/// arises here).
fn cell_text(s: &str) -> String {
    s.chars()
        .map(|c| {
            if (' '..='~').contains(&c) {
                c.to_string()
            } else {
                format!("\\u{{{:X}}}", c as u32)
            }
        })
        .collect()
}

fn cell_variant(e: &KeycloakError) -> String {
    let name = match e {
        KeycloakError::Config(_) => "Config".to_string(),
        KeycloakError::Auth { .. } => "Auth".to_string(),
        KeycloakError::Transport(_) => "Transport".to_string(),
        KeycloakError::Admin(_) => "Admin".to_string(),
        KeycloakError::TokenValidation(_) => "TokenValidation".to_string(),
        other => format!("{other:?}")
            .split(['(', ' ', '{'])
            .next()
            .unwrap_or("?")
            .to_string(),
    };
    format!("KeycloakError::{name}")
}

/// (outcome, code, message) of an error — the code is `oauth_error`, which only `Auth` has.
fn cell_error(e: &KeycloakError) -> (String, String, String) {
    let code = match e {
        KeycloakError::Auth {
            oauth_error: Some(c),
            ..
        } => format!("\"{c}\""),
        KeycloakError::Auth {
            oauth_error: None, ..
        } => "null".to_string(),
        _ => "n/a".to_string(),
    };
    (cell_variant(e), code, e.to_string())
}

fn cell_token<T>(
    r: Result<T, KeycloakError>,
    access_token: impl Fn(&T) -> String,
) -> (String, String, String) {
    match r {
        Ok(t) => (
            "SUCCESS".into(),
            "-".into(),
            format!("access_token={}", access_token(&t)),
        ),
        Err(e) => cell_error(&e),
    }
}

/// Records the `Authorization` header of every admin request and answers it with a user the facade parses.
struct CellAdmin(Arc<Mutex<Vec<String>>>);

impl Respond for CellAdmin {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let auth = req
            .headers
            .get("authorization")
            .map(|v| String::from_utf8_lossy(v.as_bytes()).into_owned())
            .unwrap_or_else(|| "(none)".into());
        self.0.lock().unwrap().push(auth);
        ResponseTemplate::new(200).set_body_raw(
            br#"{"id":"u1","username":"u1"}"#.to_vec(),
            "application/json",
        )
    }
}

/// One lane × cell → (outcome, code, message).
async fn residual_cell(lane: &'static str, status: u16, body: Vec<u8>) -> (String, String, String) {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(status).set_body_raw(body, "application/json"))
        .mount(&server)
        .await;
    let admin_seen = Arc::new(Mutex::new(Vec::new()));
    Mock::given(method("GET"))
        .and(wiremock::matchers::path(CELL_ADMIN_PATH))
        .respond_with(CellAdmin(admin_seen.clone()))
        .mount(&server)
        .await;
    let cfg = config(&server.uri(), Some(SECRET));
    let (outcome, code, message) = match KeycloakClient::new(cfg.clone()) {
        Err(e) => cell_error(&e),
        Ok(client) => {
            let auth: &AuthClient = client.auth();
            match lane {
                "client_credentials_token" => {
                    cell_token(auth.client_credentials_token().await, |t| {
                        t.access_token.clone()
                    })
                }
                "refresh" => cell_token(auth.refresh(REFRESH).await, |t| t.access_token.clone()),
                "exchange_code" => {
                    cell_token(auth.exchange_code(CODE, VERIFIER, None).await, |t| {
                        t.access_token.clone()
                    })
                }
                "introspect" => match auth.introspect(TOKEN).await {
                    Ok(r) => ("SUCCESS".into(), "-".into(), format!("active={}", r.active)),
                    Err(e) => cell_error(&e),
                },
                "AuthClient as TokenProvider" => {
                    cell_token(TokenProvider::access_token(auth).await, String::clone)
                }
                "ClientCredentialsTokenProvider" => cell_token(
                    ClientCredentialsTokenProvider::new(cfg.clone(), reqwest::Client::new())
                        .access_token()
                        .await,
                    String::clone,
                ),
                "admin" => {
                    let call = client.admin().get_user("u1").await;
                    let sent = admin_seen.lock().unwrap().first().cloned();
                    match (sent, call) {
                        (Some(header), call) => {
                            let call = match call {
                                Ok(_) => "ok".to_string(),
                                Err(e) => format!("{}: {e}", cell_variant(&e)),
                            };
                            let outcome = if header == "Bearer AT-ok" {
                                "SUCCESS"
                            } else {
                                "ADMIN_SENT_WITH_OTHER_AUTHORIZATION"
                            };
                            (
                                outcome.into(),
                                "-".into(),
                                format!("admin request sent, Authorization={header}; call={call}"),
                            )
                        }
                        (None, Err(e)) => cell_error(&e),
                        (None, Ok(_)) => (
                            "ADMIN_CALL_OK_WITHOUT_REQUEST".into(),
                            "-".into(),
                            String::new(),
                        ),
                    }
                }
                other => ("UNKNOWN_LANE".into(), "-".into(), other.to_string()),
            }
        }
    };
    (outcome, code, cell_text(&message))
}

/// The message with its status number named alike — (C) lets the message differ by it alone.
fn status_blind(message: &str, status: u16) -> String {
    message.replace(&format!("HTTP {status}"), "HTTP <status>")
}

/// Each cell of one lane that misses its target (A · B2 · C) — none means the lane meets them.
fn residual_wrong(lane: &str, rows: &HashMap<&str, (String, String, String)>) -> Vec<String> {
    let row = |cell: &str| rows.get(cell).cloned().unwrap_or_default();
    let shown = |r: &(String, String, String)| format!("{}|{}|{}", r.0, r.1, r.2);
    let mut wrong = Vec::new();
    // (A) the cells a token or introspection lane takes as success — no `error`, a null one, ""
    for cell in ["A0", "A5", "A6"] {
        if row(cell).0 != "SUCCESS" {
            wrong.push(format!(
                "{lane} {cell}: {} -- wants SUCCESS",
                shown(&row(cell))
            ));
        }
    }
    // (A) a 200 whose `error` is a number, an object, an array, a boolean — and (B) a duplicated string one
    for cell in ["A1", "A2", "A3", "A4", "B2"] {
        let (outcome, code, _) = row(cell);
        if outcome != "KeycloakError::Auth" || (cell != "B2" && code != "null") {
            wrong.push(format!(
                "{lane} {cell}: {} -- wants KeycloakError::Auth, no code",
                shown(&row(cell))
            ));
        }
    }
    for (created, refused) in [("C1", "C2"), ("C3", "C4")] {
        let (got, want) = (row(created), row(refused));
        if got.0 != want.0
            || got.1 != want.1
            || status_blind(&got.2, 201) != status_blind(&want.2, 400)
        {
            wrong.push(format!(
                "{lane} {created} {} != {refused} {}",
                shown(&got),
                shown(&want)
            ));
        }
    }
    wrong
}

/// What a bare reqwest client reads from the fake for a cell — status, Content-Type and whether the body bytes are the
/// ones the cell wrote.
async fn residual_probe(cell: &'static str, status: u16, body: Vec<u8>) -> Option<String> {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(status).set_body_raw(body.clone(), "application/json"))
        .mount(&server)
        .await;
    let url = format!("{}/realms/r/protocol/openid-connect/token", server.uri());
    let resp = reqwest::Client::new()
        .post(url)
        .send()
        .await
        .expect("the fake answers");
    let got_status = resp.status().as_u16();
    let same = resp
        .bytes()
        .await
        .is_ok_and(|got| got.as_ref() == body.as_slice());
    (got_status != status || !same).then(|| {
        format!(
            "fake {cell}: status {got_status}, bytes {}",
            if same { "equal" } else { "differ" }
        )
    })
}

#[tokio::test]
async fn residual_divergence_cells_meet_their_targets() {
    let mut wrong = Vec::new();
    // The instrument first: a bare reqwest client reads off the wire the exact status and bytes of every cell.
    for (cell, status, token_body, _) in residual_cells() {
        wrong.extend(residual_probe(cell, status, token_body).await);
    }
    // Only B5 prints — its outcome class and whether anything in the body was used, never a code or a message (the cells'
    // text is the assertion's message alone).
    let mut b5 = Vec::new();
    for lane in SURFACES {
        let mut rows = HashMap::new();
        for (cell, status, token_body, introspection_body) in residual_cells() {
            let body = if lane == "introspect" {
                introspection_body
            } else {
                token_body
            };
            // Its own task, so a panic in a lane is recorded as that cell's outcome instead of ending the run.
            let row = match tokio::spawn(residual_cell(lane, status, body)).await {
                Ok(row) => row,
                Err(join) => {
                    let why = match join.try_into_panic() {
                        Ok(payload) => payload
                            .downcast_ref::<&str>()
                            .map(|s| s.to_string())
                            .or_else(|| payload.downcast_ref::<String>().cloned())
                            .unwrap_or_else(|| "(non-string panic)".into()),
                        Err(join) => join.to_string(),
                    };
                    ("PANIC".to_string(), "-".to_string(), cell_text(&why))
                }
            };
            if cell == "B5" {
                let used = row.0 == "SUCCESS" || row.0 == "ADMIN_SENT_WITH_OTHER_AUTHORIZATION";
                b5.push(format!("B5|rust|{lane}|{}|used={used}", row.0));
            }
            rows.insert(cell, row);
        }
        wrong.extend(residual_wrong(lane, &rows));
    }
    println!("{}", b5.join("\n"));
    assert!(
        wrong.is_empty(),
        "{} cells:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}
