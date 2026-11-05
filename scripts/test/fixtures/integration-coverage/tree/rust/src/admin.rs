// Fixture: the admin facade — async methods, a multi-line signature, an async fn in a trait
// impl, and top-level functions whose bodies hold a column-4 `}` before their column-0 close.
use std::future::Future;

pub struct AdminClient {
    base: String,
}

fn encode(segment: &str) -> String {
    let mut out = String::new();
    for c in segment.chars() {
        if c == '/' {
            out.push_str("%2F");
        } else {
            out.push(c);
        }
    }
    out
}

fn transport(e: &str) -> String {
    format!("admin request: {e}")
}

impl AdminClient {
    pub fn new(base: &str) -> Self {
        Self {
            base: base.to_string(),
        }
    }

    async fn send(&self, path: &str) -> Result<String, String> {
        if path.is_empty() {
            return Err(transport("empty path"));
        }
        Ok(format!("{}/{}", self.base, encode(path)))
    }

    pub async fn get_user(&self, id: &str) -> Result<String, String> {
        self.send(&format!("users/{id}")).await
    }

    pub async fn search_users(
        &self,
        search: &str,
        first: i32,
        max: i32,
        exact: bool,
    ) -> Result<Vec<String>, String> {
        let query = format!("users?search={search}&first={first}&max={max}&exact={exact}");
        self.send(&query).await.map(|one| vec![one])
    }

    pub async fn delete_user(&self, id: &str) -> Result<(), String> {
        self.send(&format!("users/{id}")).await.map(|_| ())
    }
}

pub trait Supplier {
    fn supply(&self) -> impl Future<Output = String>;
}

impl Supplier for AdminClient {
    async fn supply(&self) -> String {
        self.base.clone()
    }
}

// `#[async_trait]` keeps no separate record for the async body: a polled method shows its body lines,
// a dropped one only the head and closing lines (with the outer count).
#[async_trait::async_trait]
pub trait Fetch {
    async fn fetch(&self) -> String;
}

pub struct Polled;

pub struct Dropped;

#[async_trait::async_trait]
impl Fetch for Polled {
    async fn fetch(&self) -> String {
        "polled".to_string()
    }
}

#[async_trait::async_trait]
impl Fetch for Dropped {
    async fn fetch(&self) -> String {
        "dropped".to_string()
    }
}
