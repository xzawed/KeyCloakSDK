package keycloak_test

import (
	"context"
	"errors"
	"fmt"

	"github.com/Nerzal/gocloak/v13"
	keycloak "github.com/xzawed/KeyCloakSDK/go"
)

// Example shows the primary flow: assemble a client, obtain a service-account
// token, verify it, then use the admin facade. It compiles as documentation but
// is not executed (no Output comment) because it needs a live Keycloak server.
func Example() {
	client, err := keycloak.New(keycloak.Config{
		ServerURL:    "https://kc.example.com",
		Realm:        "myrealm",
		ClientID:     "my-app",
		ClientSecret: "…", // load from an env var / secret manager; Config masks it when logged
	})
	if err != nil {
		panic(err)
	}
	defer func() { _ = client.Close() }()

	ctx := context.Background()

	// 1) client-credentials token. TokenSet.String masks the token when logged.
	token, err := client.Auth.ClientCredentialsToken(ctx)
	if err != nil {
		panic(err)
	}
	fmt.Println(token) // TokenSet{... AccessToken:***, RefreshToken:***}

	// 2) hardened verification (alg pinning · exact iss · aud membership · clock skew).
	vt, err := client.Auth.Validate(ctx, token.AccessToken)
	if err != nil {
		panic(err)
	}
	fmt.Println(vt.Subject, vt.Audience)

	// 3) admin API (lazily created; requires clientSecret). Sentinels via errors.Is.
	admin, err := client.Admin(ctx)
	if err != nil {
		panic(err)
	}
	id, err := admin.Users.Create(ctx, gocloak.User{
		Username: gocloak.StringP("alice"), Enabled: gocloak.BoolP(true),
	})
	if err != nil {
		panic(err)
	}
	if _, err := admin.Users.Get(ctx, id); errors.Is(err, keycloak.ErrNotFound) {
		fmt.Println("not found")
	}
}
