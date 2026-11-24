// Fixture: the boundary file — what the unit drive (tests/drive.rs and the cfg(test) module at the end) reaches and
// what it does not. The integration test (tests/integration_test.rs) is #[ignore]: the unit run compiles it and skips it.
use std::fmt;
use std::sync::LazyLock;

macro_rules! owned {
    ($s:expr) => {
        $s.to_string()
    };
}

pub struct AuthClient {
    realm: String,
}

impl AuthClient {
    pub fn new(realm: &str) -> Self {
        Self {
            realm: owned!(realm),
        }
    }

    pub fn realm(&self) -> &str {
        &self.realm
    }

    // The failure arm has lines of its own — the drive never sends an empty code.
    pub fn exchange(&self, code: &str) -> Result<String, String> {
        if code.is_empty() {
            return Err("code is required".to_string());
        }
        Ok(format!("{}:{code}", self.realm))
    }

    // The failure closure has a line of its own after the call that ran (rustfmt breaks the chain).
    pub fn port(&self, raw: &str) -> Result<u16, String> {
        let port = raw
            .parse::<u16>()
            .map_err(|e| format!("not a port number: {e}"))?;
        Ok(port)
    }

    // The failure closure shares the line of the call that ran — a line, not an arm.
    pub fn fallback(&self, raw: &str) -> Result<u16, String> {
        raw.parse::<u16>().map_err(|e| format!("bad port: {e}"))
    }

    // A closure the drive never calls — its lines are pick's.
    pub fn pick<'a>(&self, keys: &[&'a str]) -> &'a str {
        keys.iter()
            .copied()
            .find(|k| k.starts_with(self.realm.as_str()))
            .unwrap_or_else(|| {
                let first = keys.first().copied();
                first.unwrap_or_default()
            })
    }

    // An async fn the drive polls — its body is a record of its own inside token's range.
    pub async fn token(&self, code: &str) -> Result<String, String> {
        if code.is_empty() {
            return Err("code is required".to_string());
        }
        Ok(format!("at-{code}"))
    }

    // An async fn whose future the drive builds and drops — its body never runs (the library's unit-test binary keeps the
    // body's zero-count record).
    pub async fn refresh(&self, rt: &str) -> String {
        format!("rt-{rt}")
    }

    // Only the integration test calls it.
    pub fn logout_url(&self) -> String {
        format!("/realms/{}/logout", self.realm)
    }

    // A generic nothing instantiates — the library's unit-test binary keeps a zero-count record of it.
    pub fn convert<T: Into<String>>(&self, value: T) -> String {
        value.into()
    }
}

impl fmt::Display for AuthClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AuthClient({})", self.realm)
    }
}

// A static whose closure nothing forces.
pub static DEFAULT_SCOPE: LazyLock<String> = LazyLock::new(|| {
    let scope = "openid";
    scope.to_string()
});

#[cfg(test)]
mod tests {
    use super::AuthClient;

    // A unit test inside the boundary file — its lines are the test's, not boundary code (the arm that never runs
    // included).
    #[test]
    fn realm_is_kept() {
        let client = AuthClient::new("kc");
        if client.realm() != "kc" {
            panic!("the realm changed");
        }
    }
}
