package keycloak

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 형식이 틀린·적대적인 IdP 응답에서 난 SDK 오류가 **그 응답의 토큰을 찍지 않는다** — 최상위 표현과 원인 사슬 둘 다.
//
// ⚠️ `facade_dump_test.go` 의 걷기와 축이 다르다: 거기는 도달 가능한 **이 패키지 타입**만 렌더링하고 하위
// 라이브러리 타입(`*oauth2.RetrieveError`·`*gocloak.APIError`)은 건너뛴다. 원인 사슬은 바로 그 하위 오류를 싣는다 —
// x/oauth2 의 `RetrieveError.Error()` 는 실패 응답의 **본문 전체** 또는 `error_description` 을 인용한다.
//
// 재는 출력: 반환 오류의 `%v %+v %#v %s`·slog JSON(SDK 가 소유한다) + `errors.Unwrap` 로 사슬을 내려가며 각 고리의
// `%v %+v %#v`(고리의 **텍스트**는 하위 라이브러리 것이지만, 그 고리를 사슬에 **다는 것**은 SDK 의 결정이다).
// 한 고리가 새면 `errors.As` 로 그 타입을 꺼낸 소비자도 같은 것을 본다 — 같은 객체다.

// 카나리아 — 서로 다른 머리 10 자를 가진다(접두 검사가 카나리아끼리 섞이지 않게).
const (
	causeAT    = "atQ7mZ2vLp9K-ACCESS"   // 응답의 access_token
	causeRT    = "rtW8nB1xCs4J-REFRESH"  // 응답의 refresh_token
	causeID    = "idH3jR5yDf6T-IDTOKEN"  // 응답의 id_token(JWT 가 아니다)
	causeShort = "njT8Lw2Rb5Qs"          // JSON 이 아닌 짧은 본문 전체(≤20 자)
	causeLong  = "nlV9Pk6Ys3Xe-LONGBODY" // JSON 이 아닌 긴 본문의 머리
	causeLoc   = "lcF2Gd7Kw4Nb-LOCATION" // 3xx Location 에 실린 토큰
)

// hostileResp 는 가짜 IdP 가 겨눈 엔드포인트에 내는 응답 하나다.
type hostileResp struct {
	status   int
	ctype    string
	body     string
	location string
	// raw 가 있으면 HTTP 서버가 아니라 소켓이 이 바이트를 그대로 낸다 — HTTP 틀 자체가 깨진 응답.
	raw string
}

type causeVariant struct {
	name     string
	resp     hostileResp
	canaries []string
	// on 은 이 응답이 **실패시키는** 호출이다. 여기 없는 호출은 이 응답을 정상으로 받는다(아래 causeNotOn 이 이유를 소유).
	on []string
}

const (
	callCC       = "ClientCredentialsToken"
	callExchange = "ExchangeCode"
	// nonce 를 주면 id_token 을 검증한다 — 변이 a 만 이 길을 밟는다. ⚠️ 다른 변이에 쓰면 흐름 검사가 공허해진다:
	// id_token 없는 **정상** 응답도 「missing id_token」으로 실패하므로, 적대 응답이 안 닿아도 호출은 실패한다(변이 b 실측).
	callExchangeNonce = "ExchangeCode(nonce)"
	callRefresh       = "Refresh"
	callAdmin         = "Client.Admin(login)"
	callIntrospect    = "Introspect"
	callLogout        = "Logout"
)

var tokenCalls = []string{callCC, callExchange, callRefresh, callAdmin}

// 겨누는 엔드포인트 — 토큰 엔드포인트 호출은 같은 경로를 쓴다(admin 은 gocloak LoginClient 로).
var causeEndpoint = map[string]string{
	callCC: "/token", callExchange: "/token", callExchangeNonce: "/token", callRefresh: "/token", callAdmin: "/token",
	callIntrospect: "/token/introspect", callLogout: "/logout",
}

func hr(status int, ctype, body, location string) hostileResp {
	return hostileResp{status: status, ctype: ctype, body: body, location: location}
}

func causeTokenJSON(fields string) hostileResp {
	return hostileResp{status: 200, ctype: "application/json", body: "{" + fields + "}"}
}

func causeVariants() []causeVariant {
	long := causeLong + strings.Repeat("-x", 200)
	echo := `{"error":"invalid_grant","error_description":"Token ` + causeRT + ` is not active"}`
	return []causeVariant{
		{"a id_token 이 JWT 가 아니다", causeTokenJSON(fmt.Sprintf(
			`"access_token":%q,"token_type":"Bearer","expires_in":300,"refresh_token":%q,"id_token":%q`,
			causeAT, causeRT, causeID)), []string{causeAT, causeRT, causeID}, []string{callExchangeNonce}},
		{"b access_token 이 문자열이 아니다", causeTokenJSON(fmt.Sprintf(
			`"access_token":123,"token_type":"Bearer","expires_in":300,"refresh_token":%q,"id_token":%q`,
			causeRT, causeID)), []string{causeRT, causeID}, tokenCalls},
		{"c1 expires_in 이 숫자가 아니다", causeTokenJSON(fmt.Sprintf(
			`"access_token":%q,"token_type":"Bearer","expires_in":"soon","refresh_token":%q`,
			causeAT, causeRT)), []string{causeAT, causeRT}, tokenCalls},
		{"c2 token_type 이 문자열이 아니다", causeTokenJSON(fmt.Sprintf(
			`"access_token":%q,"token_type":5,"expires_in":300,"refresh_token":%q`,
			causeAT, causeRT)), []string{causeAT, causeRT}, tokenCalls},
		// 입력을 인용하는 파서 오류 — encoding/json 은 json.Number 로 못 읽는 문자열을 %q 로 싣는다.
		{"c3 expires_in 이 토큰을 품은 문자열이다", causeTokenJSON(fmt.Sprintf(
			`"access_token":%q,"token_type":"Bearer","expires_in":%q,"refresh_token":%q`,
			causeAT, causeRT, causeRT)), []string{causeAT, causeRT}, tokenCalls},
		{"d1 200 본문이 JSON 이 아니다(짧다)", hr(200, "application/json", causeShort, ""),
			[]string{causeShort}, append([]string{callIntrospect}, tokenCalls...)},
		{"d2 200 본문이 JSON 이 아니다(길다)", hr(200, "application/json", long, ""),
			[]string{causeLong}, append([]string{callIntrospect}, tokenCalls...)},
		{"e1 400 error_description 이 토큰을 되울린다", hr(400, "application/json", echo, ""),
			[]string{causeRT}, append([]string{callIntrospect, callLogout}, tokenCalls...)},
		{"e2 401 error_description 이 토큰을 되울린다", hr(401, "application/json",
			`{"error":"invalid_client","error_description":"client assertion `+causeAT+` rejected"}`, ""),
			[]string{causeAT}, append([]string{callIntrospect, callLogout}, tokenCalls...)},
		// 비정통 서버 — 200 에 error 를 싣는다(x/oauth2 가 실패로 읽는다).
		{"e3 200 에 error 코드와 토큰", causeTokenJSON(fmt.Sprintf(
			`"error":"invalid_request","error_description":"echo %s","access_token":%q,"refresh_token":%q`,
			causeRT, causeAT, causeRT)), []string{causeAT, causeRT}, []string{callCC, callExchange, callRefresh}},
		{"e4 500 error 코드 없는 JSON 이 토큰을 싣는다", hr(500, "application/json", fmt.Sprintf(
			`{"access_token":%q,"refresh_token":%q}`, causeAT, causeRT), ""),
			[]string{causeAT, causeRT}, append([]string{callIntrospect, callLogout}, tokenCalls...)},
		{"e5 500 본문이 JSON 이 아니다", hr(500, "text/plain", long, ""),
			[]string{causeLong}, append([]string{callIntrospect, callLogout}, tokenCalls...)},
		// error 필드 자체가 토큰이다 — Grok 레그가 찾았다: 텍스트에서는 빠지지만 AuthError.OAuthError 가 원문을 쥐어 %#v 가 찍었다.
		{"e7 error 필드가 토큰이다", hr(400, "application/json", `{"error":"`+causeAT+`"}`, ""),
			[]string{causeAT}, append([]string{callIntrospect, callLogout}, tokenCalls...)},
		{"e6 302 Location·본문이 토큰을 싣는다", hr(302, "text/html",
			`<a href="https://app/cb#access_token=`+causeLoc+`">Found</a>`, "https://app/cb#access_token="+causeLoc),
			[]string{causeLoc}, append([]string{callIntrospect, callLogout}, tokenCalls...)},
		// HTTP 틀이 없는 응답 — 헤더를 떨군 중계기가 본문만 낸다. net/http 는 그 첫 줄을 %q 로 인용한다.
		{"f1 상태줄 없이 본문만 온다", hostileResp{raw: fmt.Sprintf(`{"access_token":%q,"refresh_token":%q}`+"\r\n",
			causeAT, causeRT)}, []string{causeAT, causeRT}, allCalls},
		{"f2 헤더 줄이 틀렸다", hostileResp{raw: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" + causeAT + "\r\n\r\n{}"},
			[]string{causeAT}, allCalls},
		// 본문 읽기 오류 — 상태·헤더는 멀쩡하고 chunked 트레일러 줄이 틀렸다. RoundTrip 이 아니라 Body.Read 가 인용한다.
		{"f3 chunked 트레일러 줄이 틀렸다", hostileResp{raw: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
			"Transfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n" + causeRT + "\r\n\r\n"},
			[]string{causeRT}, append([]string{callIntrospect}, tokenCalls...)},
	}
}

var allCalls = []string{callCC, callExchange, callRefresh, callAdmin, callIntrospect, callLogout}

// 변이가 on 에 없는 호출을 **정상으로 받는** 이유. 이유 없는 제외는 없다 — causeVariants 와 대조한다.
var causeNotOn = map[string]string{
	"a/" + callCC:       "x/oauth2 는 id_token 을 검증하지 않는다 — 검증은 nonce 가 있는 ExchangeCode 만 한다",
	"a/" + callExchange: "같음 — nonce 가 없으면 id_token 을 검증하지 않는다",
	"a/" + callRefresh:  "같음",
	"a/" + callAdmin:    "gocloak LoginClient 는 id_token 을 안 본다",
	"e3/" + callAdmin:   "gocloak 은 2xx 를 성공으로 읽고 access_token 이 있다",
}

// 고치지 못한 누출 — 키는 `변이/호출/출력`. 관측되지 않는 항목은 낡은 것이라 실패한다.
var causeKnownLeaks = map[string]string{}

func causeServe(w http.ResponseWriter, r hostileResp) {
	if r.location != "" {
		w.Header().Set("Location", r.location)
	}
	if r.ctype != "" {
		w.Header().Set("Content-Type", r.ctype)
	}
	w.WriteHeader(r.status)
	_, _ = w.Write([]byte(r.body))
}

// 가짜 IdP — 겨눈 엔드포인트만 적대 응답을 내고, 나머지는 정상이다. hits 는 적대 응답을 낸 횟수다.
func newCauseIdP(t *testing.T, endpoint string, resp hostileResp, hits *atomic.Int32) string {
	t.Helper()
	if resp.raw != "" {
		return newRawIdP(t, resp.raw, hits)
	}
	base := "/realms/r/protocol/openid-connect"
	valid := map[string]hostileResp{
		"/token":            causeTokenJSON(`"access_token":"ok-at","token_type":"Bearer","expires_in":300,"refresh_token":"ok-rt"`),
		"/token/introspect": hr(200, "application/json", `{"active":true}`, ""),
		"/logout":           hr(204, "", "", ""),
	}
	mux := http.NewServeMux()
	for path, ok := range valid {
		mux.HandleFunc(base+path, func(w http.ResponseWriter, _ *http.Request) {
			if path == endpoint {
				hits.Add(1)
				causeServe(w, resp)
				return
			}
			causeServe(w, ok)
		})
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

// newRawIdP 는 연결마다 요청 머리를 읽고 raw 를 그대로 쓴 뒤 닫는다 — 어느 엔드포인트든 첫 요청이 곧 적대 응답이다.
func newRawIdP(t *testing.T, raw string, hits *atomic.Int32) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = conn.Close() }()
				_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
				req, err := http.ReadRequest(bufio.NewReader(conn))
				if err != nil {
					return
				}
				// ⚠️ 본문까지 다 읽고 답한다 — 머리만 읽고 닫으면 클라이언트가 아직 쓰던 본문이 끊겨, 깨진 응답 대신
				// 소켓 쓰기 오류를 본다(실측: f1/Client.Admin 이 가끔 「readfrom tcp …」로 실패했다).
				_, _ = io.Copy(io.Discard, req.Body)
				hits.Add(1)
				_, _ = conn.Write([]byte(raw))
			}()
		}
	}()
	return "http://" + ln.Addr().String()
}

func causeRun(ctx context.Context, c *Client, call string) error {
	switch call {
	case callCC:
		_, err := c.Auth.ClientCredentialsToken(ctx)
		return err
	case callExchange:
		_, err := c.Auth.ExchangeCode(ctx, "code-in", "https://app/cb", "verifier-in", "")
		return err
	case callExchangeNonce:
		_, err := c.Auth.ExchangeCode(ctx, "code-in", "https://app/cb", "verifier-in", "nonce-in")
		return err
	case callRefresh:
		_, err := c.Auth.Refresh(ctx, "rt-in")
		return err
	case callAdmin:
		_, err := c.Admin(ctx)
		return err
	case callIntrospect:
		_, err := c.Auth.Introspect(ctx, "tok-in")
		return err
	case callLogout:
		return c.Auth.Logout(ctx, "rt-in")
	}
	panic("unknown call " + call)
}

// causeLinks 는 반환 오류부터 errors.Unwrap(과 Unwrap() []error)으로 닿는 고리 전부다.
func causeLinks(err error) []error {
	var out []error
	var walk func(e error, depth int)
	walk = func(e error, depth int) {
		for ; e != nil && depth < 32; depth++ {
			out = append(out, e)
			if j, ok := e.(interface{ Unwrap() []error }); ok {
				for _, x := range j.Unwrap() {
					walk(x, depth+1)
				}
				return
			}
			e = errors.Unwrap(e)
		}
	}
	walk(err, 0)
	return out
}

// causeRender 는 소비자가 이 오류로 얻는 텍스트 전부다 — 키는 출력 경로.
func causeRender(err error) map[string]string {
	outs := map[string]string{}
	for _, verb := range []string{"%v", "%+v", "%#v", "%s"} {
		outs["top "+verb] = fmt.Sprintf(verb, err)
	}
	var js bytes.Buffer
	slog.New(slog.NewJSONHandler(&js, nil)).Error("m", "err", err)
	outs["top slog.JSON"] = js.String()
	for i, l := range causeLinks(err)[1:] {
		for _, verb := range []string{"%v", "%+v", "%#v"} {
			outs[fmt.Sprintf("cause[%d] %T %s", i+1, l, verb)] = fmt.Sprintf(verb, l)
		}
	}
	return outs
}

// causeFind 는 out 에 카나리아가 원문(FULL)·머리 10 자(PREFIX)·%#v 바이트 표기(HEX)로 있는지 본다.
func causeFind(out, canary string) string {
	hex := func(s string) string {
		h := fmt.Sprintf("%#v", []byte(s))
		return h[strings.Index(h, "{")+1 : len(h)-1]
	}
	switch {
	case strings.Contains(out, canary):
		return "FULL"
	case strings.Contains(out, canary[:10]):
		return "PREFIX"
	case strings.Contains(out, hex(canary[:10])):
		return "HEX"
	}
	return ""
}

func causeShortName(v causeVariant) string { return strings.Fields(v.name)[0] }

func TestMalformedTokenResponseErrorsDoNotRenderTokens(t *testing.T) {
	observed := map[string]bool{}
	var rows []string
	for _, v := range causeVariants() {
		for _, call := range causeCalls {
			key := causeShortName(v) + "/" + call
			if !slices.Contains(v.on, call) {
				causeCheckExcluded(t, key, call)
				continue
			}
			t.Run(key, func(t *testing.T) {
				err := causeFlow(t, v, call)
				causeCheckShape(t, key, v, call, err)
				rows = append(rows, causeCheckLeaks(t, key, v, err, observed)...)
			})
		}
	}
	causeCheckStale(t, observed)
	sort.Strings(rows)
	for _, r := range rows {
		t.Log(r)
	}
}

var causeCalls = []string{callCC, callExchange, callExchangeNonce, callRefresh, callAdmin, callIntrospect, callLogout}

// 토큰 엔드포인트 호출이 변이에서 빠지면 이유가 있어야 한다. ExchangeCode(nonce) 는 변이 a 전용이라 제외다.
func causeCheckExcluded(t *testing.T, key, call string) {
	t.Helper()
	if _, ok := causeNotOn[key]; !ok && causeEndpoint[call] == "/token" && call != callExchangeNonce {
		t.Errorf("%s: 토큰 엔드포인트 호출이 이 변이에서 빠졌는데 이유가 없다 — on 에 넣거나 causeNotOn 에 이유를 적어라", key)
	}
}

// causeFlow 는 적대 응답을 내는 IdP 에 호출을 한 번 보내고, 그 응답이 정말 이 호출을 실패시켰는지 본다.
// 아니면 누출 검사는 없는 것을 찾으며 공허하게 통과한다.
func causeFlow(t *testing.T, v causeVariant, call string) error {
	t.Helper()
	var hits atomic.Int32
	srvURL := newCauseIdP(t, causeEndpoint[call], v.resp, &hits)
	c, err := New(Config{ServerURL: srvURL, Realm: "r", ClientID: "c", ClientSecret: "cs-in"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	err = causeRun(context.Background(), c, call)
	if hits.Load() == 0 {
		t.Fatalf("적대 응답이 %s 에 한 번도 안 나갔다 — 가짜 IdP 경로가 호출과 어긋났다", causeEndpoint[call])
	}
	if err == nil {
		t.Fatalf("적대 응답인데 호출이 성공했다 — 변이가 SDK 에 닿지 않았다")
	}
	// nonce 경로는 id_token 없는 정상 응답에도 실패한다 — id_token 이 검증기까지 갔는지를 따로 본다.
	if call == callExchangeNonce && !strings.Contains(err.Error(), "invalid id_token") {
		t.Fatalf("id_token 이 검증기에 닿지 않았다 — 변이가 SDK 에 닿지 않았다: %v", err)
	}
	return err
}

// causeCheckShape 는 정화가 분류를 바꾸지 않았고 디버깅 정보를 남겼는지 본다.
func causeCheckShape(t *testing.T, key string, v causeVariant, call string, err error) {
	t.Helper()
	t.Logf("CLASS %s | %T | %v", key, err, causeLinkTypes(err))
	// 분류는 정화 전과 같아야 한다(실측 2026-09-26, 수정 전 전 사례가 이 규칙과 일치).
	if got, want := fmt.Sprintf("%T", err), causeWantKind(v, call); got != want {
		t.Errorf("분류가 바뀌었다: %s, want %s", got, want)
	}
	chain := causeChainText(err)
	t.Logf("TEXT %s | %s", key, causeLine(chain))
	for _, want := range causeKeeps(v, call) {
		if !strings.Contains(chain, want) {
			t.Errorf("디버깅 정보 %q 가 사라졌다 — 정화가 너무 많이 지웠다: %s", want, causeLine(chain))
		}
	}
}

// causeCheckLeaks 는 모든 출력 경로에서 카나리아를 찾고, 알려진 누출이 아니면 실패시킨다. 관측 행을 돌려준다.
func causeCheckLeaks(t *testing.T, key string, v causeVariant, err error, observed map[string]bool) []string {
	t.Helper()
	var rows []string
	for path, out := range causeRender(err) {
		for _, cn := range v.canaries {
			how := causeFind(out, cn)
			if how == "" {
				continue
			}
			leak := key + "/" + path
			observed[leak] = true
			rows = append(rows, fmt.Sprintf("%s | %s | %.10s… | %s", leak, how, cn, causeLine(out)))
			if _, known := causeKnownLeaks[leak]; !known {
				t.Errorf("%s: 응답의 토큰이 찍혔다(%s %.10s…): %s", path, how, cn, causeLine(out))
			}
		}
	}
	return rows
}

// causeCheckStale 는 제외 표·알려진 누출 표에 낡은 항목이 없는지 본다.
func causeCheckStale(t *testing.T, observed map[string]bool) {
	t.Helper()
	for key := range causeNotOn {
		name, call, _ := strings.Cut(key, "/")
		found := false
		for _, cv := range causeVariants() {
			found = found || (causeShortName(cv) == name && !slices.Contains(cv.on, call))
		}
		if !found {
			t.Errorf("causeNotOn[%s]: 해당 변이·호출이 없거나 이미 on 에 있다 — 낡은 제외다", key)
		}
	}
	for leak, reason := range causeKnownLeaks {
		if !observed[leak] {
			t.Errorf("causeKnownLeaks[%s]: 더는 관측되지 않는다 — 낡은 항목을 지워라(%s)", leak, reason)
		}
	}
}

// causeWantKind 는 정화 전에 잰 분류다 — x/oauth2 레인은 전부 AuthError, admin 로그인은 HTTP 상태가 있으면
// AdminError·없으면 TransportError, postForm 레인은 HTTP 틀이 깨지면 TransportError·아니면 AuthError.
func causeWantKind(v causeVariant, call string) string {
	switch {
	case call == callAdmin && v.resp.raw == "" && v.resp.status >= 400:
		return "*keycloak.AdminError"
	case call == callAdmin, v.resp.raw != "" && (call == callIntrospect || call == callLogout):
		return "*keycloak.TransportError"
	}
	return "*keycloak.AuthError"
}

// 정화가 전송 계층 **아래**의 오류(취소·타임아웃·소켓)는 그대로 두는가 — 소비자는 errors.Is/As 로 그것을 가른다.
// 정화를 모든 전송 오류에 걸면 errors.Is(err, context.Canceled) 가 조용히 거짓이 된다.
func TestScrubKeepsBelowHTTPErrorIdentity(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("취소된 요청이 서버에 닿았다")
	}))
	t.Cleanup(srv.Close)
	c, err := New(Config{ServerURL: srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	// admin 로그인은 빠진다 — gocloak 이 SDK 에 닿기 전에 오류를 문자열로 납작하게 만들어, 정화 전에도 거짓이었다.
	for _, call := range []string{callCC, callExchange, callRefresh, callIntrospect, callLogout} {
		err := causeRun(ctx, c, call)
		if !errors.Is(err, context.Canceled) {
			t.Errorf("%s: errors.Is(err, context.Canceled) 가 거짓이다 — %T: %v", call, err, err)
		}
	}
	// 닫힌 포트 — 소켓 오류가 사슬에 그대로 있다. ⚠️ net.Error 인터페이스로 재면 공허하다: *url.Error 자신이
	// Timeout·Temporary 를 가져 net.Error 를 만족한다(변이 c6 실측 — 소켓 오류를 정화해도 통과했다). 구체 타입으로 잰다.
	down, err := New(Config{ServerURL: "http://127.0.0.1:1", Realm: "r", ClientID: "c", ClientSecret: "s"})
	if err != nil {
		t.Fatal(err)
	}
	for _, call := range []string{callCC, callExchange, callRefresh, callIntrospect, callLogout} {
		var oe *net.OpError
		if err := causeRun(context.Background(), down, call); !errors.As(err, &oe) {
			t.Errorf("%s: errors.As(err, &*net.OpError) 가 거짓이다 — %T: %v", call, err, err)
		}
	}
}

// ownWords 의 텍스트 규칙을 직접 잰다. ⚠️ 인용 검사는 위 사례 어느 것도 밟지 않는다(변이 c7 실측: 끄고도 통과) —
// HTTP/1 과 x/oauth2 의 인용은 전부 둘째 절 뒤에 있어 절 자르기가 먼저 걷는다. 그 검사가 막는 실물은 HTTP/2 다:
// net/http 의 http2GoAwayError 는 「http2: server sent GOAWAY …; debug=%q」로 서버가 보낸 바이트를 **첫 절 안에**
// 인용한다(h2_bundle.go). 가짜 IdP 는 HTTP/1.1 이라 그 오류를 못 만들어 여기서 문자열로 고정한다.
func TestOwnWordsKeepsOnlyThePackagesOwnWords(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{`http2: server sent GOAWAY and closed the connection; LastStreamID=1, ErrCode=NO_ERROR, debug="` + causeRT + `"`,
			"message withheld"},
		{`malformed HTTP response "` + causeAT + `"`, "message withheld"},
		{`oauth2: cannot parse json: json: invalid number literal, trying to unmarshal "\"` + causeRT + `\"" into Number`,
			"oauth2: cannot parse json"},
		{"oauth2: cannot fetch token: 500 Internal Server Error\nResponse: " + causeLong, "oauth2: cannot fetch token"},
		{`malformed MIME header: missing colon: "` + causeRT + `"`, "malformed MIME header"},
		{"oauth2: server response missing access_token", "oauth2: server response missing access_token"},
		{"invalid character 'n' looking for beginning of value", "invalid character 'n' looking for beginning of value"},
	} {
		got, cut := ownWords(tc.in)
		if got != tc.want {
			t.Errorf("ownWords(%.40q…) = %q, want %q", tc.in, got, tc.want)
		}
		if cut != (got != tc.in) {
			t.Errorf("ownWords(%.40q…): cut=%v 인데 텍스트가 %s", tc.in, cut, map[bool]string{true: "그대로다", false: "잘렸다"}[cut])
		}
	}
}

// causeChainText 는 반환 오류와 그 아래 고리 전부의 %v 를 잇는다.
func causeChainText(err error) string {
	var parts []string
	for _, l := range causeLinks(err) {
		parts = append(parts, l.Error())
	}
	return strings.Join(parts, " ⇒ ")
}

// causeKeeps 는 정화 뒤에도 사슬에 남아야 하는 디버깅 정보다 — 하위 타입 이름·HTTP 상태·OAuth 오류 코드·전송 계층의 말.
func causeKeeps(v causeVariant, call string) []string {
	r := v.resp
	oauthLane := call == callCC || call == callExchange || call == callExchangeNonce || call == callRefresh
	bodyRead := strings.HasPrefix(causeShortName(v), "f3") // Body.Read 가 낸 오류 — RoundTrip 이 아니다
	switch {
	case r.raw != "" && bodyRead && oauthLane:
		return []string{"*errors.errorString", "oauth2: cannot fetch token"}
	case r.raw != "" && bodyRead:
		return []string{"textproto.ProtocolError", "malformed MIME header"}
	case r.raw != "":
		// *url.Error 의 텍스트 — 요청한 엔드포인트(SDK 가 만든 URL)와 net/http 자신의 말은 남는다.
		return []string{`Post "http://127.0.0.1:`, causeEndpoint[call] + `": `, "net/http: HTTP/1.x transport connection broken"}
	case call == callAdmin && r.status == http.StatusFound:
		return []string{"back-channel redirect refused"}
	case call == callAdmin && r.status >= 400:
		keep := []string{"HTTP " + strconv.Itoa(r.status), http.StatusText(r.status)}
		if code := causeOAuthCode(r.body); code != "" {
			keep = append(keep, code)
		}
		return keep
	case oauthLane && (r.status >= 300 || strings.Contains(r.body, `"error"`)):
		keep := []string{"*oauth2.RetrieveError", "HTTP " + strconv.Itoa(r.status)}
		if code := causeOAuthCode(r.body); code != "" {
			keep = append(keep, `error "`+code+`"`)
		}
		return keep
	case oauthLane && strings.HasPrefix(causeShortName(v), "c3"):
		return []string{"oauth2: cannot parse json"}
	}
	return nil
}

func causeOAuthCode(body string) string {
	_, rest, ok := strings.Cut(body, `"error":"`)
	if !ok {
		return ""
	}
	code, _, _ := strings.Cut(rest, `"`)
	if !oauthCodeShaped(code) {
		return "" // 코드 모양이 아니면 정화가 빼는 것이 맞다 — 남기라고 요구하지 않는다
	}
	return code
}

func causeLinkTypes(err error) []string {
	var out []string
	for _, l := range causeLinks(err) {
		out = append(out, fmt.Sprintf("%T", l))
	}
	return out
}

func causeLine(s string) string {
	s = strings.ReplaceAll(s, "\n", `\n`)
	if len(s) > 160 {
		return s[:160] + "…"
	}
	return s
}
