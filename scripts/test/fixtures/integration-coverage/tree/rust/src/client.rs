// Fixture: the client entry point.
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
