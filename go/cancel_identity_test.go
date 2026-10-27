package keycloak

import (
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net"
	"net/url"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Nerzal/gocloak/v13"
)

// 소비자는 errors.Is(err, context.DeadlineExceeded) 로 「시간이 다 됐다」를 가른다 — cause.go 의 scrubCause 주석이 그것을 약속한다.
// 그 정체가 교환 **도중**(머리를 받은 뒤 본문을 읽다가)에 기한이 오면 사라졌다: x/oauth2 는 본문 읽기 오류를 %v 로
// (internal/token.go), gocloak 은 요청 오류 전부를 APIError.Message 문자열로(client.go checkForError) 납작하게 만든다.
// 2026-10-27 실측(본문 64 B 뒤 멈춘 IdP · 호출자 기한 300 ms 와 SDK 읽기 타임아웃 5 s): 그랜트 셋과 admin 자원 호출이 거짓,
// introspect·Validate 는 참. 요청 전에 이미 취소된 호출은 TestScrubKeepsBelowHTTPErrorIdentity 가 잰다.

// ciSilent 는 요청을 받고 아무것도 답하지 않는다 — 머리 전의 기다림.
func ciSilent() rbReply {
	return func(net.Conn, *atomic.Int64) bool {
		time.Sleep(20 * time.Second)
		return false
	}
}

// ciDeadline 은 기한 하나다 — 호출자의 것(ctx) 또는 SDK 의 읽기 타임아웃(Config.ReadTimeout).
type ciDeadline struct {
	name     string
	ctx      func() (context.Context, context.CancelFunc)
	readTOms int64
}

func ciDeadlines() []ciDeadline {
	return []ciDeadline{
		{"호출자 기한", func() (context.Context, context.CancelFunc) {
			return context.WithTimeout(context.Background(), 300*time.Millisecond)
		}, 5000},
		{"SDK 읽기 타임아웃", func() (context.Context, context.CancelFunc) {
			return context.WithCancel(context.Background())
		}, 300},
	}
}

// ciShape 는 IdP 가 멈추는 자리다. successBody 는 성공(2xx) 본문 안에서 멈추는 것 — admin 쓰기는 그것을 읽지 않으므로
// (adminbody.go) 그 칸을 건너뛴다. 오류 상태의 본문은 쓰기도 읽는다.
type ciShape struct {
	name        string
	successBody bool
	reply       rbReply
}

// ciRawStall 은 머리와 본문 앞부분을 그대로 쓰고 멈춘다 — Content-Length 아닌 틀(close 로 끝을 알림 · chunked)을 위해.
func ciRawStall(head string) rbReply {
	return func(c net.Conn, written *atomic.Int64) bool {
		n, err := io.WriteString(c, head)
		written.Add(int64(n))
		if err != nil {
			return false
		}
		time.Sleep(20 * time.Second)
		return false
	}
}

func ciShapes() []ciShape {
	body64 := `{"access_token":"x","token_type":"Bearer","expires_in":300,"x":"` // 64 B 를 채우는 앞부분
	for len(body64) < 64 {
		body64 += " "
	}
	return []ciShape{
		{"머리 전", false, ciSilent()},
		{"Content-Length 본문 64 B 뒤", true, rbStalled("200 OK", rbTyped, 64)},
		{"close 로 끝나는 본문 64 B 뒤", true,
			ciRawStall("HTTP/1.1 200 OK\r\n" + rbTyped + "Connection: close\r\n\r\n" + body64)},
		{"chunked 본문 64 B 뒤", true,
			ciRawStall("HTTP/1.1 200 OK\r\n" + rbTyped + "Transfer-Encoding: chunked\r\n\r\n80\r\n" + body64)},
		{"404 · 오류 본문 64 B 뒤", false, rbStalled("404 Not Found", rbTyped, 64)},
	}
}

// ciCheck 는 오류가 기한의 정체와 그 레인의 SDK 타입을 함께 지니는지, 그리고 호출이 기다리지 않았는지 본다.
func ciCheck(t *testing.T, what string, err error, wantType string, elapsed time.Duration) {
	t.Helper()
	if elapsed > 3*time.Second {
		t.Errorf("%s: %d ms 를 기다렸다 — 기한이 교환을 끝내지 못했다", what, elapsed.Milliseconds())
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("%s: errors.Is(err, context.DeadlineExceeded) 가 거짓이다 — %T: %v", what, err, err)
	}
	if ne := net.Error(nil); !errors.As(err, &ne) || !ne.Timeout() {
		t.Errorf("%s: errors.As(err, &net.Error) 와 Timeout() 이 참이어야 한다 — %T: %v", what, err, err)
	}
	if got := fmt.Sprintf("%T", err); got != wantType {
		t.Errorf("%s: %s 여야 하는데 %s 다", what, wantType, got)
	}
}

// TestDeadlineDuringTheExchange_keepsItsIdentity — 인증 레인 여섯(그랜트 셋 · admin 로그인 · introspect · logout). 타입은 레인의
// 계약 그대로다(README v1.2.3 노트 · causeWantKind — 그랜트는 *AuthError, 나머지는 *TransportError).
func TestDeadlineDuringTheExchange_keepsItsIdentity(t *testing.T) {
	want := map[string]string{
		callCC: "*keycloak.AuthError", callExchange: "*keycloak.AuthError", callRefresh: "*keycloak.AuthError",
		callAdmin: "*keycloak.TransportError", callIntrospect: "*keycloak.TransportError", callLogout: "*keycloak.TransportError",
	}
	for _, d := range ciDeadlines() {
		for _, sh := range ciShapes() {
			for _, call := range []string{callCC, callExchange, callRefresh, callAdmin, callIntrospect, callLogout} {
				t.Run(d.name+"/"+sh.name+"/"+call, func(t *testing.T) {
					t.Parallel()
					s := newRBServer(t, nil, func(string, string) rbReply { return sh.reply })
					c, err := New(Config{ServerURL: s.url("http"), Realm: "r", ClientID: "c", ClientSecret: "cs-in",
						ConnectTimeout: 5000, ReadTimeout: d.readTOms})
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(func() { _ = c.Close() })
					ctx, cancel := d.ctx()
					defer cancel()
					start := time.Now()
					err = causeRun(ctx, c, call)
					ciCheck(t, call, err, want[call], time.Since(start))
				})
			}
		}
	}
}

// ciAdminOp 는 admin 파사드 호출 하나다. 쓰기는 2xx 본문을 읽지 않으므로(adminbody.go) 본문 중간의 멈춤은 읽기에서만 잰다.
type ciAdminOp struct {
	name  string
	reads bool
	do    func(context.Context, *AdminClient) error
}

func ciAdminOps() []ciAdminOp {
	return []ciAdminOp{
		{"Users.Get", true, func(ctx context.Context, a *AdminClient) error { _, err := a.Users.Get(ctx, "abc"); return err }},
		{"Users.Search", true, func(ctx context.Context, a *AdminClient) error {
			_, err := a.Users.Search(ctx, "", 0, 10)
			return err
		}},
		{"Users.Create", false, func(ctx context.Context, a *AdminClient) error {
			_, err := a.Users.Create(ctx, rbUserRep())
			return err
		}},
		{"Users.Update", false, func(ctx context.Context, a *AdminClient) error { return a.Users.Update(ctx, "abc", rbUserRep()) }},
		{"Users.Delete", false, func(ctx context.Context, a *AdminClient) error { return a.Users.Delete(ctx, "abc") }},
	}
}

// TestAdminDeadlineDuringTheExchange_keepsItsIdentity — admin 자원 호출(토큰은 네트워크 없이 온다 — rbToken).
func TestAdminDeadlineDuringTheExchange_keepsItsIdentity(t *testing.T) {
	for _, d := range ciDeadlines() {
		for _, sh := range ciShapes() {
			for _, op := range ciAdminOps() {
				if sh.successBody && !op.reads {
					continue
				}
				t.Run(d.name+"/"+sh.name+"/"+op.name, func(t *testing.T) {
					t.Parallel()
					s := newRBServer(t, nil, func(string, string) rbReply { return sh.reply })
					a := rbAdmin(t, s, nil, time.Duration(d.readTOms)*time.Millisecond)
					ctx, cancel := d.ctx()
					defer cancel()
					start := time.Now()
					err := op.do(ctx, a)
					ciCheck(t, op.name, err, "*keycloak.TransportError", time.Since(start))
					// 원인은 기한의 오류를 gocloak 의 오류에 **붙인다** — 고치기 전처럼 *gocloak.APIError 에도 닿는다.
					var apiErr *gocloak.APIError
					if !errors.As(err, &apiErr) {
						t.Errorf("%s: errors.As(err, &*gocloak.APIError) 가 거짓이다 — 원인에서 gocloak 의 오류가 빠졌다: %v", op.name, err)
					}
				})
			}
		}
	}
}

// ciAfterDeadline 은 기한이 지났는데 Err() 가 아직 nil 인 ctx 다 — net/http 의 Client.Timeout 이 Request.Cancel 로 읽기를
// 끊은 찰나, ctx 의 타이머가 아직 표시하기 전과 같다(keep 의 주석). 표준 ctx 로는 만들 수 없어 직접 만든다.
type ciAfterDeadline struct{ context.Context }

func (ciAfterDeadline) Deadline() (time.Time, bool) { return time.Now().Add(-time.Millisecond), true }

// TestBelowHTTPSlot_keepsTheConditionThatEndedTheRead — keep 의 판정 넷을 경쟁 없이 잰다(통합 칸으로는 경쟁이라 190 칸 중
// 3 칸에서만 드러났다).
func TestBelowHTTPSlot_keepsTheConditionThatEndedTheRead(t *testing.T) {
	canceledText := errors.New("net/http: request canceled") // 정화 뒤에도 남는 net/http 의 맨 문자열 오류
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	for _, c := range []struct {
		name string
		ctx  context.Context
		err  error
		want error // nil 이면 남기지 않는다
	}{
		{"기한이 지났는데 Err() 가 아직 nil", ciAfterDeadline{context.Background()}, canceledText, context.DeadlineExceeded},
		{"취소된 ctx 는 ctx 의 오류", cancelled, canceledText, context.Canceled},
		{"살아 있는 ctx 의 belowHTTP 오류", context.Background(), io.ErrUnexpectedEOF, io.ErrUnexpectedEOF},
		{"살아 있는 ctx 의 정화된 글", context.Background(), canceledText, nil},
		{"정상 끝 io.EOF", cancelled, io.EOF, nil},
	} {
		var s belowHTTPSlot
		s.keep(c.ctx, c.err)
		got := s.lost(errors.New("flattened by the lower library"))
		if !errors.Is(got, c.want) || (c.want == nil) != (got == nil) {
			t.Errorf("%s: 남긴 것 %v, 바란 것 %v", c.name, got, c.want)
		}
	}
	var none *belowHTTPSlot // 칸 없는 요청(인증 레인의 introspect 따위)
	none.keep(cancelled, canceledText)
	if none.lost(canceledText) != nil {
		t.Error("칸 없는 요청이 무언가를 남겼다")
	}
}

// TestRefusedBeforeAnyResponse_keepsItsCause — 응답 전에 거부된 그랜트의 원인은 고치기 전 그대로 *url.Error 다(x/oauth2 가
// 그 오류를 납작하게 만들지 않으므로 칸은 끼어들지 않는다 — lost 의 errors.Is 검사).
func TestRefusedBeforeAnyResponse_keepsItsCause(t *testing.T) {
	down, err := New(Config{ServerURL: "http://127.0.0.1:1", Realm: "r", ClientID: "c", ClientSecret: "s"})
	if err != nil {
		t.Fatal(err)
	}
	for _, call := range []string{callCC, callExchange, callRefresh} {
		err := causeRun(context.Background(), down, call)
		var ae *AuthError
		if !errors.As(err, &ae) {
			t.Fatalf("%s: *keycloak.AuthError 여야 하는데 %T 다", call, err)
		}
		if _, ok := ae.Cause.(*url.Error); !ok {
			t.Errorf("%s: 원인이 *url.Error 여야 하는데 %T 다", call, ae.Cause)
		}
	}
}

// TestAdminCancelledBeforeTheRequest_keepsItsIdentity — 이미 취소된 ctx 로 부른 admin 자원 호출은 서버에 닿지 않고
// errors.Is(err, context.Canceled) 다(인증 레인의 같은 칸은 TestScrubKeepsBelowHTTPErrorIdentity).
func TestAdminCancelledBeforeTheRequest_keepsItsIdentity(t *testing.T) {
	for _, op := range ciAdminOps() {
		t.Run(op.name, func(t *testing.T) {
			s := newRBServer(t, nil, func(string, string) rbReply {
				t.Error("취소된 요청이 서버에 닿았다")
				return ciSilent()
			})
			a := rbAdmin(t, s, nil, 5*time.Second)
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			err := op.do(ctx, a)
			if !errors.Is(err, context.Canceled) {
				t.Errorf("%s: errors.Is(err, context.Canceled) 가 거짓이다 — %T: %v", op.name, err, err)
			}
			var te *TransportError
			if !errors.As(err, &te) {
				t.Errorf("%s: *keycloak.TransportError 여야 하는데 %T 다", op.name, err)
			}
		})
	}
}

// TestAdminFacadeClosures_takeTheCallCtx — 위 시험들은 Users 다섯 호출만 잰다. 다른 리소스의 메서드가 call/run 에 넘기는
// 클로저가 받은 ctx(칸이 실린 것) 대신 바깥 ctx 를 쓰면 정체를 조용히 잃는다. 그래서 call/run 의 클로저 전부가 매개변수를
// `ctx context.Context` 로 받는지 소스에서 잰다 — 그 이름이 바깥 ctx 를 가리므로 본문의 ctx 는 언제나 칸이 실린 것이다.
func TestAdminFacadeClosures_takeTheCallCtx(t *testing.T) {
	files, err := filepath.Glob("admin*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	seen := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(af, func(n ast.Node) bool {
			ce, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			id, ok := ce.Fun.(*ast.Ident)
			if !ok || (id.Name != "call" && id.Name != "run") || len(ce.Args) != 2 {
				return true
			}
			seen++
			lit, ok := ce.Args[1].(*ast.FuncLit)
			var params []*ast.Field
			if ok {
				params = lit.Type.Params.List
			}
			if !ok || len(params) != 1 || len(params[0].Names) != 1 || params[0].Names[0].Name != "ctx" {
				t.Errorf("%s: %s 의 클로저가 매개변수를 `ctx context.Context` 로 받지 않는다 — 칸이 실린 ctx 를 못 쓴다",
					fset.Position(ce.Pos()), id.Name)
			}
			return true
		})
	}
	// 공허 방지 — 다섯 리소스의 호출 자리(25)와 run 자신(1)보다 적게 세면 이 검사는 아무것도 안 본 것이다.
	if seen < 26 {
		t.Fatalf("call/run 호출을 %d 곳만 찾았다 — 파일 글롭이나 이름이 바뀌었나?", seen)
	}
}
