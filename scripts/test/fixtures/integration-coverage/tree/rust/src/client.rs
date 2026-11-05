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

#[cfg(not(windows))] // every other platform
pub fn platform() -> &'static str {
    "other"
}

pub fn größe() -> usize {
    GREETING.len()
}

#[cfg(all(
    test,
    debug_assertions,
    any(
        target_pointer_width = "64",
        target_pointer_width = "32",
        target_pointer_width = "16"
    )
))]
mod debug_tests {
    #[test]
    fn admin_is_reachable() {
        let c = super::KeycloakClient::new("r").unwrap();
        assert!(std::ptr::eq(c.admin(), c.admin()));
    }
}

const _: () = assert!(u32::MAX > 0);
const _: () = assert!(usize::MAX > 0);

#[cfg(any(
    target_os = "linux",
    target_os = "macos",
    target_os = "freebsd",
    target_os = "openbsd"
))]
pub fn family() -> &'static str {
    "unix-like"
}

#[cfg(not(any(
    target_os = "linux",
    target_os = "macos",
    target_os = "freebsd",
    target_os = "openbsd"
)))]
pub fn family() -> &'static str {
    "other"
}

pub async fn warm_up() {
    // nothing to prepare in the fixture
}

// A future built and dropped where the library also keeps its own (zero-count) body record.
pub async fn never_polled() -> u32 {
    7
}

// An unnamed const block holding items — its impl is read like any other (the methods belong to the
// type), and a free fn inside it is named `const _::…`, so it cannot collide with the outer fn below.
const _: () = {
    impl KeycloakClient {
        pub fn scoped(&self) -> u8 {
            block_local()
        }
    }

    fn block_local() -> u8 {
        9
    }
};

pub fn block_local() -> u8 {
    8
}

// A closure-valued unnamed const — its closure is code with a record of its own.
const _: fn() -> u8 = || {
    let seven = 7;
    seven
};
