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
            ClientCredentialsTokenProvider::new(cfg.clone(), reqwest::Client::new())
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
// field "at any status"; that was measured at 400 · 401 (#1199) and the other 2xx (#1207) only. 5xx: pinned as the
// contract reads. 302 (`Location` on this server): recorded, not pinned — the 3xx contract is open; only "never followed"
// is asserted.
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
async fn a_redirect_error_status_to_this_server_is_recorded_and_never_followed() {
    let mut wrong = Vec::new();
    for surface in SURFACES {
        let c = error_status_cell(surface, 302, B5, true).await;
        println!("{}", c.line);
        if c.requests
            .iter()
            .any(|r| r.ends_with(&format!(" {REDIRECT_TARGET}")))
        {
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
