//! The redirect URI rule of RFC 6749 §3.1.2 that `url::Url` parsing does not enforce — the fragment.
//!
//! `auth.rs` is the network boundary and is left out of unit coverage, so the rule lives in this measured module and
//! `AuthClient` calls it in one line. The absolute-URI rule is `RedirectUrl::new`'s `Url::parse`, whose message is kept.
//! It only judges: the upstream `RedirectUrl` carries the caller's original string, which is never rewritten.
// 등록부 authz-request-redirect-unvalidated. 공유 `redirect_url`(교환도 쓴다)에는 넣지 않는다 — 교환은 바뀌지 않는다.

use crate::error::{KeycloakError, Result};

/// RFC 6749 §3.1.2: "The endpoint URI MUST NOT include a fragment component." An empty fragment
/// (`https://app/cb#`) is one too — `Url::fragment()` is `Some("")` then. The message does not quote the value.
pub(crate) fn reject_fragment(url: &url::Url) -> Result<()> {
    match url.fragment() {
        Some(_) => Err(KeycloakError::Config(
            "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)".into(),
        )),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(s: &str) -> url::Url {
        url::Url::parse(s).expect("an absolute URL")
    }

    #[test]
    fn refuses_a_fragment_component_including_an_empty_one() {
        for s in ["https://app/cb#", "https://app/cb#f", "myapp:/cb#x"] {
            match reject_fragment(&parsed(s)) {
                Err(KeycloakError::Config(m)) => assert_eq!(
                    m, "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)",
                    "{s:?}"
                ),
                other => panic!("{s:?}: expected KeycloakError::Config, got {other:?}"),
            }
        }
    }

    #[test]
    fn passes_a_uri_without_a_fragment() {
        // `%23` 은 쿼리 안의 `#` 문자다 — fragment 성분이 아니다.
        for s in [
            "https://app/cb",
            "https://app/cb?x=1",
            "myapp:/cb",
            "HTTP://LOCALHOST/cb",
            "https://app/cb?x=%23",
        ] {
            assert!(reject_fragment(&parsed(s)).is_ok(), "{s:?}");
        }
    }
}
