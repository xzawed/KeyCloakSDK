package keycloak

import (
	"context"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// gocloak 이 상태 없이(APIError Code 0) 보고한 실패라도 그 호출의 마지막 요청이 2xx 아닌 응답을 끝까지 받았으면, 그 응답의
// 상태를 지닌 *AdminError 다(등록부 python-admin-list-error-array-body 부류 재스캔의 go 칸 · admin-followable-redirect-class-
// divergent 의 go 칸). 로그인 레인(loginError)이 이미 긋는 선이다.
//
// (A) 오류 응답의 JSON 본문이 객체가 아니면 — 배열 · 문자열 · 수 · 참거짓, 또는 encoding/json 의 깊이 한도를 넘는 중첩 — 또는 필드
// 형이 맞지 않는 객체면 gocloak 의 SetError(&HTTPErrorResponse{}) 결합이 실패하고, resty 는 그 실패를 오류로 돌려주고, gocloak 은 그것을 Code 0 으로 접는다.
// (B) Location 이 있는 301 · 302 · 303 · 307 · 308 은 errOnRedirect 가 거부한다 — 따라가지 않는 것은 옳다 — 그 거부도 Code 0 이다.
// toSDKError 는 둘 다 *TransportError(상태 없음)로 읽었다. 같은 25 호출에서 rust · .NET · java · kotlin · python 은 둘 다 그
// 상태의 admin 오류다(실측 2026-11-14 — 부류 재스캔).
//
// 수정 전(실측 2026-11-14, origin/main ad16554d · Windows · go1.26.4 · 루프백): UNREAD_BEFORE

// uaTarget 은 리다이렉트 표적의 경로다 — 이 경로에 온 요청은 admin 요청으로 세지 않는다.
const uaTarget = "/redirected-target"

// uaShapes 는 오류 응답의 본문이다. object · null 은 대조다 — gocloak 이 결합한다(수정 전에도 옳았다).
var uaShapes = []struct{ name, body string }{
	{"object", `{"error":"x"}`},
	{"array", `[]`},
	{"string", `"boom"`},
	{"number", `42`},
	{"boolean", `true`},
	{"null", `null`},
	{"deep", strings.Repeat("[", 100000) + strings.Repeat("]", 100000)},
	{"mistyped", `{"error":5}`}, // 객체지만 gocloak 의 오류 구조체(문자열 필드)에 결합되지 않는다
}

// uaRun 은 op 를 route(서버 주소 · 메서드 · URI → 답)로 답하는 루프백 서버 앞에서 부른다 — 돌려준 값, admin 요청(메서드 · URI),
// 리다이렉트 표적이 받은 요청 수, 오류.
func uaRun(t *testing.T, op a3xxOp, route func(base, method, uri string) rbReply) (any, []string, int32, error) {
	t.Helper()
	var mu sync.Mutex
	var admin []string
	var target atomic.Int32
	var base atomic.Value
	base.Store("")
	s := newRBServer(t, nil, func(method, uri string) rbReply {
		if strings.HasPrefix(uri, uaTarget) {
			target.Add(1)
		} else {
			mu.Lock()
			admin = append(admin, method+" "+uri)
			mu.Unlock()
		}
		return route(base.Load().(string), method, uri)
	})
	base.Store(s.url("http"))
	a := rbAdmin(t, s, nil, 5*time.Second)
	v, err := op.call(context.Background(), a)
	mu.Lock()
	defer mu.Unlock()
	return v, append([]string(nil), admin...), target.Load(), err
}

// uaCheck 는 칸 하나의 단언이다 — 그 상태를 지닌 *AdminError(404 면 ErrNotFound 와도 맞는다) · 영값 · 그 동사의 admin 요청 하나.
func uaCheck(t *testing.T, op a3xxOp, code int, v any, admin []string, err error) {
	t.Helper()
	var ae *AdminError
	if !errors.As(err, &ae) || ae.StatusCode != code {
		t.Errorf("HTTP %d 를 지닌 *AdminError 가 아니다 — %s · %v", code, classKind(err), err)
	}
	if code == 404 && !errors.Is(err, ErrNotFound) {
		t.Errorf("errors.Is(err, ErrNotFound) 가 거짓이다 — %v", err)
	}
	if !a3xxZero(v) {
		t.Errorf("오류와 함께 영값이 아닌 값을 돌려줬다 — %s", a3xxShow(v))
	}
	if len(admin) != 1 || !strings.HasPrefix(admin[0], op.method+" ") {
		t.Errorf("admin 요청이 %s 하나가 아니다 — %q", op.method, admin)
	}
}

func TestAdminUnreadErrorBody_keepsItsStatusOnEveryFacadeCall(t *testing.T) {
	ops := a3xxOps()
	for _, st := range []struct {
		code int
		line string
	}{{404, "404 Not Found"}, {500, "500 Internal Server Error"}} {
		for _, sh := range uaShapes {
			t.Run(strconv.Itoa(st.code)+"/"+sh.name, func(t *testing.T) {
				passed := 0
				for _, op := range ops {
					ok := t.Run(op.name, func(t *testing.T) {
						v, admin, _, err := uaRun(t, op, func(string, string, string) rbReply {
							return rbExact(st.line, rbTyped, sh.body)
						})
						uaCheck(t, op, st.code, v, admin, err)
					})
					if ok {
						passed++
					}
				}
				t.Logf("[AdminUnread] HTTP %d %s: %d/%d 칸 통과", st.code, sh.name, passed, len(ops))
			})
		}
	}
}

// (B) 따라갈 수 있는 리다이렉트 — 표적은 그 호출의 성공 본문을 200 으로 준다. 따라가면 성공하거나 표적에 요청이 남는다.
func TestAdminRefusedRedirect_isAnAdminErrorWithItsStatus(t *testing.T) {
	ops := a3xxOps()
	for _, st := range []struct {
		code int
		line string
	}{
		{301, "301 Moved Permanently"}, {302, "302 Found"}, {303, "303 See Other"},
		{307, "307 Temporary Redirect"}, {308, "308 Permanent Redirect"},
	} {
		t.Run(strconv.Itoa(st.code), func(t *testing.T) {
			passed := 0
			for _, op := range ops {
				ok := t.Run(op.name, func(t *testing.T) {
					v, admin, target, err := uaRun(t, op, func(base, _, uri string) rbReply {
						if strings.HasPrefix(uri, uaTarget) {
							return rbExact("200 OK", rbTyped, op.body)
						}
						return rbExact(st.line, rbTyped+"Location: "+base+uaTarget+"\r\n", `{}`)
					})
					uaCheck(t, op, st.code, v, admin, err)
					if target != 0 {
						t.Errorf("리다이렉트를 따라갔다 — 표적 요청 %d", target)
					}
				})
				if ok {
					passed++
				}
			}
			t.Logf("[AdminUnread] 리다이렉트 %d: %d/%d 칸 통과", st.code, passed, len(ops))
		})
	}
}

// 대조 — 판정은 **끝까지 온 2xx 아닌** 응답의 몫이다. 알린 길이보다 먼저 연결이 닫힌 오류 응답은 받지 못한 응답이고, 2xx 의
// 본문을 결합하지 못한 실패는 이 레인의 규칙대로 둘 다 *TransportError 다(errors.go TransportError).
func TestAdminUnreadAnswer_needsANon2xxThatArrivedInFull(t *testing.T) {
	var get a3xxOp
	for _, op := range a3xxOps() {
		if op.name == "Users.Get" {
			get = op
		}
	}
	for _, tc := range []struct {
		name  string
		reply rbReply
	}{
		{"404 본문이 끊김", func(c net.Conn, _ *atomic.Int64) bool {
			_, _ = io.WriteString(c, "HTTP/1.1 404 Not Found\r\n"+rbTyped+"Content-Length: 100\r\n\r\n[")
			return false // 연결을 닫는다 — 알린 100 B 가 다 오지 않는다
		}},
		{"200 본문이 배열", rbExact("200 OK", rbTyped, `[]`)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v, admin, _, err := uaRun(t, get, func(string, string, string) rbReply { return tc.reply })
			var te *TransportError
			if !errors.As(err, &te) {
				t.Errorf("*TransportError 가 아니다 — %s · %v", classKind(err), err)
			}
			if !a3xxZero(v) || len(admin) != 1 {
				t.Errorf("값 %s · admin 요청 %q", a3xxShow(v), admin)
			}
		})
	}
}
