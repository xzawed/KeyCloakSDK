package keycloak

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// redirectScheme 는 RFC 3986 §3.1 의 scheme 과 뒤따르는 ":" 이다 — 이것으로 시작하는 값이 절대 URI 다(§4.3).
var redirectScheme = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.-]*:`)

// uriExcludedASCII 는 RFC 3986 §2 에 없는 ASCII 문장부호 중 Keycloak 의 java.net.URI.create 가 던지는 아홉이다.
const uriExcludedASCII = "\"<>\\^`{|}"

// checkRedirectURI 는 인가요청의 redirect_uri 를 보고, 쓸 수 없으면 *ConfigError 를 낸다(등록부
// authz-request-redirect-unvalidated). 순서가 계약이다 — R1 · R2 · R3:
//
//	R1  RFC 6749 §3.1.2 "MUST be an absolute URI" — scheme ":" 으로 시작한다.
//	R2  같은 절 "MUST NOT include a fragment component" — `#` 가 어디에도 없다(빈 fragment `…#` 도 fragment 다).
//	R3  RFC 3986 §2 밖 — Keycloak 은 받은 값을 java.net.URI.create 로 파싱해 그것이 던지면 어느 클라이언트 등록에서도
//	    거부한다(RedirectUtils.toUri). 그 실측 집합과 잘못된 UTF-8 이다(uriChars).
//
// 검사만 한다 — 값을 고치지 않는다. ExchangeCode 는 호출자의 문자열을 그대로 보내므로 인가요청 쪽만 정규화하면 두 요청의
// redirect_uri 가 갈라진다(#1133 의 결함). 문구는 입력을 인용하지 않는다.
func checkRedirectURI(redirectURI string) error {
	switch {
	case !redirectScheme.MatchString(redirectURI):
		return &ConfigError{Msg: "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)"}
	case strings.Contains(redirectURI, "#"):
		return &ConfigError{Msg: "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)"}
	case !uriChars(redirectURI):
		return &ConfigError{Msg: "invalid redirect_uri: not a valid URI (RFC 3986 §2)"}
	}
	return nil
}

// uriChars 는 R3 이다 — s 가 올바른 UTF-8 이고, U+0000–U+0020 · U+007F–U+00A0 · uriExcludedASCII 의 문자도,
// 16진 숫자 두 개가 따르지 않는 '%' 도 없는가.
func uriChars(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for i, r := range s {
		switch {
		case r <= 0x20, r >= 0x7f && r <= 0xa0, strings.ContainsRune(uriExcludedASCII, r):
			return false
		case r == '%' && (i+2 >= len(s) || !isHexDigit(s[i+1]) || !isHexDigit(s[i+2])):
			return false
		}
	}
	return true
}

func isHexDigit(c byte) bool {
	return '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F'
}
