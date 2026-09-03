package keycloak

import (
	"bytes"
	"fmt"
	"log/slog"
	"strings"
	"testing"
)

func TestMask(t *testing.T) {
	if got := mask("supersecret"); got != "***" {
		t.Fatalf("mask must be fully opaque, got %q", got)
	}
	if got := mask(""); got != "***" {
		t.Fatalf("empty also masked, got %q", got)
	}
}

// 카나리아 상수 — 이 문자열이 출력에 나타나면 마스킹이 뚫린 것이다.
const (
	canaryAccess   = "CANARY_ACCESS_TOKEN"
	canaryRefresh  = "CANARY_REFRESH_TOKEN"
	canarySecret   = "CANARY_CLIENT_SECRET"
	canaryVerifier = "CANARY_CODE_VERIFIER"
)

func assertMasked(t *testing.T, label, out string, canaries ...string) {
	t.Helper()
	for _, c := range canaries {
		if strings.Contains(out, c) {
			t.Errorf("%s: 비밀이 원문으로 노출됐다 (%s)\n  출력: %s", label, c, out)
		}
	}
	if !strings.Contains(out, "***") {
		t.Errorf("%s: 마스킹 표식(***)이 없다\n  출력: %s", label, out)
	}
}

// 교차언어 보안 기본선의 **바닥 계약**: 그 언어의 기본 문자열/디버그 표현이 비밀을 `***` 로
// 낸다. Go 에서 그 경로는 `fmt` 의 %v/%s — 즉 Stringer 다.
//
// ⚠️ 값과 포인터를 **둘 다** 잰다. `String()` 을 포인터 리시버로 달면 **값은 Stringer 가
// 아니어서** `fmt.Printf("%v", ts)` 가 필드를 그대로 찍는다. 실측(수정 전):
//
//	TokenSet(값)             → LEAK  CANARY_ACCESS_TOKEN
//	TokenSet(포인터)          → OK
//	AuthorizationRequest     → LEAK  CANARY_CODE_VERIFIER  (String 자체가 없었다)
//
// CreateAuthorizationRequest 는 값을 돌려주므로 소비자가 손에 쥐는 것이 정확히 그 값이다.
func TestDefaultStringReprMasksSecrets(t *testing.T) {
	ts := TokenSet{AccessToken: canaryAccess, TokenType: "Bearer", RefreshToken: canaryRefresh}
	cfg := Config{ServerURL: "https://kc", Realm: "r", ClientID: "c", ClientSecret: canarySecret}
	ar := AuthorizationRequest{URL: "https://kc/auth", CodeVerifier: canaryVerifier, State: "st", Nonce: "no"}

	for _, verb := range []string{"%v", "%s", "%+v"} {
		assertMasked(t, "TokenSet(값) "+verb, fmt.Sprintf(verb, ts), canaryAccess, canaryRefresh)
		assertMasked(t, "TokenSet(포인터) "+verb, fmt.Sprintf(verb, &ts), canaryAccess, canaryRefresh)
		assertMasked(t, "Config(값) "+verb, fmt.Sprintf(verb, cfg), canarySecret)
		assertMasked(t, "Config(포인터) "+verb, fmt.Sprintf(verb, &cfg), canarySecret)
		assertMasked(t, "AuthorizationRequest(값) "+verb, fmt.Sprintf(verb, ar), canaryVerifier)
		assertMasked(t, "AuthorizationRequest(포인터) "+verb, fmt.Sprintf(verb, &ar), canaryVerifier)
	}
}

// 바닥 **위**의 개선: log/slog 의 JSONHandler 는 Stringer 를 타지 않고 리플렉션으로
// 필드를 직렬화한다 — Go 서비스의 기본 구조화 로깅 경로다. 관용 훅은 `slog.LogValuer` 이며,
// `MarshalJSON` 과 달리 **소비자의 JSON 왕복을 깨지 않는다**(세션·캐시에 저장한 TokenSet 이
// 마스킹된 값으로 바뀌지 않는다). 그래서 LogValuer 를 고른다.
func TestSlogHandlersMaskSecrets(t *testing.T) {
	ts := TokenSet{AccessToken: canaryAccess, TokenType: "Bearer", RefreshToken: canaryRefresh}
	cfg := Config{ServerURL: "https://kc", Realm: "r", ClientID: "c", ClientSecret: canarySecret}
	ar := AuthorizationRequest{URL: "https://kc/auth", CodeVerifier: canaryVerifier, State: "st", Nonce: "no"}

	for _, h := range []struct {
		name string
		make func(*bytes.Buffer) slog.Handler
	}{
		{"JSONHandler", func(b *bytes.Buffer) slog.Handler { return slog.NewJSONHandler(b, nil) }},
		{"TextHandler", func(b *bytes.Buffer) slog.Handler { return slog.NewTextHandler(b, nil) }},
	} {
		for _, c := range []struct {
			label string
			val   any
			cans  []string
		}{
			{"TokenSet(값)", ts, []string{canaryAccess, canaryRefresh}},
			{"TokenSet(포인터)", &ts, []string{canaryAccess, canaryRefresh}},
			{"Config(값)", cfg, []string{canarySecret}},
			{"AuthorizationRequest(값)", ar, []string{canaryVerifier}},
		} {
			var buf bytes.Buffer
			slog.New(h.make(&buf)).Info("probe", "v", c.val)
			assertMasked(t, h.name+" "+c.label, buf.String(), c.cans...)
		}
	}
}
