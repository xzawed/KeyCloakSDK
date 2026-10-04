package keycloak

import (
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// 토큰 응답 상한(등록부 token-response-size-unbounded). 토큰 엔드포인트(세 그랜트 + admin 레인의 토큰 요청)와
// introspection 응답 본문은 1,048,576 바이트(전송이 푼 뒤의 바이트)까지만 받는다.
//
// 수정 전 실측(2026-10-05, 이 트리): admin·introspect 는 32 MiB 를 통째로 읽고 수락했다(피크 12→87 MB). 세
// 그랜트는 x/oauth2 가 `io.LimitReader(body, 1<<20)` 로 **잘라** 읽어 메모리는 묶였지만, 첫 MiB 가 유효한 JSON
// 이면 1,048,577 바이트 본문을 **수락**했다 — 상한이 거부가 아니라 절단이었다.
//
// ⚠️ 경계값은 상수 이름이 아니라 **리터럴**로 적는다 — 상수를 바꾸면 이 테스트가 운다(교차언어 정렬값이다).
const (
	capTestLimit = 1048576
	// keycloakMaxBearer 는 Keycloak 26.6 이 기본 설정에서 받는 가장 긴 Bearer 다(실측 2026-10-03: 65,459 → 401,
	// 한 바이트 더 → 431). 상한은 이것을 어느 레인에서도 막으면 안 된다.
	keycloakMaxBearer = 65459
	// capAllocBound 는 상한을 넘는 16 MiB 본문 하나를 거부하는 호출 전체가 할당해도 되는 양이다. cap+1 을
	// io.ReadAll 로 읽는 값은 약 2.2 MB(실측 — x/oauth2 레인), 16 MiB 를 통째로 읽으면 약 37 MB 다.
	capAllocBound = 6 << 20
)

// capJWT 는 정확히 n 바이트인 JWT 모양 문자열이다(header.payload.signature, base64url 알파벳).
func capJWT(n int) string {
	head := "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImsxIn0."
	sig := "." + strings.Repeat("s", 342)
	if n <= len(head)+len(sig) {
		return strings.Repeat("t", n)
	}
	return head + strings.Repeat("p", n-len(head)-len(sig)) + sig
}

// capShape 는 가짜 IdP 가 토큰·introspect·logout 엔드포인트에 낼 본문의 모양이다.
type capShape struct {
	name   string
	tokLen int    // 토큰 응답의 access_token 길이
	total  int    // > 0 이면 (푼 뒤의) 본문 길이를 정확히 이 값으로 — JSON 뒤를 공백으로 채운다
	enc    string // "" = chunked, "cl" = Content-Length, "gzip" = Content-Encoding: gzip
	over   bool   // 상한을 넘는다 — 실패해야 한다
}

var capShapes = []capShape{
	{name: "bearer65459", tokLen: keycloakMaxBearer},
	{name: "bearer65459-cl", tokLen: keycloakMaxBearer, enc: "cl"},
	{name: "exact-cap", tokLen: 900, total: capTestLimit},
	{name: "exact-cap-cl", tokLen: 900, total: capTestLimit, enc: "cl"},
	{name: "exact-cap-gzip", tokLen: 900, total: capTestLimit, enc: "gzip"},
	{name: "cap+1", tokLen: 900, total: capTestLimit + 1, over: true},
	{name: "cap+1-cl", tokLen: 900, total: capTestLimit + 1, enc: "cl", over: true},
	{name: "cap+1-gzip", tokLen: 900, total: capTestLimit + 1, enc: "gzip", over: true},
	{name: "16MiB", tokLen: 900, total: 16 << 20, over: true},
}

type capIdP struct {
	srv       *httptest.Server
	mu        sync.Mutex
	shape     capShape
	tokenReqs atomic.Int32
	adminReqs atomic.Int32
	bearerLen atomic.Int64 // admin 호출이 실은 Bearer 의 길이
	formTok   atomic.Int64 // introspect 의 token · logout 의 refresh_token 길이
	gzipAsked atomic.Bool  // 토큰·introspect·logout 요청이 Accept-Encoding: gzip 을 실었다(전송이 풀 것이다)
	expiresIn int
}

var capSpaces = []byte(strings.Repeat(" ", 64<<10))

func newCapIdP(t *testing.T, s capShape) *capIdP {
	t.Helper()
	p := &capIdP{shape: s, expiresIn: 300}
	base := "/realms/r/protocol/openid-connect"
	mux := http.NewServeMux()
	mux.HandleFunc(base+"/token", func(w http.ResponseWriter, r *http.Request) {
		p.tokenReqs.Add(1)
		p.noteGzip(r)
		sh, exp := p.current()
		p.serve(w, sh, fmt.Sprintf(`{"access_token":%q,"token_type":"Bearer","expires_in":%d,"refresh_token":"rt-1"}`,
			capJWT(sh.tokLen), exp))
	})
	mux.HandleFunc(base+"/token/introspect", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		p.formTok.Store(int64(len(r.PostForm.Get("token"))))
		p.noteGzip(r)
		sh, _ := p.current()
		p.serve(w, sh, `{"active":true,"sub":"u1","username":"alice","client_id":"c"}`)
	})
	mux.HandleFunc(base+"/logout", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		p.formTok.Store(int64(len(r.PostForm.Get("refresh_token"))))
		p.noteGzip(r)
		sh, _ := p.current()
		p.serve(w, sh, `{}`)
	})
	mux.HandleFunc("/admin/realms/r/users", func(w http.ResponseWriter, r *http.Request) {
		p.adminReqs.Add(1)
		p.bearerLen.Store(int64(len(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))))
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, "[]")
	})
	p.srv = httptest.NewServer(mux)
	t.Cleanup(p.srv.Close)
	return p
}

func (p *capIdP) current() (capShape, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.shape, p.expiresIn
}

func (p *capIdP) set(s capShape) { p.mu.Lock(); p.shape = s; p.mu.Unlock() }

func (p *capIdP) noteGzip(r *http.Request) {
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		p.gzipAsked.Store(true)
	}
}

// serve 는 obj 뒤를 공백으로 채워 (푼 뒤) 정확히 s.total 바이트를 낸다. 클라이언트가 끊으면 쓰기를 멈춘다.
func (p *capIdP) serve(w http.ResponseWriter, s capShape, obj string) {
	pad := 0
	if s.total > len(obj) {
		pad = s.total - len(obj)
	}
	w.Header().Set("Content-Type", "application/json")
	var dst io.Writer = w
	switch s.enc {
	case "cl":
		w.Header().Set("Content-Length", strconv.Itoa(len(obj)+pad))
	case "gzip":
		w.Header().Set("Content-Encoding", "gzip")
		gz := gzip.NewWriter(w)
		defer func() { _ = gz.Close() }()
		dst = gz
	}
	w.WriteHeader(http.StatusOK)
	if _, err := io.WriteString(dst, obj); err != nil {
		return
	}
	for pad > 0 {
		n := min(pad, len(capSpaces))
		if _, err := dst.Write(capSpaces[:n]); err != nil {
			return
		}
		pad -= n
	}
}

func (p *capIdP) client(t *testing.T) *Client {
	t.Helper()
	c, err := New(Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "cs-in"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// capLane 은 상한이 걸리는 공개 호출 하나다. run 은 그 호출의 오류를 돌려주고, 성공이면 토큰이 끝까지 갔는지 본다.
type capLane struct {
	name string
	// over 는 상한을 넘는 본문에서 이 레인이 돌려줘야 하는 SDK 오류 타입이다 — 그 레인이 **이미** 실패한
	// 응답에 쓰던 타입: 그랜트는 *AuthError, admin 토큰 요청은 2xx 본문을 못 읽을 때의 *TransportError,
	// introspect·logout 은 거부한 응답의 *AuthError.
	over string
	run  func(t *testing.T, p *capIdP, c *Client, s capShape) error
}

func capGrantLane(name string, grant func(ctx context.Context, c *Client) (*TokenSet, error)) capLane {
	return capLane{name: name, over: "*keycloak.AuthError", run: func(t *testing.T, _ *capIdP, c *Client, s capShape) error {
		ts, err := grant(context.Background(), c)
		if err == nil && len(ts.AccessToken) != s.tokLen {
			t.Fatalf("access_token %d bytes, want %d", len(ts.AccessToken), s.tokLen)
		}
		return err
	}}
}

var capLanes = []capLane{
	capGrantLane("ClientCredentialsToken", func(ctx context.Context, c *Client) (*TokenSet, error) {
		return c.Auth.ClientCredentialsToken(ctx)
	}),
	capGrantLane("Refresh", func(ctx context.Context, c *Client) (*TokenSet, error) {
		return c.Auth.Refresh(ctx, "rt-in")
	}),
	capGrantLane("ExchangeCode", func(ctx context.Context, c *Client) (*TokenSet, error) {
		return c.Auth.ExchangeCode(ctx, "code-in", "https://app/cb", "verifier-in", "")
	}),
	{name: "Admin", over: "*keycloak.TransportError", run: func(t *testing.T, p *capIdP, c *Client, s capShape) error {
		a, err := c.Admin(context.Background())
		if err != nil {
			if n := p.adminReqs.Load(); n != 0 {
				t.Fatalf("the admin token fetch failed, yet %d admin request(s) went out", n)
			}
			return err
		}
		if _, err := a.Users.Search(context.Background(), "", 0, 1); err != nil {
			t.Fatalf("admin call after a good token: %v", err)
		}
		if got := p.bearerLen.Load(); got != int64(s.tokLen) {
			t.Fatalf("the admin call carried a %d-byte bearer, want %d", got, s.tokLen)
		}
		return nil
	}},
	{name: "Introspect", over: "*keycloak.AuthError", run: func(t *testing.T, p *capIdP, c *Client, s capShape) error {
		tok := capJWT(s.tokLen)
		res, err := c.Auth.Introspect(context.Background(), tok)
		if err != nil {
			return err
		}
		if !res.Active || res.Username != "alice" {
			t.Fatalf("introspection result %+v", res)
		}
		if got := p.formTok.Load(); got != int64(len(tok)) {
			t.Fatalf("the IdP saw a %d-byte token, want %d", got, len(tok))
		}
		return nil
	}},
	{name: "Logout", over: "*keycloak.AuthError", run: func(t *testing.T, p *capIdP, c *Client, s capShape) error {
		rt := capJWT(s.tokLen)
		if err := c.Auth.Logout(context.Background(), rt); err != nil {
			return err
		}
		if got := p.formTok.Load(); got != int64(len(rt)) {
			t.Fatalf("the IdP saw a %d-byte refresh token, want %d", got, len(rt))
		}
		return nil
	}},
}

// TestTokenResponseCapOnEveryLane 는 레인마다 같은 본문 모양을 돌린다: Keycloak 이 받는 가장 긴 Bearer 와 정확히
// 상한인 본문은 지금처럼 통과하고, 상한 + 1 바이트(청크·Content-Length·gzip 를 푼 뒤)와 16 MiB 는 그 레인의 SDK
// 오류 타입으로 실패한다 — 메시지가 상한을 말하고, admin 레인은 admin 요청을 하나도 보내지 않으며, 16 MiB 를
// 거부하는 호출의 할당은 본문이 아니라 상한을 따른다.
func TestTokenResponseCapOnEveryLane(t *testing.T) {
	for _, lane := range capLanes {
		for _, s := range capShapes {
			t.Run(lane.name+"/"+s.name, func(t *testing.T) {
				p := newCapIdP(t, s)
				c := p.client(t)
				runtime.GC()
				var m0, m1 runtime.MemStats
				runtime.ReadMemStats(&m0)
				err := lane.run(t, p, c, s)
				runtime.ReadMemStats(&m1)
				alloc := m1.TotalAlloc - m0.TotalAlloc
				if s.enc == "gzip" && !p.gzipAsked.Load() {
					t.Fatal("the request did not ask for gzip, so the transport decoded nothing — the gzip row is vacuous")
				}
				if !s.over {
					if err != nil {
						t.Fatalf("a body of at most 1048576 bytes must pass as before: %T %v", err, err)
					}
					return
				}
				if err == nil {
					t.Fatalf("a %d-byte body must fail", s.total)
				}
				if got := fmt.Sprintf("%T", err); got != lane.over {
					t.Fatalf("over the cap the error must be %s (this lane's type for a failed response), got %s: %v",
						lane.over, got, err)
				}
				if !strings.Contains(err.Error(), "exceeds 1048576 bytes") {
					t.Fatalf("the message must say what failed: %v", err)
				}
				if lane.name == "Admin" && p.adminReqs.Load() != 0 {
					t.Fatalf("no admin request may go out after a refused token response, got %d", p.adminReqs.Load())
				}
				if s.total >= 16<<20 {
					t.Logf("refused a %d-byte body with %T, allocating %d bytes", s.total, err, alloc)
					if alloc > capAllocBound {
						t.Fatalf("refusing a %d-byte body allocated %d bytes — the read is not bounded by the cap (limit %d)",
							s.total, alloc, capAllocBound)
					}
				}
			})
		}
	}
}

// TestTokenResponseCapSmallBodyAllocatesLittle — 상한 판정이 상한만 한 버퍼를 미리 잡으면 작은 토큰 요청
// 하나하나가 1 MiB 를 할당한다. 2 KiB 본문의 호출 전체(서버 포함, 실측 86–251 KB)는 상한의 절반보다 작아야 한다.
func TestTokenResponseCapSmallBodyAllocatesLittle(t *testing.T) {
	s := capShape{name: "2KiB", tokLen: 900, total: 2 << 10}
	for _, lane := range capLanes {
		t.Run(lane.name, func(t *testing.T) {
			p := newCapIdP(t, s)
			c := p.client(t)
			runtime.GC()
			var m0, m1 runtime.MemStats
			runtime.ReadMemStats(&m0)
			err := lane.run(t, p, c, s)
			runtime.ReadMemStats(&m1)
			if err != nil {
				t.Fatalf("2 KiB body: %v", err)
			}
			if alloc := m1.TotalAlloc - m0.TotalAlloc; alloc > capTestLimit/2 {
				t.Fatalf("a 2 KiB body allocated %d bytes — near the cap, so the read is sized by the cap, not the body", alloc)
			}
		})
	}
}

// capSource 는 size 바이트를 내는 본문이다. 지금까지 읽힌 위치 + 요청한 길이의 최댓값(farthest)을 적는다 —
// 상한 래퍼가 본문에 cap+1 바이트 너머를 **요청**하는지를 재는 계측기다. endErr 가 있으면 끝에서 io.EOF 대신 낸다.
type capSource struct {
	size, pos, farthest int64
	endErr              error
	eofWithData         bool // 마지막 바이트와 함께 io.EOF 를 낸다(io.Reader 가 허용하는 다른 끝맺음)
}

func (s *capSource) Read(p []byte) (int, error) {
	if s.pos >= s.size {
		if s.endErr != nil {
			return 0, s.endErr
		}
		return 0, io.EOF
	}
	s.farthest = max(s.farthest, s.pos+int64(len(p)))
	n := min(int64(len(p)), s.size-s.pos)
	s.pos += n
	if s.eofWithData && s.pos == s.size {
		return int(n), io.EOF
	}
	return int(n), nil
}

func (s *capSource) Close() error { return nil }

// TestCappedBodyNeverAsksPastCapPlusOne 는 래퍼를 세 읽기 모양으로 몬다 — x/oauth2(`io.LimitReader(body,
// 1<<20)`: 상한 바이트 너머를 스스로 묻지 않는다), resty(`io.ReadAll`: 얼마든 묻는다), 한 바이트씩. 어느 모양에서도
// 본문에 cap+1 너머를 묻지 않고, 상한 이하는 그대로 넘기며, 넘으면 상한 오류다. 끝난 뒤의 Read 는 같은 결과를 낸다.
func TestCappedBodyNeverAsksPastCapPlusOne(t *testing.T) {
	readers := []struct {
		name string
		read func(io.Reader) ([]byte, error)
	}{
		{"x/oauth2", func(r io.Reader) ([]byte, error) { return io.ReadAll(io.LimitReader(r, 1<<20)) }},
		{"resty", io.ReadAll},
		{"one-byte", func(r io.Reader) ([]byte, error) { return io.ReadAll(iotestOneByte{r}) }},
	}
	for _, rd := range readers {
		for _, c := range []struct {
			size        int64
			eofWithData bool
		}{{0, false}, {2 << 10, false}, {capTestLimit, false}, {capTestLimit, true}, {capTestLimit + 1, false},
			{capTestLimit + 1, true}, {16 << 20, false}} {
			size := c.size
			t.Run(fmt.Sprintf("%s/%d/eofWithData=%v", rd.name, size, c.eofWithData), func(t *testing.T) {
				src := &capSource{size: size, eofWithData: c.eofWithData}
				hit := new(atomic.Bool)
				b := &cappedBody{ReadCloser: src, hit: hit}
				got, err := rd.read(b)
				if src.farthest > capTestLimit+1 {
					t.Fatalf("the body was asked for bytes up to %d, past cap+1 (%d)", src.farthest, capTestLimit+1)
				}
				if size <= capTestLimit {
					if err != nil || int64(len(got)) != size || hit.Load() {
						t.Fatalf("a %d-byte body must pass whole: len %d, err %v, hit %v", size, len(got), err, hit.Load())
					}
				} else if !errors.Is(err, errTokenResponseTooLarge) || !hit.Load() || len(got) > capTestLimit {
					t.Fatalf("a %d-byte body must be refused after at most the cap: len %d, err %v, hit %v",
						size, len(got), err, hit.Load())
				}
				if n, again := b.Read(make([]byte, 8)); n != 0 || (again != io.EOF && !errors.Is(again, errTokenResponseTooLarge)) {
					t.Fatalf("a Read after the end must repeat the end, got %d, %v", n, again)
				}
			})
		}
	}
	// 정확히 상한 길이에서 끝난 본문의 읽기 오류는 상한 오류가 아니라 그 오류로 나간다(이미 정화된 오류다).
	bad := errors.New("read failed after the last byte")
	b := &cappedBody{ReadCloser: &capSource{size: capTestLimit, endErr: bad}, hit: new(atomic.Bool)}
	if _, err := io.ReadAll(b); !errors.Is(err, bad) || b.hit.Load() {
		t.Fatalf("a read error right after the cap's last byte must pass through, got %v (hit %v)", err, b.hit.Load())
	}
}

// iotestOneByte 는 Read 마다 한 바이트만 넘긴다(testing/iotest.OneByteReader 와 같다 — 그 패키지를 끌어오지 않으려고).
type iotestOneByte struct{ r io.Reader }

func (o iotestOneByte) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	return o.r.Read(p[:1])
}

// TestAdminTokenRefreshOverCapSendsNoAdminRequest — admin 클라이언트가 이미 있고, 만료된 토큰을 다시 받는
// 응답이 상한을 넘으면 그 admin 호출은 요청 없이 실패한다(생성 때만이 아니다).
func TestAdminTokenRefreshOverCapSendsNoAdminRequest(t *testing.T) {
	p := newCapIdP(t, capShape{name: "small", tokLen: 900})
	p.mu.Lock()
	p.expiresIn = 1 // 기본 skew 30초 안 — 공급자가 즉시 만료로 보고 admin 호출마다 다시 받는다
	p.mu.Unlock()
	c := p.client(t)
	a, err := c.Admin(context.Background())
	if err != nil {
		t.Fatalf("admin: %v", err)
	}
	p.set(capShape{name: "cap+1", tokLen: 900, total: capTestLimit + 1})
	before := p.tokenReqs.Load()
	_, err = a.Users.Search(context.Background(), "", 0, 1)
	var te *TransportError
	if !errors.As(err, &te) || !strings.Contains(err.Error(), "exceeds 1048576 bytes") {
		t.Fatalf("the refetched over-cap token response must fail the admin call as *TransportError, got %T %v", err, err)
	}
	if p.tokenReqs.Load() != before+1 {
		t.Fatalf("the admin call must have refetched the token once (%d → %d)", before, p.tokenReqs.Load())
	}
	if n := p.adminReqs.Load(); n != 0 {
		t.Fatalf("no admin request may go out with a refused token, got %d", n)
	}
}
