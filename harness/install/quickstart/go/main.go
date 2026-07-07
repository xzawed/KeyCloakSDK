// Command quickstart is the install-smoke(b1) equivalent of
// harness/install/quickstart/node/quickstart.mjs for the go SDK.
//
// go/example_test.go's Example() documents the same flow but is package
// keycloak_test (not package main) and has no Output comment, so `go test`
// never executes it — it compiles as documentation only, not a runnable
// program. consume/go.Dockerfile builds and runs *this* file instead, against
// the module installed from the local file GOPROXY (no access to the go/
// source tree), to prove "the first program after install actually works"
// against a real Keycloak. It is a harness-only file under harness/install/ —
// not part of the go/ module's own distribution artifact.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	keycloak "github.com/xzawed/KeyCloakSDK/go"
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	client, err := keycloak.New(keycloak.Config{
		ServerURL:    env("KC_SERVER_URL", "http://localhost:8080"),
		Realm:        env("KC_REALM", "it-realm"),
		ClientID:     env("KC_CLIENT_ID", "it-client"),
		ClientSecret: env("KC_CLIENT_SECRET", "it-secret"),
	})
	if err != nil {
		log.Fatalf("quickstart-smoke FAILED: keycloak.New: %v", err)
	}
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// 1) client-credentials 토큰 발급.
	token, err := client.Auth.ClientCredentialsToken(ctx)
	if err != nil {
		log.Fatalf("quickstart-smoke FAILED: ClientCredentialsToken: %v", err)
	}
	if token.AccessToken == "" {
		log.Fatal("quickstart-smoke FAILED: no access token issued")
	}

	// 2) 발급받은 토큰을 자체 강화 검증(alg 핀·iss 정확일치·aud 포함검사·클록 스큐).
	vt, err := client.Auth.Validate(ctx, token.AccessToken)
	if err != nil {
		log.Fatalf("quickstart-smoke FAILED: Validate: %v", err)
	}
	if vt.Subject == "" {
		log.Fatal("quickstart-smoke FAILED: validate produced no subject")
	}

	fmt.Printf("quickstart-smoke OK: tokenType=%s subject=%s audience=%s\n",
		token.TokenType, vt.Subject, strings.Join(vt.Audience, ","))
}
