//! MEASUREMENT ONLY — scratch file, not for commit (registry `rust-lowlevel-ctor-redirect-policy`).
//!
//! The four low-level ctors that take a consumer `reqwest::Client` — `ClientCredentialsTokenProvider::new`,
//! `AuthClient::new`, `AdminClient::new`, `JwksStore::new` — are given `reqwest::Client::new()` (reqwest's default
//! policy: follow, up to 10 hops). The origin answers the SDK's request with 302 · 303 · 307 · 308 whose `Location`
//! points at `/moved<same path>` either on the same server (same origin, different path) or on a second `MockServer`
//! (another port = cross origin). The target answers every request with a usable success body, so `result` shows what
//! the SDK does with an answer that came from the redirect target.
//! Controls: the same cells through `KeycloakClient::new(config)` (the SDK's own client — `Policy::none()`).
//! Extra row: `AdminClient::update_user` (PUT + JSON) — tower-http rewrites only POST on 301/302.
//!
//! Run: `cargo test --test zz_redirect_measure -- --nocapture`
use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use keycloak_sdk::jwks::JwksStore;
use keycloak_sdk::types::UserRepresentation;
use keycloak_sdk::{
    AdminClient, AuthClient, ClientCredentialsTokenProvider, JwtValidator, KeycloakClient,
    KeycloakConfig, KeycloakError, OidcEndpoints, TokenProvider, reqwest,
};
use std::sync::Arc;
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

const REALM: &str = "it-realm";
const CLIENT_ID: &str = "it-client";
const SECRET: &str = "CLIENT-SECRET-MARK";
const REFRESH: &str = "REFRESH-TOKEN-MARK";
const INTROSPECTED: &str = "INTROSPECTED-TOKEN-MARK";
const ADMIN_BEARER: &str = "ADMIN-BEARER-MARK";
const ADMIN_USER: &str = "admin-json-body-mark";
const STATUSES: [u16; 4] = [302, 303, 307, 308];
/// RFC 7517 A.1's example RSA key under kid `k1` — `get_key` does not build a DecodingKey, it only finds the kid.
const JWKS: &str = r#"{"keys":[{"kty":"RSA","kid":"k1","use":"sig","alg":"RS256","e":"AQAB","n":"0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw"}]}"#;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Op {
    ProviderCc,
    AuthCc,
    AuthRefresh,
    AuthIntrospect,
    AdminGet,
    AdminPost,
    AdminPut,
    Jwks,
}

const OPS: [Op; 8] = [
    Op::ProviderCc,
    Op::AuthCc,
    Op::AuthRefresh,
    Op::AuthIntrospect,
    Op::AdminGet,
    Op::AdminPost,
    Op::AdminPut,
    Op::Jwks,
];

impl Op {
    fn ctor(self) -> &'static str {
        match self {
            Op::ProviderCc => "ClientCredentialsTokenProvider::new",
            Op::AuthCc | Op::AuthRefresh | Op::AuthIntrospect => "AuthClient::new",
            Op::AdminGet | Op::AdminPost | Op::AdminPut => "AdminClient::new",
            Op::Jwks => "JwksStore::new",
        }
    }
    /// The call made on the low-level instance.
    fn name(self) -> &'static str {
        match self {
            Op::ProviderCc => "access_token(POST form)",
            Op::AuthCc => "client_credentials_token(POST form)",
            Op::AuthRefresh => "refresh(POST form)",
            Op::AuthIntrospect => "introspect(POST form)",
            Op::AdminGet => "get_realm(GET)",
            Op::AdminPost => "create_user(POST json)",
            Op::AdminPut => "update_user(PUT json)[extra]",
            Op::Jwks => "get_key(GET)",
        }
    }
    /// The control call through `KeycloakClient` that issues the same request.
    fn sdk_name(self) -> &'static str {
        match self {
            Op::ProviderCc => "admin().get_realm->provider grant(POST form)",
            Op::AuthCc => "auth().client_credentials_token(POST form)",
            Op::AuthRefresh => "auth().refresh(POST form)",
            Op::AuthIntrospect => "auth().introspect(POST form)",
            Op::AdminGet => "admin().get_realm(GET)",
            Op::AdminPost => "admin().create_user(POST json)",
            Op::AdminPut => "admin().update_user(PUT json)[extra]",
            Op::Jwks => "auth().validate->JWKS fetch(GET)",
        }
    }
    /// The origin path the SDK requests — this one answers with the 3xx.
    fn origin_path(self) -> String {
        let oidc = format!("/realms/{REALM}/protocol/openid-connect");
        match self {
            Op::ProviderCc | Op::AuthCc | Op::AuthRefresh => format!("{oidc}/token"),
            Op::AuthIntrospect => format!("{oidc}/token/introspect"),
            Op::AdminGet => format!("/admin/realms/{REALM}"),
            Op::AdminPost => format!("/admin/realms/{REALM}/users"),
            Op::AdminPut => format!("/admin/realms/{REALM}/users/u1"),
            Op::Jwks => format!("{oidc}/certs"),
        }
    }
}

/// A consumer-injected provider — always the same Bearer, so the admin cells isolate the admin request.
struct Fixed;

#[async_trait]
impl TokenProvider for Fixed {
    async fn access_token(&self) -> Result<String, KeycloakError> {
        Ok(ADMIN_BEARER.to_string())
    }
}

/// The redirect target — a usable success answer for every request it gets, whatever the method.
struct Target(Op);

impl Respond for Target {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let json = |status: u16, body: &str| {
            ResponseTemplate::new(status).set_body_raw(body.to_string(), "application/json")
        };
        match self.0 {
            Op::ProviderCc | Op::AuthCc | Op::AuthRefresh => json(
                200,
                r#"{"access_token":"TARGET-AT","token_type":"Bearer","expires_in":300,"refresh_token":"TARGET-RT"}"#,
            ),
            Op::AuthIntrospect => json(
                200,
                r#"{"active":true,"username":"target-user","client_id":"target-client"}"#,
            ),
            Op::AdminGet => json(200, r#"{"realm":"target-realm"}"#),
            // A real collection answers a GET with a list and a POST with 201 + Location.
            Op::AdminPost if req.method.as_str() == "POST" => ResponseTemplate::new(201)
                .insert_header("Location", format!("{}/target-id", req.url)),
            Op::AdminPost => json(200, "[]"),
            Op::AdminPut => ResponseTemplate::new(204),
            Op::Jwks => json(200, JWKS),
        }
    }
}

fn config(origin: &str) -> KeycloakConfig {
    KeycloakConfig::new(origin, REALM, CLIENT_ID)
        .expect("config")
        .with_client_secret(SECRET)
}

fn user() -> UserRepresentation {
    UserRepresentation {
        username: Some(ADMIN_USER.into()),
        ..Default::default()
    }
}

/// A JWT whose header names kid `k1` — enough for `validate` to reach the JWKS fetch.
fn kid_token() -> String {
    let h = URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256","kid":"k1","typ":"JWT"}"#);
    let p = URL_SAFE_NO_PAD.encode(br#"{"sub":"x","typ":"Bearer"}"#);
    format!("{h}.{p}.c2ln")
}

fn clean(s: String) -> String {
    s.replace('|', "/").replace('\n', " ")
}

fn err_str(e: &KeycloakError) -> String {
    let variant = match e {
        KeycloakError::Config(_) => "Config",
        KeycloakError::Auth { .. } => "Auth",
        KeycloakError::Transport(_) => "Transport",
        KeycloakError::Admin(_) => "Admin",
        KeycloakError::TokenValidation(_) => "TokenValidation",
        _ => "Other",
    };
    let code = match e {
        KeycloakError::Auth { oauth_error, .. } => format!(" oauth_error={oauth_error:?}"),
        _ => String::new(),
    };
    clean(format!("Err({variant}: {e}{code})"))
}

fn ok_or<T>(r: Result<T, KeycloakError>, f: impl FnOnce(&T) -> String) -> String {
    match r {
        Ok(v) => clean(format!("Ok({})", f(&v))),
        Err(e) => err_str(&e),
    }
}

async fn admin_call(admin: &AdminClient, op: Op) -> String {
    match op {
        Op::AdminGet => ok_or(admin.get_realm().await, |r| format!("realm={:?}", r.realm)),
        Op::AdminPost => ok_or(admin.create_user(user()).await, |id| {
            format!("created_id={id:?}")
        }),
        Op::AdminPut => ok_or(admin.update_user("u1", user()).await, |_| "()".into()),
        other => unreachable!("{other:?}"),
    }
}

/// The low-level ctor given the consumer's client.
async fn call_lowlevel(op: Op, cfg: &KeycloakConfig, http: reqwest::Client) -> String {
    match op {
        Op::ProviderCc => ok_or(
            ClientCredentialsTokenProvider::new(cfg.clone(), http)
                .access_token()
                .await,
            |t| format!("access_token={t}"),
        ),
        Op::AuthCc | Op::AuthRefresh | Op::AuthIntrospect => {
            let endpoints = OidcEndpoints::new(cfg);
            let jwks = JwksStore::new(endpoints.jwks(), http.clone(), 30);
            let validator = JwtValidator::new(cfg, &endpoints, jwks).expect("validator");
            let auth = AuthClient::new(cfg.clone(), OidcEndpoints::new(cfg), http, validator)
                .expect("auth");
            match op {
                Op::AuthCc => ok_or(auth.client_credentials_token().await, |t| {
                    format!("access_token={}", t.access_token)
                }),
                Op::AuthRefresh => ok_or(auth.refresh(REFRESH).await, |t| {
                    format!("access_token={}", t.access_token)
                }),
                _ => ok_or(auth.introspect(INTROSPECTED).await, |r| {
                    format!("active={} username={:?}", r.active, r.username)
                }),
            }
        }
        Op::AdminGet | Op::AdminPost | Op::AdminPut => {
            let admin = AdminClient::new(cfg, http, Arc::new(Fixed));
            admin_call(&admin, op).await
        }
        Op::Jwks => {
            let store = JwksStore::new(OidcEndpoints::new(cfg).jwks(), http, 30);
            ok_or(store.get_key("k1").await, |k| {
                format!("kid={:?}", k.common.key_id)
            })
        }
    }
}

/// The control — the same request through the SDK's own path.
async fn call_sdk(op: Op, cfg: &KeycloakConfig) -> String {
    let client = KeycloakClient::new(cfg.clone()).expect("client");
    match op {
        Op::ProviderCc => ok_or(client.admin().get_realm().await, |r| {
            format!("realm={:?}", r.realm)
        }),
        Op::AuthCc => ok_or(client.auth().client_credentials_token().await, |t| {
            format!("access_token={}", t.access_token)
        }),
        Op::AuthRefresh => ok_or(client.auth().refresh(REFRESH).await, |t| {
            format!("access_token={}", t.access_token)
        }),
        Op::AuthIntrospect => ok_or(client.auth().introspect(INTROSPECTED).await, |r| {
            format!("active={} username={:?}", r.active, r.username)
        }),
        Op::AdminGet | Op::AdminPost | Op::AdminPut => admin_call(client.admin(), op).await,
        Op::Jwks => ok_or(client.auth().validate(&kid_token()).await, |v| {
            format!("validated sub={}", v.subject)
        }),
    }
}

async fn requests(server: &MockServer, keep: impl Fn(&str) -> bool) -> Vec<Request> {
    server
        .received_requests()
        .await
        .unwrap_or_default()
        .into_iter()
        .filter(|r| keep(r.url.path()))
        .collect()
}

fn auth_of(req: &Request) -> String {
    let Some(v) = req
        .headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
    else {
        return "none".into();
    };
    if let Some(b64) = v.strip_prefix("Basic ") {
        let decoded = STANDARD
            .decode(b64)
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
            .unwrap_or_default();
        return if decoded == format!("{CLIENT_ID}:{SECRET}") {
            "Basic(client_id:client_secret)".into()
        } else {
            format!("Basic({decoded})")
        };
    }
    if v == format!("Bearer {ADMIN_BEARER}") {
        return "Bearer(admin-token)".into();
    }
    format!("other({v})")
}

fn body_secret_of(req: &Request) -> String {
    if req.body.is_empty() {
        return "no-body".into();
    }
    let b = String::from_utf8_lossy(&req.body);
    let mut marks = Vec::new();
    if b.contains(&format!("client_secret={SECRET}")) {
        marks.push("client_secret");
    }
    if b.contains(&format!("refresh_token={REFRESH}")) {
        marks.push("refresh_token");
    }
    if b.contains(&format!("token={INTROSPECTED}")) {
        marks.push("introspected_token");
    }
    if b.contains(ADMIN_USER) {
        marks.push("admin_json");
    }
    if marks.is_empty() {
        "none".into()
    } else {
        marks.join("+")
    }
}

fn body_of(req: &Request) -> String {
    if req.body.is_empty() {
        return "0B".into();
    }
    let b = String::from_utf8_lossy(&req.body);
    let keys = if b.starts_with('{') {
        "json".to_string()
    } else {
        b.split('&')
            .map(|kv| kv.split('=').next().unwrap_or(""))
            .collect::<Vec<_>>()
            .join(",")
    };
    format!("{}B[{keys}]", req.body.len())
}

fn header_of(req: &Request, name: &str) -> String {
    req.headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map_or_else(|| "none".to_string(), str::to_string)
}

fn hop_of(req: &Request) -> String {
    format!(
        "{} auth={} body_secret={}",
        req.method,
        auth_of(req),
        body_secret_of(req)
    )
}

fn each(reqs: &[Request], f: impl Fn(&Request) -> String) -> String {
    if reqs.is_empty() {
        "-".into()
    } else {
        reqs.iter().map(f).collect::<Vec<_>>().join(",")
    }
}

async fn cell(op: Op, status: u16, cross: bool, sdk_path: bool) -> String {
    let origin = MockServer::start().await;
    let other = MockServer::start().await;
    let target_srv = if cross { &other } else { &origin };
    let opath = op.origin_path();
    let location = format!("{}/moved{opath}", target_srv.uri());
    Mock::given(path(opath.clone()))
        .respond_with(ResponseTemplate::new(status).insert_header("Location", location.as_str()))
        .mount(&origin)
        .await;
    Mock::given(path_regex("^/moved/"))
        .respond_with(Target(op))
        .mount(target_srv)
        .await;
    let cfg = config(&origin.uri());
    let result = if sdk_path {
        match op {
            // The SDK path's admin needs its provider's grant first — the token endpoint answers it.
            Op::AdminGet | Op::AdminPost | Op::AdminPut => {
                Mock::given(method("POST"))
                    .and(path(Op::ProviderCc.origin_path()))
                    .respond_with(ResponseTemplate::new(200).set_body_raw(
                        format!(
                            r#"{{"access_token":"{ADMIN_BEARER}","token_type":"Bearer","expires_in":300}}"#
                        ),
                        "application/json",
                    ))
                    .mount(&origin)
                    .await;
            }
            // The provider row redirects the grant; the admin GET it precedes would answer here.
            Op::ProviderCc => {
                Mock::given(method("GET"))
                    .and(path(Op::AdminGet.origin_path()))
                    .respond_with(
                        ResponseTemplate::new(200)
                            .set_body_raw(r#"{"realm":"origin-realm"}"#, "application/json"),
                    )
                    .mount(&origin)
                    .await;
            }
            _ => {}
        }
        call_sdk(op, &cfg).await
    } else {
        call_lowlevel(op, &cfg, reqwest::Client::new()).await
    };
    let first = requests(&origin, |p| p == opath).await;
    let moved = requests(target_srv, |p| p.starts_with("/moved/")).await;
    let (ctor, name) = if sdk_path {
        ("KeycloakClient::new(control)", op.sdk_name())
    } else {
        (op.ctor(), op.name())
    };
    format!(
        "CELL|{ctor}|{name}|{status}|{}|followed={}|method={}|body_secret={}|auth={}|result={result}|body={}|ctype={}|referer={}|origin_hop={}|hits=origin:{}/target:{}",
        if cross { "cross-origin" } else { "same-origin" },
        if moved.is_empty() { "no" } else { "yes" },
        each(&moved, |r| r.method.to_string()),
        each(&moved, body_secret_of),
        each(&moved, auth_of),
        each(&moved, body_of),
        each(&moved, |r| header_of(r, "content-type")),
        each(&moved, |r| header_of(r, "referer")),
        each(&first, hop_of),
        first.len(),
        moved.len(),
    )
}

/// After the fact: one hop to another origin — does `Response::url()` differ from the request URL?
async fn detect_single(status: u16) -> String {
    let origin = MockServer::start().await;
    let other = MockServer::start().await;
    Mock::given(path("/start"))
        .respond_with(
            ResponseTemplate::new(status)
                .insert_header("Location", format!("{}/moved/start", other.uri())),
        )
        .mount(&origin)
        .await;
    Mock::given(path("/moved/start"))
        .respond_with(ResponseTemplate::new(200))
        .mount(&other)
        .await;
    let url = format!("{}/start", origin.uri());
    let resp = reqwest::Client::new()
        .post(&url)
        .form(&[("client_secret", SECRET)])
        .send()
        .await
        .expect("send");
    let moved = requests(&other, |p| p == "/moved/start").await;
    format!(
        "DETECT|single hop {status} A->B|request_url={url}|response.url()={}|status={}|url_differs={}|B_got={}",
        resp.url(),
        resp.status().as_u16(),
        resp.url().as_str() != url,
        each(&moved, hop_of)
    )
}

/// After the fact: A 307 -> B 307 -> A (A answers 200 the second time). The final URL equals the request URL, yet B
/// received the body.
async fn detect_bounce() -> String {
    let origin = MockServer::start().await;
    let other = MockServer::start().await;
    Mock::given(path("/token"))
        .respond_with(
            ResponseTemplate::new(307).insert_header("Location", format!("{}/hop", other.uri())),
        )
        .up_to_n_times(1)
        .with_priority(1)
        .mount(&origin)
        .await;
    Mock::given(path("/token"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(
            r#"{"access_token":"AT","token_type":"Bearer"}"#,
            "application/json",
        ))
        .with_priority(2)
        .mount(&origin)
        .await;
    Mock::given(path("/hop"))
        .respond_with(
            ResponseTemplate::new(307).insert_header("Location", format!("{}/token", origin.uri())),
        )
        .mount(&other)
        .await;
    let url = format!("{}/token", origin.uri());
    let resp = reqwest::Client::new()
        .post(&url)
        .form(&[("client_secret", SECRET)])
        .send()
        .await
        .expect("send");
    let hop = requests(&other, |p| p == "/hop").await;
    let at_origin = requests(&origin, |p| p == "/token").await.len();
    format!(
        "DETECT|bounce A-307->B-307->A|request_url={url}|response.url()={}|status={}|url_differs={}|B_got={}|A_hits={at_origin}",
        resp.url(),
        resp.status().as_u16(),
        resp.url().as_str() != url,
        each(&hop, hop_of)
    )
}

fn api_lines() -> Vec<String> {
    let build = |p: reqwest::redirect::Policy| {
        reqwest::Client::builder()
            .redirect(p)
            .build()
            .expect("client")
    };
    vec![
        format!("API|Debug(Client::new())={:?}", reqwest::Client::new()),
        format!(
            "API|Debug(builder.redirect(Policy::none()))={:?}",
            build(reqwest::redirect::Policy::none())
        ),
        format!(
            "API|Debug(builder.redirect(Policy::limited(10)))={:?}",
            build(reqwest::redirect::Policy::limited(10))
        ),
        format!(
            "API|Debug(builder.redirect(Policy::limited(3)))={:?}",
            build(reqwest::redirect::Policy::limited(3))
        ),
    ]
}

#[tokio::test]
async fn zz_redirect_measure() {
    println!(
        "HEADER|ctor|op|status|target|followed|method@target|body_secret@target|auth@target|result|body@target|content-type@target|referer@target|origin_hop|hits"
    );
    let mut followed = [0usize; 2];
    for sdk_path in [false, true] {
        for op in OPS {
            for status in STATUSES {
                for cross in [false, true] {
                    let line = cell(op, status, cross, sdk_path).await;
                    if line.contains("|followed=yes|") {
                        followed[usize::from(sdk_path)] += 1;
                    }
                    println!("{line}");
                }
            }
        }
    }
    println!(
        "SUMMARY|lowlevel followed {}/{} cells|controls followed {}/{} cells",
        followed[0],
        OPS.len() * STATUSES.len() * 2,
        followed[1],
        OPS.len() * STATUSES.len() * 2
    );
    for status in STATUSES {
        println!("{}", detect_single(status).await);
    }
    println!("{}", detect_bounce().await);
    for line in api_lines() {
        println!("{line}");
    }
}
