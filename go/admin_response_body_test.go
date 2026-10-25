package keycloak

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Nerzal/gocloak/v13"
)

// admin 레인이 읽지 않는 응답 본문은 읽지 않는다 — resty 는 모든 본문을 끝까지 읽으므로 그 아래 전송(adminBodyTransport)이 끝을
// 정한다. 파사드의 쓰기 호출(Create·Update·Delete)이 받는 2xx 는 본문이 비어 보이고(그 호출이 컨텍스트에 표시한다 — Raw() 호출은
// 본문을 그대로 받는다), 오류 상태(3xx 이상)의 본문은 tokenResponseMaxBytes 에서 끝난다. 그 밖의 성공 본문(목록 등)에는 상한이 없다.
// admin 토큰 요청의 오류 본문은 이 상한과 토큰 상한(tokencap.go)을 함께 지난다 — 아래 대조가 둘의 맞물림을 잰다.
//
// 수정 전(실측 2026-10-25, Windows · go1.26.4 · 루프백 · main ee862c6 = 0a4cfee 의 go/ — 등록부 admin-response-body-unbounded 의 재스캔): create 201 +
// 64 MiB 를 서버가 끝까지 썼고(103–107 ms) · 201 뒤 멈춘 서버 앞에서 create 가 읽기 타임아웃(4 s) 끝에 *TransportError(4,001–4,002 ms) ·
// 404 + 64 MiB 를 끝까지 읽었다. 공개 API(NewAdminClient + 정적 토큰 공급자)와 로컬 루프백만 쓴다 — TLS 갈래만 시험 CA 를 믿게 하려고
// 그 클라이언트의 전송(a.tr)에 손을 댄다(Config 에 TLS 근원 손잡이가 없다).

const (
	rbCap          = tokenResponseMaxBytes
	rbHuge         = 64 << 20
	rbWrittenBound = 16 << 20 // 끊긴 교환에서 서버가 써도 되는 본문 — 상한 + 소켓 버퍼를 넉넉히 넘는다
	rbUser         = `{"id":"x","username":"alice"}`
	rbNotFound     = `{"error":"User not found"}`
	rbStallRepeats = 5
)

var rbSlab = bytes.Repeat([]byte{' '}, 64<<10)

// rbToken 은 네트워크 없이 토큰을 주는 공급자다 — admin 응답만 잰다.
type rbToken string

func (t rbToken) Token(context.Context) (string, error) { return string(t), nil }

// rbReply 는 admin 응답 하나다. written 은 서버가 쓴 본문 바이트를 센다. 돌려주는 값은 연결을 이어 쓸지다.
type rbReply func(conn net.Conn, written *atomic.Int64) bool

// rbServer 는 원시 HTTP/1.1 서버(평문 또는 TLS)다 — 연결 하나에 요청 여럿. 받아들인 연결 수 · 마지막 admin 응답이 쓴 본문 바이트 ·
// 그 응답의 쓰기가 끝났는지를 센다.
type rbServer struct {
	ln      net.Listener
	route   func(method, path string) rbReply
	conns   atomic.Int32
	written atomic.Int64
	mu      sync.Mutex
	done    chan struct{}
	open    []net.Conn
}

func newRBServer(t *testing.T, tlsCfg *tls.Config, route func(method, path string) rbReply) *rbServer {
	t.Helper()
	var ln net.Listener
	var err error
	if tlsCfg == nil {
		ln, err = net.Listen("tcp", "127.0.0.1:0")
	} else {
		ln, err = tls.Listen("tcp", "127.0.0.1:0", tlsCfg)
	}
	if err != nil {
		t.Fatal(err)
	}
	// done 은 용량 1 — 시험이 기다리기 전에 쓰기가 끝나도 신호가 남는다(비버퍼면 사라져 30 초를 기다렸다).
	s := &rbServer{ln: ln, route: route, done: make(chan struct{}, 1)}
	t.Cleanup(s.close)
	go s.serve()
	return s
}

func (s *rbServer) url(scheme string) string {
	return scheme + "://" + s.ln.Addr().String()
}

func (s *rbServer) close() {
	_ = s.ln.Close()
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.open {
		_ = c.Close()
	}
}

func (s *rbServer) serve() {
	for {
		c, err := s.ln.Accept()
		if err != nil {
			return
		}
		s.conns.Add(1)
		s.mu.Lock()
		s.open = append(s.open, c)
		s.mu.Unlock()
		go s.exchanges(c)
	}
}

func (s *rbServer) exchanges(c net.Conn) {
	defer func() { _ = c.Close() }()
	br := bufio.NewReader(c)
	for {
		req, err := http.ReadRequest(br)
		if err != nil {
			return
		}
		_, _ = io.Copy(io.Discard, req.Body)
		_ = req.Body.Close()
		reply := s.route(req.Method, req.URL.RequestURI())
		s.written.Store(0)
		keep := reply(c, &s.written)
		select {
		case s.done <- struct{}{}:
		default:
		}
		if !keep {
			return
		}
	}
}

// awaitReply 는 마지막 admin 응답의 쓰기가 끝날 때까지(최대 30 초) 기다린다 — 끝나지 않으면 거짓.
func (s *rbServer) awaitReply() bool {
	select {
	case <-s.done:
		return true
	case <-time.After(30 * time.Second):
		return false
	}
}

// rbWrite 는 머리를 쓰고 본문 head 와 tail 사이를 공백으로 채워 total 바이트를 쓴다(쓴 본문 바이트를 센다).
func rbWrite(c net.Conn, written *atomic.Int64, status, headers, head, tail string, total int) error {
	if _, err := io.WriteString(c, "HTTP/1.1 "+status+"\r\n"+headers+"Content-Length: "+strconv.Itoa(total)+"\r\n\r\n"); err != nil {
		return err
	}
	n, err := io.WriteString(c, head)
	written.Add(int64(n))
	if err != nil {
		return err
	}
	for left := total - len(head) - len(tail); left > 0; {
		k := min(left, len(rbSlab))
		n, err := c.Write(rbSlab[:k])
		written.Add(int64(n))
		if err != nil {
			return err
		}
		left -= k
	}
	n, err = io.WriteString(c, tail)
	written.Add(int64(n))
	return err
}

func rbPadded(status, headers, head string, total int) rbReply {
	return rbFramed(status, headers, head, "", total)
}

// rbFramed 는 head 와 tail 사이를 공백으로 채운 본문이다 — `{"errorMessage":"` 와 `"}` 사이를 채우면 통째로는 유효하고 잘리면 깨지는 JSON 이다.
func rbFramed(status, headers, head, tail string, total int) rbReply {
	return func(c net.Conn, written *atomic.Int64) bool {
		return rbWrite(c, written, status, headers, head, tail, total) == nil
	}
}

func rbExact(status, headers, body string) rbReply {
	return rbPadded(status, headers, body, len(body))
}

// rbBytes 는 body 를 그대로 싣는 응답이다(쓴 본문 바이트를 센다).
func rbBytes(status, headers string, body []byte) rbReply {
	return func(c net.Conn, written *atomic.Int64) bool {
		if _, err := io.WriteString(c, "HTTP/1.1 "+status+"\r\n"+headers+"Content-Length: "+strconv.Itoa(len(body))+"\r\n\r\n"); err != nil {
			return false
		}
		n, err := c.Write(body)
		written.Add(int64(n))
		return err == nil
	}
}

// rbGzip 은 head 뒤에 공백 pad 바이트와 tail 을 이은 내용을 gzip 으로 압축한다.
func rbGzip(t *testing.T, head string, pad int, tail string) []byte {
	t.Helper()
	var b bytes.Buffer
	zw := gzip.NewWriter(&b)
	_, err := io.WriteString(zw, head)
	for left := pad; err == nil && left > 0; left -= len(rbSlab) {
		_, err = zw.Write(rbSlab[:min(left, len(rbSlab))])
	}
	if err == nil {
		_, err = io.WriteString(zw, tail)
	}
	if err == nil {
		err = zw.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// rbStalled 는 1 MiB 를 알리고 공백 sent 바이트만 쓴 뒤 20 초 동안 읽지도 쓰지도 않고 붙든다.
func rbStalled(status, headers string, sent int) rbReply {
	return func(c net.Conn, written *atomic.Int64) bool {
		if _, err := io.WriteString(c, "HTTP/1.1 "+status+"\r\n"+headers+"Content-Length: 1048576\r\n\r\n"); err != nil {
			return false
		}
		for left := sent; left > 0; {
			k := min(left, len(rbSlab))
			n, err := c.Write(rbSlab[:k])
			written.Add(int64(n))
			if err != nil {
				return false
			}
			left -= k
		}
		time.Sleep(20 * time.Second)
		return false
	}
}

const (
	rbTyped    = "Content-Type: application/json\r\n"
	rbLocation = "Location: http://127.0.0.1:1/admin/realms/r/users/abc\r\n"
)

func rbAdmin(t *testing.T, s *rbServer, pool *x509.CertPool, readTimeout time.Duration) *AdminClient {
	t.Helper()
	scheme := "http"
	if pool != nil {
		scheme = "https"
	}
	cfg := Config{ServerURL: s.url(scheme), Realm: "r", ClientID: "app", ConnectTimeout: 5000, ReadTimeout: readTimeout.Milliseconds()}
	a, err := NewAdminClient(context.Background(), cfg, rbToken("good"))
	if err != nil {
		t.Fatal(err)
	}
	if pool != nil {
		a.tr.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS13}
	}
	t.Cleanup(func() { _ = a.Close() })
	return a
}

// rbTLS 는 127.0.0.1 의 시험 인증서(실행마다 새로)와 그것을 믿는 풀을 만든다 — 저장소에 키를 두지 않는다.
func rbTLS(t *testing.T) (*tls.Config, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "127.0.0.1"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1)}, IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(parsed)
	return &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}, MinVersion: tls.VersionTLS13}, pool
}

func rbUserRep() gocloak.User {
	name := "u"
	return gocloak.User{Username: &name}
}

// rbAllocated 는 f 하나가 이 프로세스에 더한 할당(TotalAlloc 의 차)이다 — admin 호출은 호출한 고루틴에서 돈다.
func rbAllocated(f func()) uint64 {
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	f()
	runtime.ReadMemStats(&after)
	return after.TotalAlloc - before.TotalAlloc
}

// (1) 파사드의 쓰기 호출이 받는 2xx 본문은 읽지 않는다 — 응답 모양(201 · 200 · 미디어 타입 유무)이 달라도 호출은 결과를 돌려주고
// 서버는 64 MiB 를 다 쓰지 못한다. 수정 전: 여섯 자리 모두 끝까지.
func TestAdminBodiesNoCallReads_areNotReadOn(t *testing.T) {
	cases := []struct {
		name  string
		reply rbReply
		call  func(*AdminClient) error
	}{
		{"create 201 미디어 타입 없음", rbPadded("201 Created", rbLocation, "", rbHuge), func(a *AdminClient) error {
			id, err := a.Users.Create(context.Background(), rbUserRep())
			if err == nil && id != "abc" {
				return errors.New("id " + id)
			}
			return err
		}},
		{"create 201 미디어 타입 있음", rbPadded("201 Created", rbLocation+rbTyped, "{}", rbHuge), func(a *AdminClient) error {
			id, err := a.Users.Create(context.Background(), rbUserRep())
			if err == nil && id != "abc" {
				return errors.New("id " + id)
			}
			return err
		}},
		{"create 200 미디어 타입 없음", rbPadded("200 OK", rbLocation, "", rbHuge), func(a *AdminClient) error {
			id, err := a.Users.Create(context.Background(), rbUserRep())
			if err == nil && id != "abc" {
				return errors.New("id " + id)
			}
			return err
		}},
		{"update 200 미디어 타입 있음", rbPadded("200 OK", rbTyped, "{}", rbHuge), func(a *AdminClient) error {
			return a.Users.Update(context.Background(), "x", rbUserRep())
		}},
		{"delete 200 미디어 타입 있음", rbPadded("200 OK", rbTyped, "{}", rbHuge), func(a *AdminClient) error {
			return a.Users.Delete(context.Background(), "x")
		}},
		{"delete 200 미디어 타입 없음", rbPadded("200 OK", "", "", rbHuge), func(a *AdminClient) error {
			return a.Users.Delete(context.Background(), "x")
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newRBServer(t, nil, func(string, string) rbReply { return c.reply })
			a := rbAdmin(t, s, nil, 20*time.Second)
			start := time.Now()
			err := c.call(a)
			elapsed := time.Since(start)
			_ = a.Close()
			finished := s.awaitReply()
			t.Logf("[AdminResponseBody] %s → err=%v · %d ms · server wrote %d B", c.name, err, elapsed.Milliseconds(), s.written.Load())
			if err != nil {
				t.Fatalf("결과를 돌려주지 않았다: %v", err)
			}
			if !finished || s.written.Load() > rbWrittenBound {
				t.Fatalf("읽지 않는 본문을 읽었다 — server wrote %d B (한도 %d) finished=%v", s.written.Load(), rbWrittenBound, finished)
			}
		})
	}
}

// (1b) 파사드의 쓰기 호출 열다섯 — 다섯 리소스의 Create·Update·Delete(Realms.Update 는 raw PUT)는 모두 2xx 본문을 읽지 않는다. 그 표시
// (withoutBody)를 한 자리라도 빠뜨리면 그 자리가 64 MiB 를 읽는다 — 자리마다 잰다.
func TestAdminFacadeWrites_readNoBody(t *testing.T) {
	ctx := context.Background()
	str := func(s string) *string { return &s }
	writes := []struct {
		name string
		call func(*AdminClient) error
	}{
		{"Users.Create", func(a *AdminClient) error { _, err := a.Users.Create(ctx, rbUserRep()); return err }},
		{"Users.Update", func(a *AdminClient) error { return a.Users.Update(ctx, "x", rbUserRep()) }},
		{"Users.Delete", func(a *AdminClient) error { return a.Users.Delete(ctx, "x") }},
		{"Clients.Create", func(a *AdminClient) error {
			_, err := a.Clients.Create(ctx, gocloak.Client{ClientID: str("c")})
			return err
		}},
		{"Clients.Update", func(a *AdminClient) error { return a.Clients.Update(ctx, "x", gocloak.Client{ClientID: str("c")}) }},
		{"Clients.Delete", func(a *AdminClient) error { return a.Clients.Delete(ctx, "x") }},
		{"Groups.Create", func(a *AdminClient) error { _, err := a.Groups.Create(ctx, gocloak.Group{Name: str("g")}); return err }},
		{"Groups.Update", func(a *AdminClient) error { return a.Groups.Update(ctx, "x", gocloak.Group{Name: str("g")}) }},
		{"Groups.Delete", func(a *AdminClient) error { return a.Groups.Delete(ctx, "x") }},
		{"Roles.Create", func(a *AdminClient) error { return a.Roles.Create(ctx, gocloak.Role{Name: str("ro")}) }},
		{"Roles.Update", func(a *AdminClient) error { return a.Roles.Update(ctx, "ro", gocloak.Role{Name: str("ro")}) }},
		{"Roles.Delete", func(a *AdminClient) error { return a.Roles.Delete(ctx, "ro") }},
		{"Realms.Create", func(a *AdminClient) error { return a.Realms.Create(ctx, gocloak.RealmRepresentation{Realm: str("re")}) }},
		{"Realms.Update", func(a *AdminClient) error { return a.Realms.Update(ctx, "re", gocloak.RealmRepresentation{}) }},
		{"Realms.Delete", func(a *AdminClient) error { return a.Realms.Delete(ctx, "re") }},
	}
	for _, w := range writes {
		t.Run(w.name, func(t *testing.T) {
			s := newRBServer(t, nil, func(method, _ string) rbReply {
				if method == http.MethodPost {
					return rbPadded("201 Created", rbLocation+rbTyped, "{}", rbHuge)
				}
				return rbPadded("200 OK", rbTyped, "{}", rbHuge)
			})
			a := rbAdmin(t, s, nil, 20*time.Second)
			err := w.call(a)
			_ = a.Close()
			finished := s.awaitReply()
			t.Logf("[AdminResponseBody] %s → err=%v · server wrote %d B", w.name, err, s.written.Load())
			if err != nil {
				t.Fatalf("결과를 돌려주지 않았다: %v", err)
			}
			if !finished || s.written.Load() > rbWrittenBound {
				t.Fatalf("읽지 않는 본문을 읽었다 — server wrote %d B (한도 %d) finished=%v", s.written.Load(), rbWrittenBound, finished)
			}
		})
	}
}

// 대조 — Raw() 로 부른 gocloak 메서드는 2xx 본문을 그대로 받는다: PUT 의 200 본문(UpdateGroupManagementPermissions)과 201 본문
// (CreateClientRepresentation — 클라이언트 등록 API)을 결합한다. 전송이 「201·PUT 의 답은 본문이 없다」로 자르면 이 둘이 빈 값을 냈다
// (이 PR 의 첫 설계 — PM 이 gocloak v13.9.0 을 판독해 찾았다). 그래서 쓰지 않는 본문은 파사드의 표시(withoutBody)로만 끝난다.
func TestAdminRawCalls_keepTheirBodies(t *testing.T) {
	s := newRBServer(t, nil, func(method, _ string) rbReply {
		if method == http.MethodPut {
			return rbExact("200 OK", rbTyped, `{"enabled":true,"resource":"res-1"}`)
		}
		return rbExact("201 Created", rbTyped, `{"clientId":"made"}`)
	})
	a := rbAdmin(t, s, nil, 20*time.Second)
	ctx := context.Background()
	perm, err := a.Raw().UpdateGroupManagementPermissions(ctx, "good", "r", "g1", gocloak.ManagementPermissionRepresentation{})
	if err != nil || perm == nil || perm.Resource == nil || *perm.Resource != "res-1" {
		t.Fatalf("PUT 의 200 본문을 결합하지 못했다: %+v %v", perm, err)
	}
	cl, err := a.Raw().CreateClientRepresentation(ctx, "good", "r", gocloak.Client{})
	if err != nil || cl == nil || cl.ClientID == nil || *cl.ClientID != "made" {
		t.Fatalf("201 본문을 결합하지 못했다: %+v %v", cl, err)
	}
}

// (2) 오류 본문은 상한까지만 쥔다 — 404 + 64 MiB 는 ErrNotFound 이고 서버는 다 쓰지 못하며 호출의 할당이 묶인다. 수정 전: 끝까지 읽었다.
// 잘려서 깨지는 JSON(`{"errorMessage":"…"}` 의 문자열이 상한 너머로 이어진다)도 상태를 지킨다 — 이 PR 의 첫 상한은 이것을 *TransportError 로
// 바꿨다(Grok 레그 지목 · 실측). 상한은 3xx 부터다: Location 없는 300 은 net/http 가 따라가지 않아 resty 가 본문을 읽는다(그 답을 무엇으로
// 돌려주는지는 여기서 재지 않는다).
func TestAdminErrorBody_isHeldOnlyUpToTheCap(t *testing.T) {
	cases := []struct {
		name, status, head, tail string
	}{
		{"404 · 상한 안에서 닫히는 JSON", "404 Not Found", rbNotFound, ""},
		{"404 · 상한 너머로 이어지는 JSON", "404 Not Found", `{"errorMessage":"`, `"}`},
		{"300", "300 Multiple Choices", rbNotFound, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newRBServer(t, nil, func(string, string) rbReply { return rbFramed(c.status, rbTyped, c.head, c.tail, rbHuge) })
			a := rbAdmin(t, s, nil, 20*time.Second)
			var err error
			allocated := rbAllocated(func() { _, err = a.Users.Get(context.Background(), "x") })
			_ = a.Close()
			finished := s.awaitReply()
			t.Logf("[AdminResponseBody] get %s + 64 MiB → err=%v · allocated %d B · server wrote %d B", c.name, err, allocated, s.written.Load())
			if c.status == "404 Not Found" && !errors.Is(err, ErrNotFound) {
				t.Fatalf("ErrNotFound 가 아니다: %T %v", err, err)
			}
			if !finished || s.written.Load() > rbWrittenBound {
				t.Fatalf("오류 본문의 나머지를 읽었다 — server wrote %d B finished=%v", s.written.Load(), finished)
			}
			if allocated > rbErrorAllocationBound {
				t.Fatalf("할당이 한도를 넘었다 — %d B (한도 %d)", allocated, rbErrorAllocationBound)
			}
		})
	}
}

// (2b) 호출자가 압축을 직접 청한 오류 본문도 푼 뒤 상한까지만 쥔다 — resty 클라이언트에 Accept-Encoding 을 건 소비자(Raw() 로 닿는 손잡이 —
// 파사드 호출에도 실린다)의 요청이다. net/http 는 자기가 청한 gzip 만 풀므로 이 본문은 Content-Encoding 이 남은 채 오고 resty 가 스스로 푼다:
// 압축 바이트를 상한에서 자르면 resty 가 잘린 gzip 을 풀다 실패해 404 가 *TransportError 였고, 상한 안의 작은 gzip 은 끝없이 풀렸다(Grok 레그 지목).
func TestAdminErrorBodyTheCallerAskedCompressed_isHeldOnlyUpToTheCap(t *testing.T) {
	random := make([]byte, 3<<19)
	if _, err := rand.Read(random); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		body []byte
	}{
		{"압축이 상한을 넘는다", rbGzip(t, `{"errorMessage":"`+base64.StdEncoding.EncodeToString(random), 0, `"}`)},
		{"작은 압축이 상한 너머로 풀린다", rbGzip(t, rbNotFound, rbHuge, "")},
	}
	if len(cases[0].body) <= rbCap+1 || len(cases[1].body) >= rbCap {
		t.Fatalf("행이 성립하지 않는다 — 압축 %d B(상한을 넘어야 한다) · %d B(상한 안이어야 한다)", len(cases[0].body), len(cases[1].body))
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newRBServer(t, nil, func(string, string) rbReply {
				return rbBytes("404 Not Found", rbTyped+"Content-Encoding: gzip\r\n", c.body)
			})
			a := rbAdmin(t, s, nil, 20*time.Second)
			a.Raw().RestyClient().SetHeader("Accept-Encoding", "gzip")
			var err error
			allocated := rbAllocated(func() { _, err = a.Users.Get(context.Background(), "x") })
			t.Logf("[AdminResponseBody] get 404 + gzip %d B(%s) → %T %v · allocated %d B", len(c.body), c.name, err, err, allocated)
			if !errors.Is(err, ErrNotFound) {
				t.Fatalf("ErrNotFound 가 아니다: %T %v", err, err)
			}
			if allocated > rbErrorAllocationBound {
				t.Fatalf("할당이 한도를 넘었다 — %d B (한도 %d)", allocated, rbErrorAllocationBound)
			}
		})
	}
}

// rbErrorAllocationBound 는 64 MiB 오류 본문 호출 하나의 할당 한도다. 근거(2026-10-25 실측, Windows · go1.26.4): 수정 전 165.5 MB(서버가
// 64 MiB 를 끝까지 썼다), 수정 뒤 4.5 MB(서버 1.1 MB — 전송이 상한 + 1 까지 읽고 resty 가 그것을 다시 읽는다) — 16 MiB(16.8 MB)는 수정 뒤보다
// 3.7 배, 수정 전보다 10 배 떨어진다.
const rbErrorAllocationBound = 16 << 20

// 대조 — 상한 안의 오류 본문은 통째로 실리고, 한 바이트 넘으면 상한까지 잘린다(경계). Realms.Update 는 오류 본문을 그대로 메시지에 싣는다.
func TestAdminErrorBodyAtTheCap_isCarriedWhole(t *testing.T) {
	for _, total := range []int{rbCap, rbCap + 1} {
		s := newRBServer(t, nil, func(string, string) rbReply {
			return rbPadded("404 Not Found", "Content-Type: text/plain\r\n", "missing", total)
		})
		a := rbAdmin(t, s, nil, 20*time.Second)
		err := a.Realms.Update(context.Background(), "r", gocloak.RealmRepresentation{})
		var adminErr *AdminError
		if !errors.As(err, &adminErr) {
			t.Fatalf("%d B 본문 → *AdminError 가 아니다: %v", total, err)
		}
		t.Logf("[AdminResponseBody] realms update 404 %d B → message %d B", total, len(adminErr.Msg))
		if len(adminErr.Msg) != rbCap || !strings.HasPrefix(adminErr.Msg, "missing") {
			t.Fatalf("%d B 본문 → message %d B (기대 %d)", total, len(adminErr.Msg), rbCap)
		}
	}
}

// 대조 — admin 토큰 요청의 오류 본문은 토큰 상한이 거부한다: 401 + 상한 + 1 바이트는 상한을 말하는 *TransportError, 정확히 상한이면 본문의
// 오류 코드까지 읽은 401 *AdminError 다. 그 본문은 오류 본문 상한과 토큰 상한을 함께 지나는데, 둘이 같고 토큰 상한이 상한에 닿는 읽기 안에서
// 한 바이트 너머를 보기 때문에 거부가 살아 있다 — 오류 본문 상한을 토큰 상한보다 낮추면 거부가 절단으로 바뀌어 이 시험이 운다.
func TestAdminTokenErrorBodyPastTheCap_isRefusedByTheTokenCap(t *testing.T) {
	for _, total := range []int{rbCap, rbCap + 1} {
		s := newRBServer(t, nil, func(string, string) rbReply {
			return rbPadded("401 Unauthorized", rbTyped, `{"error":"invalid_client"}`, total)
		})
		c, err := New(Config{ServerURL: s.url("http"), Realm: "r", ClientID: "app", ClientSecret: "cs-in"})
		if err != nil {
			t.Fatal(err)
		}
		_, err = c.Admin(context.Background())
		_ = c.Close()
		t.Logf("[AdminResponseBody] admin 토큰 요청 401 %d B → %T %v", total, err, err)
		refused := err != nil && strings.Contains(err.Error(), "exceeds 1048576 bytes")
		var transportErr *TransportError
		var adminErr *AdminError
		if total > rbCap && (!refused || !errors.As(err, &transportErr)) {
			t.Fatalf("상한을 넘는 오류 본문을 토큰 상한이 거부하지 않았다: %T %v", err, err)
		}
		if total == rbCap && (refused || !errors.As(err, &adminErr) || adminErr.StatusCode != http.StatusUnauthorized ||
			!strings.Contains(err.Error(), "invalid_client")) {
			t.Fatalf("상한 안의 오류 본문 → 본문을 읽은 401 *AdminError 가 아니다: %T %v", err, err)
		}
	}
}

// (3) 결과 뒤 멈춘 서버를 기다리지 않는다 — create 201(1 MiB 를 알린 본문)의 머리만 받은 뒤 읽기 타임아웃 4 초의 절반 안에 id 를 돌려준다.
// 본문 64 KiB 가 와 있다 · 한 바이트도 없다, 평문과 TLS 1.3 각각, 갈래마다 rbStallRepeats 번. 호출자가 gzip 을 청하고 서버가 Content-Encoding:
// gzip 을 단 갈래도 같다 — 전송이 gzip 을 미리 풀기 시작하면 그 머리를 읽느라 기다린다(decodedGzip 은 첫 읽기에서 푼다). 수정 전: 평문 4,000–4,002 ms
// 에 *TransportError.
func TestAdminServerStalledAfterTheResult_isNotWaitedFor(t *testing.T) {
	serverTLS, pool := rbTLS(t)
	readTimeout := 4 * time.Second
	cases := []struct {
		name string
		tls  bool
		sent int
		gzip bool
	}{
		{"평문 · 본문 64 KiB 뒤 멈춤", false, 65536, false}, {"평문 · 본문 없이 멈춤", false, 0, false},
		{"TLS 1.3 · 본문 64 KiB 뒤 멈춤", true, 65536, false}, {"TLS 1.3 · 본문 없이 멈춤", true, 0, false},
		{"평문 · gzip 머리 뒤 본문 없이 멈춤", false, 0, true},
	}
	for _, c := range cases {
		for r := 1; r <= rbStallRepeats; r++ {
			var cfg *tls.Config
			var p *x509.CertPool
			if c.tls {
				cfg, p = serverTLS, pool
			}
			headers := rbLocation
			if c.gzip {
				headers += "Content-Encoding: gzip\r\n"
			}
			s := newRBServer(t, cfg, func(string, string) rbReply { return rbStalled("201 Created", headers, c.sent) })
			a := rbAdmin(t, s, p, readTimeout)
			if c.gzip {
				a.Raw().RestyClient().SetHeader("Accept-Encoding", "gzip")
			}
			start := time.Now()
			id, err := a.Users.Create(context.Background(), rbUserRep())
			elapsed := time.Since(start)
			t.Logf("[AdminResponseBody] %s #%d → id=%q err=%v · %d ms (읽기 타임아웃 4,000 ms)", c.name, r, id, err, elapsed.Milliseconds())
			if err != nil || id != "abc" {
				t.Fatalf("%s #%d: 결과를 돌려주지 않았다 — id=%q err=%v", c.name, r, id, err)
			}
			if elapsed >= readTimeout/2 {
				t.Fatalf("%s #%d: 멈춘 서버를 기다렸다 — %d ms", c.name, r, elapsed.Milliseconds())
			}
			_ = a.Close()
			s.close()
		}
	}
}

// 대조 — 연결을 끊는 것은 이 전송의 닫기다: resty 클라이언트의 전체 기한을 끄면(SetTimeout(0) — Raw() 로 닿는 손잡이) http.Client 가 본문을
// 닫으며 기한 컨텍스트를 취소하는 일이 없어(그 취소도 연결을 끊는다 — 기한이 있으면 이 전송의 닫기를 빼도 시험이 못 본다, 변이 실측) 끊는 것이
// 이 전송뿐이다. 그래도 쓰지 않는 2xx 본문과 상한을 넘은 오류 본문 앞에서 서버는 다 쓰지 못한다.
func TestAdminCutsWithoutAClientDeadline(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name  string
		reply rbReply
		call  func(*AdminClient) error
	}{
		{"create 201 + 64 MiB", rbPadded("201 Created", rbLocation, "", rbHuge), func(a *AdminClient) error {
			_, err := a.Users.Create(ctx, rbUserRep())
			return err
		}},
		{"get 404 + 64 MiB", rbPadded("404 Not Found", rbTyped, rbNotFound, rbHuge), func(a *AdminClient) error {
			if _, err := a.Users.Get(ctx, "x"); !errors.Is(err, ErrNotFound) {
				return errors.New("ErrNotFound 가 아니다")
			}
			return nil
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newRBServer(t, nil, func(string, string) rbReply { return c.reply })
			a := rbAdmin(t, s, nil, 20*time.Second)
			a.Raw().RestyClient().SetTimeout(0)
			err := c.call(a)
			finished := s.awaitReply()
			t.Logf("[AdminResponseBody] 기한 없음 · %s → err=%v · server wrote %d B finished=%v", c.name, err, s.written.Load(), finished)
			if err != nil {
				t.Fatalf("결과가 틀렸다: %v", err)
			}
			if !finished || s.written.Load() > rbWrittenBound {
				t.Fatalf("연결을 끊지 않았다 — server wrote %d B finished=%v", s.written.Load(), finished)
			}
		})
	}
}

// 대조 — 성공 본문에는 상한을 걸지 않는다(정당하게 크다): 상한을 넘는 사용자 목록도 통째로 결합된다.
func TestAdminSuccessBodyPastTheCap_isReadWhole(t *testing.T) {
	users := rbCap/len(rbUser) + 1000
	var b strings.Builder
	b.WriteString("[")
	for i := 0; i < users; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(rbUser)
	}
	b.WriteString("]")
	body := b.String()
	s := newRBServer(t, nil, func(string, string) rbReply { return rbExact("200 OK", rbTyped, body) })
	a := rbAdmin(t, s, nil, 20*time.Second)
	got, err := a.Users.Search(context.Background(), "u", 0, users)
	t.Logf("[AdminResponseBody] 사용자 %d 명(%d B) → %d 명 err=%v", users, len(body), len(got), err)
	if err != nil || len(got) != users || len(body) <= rbCap {
		t.Fatalf("성공 본문을 통째로 읽지 않았다 — %d 명 (기대 %d) err=%v", len(got), users, err)
	}
}

// 대조 — 끊긴 연결은 다시 쓰이지 않는다: 본문을 읽지 않은 create 다음의 get 은 새 연결에서 성공한다(연결 2).
func TestAdminACutConnection_isNotReused(t *testing.T) {
	s := newRBServer(t, nil, func(method, _ string) rbReply {
		if method == http.MethodPost {
			return rbPadded("201 Created", rbLocation, "", 16<<20)
		}
		return rbExact("200 OK", rbTyped, rbUser)
	})
	a := rbAdmin(t, s, nil, 20*time.Second)
	id, err := a.Users.Create(context.Background(), rbUserRep())
	if err != nil || id != "abc" {
		t.Fatalf("create: id=%q err=%v", id, err)
	}
	u, err := a.Users.Get(context.Background(), "x")
	if err != nil || u == nil || u.Username == nil || *u.Username != "alice" {
		t.Fatalf("get: %v %v", u, err)
	}
	t.Logf("[AdminResponseBody] 끊은 create 뒤 get → 연결 %d", s.conns.Load())
	if s.conns.Load() != 2 {
		t.Fatalf("끊긴 연결을 다시 썼거나 연결이 더 열렸다 — 연결 %d", s.conns.Load())
	}
}

// 대조 — resty 의 http.Client 에 거는 CloseIdleConnections(Raw() 소비자의 손잡이)는 이 전송을 지나 풀까지 닿는다 — 끼우기 전 wireScrubTransport
// 가 그랬듯이: 닫은 뒤의 요청은 새 연결로 나간다(연결 2). 끝까지 읽은 본문의 Read 는 연결이 풀에 돌아간 뒤에 돌아오므로 순서가 정해져 있다.
func TestAdminCloseIdleConnections_reachesThePool(t *testing.T) {
	s := newRBServer(t, nil, func(string, string) rbReply { return rbExact("200 OK", rbTyped, rbUser) })
	a := rbAdmin(t, s, nil, 20*time.Second)
	ctx := context.Background()
	if _, err := a.Users.Get(ctx, "x"); err != nil {
		t.Fatalf("get: %v", err)
	}
	a.Raw().RestyClient().GetClient().CloseIdleConnections()
	if _, err := a.Users.Get(ctx, "x"); err != nil {
		t.Fatalf("get: %v", err)
	}
	t.Logf("[AdminResponseBody] 유휴 연결을 닫은 뒤 get → 연결 %d", s.conns.Load())
	if s.conns.Load() != 2 {
		t.Fatalf("유휴 연결 닫기가 풀에 닿지 않았다 — 연결 %d", s.conns.Load())
	}
}

// 대조 — 끝까지 읽은 응답의 연결은 지금처럼 다시 쓰인다(create 201 빈 본문 · get · search · update 204 · delete 204 · 300 ms 늦은 get 이 연결 하나에서).
func TestAdminResponsesReadToTheirEnd_keepTheirConnection(t *testing.T) {
	s := newRBServer(t, nil, func(method, uri string) rbReply {
		switch {
		case method == http.MethodPost:
			return rbExact("201 Created", rbLocation, "")
		case method == http.MethodPut || method == http.MethodDelete:
			return rbExact("204 No Content", "", "")
		case strings.Contains(uri, "?"):
			return rbExact("200 OK", rbTyped, "["+rbUser+"]")
		case strings.HasSuffix(uri, "/late"):
			return func(c net.Conn, w *atomic.Int64) bool {
				time.Sleep(300 * time.Millisecond)
				return rbExact("200 OK", rbTyped, rbUser)(c, w)
			}
		default:
			return rbExact("200 OK", rbTyped, rbUser)
		}
	})
	a := rbAdmin(t, s, nil, 20*time.Second)
	ctx := context.Background()
	if id, err := a.Users.Create(ctx, rbUserRep()); err != nil || id != "abc" {
		t.Fatalf("create: %q %v", id, err)
	}
	if _, err := a.Users.Get(ctx, "x"); err != nil {
		t.Fatalf("get: %v", err)
	}
	if got, err := a.Users.Search(ctx, "u", 0, 10); err != nil || len(got) != 1 {
		t.Fatalf("search: %v %v", got, err)
	}
	if err := a.Users.Update(ctx, "x", rbUserRep()); err != nil {
		t.Fatalf("update: %v", err)
	}
	if err := a.Users.Delete(ctx, "x"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := a.Users.Get(ctx, "late"); err != nil {
		t.Fatalf("late get: %v", err)
	}
	t.Logf("[AdminResponseBody] 끝까지 읽은 응답 여섯 → 연결 %d", s.conns.Load())
	if s.conns.Load() != 1 {
		t.Fatalf("끝까지 읽은 응답의 연결을 다시 쓰지 않았다 — 연결 %d", s.conns.Load())
	}
}
