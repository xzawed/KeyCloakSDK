package keycloak

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Nerzal/gocloak/v13"
)

// admin 파사드가 받은 3xx 는 성공이 아니다(등록부 go-admin-3xx-read-as-success). Location 없는 3xx 는 net/http 가 따라가지 않아
// errOnRedirect 도 불리지 않고 답이 그대로 resty 에 닿는데, gocloak 의 오류 판정은 resty 의 IsError()(= 상태 > 399)뿐이고 resty 는
// 2xx 에만 결과를 결합한다 — 3xx 는 오류도 결과도 아니어서 빈 값과 nil 이 나왔다. 파사드 25 연산(다섯 리소스 × create · get ·
// list/search · update · delete — integration_test.go 의 admin 표면과 같은 25)이 300 · Location 없는 302 · 399 를 받으면 그 상태를
// 지닌 *AdminError(404 와 같은 부류 — toSDKError)이고 값은 영값이다. 본문은 그 호출의 성공 본문 모양의 JSON 이다 — 2xx 대조가
// 결합됨을 재므로 칸을 가르는 것은 상태뿐이다. 전송 · 결합 오류(*TransportError)는 칸의 실패로 센다.
//
// 수정 전(실측 2026-11-13, origin/main 3ff48b96 · Windows · go1.26.4 · 루프백): 상태마다 25 칸 중 1 칸 — Realms.Update(손으로 만든
// raw PUT 이 2xx 를 스스로 본다)만 *AdminError 였고 나머지 24 칸은 오류 없이 빈 값이었다: get 은 빈 구조체 포인터(`{}`), list · search 는
// nil 슬라이스, create 는 id "", update · delete 는 nil. 칸마다 요청은 하나였다. 수정 뒤 75 칸 모두 통과.

// a3xxOp 는 파사드 호출 하나다 — 이름은 통합 시험이 부르는 메서드다.
type a3xxOp struct {
	name   string // Resource.Method
	method string // 그 호출이 보내는 HTTP 메서드
	body   string // 그 호출의 성공 본문 모양 — get · create · update · delete 는 객체, list · search 는 배열
	bound  string // 2xx 대조에서 돌려준 값(JSON)이 담아야 하는 것 — 값을 돌려주지 않는 호출은 ""
	call   func(context.Context, *AdminClient) (any, error)
}

const (
	a3xxUser   = `{"id":"u-1","username":"alice","enabled":true}`
	a3xxClient = `{"id":"c-1","clientId":"app-1","enabled":true}`
	a3xxRealm  = `{"id":"re-1","realm":"re-1","enabled":true}`
	a3xxRole   = `{"id":"ro-1","name":"role-1"}`
	a3xxGroup  = `{"id":"g-1","name":"grp-1"}`
)

// a3xxOps 는 25 연산이다. create 의 대조 값 "abc" 는 rbLocation 의 마지막 경로 조각이다(gocloak 이 id 를 거기서 읽는다).
func a3xxOps() []a3xxOp {
	s := gocloak.StringP
	list := func(obj string) string { return "[" + obj + "]" }
	return []a3xxOp{
		{"Users.Create", http.MethodPost, a3xxUser, `"abc"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Users.Create(ctx, gocloak.User{Username: s("alice")})
		}},
		{"Users.Get", http.MethodGet, a3xxUser, `"u-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Users.Get(ctx, "u-1")
		}},
		{"Users.Search", http.MethodGet, list(a3xxUser), `"u-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Users.Search(ctx, "alice", 0, 10)
		}},
		{"Users.Update", http.MethodPut, a3xxUser, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Users.Update(ctx, "u-1", gocloak.User{FirstName: s("Bob")})
		}},
		{"Users.Delete", http.MethodDelete, a3xxUser, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Users.Delete(ctx, "u-1")
		}},
		{"Clients.Create", http.MethodPost, a3xxClient, `"abc"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Clients.Create(ctx, gocloak.Client{ClientID: s("app-1")})
		}},
		{"Clients.Get", http.MethodGet, a3xxClient, `"c-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Clients.Get(ctx, "c-1")
		}},
		{"Clients.FindByClientID", http.MethodGet, list(a3xxClient), `"c-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Clients.FindByClientID(ctx, "app-1")
		}},
		{"Clients.Update", http.MethodPut, a3xxClient, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Clients.Update(ctx, "c-1", gocloak.Client{Description: s("updated")})
		}},
		{"Clients.Delete", http.MethodDelete, a3xxClient, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Clients.Delete(ctx, "c-1")
		}},
		{"Realms.Create", http.MethodPost, a3xxRealm, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Realms.Create(ctx, gocloak.RealmRepresentation{Realm: s("re-1"), Enabled: gocloak.BoolP(true)})
		}},
		{"Realms.Get", http.MethodGet, a3xxRealm, `"re-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Realms.Get(ctx, "re-1")
		}},
		{"Realms.List", http.MethodGet, list(a3xxRealm), `"re-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Realms.List(ctx)
		}},
		{"Realms.Update", http.MethodPut, a3xxRealm, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Realms.Update(ctx, "re-1", gocloak.RealmRepresentation{DisplayName: s("updated")})
		}},
		{"Realms.Delete", http.MethodDelete, a3xxRealm, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Realms.Delete(ctx, "re-1")
		}},
		{"Roles.Create", http.MethodPost, a3xxRole, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Roles.Create(ctx, gocloak.Role{Name: s("role-1")})
		}},
		{"Roles.Get", http.MethodGet, a3xxRole, `"ro-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Roles.Get(ctx, "role-1")
		}},
		{"Roles.List", http.MethodGet, list(a3xxRole), `"ro-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Roles.List(ctx)
		}},
		{"Roles.Update", http.MethodPut, a3xxRole, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Roles.Update(ctx, "role-1", gocloak.Role{Description: s("updated")})
		}},
		{"Roles.Delete", http.MethodDelete, a3xxRole, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Roles.Delete(ctx, "role-1")
		}},
		{"Groups.Create", http.MethodPost, a3xxGroup, `"abc"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Groups.Create(ctx, gocloak.Group{Name: s("grp-1")})
		}},
		{"Groups.Get", http.MethodGet, a3xxGroup, `"g-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Groups.Get(ctx, "g-1")
		}},
		{"Groups.List", http.MethodGet, list(a3xxGroup), `"g-1"`, func(ctx context.Context, a *AdminClient) (any, error) {
			return a.Groups.List(ctx, 0, 10)
		}},
		{"Groups.Update", http.MethodPut, a3xxGroup, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Groups.Update(ctx, "g-1", gocloak.Group{Name: s("grp-2")})
		}},
		{"Groups.Delete", http.MethodDelete, a3xxGroup, "", func(ctx context.Context, a *AdminClient) (any, error) {
			return nil, a.Groups.Delete(ctx, "g-1")
		}},
	}
}

// a3xxRun 은 op 를 reply(요청 메서드 → 답)로 답하는 루프백 서버 앞에서 부른다 — 돌려준 값, 서버가 받은 요청(메서드 · 경로), 오류.
func a3xxRun(t *testing.T, op a3xxOp, reply func(method string) rbReply) (any, []string, error) {
	t.Helper()
	var mu sync.Mutex
	var seen []string
	s := newRBServer(t, nil, func(method, uri string) rbReply {
		mu.Lock()
		seen = append(seen, method+" "+uri)
		mu.Unlock()
		return reply(method)
	})
	a := rbAdmin(t, s, nil, 5*time.Second)
	v, err := op.call(context.Background(), a)
	mu.Lock()
	defer mu.Unlock()
	return v, append([]string(nil), seen...), err
}

// a3xxZero 는 v 가 그 형의 영값인지다 — nil 포인터 · nil 슬라이스 · "" · 값 없음.
func a3xxZero(v any) bool { return v == nil || reflect.ValueOf(v).IsZero() }

// a3xxShow 는 돌려준 값을 형과 JSON 으로 적는다 — 빈 *gocloak.User 는 `{}`, nil 은 `null`, 빈 id 는 `""`.
func a3xxShow(v any) string {
	if v == nil {
		return "값 없음"
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%T (%v)", v, err)
	}
	return fmt.Sprintf("%T %s", v, b)
}

func TestAdminLocationless3xx_isAnAdminErrorOnEveryFacadeCall(t *testing.T) {
	ops := a3xxOps()
	if len(ops) != 25 {
		t.Fatalf("연산 %d 개 — 통합 시험의 admin 표면은 25 다", len(ops))
	}
	for _, st := range []struct {
		code int
		line string
	}{{300, "300 Multiple Choices"}, {302, "302 Found"}, {399, "399 Unassigned"}} {
		t.Run(strconv.Itoa(st.code), func(t *testing.T) {
			passed := 0
			for _, op := range ops {
				ok := t.Run(op.name, func(t *testing.T) {
					// 머리는 rbTyped 뿐이다 — Location 이 없다.
					v, seen, err := a3xxRun(t, op, func(string) rbReply { return rbExact(st.line, rbTyped, op.body) })
					t.Logf("[Admin3xx] %d %s → %s · %s · %v · requests %q", st.code, op.name, a3xxShow(v), classKind(err), err, seen)
					var ae *AdminError
					if !errors.As(err, &ae) || ae.StatusCode != st.code {
						t.Errorf("HTTP %d 를 지닌 *AdminError 가 아니다 — %T %v", st.code, err, err)
					}
					if !a3xxZero(v) {
						t.Errorf("오류와 함께 영값이 아닌 값을 돌려줬다 — %s", a3xxShow(v))
					}
					if len(seen) != 1 || !strings.HasPrefix(seen[0], op.method+" ") {
						t.Errorf("요청이 %s 하나가 아니다 — %q", op.method, seen)
					}
				})
				if ok {
					passed++
				}
			}
			t.Logf("[Admin3xx] HTTP %d: %d/%d 칸 통과", st.code, passed, len(ops))
		})
	}
}

// 대조 — 같은 25 연산이 같은 본문을 2xx(create 는 201 + Location, 나머지는 200)로 받으면 성공하고, 값을 돌려주는 호출은 본문을
// 결합한다: 본문이 그 호출의 성공 모양이라는 증거다. 요청은 칸마다 하나다 — 25 연산 가운데 요청을 둘 이상 보내는 것은 없다.
func TestAdminLocationless3xxBodies_bindOn2xx(t *testing.T) {
	for _, op := range a3xxOps() {
		t.Run(op.name, func(t *testing.T) {
			v, seen, err := a3xxRun(t, op, func(method string) rbReply {
				if method == http.MethodPost {
					return rbExact("201 Created", rbLocation+rbTyped, op.body)
				}
				return rbExact("200 OK", rbTyped, op.body)
			})
			if err != nil {
				t.Fatalf("2xx 가 성공하지 않았다 — %T %v", err, err)
			}
			if b, _ := json.Marshal(v); op.bound != "" && !strings.Contains(string(b), op.bound) {
				t.Errorf("본문을 결합하지 않았다 — %s (기대: %s 를 담는다)", b, op.bound)
			}
			if len(seen) != 1 || !strings.HasPrefix(seen[0], op.method+" ") {
				t.Errorf("요청이 %s 하나가 아니다 — %q", op.method, seen)
			}
		})
	}
}

// 한 호출의 첫 3xx 를 뒤의 2xx 가 덮지 못한다 — 판정은 그 호출의 admin 요청들이 받은 첫 3xx 다(마지막 상태가 아니다). 25 연산은
// 저마다 요청이 하나이고(위 대조), 한 호출이 admin 요청을 둘 보내는 길은 소비자가 Raw() 로 resty 재시도를 켰을 때뿐이다. resty 의 기본
// 조건은 전송 · 본문 읽기 오류에만 다시 보내므로 첫 답은 본문이 끊긴 Location 없는 302, 다시 보낸 답은 사용자를 실은 200 이다 —
// 마지막 상태로 판정하면 이 호출은 그 사용자를 돌려준다(수정 전 실측: admin 요청 둘, 사용자와 nil).
func TestAdminFirst3xxOfACall_isNotHiddenByALaterSuccess(t *testing.T) {
	var n atomic.Int32
	s := newRBServer(t, nil, func(string, string) rbReply {
		if n.Add(1) == 1 {
			return func(c net.Conn, _ *atomic.Int64) bool {
				_, _ = io.WriteString(c, "HTTP/1.1 302 Found\r\n"+rbTyped+"Content-Length: 100\r\n\r\n"+`{"id"`)
				return false // 연결을 닫는다 — 알린 100 B 가 다 오지 않는다
			}
		}
		return rbExact("200 OK", rbTyped, a3xxUser)
	})
	a := rbAdmin(t, s, nil, 5*time.Second)
	a.Raw().RestyClient().SetRetryCount(1)
	u, err := a.Users.Get(context.Background(), "u-1")
	t.Logf("[Admin3xx] 끊긴 302 → 재시도 200 → %s · %s · %v · 요청 %d", a3xxShow(u), classKind(err), err, n.Load())
	if n.Load() != 2 {
		t.Fatalf("admin 요청이 둘이 아니다(%d) — 이 칸이 재려는 것이 성립하지 않는다", n.Load())
	}
	var ae *AdminError
	if !errors.As(err, &ae) || ae.StatusCode != http.StatusFound || u != nil {
		t.Fatalf("첫 3xx 가 뒤의 200 에 가려졌다 — %s · %T %v", a3xxShow(u), err, err)
	}
}

// 토큰 요청의 3xx 는 admin 호출의 3xx 가 아니다. SDK 자신의 공급자(client-credentials)는 만료된 토큰을 파사드 호출 안에서 다시
// 받는다(expires_in 1 초 < 시계 오차 30 초 — 받자마자 만료다). 그 토큰 요청은 판정 자리(call 의 슬롯)가 생기기 전에 끝나고 로그인은
// 제 슬롯을 쓰므로, 토큰 엔드포인트의 Location 없는 302 는 *AuthError 이고 admin 요청은 나가지 않는다(본문에 access_token 이 있어도 —
// gocloak 은 3xx 에 결과를 결합하지 않는다). 대조: 토큰이 200, admin 이 Location 없는 302 면 *AdminError{302} 다 — 기본 생성
// 경로(newAdminClient)의 칸이다(수정 전 실측: 첫 칸은 이미 *AuthError, 둘째 칸은 빈 *gocloak.User 와 nil).
func TestAdminTokenRequest3xx_isNotBlamedOnTheAdminCall(t *testing.T) {
	const token = `{"access_token":"tok","token_type":"Bearer","expires_in":1}`
	for _, tc := range []struct {
		name, tokenLine, adminLine, want string
		adminRequests                    int32
	}{
		{"토큰 302 · admin 200", "302 Found", "200 OK", "Auth", 0},
		{"토큰 200 · admin 302", "200 OK", "302 Found", "Admin(302)", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var inCall atomic.Bool
			var tokenHits, adminHits atomic.Int32
			s := newRBServer(t, nil, func(_, uri string) rbReply {
				if strings.HasSuffix(uri, "/protocol/openid-connect/token") {
					tokenHits.Add(1)
					if inCall.Load() {
						return rbExact(tc.tokenLine, rbTyped, token)
					}
					return rbExact("200 OK", rbTyped, token)
				}
				adminHits.Add(1)
				return rbExact(tc.adminLine, rbTyped, a3xxUser)
			})
			cfg := Config{ServerURL: s.url("http"), Realm: "r", ClientID: "app", ClientSecret: "cs-1"}.withDefaults()
			a, err := newAdminClient(context.Background(), cfg)
			if err != nil {
				t.Fatalf("200 토큰으로 만들지 못했다: %v", err)
			}
			t.Cleanup(func() { _ = a.Close() })
			inCall.Store(true)
			tokensBefore := tokenHits.Load()
			u, err := a.Users.Get(context.Background(), "u-1")
			t.Logf("[Admin3xx] %s → %s · %s · %v · 토큰 요청 %d · admin 요청 %d", tc.name, a3xxShow(u), classKind(err), err,
				tokenHits.Load()-tokensBefore, adminHits.Load())
			if got := classKind(err); got != tc.want {
				t.Errorf("%s 여야 하는데 %s — %v", tc.want, got, err)
			}
			if tokenHits.Load()-tokensBefore != 1 {
				t.Errorf("파사드 호출 안에서 토큰을 한 번 다시 받지 않았다 — %d 번", tokenHits.Load()-tokensBefore)
			}
			if adminHits.Load() != tc.adminRequests || u != nil {
				t.Errorf("admin 요청 %d 번(기대 %d) · 값 %s", adminHits.Load(), tc.adminRequests, a3xxShow(u))
			}
		})
	}
}
