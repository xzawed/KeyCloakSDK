//! 형식이 틀리거나 적대적인 토큰·introspect 응답에서 난 SDK 오류가 **응답이 품은 토큰과 호출 인자로
//! 넘긴 비밀을 찍지 않는다** — node #603 의 rust 판. `facade_dump.rs` 가 정상 응답으로 만든 뿌리를
//! 걷는다면, 여기는 IdP 가 틀린 응답을 줄 때 나는 오류만 본다.
//!
//! 가짜 IdP 하나가 변형마다 realm 하나를 갖고, 그 realm 의 token·introspect 엔드포인트가 **같은 본문**을
//! 준다(refresh·코드 교환도 token 엔드포인트라 같은 모양을 받는다). 공개 인증 호출 전부를 변형마다 부른다.
//!
//! 찍는 경로 넷: `{e}` · `{e:?}` · `{e:#?}` · 로거가 찍는 `source()` 사슬(고리마다 `{}`, `": "` 로 잇는다).
//! 판정: 카나리아 원문, 또는 **그 카나리아에만 있는** 10자 조각(앞 10자 = 접두 노출 포함).
//!
//! ⚠️ 흐름 검사가 먼저다 — 변형이 호출을 실제로 실패시키지 않으면(가짜 IdP 가 정상 응답을 주면) 누출 검사는
//! 없는 오류를 찾으며 통과한다. 그래서 (변형, 호출) 마다 결과 분류를 못박는다.
//!
//! 변형·기대 분류표·판정기는 `hostile_variants` 모듈이 소유한다 — `hostile_path_matrix.rs` 가 같은 변형을
//! 계급(토큰 부여·코드 교환) 행 전부에 붙이므로 둘이 한 사본을 쓴다.

mod hostile_variants;

use hostile_variants::{
    CALLS, CLIENT_ID, EXPECTED, NONCE, Variant, WINDOW, hits, public_jwk, renders, unique_windows,
    variants,
};
use keycloak_sdk::{
    AdminError, AuthClient, ClientCredentialsTokenProvider, KeycloakClient, KeycloakConfig,
    KeycloakError, TokenProvider, reqwest,
};
use serde_json::json;
use std::collections::BTreeSet;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── 카나리아 ─────────────────────────────────────────────────────────────────────────────
// 대문자·하이픈으로 짓는다 — realm 이름·URL·오류 문구(소문자)의 조각과 겹치면 안 된다.

/// 호출 인자·설정으로 흘려 넣는 비밀. 오류가 **요청**을 품으면 여기서 샌다.
const SECRET: &str = "CLIENT-SECRET-CANARY-HOSTILE";
const RT_ARG: &str = "REFRESH-ARG-CANARY-HOSTILE";
const INTROSPECT_ARG: &str = "INTROSPECT-ARG-CANARY-HOSTILE";
const CODE_ARG: &str = "AUTHCODE-ARG-CANARY-HOSTILE";
const VERIFIER_ARG: &str = "PKCE-VERIFIER-ARG-CANARY-HOSTILE-0123456789-abcdefghijk";

/// 알려진 누출 — `"realm|호출|카나리아"` → 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**.
const KNOWN_LEAKS: &[(&str, &str)] = &[];

async fn mount(server: &MockServer, v: &Variant, jwk: &serde_json::Value) {
    let oidc = format!("/realms/{}/protocol/openid-connect", v.realm);
    let hostile = ResponseTemplate::new(v.status)
        .set_body_raw(v.body.clone().into_bytes(), v.content_type.as_str());
    for p in [format!("{oidc}/token"), format!("{oidc}/token/introspect")] {
        Mock::given(method("POST"))
            .and(path(p))
            .respond_with(hostile.clone())
            .mount(server)
            .await;
    }
    Mock::given(method("GET"))
        .and(path(format!("{oidc}/certs")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"keys": [jwk]})))
        .mount(server)
        .await;
    // provider 가 토큰을 얻으면 admin 호출은 성공한다 — 실패는 토큰 경로에서만 나야 한다.
    Mock::given(method("GET"))
        .and(path(format!("/admin/realms/{}/users/u", v.realm)))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id": "u"})))
        .mount(server)
        .await;
}

type Outcome = std::result::Result<(), KeycloakError>;

/// token·introspect 엔드포인트를 치는 공개 인증 호출 전부.
async fn drive(cfg: &KeycloakConfig) -> Vec<(&'static str, Outcome)> {
    let client = KeycloakClient::new(cfg.clone()).expect("client");
    let auth: &AuthClient = client.auth();
    let provider = ClientCredentialsTokenProvider::new(cfg.clone(), reqwest::Client::new());
    vec![
        (
            "client_credentials_token",
            auth.client_credentials_token().await.map(|_| ()),
        ),
        ("refresh", auth.refresh(RT_ARG).await.map(|_| ())),
        (
            "exchange_code(nonce=None)",
            auth.exchange_code(CODE_ARG, VERIFIER_ARG, None)
                .await
                .map(|_| ()),
        ),
        (
            "exchange_code(nonce=Some)",
            auth.exchange_code(CODE_ARG, VERIFIER_ARG, Some(NONCE))
                .await
                .map(|_| ()),
        ),
        (
            "exchange_code_with_redirect",
            auth.exchange_code_with_redirect(
                CODE_ARG,
                VERIFIER_ARG,
                "https://app.example/cb2",
                Some(NONCE),
            )
            .await
            .map(|_| ()),
        ),
        (
            "introspect",
            auth.introspect(INTROSPECT_ARG).await.map(|_| ()),
        ),
        (
            "AuthClient as TokenProvider",
            TokenProvider::access_token(auth).await.map(|_| ()),
        ),
        (
            "ClientCredentialsTokenProvider",
            provider.access_token().await.map(|_| ()),
        ),
        (
            "admin get_user (default provider)",
            client.admin().get_user("u").await.map(|_| ()),
        ),
    ]
}

/// 결과 분류 — 흐름 검사가 못박는 것. oauth_error 는 따로 본다(수정 대상이다).
fn kind(r: &Outcome) -> String {
    match r {
        Ok(()) => "ok".into(),
        Err(KeycloakError::Auth { .. }) => "Auth".into(),
        Err(KeycloakError::Transport(_)) => "Transport".into(),
        Err(KeycloakError::TokenValidation(_)) => "TokenValidation".into(),
        Err(KeycloakError::Config(_)) => "Config".into(),
        Err(KeycloakError::Admin(AdminError::Other { status })) => format!("Admin({status})"),
        Err(KeycloakError::Admin(a)) => format!("Admin({a:?})"),
        Err(other) => format!("unexpected {other:?}"),
    }
}

#[tokio::test]
async fn hostile_token_responses_fail_as_classified_and_errors_do_not_render_tokens() {
    let server = MockServer::start().await;
    let jwk = public_jwk();
    let vs = variants(&server.uri());
    for v in &vs {
        mount(&server, v, &jwk).await;
    }

    let mut canaries: Vec<(&'static str, String)> = vec![
        ("SECRET", SECRET.into()),
        ("RT_ARG", RT_ARG.into()),
        ("INTROSPECT_ARG", INTROSPECT_ARG.into()),
        ("CODE_ARG", CODE_ARG.into()),
        ("VERIFIER_ARG", VERIFIER_ARG.into()),
    ];
    canaries.extend(vs.iter().flat_map(|v| v.canaries.iter().cloned()));
    let windows = unique_windows(&canaries);
    let blind: Vec<_> = canaries
        .iter()
        .zip(&windows)
        .filter(|(_, w)| w.is_empty())
        .map(|((n, _), _)| *n)
        .collect();
    assert!(
        blind.is_empty(),
        "고유 10자 조각이 없는 카나리아: {blind:?}"
    );
    // 판정기 대조군 — 원문·접두·조각을 실제로 알아보는가.
    assert_eq!(
        hits(&format!("x{SECRET}x"), &canaries, &windows),
        [("SECRET", "full")]
    );
    assert_eq!(
        hits(&format!("x{}x", &RT_ARG[..WINDOW]), &canaries, &windows),
        [("RT_ARG", "prefix")]
    );

    let mut observed: Vec<(&'static str, &'static str, Outcome)> = Vec::new();
    for v in &vs {
        let cfg = KeycloakConfig::new(server.uri(), v.realm, CLIENT_ID)
            .expect("config")
            .with_client_secret(SECRET)
            .with_redirect_uri("https://app.example/cb");
        for (call, r) in drive(&cfg).await {
            observed.push((v.realm, call, r));
        }
    }

    // ── (1) 흐름 — 적대적 응답이 실제로 흘렀고, 호출마다 기대한 대로 실패했다.
    let reqs = server.received_requests().await.expect("recording");
    let mut flow = Vec::new();
    for v in &vs {
        let oidc = format!("/realms/{}/protocol/openid-connect", v.realm);
        for (p, needle) in [
            (format!("{oidc}/token"), format!("code={CODE_ARG}")),
            (format!("{oidc}/token"), format!("refresh_token={RT_ARG}")),
            (
                format!("{oidc}/token/introspect"),
                format!("token={INTROSPECT_ARG}"),
            ),
        ] {
            let seen = reqs
                .iter()
                .any(|r| r.url.path() == p && String::from_utf8_lossy(&r.body).contains(&needle));
            if !seen {
                flow.push(format!("{}: {p} 에 {needle} 가 안 실렸다", v.realm));
            }
        }
        let got: Vec<String> = observed
            .iter()
            .filter(|(realm, _, _)| *realm == v.realm)
            .map(|(_, _, r)| kind(r))
            .collect();
        // EXPECTED 의 열 이름(`CALLS`)이 `drive` 의 호출 순서와 같다 — 행렬이 그 이름으로 토큰 열을 가른다.
        let calls: Vec<&str> = observed
            .iter()
            .filter(|(realm, _, _)| *realm == v.realm)
            .map(|(_, call, _)| *call)
            .collect();
        if calls != CALLS {
            flow.push(format!(
                "{}: drive 의 호출 {calls:?} ≠ CALLS {CALLS:?}",
                v.realm
            ));
        }
        match EXPECTED.iter().find(|(realm, _)| *realm == v.realm) {
            Some((_, want)) if got == want.as_slice() => {}
            Some((_, want)) => flow.push(format!("{}: 기대 {want:?} ≠ 실제 {got:?}", v.realm)),
            None => flow.push(format!("(\"{}\", {got:?}), — EXPECTED 에 없다", v.realm)),
        }
    }
    assert!(flow.is_empty(), "흐름 검사:\n{}", flow.join("\n"));

    // ── (2) 누출 — 오류 뿌리 전부를 네 경로로 찍는다.
    let mut leaks = Vec::new();
    let mut known_seen = BTreeSet::new();
    let mut roots = 0;
    for (realm, call, r) in &observed {
        let Err(e) = r else { continue };
        roots += 1;
        for (how, out) in renders(e) {
            for (name, level) in hits(&out, &canaries, &windows) {
                let key = format!("{realm}|{call}|{name}");
                if KNOWN_LEAKS.iter().any(|(k, _)| *k == key) {
                    known_seen.insert(key);
                    continue;
                }
                leaks.push(format!(
                    "{realm} | {call} | {how} | {name} ({level}) | {out}"
                ));
            }
        }
    }
    let want_roots = EXPECTED
        .iter()
        .flat_map(|(_, row)| row.iter())
        .filter(|k| **k != "ok")
        .count();
    assert_eq!(roots, want_roots, "오류 뿌리 수가 표와 다르다");
    assert!(
        leaks.is_empty(),
        "적대적 응답의 오류가 비밀을 찍는다 ({} 건):\n{}",
        leaks.len(),
        leaks.join("\n")
    );
    let stale: Vec<_> = KNOWN_LEAKS
        .iter()
        .filter(|(k, _)| !known_seen.contains(*k))
        .map(|(k, _)| *k)
        .collect();
    assert!(
        stale.is_empty(),
        "알려진 누출이 더 안 난다 — KNOWN_LEAKS 에서 지워라: {stale:?}"
    );

    // ── (3) 디버깅 정보는 남는다 — 서버 OAuth 오류는 `Auth` 이고 `oauth_error` 는 **코드 그대로**다.
    // 정화가 코드까지 지우면(None) 여기서 떨어진다(누출 검사는 그것을 못 본다). 코드 자리에 코드 아닌
    // 값이 오면(e3) `None` 이다 — 두 경로(openidconnect·provider) 모두.
    let mut codes = Vec::new();
    for (realm, want) in [
        ("e1-error-description", Some("invalid_grant")),
        ("e2-error-uri", Some("invalid_client")),
        ("e3-error-code-token", None),
    ] {
        for (_, call, r) in observed.iter().filter(|(v, _, _)| *v == realm) {
            match r {
                Err(KeycloakError::Auth { oauth_error, .. }) if oauth_error.as_deref() == want => {}
                Err(KeycloakError::Admin(_)) => {} // admin 경로는 상태코드만 싣는다(map_admin).
                other => codes.push(format!(
                    "{realm} | {call}: 기대 oauth_error={want:?}, 실제 {other:?}"
                )),
            }
        }
    }
    assert!(codes.is_empty(), "OAuth 오류 코드:\n{}", codes.join("\n"));
}
