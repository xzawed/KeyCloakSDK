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
	"crypto/rand"
	_ "embed"
	"encoding/hex"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Nerzal/gocloak/v13"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

//go:embed testdata/it-realm-realm.json
var itRealmJSON []byte

// The master realm's bootstrap admin service account (startKeycloak). Creating a realm is a master-realm-only
// privilege — the it-client service account gets 403 — so TestE2E's realm lifecycle authenticates as this client
// through the SDK's ordinary path (New → Admin, client-credentials).
const (
	masterAdminClientID     = "go-it-master-admin"
	masterAdminClientSecret = "go-it-master-secret"
)

// One Keycloak for the whole run — TestE2E and TestE2ECodeExchange share it (both match `-run TestE2E`),
// so the code-exchange tests cost no second container start. TestMain terminates it after every test.
var (
	kcOnce sync.Once
	kcURL  string
	kcStop func()
	kcErr  error
)

func keycloakURL(t *testing.T) string {
	t.Helper()
	kcOnce.Do(func() { kcURL, kcStop, kcErr = startKeycloak(context.Background()) })
	if kcErr != nil {
		t.Fatalf("start keycloak: %v", kcErr)
	}
	return kcURL
}

func TestMain(m *testing.M) {
	code := m.Run()
	if kcStop != nil {
		kcStop()
	}
	os.Exit(code)
}

func startKeycloak(ctx context.Context) (string, func(), error) {
	req := testcontainers.ContainerRequest{
		Image:        "quay.io/keycloak/keycloak:26.6",
		ExposedPorts: []string{"8080/tcp"},
		Env: map[string]string{
			"KC_BOOTSTRAP_ADMIN_USERNAME":      "admin",
			"KC_BOOTSTRAP_ADMIN_PASSWORD":      "admin",
			"KC_BOOTSTRAP_ADMIN_CLIENT_ID":     masterAdminClientID,
			"KC_BOOTSTRAP_ADMIN_CLIENT_SECRET": masterAdminClientSecret,
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
	stop := func() {
		if c != nil {
			_ = c.Terminate(context.Background())
		}
	}
	if err != nil {
		stop() // GenericContainer can hand back a created container together with the error
		return "", nil, err
	}
	url, err := c.PortEndpoint(ctx, "8080/tcp", "http")
	if err != nil {
		stop()
		return "", nil, err
	}
	return url, stop, nil
}

func TestE2E(t *testing.T) {
	ctx := context.Background()
	serverURL := keycloakURL(t)

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
	// Removed even when an assertion below fails; after a full lifecycle it is already gone (ErrNotFound).
	defer func() {
		if err := admin.Clients.Delete(ctx, cid); err != nil && !errors.Is(err, ErrNotFound) {
			t.Errorf("clients cleanup: %v", err)
		}
	}()
	if c, err := admin.Clients.Get(ctx, cid); err != nil || c.ClientID == nil || *c.ClientID != "e2e-client" {
		t.Fatalf("clients.Get: %+v %v", c, err)
	}
	fc, err := admin.Clients.FindByClientID(ctx, "e2e-client")
	if err != nil || len(fc) == 0 {
		t.Fatalf("clients.FindByClientID: %d %v", len(fc), err)
	}
	listed := false
	for _, c := range fc {
		if c != nil && c.ID != nil && *c.ID == cid {
			listed = true
		}
	}
	if !listed {
		t.Fatalf("clients.FindByClientID: %s is not in the result (%d clients)", cid, len(fc))
	}
	// clients.Update addresses the client by its internal id — the facade fills the body's .ID with it, because
	// gocloak builds the path from the body.
	if err := admin.Clients.Update(ctx, cid, gocloak.Client{
		ClientID:    gocloak.StringP("e2e-client"),
		Description: gocloak.StringP("updated by e2e"),
	}); err != nil {
		t.Fatalf("clients.Update: %v", err)
	}
	if c, err := admin.Clients.Get(ctx, cid); err != nil || c.Description == nil || *c.Description != "updated by e2e" {
		t.Fatalf("clients.Update did not take effect: %+v %v", c, err)
	}
	if err := admin.Clients.Delete(ctx, cid); err != nil {
		t.Fatalf("clients.Delete: %v", err)
	}
	if _, err := admin.Clients.Get(ctx, cid); !errors.Is(err, ErrNotFound) {
		t.Fatalf("clients.Get after delete must be ErrNotFound, got %v", err)
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

	// 4c) realm lifecycle on a throwaway realm — create · get · list · update · delete, then ErrNotFound.
	// Creating a realm is master-realm-only (it-client gets 403), so this runs as the master bootstrap admin service
	// account through the SDK's ordinary path (New → Admin, client-credentials). ⚠️ Not NewAdminClient with an
	// injected password-grant token: that function's integration gap is owned by another registry item
	// (facade-wiring-close-contract-unasserted), which an unasserted call here would silently mark as covered.
	master, err := New(Config{
		ServerURL: serverURL, Realm: "master", ClientID: masterAdminClientID, ClientSecret: masterAdminClientSecret,
	})
	if err != nil {
		t.Fatalf("new master client: %v", err)
	}
	defer func() { _ = master.Close() }()
	masterAdmin, err := master.Admin(ctx)
	if err != nil {
		t.Fatalf("master admin: %v", err)
	}
	tmpRealm := "go-it-realm-" + randomHex(t, 4)
	if err := masterAdmin.Realms.Create(ctx, gocloak.RealmRepresentation{
		Realm:   gocloak.StringP(tmpRealm),
		Enabled: gocloak.BoolP(true),
	}); err != nil {
		t.Fatalf("realms.Create(%s): %v", tmpRealm, err)
	}
	// The container is shared — removed even when an assertion below fails; after a full lifecycle it is already gone.
	defer func() {
		if err := masterAdmin.Realms.Delete(ctx, tmpRealm); err != nil && !errors.Is(err, ErrNotFound) {
			t.Errorf("realms cleanup: %v", err)
		}
	}()
	if r, err := masterAdmin.Realms.Get(ctx, tmpRealm); err != nil || r.Realm == nil || *r.Realm != tmpRealm || r.Enabled == nil || !*r.Enabled {
		t.Fatalf("realms.Get(%s): %+v %v", tmpRealm, r, err)
	}
	rls, err := masterAdmin.Realms.List(ctx)
	if err != nil {
		t.Fatalf("realms.List: %v", err)
	}
	listedRealm := false
	for _, r := range rls {
		if r != nil && r.Realm != nil && *r.Realm == tmpRealm {
			listedRealm = true
		}
	}
	if !listedRealm {
		t.Fatalf("realms.List: %s is not in the list (%d realms)", tmpRealm, len(rls))
	}
	if err := masterAdmin.Realms.Update(ctx, tmpRealm, gocloak.RealmRepresentation{
		Realm:       gocloak.StringP(tmpRealm),
		DisplayName: gocloak.StringP("throwaway updated by e2e"),
	}); err != nil {
		t.Fatalf("realms.Update(%s): %v", tmpRealm, err)
	}
	if r, err := masterAdmin.Realms.Get(ctx, tmpRealm); err != nil || r.DisplayName == nil || *r.DisplayName != "throwaway updated by e2e" {
		t.Fatalf("realms.Update(%s) did not take effect: %+v %v", tmpRealm, r, err)
	}
	if err := masterAdmin.Realms.Delete(ctx, tmpRealm); err != nil {
		t.Fatalf("realms.Delete(%s): %v", tmpRealm, err)
	}
	if _, err := masterAdmin.Realms.Get(ctx, tmpRealm); !errors.Is(err, ErrNotFound) {
		t.Fatalf("realms.Get after delete must be ErrNotFound, got %v", err)
	}

	// 5) Raw() escape hatch reaches endpoints the facade does not wrap.
	realm, err := admin.Raw().GetRealm(ctx, mustToken(t, admin, ctx), "it-realm")
	if err != nil || realm.Realm == nil || *realm.Realm != "it-realm" {
		t.Fatalf("raw GetRealm: %+v %v", realm, err)
	}
}

// ⚠️ realm 에 Ed448 EdDSA 키가 있어도 RS256 토큰 검증은 그대로여야 한다. Keycloak 은 `eddsa-generated` 제공자의
// Ed448 키를 JWKS 에 그대로 내놓고(kty OKP · crv Ed448), go-jose 는 그 키를 못 읽는다 — 키셋을 한 번에 풀던 동안 그
// 키 하나가 키셋 전체를 버려 realm 의 모든 토큰이 거부됐다(등록부 jwks-unsupported-key-rejects-set).
func TestE2EValidateIgnoresEd448KeyInRealmJWKS(t *testing.T) {
	ctx := context.Background()
	client, err := New(Config{
		ServerURL: keycloakURL(t), Realm: "it-realm", ClientID: "it-client", ClientSecret: "it-secret",
	})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	defer func() { _ = client.Close() }()
	admin, err := client.Admin(ctx)
	if err != nil {
		t.Fatalf("admin: %v", err)
	}
	realm, err := admin.Raw().GetRealm(ctx, mustToken(t, admin, ctx), "it-realm")
	if err != nil || realm.ID == nil {
		t.Fatalf("raw GetRealm: %+v %v", realm, err)
	}
	cid, err := admin.Raw().CreateComponent(ctx, mustToken(t, admin, ctx), "it-realm", gocloak.Component{
		Name:         gocloak.StringP("e2e-ed448"),
		ProviderID:   gocloak.StringP("eddsa-generated"),
		ProviderType: gocloak.StringP("org.keycloak.keys.KeyProvider"),
		ParentID:     realm.ID,
		ComponentConfig: &map[string][]string{
			"priority": {"50"}, "enabled": {"true"}, "active": {"true"}, "eddsaEllipticCurveKey": {"Ed448"},
		},
	})
	if err != nil {
		t.Fatalf("create Ed448 key provider: %v", err)
	}
	// 다음 테스트가 Ed448 키 없는 realm 을 보게 지운다.
	t.Cleanup(func() {
		if err := admin.Raw().DeleteComponent(ctx, mustToken(t, admin, ctx), "it-realm", cid); err != nil {
			t.Errorf("delete Ed448 key provider: %v", err)
		}
	})

	// 전제 — JWKS 에 Ed448 키가 정말 있다(없으면 이 테스트는 아무것도 재지 않는다).
	certs, err := admin.Raw().GetCerts(ctx, "it-realm")
	if err != nil || certs.Keys == nil {
		t.Fatalf("certs: %+v %v", certs, err)
	}
	hasEd448 := false
	for _, k := range *certs.Keys {
		if k.Crv != nil && *k.Crv == "Ed448" {
			hasEd448 = true
		}
	}
	if !hasEd448 {
		t.Fatalf("realm JWKS 에 Ed448 키가 없다 — 이 테스트의 전제가 무너졌다 (%d keys)", len(*certs.Keys))
	}

	token, err := client.Auth.ClientCredentialsToken(ctx)
	if err != nil {
		t.Fatalf("client credentials: %v", err)
	}
	if _, err := client.Auth.Validate(ctx, token.AccessToken); err != nil {
		t.Fatalf("realm 에 Ed448 키가 있다고 RS256 토큰이 거부됐다: %v", err)
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

// randomHex is a name suffix that keeps a throwaway resource from colliding with anything else on the shared server.
func randomHex(t *testing.T, n int) string {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("random suffix: %v", err)
	}
	return hex.EncodeToString(b)
}

func mustToken(t *testing.T, a *AdminClient, ctx context.Context) string {
	t.Helper()
	tok, err := a.token(ctx)
	if err != nil {
		t.Fatalf("admin token: %v", err)
	}
	return tok
}
