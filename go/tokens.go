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

// ⚠️ **값 리시버여야 한다.** 포인터 리시버로 달면 `TokenSet` 값은 fmt.Stringer 를 만족하지
// 않아 `fmt.Printf("%v", ts)` 가 필드를 그대로 찍는다 — 실측(수정 전): 값은 access/refresh
// 토큰을 원문으로 냈고 포인터만 마스킹됐다. 값 리시버면 값과 포인터가 **둘 다** 마스킹된다.
func (t TokenSet) String() string {
	return fmt.Sprintf("TokenSet{TokenType:%q, ExpiresIn:%d, AccessToken:%s, RefreshToken:%s}",
		t.TokenType, t.ExpiresIn, mask(t.AccessToken), mask(t.RefreshToken))
}

// LogValue 는 `log/slog` 의 마스킹 훅이다. JSONHandler 는 Stringer 를 타지 않고 리플렉션으로
// 필드를 직렬화하므로 String() 만으로는 구조화 로그가 원문을 낸다(실측 확인).
//
// ⚠️ 여기에 `MarshalJSON` 을 다는 것은 **틀린 선택이다.** 그러면 소비자가 TokenSet 을 세션·캐시에
// 직렬화해 왕복시킬 때 마스킹된 값이 저장된다 — .NET 이 자기 converter 의 Read 를 throw 로
// 막아야 했던 이유가 그것이다. LogValuer 는 로깅 경로만 바꾸고 왕복을 깨지 않는다.
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

// ⚠️ 이 타입에는 오래 String() 이 없었다 — 그래서 `fmt.Printf("%v", req)` 가 PKCE CodeVerifier 를
// 원문으로 찍었고, CreateAuthorizationRequest 는 **값**을 돌려주므로 그것이 소비자가 손에 쥐는
// 바로 그 값이다. CodeVerifier 는 코드 교환의 소유 증명 비밀이라, 인가 코드를 훔친 공격자가
// 로그에서 이 값을 얻으면 흐름을 완성한다.
// URL/State/Nonce 는 가리지 않는다 — Rust 의 Debug impl 과 동형이다(거기서도 code_verifier 만 가린다).
func (a AuthorizationRequest) String() string {
	return fmt.Sprintf("AuthorizationRequest{URL:%q, State:%q, Nonce:%q, CodeVerifier:%s}",
		a.URL, a.State, a.Nonce, mask(a.CodeVerifier))
}

func (a AuthorizationRequest) LogValue() slog.Value { return slog.StringValue(a.String()) }
