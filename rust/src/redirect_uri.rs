//! The redirect URI rules that `url::Url` parsing does not enforce: no fragment (RFC 6749 §3.1.2), no character
//! outside RFC 3986 §2 that Keycloak refuses, and no shape Keycloak refuses.
//!
//! `auth.rs` is the network boundary and is left out of unit coverage, so the rules live in this measured module and
//! `AuthClient` calls them in one line. The absolute-URI rule is `RedirectUrl::new`'s `Url::parse`, whose message is
//! kept. They only judge: the upstream `RedirectUrl` carries the caller's original string, which is never rewritten.
// 등록부 authz-request-redirect-unvalidated · redirect-uri-r3-narrower-than-keycloak. 공유 `redirect_url`(교환도
// 쓴다)에는 넣지 않는다 — 교환은 바뀌지 않는다.

use crate::error::{KeycloakError, Result};
use openidconnect::RedirectUrl;

/// R3's message — R4 refuses with it too.
const NOT_A_VALID_URI: &str = "invalid redirect_uri: not a valid URI (RFC 3986 §2)";

/// R2, then R3, then R4, on a value `RedirectUrl::new` accepted (R1) — the order is the contract. The messages do not
/// quote the value.
pub(crate) fn check_redirect_uri(redirect: &RedirectUrl) -> Result<()> {
    reject_fragment(redirect.url())?;
    // `RedirectUrl` derefs to the caller's original `String` — what oauth2 5.0.0 sends in both requests (measured).
    reject_invalid_chars(redirect.as_str())?;
    reject_invalid_shape(redirect.as_str())
}

/// R2 — RFC 6749 §3.1.2: "The endpoint URI MUST NOT include a fragment component." An empty fragment
/// (`https://app/cb#`) is one too — `Url::fragment()` is `Some("")` then.
fn reject_fragment(url: &url::Url) -> Result<()> {
    match url.fragment() {
        Some(_) => Err(KeycloakError::Config(
            "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)".into(),
        )),
        None => Ok(()),
    }
}

/// R3 — RFC 3986 §2: what Keycloak's `java.net.URI.create` refuses (`RedirectUtils.toUri`; measured on JDK 21.0.8):
/// U+0000–U+0020, U+007F–U+00A0, the Unicode space separators above U+00A0, `"` `<` `>` `\` `^` `` ` `` `{` `|` `}`,
/// and a `%` not followed by two hex digits. It reads the original string: `Url::parse` percent-encodes these in its
/// own copy, which is not what is sent.
fn reject_invalid_chars(raw: &str) -> Result<()> {
    let bytes = raw.as_bytes();
    let hex_at = |i: usize| bytes.get(i).is_some_and(u8::is_ascii_hexdigit);
    let refused = raw.char_indices().any(|(i, c)| match c {
        '%' => !(hex_at(i + 1) && hex_at(i + 2)),
        _ => outside_uri(c),
    });
    if refused {
        return Err(KeycloakError::Config(NOT_A_VALID_URI.into()));
    }
    Ok(())
}

/// R4 — what `java.net.URI.create` refuses although every character passes R3 (JDK 21.0.8, measured), on the original
/// string, with R3's message:
/// - R4a: nothing after the scheme's `:` (`myapp:` — "Expected scheme-specific part");
/// - R4b: when the part after the scheme starts with `/`, the text before the first `?`: if it starts with `//`, the
///   authority (up to the next `/` or the end) may hold `[` or `]` only as one bracketed host ([`bracketed_host`]), and
///   anywhere else — the path — they are refused (`https://app/c[b`, `myapp:/c[b`, `https://u[@[::1]/cb`). An opaque
///   value (`myapp:c[b`, `urn:x[y]`) and the query may hold them.
///
/// Residual, not judged: a bracketed host's content (`URI.create` also refuses `[zz]` and IPvFuture `[v1.x]`).
fn reject_invalid_shape(raw: &str) -> Result<()> {
    // R1 (`Url::parse`) and R3 passed, so the value starts with its scheme — the first `:` ends it.
    let rest = raw.split_once(':').map_or("", |(_, rest)| rest);
    let shaped = if rest.is_empty() {
        false
    } else if !rest.starts_with('/') {
        true
    } else {
        let before_query = rest.split_once('?').map_or(rest, |(h, _)| h);
        match before_query.strip_prefix("//") {
            Some(after) => {
                let (authority, path) = after.split_once('/').unwrap_or((after, ""));
                (!authority.contains(['[', ']']) || bracketed_host(authority))
                    && !path.contains(['[', ']'])
            }
            None => !before_query.contains(['[', ']']),
        }
    };
    if shaped {
        Ok(())
    } else {
        Err(KeycloakError::Config(NOT_A_VALID_URI.into()))
    }
}

/// `^([^@\[\]/]*@)?\[[^\[\]/]+\](:[0-9]*)?$` — an authority whose host is one bracketed literal, with an optional
/// userinfo and port: what `URI.create` reads as an IPv6 host. The same expression the other SDKs use, written out
/// (the crate has no regex dependency) — a userinfo ends at the first `@`.
fn bracketed_host(authority: &str) -> bool {
    let bracketed = |s: &str| {
        s.strip_prefix('[')
            .and_then(|s| s.split_once(']'))
            .is_some_and(|(host, port)| {
                !host.is_empty()
                    && !host.contains(['[', '/'])
                    && (port.is_empty()
                        || port
                            .strip_prefix(':')
                            .is_some_and(|p| p.bytes().all(|b| b.is_ascii_digit())))
            })
    };
    bracketed(authority)
        || authority
            .split_once('@')
            .is_some_and(|(userinfo, rest)| !userinfo.contains(['[', ']', '/']) && bracketed(rest))
}

/// The characters R3 refuses besides a malformed `%`. The space separators are Zs · Zl · Zp above U+00A0, which
/// `java.net.URI` refuses through `Character.isSpaceChar` (U+200B · U+FEFF are not among them and are accepted). The
/// table is code points, not a Unicode-category lookup — the yardstick is Keycloak's JDK, not this toolchain's tables.
fn outside_uri(c: char) -> bool {
    matches!(
        c as u32,
        0x00..=0x20
            | 0x7f..=0xa0
            | 0x1680
            | 0x2000..=0x200a
            | 0x2028
            | 0x2029
            | 0x202f
            | 0x205f
            | 0x3000
    ) || "\"<>\\^`{|}".contains(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    const R2: &str = "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)";
    const R3: &str = "invalid redirect_uri: not a valid URI (RFC 3986 §2)";

    fn check(s: &str) -> Result<()> {
        check_redirect_uri(&RedirectUrl::new(s.to_string()).expect("an absolute URL"))
    }

    fn refusal(s: &str) -> String {
        match check(s) {
            Err(KeycloakError::Config(m)) => m,
            other => panic!("{s:?}: expected KeycloakError::Config, got {other:?}"),
        }
    }

    #[test]
    fn refuses_a_fragment_component_including_an_empty_one() {
        for s in ["https://app/cb#", "https://app/cb#f", "myapp:/cb#x"] {
            assert_eq!(refusal(s), R2, "{s:?}");
        }
    }

    #[test]
    fn refuses_characters_outside_rfc_3986_in_the_original_string() {
        for s in [
            "https://app/c b",
            "https://app/cb\n",
            "https://app/c\\b",
            "https://app/c%zz",
            "https://app/cb%2",
            "https://app/c|b",
        ] {
            assert_eq!(refusal(s), R3, "{s:?}");
        }
        // 공백 구분자 — 파싱은 퍼센트 인코딩해 받아 준다(사본에서). 원본이 보내지므로 거부한다.
        let ideographic = format!("https://app/c{}b", char::from_u32(0x3000).expect("scalar"));
        assert_eq!(refusal(&ideographic), R3);
    }

    #[test]
    fn a_fragment_is_judged_before_the_characters() {
        assert_eq!(refusal("https://app/c b#f"), R2);
    }

    /// R4 — `Url::parse` 가 받는 값 중 `URI.create` 가 거부하는 모양(JDK 21.0.8 실측). 문구는 R3 이다.
    #[test]
    fn refuses_a_shape_keycloak_cannot_parse() {
        for s in [
            "myapp:",
            "https://app/c[b",
            "https://app/c]b",
            "myapp:/c[b",
            "https://[::1]/c[b",
            "https://u[@[::1]/cb",
            "https://u@[::1]/c]b?x=[1]",
        ] {
            assert_eq!(refusal(s), R3, "{s:?}");
        }
    }

    /// R3 과 R4 가 둘 다 거부하는 값은 R3 의 칸이다 — 문구가 같아 바깥에서는 안 보이므로 규칙 함수를 직접 본다.
    #[test]
    fn the_characters_are_judged_before_the_shape() {
        let both = "https://app/c[b c";
        assert!(reject_invalid_chars(both).is_err() && reject_invalid_shape(both).is_err());
        assert_eq!(refusal(both), R3);
        assert!(reject_invalid_chars("https://app/c[b").is_ok());
    }

    /// 괄호 친 호스트 — 다른 SDK 가 쓰는 정규식 `^([^@\[\]/]*@)?\[[^\[\]/]+\](:[0-9]*)?$` 과 같은 판정이다. 내용은 보지
    /// 않는다(남은 틈 — `[a@b]` · `[zz]` 는 받는다). `Url::parse` 를 지나지 못하는 꼴도 함수에서는 잰다.
    #[test]
    fn a_bracketed_host_matches_the_shared_expression() {
        for a in [
            "[::1]",
            "[::1]:8443",
            "[::1]:",
            "u@[::1]:8443",
            "@[::1]",
            "[a@b]",
            "[zz]",
        ] {
            assert!(bracketed_host(a), "{a:?} must match");
        }
        for a in [
            "app[1]",
            "[::1]]",
            "[::1][::2]",
            "[::1]:x",
            "[]",
            "u[@[::1]",
            "a@b@[::1]",
            "[::1",
            "::1]",
        ] {
            assert!(!bracketed_host(a), "{a:?} must not match");
        }
    }

    #[test]
    fn passes_a_valid_uri_without_a_fragment() {
        // `%23` 은 쿼리 안의 `#` 문자다 — fragment 성분이 아니다.
        for s in [
            "https://app/cb",
            "https://app/cb?x=1",
            "myapp:/cb",
            "HTTP://LOCALHOST/cb",
            "https://app/cb?x=%23",
            "https://app/c%20b",
            "https://app/cb?x=[1]",
            // R4 대조 — `URI.create` 가 받는다(JDK 21.0.8 실측).
            "https://[::1]/cb",
            "https://u@[::1]:8443/cb",
            "https://[::1]?x=[2]",
            "myapp:c[b",
            "urn:x[y]",
            "myapp:/",
        ] {
            assert!(check(s).is_ok(), "{s:?}");
        }
    }
}
