package keycloak

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/Nerzal/gocloak/v13"
)

// admin 쓰기의 본문을 JSON 이 충실히 싣지 못하면 **요청 전에** 거부한다 — 등록부 admin-unencodable-body-residuals.
//
//	(N) 비유한 수(NaN · +Inf · −Inf) 어디든 — encoding/json 이 오류를 내고, gocloak 이 그것을 자기 문구로 감싸
//	    *TransportError 가 `could not create user: json: unsupported value: NaN` 이었다.
//	(T) 올바른 UTF-8 이 아닌 문자열 어디든(값 · 맵 키 · 인터페이스 안) — encoding/json 은 오류 없이 바이트마다
//	    U+FFFD 로 바꿔 써 보낸다(조용한 변조).
//
// 문구는 아홉 언어 공통이고 *TransportError 다. 본문 검사가 토큰보다 먼저라 토큰 요청도 없다 — 가짜 서버가 모든 요청을
// 세고, 주입한 provider 가 Token 호출을 센다.
const wantUnencodableBody = "admin request failed: the request body could not be encoded as JSON"

// countingTokens 는 Token 호출을 센다 — 거부는 토큰을 묻기 전이어야 한다.
type countingTokens struct{ n atomic.Int32 }

func (c *countingTokens) Token(context.Context) (string, error) {
	c.n.Add(1)
	return "test-token", nil
}

// writeProbe 는 모든 요청을 세고 본문을 남기는 가짜 서버 위의 admin 클라이언트다(주입 생성자 — 하드닝은 기본 경로와
// 같다). POST 에는 201 과 Location, 그 밖에는 204 로 답한다. 생성자의 eager 인증이 부른 Token 은 세지 않는다.
type writeProbe struct {
	a      *AdminClient
	tokens *countingTokens
	hits   atomic.Int32
	mu     sync.Mutex
	bodies []string
}

func newWriteProbe(t *testing.T) *writeProbe {
	t.Helper()
	p := &writeProbe{tokens: &countingTokens{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.hits.Add(1)
		b, _ := io.ReadAll(r.Body)
		p.mu.Lock()
		p.bodies = append(p.bodies, string(b))
		p.mu.Unlock()
		if r.Method == http.MethodPost {
			// 고정 값 — gocloak 은 Location 의 마지막 조각만 id 로 읽는다(요청 입력을 되울리지 않는다: SonarCloud S5146).
			w.Header().Set("Location", "/admin/realms/r/created/new-id")
			w.WriteHeader(http.StatusCreated)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(srv.Close)
	a, err := NewAdminClient(context.Background(), Config{ServerURL: srv.URL, Realm: "r", ClientID: "c"}, p.tokens)
	if err != nil {
		t.Fatalf("NewAdminClient: %v", err)
	}
	t.Cleanup(func() { _ = a.Close() })
	p.a = a
	p.tokens.n.Store(0)
	return p
}

// adminWrite 는 쓰기 메서드 하나를 부른다 — 반환값은 오류만 본다.
type adminWrite struct {
	name string
	call func(context.Context, *AdminClient) error
}

func usersCreate(u gocloak.User) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { _, err := a.Users.Create(ctx, u); return err }
}

func usersUpdate(id string, u gocloak.User) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { return a.Users.Update(ctx, id, u) }
}

func clientsCreate(c gocloak.Client) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { _, err := a.Clients.Create(ctx, c); return err }
}

func clientsUpdate(id string, c gocloak.Client) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { return a.Clients.Update(ctx, id, c) }
}

func realmsCreate(r gocloak.RealmRepresentation) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { return a.Realms.Create(ctx, r) }
}

func realmsUpdate(name string, r gocloak.RealmRepresentation) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { return a.Realms.Update(ctx, name, r) }
}

func rolesCreate(r gocloak.Role) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { return a.Roles.Create(ctx, r) }
}

func rolesUpdate(name string, r gocloak.Role) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { return a.Roles.Update(ctx, name, r) }
}

func groupsCreate(g gocloak.Group) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { _, err := a.Groups.Create(ctx, g); return err }
}

func groupsUpdate(id string, g gocloak.Group) func(context.Context, *AdminClient) error {
	return func(ctx context.Context, a *AdminClient) error { return a.Groups.Update(ctx, id, g) }
}

// requireUnencodable 는 err 이 정확히 공통 문구의 *TransportError 이고(Error() 는 패키지 접두를 지킨다) 그 호출이 토큰도
// 요청도 내지 않았음을 단언한다.
func requireUnencodable(t *testing.T, p *writeProbe, err error) {
	t.Helper()
	var te *TransportError
	if !errors.As(err, &te) {
		t.Fatalf("want *TransportError, got %T: %v (requests %d, Token calls %d)", err, err, p.hits.Load(), p.tokens.n.Load())
	}
	if te.Msg != wantUnencodableBody {
		t.Fatalf("Msg = %q, want %q (requests %d, Token calls %d)", te.Msg, wantUnencodableBody, p.hits.Load(), p.tokens.n.Load())
	}
	if got, want := err.Error(), "keycloak: transport: "+wantUnencodableBody; got != want {
		t.Fatalf("Error() = %q, want %q", got, want)
	}
	if n := p.tokens.n.Load(); n != 0 {
		t.Fatalf("the body must be judged before the token is asked for — Token called %d time(s)", n)
	}
	if n := p.hits.Load(); n != 0 {
		t.Fatalf("no request may leave — the server saw %d", n)
	}
}

// (N) — 비유한 수. gocloak 표현에서 수를 실을 수 있는 자유 형식 자리는 User.DisableableCredentialTypes ·
// Client.Access · RealmRepresentation.Components 다(Role · Group 에는 수 자리가 없다). 세 값 × 쓰기 메서드 여섯 —
// Realms.Update 는 gocloak 을 거치지 않는 손 PUT 이다(admin_realms.go).
func TestAdminWriteRefusesANonFiniteNumberBeforeAnyRequest(t *testing.T) {
	for _, x := range []struct {
		name string
		v    float64
	}{{"NaN", math.NaN()}, {"+Inf", math.Inf(1)}, {"-Inf", math.Inf(-1)}} {
		for _, w := range []adminWrite{
			{"Users.Create", usersCreate(gocloak.User{DisableableCredentialTypes: &[]interface{}{"otp", x.v}})},
			{"Users.Update", usersUpdate("uid", gocloak.User{DisableableCredentialTypes: &[]interface{}{x.v}})},
			{"Clients.Create", clientsCreate(gocloak.Client{Access: &map[string]interface{}{"view": x.v}})},
			{"Clients.Update", clientsUpdate("cid", gocloak.Client{Access: &map[string]interface{}{"view": []interface{}{x.v}}})},
			{"Realms.Create", realmsCreate(gocloak.RealmRepresentation{Realm: gocloak.StringP("r2"),
				Components: map[string]interface{}{"k": x.v}})},
			{"Realms.Update", realmsUpdate("r", gocloak.RealmRepresentation{Components: x.v})},
		} {
			t.Run(w.name+"/"+x.name, func(t *testing.T) {
				p := newWriteProbe(t)
				requireUnencodable(t, p, w.call(context.Background(), p.a))
			})
		}
	}
}

// (T) — 올바른 UTF-8 이 아닌 문자열. 쓰기 메서드 열 모두, 자리를 바꿔 가며: 값 · 맵 키 · 맵 값 · 인터페이스 안 · 중첩
// 구조체 · 경로 인자가 본문에 주입되는 id(Users · Clients · Groups 의 Update 는 `X.ID = &id` 를 본문에 싣는다).
// "\xed\xa0\x80" 은 U+D800 의 UTF-8 꼴이다 — Go 문자열에는 홀로 선 서로게이트가 없고, 그 꼴은 잘못된 UTF-8 이라
// encoding/json 이 U+FFFD 셋으로 바꾼다(실측). 그래서 JVM · node · python 의 「홀로 선 서로게이트는 받는다」 대조군은
// Go 에 해당하지 않는다.
func TestAdminWriteRefusesTextThatIsNotUTF8BeforeAnyRequest(t *testing.T) {
	for _, w := range []adminWrite{
		{"Users.Create/value", usersCreate(gocloak.User{Username: gocloak.StringP("a\xffb")})},
		{"Users.Update/map-key", usersUpdate("uid", gocloak.User{Attributes: &map[string][]string{"k\xc3": {"v"}}})},
		{"Users.Update/injected-id", usersUpdate("u\xff", gocloak.User{})},
		{"Clients.Create/surrogate-utf8", clientsCreate(gocloak.Client{ClientID: gocloak.StringP("c\xed\xa0\x80")})},
		{"Clients.Update/in-interface", clientsUpdate("cid", gocloak.Client{Access: &map[string]interface{}{"k": []interface{}{"\x80"}}})},
		{"Clients.Update/injected-id", clientsUpdate("c\xfe", gocloak.Client{})},
		{"Realms.Create/value", realmsCreate(gocloak.RealmRepresentation{Realm: gocloak.StringP("r\xff")})},
		{"Realms.Update/in-interface", realmsUpdate("r", gocloak.RealmRepresentation{Components: map[string]interface{}{"k\xff": 1}})},
		{"Roles.Create/value", rolesCreate(gocloak.Role{Name: gocloak.StringP("role\xff")})},
		{"Roles.Update/map-value", rolesUpdate("role", gocloak.Role{Attributes: &map[string][]string{"k": {"\xfe"}}})},
		{"Groups.Create/value", groupsCreate(gocloak.Group{Name: gocloak.StringP("g\xff")})},
		{"Groups.Update/nested", groupsUpdate("gid", gocloak.Group{SubGroups: &[]gocloak.Group{{Name: gocloak.StringP("\xff")}}})},
		{"Groups.Update/injected-id", groupsUpdate("g\xff", gocloak.Group{})},
	} {
		t.Run(w.name, func(t *testing.T) {
			p := newWriteProbe(t)
			requireUnencodable(t, p, w.call(context.Background(), p.a))
		})
	}
}

// selfLoop 는 MarshalJSON 뒤에 순환을 숨긴다 — encoding/json 은 메서드를 부르고 끝나지만, 필드를 걷는 쪽은 그 순환을
// 만난다. 걷기가 끝나야 한다(포인터 · 맵 · 슬라이스는 한 번만 본다).
type selfLoop struct {
	Name string
	Next *selfLoop
	Kids map[string]any
	List []any
}

func (*selfLoop) MarshalJSON() ([]byte, error) { return []byte(`"loop"`), nil }

// failingMarshal 은 MarshalJSON 이 실패하는 소비자 타입이다 — encoding/json 은 *json.MarshalerError 로 감싼다.
type failingMarshal struct{}

func (failingMarshal) MarshalJSON() ([]byte, error) { return nil, errors.New("boom") }

// encodableBody 를 직접 — 자유 형식 자리(interface{})에 소비자가 무엇이든 넣을 수 있으므로 encoding/json 의 실패 전부와
// 걷기의 가장자리를 잰다.
func TestEncodableBodyRefusesWhatEncodingJSONRefusesWithItsErrorAsCause(t *testing.T) {
	cyclic := map[string]any{}
	cyclic["self"] = cyclic
	for _, c := range []struct {
		name  string
		body  any
		cause func(error) bool
	}{
		{"NaN", gocloak.User{DisableableCredentialTypes: &[]interface{}{math.NaN()}}, func(err error) bool {
			var e *json.UnsupportedValueError
			return errors.As(err, &e)
		}},
		{"cycle", gocloak.RealmRepresentation{Components: cyclic}, func(err error) bool {
			var e *json.UnsupportedValueError
			return errors.As(err, &e)
		}},
		{"channel", gocloak.RealmRepresentation{Components: make(chan int)}, func(err error) bool {
			var e *json.UnsupportedTypeError
			return errors.As(err, &e)
		}},
		{"failing-MarshalJSON", gocloak.RealmRepresentation{Components: failingMarshal{}}, func(err error) bool {
			var e *json.MarshalerError
			return errors.As(err, &e)
		}},
		// 타입 셋 밖 — encoding/json 은 잘못된 json.Number 를 평범한 오류로 거부한다(실측: *errors.errorString).
		{"invalid-json.Number", gocloak.RealmRepresentation{Components: json.Number("NaN")}, func(err error) bool {
			return err != nil && err.Error() == `json: invalid number literal "NaN"`
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			err := encodableBody(c.body)
			var te *TransportError
			if !errors.As(err, &te) || te.Msg != wantUnencodableBody {
				t.Fatalf("want *TransportError %q, got %T: %v", wantUnencodableBody, err, err)
			}
			if !c.cause(te.Cause) {
				t.Fatalf("the cause must be encoding/json's error, got %T: %v", te.Cause, te.Cause)
			}
		})
	}
}

func TestEncodableBodyJudgesTheStringsJSONWrites(t *testing.T) {
	type Embedded struct{ Note string }
	type withHidden struct {
		Shown  string
		hidden string
		Skip   string `json:"-"`
		Embedded
		Array [2]string
	}
	// 포인터 · 맵 · 슬라이스 순환 셋 — 모두 MarshalJSON 뒤라 encoding/json 은 만나지 않는다.
	loop := &selfLoop{Name: "ok"}
	loop.Next = loop
	loop.Kids = map[string]any{"back": loop}
	loop.Kids["self"] = loop.Kids
	loop.List = make([]any, 1)
	loop.List[0] = loop.List
	var nilUser *gocloak.User
	for _, c := range []struct {
		name string
		body any
		ok   bool
	}{
		// encoding/json 이 쓰지 않는 필드(비공개 · `json:"-"`)의 바이트는 나가지 않는다 — 받는다.
		{"unexported-and-dash-fields", withHidden{Shown: "ok", hidden: "\xff", Skip: "\xff"}, true},
		{"embedded-field", withHidden{Embedded: Embedded{Note: "\xff"}}, false},
		{"array-element", withHidden{Array: [2]string{"ok", "\xff"}}, false},
		{"cycle-behind-MarshalJSON", gocloak.RealmRepresentation{Components: loop}, true},
		{"cycle-behind-MarshalJSON-with-bad-text", gocloak.RealmRepresentation{Components: &selfLoop{Name: "\xff"}}, false},
		{"nil-pointer-map-slice-interface", gocloak.User{Attributes: nil, DisableableCredentialTypes: &[]interface{}{nil, nilUser}}, true},
		{"nil-body", nil, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			err := encodableBody(c.body)
			if c.ok && err != nil {
				t.Fatalf("want accepted, got %v", err)
			}
			var te *TransportError
			if !c.ok && (!errors.As(err, &te) || te.Msg != wantUnencodableBody || te.Cause != nil) {
				t.Fatalf("want *TransportError %q without a cause, got %T: %v", wantUnencodableBody, err, err)
			}
		})
	}
}

// 대조 — JSON 이 충실히 싣는 본문은 그대로 나간다: 유한한 수(0 · 음수 · 지수), U+FFFD 문자 자체, 아스트랄 문자, 제어
// 문자(encoding/json 이 \u0000 으로 이스케이프한다). 요청 하나 · Token 한 번이고, 서버가 받은 본문을 풀면 넣은 값이다.
func TestAdminWriteSendsABodyJSONCarriesFaithfully(t *testing.T) {
	text := "ok � \U0001F600 \x00 é"
	for _, w := range []adminWrite{
		{"Users.Create", usersCreate(gocloak.User{Username: gocloak.StringP(text),
			DisableableCredentialTypes: &[]interface{}{0.0, -1.5, 1e300}})},
		{"Users.Update", usersUpdate("uid", gocloak.User{Username: gocloak.StringP(text)})},
		{"Clients.Create", clientsCreate(gocloak.Client{ClientID: gocloak.StringP(text)})},
		{"Clients.Update", clientsUpdate("cid", gocloak.Client{ClientID: gocloak.StringP(text)})},
		{"Realms.Create", realmsCreate(gocloak.RealmRepresentation{Realm: gocloak.StringP(text)})},
		{"Realms.Update", realmsUpdate("r", gocloak.RealmRepresentation{Realm: gocloak.StringP(text)})},
		{"Roles.Create", rolesCreate(gocloak.Role{Name: gocloak.StringP(text)})},
		{"Roles.Update", rolesUpdate("role", gocloak.Role{Name: gocloak.StringP(text)})},
		{"Groups.Create", groupsCreate(gocloak.Group{Name: gocloak.StringP(text)})},
		{"Groups.Update", groupsUpdate("gid", gocloak.Group{Name: gocloak.StringP(text)})},
	} {
		t.Run(w.name, func(t *testing.T) {
			p := newWriteProbe(t)
			if err := w.call(context.Background(), p.a); err != nil {
				t.Fatalf("a body JSON carries must be sent: %v", err)
			}
			if p.hits.Load() != 1 || p.tokens.n.Load() != 1 {
				t.Fatalf("want 1 request and 1 Token call, got %d and %d", p.hits.Load(), p.tokens.n.Load())
			}
			var body map[string]any
			if err := json.Unmarshal([]byte(p.bodies[0]), &body); err != nil {
				t.Fatalf("the body is not JSON (%v): %q", err, p.bodies[0])
			}
			got := ""
			for _, k := range []string{"username", "clientId", "realm", "name"} {
				if s, ok := body[k].(string); ok {
					got = s
				}
			}
			if got != text {
				t.Fatalf("the body must carry the text as given: got %q, want %q", got, text)
			}
		})
	}
}
