//! The redirect URI rules that `url::Url` parsing does not enforce: no fragment (RFC 6749 §3.1.2), no character
//! outside RFC 3986 §2 that Keycloak refuses, and no shape Keycloak refuses.
//!
//! `auth.rs` is the network boundary and is left out of unit coverage, so the rules live in this measured module and
//! `AuthClient` calls them in one line. The absolute-URI rule is `RedirectUrl::new`'s `Url::parse`, whose message is
//! kept. They only judge: the upstream `RedirectUrl` carries the caller's original string, which is never rewritten.
// 등록부 authz-request-redirect-unvalidated · redirect-uri-r3-narrower-than-keycloak · redirect-uri-create-residuals.
// 공유 `redirect_url`(교환도 쓴다)에는 넣지 않는다 — 교환은 바뀌지 않는다.

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
/// - R4c: nothing after it but `//` (`https://`, `myapp://` — "Expected authority"; `https:///cb`, `https://?x=1` and
///   `https://u@/cb` hold more and pass);
/// - R4b: when the part after the scheme starts with `/`, the text before the first `?`: if it starts with `//`, the
///   authority (up to the next `/` or the end) may hold `[` or `]` only around its host ([`bracketed_host`] —
///   `https://u[@[::1]/cb` is refused), and anywhere else — the path — they are refused (`https://app/c[b`,
///   `myapp:/c[b`). An opaque value (`myapp:c[b`, `urn:x[y]`) and the query may hold them;
/// - R4d: that host is an IPv6 literal — RFC 3986's `IPv6address` with an optional zone id (`[zz]` and IPvFuture
///   `[v1.x]` are refused — "Malformed IPv6 address");
/// - R4e: its port, if any, is at most 2147483647 ("Malformed port number").
///
/// Deliberately, R3 still refuses a zone id's `%` that two hex digits do not follow (`[fe80::1%eth0]`), which
/// `URI.create` accepts: RFC 6874 §2 writes that `%` as `%25` in a URI (`[fe80::1%25eth0]` passes both).
fn reject_invalid_shape(raw: &str) -> Result<()> {
    // R1 (`Url::parse`) and R3 passed, so the value starts with its scheme — the first `:` ends it.
    let rest = raw.split_once(':').map_or("", |(_, rest)| rest);
    let shaped = if rest.is_empty() || rest == "//" {
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

/// R4d · R4e — `^(?:[^@\[\]/]*@)?\[IPV6(?:%[A-Za-z0-9_.]+)?\](?::([0-9]*))?$` with a port of at most 2147483647: an
/// authority whose host is one IPv6 literal ([`ipv6_address`]) with an optional zone id (Java's `scope_id`:
/// alphanumerics, `_`, `.`), userinfo and port — what `URI.create` reads as an IPv6 host. The same expression the other
/// SDKs use, written out (the crate has no regex dependency): a userinfo ends at the first `@`, the literal at the
/// first `]`.
fn bracketed_host(authority: &str) -> bool {
    let host = if authority.starts_with('[') {
        authority
    } else {
        match authority.split_once('@') {
            Some((userinfo, host)) if !userinfo.contains(['[', ']']) => host,
            _ => return false,
        }
    };
    let Some((literal, port)) = host.strip_prefix('[').and_then(|h| h.split_once(']')) else {
        return false;
    };
    let (address, zone) = literal
        .split_once('%')
        .map_or((literal, None), |(address, zone)| (address, Some(zone)));
    ipv6_address(address)
        && zone.is_none_or(|zone| {
            !zone.is_empty()
                && zone
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.')
        })
        // R4e — Java reads the port as an `int`: at most `Integer.MAX_VALUE`.
        && (port.is_empty() || port.strip_prefix(':').is_some_and(|p| at_most(p, 2_147_483_647)))
}

/// RFC 3986 `IPv6address`: eight 16-bit pieces — `h16`, one to four hex digits — the last two of which may be written as
/// an IPv4 address, and one `::` standing for one or more zero pieces.
fn ipv6_address(address: &str) -> bool {
    match address.split_once("::") {
        Some((left, right)) => {
            matches!((pieces(left, false), pieces(right, true)), (Some(l), Some(r)) if l + r <= 7)
        }
        None => pieces(address, true) == Some(8),
    }
}

/// How many 16-bit pieces a run of `:`-separated `h16`s is (none for an empty run), its last part an IPv4 address worth
/// two when `ipv4_last` allows one — `None` when a part is neither.
fn pieces(run: &str, ipv4_last: bool) -> Option<usize> {
    if run.is_empty() {
        return Some(0);
    }
    let parts: Vec<&str> = run.split(':').collect();
    let (last, init) = parts.split_last()?;
    let h16 = |p: &str| (1..=4).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_hexdigit());
    if !init.iter().all(|p| h16(p)) {
        None
    } else if h16(last) {
        Some(parts.len())
    } else if ipv4_last && ipv4_address(last) {
        Some(parts.len() + 1)
    } else {
        None
    }
}

/// `IPv4address` with Java's `dec-octet`: four dot-separated runs of digits, each worth at most 255 — leading zeros
/// allowed (`01`, `00000000255`), as `URI.create` reads them.
fn ipv4_address(address: &str) -> bool {
    address.split('.').count() == 4
        && address
            .split('.')
            .all(|octet| !octet.is_empty() && at_most(octet, 255))
}

/// Digits only (none at all reads as zero) worth at most `max` — leading zeros do not count, as Java's
/// `Integer.parseInt` reads them, and a long run stops at the first digit that passes `max`.
fn at_most(digits: &str, max: u32) -> bool {
    let mut value = 0u64;
    for b in digits.bytes() {
        if !b.is_ascii_digit() {
            return false;
        }
        value = value * 10 + u64::from(b - b'0');
        if value > u64::from(max) {
            return false;
        }
    }
    true
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

/// Keycloak 의 `RedirectUtils.toUri`(`java.net.URI.create`)가 각 값에 내린 판정(JDK 21.0.8 실측, `true` = 받음) — 등록부
/// redirect-uri-create-residuals 의 벡터 표 그대로다. 두 시험이 읽는다: 아래 `tests` 는 R3 + R4 를 원본 문자열에, `auth.rs`
/// 의 시험은 공개 메서드를 잰다.
#[cfg(test)]
pub(crate) const URI_CREATE_VECTORS: &[(&str, bool)] = &[
    ("https://", false),
    ("myapp://", false),
    ("https:///", true),
    ("https:///cb", true),
    ("https://?x=1", true),
    ("https://u@/cb", true),
    ("https://:80/cb", true),
    ("https://@/cb", true),
    ("https:/", true),
    ("https://[::1]/cb", true),
    ("https://[zz]/cb", false),
    ("https://[v1.x]/cb", false),
    ("https://[::1::2]/cb", false),
    ("https://[1:2:3:4:5:6:7:8:9]/cb", false),
    ("https://[1:2:3:4:5:6:7:8]/cb", true),
    ("https://[1:2:3:4:5:6:7::]/cb", true),
    ("https://[::1:2:3:4:5:6:7]/cb", true),
    ("https://[1:2:3:4:5:6:7:8::]/cb", false),
    ("https://[::1:2:3:4:5:6:7:8]/cb", false),
    ("https://[1:2:3:4:5:6:7]/cb", false),
    ("https://[::]/cb", true),
    ("https://[:]/cb", false),
    ("https://[:::]/cb", false),
    ("https://[1:::2]/cb", false),
    ("https://[::1:]/cb", false),
    ("https://[:1::2]/cb", false),
    ("https://[1::2:]/cb", false),
    ("https://[12345::]/cb", false),
    ("https://[ABCD::EF]/cb", true),
    ("https://[abcd:EF01::]/cb", true),
    ("https://[0001:2:3:4:5:6:7:8]/cb", true),
    ("https://[::ffff:1.2.3.4]/cb", true),
    ("https://[::1.2.3.4]/cb", true),
    ("https://[1.2.3.4]/cb", false),
    ("https://[::ffff:01.2.3.4]/cb", true),
    ("https://[::ffff:0001.2.3.4]/cb", true),
    ("https://[::ffff:00000000255.2.3.4]/cb", true),
    ("https://[::ffff:256.2.3.4]/cb", false),
    ("https://[::ffff:1.2.3]/cb", false),
    ("https://[::ffff:1.2.3.4.5]/cb", false),
    ("https://[::ffff:1.2.3.]/cb", false),
    ("https://[::ffff:.1.2.3]/cb", false),
    ("https://[::ffff:1..2.3]/cb", false),
    ("https://[1:2:3:4:5:6:1.2.3.4]/cb", true),
    ("https://[1:2:3:4:5:6:7:1.2.3.4]/cb", false),
    ("https://[1:2:3:4:5:1.2.3.4]/cb", false),
    ("https://[1::1.2.3.4]/cb", true),
    ("https://[1:2:3:4:5::1.2.3.4]/cb", true),
    ("https://[1:2:3:4:5:6::1.2.3.4]/cb", false),
    ("https://[::1.2.3.4:5]/cb", false),
    ("https://[1.2.3.4::]/cb", false),
    ("https://[::99999999999.2.3.4]/cb", false),
    ("https://[::1.2.3.9999999999999]/cb", false),
    ("https://[fe80::1%eth0]/cb", true),
    ("https://[fe80::1%25eth0]/cb", true),
    ("https://[fe80::1%25]/cb", true),
    ("https://[fe80::1%]/cb", false),
    ("https://[fe80::1%25en-1]/cb", false),
    ("https://[fe80::1%25a_b.c]/cb", true),
    ("https://[fe80::1%25a%25b]/cb", false),
    ("https://[fe80::1%25a~b]/cb", false),
    ("https://[fe80::1%25é]/cb", false),
    ("https://[%25::1]/cb", false),
    ("https://[::1%1]/cb", true),
    ("https://[::1%zz]/cb", true),
    ("https://[::1]:/cb", true),
    ("https://[::1]:8443/cb", true),
    ("https://[::1]:2147483647/cb", true),
    ("https://[::1]:2147483648/cb", false),
    ("https://[::1]:00000000000000000080/cb", true),
    ("https://[::1]:99999999999/cb", false),
    ("https://h:99999999999/cb", true),
    ("https://u@[::1]:8443/cb", true),
    ("https://u:p@[::1]/cb", true),
    ("https://a@b@[::1]/cb", false),
    ("https://[::1]", true),
    ("https://[::1]?x=[1]", true),
    ("myapp://[::1]/cb", true),
    ("myapp://[zz]/cb", false),
    ("https://my_host/cb", true),
    ("https://999.1.1.1/cb", true),
    ("https://host:abc/cb", true),
    ("https://hé/cb", true),
];

/// 의도한 차이 — 표가 받는 행인데 R3 이 거부하는 셋: zone id 의 `%` 뒤에 16진 두 자리가 없다(RFC 6874 §2 는 `%25`).
#[cfg(test)]
pub(crate) const ZONE_ID_R3: [&str; 3] = [
    "https://[fe80::1%eth0]/cb",
    "https://[::1%1]/cb",
    "https://[::1%zz]/cb",
];

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

    /// R4 — `Url::parse` 가 받는 값 중 `URI.create` 가 거부하는 모양(JDK 21.0.8 실측). 문구는 R3 이다. `myapp://` 는 R4c 다
    /// ("Expected authority" — WHATWG 는 비특수 scheme 의 빈 호스트를 받는다).
    #[test]
    fn refuses_a_shape_keycloak_cannot_parse() {
        for s in [
            "myapp:",
            "myapp://",
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

    /// 괄호 친 호스트(R4d · R4e) — 다른 SDK 가 쓰는 정규식 `^(?:[^@\[\]/]*@)?\[IPV6(?:%[A-Za-z0-9_.]+)?\](?::([0-9]*))?$`
    /// (IPV6 = RFC 3986 `IPv6address`, `dec-octet` 은 Java 처럼 앞 0 을 받는다)에 포트 2147483647 이하를 더한 판정이다.
    /// `[a@b]` · `[zz]` · `[v1.x]` 는 예전에 받던 남은 틈이다. `Url::parse` 를 지나지 못하는 꼴도 함수에서는 잰다 — `%eth0`
    /// 같은 zone id 는 이 식에 맞고, 거부는 R3 의 몫이다.
    #[test]
    fn a_bracketed_host_matches_the_shared_expression() {
        let matching = [
            "[::1]",
            "[::1]:8443",
            "[::1]:",
            "u@[::1]:8443",
            "@[::1]",
            "u:p@[::1]",
            "[::]",
            "[1:2:3:4:5:6:7:8]",
            "[1:2:3:4:5:6:7::]",
            "[::1:2:3:4:5:6:7]",
            "[ABCD::ef]",
            "[::ffff:1.2.3.4]",
            "[1:2:3:4:5:6:1.2.3.4]",
            "[1:2:3:4:5::1.2.3.4]",
            "[::ffff:00000000255.2.3.4]",
            "[::ffff:0.0.0.0]",
            "[fe80::1%25eth0]",
            "[fe80::1%eth0]",
            "[fe80::1%25a_b.c]",
            "[::1]:2147483647",
            "[::1]:00000000000000000080",
            "[::1]:0",
        ];
        let refused = [
            "[a@b]",
            "[zz]",
            "[v1.x]",
            "app[1]",
            "[::1]]",
            "[::1][::2]",
            "[::1]:x",
            "[]",
            "u[@[::1]",
            "a@b@[::1]",
            "[::1",
            "::1]",
            "[::1::2]",
            "[1:2:3:4:5:6:7]",
            "[1:2:3:4:5:6:7:8:9]",
            "[1:2:3:4:5:6:7:8::]",
            "[::1:2:3:4:5:6:7:8]",
            "[12345::]",
            "[:]",
            "[:::]",
            "[1::2:]",
            "[1:2:3:4:5:6::1.2.3.4]",
            "[1:2:3:4:5:6:7:1.2.3.4]",
            "[::1.2.3.4:5]",
            "[1.2.3.4::]",
            "[1.2.3.4]",
            "[::ffff:256.2.3.4]",
            "[::ffff:1.2.3]",
            "[::ffff:1..2.3]",
            "[::ffff:1.2.3.]",
            "[::99999999999.2.3.4]",
            "[fe80::1%]",
            "[fe80::1%25en-1]",
            "[fe80::1%25a%25b]",
            "[%25::1]",
            "[::1]:2147483648",
            "[::1]:99999999999",
            "[::1]:0x50",
        ];
        let wrong: Vec<String> = matching
            .iter()
            .filter(|a| !bracketed_host(a))
            .map(|a| format!("{a:?} must match"))
            .chain(
                refused
                    .iter()
                    .filter(|a| bracketed_host(a))
                    .map(|a| format!("{a:?} must not match")),
            )
            .collect();
        assert!(wrong.is_empty(), "{wrong:#?}");
    }

    /// 벡터 표 전부에 R3 + R4 — `Url::parse`(R1)를 거치지 않고 원본 문자열을 잰다. 판정이 `URI.create` 와 다른 행은 zone id
    /// 셋뿐이다(R3 이 거부 — 의도한 차이). 일곱 SDK 의 같은 규칙이 같은 뜻인지 보는 자리다 — 공개 메서드에서는 R1 이 IPv6
    /// 리터럴의 내용과 65535 위의 포트를 먼저 거부한다(auth.rs 의 같은 표 시험).
    #[test]
    fn r3_and_r4_judge_the_uri_create_vectors_as_keycloak_does() {
        let wrong: Vec<String> = URI_CREATE_VECTORS
            .iter()
            .filter_map(|&(s, keycloak_accepts)| {
                let accepted = reject_invalid_chars(s)
                    .and_then(|()| reject_invalid_shape(s))
                    .is_ok();
                let want = keycloak_accepts && !ZONE_ID_R3.contains(&s);
                (accepted != want).then(|| format!("{s:?}: accepted={accepted}, want {want}"))
            })
            .collect();
        assert!(wrong.is_empty(), "{wrong:#?}");
    }

    /// 의도한 차이(유지한다) — zone id 의 `%` 뒤에 16진 두 자리가 없으면 R3 이 거부한다. `URI.create` 는 받지만(표의 받는
    /// 행), RFC 6874 §2 가 URI 안의 그 `%` 를 `%25` 로 쓰게 한다 — 그렇게 쓴 값은 둘 다 받는다. 모양(R4)만으로는 받는다.
    #[test]
    fn a_zone_id_percent_not_written_as_25_is_refused_by_r3_alone() {
        for s in ZONE_ID_R3 {
            assert!(URI_CREATE_VECTORS.contains(&(s, true)), "{s:?}");
            assert!(reject_invalid_chars(s).is_err(), "{s:?}: R3 refuses it");
            assert!(reject_invalid_shape(s).is_ok(), "{s:?}: R4 accepts it");
        }
        let written = "https://[fe80::1%25eth0]/cb";
        assert!(reject_invalid_chars(written).is_ok() && reject_invalid_shape(written).is_ok());
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
            // R4c 의 이웃 — `//` 뒤에 무언가 있다(경로 · 쿼리).
            "https:///cb",
            "myapp:///cb",
            "myapp://?x=1",
            "https://[::1]:00000000000000000080/cb",
            "https://[1:2:3:4:5:6:1.2.3.4]/cb",
        ] {
            assert!(check(s).is_ok(), "{s:?}");
        }
    }
}
