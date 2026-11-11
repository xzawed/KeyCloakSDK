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
use wiremock::matchers::method;
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

const SECRET: &str = "echoedlowersecret"; // code-shaped on purpose: the shape alone cannot withhold it
const REFRESH: &str = "echoedlowerrefresh";
const TOKEN: &str = "echoedlowerintrospected";
const CODE: &str = "echoedlowercode";
const VERIFIER: &str = "echoedlowerverifierechoedlowerverifierechoedlower";

type Sent = HashMap<String, String>;
type EchoFn = Arc<dyn Fn(&Sent) -> serde_json::Value + Send + Sync>;

/// Answers every POST with 400 `{"error": …}` — `fixed`, or built by `echo` from what the request sent (the form, with
/// the client secret from Basic when it came that way). Records each request's sent values.
#[derive(Clone)]
struct EchoIdp {
    fixed: serde_json::Value,
    echo: Option<EchoFn>,
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
        ResponseTemplate::new(400).set_body_json(serde_json::json!({ "error": error }))
    }
}

struct Run {
    server: MockServer,
    seen: Arc<Mutex<Vec<Sent>>>,
}

async fn idp(fixed: serde_json::Value, echo: Option<EchoFn>) -> Run {
    let server = MockServer::start().await;
    let seen = Arc::new(Mutex::new(Vec::new()));
    Mock::given(method("POST"))
        .respond_with(EchoIdp {
            fixed,
            echo,
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
    let client = KeycloakClient::new(cfg.clone()).expect("client");
    let auth: &AuthClient = client.auth();
    let outcome = match surface {
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
    };
    outcome.expect_err(surface)
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
const ECHO_FORMS: [(&str, Shape); 3] = [
    ("whole", |v| v.to_string()),
    ("truncated", |v| v[..11].to_string()),
    ("extended", |v| format!("{v}_x")),
];

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
