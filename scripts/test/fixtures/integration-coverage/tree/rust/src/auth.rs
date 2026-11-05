// Fixture: every shape the rust name-range parser reads (rustfmt-formatted).
use std::fmt;

/* A nested block comment /* inner */ — a blanker that stopped at the first close would read
the next two lines as an item.
fn hidden() {
}
*/

/// A doc comment is not code:
/// fn doc_fake() {
/// }
pub struct AuthClient {
    realm: String,
}

const BANNER: &str = r##"
"#}
fn raw_fake() {
"##;

impl AuthClient {
    pub fn new(realm: &str) -> Self {
        Self {
            realm: realm.to_string(),
        }
    }

    pub fn realm<'a>(&'a self) -> &'a str {
        let quote = '"';
        let open = '{';
        if quote == open { BANNER } else { &self.realm }
    }

    pub fn exchange(&self, code: &str, verifier: &str) -> Result<String, String> {
        if code.is_empty() {
            return Err("empty code".to_string());
        }
        Ok(format!("{}:{code}:{verifier}", self.realm))
    }

    pub fn describe(&self) -> String {
        let text = "
    }
    fn string_fake() {
";
        format!("{text}{}", self.realm)
    }

    pub fn apply<F>(&self, f: F) -> usize
    where
        F: Fn(&str) -> usize,
    {
        f(&self.realm)
    }

    pub async fn token(&self) -> Result<String, String> {
        self.exchange("code", "verifier")
    }

    pub fn noop(&self) {}

    pub fn close(&mut self) {
        self.realm.clear();
    }
}

impl fmt::Debug for AuthClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthClient(***)")
    }
}

impl fmt::Display for AuthClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AuthClient({})", self.realm)
    }
}

pub trait TokenSource {
    fn token_now(&self) -> String;

    fn token_twice(&self) -> String {
        format!("{}{}", self.token_now(), self.token_now())
    }
}

impl TokenSource for AuthClient {
    fn token_now(&self) -> String {
        self.realm.clone()
    }
}

pub struct Wrapper<T>(pub T);

impl Wrapper<u8> {
    pub fn get(&self) -> u32 {
        u32::from(self.0)
    }
}

impl Wrapper<u16> {
    pub fn get(&self) -> u32 {
        u32::from(self.0) * 2
    }
}

impl<'a, T> From<&'a [T]> for Wrapper<usize> {
    fn from(items: &'a [T]) -> Self {
        Wrapper(items.len())
    }
}

macro_rules! twice {
    ($e:expr) => {{
        let v = $e;
        v + v
    }};
}

pub fn helper(x: u32) -> u32 {
    fn inner(y: u32) -> u32 {
        y + 1
    }
    let add = |z: u32| z + inner(z);
    twice!(add(x))
}

pub(crate) fn unused_helper() -> u32 {
    40 + 2
}

mod inner {
    pub fn depth() -> usize {
        1
    }

    pub struct Nested;

    impl Nested {
        pub fn level(&self) -> usize {
            depth() + 1
        }
    }
}

pub fn nested_level() -> usize {
    inner::Nested.level()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn platform() -> &'static str {
        "unix"
    }

    #[cfg(not(unix))]
    fn platform() -> &'static str {
        "other"
    }

    #[test]
    fn exchange_rejects_empty() {
        let c = AuthClient::new(platform());
        assert!(c.exchange("", "v").is_err());
    }
}
