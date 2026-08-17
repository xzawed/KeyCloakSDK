//go:build integration

// Package keycloak end-to-end tests against a real Keycloak 26.6 container
// (testcontainers-go). Run with: go test -tags=integration ./... -run TestE2E
//
// Reuses the Java/Python/Node integration realm (it-realm · it-client · it-secret,
// with a service account holding realm-management roles and an it-client audience
// mapper). Requires Docker.
package keycloak

import (
	"bytes"
	"context"
	_ "embed"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Nerzal/gocloak/v13"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

//go:embed testdata/it-realm-realm.json
var itRealmJSON []byte

func startKeycloak(ctx context.Context, t *testing.T) string {
	t.Helper()
	req := testcontainers.ContainerRequest{
		Image:        "quay.io/keycloak/keycloak:26.6",
		ExposedPorts: []string{"8080/tcp"},
		Env: map[string]string{
			"KC_BOOTSTRAP_ADMIN_USERNAME": "admin",
			"KC_BOOTSTRAP_ADMIN_PASSWORD": "admin",
		},
		Cmd: []string{"start-dev", "--import-realm"},
		Files: []testcontainers.ContainerFile{{
			Reader:            bytes.NewReader(itRealmJSON),
			ContainerFilePath: "/opt/keycloak/data/import/it-realm-realm.json",
			FileMode:          0o644,
		}},
		WaitingFor: wait.ForHTTP("/realms/it-realm/.well-known/openid-configuration").
			WithPort("8080/tcp").
			WithStatusCodeMatcher(func(status int) bool { return status == 200 }).
			WithStartupTimeout(180 * time.Second),
	}
	c, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: req, Started: true,
	})
	if err != nil {
		t.Fatalf("start keycloak: %v", err)
	}
	t.Cleanup(func() { _ = c.Terminate(context.Background()) })
	url, err := c.PortEndpoint(ctx, "8080/tcp", "http")
	if err != nil {
		t.Fatalf("port endpoint: %v", err)
	}
	return url
}

func TestE2E(t *testing.T) {
	ctx := context.Background()
	serverURL := startKeycloak(ctx, t)

	client, err := New(Config{
		ServerURL: serverURL, Realm: "it-realm", ClientID: "it-client", ClientSecret: "it-secret",
	})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	defer func() { _ = client.Close() }()

	// 1) client-credentials token + masking invariant.
	token, err := client.Auth.ClientCredentialsToken(ctx)
	if err != nil {
		t.Fatalf("client credentials: %v", err)
	}
	if token.AccessToken == "" {
		t.Fatal("empty access token")
	}
	if s := token.String(); strings.Contains(s, token.AccessToken) || !strings.Contains(s, "***") {
		t.Fatalf("token String must mask the access token: %q", s)
	}

	// 2) validate — accepts the real multi-valued audience (it-client mapper), returns issuer/subject.
	vt, err := client.Auth.Validate(ctx, token.AccessToken)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if !strings.HasSuffix(vt.Issuer, "/realms/it-realm") {
		t.Fatalf("issuer: %q", vt.Issuer)
	}
	if !contains(vt.Audience, "it-client") {
		t.Fatalf("audience must include it-client: %v", vt.Audience)
	}
	if vt.Subject == "" {
		t.Fatal("empty subject")
	}

	// 3) introspect reports active.
	ir, err := client.Auth.Introspect(ctx, token.AccessToken)
	if err != nil {
		t.Fatalf("introspect: %v", err)
	}
	if !ir.Active {
		t.Fatal("introspection must report active")
	}

	// 4) admin user CRUD → delete → NotFound.
	admin, err := client.Admin(ctx)
	if err != nil {
		t.Fatalf("admin: %v", err)
	}
	id, err := admin.Users.Create(ctx, gocloak.User{
		Username: gocloak.StringP("bob"), Email: gocloak.StringP("bob@example.com"), Enabled: gocloak.BoolP(true),
	})
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	got, err := admin.Users.Get(ctx, id)
	if err != nil || got.Username == nil || *got.Username != "bob" {
		t.Fatalf("get user: %+v %v", got, err)
	}
	found, err := admin.Users.Search(ctx, "bob", 0, 20)
	if err != nil || len(found) == 0 {
		t.Fatalf("search: %d %v", len(found), err)
	}
	if err := admin.Users.Update(ctx, id, gocloak.User{FirstName: gocloak.StringP("Bob")}); err != nil {
		t.Fatalf("update: %v", err)
	}
	updated, _ := admin.Users.Get(ctx, id)
	if updated.FirstName == nil || *updated.FirstName != "Bob" {
		t.Fatalf("update not applied: %+v", updated)
	}
	if err := admin.Users.Delete(ctx, id); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := admin.Users.Get(ctx, id); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get after delete must be ErrNotFound, got %v", err)
	}

	// 4b) clients / realms / roles / groups resources (thin gocloak delegations).
	if r, err := admin.Realms.Get(ctx, "it-realm"); err != nil || r.Realm == nil || *r.Realm != "it-realm" {
		t.Fatalf("realms.Get: %+v %v", r, err)
	}
	cid, err := admin.Clients.Create(ctx, gocloak.Client{ClientID: gocloak.StringP("e2e-client")})
	if err != nil {
		t.Fatalf("clients.Create: %v", err)
	}
	if _, err := admin.Clients.Get(ctx, cid); err != nil {
		t.Fatalf("clients.Get: %v", err)
	}
	if fc, err := admin.Clients.FindByClientID(ctx, "e2e-client"); err != nil || len(fc) == 0 {
		t.Fatalf("clients.FindByClientID: %d %v", len(fc), err)
	}
	if err := admin.Clients.Delete(ctx, cid); err != nil {
		t.Fatalf("clients.Delete: %v", err)
	}
	if err := admin.Roles.Create(ctx, gocloak.Role{Name: gocloak.StringP("e2e-role")}); err != nil {
		t.Fatalf("roles.Create: %v", err)
	}
	if _, err := admin.Roles.Get(ctx, "e2e-role"); err != nil {
		t.Fatalf("roles.Get: %v", err)
	}
	if rl, err := admin.Roles.List(ctx); err != nil || len(rl) == 0 {
		t.Fatalf("roles.List: %d %v", len(rl), err)
	}
	// roles.Update는 **현재 이름으로 주소를 잡고 body가 새 이름을 나른다**(Keycloak rename 계약).
	// 그래서 경로 인자를 body의 .Name으로 덮어쓰면 안 된다 — 덮으면 rename이 조용한 no-op이 된다.
	if err := admin.Roles.Update(ctx, "e2e-role", gocloak.Role{
		Name:        gocloak.StringP("e2e-role"),
		Description: gocloak.StringP("updated by e2e"),
	}); err != nil {
		t.Fatalf("roles.Update: %v", err)
	}
	if r, err := admin.Roles.Get(ctx, "e2e-role"); err != nil || r.Description == nil || *r.Description != "updated by e2e" {
		t.Fatalf("roles.Update did not take effect: %+v %v", r, err)
	}
	if err := admin.Roles.Delete(ctx, "e2e-role"); err != nil {
		t.Fatalf("roles.Delete: %v", err)
	}
	gid, err := admin.Groups.Create(ctx, gocloak.Group{Name: gocloak.StringP("e2e-group")})
	if err != nil {
		t.Fatalf("groups.Create: %v", err)
	}
	if _, err := admin.Groups.Get(ctx, gid); err != nil {
		t.Fatalf("groups.Get: %v", err)
	}
	if gl, err := admin.Groups.List(ctx, 0, 20); err != nil || len(gl) == 0 {
		t.Fatalf("groups.List: %d %v", len(gl), err)
	}
	// groups.Update는 id로 주소를 잡고 body가 새 이름을 나른다(users/clients와 같은 모양).
	if err := admin.Groups.Update(ctx, gid, gocloak.Group{Name: gocloak.StringP("e2e-group-renamed")}); err != nil {
		t.Fatalf("groups.Update: %v", err)
	}
	if g, err := admin.Groups.Get(ctx, gid); err != nil || g.Name == nil || *g.Name != "e2e-group-renamed" {
		t.Fatalf("groups.Update did not take effect: %+v %v", g, err)
	}
	if err := admin.Groups.Delete(ctx, gid); err != nil {
		t.Fatalf("groups.Delete: %v", err)
	}

	// realms.List / realms.Update — `it-client`는 manage-realm을 갖는다(testdata/it-realm-realm.json).
	// ⚠️ 서비스 계정은 보통 자기 realm만 본다 — 목록에 it-realm이 있는지만 본다(전체 목록을 가정하지 않는다).
	if rls, err := admin.Realms.List(ctx); err != nil {
		t.Fatalf("realms.List: %v", err)
	} else {
		found := false
		for _, r := range rls {
			if r != nil && r.Realm != nil && *r.Realm == "it-realm" {
				found = true
			}
		}
		if !found {
			t.Fatalf("realms.List: it-realm이 목록에 없다 (%d개)", len(rls))
		}
	}
	// ⚠️ realms.Update는 **현재 이름으로 주소를 잡는다** — gocloak의 UpdateRealm은 경로를 body의
	// .Realm에서 만들어 rename을 표현할 수 없어서, 이 메서드만 raw PUT으로 구현했다(§4 동형 유지).
	if err := admin.Realms.Update(ctx, "it-realm", gocloak.RealmRepresentation{
		Realm:       gocloak.StringP("it-realm"),
		DisplayName: gocloak.StringP("updated by e2e"),
	}); err != nil {
		t.Fatalf("realms.Update: %v", err)
	}
	if r, err := admin.Realms.Get(ctx, "it-realm"); err != nil || r.DisplayName == nil || *r.DisplayName != "updated by e2e" {
		t.Fatalf("realms.Update did not take effect: %+v %v", r, err)
	}

	// 5) Raw() escape hatch reaches endpoints the facade does not wrap.
	realm, err := admin.Raw().GetRealm(ctx, mustToken(t, admin, ctx), "it-realm")
	if err != nil || realm.Realm == nil || *realm.Realm != "it-realm" {
		t.Fatalf("raw GetRealm: %+v %v", realm, err)
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

func mustToken(t *testing.T, a *AdminClient, ctx context.Context) string {
	t.Helper()
	tok, err := a.token(ctx)
	if err != nil {
		t.Fatalf("admin token: %v", err)
	}
	return tok
}
