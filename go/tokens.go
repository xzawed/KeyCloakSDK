package keycloak

import (
	"fmt"
	"log/slog"
	"time"

	"golang.org/x/oauth2"
)

// TokenSet is a token-endpoint response. AccessToken and RefreshToken are
// masked by String. Isomorphic with the Java/Python/Node TokenSet
// (IDToken, absolute ExpiresAt, IsExpired).
type TokenSet struct {
	AccessToken  string
	TokenType    string
	ExpiresIn    int64 // relative, seconds
	ExpiresAt    int64 // absolute, epoch seconds; 0 if unknown
	RefreshToken string
	IDToken      string
	Scope        string
}

// IsExpired reports whether the token is expired at nowSec, allowing skewSec of
// clock skew. An unknown ExpiresAt (0) is treated as expired (conservative).
func (t *TokenSet) IsExpired(nowSec, skewSec int64) bool {
	if t.ExpiresAt == 0 {
		return true
	}
	return nowSec+skewSec >= t.ExpiresAt
}

// ⚠️ **This must be a value receiver.** With a pointer receiver a `TokenSet` value does not satisfy
// fmt.Stringer, so `fmt.Printf("%v", ts)` prints the fields as they are — measured (before the fix):
// the value printed the access/refresh tokens verbatim and only the pointer was masked. With a value
// receiver the value and the pointer are **both** masked.
func (t TokenSet) String() string {
	return fmt.Sprintf("TokenSet{TokenType:%q, ExpiresIn:%d, AccessToken:%s, RefreshToken:%s}",
		t.TokenType, t.ExpiresIn, mask(t.AccessToken), mask(t.RefreshToken))
}

// GoString is the `%#v` hook (`GoStringer`). ⚠️ `%#v` does **not use** `Stringer`; it builds a
// Go-syntax representation and prints the fields directly, so the masking in `String()` above does not
// reach it (measured 2026-09-12). ⚠️ This hook changes **only** `%#v` — `%v`/`%+v`/`%s` still go
// through `String()` (a control test pins this). ⚠️ `json.Marshal` is a separate path and is not
// blocked here (it round-trips, so storing `***` is worse).
func (t TokenSet) GoString() string { return t.String() }

// LogValue is the `log/slog` masking hook. JSONHandler does not go through Stringer and serializes
// the fields by reflection, so with String() alone a structured log writes them verbatim (confirmed
// by measurement).
//
// ⚠️ Adding `MarshalJSON` here is **the wrong choice.** Then, when a consumer serializes a TokenSet
// into a session or cache and round-trips it, the masked values are stored — that is why .NET had to
// block its own converter's Read with a throw. LogValuer changes only the logging path and does not
// break the round trip.
func (t TokenSet) LogValue() slog.Value { return slog.StringValue(t.String()) }

// tokenSetFromToken maps an x/oauth2 token (+ extras) to a TokenSet.
func tokenSetFromToken(tok *oauth2.Token) *TokenSet {
	ts := &TokenSet{
		AccessToken:  tok.AccessToken,
		TokenType:    tok.TokenType,
		ExpiresIn:    tok.ExpiresIn,
		RefreshToken: tok.RefreshToken,
	}
	if !tok.Expiry.IsZero() {
		ts.ExpiresAt = tok.Expiry.Unix()
		// x/oauth2 always populates Expiry but not always the public ExpiresIn
		// field; derive the relative lifetime from the absolute expiry.
		if ts.ExpiresIn == 0 {
			if d := ts.ExpiresAt - time.Now().Unix(); d > 0 {
				ts.ExpiresIn = d
			}
		}
	}
	if v, ok := tok.Extra("id_token").(string); ok {
		ts.IDToken = v
	}
	if v, ok := tok.Extra("scope").(string); ok {
		ts.Scope = v
	}
	return ts
}

// ValidatedToken is the trusted claim set of an access token that passed
// hardened verification.
type ValidatedToken struct {
	Subject   string
	Audience  []string
	Issuer    string
	ExpiresAt int64 // exp
	IssuedAt  int64 // iat
	Claims    map[string]any
}

// IntrospectionResult is an RFC 7662 introspection response.
type IntrospectionResult struct {
	Active   bool
	Username string
	ClientID string
	Claims   map[string]any
}

// AuthorizationRequest is returned by CreateAuthorizationRequest to start a
// PKCE authorization-code flow. The caller stores CodeVerifier/State/Nonce
// until the callback (the SDK is stateless).
type AuthorizationRequest struct {
	URL          string
	CodeVerifier string
	State        string
	Nonce        string
}

// ⚠️ For a long time this type had no String() — so `fmt.Printf("%v", req)` printed the PKCE
// CodeVerifier verbatim, and since CreateAuthorizationRequest returns a **value**, that is the very
// value the consumer holds. CodeVerifier is the proof-of-possession secret of the code exchange, so an
// attacker who stole the authorization code completes the flow if they obtain this value from a log.
// URL/State/Nonce are not masked — isomorphic with Rust's Debug impl (only code_verifier is masked
// there too).
func (a AuthorizationRequest) String() string {
	return fmt.Sprintf("AuthorizationRequest{URL:%q, State:%q, Nonce:%q, CodeVerifier:%s}",
		a.URL, a.State, a.Nonce, mask(a.CodeVerifier))
}

// GoString is the `%#v` hook (`GoStringer`). ⚠️ `%#v` does **not use** `Stringer`; it builds a
// Go-syntax representation and prints the fields directly, so the masking in `String()` above does not
// reach it (measured 2026-09-12). ⚠️ This hook changes **only** `%#v` — `%v`/`%+v`/`%s` still go
// through `String()` (a control test pins this). ⚠️ `json.Marshal` is a separate path and is not
// blocked here (it round-trips, so storing `***` is worse).
func (a AuthorizationRequest) GoString() string { return a.String() }

func (a AuthorizationRequest) LogValue() slog.Value { return slog.StringValue(a.String()) }
