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

// 부정/커버리지 테스트(PR6): x/oauth2가 절대 Expiry는 채우되 상대 ExpiresIn은 0으로 두는 경우,
// tokenSetFromToken이 Expiry에서 ExpiresIn을 파생하는 분기가 어떤 테스트로도 실행되지 않았다.
func TestTokenSetFromTokenDerivesExpiresInFromExpiry(t *testing.T) {
	tok := &oauth2.Token{
		AccessToken: "AT",
		TokenType:   "Bearer",
		Expiry:      time.Now().Add(5 * time.Minute), // ExpiresIn 미설정(0)
	}
	ts := tokenSetFromToken(tok)
	if ts.ExpiresAt != tok.Expiry.Unix() {
		t.Fatalf("ExpiresAt not set from Expiry: %d", ts.ExpiresAt)
	}
	// 5분 후 만료 → 파생된 ExpiresIn은 대략 300초(스케줄링 오차 허용).
	if ts.ExpiresIn < 290 || ts.ExpiresIn > 300 {
		t.Fatalf("ExpiresIn should be derived (~300) from Expiry, got %d", ts.ExpiresIn)
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
