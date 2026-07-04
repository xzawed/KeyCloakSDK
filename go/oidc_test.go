package keycloak

import "testing"

func TestOidcEndpoints(t *testing.T) {
	ep := oidcEndpoints(Config{ServerURL: "https://kc.example.com", Realm: "demo"})
	want := map[string]string{
		"issuer":        "https://kc.example.com/realms/demo",
		"token":         "https://kc.example.com/realms/demo/protocol/openid-connect/token",
		"authorization": "https://kc.example.com/realms/demo/protocol/openid-connect/auth",
		"introspection": "https://kc.example.com/realms/demo/protocol/openid-connect/token/introspect",
		"endSession":    "https://kc.example.com/realms/demo/protocol/openid-connect/logout",
		"jwks":          "https://kc.example.com/realms/demo/protocol/openid-connect/certs",
	}
	got := map[string]string{
		"issuer": ep.issuer, "token": ep.token, "authorization": ep.authorization,
		"introspection": ep.introspection, "endSession": ep.endSession, "jwks": ep.jwks,
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s = %q, want %q", k, got[k], w)
		}
	}
}
