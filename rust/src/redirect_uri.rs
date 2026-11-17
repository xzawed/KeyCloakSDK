//! The redirect URI rules that `url::Url` parsing does not enforce: no fragment (RFC 6749 §3.1.2) and no character
//! outside RFC 3986 §2 that Keycloak refuses.
//!
//! `auth.rs` is the network boundary and is left out of unit coverage, so the rules live in this measured module and
//! `AuthClient` calls them in one line. The absolute-URI rule is `RedirectUrl::new`'s `Url::parse`, whose message is
//! kept. They only judge: the upstream `RedirectUrl` carries the caller's original string, which is never rewritten.
// 등록부 authz-request-redirect-unvalidated. 공유 `redirect_url`(교환도 쓴다)에는 넣지 않는다 — 교환은 바뀌지 않는다.

use crate::error::{KeycloakError, Result};
use openidconnect::RedirectUrl;

/// R2, then R3, on a value `RedirectUrl::new` accepted (R1) — the order is the contract. The messages do not quote the
/// value.
pub(crate) fn check_redirect_uri(redirect: &RedirectUrl) -> Result<()> {
    reject_fragment(redirect.url())?;
    // `RedirectUrl` derefs to the caller's original `String` — what oauth2 5.0.0 sends in both requests (measured).
    reject_invalid_chars(redirect.as_str())
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
        return Err(KeycloakError::Config(
            "invalid redirect_uri: not a valid URI (RFC 3986 §2)".into(),
        ));
    }
    Ok(())
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
        ] {
            assert!(check(s).is_ok(), "{s:?}");
        }
    }
}
