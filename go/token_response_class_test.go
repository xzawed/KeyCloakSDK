package keycloak

// 토큰 응답의 오류 계급표 — 아홉 언어 판정(#935): 응답이 **끝까지 왔고** 쓸 토큰 응답이 아니면 *AuthError, 다 오지 않았거나
// (네트워크 · 마감 · 상한 초과 · 깨진 HTTP 틀) 보내지 못했으면 *TransportError 다. 행 이름의 R 번호는 #935 의 표와 같다 —
// R1 503 HTML · R2 200 비-JSON · R3 400 OAuth 오류 · R4 access_token 없음 · R5 1,048,576 B 초과 · R6 introspection 200
// 비-JSON(R2 행의 Introspect 칸). 빈 본문 둘(E1 · E2) · 자기를 가리키는 307(X1) · 본문이 끊기는 IdP(T) · 닿지 않는 IdP(N).
//
// 열은 세 레인이다 — 그랜트 셋(x/oauth2 · grantFailed) · Introspect(postForm) · admin 자기 그랜트(gocloak · loginError) —
// 그리고 공개 provider 로 그랜트를 주입한 admin. ⚠️ 위임 판정(2026-11-05, #951 본문): admin 레인도 온 응답은 상태와 무관하게
// *AuthError 다 — *AdminError 로 내면 토큰 엔드포인트의 404·403·409 가 ErrNotFound·ErrForbidden·ErrConflict 로 읽힌다
// (TestAdminTokenFailureNeverMatchesAdminSentinels). 칸 하나를 바꾸면 등록부 `token-response-class-divergent` 도 본다.

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const classUsable = `{"access_token":"at","token_type":"Bearer","expires_in":300,"refresh_token":"rt","active":true}`

var classCalls = []string{"ClientCredentialsToken", "ExchangeCode", "Refresh", "Introspect", "Admin", "NewAdminClient(provider)"}

type classRow struct {
	name     string
	status   int
	ctype    string
	body     string
	encoding string // 있으면 Content-Encoding 으로 단다(body 는 그 코딩의 바이트다)
	toSelf   bool   // Location 이 같은 token 주소다 — 따라가지 않는 SDK 는 3xx 를 그대로 받는다
	raw      string // 있으면 소켓이 이 바이트를 그대로 쓴다(newRawIdP)
	nowhere  bool   // 닿지 않는 IdP
	contains string // 있으면 실패한 모든 칸의 오류 메시지가 이것을 담는다
	expected [6]string
}

// classRows 의 기대 계급 — classCalls 순서. Introspect 의 R4 는 `active` 가 없어 *AuthError 다(RFC 7662 §2.2 REQUIRED — 판정 D3,
// 2026-11-10; 그 전에는 비활성으로 읽어 ok 였다).
var classRows = []classRow{
	{name: "ok", status: 200, ctype: "application/json", body: classUsable,
		expected: [6]string{"ok", "ok", "ok", "ok", "ok", "ok"}},
	{name: "r1-503-html", status: 503, ctype: "text/html; charset=utf-8", body: "<html><body><h1>503 Service Unavailable</h1></body></html>",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r2-200-not-json", status: 200, ctype: "text/plain", body: "not json",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r2-200-not-json-json-type", status: 200, ctype: "application/json", body: "not json",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r3-400-oauth-error", status: 400, ctype: "application/json", body: `{"error":"invalid_client","error_description":"bad client"}`,
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r4-no-access-token", status: 200, ctype: "application/json", body: `{"token_type":"Bearer","expires_in":300}`,
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	// r9 — 문자열 안의 잘못된 UTF-8(RFC 8259 §8.1). encoding/json 은 그것을 U+FFFD 로 바꾸고 받아들였다(판정 D1, 실측
	// 2026-11-10: 그랜트 셋 · Introspect 성공). 본문 어디든 — 토큰 안이든 밖이든 — 같은 판정이다.
	{name: "r9-invalid-utf8-in-token", status: 200, ctype: "application/json",
		body:     "{\"access_token\":\"at\xff\xfe\",\"token_type\":\"Bearer\",\"expires_in\":300,\"refresh_token\":\"rt\",\"active\":true}",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r9-invalid-utf8-outside-token", status: 200, ctype: "application/json",
		body:     "{\"access_token\":\"at\",\"token_type\":\"Bearer\",\"expires_in\":300,\"refresh_token\":\"rt\",\"active\":true,\"username\":\"s\xff\xfevc\"}",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	// r10 — application/json 의 모르는 charset 은 효과가 없다(RFC 8259 §11, 판정 D2) — 받아들인다(대조군).
	{name: "r10-unknown-charset", status: 200, ctype: "application/json; charset=x-no-such-charset", body: classUsable,
		expected: [6]string{"ok", "ok", "ok", "ok", "ok", "ok"}},
	// D3 — introspection 의 active 는 boolean 이어야 한다. 문자열 "true" 는 비활성으로 읽혔다(오류 없이).
	{name: "d3-active-not-boolean", status: 200, ctype: "application/json",
		body:     `{"access_token":"at","token_type":"Bearer","expires_in":300,"refresh_token":"rt","active":"true"}`,
		expected: [6]string{"ok", "ok", "ok", "Auth", "ok", "ok"}},
	{name: "r5-over-cap", status: 200, ctype: "application/json", body: classUsable + strings.Repeat(" ", tokenResponseMaxBytes+1-len(classUsable)),
		expected: [6]string{"Transport", "Transport", "Transport", "Transport", "Transport", "Transport"}},
	{name: "e1-200-empty", status: 200, ctype: "application/json", body: "",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "e2-502-empty", status: 502, ctype: "text/html", body: "",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "x1-307-self", status: 307, ctype: "text/plain", body: "", toSelf: true,
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "t-truncated-body", raw: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{\"access_token\"",
		expected: [6]string{"Transport", "Transport", "Transport", "Transport", "Transport", "Transport"}},
	// 다 오지 않은 본문은 잘못된 바이트가 어디 있든 *TransportError 다 — UTF-8 판정은 끝까지 온 본문에만 한다. 수정 전 첫 판(fb6b4f06)은
	// 첫 나쁜 바이트에서 거부해 그랜트 · admin 이 *AuthError(그리고 상한 메시지가 UTF-8 메시지로)였고 Introspect 만 Transport 였다
	// (독립 레그가 찾음).
	{name: "t-truncated-body-invalid-utf8", raw: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{\"access_token\":\"a\xff",
		expected: [6]string{"Transport", "Transport", "Transport", "Transport", "Transport", "Transport"}},
	{name: "r5-over-cap-invalid-utf8-first", status: 200, ctype: "application/json",
		body: "\xff" + strings.Repeat(" ", tokenResponseMaxBytes+1), contains: "exceeds 1048576 bytes",
		expected: [6]string{"Transport", "Transport", "Transport", "Transport", "Transport", "Transport"}},
	{name: "r5-over-cap-invalid-utf8-near-cap", status: 200, ctype: "application/json",
		body: strings.Repeat(" ", tokenResponseMaxBytes-5) + "\xff" + strings.Repeat(" ", 10), contains: "exceeds 1048576 bytes",
		expected: [6]string{"Transport", "Transport", "Transport", "Transport", "Transport", "Transport"}},
	{name: "n-unreachable", nowhere: true,
		expected: [6]string{"Transport", "Transport", "Transport", "Transport", "Transport", "Transport"}},
	// 2026-11-11(등록부 token-response-class-residue). 짝 없는 서로게이트 이스케이프는 어디에 있든 응답 전체를 쓸 수 없다(판정 Q2) —
	// encoding/json 이 U+FFFD 로 바꾸고 받아들였다(그랜트 셋 · Introspect 성공, admin 은 토큰 칸만 bearer 규칙이 거부). 짝을 이룬 것은
	// 받는다(대조군).
	{name: "r13-surrogate-in-extension", status: 200, ctype: "application/json",
		body: classWith(`"x_ext":"\ud800"`), contains: "unpaired surrogate escape",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r14-surrogate-in-member-name", status: 200, ctype: "application/json",
		body: classWith(`"\udc00":1`), contains: "unpaired surrogate escape",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r15-surrogate-as-access-token", status: 200, ctype: "application/json",
		body:     `{"access_token":"\ud800","token_type":"Bearer","expires_in":300,"refresh_token":"rt","active":true}`,
		contains: "unpaired surrogate escape",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r17-valid-surrogate-pair", status: 200, ctype: "application/json", body: classWith(`"scope":"a\ud83d` + `\ude00b"`),
		expected: [6]string{"ok", "ok", "ok", "ok", "ok", "ok"}},
	// 깨진 gzip — 머리와 길이는 온전하고 끝까지 온 바이트를 풀지 못했다(판정 Q1 — 전에는 해제기의 오류가 끊긴 본문으로 세어져
	// transport). 오류 상태도 그 상태가 판정한다(auth). 잘린 gzip(io.ErrUnexpectedEOF)은 끊긴 연결과 가를 수 없어 transport 다.
	{name: "r16-valid-gzip", status: 200, ctype: "application/json", encoding: "gzip", body: classGzip(classUsable),
		expected: [6]string{"ok", "ok", "ok", "ok", "ok", "ok"}},
	{name: "r16-corrupt-deflate", status: 200, ctype: "application/json", encoding: "gzip", body: classCorruptGzip,
		contains: "could not be decoded", expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r16-not-gzip", status: 200, ctype: "application/json", encoding: "gzip", body: strings.Repeat("x", 40),
		contains: "could not be decoded", expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r16-corrupt-deflate-400", status: 400, ctype: "application/json", encoding: "gzip", body: classCorruptGzip,
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	// 꼬리의 CRC-32 · 길이가 틀렸다(gzip.ErrChecksum) — 실행 레그: 이 칸이 없어 ErrChecksum 을 빼는 편집이 살아남았다.
	{name: "r16-bad-checksum", status: 200, ctype: "application/json", encoding: "gzip", body: classFlip(classUsable, 8),
		contains: "could not be decoded", expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r16-bad-length", status: 200, ctype: "application/json", encoding: "gzip", body: classFlip(classUsable, 4),
		contains: "could not be decoded", expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	// 멤버 뒤의 바이트는 다음 gzip 멤버의 머리로 읽힌다 — 머리가 아니면 풀지 못한다(gzip.ErrHeader). 푼 본문이 정확히 상한이면 그
	// 판정은 상한 너머 한 바이트를 보는 읽기(cappedBody.lookPast)에서 난다. ⚠️ 머리 열 바이트에 못 미치는 꼬리는 잘린 머리
	// (io.ErrUnexpectedEOF)라 transport 다 — 위 잘린 gzip 과 같은 모양이다(실측).
	{name: "r16-garbage-after-member", status: 200, ctype: "application/json", encoding: "gzip",
		body: classGzip(classUsable) + strings.Repeat("x", 40), contains: "could not be decoded",
		expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r16-garbage-after-a-member-of-exactly-the-cap", status: 200, ctype: "application/json", encoding: "gzip",
		body:     classGzip(classUsable+strings.Repeat(" ", tokenResponseMaxBytes-len(classUsable))) + strings.Repeat("x", 40),
		contains: "could not be decoded", expected: [6]string{"Auth", "Auth", "Auth", "Auth", "Auth", "Auth"}},
	{name: "r16-truncated-gzip", status: 200, ctype: "application/json", encoding: "gzip",
		body:     classGzip(classUsable)[:len(classGzip(classUsable))-8],
		expected: [6]string{"Transport", "Transport", "Transport", "Transport", "Transport", "Transport"}},
}

// classWith is classUsable with one more member.
func classWith(member string) string {
	return strings.TrimSuffix(classUsable, "}") + "," + member + "}"
}

// classGzip is s gzip-coded.
func classGzip(s string) string {
	var b bytes.Buffer
	w := gzip.NewWriter(&b)
	_, _ = w.Write([]byte(s))
	_ = w.Close()
	return b.String()
}

// classFlip is s gzip-coded with one byte of its 8-byte trailer flipped — back 8 is in the CRC-32, back 4 in the length.
func classFlip(s string, back int) string {
	b := []byte(classGzip(s))
	b[len(b)-back] ^= 0xff
	return string(b)
}

// classCorruptGzip is a gzip header followed by bytes that are not a deflate stream (a stored block whose lengths do not
// match) — every byte arrives, none decodes.
const classCorruptGzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff" + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

func classKind(err error) string {
	var ae *AuthError
	var te *TransportError
	var ad *AdminError
	switch {
	case err == nil:
		return "ok"
	case errors.As(err, &ae):
		return "Auth"
	case errors.As(err, &te):
		return "Transport"
	case errors.As(err, &ad):
		return fmt.Sprintf("Admin(%d)", ad.StatusCode)
	}
	return fmt.Sprintf("unexpected %T", err)
}

func classServer(t *testing.T, r classRow) string {
	t.Helper()
	switch {
	case r.nowhere:
		return "http://127.0.0.1:1"
	case r.raw != "":
		var hits atomic.Int32
		return newRawIdP(t, r.raw, &hits)
	}
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if r.toSelf {
			w.Header().Set("Location", srv.URL+req.URL.Path)
		}
		w.Header().Set("Content-Type", r.ctype)
		if r.encoding != "" {
			w.Header().Set("Content-Encoding", r.encoding)
		}
		w.WriteHeader(r.status)
		_, _ = w.Write([]byte(r.body))
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestTokenResponseClassFollowsTheNineLanguageDecision(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	var wrong []string
	for _, r := range classRows {
		cfg := Config{ServerURL: classServer(t, r), Realm: "r", ClientID: "c", ClientSecret: "s"}
		c, err := New(cfg)
		if err != nil {
			t.Fatalf("%s: New: %v", r.name, err)
		}
		_, cc := c.Auth.ClientCredentialsToken(ctx)
		_, ex := c.Auth.ExchangeCode(ctx, "code", "https://app/cb", "verifier-0123456789-0123456789-0123456789", "")
		_, rf := c.Auth.Refresh(ctx, "rt")
		_, in := c.Auth.Introspect(ctx, "at")
		_, ad := c.Admin(ctx)
		_, inj := NewAdminClient(ctx, cfg, NewClientCredentialsTokenProvider(c.Auth.ClientCredentialsToken, 30))
		for i, err := range []error{cc, ex, rf, in, ad, inj} {
			if got := classKind(err); got != r.expected[i] {
				wrong = append(wrong, fmt.Sprintf("%s × %s: %s (기대 %s) — %v", r.name, classCalls[i], got, r.expected[i], err))
			}
			if r.contains != "" && err != nil && !strings.Contains(err.Error(), r.contains) {
				wrong = append(wrong, fmt.Sprintf("%s × %s: 메시지에 %q 가 없다 — %v", r.name, classCalls[i], r.contains, err))
			}
		}
		_ = c.Close()
	}
	if len(wrong) > 0 {
		t.Errorf("계급표와 다른 칸 %d:\n%s", len(wrong), strings.Join(wrong, "\n"))
	}
}

// TestGrantFailingBeforeAnyRequestStaysAuth — 요청을 하나도 보내지 않은 실패(x/oauth2 가 빈 refresh token 을 요청 전에 거부한다)는
// 다 오지 않은 응답이 아니다 — 재시도해도 소용없으니 *AuthError 로 남는다(#952 독립 레그가 찾았다: 「보냄」 신호 없이는 *TransportError 였다).
func TestGrantFailingBeforeAnyRequestStaysAuth(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(classUsable))
	}))
	defer srv.Close()
	c, err := New(Config{ServerURL: srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	_, err = c.Auth.Refresh(context.Background(), "")
	if got := classKind(err); got != "Auth" || hits.Load() != 0 {
		t.Errorf("Refresh(\"\"): %s 에 요청 %d 번 — *AuthError · 0 번이어야 한다: %v", got, hits.Load(), err)
	}
}

// TestUnbuildableRequestIsTransportOnEveryLane — Config 가 받는 realm 이라도 요청 URL 로 만들 수 없으면(「%zz」) 그 실패는
// 모든 레인에서 *TransportError 다. 그랜트는 x/oauth2 의 http.NewRequest 가 전송층 전에 실패해 「보냄」이 없는데, 그것을
// 빈 refresh token 과 같이 *AuthError 로 두면 같은 Config 에서 Introspect·Admin 과 갈린다(#952 셋째 레그가 찾았다).
func TestUnbuildableRequestIsTransportOnEveryLane(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { hits.Add(1) }))
	defer srv.Close()
	cfg := Config{ServerURL: srv.URL, Realm: "%zz", ClientID: "c", ClientSecret: "s"}
	c, err := New(cfg)
	if err != nil {
		t.Skipf("Config 가 이 realm 을 거부한다(그러면 이 시험의 전제가 사라진다): %v", err)
	}
	defer func() { _ = c.Close() }()
	ctx := context.Background()
	_, cc := c.Auth.ClientCredentialsToken(ctx)
	_, ex := c.Auth.ExchangeCode(ctx, "code", "https://app/cb", "verifier-0123456789-0123456789-0123456789", "")
	_, rf := c.Auth.Refresh(ctx, "rt")
	_, in := c.Auth.Introspect(ctx, "at")
	_, ad := c.Admin(ctx)
	_, inj := NewAdminClient(ctx, cfg, NewClientCredentialsTokenProvider(c.Auth.ClientCredentialsToken, 30))
	for i, err := range []error{cc, ex, rf, in, ad, inj} {
		if got := classKind(err); got != "Transport" {
			t.Errorf("%s: %s 여야 하는데 %s — %v", classCalls[i], "Transport", got, err)
		}
	}
	if hits.Load() != 0 {
		t.Errorf("만들 수 없는 요청이 %d 번 나갔다", hits.Load())
	}
}

// TestAdminLoginUnusableResponseNamesTheStatusNotTheBody — 상태 없이 실패한 admin 로그인의 온 응답은 슬롯의 상태를 밝히고 gocloak 의
// 말은 옮기지 않는다: JSON 이라 적힌 503 HTML 은 gocloak 이 상태를 잃는다(Code 0), 맞지 않는 숫자는 디코더가 그 숫자를 인용한다.
func TestAdminLoginUnusableResponseNamesTheStatusNotTheBody(t *testing.T) {
	const bigNumber = "98765432109876543210987654321"
	for _, tc := range []struct {
		name, status, body, want string
	}{
		{"503 html labelled json", "503", "<html><body>Service Unavailable from upstream-proxy-7Q2K</body></html>", "HTTP 503"},
		{"200 expires_in overflow", "200", `{"access_token":"tok","token_type":"Bearer","expires_in":` + bigNumber + `}`, "HTTP 200"},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			code := http.StatusOK
			if tc.status == "503" {
				code = http.StatusServiceUnavailable
			}
			w.WriteHeader(code)
			_, _ = w.Write([]byte(tc.body))
		}))
		_, err := newAdminClient(context.Background(), Config{ServerURL: srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"})
		srv.Close()
		rendered := fmt.Sprintf("%v · %#v", err, err)
		if classKind(err) != "Auth" || !strings.Contains(rendered, tc.want) {
			t.Errorf("%s: *AuthError 에 %q 여야 한다 — %s", tc.name, tc.want, rendered)
		}
		for _, leak := range []string{bigNumber, "upstream-proxy-7Q2K", "invalid character"} {
			if strings.Contains(rendered, leak) {
				t.Errorf("%s: 응답에서 온 글자 %q 를 찍었다 — %s", tc.name, leak, rendered)
			}
		}
	}
}

// TestAdminTokenFailureNeverMatchesAdminSentinels — admin 이 토큰을 다시 받으려다 토큰 엔드포인트가 404·403·409 를 내면,
// 그 실패는 admin 자원의 상태가 아니다. *AdminError 로 내던 때(2026-11-05 실측)는 admin 요청을 **한 번도 보내지 않고**
// errors.Is(err, ErrNotFound) 가 참이어서, 「있으면 지운다」는 성공으로 · 「없으면 만든다」는 생성으로 읽혔다.
func TestAdminTokenFailureNeverMatchesAdminSentinels(t *testing.T) {
	for _, status := range []int{404, 403, 409} {
		var tokenStatus, adminHits atomic.Int32
		tokenStatus.Store(200)
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token") {
				w.Header().Set("Content-Type", "application/json")
				if s := int(tokenStatus.Load()); s != 200 {
					w.WriteHeader(s)
					_, _ = w.Write([]byte(`{"error":"Realm does not exist"}`))
					return
				}
				_, _ = w.Write([]byte(`{"access_token":"tok","token_type":"Bearer","expires_in":1}`))
				return
			}
			adminHits.Add(1)
			w.WriteHeader(http.StatusNoContent)
		}))
		cfg := Config{ServerURL: srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"}
		ctx := context.Background()
		tokenStatus.Store(int32(status))
		_, ctorErr := newAdminClient(ctx, cfg)
		tokenStatus.Store(200)
		a, err := newAdminClient(ctx, cfg)
		if err != nil {
			t.Fatalf("%d: construction with a good token: %v", status, err)
		}
		time.Sleep(1500 * time.Millisecond) // expires_in=1 이 지난다 — 다음 호출이 토큰을 다시 받는다
		tokenStatus.Store(int32(status))
		before := adminHits.Load()
		delErr := a.Users.Delete(ctx, "u1")
		_, getErr := a.Users.Get(ctx, "u1")
		for what, err := range map[string]error{"construction": ctorErr, "Users.Delete": delErr, "Users.Get": getErr} {
			if errors.Is(err, ErrNotFound) || errors.Is(err, ErrForbidden) || errors.Is(err, ErrConflict) {
				t.Errorf("token endpoint %d · %s: 토큰 실패가 admin 센티널로 읽힌다 — %T: %v", status, what, err, err)
			}
			if got := classKind(err); got != "Auth" {
				t.Errorf("token endpoint %d · %s: %s 여야 하는데 %s — %v", status, what, "Auth", got, err)
			}
		}
		if sent := adminHits.Load() - before; sent != 0 {
			t.Errorf("token endpoint %d: 토큰 없이 admin 요청이 %d 번 나갔다", status, sent)
		}
		srv.Close()
	}
}

// 성공 상태는 200 하나다(등록부 token-success-status-range-divergent) — 토큰 응답은 200 으로만 성공하고(RFC 6749 §5.1)
// introspection 응답도 200 으로만 성공한다(SDK 의 규칙 — RFC 7662 §2.2 는 상태를 정하지 않고 그 예와 Keycloak 이 200 이다).
// HTTP 가 성공이라 부르는 다른 2xx 는 그 레인이 같은 본문의 400 에
// 내는 것을 그대로 낸다 — 같은 형 · 같은 메시지(상태 숫자만 다르다) · 같은 코드, 내준 것 없음, admin 요청 0, 캐시된 것 없음.
// 수정 전(c4b5096a): x/oauth2 는 2xx 를 전부 성공으로 받았고(internal/token.go failureStatus), Introspect 도 그랬고
// (statusIs2xx), admin 로그인은 gocloak 이 400 미만을 전부 받았다 — 201 에 실린 토큰이 그랜트 · provider · admin 요청으로 나갔다.
var non200SuccessStatuses = []int{201, 202, 203, 204, 206, 299}

const (
	statusFresh        = "status-fresh-token"
	statusUsable       = `{"access_token":"` + statusFresh + `","token_type":"Bearer","expires_in":300,"refresh_token":"rt"}`
	statusAgain        = "status-again-token" // 200 으로 돌아선 IdP 의 토큰 — 이것이 나오면 다시 받은 것이다
	statusUsableAgain  = `{"access_token":"` + statusAgain + `","token_type":"Bearer","expires_in":300,"refresh_token":"rt"}`
	statusActive       = `{"active":true,"username":"svc","client_id":"app"}`
	statusB1Token      = `{"error":"invalid_grant","error_description":"d"}`
	statusB1Introspect = `{"error":"invalid_token"}`
)

// statusIdP answers the token and introspection endpoints with the status and the bodies last set — a body and its JSON
// media type, or neither (net/http sends no body with a 204: it has no content) — serves /admin/realms/r/users/{id} with
// 200, and counts admin requests, keeping the last one's Authorization.
type statusIdP struct {
	srv               *httptest.Server
	status            atomic.Int64
	token, introspect atomic.Value
	bearer            atomic.Value
	adminHits         atomic.Int32
}

func newStatusIdP(t *testing.T) *statusIdP {
	t.Helper()
	p := &statusIdP{}
	p.set(http.StatusOK, statusUsable, statusActive)
	p.bearer.Store("")
	answer := func(w http.ResponseWriter, body string) {
		if body != "" {
			w.Header().Set("Content-Type", "application/json")
		}
		w.WriteHeader(int(p.status.Load()))
		_, _ = w.Write([]byte(body))
	}
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token/introspect"):
			answer(w, p.introspect.Load().(string))
		case strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token"):
			answer(w, p.token.Load().(string))
		case strings.HasPrefix(r.URL.Path, "/admin/realms/r/users/"):
			p.adminHits.Add(1)
			p.bearer.Store(r.Header.Get("Authorization"))
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"id":"u1","username":"alice"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(p.srv.Close)
	return p
}

func (p *statusIdP) set(status int, token, introspect string) {
	p.status.Store(int64(status))
	p.token.Store(token)
	p.introspect.Store(introspect)
}

// statusLane is one lane that reads a token or introspection response, on clients of its own: run is asked once at a cell's
// status and again once the IdP answers 200, so a lane that cached what the first answer held hands that out the second
// time. It returns what the lane handed out ("" when nothing) and its error.
type statusLane struct {
	name string
	run  func(context.Context) (string, error)
}

func statusLanes(t *testing.T, p *statusIdP) []statusLane {
	t.Helper()
	cfg := Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"}
	client := func() *Client {
		c, err := New(cfg)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = c.Close() })
		return c
	}
	cc, rf, ex, in, pv, ad, inj := client(), client(), client(), client(), client(), client(), client()
	provider := NewClientCredentialsTokenProvider(pv.Auth.ClientCredentialsToken, 30)
	injected := NewClientCredentialsTokenProvider(inj.Auth.ClientCredentialsToken, 30)
	token := func(ts *TokenSet, err error) (string, error) {
		if ts != nil {
			return "token " + ts.AccessToken, err
		}
		return "", err
	}
	// An admin lane hands out a read user and the bearer its request carried.
	read := func(ctx context.Context, a *AdminClient, err error) (string, error) {
		if err != nil {
			return "", err
		}
		u, err := a.Users.Get(ctx, "u1")
		if u != nil && u.ID != nil {
			return "user " + *u.ID + " read with " + p.bearer.Load().(string), err
		}
		return "", err
	}
	return []statusLane{
		{"ClientCredentialsToken", func(ctx context.Context) (string, error) { return token(cc.Auth.ClientCredentialsToken(ctx)) }},
		{"Refresh", func(ctx context.Context) (string, error) { return token(rf.Auth.Refresh(ctx, "rt-in")) }},
		{"ExchangeCode", func(ctx context.Context) (string, error) {
			return token(ex.Auth.ExchangeCode(ctx, "code-in", "https://app/cb", "verifier-0123456789-0123456789-0123456789", ""))
		}},
		{"Introspect", func(ctx context.Context) (string, error) {
			r, err := in.Auth.Introspect(ctx, "tok-in")
			if r != nil {
				return fmt.Sprintf("introspection active=%v username=%s", r.Active, r.Username), err
			}
			return "", err
		}},
		{"provider", func(ctx context.Context) (string, error) {
			tok, err := provider.Token(ctx)
			if tok != "" {
				return "token " + tok, err
			}
			return "", err
		}},
		{"Admin", func(ctx context.Context) (string, error) {
			a, err := ad.Admin(ctx)
			return read(ctx, a, err)
		}},
		{"NewAdminClient(provider)", func(ctx context.Context) (string, error) {
			a, err := NewAdminClient(ctx, cfg, injected)
			return read(ctx, a, err)
		}},
	}
}

// statusVerdict renders what a lane gave: the class, the message, the cause's own words — not its type: the lower value a
// cause stands in for is x/oauth2's or gocloak's failure for a 400 and the value they returned for a 201 — the OAuth code,
// what it handed out, and the admin requests it sent.
func statusVerdict(handed string, err error, admin int32) string {
	if err == nil {
		return fmt.Sprintf("ok %s admin=%d", handed, admin)
	}
	code, cause := "", ""
	var ae *AuthError
	if errors.As(err, &ae) {
		code = ae.OAuthError
	}
	var rf *responseFreeError
	if c := errors.Unwrap(err); errors.As(c, &rf) {
		cause = rf.msg
	} else if c != nil {
		cause = c.Error()
	}
	return fmt.Sprintf("%s(%v) cause=%q code=%q handed=%q admin=%d", classKind(err), err, cause, code, handed, admin)
}

// atStatus is a 400's verdict as it reads for status: the status line and the status number.
func atStatus(verdict400 string, status int) string {
	code := strconv.Itoa(status)
	v := strings.ReplaceAll(verdict400, "HTTP 400 "+http.StatusText(http.StatusBadRequest), "HTTP "+code+" "+http.StatusText(status))
	return strings.ReplaceAll(v, "HTTP 400", "HTTP "+code)
}

// TestNon200SuccessStatusFailsAsTheLanesErrorResponse — a 2xx other than 200 fails every lane exactly as a 400 with the same
// content does (a 204 has none: no body, no media type), and nothing of it is kept: once the IdP answers 200, the same lanes
// fetch again. The control: 200 is every lane's success, and each admin lane sends its one admin request with its token.
func TestNon200SuccessStatusFailsAsTheLanesErrorResponse(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	p := newStatusIdP(t)
	// ask runs lanes once with the IdP at status and the bodies, and returns each lane's verdict.
	ask := func(lanes []statusLane, status int, token, introspect string) []string {
		p.set(status, token, introspect)
		out := make([]string, len(lanes))
		for i, l := range lanes {
			before := p.adminHits.Load()
			handed, err := l.run(ctx)
			out[i] = statusVerdict(handed, err, p.adminHits.Load()-before)
		}
		return out
	}
	// ok is what every lane hands out from a 200 carrying token.
	ok := func(token string) []string {
		return []string{
			"ok token " + token + " admin=0", "ok token " + token + " admin=0", "ok token " + token + " admin=0",
			"ok introspection active=true username=svc admin=0", "ok token " + token + " admin=0",
			"ok user u1 read with Bearer " + token + " admin=1", "ok user u1 read with Bearer " + token + " admin=1",
		}
	}
	var wrong []string
	compare := func(label string, lanes []statusLane, got, want []string) {
		for i, l := range lanes {
			t.Logf("%s × %s → %s", label, l.name, got[i])
			if got[i] != want[i] {
				wrong = append(wrong, fmt.Sprintf("%s × %s:\n      got  %s\n      want %s", label, l.name, got[i], want[i]))
			}
		}
	}
	control := statusLanes(t, p)
	compare("200 usable", control, ask(control, http.StatusOK, statusUsable, statusActive), ok(statusFresh))
	for _, status := range non200SuccessStatuses {
		bodies := []struct{ name, token, introspect string }{{"usable", statusUsable, statusActive}}
		if status == http.StatusCreated {
			bodies = append(bodies, struct{ name, token, introspect string }{"B1", statusB1Token, statusB1Introspect})
		}
		for _, b := range bodies {
			if status == http.StatusNoContent {
				b.token, b.introspect = "", ""
			}
			var want []string
			for _, v := range ask(statusLanes(t, p), http.StatusBadRequest, b.token, b.introspect) {
				want = append(want, atStatus(v, status))
			}
			lanes := statusLanes(t, p)
			label := strconv.Itoa(status) + " " + b.name
			compare(label, lanes, ask(lanes, status, b.token, b.introspect), want)
			compare(label+", then 200", lanes, ask(lanes, http.StatusOK, statusUsableAgain, statusActive), ok(statusAgain))
		}
	}
	if len(wrong) > 0 {
		t.Errorf("200 밖의 2xx 가 같은 본문의 400 과 다르게 끝난 칸 %d:\n%s", len(wrong), strings.Join(wrong, "\n"))
	}
}
