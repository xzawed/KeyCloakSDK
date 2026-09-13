package keycloak

import (
	"fmt"
	"strings"
	"testing"
)

// **덤프 경로** 마스킹 — `%#v` 가 비밀을 원문으로 찍지 않는가.
//
// ⚠️ 이것은 축의 **바닥(기본 문자열 표현)이 아니라 그 밖**이다. `String()` 은 `%v`·`%+v`·`%s`
// 를 이미 마스킹하는데, `%#v` 는 `Stringer` 를 **쓰지 않고** Go 문법 표현을 만들어 필드를 직접
// 찍는다(실측 2026-09-12). `GoStringer`(`GoString() string`)가 그 경로의 훅이다.
//
// ⚠️ **`json.Marshal` 은 여기서 고치지 않는다.** `MarshalJSON` 을 넣으면 소비자가 토큰을
// 세션 저장소에 넣을 때 `***` 가 저장된다 — 덤프는 단방향이지만 JSON 은 왕복이라 부류가 다르다.
// `tokens.go` 의 기존 주석이 그 판정을 소유한다.
func TestGoSyntaxVerbDoesNotLeak(t *testing.T) {
	const tok = "AT-CENSUS-TOKEN"
	const sec = "SECRET-CENSUS"

	cases := []struct {
		name string
		v    any
	}{
		{"TokenSet", TokenSet{AccessToken: tok, RefreshToken: tok, IDToken: tok}},
		{"AuthorizationRequest", AuthorizationRequest{URL: "http://x", State: "s", CodeVerifier: tok, Nonce: "n"}},
		{"Config", Config{ServerURL: "http://kc", Realm: "r", ClientID: "c", ClientSecret: sec}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := fmt.Sprintf("%#v", c.v)
			if strings.Contains(got, tok) {
				t.Errorf("%%#v 가 토큰을 원문으로 찍는다: %s", got)
			}
			if strings.Contains(got, sec) {
				t.Errorf("%%#v 가 시크릿을 원문으로 찍는다: %s", got)
			}
			if !strings.Contains(got, "***") {
				t.Errorf("%%#v 에 마스킹 표시가 없다: %s", got)
			}
		})
	}
}

// ⚠️ 대조군 — `GoString` 을 더해도 `%v`·`%+v` 는 **여전히 `String()`** 을 탄다(실측).
// 이것이 깨지면 기존 로깅 계약이 조용히 바뀐 것이다.
func TestStringerStillOwnsPlainVerbs(t *testing.T) {
	ts := TokenSet{AccessToken: "AT-CENSUS-TOKEN"}
	for _, verb := range []string{"%v", "%+v", "%s"} {
		got := fmt.Sprintf(verb, ts)
		if got != ts.String() {
			t.Errorf("%s 가 String() 과 다르다: %q vs %q", verb, got, ts.String())
		}
	}
}
