package keycloak

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// checkedAuthorizationRequest 는 BuildAuthorizationRequest 의 몸통이다 — 검사가 먼저이고(PKCE·state·nonce 를 만들기
// 전), 통과한 값만 build(CreateAuthorizationRequest)에 그대로 넘긴다. 분기를 auth.go 가 아니라 여기 두는 까닭: auth.go 는
// 단위 커버리지 경계이고 통합 커버리지 하한(scripts/integration-coverage.json)이 재는 파일인데, 통합 실행은 거부 분기를
// 밟지 않는다 — 거기 두면 안 도는 문장이 하나 는다.
func checkedAuthorizationRequest(redirectURI string, build func(string) AuthorizationRequest) (AuthorizationRequest, error) {
	if err := checkRedirectURI(redirectURI); err != nil {
		return AuthorizationRequest{}, err
	}
	return build(redirectURI), nil
}

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
//	    거부한다(RedirectUtils.toUri). 그 실측 집합과 잘못된 UTF-8 이다(uriChars). ⚠️ 남은 틈(구현하지 않는다 —
//	    Amendment 3): URI.create 는 query·host 밖의 `[` `]`(`https://app/c[b`)와 scheme 뒤가 빈 값(`https:`)도 거부하는데
//	    R1–R3 은 받는다.
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

// uriChars 는 R3 이다 — s 가 올바른 UTF-8 이고, U+0000–U+0020 · U+007F–U+00A0 · 유니코드 공백 구분자 ·
// uriExcludedASCII 의 문자도, 16진 숫자 두 개가 따르지 않는 '%' 도 없는가.
func uriChars(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for i, r := range s {
		switch {
		case r <= 0x20, r >= 0x7f && r <= 0xa0, isSpaceSeparator(r), strings.ContainsRune(uriExcludedASCII, r):
			return false
		case r == '%' && (i+2 >= len(s) || !isHexDigit(s[i+1]) || !isHexDigit(s[i+2])):
			return false
		}
	}
	return true
}

// isSpaceSeparator 는 U+00A0 위의 유니코드 공백 구분자(Zs · Zl · Zp)다 — java.net.URI 는 이것을 Character.isSpaceChar 로
// 거부한다(JDK 21.0.8 실측: U+1680 · U+2000–U+200A · U+2028 · U+2029 · U+202F · U+205F · U+3000 거부, 이웃
// U+200B · U+FEFF 수락). 표를 unicode.Zs 에 맡기지 않는다 — 판정 기준은 Keycloak 의 JDK 이지 Go 의 유니코드 판이 아니다.
func isSpaceSeparator(r rune) bool {
	switch {
	case r == 0x1680, r >= 0x2000 && r <= 0x200a, r == 0x2028, r == 0x2029, r == 0x202f, r == 0x205f, r == 0x3000:
		return true
	}
	return false
}

func isHexDigit(c byte) bool {
	return '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F'
}
