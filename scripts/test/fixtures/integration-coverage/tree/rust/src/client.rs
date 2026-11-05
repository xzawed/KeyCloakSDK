// Fixture: the client entry point, then module-level shapes (static closures · cfg twins · a non-ASCII name).
use crate::admin::AdminClient;
use crate::auth::AuthClient;

pub struct KeycloakClient {
    auth: AuthClient,
    admin: AdminClient,
}

impl KeycloakClient {
    pub fn new(realm: &str) -> Result<Self, String> {
        if realm.is_empty() {
            return Err("realm is required".to_string());
        }
        Ok(Self {
            auth: AuthClient::new(realm),
            admin: AdminClient::new(realm),
        })
    }

    pub fn auth(&self) -> &AuthClient {
        &self.auth
    }

    pub fn admin(&self) -> &AdminClient {
        &self.admin
    }
}

pub static GREETING: std::sync::LazyLock<String> = std::sync::LazyLock::new(|| {
    let who = "the fixture";
    format!("hello from {who}")
});

static UNUSED: std::sync::LazyLock<u32> = std::sync::LazyLock::new(|| 40 + 2);

pub fn unused_count() -> u32 {
    *UNUSED
}

#[cfg(windows)]
pub fn platform() -> &'static str {
    "windows"
}

#[cfg(not(windows))]
pub fn platform() -> &'static str {
    "other"
}

pub fn größe() -> usize {
    GREETING.len()
}

#[cfg(all(test, debug_assertions))]
mod debug_tests {
    #[test]
    fn admin_is_reachable() {
        let c = super::KeycloakClient::new("r").unwrap();
        assert!(std::ptr::eq(c.admin(), c.admin()));
    }
}
