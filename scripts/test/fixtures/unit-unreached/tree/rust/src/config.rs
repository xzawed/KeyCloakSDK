// Fixture: outside the boundary — the lane's unit coverage gate measures it.
pub struct Config {
    realm: String,
}

impl Config {
    pub fn new(realm: &str) -> Self {
        Self {
            realm: realm.to_string(),
        }
    }

    pub fn valid(&self) -> bool {
        !self.realm.is_empty()
    }
}
