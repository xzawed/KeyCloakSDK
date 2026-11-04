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
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
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
	toSelf   bool   // Location 이 같은 token 주소다 — 따라가지 않는 SDK 는 3xx 를 그대로 받는다
	raw      string // 있으면 소켓이 이 바이트를 그대로 쓴다(newRawIdP)
	nowhere  bool   // 닿지 않는 IdP
	expected [6]string
}

// classRows 의 기대 계급 — classCalls 순서. Introspect 의 R4 가 ok 인 것은 introspection 에 `active` 가 없으면 비활성이라서다.
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
		expected: [6]string{"Auth", "Auth", "Auth", "ok", "Auth", "Auth"}},
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
	{name: "n-unreachable", nowhere: true,
		expected: [6]string{"Transport", "Transport", "Transport", "Transport", "Transport", "Transport"}},
}

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
		}
		_ = c.Close()
	}
	if len(wrong) > 0 {
		t.Errorf("계급표와 다른 칸 %d:\n%s", len(wrong), strings.Join(wrong, "\n"))
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
