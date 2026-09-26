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
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// 적대 경로 행렬의 첫 걸음 — **분류표만** 세운다(등록부 `guard-detection-surface-hand-narrowed`).
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
// 단언은 둘뿐이다 — (1) UNDETERMINED 가 없다(면제 표에 이유와 함께 있으면 통과, 낡은 면제는 실패),
// (2) CODE_EXCHANGE·TOKEN_GRANT·JWKS_FETCH 가 각각 비어 있지 않다. 적대 변형은 다음 걸음이다.
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
}

func newHPIdP(t *testing.T, key *rsa.PrivateKey) *hpIdP {
	t.Helper()
	idp := &hpIdP{}
	mux := http.NewServeMux()
	mux.HandleFunc(hpBase+"/token", func(w http.ResponseWriter, _ *http.Request) {
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
	iss := idp.srv.URL + "/realms/r"
	idp.universal = hpSign(t, key, iss, nil)
	idp.idToken = hpSign(t, key, iss, map[string]any{"nonce": idp.universal})
	return idp
}

func (p *hpIdP) cfg() Config {
	return Config{ServerURL: p.srv.URL, Realm: "r", ClientID: "c", ClientSecret: "hp-client-secret"}
}

func (p *hpIdP) reset() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.reqs = nil
}

func (p *hpIdP) snapshot() []hpReq {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]hpReq(nil), p.reqs...)
}

func hpSign(t *testing.T, key *rsa.PrivateKey, iss string, extra map[string]any) string {
	t.Helper()
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "k1"))
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
	m := recv.MethodByName(name)
	mt := m.Type()
	args := make([]reflect.Value, mt.NumIn())
	for i := range args {
		args[i] = hpArg(mt.In(i), universal)
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
		k := r.method + " " + strings.ReplaceAll(strings.TrimPrefix(r.path, hpBase), universal, "{U}")
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

type hpRow struct{ label, class, reqs, recv, outcome, note string }

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
		reqs: hpFormat(reqs, idp.universal), recv: src, outcome: "ok"}
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
	for _, m := range hpDeclared(t) {
		r := hpRun(t, key, m, builderOf)
		rows = append(rows, r)
		byLabel[r.label] = r
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
}
