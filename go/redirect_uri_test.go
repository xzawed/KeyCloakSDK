package keycloak

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/url"
	"slices"
	"strings"
	"testing"
)

// BuildAuthorizationRequest 의 redirectURI 규칙 — 등록부 authz-request-redirect-unvalidated.
//
//	R1  RFC 6749 §3.1.2 "The redirection endpoint URI MUST be an absolute URI" — 스킴 + ":" 로 시작한다.
//	R2  같은 절 "MUST NOT include a fragment component" — `#` 가 어디에도 없다(빈 fragment 도 fragment 다).
//	R3  RFC 3986 §2 밖의 문자 — Keycloak 은 받은 redirect_uri 를 java.net.URI.create 로 파싱하고, 그것이 던지면
//	    어느 클라이언트 등록에서도 거부한다(RedirectUtils.toUri). 잘못된 UTF-8 도 여기다.
//	R4  문자는 R3 안이지만 URI.create 가 거부하는 모양 — scheme 뒤가 빈 값, scheme 뒤가 "//" 뿐인 값, query 앞의 `[` `]`
//	    (괄호 친 IPv6 호스트 하나 밖), 괄호 안이 IPv6 리터럴이 아닌 값, 2147483647 을 넘는 포트. 문구는 R3 과 같다(등록부
//	    redirect-uri-r3-narrower-than-keycloak · redirect-uri-create-residuals).
//
// 순서는 R1 · R2 · R3 · R4 이고, 거부만 한다 — URL 은 호출자의 문자열을 그대로 싣는다(코드 교환이 그 문자열을 그대로
// 보내므로 한쪽만 고치면 #1133 의 결함이다). 문구는 정확히 아래 셋이고 입력을 인용하지 않는다.
const (
	wantRedirectR1 = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)"
	wantRedirectR2 = "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)"
	wantRedirectR3 = "invalid redirect_uri: not a valid URI (RFC 3986 §2)"
)

func newRedirectTestClient(t *testing.T) *Client {
	t.Helper()
	c, err := New(Config{ServerURL: "https://kc.example.com", Realm: "demo", ClientID: "app"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// requireRedirectRefused 는 BuildAuthorizationRequest(in) 이 정확히 want 문구의 *ConfigError 로 거부되고, 아무것도
// 만들지 않았음(영값)을 단언한다.
func requireRedirectRefused(t *testing.T, a *AuthClient, in, want string) {
	t.Helper()
	ar, err := a.BuildAuthorizationRequest(in)
	if err == nil {
		t.Fatalf("BuildAuthorizationRequest(%q) accepted — want %q (URL %s)", in, want, ar.URL)
	}
	var ce *ConfigError
	if !errors.As(err, &ce) {
		t.Fatalf("BuildAuthorizationRequest(%q): want *ConfigError, got %T: %v", in, err, err)
	}
	if ce.Msg != want {
		t.Fatalf("BuildAuthorizationRequest(%q): Msg = %q, want %q", in, ce.Msg, want)
	}
	if err.Error() != "keycloak: "+want {
		t.Fatalf("BuildAuthorizationRequest(%q): Error() = %q", in, err.Error())
	}
	if ar != (AuthorizationRequest{}) {
		t.Fatalf("BuildAuthorizationRequest(%q): a refused call must build nothing, got %+v", in, ar)
	}
}

func TestBuildAuthorizationRequestRefusesRedirectURIs(t *testing.T) {
	a := newRedirectTestClient(t).Auth
	for _, c := range []struct{ name, in, want string }{
		// R1 — 절대 URI 가 아니다.
		{"empty", "", wantRedirectR1},
		{"relative", "cb", wantRedirectR1},
		{"absolute-path", "/cb", wantRedirectR1},
		{"network-path", "//app/cb", wantRedirectR1},
		{"not-a-url", "not a url", wantRedirectR1},
		// 순서 — R1 이 R2 보다 먼저다.
		{"relative-with-fragment", "cb#f", wantRedirectR1},
		// R2 — fragment 성분. 빈 fragment 도 fragment 다.
		{"empty-fragment", "https://app/cb#", wantRedirectR2},
		{"fragment", "https://app/cb#f", wantRedirectR2},
		// 순서 — R2 가 R3 보다 먼저다.
		{"space-and-fragment", "https://app/c b#f", wantRedirectR2},
		// R3 — Keycloak 의 URI.create 가 던지는 값.
		{"space", "https://app/c b", wantRedirectR3},
		{"trailing-newline", "https://app/cb\n", wantRedirectR3},
		{"backslash", "https://app/c\\b", wantRedirectR3},
		{"bad-percent", "https://app/c%zz", wantRedirectR3},
		{"nbsp", "https://app/c" + string(rune(0xa0)) + "b", wantRedirectR3},
		{"invalid-utf8", "https://app/c\xffb", wantRedirectR3},
		// R3 — U+00A0 위의 유니코드 공백 구분자(Amendment 3).
		{"ideographic-space", "https://app/c" + string(rune(0x3000)) + "b", wantRedirectR3},
		{"line-separator", "https://app/c" + string(rune(0x2028)) + "b", wantRedirectR3},
		// R4 — 문자는 RFC 3986 §2 안이지만 Keycloak 의 URI.create 가 거부하는 모양(JDK 21.0.8 실측, 등록부
		// redirect-uri-r3-narrower-than-keycloak). 문구는 R3 과 같다.
		{"empty-after-scheme", "https:", wantRedirectR3},
		{"empty-after-opaque-scheme", "myapp:", wantRedirectR3},
		{"open-bracket-in-path", "https://app/c[b", wantRedirectR3},
		{"close-bracket-in-path", "https://app/c]b", wantRedirectR3},
		{"bracket-in-path-without-authority", "myapp:/c[b", wantRedirectR3},
		{"bracket-in-path-after-ipv6-host", "https://[::1]/c[b", wantRedirectR3},
		{"bracket-in-reg-name", "https://app[1]/cb", wantRedirectR3},
		{"stray-bracket-after-ipv6-host", "https://[::1]]/cb", wantRedirectR3},
		{"two-bracketed-hosts", "https://[::1][::2]/cb", wantRedirectR3},
		{"bracket-in-userinfo", "https://u[@[::1]/cb", wantRedirectR3},
		{"non-digit-port-after-ipv6-host", "https://[::1]:x/cb", wantRedirectR3},
		// 순서 — R1 · R2 가 R4 보다 먼저다. R3 과 R4 둘 다 걸리면 R3 의 칸이다(같은 문구 — 갈래는
		// TestRedirectURIR3IsJudgedBeforeR4 가 잰다).
		{"r4-without-scheme", "//[::1]]/cb", wantRedirectR1},
		{"r4-with-fragment", "https://app/c[b#f", wantRedirectR2},
		{"r3-and-r4", "https://app/c[b c", wantRedirectR3},
	} {
		t.Run(c.name, func(t *testing.T) { requireRedirectRefused(t, a, c.in, c.want) })
	}
}

// R3 의 문자 집합 전수 — U+0000–U+0020 · U+007F–U+00A0 · 유니코드 공백 구분자(U+1680 · U+2000–U+200A · U+2028 ·
// U+2029 · U+202F · U+205F · U+3000) · ASCII 아홉(" < > \ ^ ` { | }) · 16진 두 자리가 따르지 않는 %.
// 경계 바로 밖(U+0021 · U+007E · U+00A1 · U+200B …)은 아래 수락 시험이 잰다.
func TestBuildAuthorizationRequestR3CharacterSet(t *testing.T) {
	a := newRedirectTestClient(t).Auth
	var refused []string
	for r := rune(0); r <= 0x20; r++ {
		refused = append(refused, "https://app/c"+string(r)+"b")
	}
	for r := rune(0x7f); r <= 0xa0; r++ {
		refused = append(refused, "https://app/c"+string(r)+"b")
	}
	separators := []rune{0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000}
	for r := rune(0x2000); r <= 0x200a; r++ {
		separators = append(separators, r)
	}
	for _, r := range separators {
		refused = append(refused, "https://app/c"+string(r)+"b")
	}
	for _, r := range "\"<>\\^`{|}" {
		refused = append(refused, "https://app/c"+string(r)+"b")
	}
	refused = append(refused,
		"https://app/cb%", "https://app/cb%2", "https://app/c%2zb", "https://app/c%z2b", "https://app/c%%20b",
		"https://app/cb?x=%G0",
		// 잘못된 UTF-8 — 홀로 선 연속 바이트 · 잘린 다중 바이트 · 서로게이트의 UTF-8 꼴.
		"https://app/c\x80b", "https://app/c\xc3", "https://app/c\xed\xa0\x80b")
	for _, in := range refused {
		requireRedirectRefused(t, a, in, wantRedirectR3)
	}
}

// R3 과 R4 가 둘 다 거부하는 값은 R3 의 칸이다 — 문구가 같아 바깥에서는 안 보이므로 술어를 직접 본다: 둘 다 그 값을
// 거부하고, checkRedirectURI 는 R3 의 문구를 낸다(switch 의 순서). R4 만 거부하는 값의 대조도 함께.
func TestRedirectURIR3IsJudgedBeforeR4(t *testing.T) {
	both := "https://app/c[b c"
	if uriChars(both) || uriShape(both) {
		t.Fatalf("%q must fail R3 (%v) and R4 (%v)", both, uriChars(both), uriShape(both))
	}
	if err := checkRedirectURI(both); err == nil || err.Error() != "keycloak: "+wantRedirectR3 {
		t.Fatalf("checkRedirectURI(%q) = %v, want R3", both, err)
	}
	onlyR4 := "https://app/c[b"
	if !uriChars(onlyR4) || uriShape(onlyR4) {
		t.Fatalf("%q must pass R3 (%v) and fail R4 (%v)", onlyR4, uriChars(onlyR4), uriShape(onlyR4))
	}
}

// requireRedirectAccepted 는 BuildAuthorizationRequest(in) 이 CreateAuthorizationRequest 가 만드는 것과 같은 꼴의
// URL 을 만들고, 그 redirect_uri 파라미터가 디코드해 입력과 정확히 같음을 단언한다(검사만 하고 고치지 않는다).
func requireRedirectAccepted(t *testing.T, a *AuthClient, in string) AuthorizationRequest {
	t.Helper()
	ar, err := a.BuildAuthorizationRequest(in)
	if err != nil {
		t.Fatalf("BuildAuthorizationRequest(%q) refused: %v", in, err)
	}
	u, err := url.Parse(ar.URL)
	if err != nil {
		t.Fatalf("BuildAuthorizationRequest(%q): bad URL %q: %v", in, ar.URL, err)
	}
	if got := u.Scheme + "://" + u.Host + u.Path; got != "https://kc.example.com/realms/demo/protocol/openid-connect/auth" {
		t.Fatalf("BuildAuthorizationRequest(%q): endpoint %s", in, got)
	}
	q := u.Query()
	if got := q["redirect_uri"]; len(got) != 1 || got[0] != in {
		t.Fatalf("BuildAuthorizationRequest(%q): redirect_uri = %q, want exactly the input", in, got)
	}
	if ar.CodeVerifier == "" || ar.State == "" || ar.Nonce == "" {
		t.Fatalf("BuildAuthorizationRequest(%q): verifier/state/nonce must be set: %+v", in, ar)
	}
	sum := sha256.Sum256([]byte(ar.CodeVerifier))
	for k, want := range map[string]string{
		"response_type": "code", "client_id": "app", "scope": "openid", "code_challenge_method": "S256",
		"code_challenge": base64.RawURLEncoding.EncodeToString(sum[:]), "state": ar.State, "nonce": ar.Nonce,
	} {
		if got := q.Get(k); got != want {
			t.Errorf("BuildAuthorizationRequest(%q): %s = %q, want %q", in, k, got, want)
		}
	}
	return ar
}

func TestBuildAuthorizationRequestAcceptsAbsoluteURIs(t *testing.T) {
	a := newRedirectTestClient(t).Auth
	for _, in := range []string{
		"https://app/cb", "https://app/cb?x=1", "myapp:/cb", "com.example.app:/oauth2redirect", "HTTP://LOCALHOST/cb",
		// R3 대조 — Keycloak 의 URI.create 가 받는 값.
		"https://app/c%20b", "https://app/cüb", "https://app/cb?x=[1]",
		// R3 경계 바로 밖 — U+0021 · U+007E · U+00A1, 그리고 RFC 3986 의 나머지 구분자.
		"https://app/c!b", "https://app/c~b", "https://app/c" + string(rune(0xa1)) + "b", "https://app/c'b",
		"https://app/cb?x=$&y=(+*,;=)@:", "https://app/c%aFb", "https://app/cb%2F",
		// 공백 구분자가 아닌 이웃 — URI.create 가 받는다(JDK 21.0.8 실측): U+00AD · U+200B · U+FEFF · U+1F600.
		"https://app/c" + string(rune(0xad)) + "b", "https://app/c" + string(rune(0x200b)) + "b",
		"https://app/c" + string(rune(0xfeff)) + "b", "https://app/c" + string(rune(0x1f600)) + "b",
		// R4 대조 — URI.create 가 받는다(JDK 21.0.8 실측): 괄호 친 IPv6 호스트 하나(userinfo · 포트 포함) · 쿼리의 괄호 ·
		// 불투명 값의 괄호 · scheme 뒤 "/" 하나. 괄호 안의 내용 · 포트의 크기 · 빈 authority 는 아래 표가 잰다
		// (TestBuildAuthorizationRequestFollowsTheJDKTable).
		"https://[::1]/cb", "https://[::1]:8443/cb", "https://u@[::1]:8443/cb", "https://[::1]", "https://[::1]:/cb",
		"https://[::1]?x=[2]", "myapp:c[b", "urn:x[y]", "https:/",
	} {
		requireRedirectAccepted(t, a, in)
	}
}

// java.net.URI.create 의 실측 표(JDK 21.0.8, 83 값 — 빈 authority · 괄호 호스트의 내용 · zone id · 포트 · userinfo · 괄호
// 없는 호스트, 등록부 redirect-uri-create-residuals). 줄 끝은 JDK 의 거부 문구다.
var jdkRefusedRedirectURIs = []string{
	"https://",                           // Expected authority
	"myapp://",                           // Expected authority
	"https://[zz]/cb",                    // Malformed IPv6 address
	"https://[v1.x]/cb",                  // Malformed IPv6 address
	"https://[::1::2]/cb",                // Expected hex digits or IPv4 address
	"https://[1:2:3:4:5:6:7:8:9]/cb",     // IPv6 address too long
	"https://[1:2:3:4:5:6:7:8::]/cb",     // Malformed IPv6 address
	"https://[::1:2:3:4:5:6:7:8]/cb",     // Malformed IPv6 address
	"https://[1:2:3:4:5:6:7]/cb",         // IPv6 address too short
	"https://[:]/cb",                     // Malformed IPv6 address
	"https://[:::]/cb",                   // Expected hex digits or IPv4 address
	"https://[1:::2]/cb",                 // Expected hex digits or IPv4 address
	"https://[::1:]/cb",                  // Expected digits for an IPv6 address
	"https://[:1::2]/cb",                 // Malformed IPv6 address
	"https://[1::2:]/cb",                 // Expected digits for an IPv6 address
	"https://[12345::]/cb",               // IPv6 hexadecimal digit sequence too long
	"https://[1.2.3.4]/cb",               // Malformed IPv6 address
	"https://[::ffff:256.2.3.4]/cb",      // Malformed IPv4 address
	"https://[::ffff:1.2.3]/cb",          // Malformed IPv4 address
	"https://[::ffff:1.2.3.4.5]/cb",      // Malformed IPv4 address
	"https://[::ffff:1.2.3.]/cb",         // Malformed IPv4 address
	"https://[::ffff:.1.2.3]/cb",         // Expected digits for an IPv6 address
	"https://[::ffff:1..2.3]/cb",         // Malformed IPv4 address
	"https://[1:2:3:4:5:6:7:1.2.3.4]/cb", // IPv6 address too long
	"https://[1:2:3:4:5:1.2.3.4]/cb",     // IPv6 address too short
	"https://[1:2:3:4:5:6::1.2.3.4]/cb",  // Malformed IPv6 address
	"https://[::1.2.3.4:5]/cb",           // Expected hex digits or IPv4 address
	"https://[1.2.3.4::]/cb",             // Malformed IPv6 address
	"https://[::99999999999.2.3.4]/cb",   // NumberFormatException
	"https://[::1.2.3.9999999999999]/cb", // NumberFormatException
	"https://[fe80::1%]/cb",              // scope id expected
	"https://[fe80::1%25en-1]/cb",        // Illegal character in scope id
	"https://[fe80::1%25a%25b]/cb",       // Illegal character in scope id
	"https://[fe80::1%25a~b]/cb",         // Illegal character in scope id
	"https://[fe80::1%25é]/cb",           // Illegal character in scope id
	"https://[%25::1]/cb",                // Malformed IPv6 address
	"https://[::1]:2147483648/cb",        // Malformed port number
	"https://[::1]:99999999999/cb",       // Malformed port number
	"https://a@b@[::1]/cb",               // Illegal character in hostname
	"myapp://[zz]/cb",                    // Malformed IPv6 address
}

var jdkAcceptedRedirectURIs = []string{
	"https:///", "https:///cb", "https://?x=1", "https://u@/cb", "https://:80/cb", "https://@/cb", "https:/",
	"https://[::1]/cb", "https://[1:2:3:4:5:6:7:8]/cb", "https://[1:2:3:4:5:6:7::]/cb", "https://[::1:2:3:4:5:6:7]/cb",
	"https://[::]/cb", "https://[ABCD::EF]/cb", "https://[abcd:EF01::]/cb", "https://[0001:2:3:4:5:6:7:8]/cb",
	"https://[::ffff:1.2.3.4]/cb", "https://[::1.2.3.4]/cb", "https://[::ffff:01.2.3.4]/cb",
	"https://[::ffff:0001.2.3.4]/cb", "https://[::ffff:00000000255.2.3.4]/cb", "https://[1:2:3:4:5:6:1.2.3.4]/cb",
	"https://[1::1.2.3.4]/cb", "https://[1:2:3:4:5::1.2.3.4]/cb",
	"https://[fe80::1%eth0]/cb", "https://[fe80::1%25eth0]/cb", "https://[fe80::1%25]/cb",
	"https://[fe80::1%25a_b.c]/cb", "https://[::1%1]/cb", "https://[::1%zz]/cb",
	"https://[::1]:/cb", "https://[::1]:8443/cb", "https://[::1]:2147483647/cb", "https://[::1]:00000000000000000080/cb",
	"https://h:99999999999/cb", "https://u@[::1]:8443/cb", "https://u:p@[::1]/cb", "https://[::1]", "https://[::1]?x=[1]",
	"myapp://[::1]/cb", "https://my_host/cb", "https://999.1.1.1/cb", "https://host:abc/cb", "https://hé/cb",
}

// 의도된 차이 — URI.create 는 zone id 의 맨 '%'(16진 두 자리가 따르지 않는다)를 받지만 R3 가 거부한다: RFC 6874 §2 는 URI
// 안에서 zone id 구분자를 "%25" 로 쓰라고 한다(`[fe80::1%25eth0]` 는 둘 다 받는다).
var zoneIDsRefusedByR3 = []string{"https://[fe80::1%eth0]/cb", "https://[::1%1]/cb", "https://[::1%zz]/cb"}

// 표 그대로 — URI.create 가 받은 값은 그대로 실리고, 거부한 값은 R3 의 문구로 거부된다. 단 zone id 셋은 받은 값이지만 거부다.
func TestBuildAuthorizationRequestFollowsTheJDKTable(t *testing.T) {
	if len(jdkRefusedRedirectURIs) != 40 || len(jdkAcceptedRedirectURIs) != 43 {
		t.Fatalf("the JDK table has 40 refused and 43 accepted rows, got %d and %d",
			len(jdkRefusedRedirectURIs), len(jdkAcceptedRedirectURIs))
	}
	a := newRedirectTestClient(t).Auth
	for _, in := range jdkRefusedRedirectURIs {
		t.Run("refused "+in, func(t *testing.T) { requireRedirectRefused(t, a, in, wantRedirectR3) })
	}
	for _, in := range jdkAcceptedRedirectURIs {
		if slices.Contains(zoneIDsRefusedByR3, in) {
			t.Run("zone id "+in, func(t *testing.T) { requireRedirectRefused(t, a, in, wantRedirectR3) })
			continue
		}
		t.Run("accepted "+in, func(t *testing.T) { requireRedirectAccepted(t, a, in) })
	}
}

// 그 차이가 R3 의 것임을 술어로 본다 — 바깥 문구는 R3 와 R4 가 같다. R4 는 zone id 셋을 Java 처럼 받는다.
func TestRedirectURIZoneIDNeedsPercent25(t *testing.T) {
	for _, in := range zoneIDsRefusedByR3 {
		if uriChars(in) || !uriShape(in) {
			t.Errorf("%q: want R3 to refuse (got %v) and R4 to accept (got %v)", in, uriChars(in), uriShape(in))
		}
	}
	if in := "https://[fe80::1%25eth0]/cb"; !uriChars(in) || !uriShape(in) {
		t.Errorf("%q: want R3 and R4 to accept, got %v and %v", in, uriChars(in), uriShape(in))
	}
}

// PKCE·state·nonce 는 호출마다 새로 만든다 — CreateAuthorizationRequest 와 같다.
func TestBuildAuthorizationRequestIsFreshPerCall(t *testing.T) {
	a := newRedirectTestClient(t).Auth
	x := requireRedirectAccepted(t, a, "https://app/cb")
	y := requireRedirectAccepted(t, a, "https://app/cb")
	if x.CodeVerifier == y.CodeVerifier || x.State == y.State || x.Nonce == y.Nonce {
		t.Fatal("verifier/state/nonce must differ per call")
	}
}

// 문구는 입력을 인용하지 않는다 — 호출자가 무엇을 넣었든(로그·오류 응답으로 새지 않게).
func TestBuildAuthorizationRequestMessageDoesNotQuoteTheInput(t *testing.T) {
	a := newRedirectTestClient(t).Auth
	for _, in := range []string{"cb-CANARY-7d1f", "https://app/cb#CANARY-7d1f", "https://app/c CANARY-7d1f"} {
		_, err := a.BuildAuthorizationRequest(in)
		if err == nil {
			t.Fatalf("BuildAuthorizationRequest(%q) accepted", in)
		}
		if strings.Contains(err.Error(), "CANARY") {
			t.Fatalf("the refusal quotes the input: %q", err.Error())
		}
	}
}

// 호환 핀 — deprecated CreateAuthorizationRequest 의 동작은 그대로다: 무엇이든 URL 에 싣는다.
func TestCreateAuthorizationRequestStillPlacesAnyString(t *testing.T) {
	a := newRedirectTestClient(t).Auth
	for _, in := range []string{"cb", "https://app/cb#f", "https://app/c b"} {
		ar := a.CreateAuthorizationRequest(in)
		u, err := url.Parse(ar.URL)
		if err != nil {
			t.Fatalf("CreateAuthorizationRequest(%q): bad URL %q: %v", in, ar.URL, err)
		}
		if got := u.Query().Get("redirect_uri"); got != in {
			t.Fatalf("CreateAuthorizationRequest(%q): redirect_uri = %q", in, got)
		}
	}
}
