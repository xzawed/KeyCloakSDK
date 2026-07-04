package keycloak

import (
	"strings"
	"testing"
	"time"

	"golang.org/x/oauth2"
)

func TestTokenSetFromToken(t *testing.T) {
	tok := (&oauth2.Token{
		AccessToken:  "AT",
		TokenType:    "Bearer",
		RefreshToken: "RT",
		ExpiresIn:    300,
		Expiry:       time.Unix(1000300, 0),
	}).WithExtra(map[string]any{"id_token": "IDT", "scope": "openid"})

	ts := tokenSetFromToken(tok)
	if ts.AccessToken != "AT" || ts.TokenType != "Bearer" || ts.RefreshToken != "RT" {
		t.Fatalf("basic mapping: %+v", ts)
	}
	if ts.ExpiresIn != 300 || ts.ExpiresAt != 1000300 || ts.IDToken != "IDT" || ts.Scope != "openid" {
		t.Fatalf("extended mapping: %+v", ts)
	}
}

func TestTokenSetStringMasks(t *testing.T) {
	ts := &TokenSet{AccessToken: "SECRETat", RefreshToken: "SECRETrt", TokenType: "Bearer", ExpiresIn: 60}
	s := ts.String()
	if strings.Contains(s, "SECRETat") || strings.Contains(s, "SECRETrt") {
		t.Fatalf("String must mask access+refresh: %q", s)
	}
	if !strings.Contains(s, "***") {
		t.Fatalf("String must contain mask: %q", s)
	}
}

func TestTokenSetIsExpired(t *testing.T) {
	ts := &TokenSet{ExpiresAt: 1000300}
	if ts.IsExpired(1000000, 30) {
		t.Fatal("not expired 300s before, skew 30")
	}
	if !ts.IsExpired(1000280, 30) {
		t.Fatal("expired: 1000280+30 >= 1000300")
	}
	if !(&TokenSet{ExpiresAt: 0}).IsExpired(0, 0) {
		t.Fatal("unknown ExpiresAt treated as expired")
	}
}
