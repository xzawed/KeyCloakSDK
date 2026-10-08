package keycloak

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// 응답 머리 상한(등록부 response-framing-unbounded). SDK 가 만드는 전송은 응답 머리 블록 — 상태 줄부터 빈 줄의
// CRLF 까지, net/http 의 persistConn.readLimit 이 세는 바이트 — 을 65,536 바이트까지만 읽는다.
//
// 수정 전 실측(2026-10-09, 이 트리 · 별도 프로세스 가짜 IdP · go1.26.4): 토큰 응답이 16 MiB 머리 한 줄을 실으면
// 두 레인 모두 실패는 했지만 net/http 기본값(10 MiB)까지 읽은 뒤였다 — 서버가 11,075,680 바이트를 밀어 넣었고 호출
// 하나가 73.3 MB 를 할당했다(HeapSys +41.9 MB, 피크 작업 집합 +37.2 MB).
//
// ⚠️ 경계값은 상수 이름이 아니라 **리터럴**로 적는다 — 상수를 바꾸면 이 테스트가 운다.
const (
	hdrTestLimit = 65536
	hdrHuge      = 16 << 20
	// hdrAllocBound 는 16 MiB 머리 블록을 거부하는 호출 전체(같은 프로세스의 가짜 IdP 포함)가 할당해도 되는 양이다.
	// 실측: 수정 뒤 0.13–0.62 MB(윈도우 · 리눅스), 수정 전 12.4 MB(1 KiB 줄 여럿) · 73.3 MB(한 줄).
	hdrAllocBound = 2 << 20
	// hdrDeliverSlack 은 클라이언트가 끊기 전까지 IdP 커널이 받아 가는 몫이다(IdP 송신 버퍼는 64 KiB 로 고정, 나머지는
	// 클라이언트 수신 버퍼). 실측: 수정 뒤 IdP 가 밀어 넣은 바이트 193–393 KB, 수정 전 11.0–11.3 MB(클라이언트가 10 MiB
	// 를 읽었다). IdP 가 상한 + 이것보다 많이 밀어 넣었으면 클라이언트가 상한보다 많이 읽은 것이다.
	hdrDeliverSlack = 1 << 20
)

const (
	hdrOIDC        = "/realms/r/protocol/openid-connect"
	hdrAccessToken = "eyJhbGciOiJSUzI1NiJ9.hdr-cap-access-token.sig"
)

// hdrKeycloakLines 는 Keycloak 26.6.4(start-dev · it-realm)가 그 엔드포인트에서 실제로 보낸 머리 줄이다 — 실측
// 2026-10-09, 바이트 그대로. 프레이밍 줄(content-length · connection)은 이 가짜 IdP 가 붙인다. 같은 실측에서 SDK 가
// 부르는 엔드포인트(admin 파사드 25 메서드의 엔드포인트 전부와 오류 응답 포함)의 머리 블록은 193–339 바이트였고
// Set-Cookie 는 하나도 없었다. 브라우저 로그인 흐름 전체의 최대는 SSO 재인증 302 의 3,018 바이트다(Set-Cookie 다섯) —
// SDK 가 부르지 않는 엔드포인트다.
var hdrKeycloakLines = map[string][]string{
	"/token": {"Cache-Control: no-store", "Pragma: no-cache", "Content-Type: application/json",
		"Referrer-Policy: no-referrer", "Strict-Transport-Security: max-age=31536000; includeSubDomains",
		"X-Content-Type-Options: nosniff", "X-Frame-Options: SAMEORIGIN", "X-Robots-Tag: none"},
	"/token/introspect": {"Cache-Control: no-cache", "Content-Type: application/json", "Referrer-Policy: no-referrer",
		"Strict-Transport-Security: max-age=31536000; includeSubDomains", "X-Content-Type-Options: nosniff",
		"X-Frame-Options: SAMEORIGIN", "X-Robots-Tag: none"},
	"/certs": {"Cache-Control: no-cache", "Content-Type: application/json", "Referrer-Policy: no-referrer",
		"Strict-Transport-Security: max-age=31536000; includeSubDomains", "X-Content-Type-Options: nosniff",
		"X-Frame-Options: SAMEORIGIN", "X-Robots-Tag: none"},
	"/logout": {"Cache-Control: no-cache",
		"Content-Security-Policy: frame-src 'self'; frame-ancestors 'self'; object-src 'none';",
		"Referrer-Policy: no-referrer", "Strict-Transport-Security: max-age=31536000; includeSubDomains",
		"X-Content-Type-Options: nosniff", "X-Frame-Options: SAMEORIGIN", "X-Robots-Tag: none"},
	"/admin/realms/r/users": {"Cache-Control: no-cache", "Content-Type: application/json;charset=UTF-8",
		"Referrer-Policy: no-referrer", "Strict-Transport-Security: max-age=31536000; includeSubDomains",
		"X-Content-Type-Options: nosniff", "X-Frame-Options: SAMEORIGIN", "X-Robots-Tag: none"},
}

// hdrShape 은 겨눈 엔드포인트가 낼 응답 머리 블록의 모양이다. block 은 빈 줄까지 센 바이트 수(0 이면 Keycloak 이 실제로
// 보내는 머리 그대로), many 면 1 KiB 줄 여럿이, 아니면 한 줄이 블록을 채운다.
type hdrShape struct {
	name  string
	block int
	many  bool
	over  bool // 상한을 넘는다 — 실패해야 한다
}

var hdrShapes = []hdrShape{
	{name: "keycloak"},
	{name: "one-line-at-limit", block: hdrTestLimit},
	{name: "many-lines-at-limit", block: hdrTestLimit, many: true},
	{name: "one-line-limit+1", block: hdrTestLimit + 1, over: true},
	{name: "many-lines-limit+1", block: hdrTestLimit + 1, many: true, over: true},
	{name: "one-line-16MiB", block: hdrHuge, over: true},
	{name: "many-lines-16MiB", block: hdrHuge, many: true, over: true},
}

var hdrFill = bytes.Repeat([]byte{'a'}, 4096)

// hdrPadLine 은 정확히 n 바이트(CRLF 포함)인 머리 줄 하나를 쓴다.
func hdrPadLine(b *bytes.Buffer, i, n int) {
	name := "X-Pad-" + strconv.Itoa(i) + ": "
	b.WriteString(name)
	for k := n - len(name) - 2; k > 0; {
		w := min(k, len(hdrFill))
		b.Write(hdrFill[:w])
		k -= w
	}
	b.WriteString("\r\n")
}

// hdrHead 은 응답 머리 블록이다 — 상태 줄, 그 엔드포인트의 Keycloak 머리 줄, 프레이밍, (block > 0 이면) 블록을 정확히
// block 바이트로 채우는 덧댐 줄, 빈 줄.
func hdrHead(status string, lines []string, bodyLen int, s hdrShape) []byte {
	var b bytes.Buffer
	b.Grow(max(s.block, 1024))
	b.WriteString("HTTP/1.1 " + status + "\r\n")
	for _, l := range lines {
		b.WriteString(l + "\r\n")
	}
	if !strings.HasPrefix(status, "204") {
		b.WriteString("Content-Length: " + strconv.Itoa(bodyLen) + "\r\n")
	}
	b.WriteString("Connection: close\r\n")
	if s.block > 0 {
		pad := s.block - b.Len() - 2
		for i := 0; s.many && pad >= 2048; i++ {
			hdrPadLine(&b, i, 1024)
			pad -= 1024
		}
		hdrPadLine(&b, 99999, pad)
	}
	b.WriteString("\r\n")
	return b.Bytes()
}

// hdrIdP 는 응답을 바이트 단위로 짓는 가짜 Keycloak 이다(net/http 서버는 머리 블록의 바이트 수를 맞출 수 없다). 연결
// 하나에 요청 하나를 받고 답한 뒤 닫는다. target 경로만 미리 지어 둔 머리(head)를 내고, 나머지는 Keycloak 의 머리로 답한다.
type hdrIdP struct {
	url   string
	jwks  []byte
	token string // Validate 레인이 검증할, 이 IdP 의 키로 서명한 토큰

	mu     sync.Mutex
	target string
	head   []byte

	delivered  atomic.Int64  // target 응답에서 서버 커널이 받아 간 바이트
	targetHits atomic.Int32  // target 응답을 낸 횟수
	adminCalls atomic.Int32  // /admin/ 요청 수
	done       chan struct{} // target 응답 처리기가 끝날 때마다 하나
}

func newHdrIdP(t *testing.T, key *rsa.PrivateKey) *hdrIdP {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	p := &hdrIdP{url: "http://" + ln.Addr().String(), done: make(chan struct{}, 64)}
	p.jwks, err = json.Marshal(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
		{Key: &key.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"}}})
	if err != nil {
		t.Fatal(err)
	}
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "k1"))
	if err != nil {
		t.Fatal(err)
	}
	p.token, err = jwt.Signed(sig).Claims(jwt.Claims{Subject: "u1", Issuer: p.url + "/realms/r",
		Audience: jwt.Audience{"c"}, Expiry: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt: jwt.NewNumericDate(time.Now())}).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go p.serve(conn)
		}
	}()
	return p
}

// endpoint 는 path 에 대한 Keycloak 의 상태·머리 줄·본문이다.
func (p *hdrIdP) endpoint(path string) (string, []string, []byte) {
	switch path {
	case hdrOIDC + "/token":
		return "200 OK", hdrKeycloakLines["/token"], []byte(`{"access_token":"` + hdrAccessToken +
			`","token_type":"Bearer","expires_in":300,"refresh_token":"rt-1"}`)
	case hdrOIDC + "/token/introspect":
		return "200 OK", hdrKeycloakLines["/token/introspect"],
			[]byte(`{"active":true,"sub":"u1","username":"alice","client_id":"c"}`)
	case hdrOIDC + "/certs":
		return "200 OK", hdrKeycloakLines["/certs"], p.jwks
	case hdrOIDC + "/logout":
		return "204 No Content", hdrKeycloakLines["/logout"], nil
	case "/admin/realms/r/users":
		return "200 OK", hdrKeycloakLines["/admin/realms/r/users"], []byte(`[]`)
	}
	return "404 Not Found", []string{"Content-Type: application/json"}, []byte(`{"error":"not_found"}`)
}

// aim 은 다음 호출의 target 응답을 정한다. 머리는 여기서 — 할당을 재기 전에 — 짓는다.
func (p *hdrIdP) aim(t *testing.T, path string, s hdrShape) {
	t.Helper()
	var head []byte
	if s.block > 0 {
		status, lines, body := p.endpoint(path)
		head = hdrHead(status, lines, len(body), s)
		if len(head) != s.block {
			t.Fatalf("the %s head is %d bytes, want %d — the fixture is wrong", s.name, len(head), s.block)
		}
	}
	p.mu.Lock()
	p.target, p.head = path, head
	p.mu.Unlock()
	p.delivered.Store(0)
	p.targetHits.Store(0)
	p.adminCalls.Store(0)
}

func (p *hdrIdP) serve(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
	req, err := http.ReadRequest(bufio.NewReader(conn))
	if err != nil {
		return
	}
	// 본문까지 다 읽고 답한다(malformed_response_cause_test.go 의 newRawIdP 와 같은 이유).
	_, _ = io.Copy(io.Discard, req.Body)
	path := req.URL.Path
	if strings.HasPrefix(path, "/admin/") {
		p.adminCalls.Add(1)
	}
	status, lines, body := p.endpoint(path)
	p.mu.Lock()
	target, head := p.target, p.head
	p.mu.Unlock()
	if path != target {
		_, _ = conn.Write(append(hdrHead(status, lines, len(body), hdrShape{}), body...))
		return
	}
	defer func() { p.done <- struct{}{} }()
	p.targetHits.Add(1)
	if head == nil {
		head = hdrHead(status, lines, len(body), hdrShape{})
	}
	// 서버 쪽 송신 버퍼를 고정한다 — 리눅스는 기본값에서 송신 버퍼를 자동으로 키워(루프백 MSS 64 KiB) 클라이언트가
	// 64 KiB 만 읽어도 1.7 MB 까지 받아 갔다(실측). 고정하면 남는 것은 클라이언트 수신 버퍼다.
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetWriteBuffer(64 << 10)
	}
	// 32 KiB 씩 쓰며 커널이 받아 간 만큼 센다 — 클라이언트가 끊으면 쓰기가 실패하고 거기서 멈춘다.
	var n int64
	for off := 0; off < len(head); off += 32 << 10 {
		k, err := conn.Write(head[off:min(off+32<<10, len(head))])
		n += int64(k)
		p.delivered.Store(n)
		if err != nil {
			return
		}
	}
	_, _ = conn.Write(body)
}

// hdrLane 은 응답 머리 상한이 걸리는 공개 호출 하나다. path 는 그 호출이 머리를 받는 엔드포인트, want 는 머리가
// 상한을 넘을 때 그 호출이 돌려주는 SDK 오류 타입 — 수정 전 트리가 16 MiB 머리에 이미 돌려주던 타입이다(이 수정은
// 분류를 바꾸지 않는다: 세 그랜트는 x/oauth2 실패를 감싼 *AuthError, Introspect·Logout 은 postForm 의
// *TransportError, admin 레인은 gocloak 의 Code 0 이라 *TransportError, JWKS 는 Validate 의 *TokenValidationError).
type hdrLane struct {
	name string
	path string
	want string
	run  func(t *testing.T, ctx context.Context, p *hdrIdP, c *Client) error
}

func hdrGrantLane(name string, grant func(ctx context.Context, c *Client) (*TokenSet, error)) hdrLane {
	return hdrLane{name: name, path: hdrOIDC + "/token", want: "*keycloak.AuthError",
		run: func(t *testing.T, ctx context.Context, _ *hdrIdP, c *Client) error {
			ts, err := grant(ctx, c)
			if err == nil && ts.AccessToken != hdrAccessToken {
				t.Fatalf("the access token did not come through: %q", ts.AccessToken)
			}
			return err
		}}
}

var hdrLanes = []hdrLane{
	hdrGrantLane("ClientCredentialsToken", func(ctx context.Context, c *Client) (*TokenSet, error) {
		return c.Auth.ClientCredentialsToken(ctx)
	}),
	hdrGrantLane("Refresh", func(ctx context.Context, c *Client) (*TokenSet, error) {
		return c.Auth.Refresh(ctx, "rt-in")
	}),
	hdrGrantLane("ExchangeCode", func(ctx context.Context, c *Client) (*TokenSet, error) {
		return c.Auth.ExchangeCode(ctx, "code-in", "https://app/cb", "verifier-in", "")
	}),
	{name: "Introspect", path: hdrOIDC + "/token/introspect", want: "*keycloak.TransportError",
		run: func(t *testing.T, ctx context.Context, _ *hdrIdP, c *Client) error {
			res, err := c.Auth.Introspect(ctx, "tok-in")
			if err == nil && (!res.Active || res.Username != "alice") {
				t.Fatalf("introspection result %+v", res)
			}
			return err
		}},
	{name: "Logout", path: hdrOIDC + "/logout", want: "*keycloak.TransportError",
		run: func(_ *testing.T, ctx context.Context, _ *hdrIdP, c *Client) error {
			return c.Auth.Logout(ctx, "rt-in")
		}},
	{name: "Validate", path: hdrOIDC + "/certs", want: "*keycloak.TokenValidationError",
		run: func(t *testing.T, ctx context.Context, p *hdrIdP, c *Client) error {
			vt, err := c.Auth.Validate(ctx, p.token)
			if err == nil && vt.Subject != "u1" {
				t.Fatalf("validated token %+v", vt)
			}
			return err
		}},
	// admin 레인의 토큰 요청(gocloak → resty) — Client.Admin 이 생성 때 곧바로 보낸다.
	{name: "Admin", path: hdrOIDC + "/token", want: "*keycloak.TransportError",
		run: func(t *testing.T, ctx context.Context, p *hdrIdP, c *Client) error {
			a, err := c.Admin(ctx)
			if err != nil {
				if n := p.adminCalls.Load(); n != 0 {
					t.Fatalf("the admin token fetch failed, yet %d admin request(s) went out", n)
				}
				return err
			}
			if _, err := a.Users.Search(ctx, "", 0, 1); err != nil {
				t.Fatalf("admin call after a good token: %v", err)
			}
			return nil
		}},
	// admin REST 응답 — 토큰은 정상이고 admin 호출의 응답이 머리를 싣는다(같은 전송).
	{name: "AdminCall", path: "/admin/realms/r/users", want: "*keycloak.TransportError",
		run: func(t *testing.T, ctx context.Context, _ *hdrIdP, c *Client) error {
			a, err := c.Admin(ctx)
			if err != nil {
				t.Fatalf("admin token fetch with a normal response: %v", err)
			}
			_, err = a.Users.Search(ctx, "", 0, 1)
			return err
		}},
}

// hdrOutcome 은 호출 하나의 결과와 비용이다.
type hdrOutcome struct {
	err       error
	took      time.Duration
	alloc     uint64 // 호출 동안의 TotalAlloc 증가분(같은 프로세스의 가짜 IdP 포함)
	delivered int64  // target 응답에서 IdP 커널이 받아 간 바이트
	hits      int32  // target 응답을 낸 횟수
}

// hdrMeasure 는 새 Client 로 lane 을 한 번 부르고, IdP 가 target 응답을 다 쓰거나 끊긴 뒤의 수치를 돌려준다.
func hdrMeasure(t *testing.T, key *rsa.PrivateKey, lane hdrLane, s hdrShape) hdrOutcome {
	t.Helper()
	p := newHdrIdP(t, key)
	c, err := New(Config{ServerURL: p.url, Realm: "r", ClientID: "c", ClientSecret: "cs-in"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	p.aim(t, lane.path, s)

	runtime.GC()
	var m0, m1 runtime.MemStats
	runtime.ReadMemStats(&m0)
	t0 := time.Now()
	err = lane.run(t, context.Background(), p, c)
	took := time.Since(t0)
	runtime.ReadMemStats(&m1)
	select {
	case <-p.done:
	case <-time.After(15 * time.Second):
		t.Fatalf("the IdP was still writing the %s head 15s after the call returned — the client neither read it nor hung up", s.name)
	}
	return hdrOutcome{err: err, took: took, alloc: m1.TotalAlloc - m0.TotalAlloc,
		delivered: p.delivered.Load(), hits: p.targetHits.Load()}
}

// TestResponseHeaderCapOnEveryLane 는 레인마다 같은 머리 모양을 돌린다. Keycloak 26.6 이 실제로 보내는 머리와 정확히
// 65,536 바이트인 머리 블록(한 줄 · 1 KiB 줄 여럿)은 지금처럼 통과하고, 65,537 바이트와 16 MiB 는 그 레인의 SDK 오류
// 타입으로 실패한다 — 응답은 한 번만 받고, admin 토큰 요청이 실패하면 admin 요청은 나가지 않으며, 16 MiB 를 거부하는
// 호출의 할당과 IdP 가 밀어 넣을 수 있는 바이트는 16 MiB 가 아니라 상한을 따른다.
func TestResponseHeaderCapOnEveryLane(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	for _, lane := range hdrLanes {
		for _, s := range hdrShapes {
			t.Run(lane.name+"/"+s.name, func(t *testing.T) { hdrCheck(t, lane, s, hdrMeasure(t, key, lane, s)) })
		}
	}
}

// hdrCheck 는 한 행의 결과를 본다 — 응답은 한 번만 받고, 상한 이하는 지금처럼 통과한다.
func hdrCheck(t *testing.T, lane hdrLane, s hdrShape, o hdrOutcome) {
	t.Helper()
	if o.hits != 1 {
		t.Fatalf("the call fetched the %s response %d times, want once", lane.path, o.hits)
	}
	if s.over {
		hdrCheckRefused(t, lane, s, o)
		return
	}
	if o.err != nil {
		t.Fatalf("a %s header block (%d bytes) must pass as before: %T %v", s.name, s.block, o.err, o.err)
	}
}

// hdrCheckRefused 는 상한을 넘는 머리 블록의 결과를 본다 — 그 레인의 오류 타입, 그리고 16 MiB 면 비용.
func hdrCheckRefused(t *testing.T, lane hdrLane, s hdrShape, o hdrOutcome) {
	t.Helper()
	if o.err == nil {
		t.Fatalf("a %d-byte response header block must fail (limit 65536)", s.block)
	}
	if got := fmt.Sprintf("%T", o.err); got != lane.want {
		t.Fatalf("over the limit the error must be %s (this lane's type for a failed response), got %s: %v",
			lane.want, got, o.err)
	}
	if s.block < hdrHuge {
		return
	}
	t.Logf("refused a %d-byte header block in %v with %T: allocated %d bytes, the IdP got %d bytes onto the wire — %v",
		s.block, o.took.Round(time.Millisecond), o.err, o.alloc, o.delivered, o.err)
	if o.delivered > hdrTestLimit+hdrDeliverSlack {
		t.Errorf("the IdP got %d bytes of a %d-byte header block onto the wire — the client read past the 65536-byte limit (bound %d)",
			o.delivered, s.block, hdrTestLimit+hdrDeliverSlack)
	}
	if o.alloc > hdrAllocBound {
		t.Errorf("refusing a %d-byte header block allocated %d bytes — the read is not bounded by the limit (bound %d)",
			s.block, o.alloc, hdrAllocBound)
	}
}
