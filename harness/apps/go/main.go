package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/Nerzal/gocloak/v13"
	keycloak "github.com/xzawed/KeyCloakSDK/go"
)

var kc *keycloak.Client
var lastRefreshToken string // server-side session for /refresh, /logout — single-process demo harness

func main() {
	cfg := keycloak.Config{
		ServerURL:    env("KC_SERVER_URL", "http://localhost:8080"),
		Realm:        env("KC_REALM", "it-realm"),
		ClientID:     env("KC_CLIENT_ID", "it-client"),
		ClientSecret: env("KC_CLIENT_SECRET", "it-secret"),
	}
	var err error
	if kc, err = keycloak.New(cfg); err != nil {
		log.Fatalf("keycloak.New: %v", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("POST /token", tokenH)
	mux.HandleFunc("POST /validate", validateH)
	mux.HandleFunc("POST /introspect", introspectH)
	mux.HandleFunc("POST /admin/users", adminCreateH)
	mux.HandleFunc("GET /admin/users/{id}", adminGetH)
	mux.HandleFunc("GET /admin/users", adminSearchH)
	mux.HandleFunc("DELETE /admin/users/{id}", adminDeleteH)
	mux.HandleFunc("POST /token/password", tokenPasswordH)
	mux.HandleFunc("POST /refresh", refreshH)
	mux.HandleFunc("POST /logout", logoutH)
	mux.HandleFunc("GET /authz-url", authzURLH)
	mux.HandleFunc("POST /admin/clients", adminClientCreateH)
	mux.HandleFunc("GET /admin/clients/{id}", adminClientGetH)
	mux.HandleFunc("DELETE /admin/clients/{id}", adminClientDeleteH)
	mux.HandleFunc("POST /admin/roles", adminRoleCreateH)
	mux.HandleFunc("GET /admin/roles/{name}", adminRoleGetH)
	mux.HandleFunc("DELETE /admin/roles/{name}", adminRoleDeleteH)
	mux.HandleFunc("POST /admin/groups", adminGroupCreateH)
	mux.HandleFunc("GET /admin/groups/{id}", adminGroupGetH)
	mux.HandleFunc("DELETE /admin/groups/{id}", adminGroupDeleteH)
	mux.HandleFunc("POST /admin/realms", adminRealmCreateH)
	addr := ":" + env("APP_PORT", "8090")
	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func env(k, d string) string { if v := os.Getenv(k); v != "" { return v }; return d }

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if v != nil { _ = json.NewEncoder(w).Encode(v) }
}
func fail(w http.ResponseWriter, code int, msg string) { writeJSON(w, code, map[string]string{"error": msg}) }

func ctx(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), 15*time.Second)
}

func healthz(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) }

func tokenH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	ts, err := kc.Auth.ClientCredentialsToken(c)
	if err != nil { fail(w, 500, err.Error()); return }
	writeJSON(w, 200, map[string]any{"tokenType": ts.TokenType, "expiresIn": ts.ExpiresIn})
}

type tokenReq struct { Token string `json:"token"` }

func validateH(w http.ResponseWriter, r *http.Request) {
	var body tokenReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Token == "" { fail(w, 400, "token required"); return }
	c, cancel := ctx(r); defer cancel()
	vt, err := kc.Auth.Validate(c, body.Token)
	if err != nil { fail(w, 401, err.Error()); return }
	writeJSON(w, 200, map[string]any{"subject": vt.Subject, "audience": vt.Audience, "issuer": vt.Issuer, "expiresAt": vt.ExpiresAt})
}

func introspectH(w http.ResponseWriter, r *http.Request) {
	var body tokenReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Token == "" { fail(w, 400, "token required"); return }
	c, cancel := ctx(r); defer cancel()
	ir, err := kc.Auth.Introspect(c, body.Token)
	if err != nil { fail(w, 500, err.Error()); return }
	writeJSON(w, 200, map[string]any{"active": ir.Active, "username": ir.Username, "clientId": ir.ClientID})
}

type createReq struct { Username string `json:"username"`; Email string `json:"email"` }

func adminCreateH(w http.ResponseWriter, r *http.Request) {
	var body createReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Username == "" { fail(w, 400, "username required"); return }
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	id, err := admin.Users.Create(c, gocloak.User{Username: gocloak.StringP(body.Username), Email: gocloak.StringP(body.Email), Enabled: gocloak.BoolP(true)})
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 201, map[string]string{"id": id})
}

func adminGetH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	u, err := admin.Users.Get(c, r.PathValue("id"))
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 200, map[string]string{"id": strOr(u.ID), "username": strOr(u.Username)})
}

func adminSearchH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	us, err := admin.Users.Search(c, r.URL.Query().Get("username"), 0, 20)
	if err != nil { writeErr(w, err); return }
	out := make([]map[string]string, 0, len(us))
	for _, u := range us { out = append(out, map[string]string{"id": strOr(u.ID), "username": strOr(u.Username)}) }
	writeJSON(w, 200, out)
}

func adminDeleteH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	if err := admin.Users.Delete(c, r.PathValue("id")); err != nil { writeErr(w, err); return }
	w.WriteHeader(204)
}

// writeErr maps SDK errors to HTTP per the contract (NotFound→404, else 500).
func writeErr(w http.ResponseWriter, err error) {
	if errors.Is(err, keycloak.ErrNotFound) { fail(w, 404, err.Error()); return }
	if errors.Is(err, keycloak.ErrConflict) { fail(w, 409, err.Error()); return }
	if errors.Is(err, keycloak.ErrForbidden) { fail(w, 403, err.Error()); return }
	fail(w, 500, err.Error())
}

func strOr(p *string) string { if p != nil { return *p }; return "" }

// ropcTokenResp is the token-endpoint JSON shape for the password grant.
type ropcTokenResp struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	RefreshToken string `json:"refresh_token"`
}

type passwordReq struct { Username string `json:"username"`; Password string `json:"password"` }

// tokenPasswordH does ROPC(Resource Owner Password Credentials). It is not on
// the SDK surface by design — the harness app POSTs directly to the token
// endpoint (same pattern across all 8 harness apps).
func tokenPasswordH(w http.ResponseWriter, r *http.Request) {
	var body passwordReq
	if json.NewDecoder(r.Body).Decode(&body) != nil { fail(w, 400, "username/password required"); return }
	form := url.Values{
		"grant_type":    {"password"},
		"client_id":     {env("KC_CLIENT_ID", "it-client")},
		"client_secret": {env("KC_CLIENT_SECRET", "it-secret")},
		"username":      {body.Username},
		"password":      {body.Password},
	}
	endpoint := strings.TrimRight(env("KC_SERVER_URL", "http://localhost:8080"), "/") + "/realms/" + env("KC_REALM", "it-realm") + "/protocol/openid-connect/token"
	c, cancel := ctx(r); defer cancel()
	req, err := http.NewRequestWithContext(c, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil { fail(w, 401, err.Error()); return }
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := http.DefaultClient.Do(req)
	if err != nil { fail(w, 401, err.Error()); return }
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 { fail(w, 401, "ROPC(password) grant failed: HTTP "+resp.Status); return }
	var tr ropcTokenResp
	if err := json.Unmarshal(data, &tr); err != nil { fail(w, 401, err.Error()); return }
	lastRefreshToken = tr.RefreshToken
	writeJSON(w, 200, map[string]any{"tokenType": tr.TokenType, "expiresIn": tr.ExpiresIn, "hasRefresh": tr.RefreshToken != ""})
}

func refreshH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	ts, err := kc.Auth.Refresh(c, lastRefreshToken)
	if err != nil { fail(w, 401, err.Error()); return }
	if ts.RefreshToken != "" { lastRefreshToken = ts.RefreshToken }
	writeJSON(w, 200, map[string]any{"tokenType": ts.TokenType, "expiresIn": ts.ExpiresIn})
}

func logoutH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	if err := kc.Auth.Logout(c, lastRefreshToken); err != nil { fail(w, 500, err.Error()); return }
	w.WriteHeader(204)
}

func authzURLH(w http.ResponseWriter, r *http.Request) {
	redirectURI := r.URL.Query().Get("redirect_uri")
	if redirectURI == "" { redirectURI = "http://x/cb" }
	ar := kc.Auth.CreateAuthorizationRequest(redirectURI)
	writeJSON(w, 200, map[string]string{"url": ar.URL, "state": ar.State})
}

type clientReq struct { ClientID string `json:"clientId"` }

func adminClientCreateH(w http.ResponseWriter, r *http.Request) {
	var body clientReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.ClientID == "" { fail(w, 400, "clientId required"); return }
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	id, err := admin.Clients.Create(c, gocloak.Client{ClientID: gocloak.StringP(body.ClientID), Enabled: gocloak.BoolP(true)})
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 201, map[string]string{"id": id})
}

func adminClientGetH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	cl, err := admin.Clients.Get(c, r.PathValue("id"))
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 200, map[string]string{"id": strOr(cl.ID), "clientId": strOr(cl.ClientID)})
}

func adminClientDeleteH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	if err := admin.Clients.Delete(c, r.PathValue("id")); err != nil { writeErr(w, err); return }
	w.WriteHeader(204)
}

type nameReq struct { Name string `json:"name"` }

func adminRoleCreateH(w http.ResponseWriter, r *http.Request) {
	var body nameReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Name == "" { fail(w, 400, "name required"); return }
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	if err := admin.Roles.Create(c, gocloak.Role{Name: gocloak.StringP(body.Name)}); err != nil { writeErr(w, err); return }
	writeJSON(w, 201, map[string]string{"name": body.Name})
}

func adminRoleGetH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	ro, err := admin.Roles.Get(c, r.PathValue("name"))
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 200, map[string]string{"name": strOr(ro.Name)})
}

func adminRoleDeleteH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	if err := admin.Roles.Delete(c, r.PathValue("name")); err != nil { writeErr(w, err); return }
	w.WriteHeader(204)
}

func adminGroupCreateH(w http.ResponseWriter, r *http.Request) {
	var body nameReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Name == "" { fail(w, 400, "name required"); return }
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	id, err := admin.Groups.Create(c, gocloak.Group{Name: gocloak.StringP(body.Name)})
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 201, map[string]string{"id": id})
}

func adminGroupGetH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	g, err := admin.Groups.Get(c, r.PathValue("id"))
	if err != nil { writeErr(w, err); return }
	writeJSON(w, 200, map[string]string{"id": strOr(g.ID), "name": strOr(g.Name)})
}

func adminGroupDeleteH(w http.ResponseWriter, r *http.Request) {
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	if err := admin.Groups.Delete(c, r.PathValue("id")); err != nil { writeErr(w, err); return }
	w.WriteHeader(204)
}

type realmReq struct { Realm string `json:"realm"` }

func adminRealmCreateH(w http.ResponseWriter, r *http.Request) {
	var body realmReq
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Realm == "" { fail(w, 400, "realm required"); return }
	c, cancel := ctx(r); defer cancel()
	admin, err := kc.Admin(c)
	if err != nil { fail(w, 500, err.Error()); return }
	if err := admin.Realms.Create(c, gocloak.RealmRepresentation{Realm: gocloak.StringP(body.Realm), Enabled: gocloak.BoolP(true)}); err != nil { writeErr(w, err); return }
	writeJSON(w, 201, map[string]string{"realm": body.Realm})
}
