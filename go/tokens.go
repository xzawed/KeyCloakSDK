package keycloak

import (
	"fmt"

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

func (t *TokenSet) String() string {
	return fmt.Sprintf("TokenSet{TokenType:%q, ExpiresIn:%d, AccessToken:%s, RefreshToken:%s}",
		t.TokenType, t.ExpiresIn, mask(t.AccessToken), mask(t.RefreshToken))
}

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
