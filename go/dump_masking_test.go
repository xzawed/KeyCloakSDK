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

// `fmt.Formatter`(formatMasked)는 문자열 동사가 Stringer · GoStringer 로 찍던 것을 **바이트 그대로** 찍는다 —
// 너비 · 정밀도 · 플래그까지. 비교 대상은 String() 에 같은 동사를 건 값이다(Stringer 가 하던 일이 그것이다).
// 이것이 깨지면 비밀은 안 새도 소비자의 로그 꼴이 조용히 바뀐다.
func TestFormatterKeepsTheStringVerbOutputs(t *testing.T) {
	cfg := Config{ServerURL: "http://kc", Realm: "r", ClientID: "c", ClientSecret: "SECRET-CENSUS"}
	ts := TokenSet{AccessToken: "AT-CENSUS-TOKEN", TokenType: "Bearer"}
	for _, v := range []fmt.Stringer{cfg, &cfg, ts, &ts} {
		for _, verb := range []string{"%v", "%+v", "%s", "%q", "%x", "%X", "%-120v|", "%120s|", "%.12s", "%#q"} {
			if got, want := fmt.Sprintf(verb, v), fmt.Sprintf(verb, v.String()); got != want {
				t.Errorf("%T %s 가 Stringer 시절과 다르다:\n got  %q\n want %q", v, verb, got, want)
			}
		}
		// %#v 는 GoString() 을 꾸밈없이 — 따옴표 없이, 너비 · 정밀도만(fmt 의 GoStringer 처리).
		gs := v.(fmt.GoStringer).GoString()
		for verb, want := range map[string]string{"%#v": gs, "%#120v|": fmt.Sprintf("%120s|", gs), "%#.9v": gs[:9]} {
			if got := fmt.Sprintf(verb, v); got != want {
				t.Errorf("%T %s 가 GoStringer 시절과 다르다:\n got  %q\n want %q", v, verb, got, want)
			}
		}
	}
}

// 문자열이 아닌 동사(%d %b %e …)는 String() 을 건너뛰고 필드를 찍었다(실측 2026-11-17 — 등록부
// `go-nonstring-verb-bypasses-stringer`). 이제 fmt 자신의 잘못된-동사 꼴로 **가린 문자열**만 찍는다.
func TestFormatterWrapsOtherVerbsAroundTheMaskedString(t *testing.T) {
	cfg := Config{ServerURL: "http://kc", Realm: "r", ClientID: "c", ClientSecret: "SECRET-CENSUS"}
	for verb, want := range map[string]string{
		"%d":   "%!d(keycloak.Config=" + cfg.String() + ")",
		"%-9t": "%!t(keycloak.Config=" + cfg.String() + ")",
		"%U":   "%!U(keycloak.Config=" + cfg.String() + ")",
	} {
		for _, v := range []any{cfg, &cfg} {
			if got := fmt.Sprintf(verb, v); got != want {
				t.Errorf("%T %s:\n got  %q\n want %q", v, verb, got, want)
			}
		}
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
