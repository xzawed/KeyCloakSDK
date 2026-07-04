package keycloak

// endpoints holds the OIDC endpoint URLs for a Keycloak realm.
type endpoints struct {
	issuer        string
	token         string
	authorization string
	introspection string
	endSession    string
	jwks          string
}

// oidcEndpoints assembles the endpoints from the {ServerURL}/realms/{Realm}
// convention (no network discovery).
func oidcEndpoints(cfg Config) endpoints {
	issuer := cfg.ServerURL + "/realms/" + cfg.Realm
	base := issuer + "/protocol/openid-connect"
	return endpoints{
		issuer:        issuer,
		token:         base + "/token",
		authorization: base + "/auth",
		introspection: base + "/token/introspect",
		endSession:    base + "/logout",
		jwks:          base + "/certs",
	}
}
