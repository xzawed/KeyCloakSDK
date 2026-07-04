// Package keycloak is an idiomatic Go SDK for Keycloak — OIDC authentication
// (auth) and the Admin REST API (admin) — isomorphic with the Java, Python, and
// Node SDKs in this repository.
//
// It wraps golang.org/x/oauth2 (auth flows), github.com/go-jose/go-jose/v4
// (hardened JWT verification), and github.com/Nerzal/gocloak/v13 (admin) behind
// a consistent facade. Sub-library types and errors are converted to SDK types
// at the boundary. All network methods take a context.Context.
package keycloak
