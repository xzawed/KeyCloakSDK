package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// 적대 경로 행렬 — 분류표를 세우고, 적대 변형을 **메서드 손 목록이 아니라 계급에** 붙인다
// (등록부 `guard-detection-surface-hand-narrowed`).
//
// nonce·콜드캐시 백오프·토큰응답 타입검증 축은 `scripts/test/test-security-defaults.sh` 가 손으로 고른
// 자리에 앵커를 건다. 그래서 **새 공개 교환 경로**가 생기면 세 축 모두 그것을 모른다. 여기서는 경로를
// 손 목록이 아니라 파생한다:
//
//   - 선언 집합: facade_dump_test.go 의 뿌리(dumpRoots)·걷기(dumpWalker)가 닿는 이 패키지 타입마다
//     공개 메서드 전부(값·포인터 메서드 집합의 합 — 값 리시버 메서드는 둘 다에 있으니 한 번만 센다).
//   - 호출: 메서드마다 **새** 가짜 IdP 와 **새** 클라이언트를 만들어 리플렉션으로 부른다(캐시가 옆 행으로
//     새지 않게). 인자는 타입만 보고 합성한다.
//   - 분류: 그 호출이 IdP 에 실제로 보낸 요청으로 가른다(hpClassify).
//
// 단언:
//   (1) UNDETERMINED 가 없다(면제 표에 이유와 함께 있으면 통과, 낡은 면제는 실패).
//   (2) CODE_EXCHANGE·TOKEN_GRANT·JWKS_FETCH 가 각각 비어 있지 않다.
//   (W1) 손으로 고른 Go 테스트가 겨누는 메서드(hpHandTargets)가 전부 행이고, 기대 계급이고, 그 축의 파생
//        대상에 들어 있다. 표 자신도 손 목록이라 썩지 않게 셋과 대조한다 — 앵커 함수가 정말 그 이름을 부르는가,
//        causeRun 이 부르는 공개 이름이 전부 표에 있는가, 보안 기본값 가드의 Go 행위 앵커가 전부 표의 앵커인가.
//   (W3a) TOKEN_GRANT·CODE_EXCHANGE 행마다 형식이 틀린 토큰 응답 변형 — 변형 집합은 새로 만들지 않고 기존
//        테스트에서 가져온다(hpTokenVariants). 칸마다: 패닉 없음 · 오류 · 그 오류가 SDK 오류 타입 · 응답의
//        카나리아가 오류 렌더링 어디에도 없음 · 적대 토큰 엔드포인트에 닿음(≥ 1, 그러나 대조보다 많지 않음 —
//        틀린 응답이 재시도를 부르지 않는다) · 그 응답 **뒤로** 요청이 없음.
//        ⚠️ 행마다 정상 응답 대조를 먼저 돈다 — admin 자원 메서드는 정상 응답에도 404 로 실패하므로 그 행에서
//        「오류다」는 공허하고, 무게는 「토큰 뒤로 안 나아갔다」가 진다. 대조가 둘 다 못 가르면 행이 실패한다.
//   (W3b) CODE_EXCHANGE 행 중 **서명에 nonce 파라미터가 있는** 것(go/parser 로 파생)마다 nonce 가 다른
//        id_token · 다른 키로 서명한 id_token(같은 kid·다른 kid) · id_token 없음. 대조(맞는 id_token)는 성공해야
//        하고, id_token 이 있는 변형은 검증기까지 가야 한다(콜드 캐시 JWKS 조회 ≥ 1). nonce 클레임 없음은 측정만.
//        nonce 파라미터가 없어 빠지는 CODE_EXCHANGE 행은 hpNonceDropExempt 에 이유가 있어야 한다(조용히 빠지지 않게).
//   (W3c) 분류 실행에서 JWKS 를 조회한 행마다 콜드 캐시 + /certs 503 에서 k 회 호출 — 전부 실패하고
//        1 ≤ /certs 요청 ≤ k−1(하한은 콜드 경로에 닿았다는 증명, 상한은 백오프). 시간이 아니라 요청 수만 잰다.
// 실패한 칸은 hpKnownGaps 에 이유와 함께 있으면 GAP 으로 찍히고, 관측되지 않는 항목은 낡은 것이라 실패한다.
//
// 걷기는 이 패키지의 구조체·포인터만 찍는다 — 비구조체 정의 타입(`type Realm string`)의 메서드는 필드로
// 닿아도 걷기에 안 걸린다(Grok 레그, 실측). 그래서 소스에 선언된 공개 메서드 전수(hpSourceMethods)와 합치고,
// 걷기에 안 닿아 수신자가 없는 메서드는 UNDETERMINED 로 둔다 — 면제 표에 이유가 없으면 (1) 이 실패한다.
//
// ⚠️ 한계(Grok 레그 실측 — 전부 NONE 으로 읽힌다): 기록된 요청도 오류도 없이 끝나는 교환 경로. 합성 인자
// (영값·false)나 가짜 IdP 설정이 비운 필드가 요청 앞에서 갈라 세우는 것, 비동기로 나가는 요청(표는 반환 직후
// 찍힌다), 이 IdP 가 아닌 호스트로 나가 오류를 버리는 것. 토큰 엔드포인트에 JSON 본문으로 보낸 코드 교환은
// grant 를 못 읽어 TOKEN_GRANT 로 읽힌다(교환 계급 안이고, RFC 6749 §4.1.3 상 폼이 아니면 요청 자체가 틀렸다).

const (
	hpCodeExchange = "CODE_EXCHANGE"
	hpTokenGrant   = "TOKEN_GRANT"
	hpJWKSFetch    = "JWKS_FETCH"
	hpOther        = "OTHER"
	hpNone         = "NONE"
	hpUndetermined = "UNDETERMINED"
)

// UNDETERMINED 여도 되는 메서드와 그 이유("(*T).M" / "T.M"). **이유 없는 면제는 넣지 않는다.**
// 선언 집합에 없거나 더는 UNDETERMINED 가 아닌 항목은 낡은 면제로 실패한다.
var hpUndeterminedExempt = map[string]string{
	"wireScrubTransport.RoundTrip": "SDK 전송층(cause.go) — 모든 요청이 이미 이것을 지나며 그 요청은 부른 메서드의 행에 잡힌다. " +
		"소비자에게 건네는 값이 아니다(facade_dump_test.go 의 걷기 면제와 같은 이유)",
	"wireScrubTransport.CloseIdleConnections": "전송층의 유휴 커넥션 정리 — 요청을 내지 않는다(cause.go)",
	"wireScrubBody.Read":                      "응답 본문 래퍼 — 이미 받은 본문을 읽을 뿐 요청을 내지 않는다(cause.go)",
}

const (
	hpBase = "/realms/r/protocol/openid-connect"
	// 분류는 realm 과 무관하게 **꼬리**로 본다 — 인자로 받은 realm 의 엔드포인트도 교환이다(Grok 레그, 실측:
	// 정확한 경로로 가르면 `/realms/{U}/…/certs` 가 OTHER 로 읽혔다).
	hpTokenSuffix = "/protocol/openid-connect/token"
	hpCertsSuffix = "/protocol/openid-connect/certs"
)

type hpReq struct{ method, path, grant string }

// 기록하는 가짜 IdP — 모든 요청을 (메서드, 경로, 토큰 요청이면 grant_type) 로 남긴다. 기록은 라우팅
// **앞**에서 하므로 라우트가 없는 경로(admin 404 포함)도 남는다: 분류는 SDK 가 무엇을 **시도했나**를 본다.
type hpIdP struct {
	srv *httptest.Server
	// universal 은 모든 string 인자에 넣는 값이다. ⚠️ 평문("R2-universal")이면 토큰을 받는 메서드
	// (Validate 둘)가 JWS 파싱에서 요청 없이 실패해 UNDETERMINED 가 되고 JWKS_FETCH 가 빈다 — 그래서
	// 이 IdP 키로 서명한 **유효한 JWS** 다. 문자열 자리 어디에 들어가도 URL·폼에 안전한 문자만 쓴다.
	universal string
	idToken   string // 토큰 응답의 id_token — nonce 가 universal 이라 ExchangeCode 의 nonce 검증까지 통과한다

	mu   sync.Mutex
	reqs []hpReq
	// tokenResp 가 nil 이 아니면 토큰 엔드포인트가 정상 응답 대신 이것을 낸다(W3 변형 — 수신자를 정상 응답으로
	// 만든 **뒤에** 건다). certsDown 이면 JWKS 가 503 이다.
	tokenResp *hostileResp
	certsDown bool
}

func newHPIdP(t *testing.T, key *rsa.PrivateKey) *hpIdP {
	t.Helper()
	idp := &hpIdP{}
	mux := http.NewServeMux()
	mux.HandleFunc(hpBase+"/token", func(w http.ResponseWriter, _ *http.Request) {
		idp.mu.Lock()
		override := idp.tokenResp
		idp.mu.Unlock()
		if override != nil {
			causeServe(w, *override)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		// expires_in 을 기본 skew(30s) 보다 짧게 준다 — provider 캐시가 늘 식어 있어, 부여에 **닿을 수 있는**
		// 메서드는 실제로 닿는다(admin 메서드가 생성 때 데운 토큰에 가려 OTHER 로 읽히지 않게).
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "hp-access", "token_type": "Bearer", "expires_in": 1,
			"refresh_token": "hp-refresh", "id_token": idp.idToken, "scope": "openid",
		})
	})
	mux.HandleFunc(hpBase+"/token/introspect", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"active":true,"username":"svc","client_id":"c","sub":"u1"}`))
	})
	mux.HandleFunc(hpBase+"/certs", func(w http.ResponseWriter, _ *http.Request) {
		idp.mu.Lock()
		down := idp.certsDown
		idp.mu.Unlock()
		if down {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_ = json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
			{Key: &key.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"},
		}})
	})
	mux.HandleFunc(hpBase+"/logout", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	idp.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rq := hpReq{method: r.Method, path: r.URL.Path}
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, hpTokenSuffix) {
			_ = r.ParseForm()
			rq.grant = r.Form.Get("grant_type")
		}
		idp.mu.Lock()
		idp.reqs = append(idp.reqs, rq)
		idp.mu.Unlock()
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(idp.srv.Close)
	idp.universal = hpSign(t, key, idp.iss(), nil)
	idp.idToken = hpSign(t, key, idp.iss(), map[string]any{"nonce": idp.universal})
	return idp
}

func (p *hpIdP) iss() string { return p.srv.URL + "/realms/r" }

func (p *hpIdP) cfg() Config {
	return Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "hp-client-secret"}
}

func (p *hpIdP) reset() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.reqs = nil
}

func (p *hpIdP) setTokenResp(r *hostileResp) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.tokenResp = r
}

func (p *hpIdP) setCertsDown(down bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.certsDown = down
}

func (p *hpIdP) snapshot() []hpReq {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]hpReq(nil), p.reqs...)
}

func hpSign(t *testing.T, key *rsa.PrivateKey, iss string, extra map[string]any) string {
	t.Helper()
	return hpSignKid(t, key, "k1", iss, extra)
}

func hpSignKid(t *testing.T, key *rsa.PrivateKey, kid, iss string, extra map[string]any) string {
	t.Helper()
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid))
	if err != nil {
		t.Fatal(err)
	}
	b := jwt.Signed(sig).Claims(jwt.Claims{
		Issuer: iss, Subject: "u1", Audience: jwt.Audience{"c"},
		Expiry: jwt.NewNumericDate(time.Now().Add(5 * time.Minute)), IssuedAt: jwt.NewNumericDate(time.Now()),
	})
	if extra != nil {
		b = b.Claims(extra)
	}
	raw, err := b.Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// 수신자를 얻는 공개 API 뿌리 — **덜 데운 것부터**. 타입은 자기를 처음 닿게 하는 빌더의 새 인스턴스에서
// 불린다(Client.Admin 은 admin 이 아직 없는 New 에서). 어느 빌더에도 안 닿는 타입(값 타입·오류 타입)은
// 영값 수신자로 부른다 — 상태가 필요한 새 타입이면 그 호출이 패닉·오류를 내 UNDETERMINED 로 드러난다.
var hpBuilders = []struct {
	name  string
	build func(t *testing.T, cfg Config) any
}{
	{"New", func(t *testing.T, cfg Config) any { return hpNew(t, cfg) }},
	{"New+Admin", func(t *testing.T, cfg Config) any {
		c := hpNew(t, cfg)
		if _, err := c.Admin(context.Background()); err != nil {
			t.Fatalf("admin 뿌리를 못 만들었다: %v", err)
		}
		return c
	}},
}

func hpNew(t *testing.T, cfg Config) *Client {
	t.Helper()
	c, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// 같은 걷기(dumpWalker)로 값을 모은다 — 카나리아 없이(누출 단언은 facade_dump_test.go 의 몫이다).
func hpWalk(t *testing.T, roots map[string]any) map[string]reflect.Value {
	t.Helper()
	w := &dumpWalker{t: t, seen: map[uintptr]bool{}, types: map[string]bool{}, found: map[string]reflect.Value{}}
	names := make([]string, 0, len(roots))
	for n := range roots {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		w.visit(reflect.ValueOf(roots[n]), n)
	}
	return w.found
}

type hpMethod struct {
	typ     reflect.Type // 이름 있는 기저 타입(포인터 아님)
	name    string
	byValue bool // 값 리시버 — 값·포인터 메서드 집합 둘 다에 있다
}

func (m hpMethod) label() string {
	if m.byValue {
		return m.typ.Name() + "." + m.name
	}
	return "(*" + m.typ.Name() + ")." + m.name
}

// 선언 집합 — facade_dump_test.go 의 뿌리에서 걷기가 닿는 타입마다 포인터 메서드 집합(값 메서드 집합을 포함한다).
func hpDeclared(t *testing.T) []hpMethod {
	t.Helper()
	roots, _ := dumpRoots(t)
	byName := map[string]any{}
	for i, r := range roots {
		byName[fmt.Sprintf("%02d-%s", i, r.name)] = r.v
	}
	var out []hpMethod
	for _, v := range hpWalk(t, byName) {
		typ := v.Type()
		if typ.Kind() == reflect.Pointer {
			typ = typ.Elem()
		}
		pt := reflect.PointerTo(typ)
		for i := 0; i < pt.NumMethod(); i++ {
			name := pt.Method(i).Name
			_, byValue := typ.MethodByName(name)
			out = append(out, hpMethod{typ: typ, name: name, byValue: byValue})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if a, b := out[i].typ.Name(), out[j].typ.Name(); a != b {
			return a < b
		}
		return out[i].name < out[j].name
	})
	return out
}

// 소스(비테스트)에 선언된 공개 메서드 전수 — 라벨은 hpMethod.label 과 같은 모양이다. 걷기와 달리 수신자
// 타입의 종류(구조체·비구조체)를 가리지 않는다.
func hpSourceMethods(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	var out []string
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		for _, d := range af.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv != nil && fd.Name.IsExported() {
				out = append(out, hpRecvLabel(fd.Recv.List[0].Type)+"."+fd.Name.Name)
			}
		}
	}
	sort.Strings(out)
	return out
}

func hpRecvLabel(e ast.Expr) string {
	switch x := e.(type) {
	case *ast.StarExpr:
		return "(*" + hpRecvLabel(x.X) + ")"
	case *ast.IndexExpr: // 제네릭 수신자 T[K]
		return hpRecvLabel(x.X)
	case *ast.IndexListExpr:
		return hpRecvLabel(x.X)
	case *ast.Ident:
		return x.Name
	}
	return fmt.Sprintf("%T", e)
}

var (
	hpCtxType = reflect.TypeOf((*context.Context)(nil)).Elem()
	hpErrType = reflect.TypeOf((*error)(nil)).Elem()
)

// 인자 합성 — 타입만 본다. 포인터는 nil 이 아니라 영값을 가리키는 포인터다(nil 은 거의 항상 패닉이다).
func hpArg(t reflect.Type, universal string) reflect.Value {
	if t == hpCtxType {
		return reflect.ValueOf(context.Background())
	}
	switch t.Kind() {
	case reflect.String:
		return reflect.ValueOf(universal).Convert(t)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return reflect.ValueOf(int64(1)).Convert(t)
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return reflect.ValueOf(uint64(1)).Convert(t)
	case reflect.Float32, reflect.Float64:
		return reflect.ValueOf(float64(1)).Convert(t)
	case reflect.Bool:
		return reflect.ValueOf(false).Convert(t)
	case reflect.Pointer:
		return reflect.New(t.Elem())
	}
	return reflect.Zero(t) // struct·slice·map·interface·func·chan
}

func hpCall(recv reflect.Value, name, universal string) (panicked any, callErr error) {
	return hpInvoke(recv, name, hpArgs(universal, nil))
}

// hpArgs 는 hpArg 와 같되 blank 에 든 위치(0 부터, 수신자 제외)는 영값이다 — W3a 가 nonce 파라미터를 비워
// id_token 검증을 끄는 데 쓴다(아래 hpTokenVariants 의 공허 함정).
func hpArgs(universal string, blank map[int]bool) func(int, reflect.Type) reflect.Value {
	return func(i int, t reflect.Type) reflect.Value {
		if blank[i] {
			return reflect.Zero(t)
		}
		return hpArg(t, universal)
	}
}

func hpInvoke(recv reflect.Value, name string, arg func(int, reflect.Type) reflect.Value) (panicked any, callErr error) {
	m := recv.MethodByName(name)
	mt := m.Type()
	args := make([]reflect.Value, mt.NumIn())
	for i := range args {
		args[i] = arg(i, mt.In(i))
	}
	defer func() {
		if r := recover(); r != nil {
			panicked = r
		}
	}()
	var outs []reflect.Value
	if mt.IsVariadic() {
		outs = m.CallSlice(args)
	} else {
		outs = m.Call(args)
	}
	for _, o := range outs {
		if !o.Type().Implements(hpErrType) {
			continue
		}
		switch o.Kind() {
		case reflect.Interface, reflect.Pointer, reflect.Map, reflect.Slice, reflect.Func, reflect.Chan:
			if o.IsNil() {
				continue
			}
		}
		callErr = o.Interface().(error)
	}
	return panicked, callErr
}

// 요청으로 가른다. 앞 줄이 이긴다: 코드 교환 > 토큰 부여 > JWKS 조회 > 그 밖의 요청 > 요청 없음.
// ⚠️ 토큰 엔드포인트 POST 는 grant_type 이 무엇이든(오늘은 client_credentials·refresh_token) TOKEN_GRANT 다 —
// 새 grant(password·token-exchange…)가 OTHER 로 새지 않게. grant 는 표의 요청 열에 그대로 찍힌다.
func hpClassify(reqs []hpReq, failed bool) string {
	has := func(pred func(hpReq) bool) bool {
		for _, r := range reqs {
			if pred(r) {
				return true
			}
		}
		return false
	}
	isToken := func(r hpReq) bool { return r.method == http.MethodPost && strings.HasSuffix(r.path, hpTokenSuffix) }
	switch {
	case has(func(r hpReq) bool { return isToken(r) && r.grant == "authorization_code" }):
		return hpCodeExchange
	case has(isToken):
		return hpTokenGrant
	case has(func(r hpReq) bool { return r.method == http.MethodGet && strings.HasSuffix(r.path, hpCertsSuffix) }):
		return hpJWKSFetch
	case len(reqs) > 0:
		return hpOther
	case failed:
		return hpUndetermined
	}
	return hpNone
}

func hpFormat(reqs []hpReq, universal string) string {
	if len(reqs) == 0 {
		return "-"
	}
	var order []string
	count := map[string]int{}
	for _, r := range reqs {
		p := strings.TrimPrefix(r.path, hpBase)
		if universal != "" { // 빈 needle 의 ReplaceAll 은 글자마다 끼워 넣는다
			p = strings.ReplaceAll(p, universal, "{U}")
		}
		k := r.method + " " + p
		if r.grant != "" {
			k += "[" + r.grant + "]"
		}
		if count[k] == 0 {
			order = append(order, k)
		}
		count[k]++
	}
	for i, k := range order {
		if count[k] > 1 {
			order[i] = fmt.Sprintf("%s ×%d", k, count[k])
		}
	}
	return strings.Join(order, ", ")
}

type hpRow struct {
	label, class, reqs, recv, outcome, note string
	sent                                    []hpReq // 분류 실행이 보낸 요청 그대로 — W3c 대상 파생에 쓴다
}

// 타입마다 처음 닿게 하는 빌더 — 버리는 IdP 위에서 빌더마다 한 번씩 걸어 정한다.
func hpProbeBuilders(t *testing.T, key *rsa.PrivateKey) map[string]int {
	t.Helper()
	builderOf := map[string]int{}
	for i, b := range hpBuilders {
		for name := range hpWalk(t, map[string]any{b.name: b.build(t, newHPIdP(t, key).cfg())}) {
			if _, ok := builderOf[name]; !ok {
				builderOf[name] = i
			}
		}
	}
	return builderOf
}

// 이 IdP 위에 새로 만든 뿌리에서 수신자를 꺼낸다. 어느 빌더에도 안 닿는 타입은 영값 수신자다.
func hpReceiver(t *testing.T, idp *hpIdP, m hpMethod, builderOf map[string]int) (reflect.Value, string) {
	t.Helper()
	i, ok := builderOf[m.typ.Name()]
	if !ok {
		return reflect.New(m.typ), "zero"
	}
	b := hpBuilders[i]
	v, found := hpWalk(t, map[string]any{b.name: b.build(t, idp.cfg())})[m.typ.Name()]
	if !found {
		t.Fatalf("%s: 빌더 %s 가 탐침 때는 닿았는데 지금은 안 닿는다", m.label(), b.name)
	}
	if v.Kind() == reflect.Struct {
		v = v.Addr()
	}
	return v, b.name
}

func hpRun(t *testing.T, key *rsa.PrivateKey, m hpMethod, builderOf map[string]int) hpRow {
	t.Helper()
	idp := newHPIdP(t, key)
	recv, src := hpReceiver(t, idp, m, builderOf)
	idp.reset() // 뿌리를 만들며 나간 요청(admin 로그인 등)은 이 메서드의 몫이 아니다
	panicked, callErr := hpCall(recv, m.name, idp.universal)
	reqs := idp.snapshot()
	row := hpRow{label: m.label(), class: hpClassify(reqs, panicked != nil || callErr != nil),
		reqs: hpFormat(reqs, idp.universal), recv: src, outcome: "ok", sent: reqs}
	switch {
	case panicked != nil:
		row.outcome, row.note = "panic", fmt.Sprintf(" · panic: %v", panicked)
	case callErr != nil:
		row.outcome, row.note = "err", " · err: "+callErr.Error()
	}
	if row.class != hpUndetermined {
		row.note = "" // 사유는 분류를 못 한 행에만 — 요청을 낸 행의 오류(admin 404 등)는 분류와 무관하다
	}
	return row
}

// 소스에는 있는데 걷기가 안 닿아 부르지 못한 공개 메서드 — 분류할 수 없으니 UNDETERMINED 행이다.
func hpUnreachedRows(t *testing.T, byLabel map[string]hpRow) []hpRow {
	t.Helper()
	var out []hpRow
	for _, label := range hpSourceMethods(t) {
		if _, called := byLabel[label]; !called {
			out = append(out, hpRow{label: label, class: hpUndetermined, reqs: "-", recv: "없음", outcome: "-",
				note: " · 걷기가 닿지 않는 타입이라 수신자가 없다(facade_dump_test.go 의 뿌리에 닿게 하거나 이유와 함께 면제하라)"})
		}
	}
	return out
}

func hpLogTable(t *testing.T, rows []hpRow, called int) map[string]int {
	t.Helper()
	counts := map[string]int{}
	t.Logf("선언 집합 %d 메서드(걷기로 부른 것 %d + 소스에만 있는 것 %d) — 경로의 %s 는 생략, {U} 는 보편 인자(서명된 JWS)",
		len(rows), called, len(rows)-called, hpBase)
	for _, r := range rows {
		counts[r.class]++
		t.Logf("%-42s → %-13s · %s  [수신자 %s · %s]%s", r.label, r.class, r.reqs, r.recv, r.outcome, r.note)
	}
	classes := []string{hpCodeExchange, hpTokenGrant, hpJWKSFetch, hpOther, hpNone, hpUndetermined}
	summary := make([]string, 0, len(classes))
	for _, c := range classes {
		summary = append(summary, fmt.Sprintf("%s %d", c, counts[c]))
	}
	t.Logf("계급별: %s", strings.Join(summary, " · "))
	return counts
}

func TestHostilePathMatrix(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	builderOf := hpProbeBuilders(t, key)
	var rows []hpRow
	byLabel := map[string]hpRow{}
	methods := map[string]hpMethod{}
	for _, m := range hpDeclared(t) {
		r := hpRun(t, key, m, builderOf)
		rows = append(rows, r)
		byLabel[r.label] = r
		methods[r.label] = m
	}
	called := len(rows)
	for _, r := range hpUnreachedRows(t, byLabel) {
		rows = append(rows, r)
		byLabel[r.label] = r
	}
	counts := hpLogTable(t, rows, called)

	// (1) UNDETERMINED 없음 — 면제는 이유와 함께, 낡은 면제는 실패.
	for _, r := range rows {
		if _, exempt := hpUndeterminedExempt[r.label]; r.class == hpUndetermined && !exempt {
			t.Errorf("%s: 분류하지 못했다(UNDETERMINED) — 인자 합성·수신자를 고치거나 이유와 함께 면제하라%s", r.label, r.note)
		}
	}
	for label, reason := range hpUndeterminedExempt {
		if r, ok := byLabel[label]; !ok || r.class != hpUndetermined {
			t.Errorf("%s: 낡은 면제다 — 선언 집합에 없거나 더는 UNDETERMINED 가 아니다(%s)", label, reason)
		}
	}
	// (2) 세 교환 계급이 각각 비어 있지 않다 — 비면 분류기·가짜 IdP·인자 합성 중 하나가 공허해진 것이다.
	for _, c := range []string{hpCodeExchange, hpTokenGrant, hpJWKSFetch} {
		if counts[c] == 0 {
			t.Errorf("%s 계급이 비었다 — 교환 경로를 하나도 못 찾았다", c)
		}
	}

	// W3 — 대상은 전부 파생이다: (a) 계급 · (b) 계급 ∩ 서명 · (c) 분류 실행이 보낸 요청.
	nonceParams := hpNonceParams(t)
	tgt := map[string][]string{}
	var late []string // 판정표 뒤에 찍을 실패 — 변이 프로브는 출력 꼬리만 보여 준다
	for _, r := range rows {
		if _, called := methods[r.label]; !called {
			continue
		}
		if r.class == hpTokenGrant || r.class == hpCodeExchange {
			tgt["a"] = append(tgt["a"], r.label)
		}
		if r.class == hpCodeExchange {
			if len(nonceParams[r.label]) > 0 {
				tgt["b"] = append(tgt["b"], r.label)
			} else if reason, ok := hpNonceDropExempt[r.label]; ok {
				t.Logf("(b) nonce 파라미터가 없어 빠진 CODE_EXCHANGE 행: %s — %s", r.label, reason)
			} else {
				late = append(late, fmt.Sprintf("W3b %s: CODE_EXCHANGE 인데 이름에 nonce 가 든 파라미터가 없어 W3b 가 붙지 않는다 — "+
					"nonce 를 그 이름으로 받게 하거나, 정말 nonce 없는 흐름이면 이유와 함께 hpNonceDropExempt 에 적어라", r.label))
			}
		}
		if hpCount(r.sent, hpIsCertsGet) > 0 {
			tgt["c"] = append(tgt["c"], r.label)
		}
	}
	for label, reason := range hpNonceDropExempt {
		if r, ok := byLabel[label]; !ok || r.class != hpCodeExchange || len(nonceParams[label]) > 0 {
			late = append(late, fmt.Sprintf("hpNonceDropExempt[%s]: 낡은 면제다 — nonce 파라미터 없는 CODE_EXCHANGE 행이 아니다(%s)", label, reason))
		}
	}
	sdkErr := hpSDKErrorTypes(t)
	var cells []hpCell
	cells = append(cells, hpRunVariantsA(t, key, methods, builderOf, tgt["a"], nonceParams, sdkErr)...)
	cells = append(cells, hpRunNonceB(t, key, methods, builderOf, tgt["b"], nonceParams, sdkErr)...)
	cells = append(cells, hpRunColdJWKSC(t, key, methods, builderOf, tgt["c"], sdkErr)...)
	hpJudge(t, cells)

	// W1 — 손 목록 포함. 표의 실패 사유는 판정표 뒤에 모아 찍는다(프로브 꼬리에 보이게).
	for _, why := range append(late, hpCheckHand(t, byLabel, tgt)...) {
		t.Error(why)
	}
}

// ---- W1: 손 목록 포함 ----

// 손으로 고른 Go 테스트가 겨누는 메서드 — 파생 집합이 이것 밑으로 **조용히** 줄지 않게 한다.
// anchor 는 그 손 테스트(`파일|함수`), call 은 그 함수가 실제로 부르는 이름이다. call 이 비공개면 label 은 그것의
// 공개 입구이고, 그 입구의 소스가 call 을 부르는지 대조한다(한 단계). axis: a·b·c = 그 W3 축의 파생 대상에 있어야
// 한다 · row = 행이고 계급이 맞기만 하면 된다(교환 계급 밖).
var hpHandTargets = []struct{ label, class, axis, anchor, call string }{
	{"(*AuthClient).ClientCredentialsToken", hpTokenGrant, "a", "malformed_response_cause_test.go|causeRun", "ClientCredentialsToken"},
	{"(*AuthClient).ExchangeCode", hpCodeExchange, "a", "malformed_response_cause_test.go|causeRun", "ExchangeCode"},
	{"(*AuthClient).Refresh", hpTokenGrant, "a", "malformed_response_cause_test.go|causeRun", "Refresh"},
	{"(*Client).Admin", hpTokenGrant, "a", "malformed_response_cause_test.go|causeRun", "Admin"},
	{"(*AuthClient).Introspect", hpOther, "row", "malformed_response_cause_test.go|causeRun", "Introspect"},
	{"(*AuthClient).Logout", hpOther, "row", "malformed_response_cause_test.go|causeRun", "Logout"},
	// 보안 기본값 가드(scripts/test/test-security-defaults.sh)의 Go 행위 앵커 — nonce · 토큰 타입 · 백오프.
	{"(*AuthClient).ExchangeCode", hpCodeExchange, "b", "auth_test.go|TestExchangeCodeNonceValidation", "ExchangeCode"},
	{"(*AuthClient).ClientCredentialsToken", hpTokenGrant, "a", "auth_test.go|TestClientCredentialsRejectsNonStringAccessToken", "ClientCredentialsToken"},
	{"(*Validator).Validate", hpJWKSFetch, "c", "jwt_test.go|TestJWKSFailedFetchBackoffBoundsColdRetries", "resolveKey"},
	{"(*Validator).Validate", hpJWKSFetch, "c", "jwt_test.go|TestJWKSBackoffExpiresAndAllowsRetry", "resolveKey"},
	{"(*Validator).Validate", hpJWKSFetch, "c", "jwt_test.go|TestJWKSSuccessResetsFailureCounter", "resolveKey"},
}

// 보안 기본값 가드가 Go 행위 앵커를 적는 모양(`go/<파일>|func <이름>(`) — nonce·백오프·토큰 타입 세 축이 이 모양이다.
var hpScriptAnchorRE = regexp.MustCompile(`go/([A-Za-z0-9_]+_test\.go)\|func ([A-Za-z0-9_]+)\(`)

func hpCheckHand(t *testing.T, byLabel map[string]hpRow, tgt map[string][]string) []string {
	t.Helper()
	var why []string
	anchors := map[string]bool{}
	causeRunCalls := map[string]bool{}
	for _, h := range hpHandTargets {
		anchors[h.anchor] = true
		file, fn, _ := strings.Cut(h.anchor, "|")
		if fn == "causeRun" {
			causeRunCalls[h.call] = true
		}
		r, ok := byLabel[h.label]
		switch {
		case !ok:
			why = append(why, fmt.Sprintf("W1 %s: 손 테스트(%s)가 겨누는데 파생 집합에 행이 없다", h.label, h.anchor))
		case r.class != h.class:
			why = append(why, fmt.Sprintf("W1 %s: 손 테스트(%s)가 겨누는 계급은 %s 인데 파생은 %s 다", h.label, h.anchor, h.class, r.class))
		case h.axis != "row" && !slices.Contains(tgt[h.axis], h.label):
			why = append(why, fmt.Sprintf("W1 %s: 손 테스트(%s)가 겨누는데 W3%s 의 파생 대상에 없다", h.label, h.anchor, h.axis))
		}
		fd := hpFindFunc(t, file, fn)
		if fd == nil {
			why = append(why, fmt.Sprintf("W1 %s: 앵커 함수가 없다 — 손 테스트가 옮겨졌으면 표를 따라 고쳐라", h.anchor))
			continue
		}
		if !hpCallsIn(fd)[h.call] {
			why = append(why, fmt.Sprintf("W1 %s: 앵커가 .%s( 를 부르지 않는다 — 손 테스트의 대상이 바뀌었다", h.anchor, h.call))
		}
		if !strings.HasSuffix(h.label, "."+h.call) {
			if m := hpFindMethod(t, h.label); m == nil || !hpCallsIn(m)[h.call] {
				why = append(why, fmt.Sprintf("W1 %s: 공개 입구가 %s 를 부르지 않는다 — 앵커(%s)의 대상과 이어지지 않는다", h.label, h.call, h.anchor))
			}
		}
	}
	// causeRun 이 부르는 공개 이름은 전부 표에 있다 — 손 테스트에 대상이 늘면 여기가 먼저 운다.
	nCause := 0
	if fd := hpFindFunc(t, "malformed_response_cause_test.go", "causeRun"); fd != nil {
		for name := range hpCallsIn(fd) {
			if !ast.IsExported(name) {
				continue
			}
			nCause++
			if !causeRunCalls[name] {
				why = append(why, fmt.Sprintf("W1 causeRun 이 %s 를 부르는데 hpHandTargets 에 없다", name))
			}
		}
	}
	if nCause == 0 {
		why = append(why, "W1 causeRun 에서 공개 호출을 하나도 못 읽었다 — 대조가 공허하다")
	}
	// 보안 기본값 가드의 Go 행위 앵커는 전부 표의 앵커다 — 그 가드에 Go 앵커가 늘면 여기가 운다.
	script, err := os.ReadFile(filepath.Join("..", "scripts", "test", "test-security-defaults.sh"))
	switch {
	case err == nil:
		found := hpScriptAnchorRE.FindAllStringSubmatch(string(script), -1)
		t.Logf("W1 손 목록 %d 항목 · 앵커 %d — causeRun 공개 호출 %d · 보안 기본값 가드의 Go 행위 앵커 %d 와 대조",
			len(hpHandTargets), len(anchors), nCause, len(found))
		if len(found) == 0 {
			why = append(why, "W1 test-security-defaults.sh 에서 Go 행위 앵커를 하나도 못 읽었다 — 적는 모양이 바뀌었나?")
		}
		for _, m := range found {
			if a := m[1] + "|" + m[2]; !anchors[a] {
				why = append(why, fmt.Sprintf("W1 보안 기본값 가드의 Go 앵커 %s 가 hpHandTargets 에 없다", a))
			}
		}
	case hpInCheckout():
		why = append(why, fmt.Sprintf("W1 저장소 체크아웃인데 보안 기본값 가드를 못 읽었다: %v", err))
	default:
		t.Logf("W1: 저장소 밖(모듈 캐시)에서 돌아 보안 기본값 가드 대조는 건너뛴다")
	}
	return why
}

func hpInCheckout() bool {
	_, err := os.Stat(filepath.Join("..", ".git"))
	return err == nil
}

func hpParse(t *testing.T, file string) *ast.File {
	t.Helper()
	af, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	if err != nil {
		t.Fatalf("%s: %v", file, err)
	}
	return af
}

// hpFindFunc 는 file 의 수신자 없는 함수 name 이다(없으면 nil).
func hpFindFunc(t *testing.T, file, name string) *ast.FuncDecl {
	t.Helper()
	for _, d := range hpParse(t, file).Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv == nil && fd.Name.Name == name {
			return fd
		}
	}
	return nil
}

// hpFindMethod 는 소스(비테스트)에서 라벨이 label 인 메서드 선언이다(없으면 nil).
func hpFindMethod(t *testing.T, label string) *ast.FuncDecl {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		for _, d := range hpParse(t, f).Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv != nil &&
				hpRecvLabel(fd.Recv.List[0].Type)+"."+fd.Name.Name == label {
				return fd
			}
		}
	}
	return nil
}

// hpCallsIn 은 fd 본문이 `x.Name(…)` 꼴로 부르는 이름 전부다.
func hpCallsIn(fd *ast.FuncDecl) map[string]bool {
	out := map[string]bool{}
	if fd.Body == nil {
		return out
	}
	ast.Inspect(fd.Body, func(n ast.Node) bool {
		if c, ok := n.(*ast.CallExpr); ok {
			if s, ok := c.Fun.(*ast.SelectorExpr); ok {
				out[s.Sel.Name] = true
			}
		}
		return true
	})
	return out
}

// ---- W3: 계급별 적대 변형 ----

// W3b 에서 빠져도 되는 CODE_EXCHANGE 행과 그 이유. **이유 없는 면제는 넣지 않는다.** nonce 파라미터의 이름으로
// 대상을 파생하므로, nonce 를 다른 이름(`expected` 등)으로 받는 새 교환 메서드는 이 표가 없으면 **조용히** 빠진다 —
// Grok 레그가 지목했고 실측이 맞다고 했다(그런 메서드를 심으니 SILENT). 오늘은 비어 있다.
var hpNonceDropExempt = map[string]string{}

// hpNonceParams 는 소스(비테스트)의 공개 메서드마다 이름에 "nonce" 가 든(대소문자 무시) 파라미터의 위치다
// (0 부터, 수신자 제외 — 리플렉션으로 얻은 바운드 메서드의 In(i) 와 같은 번호). **이름 목록이 아니라 서명에서** 얻는다.
func hpNonceParams(t *testing.T) map[string][]int {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string][]int{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		for _, d := range hpParse(t, f).Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Recv == nil || !fd.Name.IsExported() {
				continue
			}
			label := hpRecvLabel(fd.Recv.List[0].Type) + "." + fd.Name.Name
			i := 0
			for _, field := range fd.Type.Params.List {
				if len(field.Names) == 0 {
					i++
					continue
				}
				for _, n := range field.Names {
					if strings.Contains(strings.ToLower(n.Name), "nonce") {
						out[label] = append(out[label], i)
					}
					i++
				}
			}
		}
	}
	return out
}

// hpSDKErrorTypes 는 errors.go 에 선언된 공개 오류 타입(Error 메서드의 수신자)이다 — SDK 오류 계급을 손으로 적지 않는다.
func hpSDKErrorTypes(t *testing.T) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	for _, d := range hpParse(t, "errors.go").Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv != nil && fd.Name.Name == "Error" {
			name := strings.Trim(hpRecvLabel(fd.Recv.List[0].Type), "(*)")
			if ast.IsExported(name) {
				out[name] = true
			}
		}
	}
	if len(out) == 0 {
		t.Fatal("errors.go 에서 SDK 오류 타입을 하나도 못 읽었다")
	}
	return out
}

// hpIsSDKError — 반환 오류 **자체**가 이 패키지의 공개 오류 타입인가(하위 오류는 경계에서 변환된다 — §4).
func hpIsSDKError(err error, sdk map[string]bool) bool {
	ty := reflect.TypeOf(err)
	if ty.Kind() == reflect.Pointer {
		ty = ty.Elem()
	}
	return ty.PkgPath() == reflect.TypeOf(Config{}).PkgPath() && sdk[ty.Name()]
}

func hpIsTokenPost(r hpReq) bool {
	return r.method == http.MethodPost && strings.HasSuffix(r.path, hpTokenSuffix)
}

func hpIsCertsGet(r hpReq) bool {
	return r.method == http.MethodGet && strings.HasSuffix(r.path, hpCertsSuffix)
}

func hpCount(reqs []hpReq, pred func(hpReq) bool) int {
	n := 0
	for _, r := range reqs {
		if pred(r) {
			n++
		}
	}
	return n
}

// hpAfterToken 은 토큰 엔드포인트 요청 수와, 첫 토큰 요청 **뒤에** 나간 토큰 아닌 요청이다.
func hpAfterToken(reqs []hpReq) (tokenHits int, after []hpReq) {
	for _, r := range reqs {
		switch {
		case hpIsTokenPost(r):
			tokenHits++
		case tokenHits > 0:
			after = append(after, r)
		}
	}
	return tokenHits, after
}

// hpVariant 는 토큰 엔드포인트가 내는 형식이 틀린 응답 하나다. from 이 비면 **측정만** 한다(단언하지 않는다) —
// 기존 테스트가 단언하지 않는 변형에 새 계약을 만들지 않기 위해서다.
type hpVariant struct {
	code, from string
	canaries   []string
	resp       hostileResp
}

// hpTokenVariants — 변형 집합을 새로 만들지 않고 기존 테스트에서 가져온다.
//   - malformed_response_cause_test.go 의 causeVariants 중 **토큰 호출 넷(tokenCalls) 전부에** 단언된 것. raw 소켓
//     변형(f*)은 뺀다 — 모든 엔드포인트의 HTTP 틀을 깨 admin 수신자를 정상 응답으로 먼저 만들 수 없다.
//   - auth_test.go 의 ccAccessTokenCases 중 비문자열 행(양성 대조 "string" 은 변형이 아니다).
//   - at:missing — 어느 기존 테스트도 단언하지 않는다. 측정만.
//
// ⚠️ 공허 함정: 이 본문들엔 쓸 수 있는 id_token 이 없다. nonce 를 준 ExchangeCode 는 정상 토큰 응답이어도
// 「missing/invalid id_token」으로 실패하므로 적대 응답이 안 닿아도 통과한다(malformed_response_cause_test.go 의
// 변이 b 실측과 같은 부류) — 그래서 W3a 는 nonce 파라미터를 비워 id_token 검증을 끄고 **토큰 응답 형식만** 잰다.
// nonce 는 W3b 가 따로 잰다.
func hpTokenVariants() (out []hpVariant, skipped []string) {
	for _, v := range causeVariants() {
		switch {
		case v.resp.raw != "":
			skipped = append(skipped, causeShortName(v)+"(raw 소켓)")
		case !hpHasAll(v.on, tokenCalls):
			skipped = append(skipped, causeShortName(v)+"(토큰 호출 넷 전부에 단언되지 않는다)")
		default:
			out = append(out, hpVariant{code: causeShortName(v), from: "malformed_response_cause_test.go " + v.name,
				canaries: v.canaries, resp: v.resp})
		}
	}
	for _, c := range ccAccessTokenCases {
		if c.accessToken != "" {
			continue
		}
		out = append(out, hpVariant{code: "at:" + strings.ReplaceAll(c.name, " ", "_"),
			from: "auth_test.go ccAccessTokenCases " + c.name, canaries: []string{causeRT},
			resp: causeTokenJSON(fmt.Sprintf(`"access_token":%s,"token_type":"Bearer","expires_in":300,"refresh_token":%q`,
				c.raw, causeRT))})
	}
	out = append(out, hpVariant{code: "at:missing", canaries: []string{causeRT},
		resp: causeTokenJSON(fmt.Sprintf(`"token_type":"Bearer","expires_in":300,"refresh_token":%q`, causeRT))})
	return out, skipped
}

// hpWellFormed 는 W3a 대조 — 변형들과 같은 모양(id_token 없음)의 쓸 수 있는 토큰 응답이다.
var hpWellFormed = causeTokenJSON(`"access_token":"hp-access","token_type":"Bearer","expires_in":300,"refresh_token":"hp-refresh"`)

func hpHasAll(set, want []string) bool {
	for _, w := range want {
		if !slices.Contains(set, w) {
			return false
		}
	}
	return true
}

// hpCell 은 판정표의 한 칸이다. why 가 비면 통과, measure 면 단언하지 않고 결과만 찍는다.
type hpCell struct {
	axis, label, variant string
	why                  []string
	measure              bool
	note                 string // 표에 함께 찍을 측정치(요청 수 등)
}

func (c hpCell) key() string { return "W3" + c.axis + " " + c.label + "/" + c.variant }

// 현재 main 에서 실패하는 칸 — 키는 hpCell.key(`W3<축> 행/변형`), 값은 `등록부 id: 한 줄 이유`. SDK 를 고치지 않고 드러내 둔다.
// 관측되지 않는(이제 통과하거나 칸이 없는) 항목은 낡은 것이라 실패한다. **이유 없는 항목은 넣지 않는다.**
var hpKnownGaps = map[string]string{}

// hpCell0 은 수신자를 정상 응답으로 만든 **뒤에** 토큰 응답을 resp 로 바꾸고(nil 이면 정상 그대로) 한 번 부른다.
func hpCell0(t *testing.T, key *rsa.PrivateKey, m hpMethod, builderOf map[string]int, blank map[int]bool,
	resp func(*hpIdP) *hostileResp) (sent []hpReq, panicked any, err error) {
	t.Helper()
	idp := newHPIdP(t, key)
	defer idp.srv.Close() // 칸마다 닫는다 — 수백 개 서버가 테스트 끝까지 살지 않게
	recv, _ := hpReceiver(t, idp, m, builderOf)
	idp.reset()
	idp.setTokenResp(resp(idp))
	panicked, err = hpInvoke(recv, m.name, hpArgs(idp.universal, blank))
	return idp.snapshot(), panicked, err
}

// hpHostileWhy 는 적대 토큰 응답 한 칸의 실패 사유다 — 비면 통과. ctlHits 는 같은 행의 대조가 낸 토큰 요청 수다.
func hpHostileWhy(sent []hpReq, panicked any, err error, canaries []string, sdk map[string]bool, ctlHits int) []string {
	var why []string
	if panicked != nil {
		why = append(why, fmt.Sprintf("패닉: %v", panicked))
	}
	if err == nil && panicked == nil {
		why = append(why, "오류 없이 성공했다")
	}
	if err != nil {
		if !hpIsSDKError(err, sdk) {
			why = append(why, fmt.Sprintf("SDK 오류 타입이 아니다: %T", err))
		}
		outs := causeRender(err)
		paths := make([]string, 0, len(outs))
		for p := range outs {
			paths = append(paths, p)
		}
		sort.Strings(paths)
		for _, p := range paths {
			for _, cn := range canaries {
				if how := causeFind(outs[p], cn); how != "" {
					why = append(why, fmt.Sprintf("카나리아 %.10s… 가 %s 에 찍혔다(%s): %s", cn, p, how, causeLine(outs[p])))
				}
			}
		}
	}
	hits, after := hpAfterToken(sent)
	if hits == 0 {
		why = append(why, "토큰 엔드포인트에 한 번도 안 닿았다 — 변형이 공허하다")
	}
	// 하한만 두면 틀린 응답마다 재시도하는 새 메서드가 통과한다(Grok 레그 지목, 실측 SILENT). 상한은 손 상수가
	// 아니라 같은 행의 대조다. ⚠️ x/oauth2 의 AuthStyleAutoDetect 로 바꾸면 여기가 운다 — 실패 한 번에 인증 방식을
	// 바꿔 한 번 더 묻는다. 그때는 그 곱절이 받아들일 만한지부터 판정한다.
	if hits > ctlHits {
		why = append(why, fmt.Sprintf("토큰 요청 %d 건 — 정상 응답 대조(%d 건)보다 많다: 틀린 응답이 재시도를 부른다", hits, ctlHits))
	}
	if len(after) > 0 {
		why = append(why, fmt.Sprintf("적대 토큰 응답 뒤로 나아갔다: %s", hpFormat(after, "")))
	}
	return why
}

func hpRunVariantsA(t *testing.T, key *rsa.PrivateKey, methods map[string]hpMethod, builderOf map[string]int,
	labels []string, nonceParams map[string][]int, sdk map[string]bool) []hpCell {
	t.Helper()
	variants, skipped := hpTokenVariants()
	t.Logf("(a) 토큰응답 형식 변형 %d(측정만 포함) — 기존 테스트에서 파생 · 뺀 것: %s", len(variants), strings.Join(skipped, ", "))
	var cells []hpCell
	for _, label := range labels {
		m := methods[label]
		blank := map[int]bool{}
		for _, i := range nonceParams[label] {
			blank[i] = true
		}
		// 대조 — 변형과 **같은 모양의** 정상 응답(id_token 없음). 이 행에서 무엇이 적대 변형을 가르는지 정한다:
		// 성공하면 「오류다」가, 토큰 뒤로 나아가면(admin 자원 → 404) 「뒤로 안 나아갔다」가 무게를 진다. 둘 다
		// 아니면 행 전체가 공허하다. ⚠️ IdP 의 기본 응답(id_token 있음)으로 대조하면 안 된다 — nonce 파라미터 이름이
		// "nonce" 가 아닌 새 교환 메서드는 변형마다 「id_token 없음」으로 실패해 공허하게 통과하는데, 기본 응답
		// 대조는 성공해 그것을 못 가른다.
		sent, panicked, err := hpCell0(t, key, m, builderOf, blank, func(*hpIdP) *hostileResp { return &hpWellFormed })
		hits, after := hpAfterToken(sent)
		ctl := hpCell{axis: "a", label: label, variant: "대조"}
		switch {
		case panicked != nil:
			ctl.why = append(ctl.why, fmt.Sprintf("정상 응답에 패닉: %v", panicked))
		case hits == 0:
			ctl.why = append(ctl.why, "정상 응답에서 토큰 엔드포인트에 안 닿았다 — 이 행의 변형은 공허하다")
		case err != nil && len(after) == 0:
			ctl.why = append(ctl.why, fmt.Sprintf("정상 응답에 실패했고 토큰 뒤로 나아가지도 않았다 — 변형이 무엇을 바꿨는지 가를 수 없다: %v", err))
		}
		ctl.note = map[bool]string{true: "ok", false: "↓" + strconv.Itoa(len(after))}[err == nil]
		cells = append(cells, ctl)
		for _, v := range variants {
			sent, panicked, err := hpCell0(t, key, m, builderOf, blank, func(*hpIdP) *hostileResp { return &v.resp })
			c := hpCell{axis: "a", label: label, variant: v.code, measure: v.from == ""}
			c.why = hpHostileWhy(sent, panicked, err, v.canaries, sdk, hits)
			if c.measure {
				c.note = fmt.Sprintf("%T", err)
			}
			cells = append(cells, c)
		}
	}
	return cells
}

// W3b 의 변형 — 대조(맞는 id_token)와 넷, 측정 하나. 다른 키로 서명할 때 kid 가 k1 이면 캐시된 키로 서명 검증이
// 실패하고, k2 면 키를 못 찾는다. 「id_token 없음」은 TestExchangeCodeNonceValidation 이 이미 단언한다.
// 「nonce 클레임 없음」은 어느 Go 테스트도 단언하지 않아 측정만 한다(java 는 단언한다 — 계약을 여기서 만들지 않는다).
var hpNonceVariants = []struct {
	code, kid string
	otherKey  bool
	claims    map[string]any // nil 이면 {"nonce": 보편 인자(=호출에 넘긴 nonce)}
	noIDToken bool
	want      string // ok=성공해야 한다 · reject=거부해야 한다 · measure=측정만
}{
	{"대조", "k1", false, nil, false, "ok"},
	{"nonce≠", "k1", false, map[string]any{"nonce": "hp-other-nonce"}, false, "reject"},
	{"key≠·kid=k1", "k1", true, nil, false, "reject"},
	{"key≠·kid=k2", "k2", true, nil, false, "reject"},
	{"id_token없음", "", false, nil, true, "reject"},
	{"nonce클레임없음", "k1", false, map[string]any{}, false, "measure"},
}

func hpRunNonceB(t *testing.T, key *rsa.PrivateKey, methods map[string]hpMethod, builderOf map[string]int,
	labels []string, nonceParams map[string][]int, sdk map[string]bool) []hpCell {
	t.Helper()
	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, l := range labels {
		names = append(names, fmt.Sprintf("%s%v", l, nonceParams[l]))
	}
	t.Logf("(b) nonce 대상(서명에서 파생 — 파라미터 위치): %s", strings.Join(names, ", "))
	var cells []hpCell
	for _, label := range labels {
		for _, nv := range hpNonceVariants {
			sent, panicked, err := hpCell0(t, key, methods[label], builderOf, nil, func(p *hpIdP) *hostileResp {
				body := `"access_token":"hp-access","token_type":"Bearer","expires_in":300,"refresh_token":"hp-refresh"`
				if !nv.noIDToken {
					signer, claims := key, nv.claims
					if nv.otherKey {
						signer = other
					}
					if claims == nil {
						claims = map[string]any{"nonce": p.universal}
					}
					body += fmt.Sprintf(`,"id_token":%q`, hpSignKid(t, signer, nv.kid, p.iss(), claims))
				}
				r := causeTokenJSON(body)
				return &r
			})
			c := hpCell{axis: "b", label: label, variant: nv.code, measure: nv.want == "measure"}
			certs := hpCount(sent, hpIsCertsGet)
			c.note = fmt.Sprintf("certs %d", certs)
			if panicked != nil {
				c.why = append(c.why, fmt.Sprintf("패닉: %v", panicked))
			}
			if hpCount(sent, hpIsTokenPost) == 0 {
				c.why = append(c.why, "토큰 엔드포인트에 안 닿았다 — 변형이 공허하다")
			}
			// id_token 이 있는 변형은 검증기에 닿아야 한다(콜드 캐시라 JWKS 를 조회한다) — 아니면 다른 이유로 실패한 것이다.
			if certs == 0 && !nv.noIDToken {
				c.why = append(c.why, "JWKS 를 조회하지 않았다 — id_token 이 검증기에 닿지 않았다")
			}
			switch {
			case nv.want == "ok" && err != nil:
				c.why = append(c.why, fmt.Sprintf("맞는 id_token 에 실패했다 — 아래 변형의 실패가 아무것도 증명하지 않는다: %v", err))
			case nv.want != "ok" && err == nil && panicked == nil:
				c.why = append(c.why, "틀린 id_token 을 받아들였다")
			case nv.want != "ok" && err != nil && !hpIsSDKError(err, sdk):
				c.why = append(c.why, fmt.Sprintf("SDK 오류 타입이 아니다: %T", err))
			}
			if c.measure && err != nil {
				c.note += " · " + fmt.Sprintf("%T", err)
			}
			cells = append(cells, c)
		}
	}
	return cells
}

// hpColdK 는 콜드 캐시 JWKS 칸의 호출 수다 — 상한 k−1 이 백오프, 하한 1 이 콜드 경로 도달의 증명이다.
const hpColdK = 5

func hpRunColdJWKSC(t *testing.T, key *rsa.PrivateKey, methods map[string]hpMethod, builderOf map[string]int,
	labels []string, sdk map[string]bool) []hpCell {
	t.Helper()
	t.Logf("(c) 콜드 캐시 JWKS 대상(분류 실행이 /certs 를 조회한 행): %s", strings.Join(labels, ", "))
	var cells []hpCell
	for _, label := range labels {
		m := methods[label]
		idp := newHPIdP(t, key)
		recv, _ := hpReceiver(t, idp, m, builderOf) // 새 클라이언트 — 캐시가 비어 있다
		idp.reset()
		idp.setCertsDown(true)
		c := hpCell{axis: "c", label: label, variant: fmt.Sprintf("503×%d", hpColdK)}
		for i := 0; i < hpColdK; i++ {
			panicked, err := hpInvoke(recv, m.name, hpArgs(idp.universal, nil))
			switch {
			case panicked != nil:
				c.why = append(c.why, fmt.Sprintf("%d번째 호출이 패닉: %v", i+1, panicked))
			case err == nil:
				c.why = append(c.why, fmt.Sprintf("%d번째 호출이 JWKS 503 인데 성공했다", i+1))
			case !hpIsSDKError(err, sdk):
				c.why = append(c.why, fmt.Sprintf("%d번째 호출의 오류가 SDK 오류 타입이 아니다: %T", i+1, err))
			}
		}
		hits := hpCount(idp.snapshot(), hpIsCertsGet)
		idp.srv.Close()
		c.note = fmt.Sprintf("certs %d", hits)
		if hits < 1 {
			c.why = append(c.why, fmt.Sprintf("/certs 요청 %d — 콜드 경로에 닿지 않았다(하한 1)", hits))
		}
		if hits > hpColdK-1 {
			c.why = append(c.why, fmt.Sprintf("/certs 요청 %d — 실패한 조회가 물러서지 않았다(상한 %d)", hits, hpColdK-1))
		}
		cells = append(cells, c)
	}
	return cells
}

// hpJudge 는 칸마다 통과·GAP·FAIL 을 정하고 판정표를 찍는다. 실패 사유는 표 **뒤에** 모은다.
func hpJudge(t *testing.T, cells []hpCell) {
	t.Helper()
	verdict := map[string]string{}
	var fails []string
	observed := map[string]bool{}
	for _, c := range cells {
		v := "pass"
		switch {
		case c.measure && len(c.why) == 0:
			v = "m:rej"
		case c.measure:
			v = "m:ACC"
		case len(c.why) > 0:
			if _, known := hpKnownGaps[c.key()]; known {
				v = "GAP"
				observed[c.key()] = true
			} else {
				v = "FAIL"
				fails = append(fails, fmt.Sprintf("%s: %s", c.key(), strings.Join(c.why, " · ")))
			}
		}
		if c.note != "" && (c.axis != "a" || c.variant == "대조") {
			v += "(" + c.note + ")"
		}
		verdict[c.key()] = v
	}
	for _, axis := range []string{"a", "b", "c"} {
		hpLogVerdicts(t, axis, cells, verdict)
	}
	// 측정 칸은 변형마다 한 줄로 모은다 — 받아들인 행만 이름과 사유를 적는다.
	type tally struct {
		rejected []string // 오류 타입
		accepted []string
	}
	measured := map[string]*tally{}
	var order []string
	for _, c := range cells {
		if !c.measure {
			continue
		}
		k := "W3" + c.axis + " " + c.variant
		if measured[k] == nil {
			measured[k] = &tally{}
			order = append(order, k)
		}
		if len(c.why) == 0 {
			measured[k].rejected = append(measured[k].rejected, c.note)
		} else {
			measured[k].accepted = append(measured[k].accepted, c.label+"("+strings.Join(c.why, " · ")+")")
		}
	}
	for _, k := range order {
		m := measured[k]
		kinds := slices.Compact(slices.Sorted(slices.Values(m.rejected)))
		t.Logf("측정(단언 안 함) %s — 거부 %d · 받아들임 %d · 거부 오류 %v · 받아들인 행 %v",
			k, len(m.rejected), len(m.accepted), kinds, m.accepted)
	}
	for key, reason := range hpKnownGaps {
		if !observed[key] {
			fails = append(fails, fmt.Sprintf("hpKnownGaps[%s]: 더는 관측되지 않는다 — 낡은 항목을 지워라(%s)", key, reason))
		}
	}
	for _, f := range fails {
		t.Error(f)
	}
	// 요약은 실패 줄 **뒤에** 찍는다 — 변이 프로브는 출력 꼬리만 보여 준다.
	for _, axis := range []string{"a", "b", "c"} {
		n := map[string]int{}
		failedBy := map[string]int{}
		var failedOrder []string
		for _, c := range cells {
			if c.axis != axis {
				continue
			}
			v := strings.SplitN(verdict[c.key()], "(", 2)[0]
			n[v]++
			if v == "FAIL" {
				if failedBy[c.variant] == 0 {
					failedOrder = append(failedOrder, c.variant)
				}
				failedBy[c.variant]++
			}
		}
		var fv []string
		for _, v := range failedOrder {
			fv = append(fv, fmt.Sprintf("%s×%d", v, failedBy[v]))
		}
		t.Logf("W3%s 요약: pass %d · GAP %d · FAIL %d · 측정 %d(m:rej %d · m:ACC %d) · FAIL 열 %v",
			axis, n["pass"], n["GAP"], n["FAIL"], n["m:rej"]+n["m:ACC"], n["m:rej"], n["m:ACC"], fv)
	}
}

// hpLogVerdicts 는 한 축의 판정표다 — 행은 메서드, 열은 변형.
func hpLogVerdicts(t *testing.T, axis string, cells []hpCell, verdict map[string]string) {
	t.Helper()
	var labels, cols []string
	for _, c := range cells {
		if c.axis != axis {
			continue
		}
		if !slices.Contains(labels, c.label) {
			labels = append(labels, c.label)
		}
		if !slices.Contains(cols, c.variant) {
			cols = append(cols, c.variant)
		}
	}
	if len(labels) == 0 {
		t.Logf("W3%s 판정표: 대상 행이 없다", axis)
		return
	}
	width := make([]int, len(cols))
	for i, col := range cols {
		width[i] = len([]rune(col))
		for _, l := range labels {
			if n := len([]rune(verdict[hpCell{axis: axis, label: l, variant: col}.key()])); n > width[i] {
				width[i] = n
			}
		}
	}
	pad := func(s string, n int) string { return s + strings.Repeat(" ", n-len([]rune(s))) }
	line := func(first string, vals func(i int) string) string {
		parts := []string{pad(first, 42)}
		for i := range cols {
			parts = append(parts, pad(vals(i), width[i]))
		}
		return strings.TrimRight(strings.Join(parts, " "), " ")
	}
	t.Logf("W3%s 판정표 — %d행 × %d열 (pass · GAP=알려진 틈 · FAIL · m:rej/m:ACC=측정만: 거부/받아들임)", axis, len(labels), len(cols))
	t.Log(line("행 \\ 변형", func(i int) string { return cols[i] }))
	for _, l := range labels {
		t.Log(line(l, func(i int) string { return verdict[hpCell{axis: axis, label: l, variant: cols[i]}.key()] }))
	}
}
