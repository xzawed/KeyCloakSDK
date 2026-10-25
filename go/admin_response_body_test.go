package keycloak

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
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
// 정한다. 2xx 중 admin 호출이 읽지 않는 것(201·204 · PUT·DELETE · 미디어 타입 없음)은 본문이 비어 보이고, 오류 상태(3xx 이상)의
// 본문은 tokenResponseMaxBytes 에서 끝난다. 그 밖의 성공 본문(목록 등)에는 상한이 없다. 토큰 요청은 tokencap.go 가 맡는다.
//
// 수정 전(실측 2026-10-25, Windows · go1.26.4 · 루프백 · main 0a4cfee — 등록부 admin-response-body-unbounded 의 재스캔): create 201 +
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

// rbWrite 는 머리를 쓰고 본문 head 뒤를 공백으로 채워 total 바이트를 쓴다(쓴 본문 바이트를 센다).
func rbWrite(c net.Conn, written *atomic.Int64, status, headers, head string, total int) error {
	if _, err := io.WriteString(c, "HTTP/1.1 "+status+"\r\n"+headers+"Content-Length: "+strconv.Itoa(total)+"\r\n\r\n"); err != nil {
		return err
	}
	n, err := io.WriteString(c, head)
	written.Add(int64(n))
	if err != nil {
		return err
	}
	for left := total - len(head); left > 0; {
		k := min(left, len(rbSlab))
		n, err := c.Write(rbSlab[:k])
		written.Add(int64(n))
		if err != nil {
			return err
		}
		left -= k
	}
	return nil
}

func rbPadded(status, headers, head string, total int) rbReply {
	return func(c net.Conn, written *atomic.Int64) bool {
		return rbWrite(c, written, status, headers, head, total) == nil
	}
}

func rbExact(status, headers, body string) rbReply {
	return rbPadded(status, headers, body, len(body))
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

// (1) admin 호출이 읽지 않는 2xx 본문은 읽지 않는다 — 호출은 결과를 돌려주고 서버는 64 MiB 를 다 쓰지 못한다. 자리마다 규칙 하나를
// 고정한다(201 · PUT · DELETE · 미디어 타입 없음). 수정 전: 여섯 자리 모두 끝까지.
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

// (2) 오류 본문은 상한까지만 쥔다 — 404 + 64 MiB 는 ErrNotFound 이고 서버는 다 쓰지 못하며 호출의 할당이 묶인다. 수정 전: 끝까지 읽었다.
func TestAdminErrorBody_isHeldOnlyUpToTheCap(t *testing.T) {
	s := newRBServer(t, nil, func(string, string) rbReply { return rbPadded("404 Not Found", rbTyped, rbNotFound, rbHuge) })
	a := rbAdmin(t, s, nil, 20*time.Second)
	var err error
	allocated := rbAllocated(func() { _, err = a.Users.Get(context.Background(), "x") })
	_ = a.Close()
	finished := s.awaitReply()
	t.Logf("[AdminResponseBody] get 404 + 64 MiB → err=%v · allocated %d B · server wrote %d B", err, allocated, s.written.Load())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("ErrNotFound 가 아니다: %v", err)
	}
	if !finished || s.written.Load() > rbWrittenBound {
		t.Fatalf("오류 본문의 나머지를 읽었다 — server wrote %d B finished=%v", s.written.Load(), finished)
	}
	if allocated > rbErrorAllocationBound {
		t.Fatalf("할당이 한도를 넘었다 — %d B (한도 %d)", allocated, rbErrorAllocationBound)
	}
}

// rbErrorAllocationBound 는 64 MiB 오류 본문 호출 하나의 할당 한도다. 근거(2026-10-25 실측, Windows · go1.26.4): 수정 전 165.5 MB(서버가
// 64 MiB 를 끝까지 썼다), 수정 뒤 2.3 MB(서버 1.64 MB) — 16 MiB(16.8 MB)는 수정 뒤보다 7 배, 수정 전보다 10 배 떨어진다.
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

// (3) 결과 뒤 멈춘 서버를 기다리지 않는다 — create 201(1 MiB 를 알린 본문)의 머리만 받은 뒤 읽기 타임아웃 4 초의 절반 안에 id 를 돌려준다.
// 본문 64 KiB 가 와 있다 · 한 바이트도 없다, 평문과 TLS 1.3 각각, 갈래마다 rbStallRepeats 번. 수정 전: 평문 4,001–4,002 ms 에 *TransportError.
func TestAdminServerStalledAfterTheResult_isNotWaitedFor(t *testing.T) {
	serverTLS, pool := rbTLS(t)
	readTimeout := 4 * time.Second
	cases := []struct {
		name string
		tls  bool
		sent int
	}{{"평문 · 본문 64 KiB 뒤 멈춤", false, 65536}, {"평문 · 본문 없이 멈춤", false, 0}, {"TLS 1.3 · 본문 64 KiB 뒤 멈춤", true, 65536}, {"TLS 1.3 · 본문 없이 멈춤", true, 0}}
	for _, c := range cases {
		for r := 1; r <= rbStallRepeats; r++ {
			var cfg *tls.Config
			var p *x509.CertPool
			if c.tls {
				cfg, p = serverTLS, pool
			}
			s := newRBServer(t, cfg, func(string, string) rbReply { return rbStalled("201 Created", rbLocation, c.sent) })
			a := rbAdmin(t, s, p, readTimeout)
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
