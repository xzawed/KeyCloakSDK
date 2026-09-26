//! 브라우저 없는 로그인 — 실제 Keycloak 로그인 폼을 HTTP 로 채워 인가 코드를 받는다.
//! python `tests/integration/browser_login.py` 의 rust 판이고, 모양이 같다.
//!
//! 세 걸음이다:
//!
//! 1. SDK 가 만든 인가 URL 을 GET 한다(로그인 페이지 + 인증 세션 쿠키 — 쿠키는 2 에서 직접 되싣는다).
//! 2. `<form id="kc-form-login">` 의 `action` 에 사용자명·비밀번호를 POST 하되 **리다이렉트는 따라가지
//!    않는다** — redirect_uri 에는 아무것도 떠 있지 않다. 302 의 `Location` 이 곧 콜백이다.
//! 3. `Location` 에서 `code`·`state` 를 꺼내고, `state` 가 SDK 가 발급한 값인지 확인한다.
//!
//! 폼을 못 찾거나 상태 코드가 틀리면 받은 HTML 앞부분을 실어 실패한다 — 테마가 바뀌었을 때 원인이
//! 바로 보이게. `tests/` 의 하위 디렉터리라 cargo 가 따로 테스트 타깃으로 만들지 않는다.

use keycloak_sdk::AuthorizationRequest;
use keycloak_sdk::reqwest;
use reqwest::StatusCode;
use reqwest::header::{COOKIE, LOCATION, SET_COOKIE};
use std::time::Duration;

const LOGIN_FORM_ID: &str = "kc-form-login";

fn snippet(status: StatusCode, url: &str, body: &str) -> String {
    let head: String = body.chars().take(1500).collect();
    format!("HTTP {status} {url}\n{head}")
}

/// `request`(SDK 의 `create_authorization_request*` 결과)로 로그인해 인가 코드를 돌려준다.
pub async fn browser_login(
    request: &AuthorizationRequest,
    redirect_uri: &str,
    username: &str,
    password: &str,
) -> String {
    let browser = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(30))
        .build()
        .expect("browser http client");

    let page = browser
        .get(&request.url)
        .send()
        .await
        .expect("GET the authorization URL");
    let (status, url) = (page.status(), page.url().to_string());
    // ⚠️ 쿠키 저장소에 맡기지 말고 **직접 되싣는다.** Keycloak 26 은 http 에서도 로그인 쿠키에
    // `Secure` 를 단다. 브라우저는 localhost 를 안전한 출처로 봐서 보내지만, RFC 6265 대로 사는
    // 저장소는 http 요청에 싣지 않아 POST 가 400 "Restart login cookie not found" 로 끝난다
    // (python 파일럿 실측). 그래서 `cookies` 기능도 켜지 않고 `Set-Cookie` 의 `이름=값` 만 옮긴다.
    let cookie = page
        .headers()
        .get_all(SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .filter_map(|v| v.split(';').next())
        .map(str::trim)
        .filter(|pair| {
            pair.split_once('=')
                .is_some_and(|(name, value)| !name.is_empty() && !value.is_empty())
        })
        .collect::<Vec<_>>()
        .join("; ");
    let html = page.text().await.expect("login page body");
    if status != StatusCode::OK {
        panic!(
            "login page did not render:\n{}",
            snippet(status, &url, &html)
        );
    }
    let Some(action) = login_form_action(&html) else {
        panic!(
            "no <form id=\"{LOGIN_FORM_ID}\"> in the login page:\n{}",
            snippet(status, &url, &html)
        );
    };

    let answer = browser
        .post(&action)
        .header(COOKIE, cookie)
        .form(&[("username", username), ("password", password)])
        .send()
        .await
        .expect("POST the login form");
    let (status, url) = (answer.status(), answer.url().to_string());
    if status != StatusCode::FOUND {
        let body = answer.text().await.unwrap_or_default();
        panic!(
            "login POST did not redirect:\n{}",
            snippet(status, &url, &body)
        );
    }
    let location = answer
        .headers()
        .get(LOCATION)
        .and_then(|v| v.to_str().ok())
        .expect("302 without a Location header")
        .to_string();

    let callback = url::Url::parse(&location)
        .unwrap_or_else(|e| panic!("Location is not an absolute URL ({e}): {location}"));
    let mut target = callback.clone();
    target.set_query(None);
    target.set_fragment(None);
    let expected = url::Url::parse(redirect_uri).expect("redirect_uri is a URL");
    if target != expected {
        panic!("login redirected somewhere else: {location}");
    }
    let param = |name: &str| -> Vec<String> {
        callback
            .query_pairs()
            .filter(|(key, _)| key == name)
            .map(|(_, value)| value.into_owned())
            .collect()
    };
    // state 는 SDK 가 인가 URL 에 실은 CSRF 값이다 — 서버가 그대로 되돌려야 한다.
    let state = param("state");
    if state != [request.state.as_str()] {
        panic!("state mismatch: sent {:?}, got {state:?}", request.state);
    }
    match param("code").as_slice() {
        [code] if !code.is_empty() => code.clone(),
        _ => panic!("no single authorization code in the callback: {location}"),
    }
}

/// `<form id="kc-form-login">` 의 action — 속성 값의 문자 참조(`&amp;` 등)는 푼다.
fn login_form_action(html: &str) -> Option<String> {
    // ⚠️ ASCII 소문자화는 바이트 길이를 바꾸지 않는다 — 소문자판의 색인을 원문에 그대로 쓴다.
    let lower = html.to_ascii_lowercase();
    let mut from = 0;
    while let Some(found) = lower[from..].find("<form") {
        let start = from + found + "<form".len();
        from = start;
        if !lower[start..].starts_with(|c: char| c.is_ascii_whitespace() || c == '>') {
            continue; // `<formx` 같은 다른 태그
        }
        let attributes = tag_attributes(&html[start..]);
        if attributes
            .iter()
            .any(|(name, value)| name == "id" && value == LOGIN_FORM_ID)
        {
            return attributes
                .into_iter()
                .find(|(name, _)| name == "action")
                .map(|(_, value)| value);
        }
    }
    None
}

/// 여는 태그의 이름 뒤부터 `>` 까지의 속성들(이름은 소문자, 값은 문자 참조를 푼 것).
fn tag_attributes(mut rest: &str) -> Vec<(String, String)> {
    let mut attributes = Vec::new();
    loop {
        rest = rest.trim_start();
        let Some(first) = rest.chars().next() else {
            break;
        };
        if first == '>' || rest.starts_with("/>") {
            break;
        }
        let name_end = rest
            .find(|c: char| c.is_whitespace() || matches!(c, '=' | '>' | '/'))
            .unwrap_or(rest.len());
        if name_end == 0 {
            rest = &rest[first.len_utf8()..]; // 떠도는 `/`·`=` — 한 글자 넘긴다
            continue;
        }
        let name = rest[..name_end].to_ascii_lowercase();
        rest = rest[name_end..].trim_start();
        let mut value = String::new();
        if let Some(after) = rest.strip_prefix('=') {
            let after = after.trim_start();
            let (raw, remaining) = match after.chars().next() {
                Some(quote @ ('"' | '\'')) => {
                    let body = &after[1..];
                    let end = body.find(quote).unwrap_or(body.len());
                    (&body[..end], body.get(end + 1..).unwrap_or(""))
                }
                _ => {
                    let end = after
                        .find(|c: char| c.is_whitespace() || c == '>')
                        .unwrap_or(after.len());
                    (&after[..end], &after[end..])
                }
            };
            value = unescape(raw);
            rest = remaining;
        }
        attributes.push((name, value));
    }
    attributes
}

/// HTML 문자 참조 — 이름 있는 다섯과 숫자 참조(`&#38;`·`&#x26;`)를 푼다. 모르는 것은 그대로 둔다.
fn unescape(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        let decoded = rest.find(';').and_then(|end| {
            let entity = &rest[1..end];
            let ch = match entity {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                _ => entity
                    .strip_prefix("#x")
                    .or_else(|| entity.strip_prefix("#X"))
                    .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                    .or_else(|| entity.strip_prefix('#').and_then(|dec| dec.parse().ok()))
                    .and_then(char::from_u32),
            };
            ch.map(|c| (c, end))
        });
        match decoded {
            Some((c, end)) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}
