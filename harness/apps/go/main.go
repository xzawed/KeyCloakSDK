package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/Nerzal/gocloak/v13"
	keycloak "github.com/xzawed/KeyCloakSDK/go"
)

var kc *keycloak.Client

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
	fail(w, 500, err.Error())
}

func strOr(p *string) string { if p != nil { return *p }; return "" }
var _ = strings.TrimSpace
