package keycloak

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
	"unsafe"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"golang.org/x/sync/singleflight"
)

// 바닥 계약(기본 문자열/디버그 표현이 비밀을 찍지 않는다)을 **값 타입 목록이 아니라 도달 가능한
// 객체 전부**에 건다. `masking_test.go` 는 손으로 고른 값 타입 셋(TokenSet·Config·AuthorizationRequest)을
// 재는데, 실측(2026-09-26)으로 그 밖의 **파사드**가 새고 있었다:
//
//	*Client · *AuthClient        %v %+v %#v %s %q → 클라이언트 시크릿 원문
//	NewClientCredentialsTokenProvider 의 반환값 → 캐시된 액세스 토큰 원문(모든 동사)
//	*AdminClient                 %s %q           → 캐시된 액세스 토큰 원문
//
// 원인: 비공개 필드는 fmt 가 메서드를 못 불러 `Config.String()` 을 건너뛰고 필드를 직접 찍는다.
//
// ⚠️ **새 자리를 스스로 찾는 것이 이 테스트의 요점이다**(등록부 `guard-detection-surface-hand-narrowed`).
// 검사 대상은 손 목록이 아니라 (1) 공개 API 로 만든 뿌리에서 리플렉션으로 **닿는 이 패키지의 타입 전부**이고,
// (2) 이 패키지 소스를 파싱해 얻은 **구조체 타입 전수**가 그 걷기에 걸렸는지를 대조한다 — 새 타입은
// 걷기에 닿거나 아래 면제 표에 이유와 함께 적혀야 통과한다.
//
// ⚠️ 한계: 카나리아는 뿌리를 만드는 호출이 흘려 넣은 비밀뿐이다. 새 타입이 이 뿌리들이 안 밟는 경로로
// 비밀을 받으면 그 비밀은 여기 없다 — 그때는 그 경로를 뿌리에 더한다.

const (
	dumpCanarySecret  = "CANARY-DUMP-CLIENT-SECRET"
	dumpCanaryAccess  = "CANARY-DUMP-ACCESS-TOKEN"
	dumpCanaryRefresh = "CANARY-DUMP-REFRESH-TOKEN"
	dumpCanaryID      = "CANARY-DUMP-ID-TOKEN"
	dumpCanaryGarbage = "CANARY-DUMP-GARBAGE-TOKEN"
)

// 걷기에 안 닿아도 되는 구조체 타입과 그 이유. **이유 없는 면제는 넣지 않는다.**
var dumpWalkExempt = map[string]string{
	"wireScrubTransport": "*http.Client.Transport·resty 안에만 산다 — 걷기는 외부 타입(http.Client) 안으로 내려가지 않는다. " +
		"필드는 하위 RoundTripper 하나뿐이고 비밀을 쥐지 않는다(cause.go)",
	"wireScrubBody": "응답 본문(http.Response.Body)을 감싸 읽는 동안만 산다 — 파사드가 쥐지 않는다. " +
		"필드는 원래 본문 하나뿐이다(cause.go)",
}

// 가짜 IdP — 토큰·introspect·JWKS·실패 realm·admin 404 를 한 서버가 낸다.
func newDumpIdP(t *testing.T, key *rsa.PrivateKey) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	base := "/realms/r/protocol/openid-connect"
	mux.HandleFunc(base+"/token", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprintf(w, `{"access_token":%q,"token_type":"Bearer","expires_in":300,"refresh_token":%q,"id_token":%q}`,
			dumpCanaryAccess, dumpCanaryRefresh, dumpCanaryID)
	})
	mux.HandleFunc(base+"/token/introspect", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"active":true,"username":"svc","client_id":"c","sub":"u1"}`))
	})
	mux.HandleFunc(base+"/certs", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
			{Key: &key.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"},
		}})
	})
	mux.HandleFunc("/realms/bad/protocol/openid-connect/token", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"invalid_client"}`))
	})
	mux.HandleFunc("/admin/realms/r/users/missing", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

type dumpRoot struct {
	name string
	v    any
}

// 공개 API 로 뿌리를 만들고, 그 과정이 흘려 넣은 비밀 전부를 카나리아로 돌려준다.
func dumpRoots(t *testing.T) ([]dumpRoot, []string) {
	t.Helper()
	ctx := context.Background()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	srv := newDumpIdP(t, key)
	cfg := Config{ServerURL: srv.URL, Realm: "r", ClientID: "c", ClientSecret: dumpCanarySecret}

	c, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	// 기본 경로의 admin — 내부에서 만든 provider 가 토큰을 캐시한 뒤라야 그 캐시가 걷기에 걸린다.
	def, err := c.Admin(ctx)
	if err != nil {
		t.Fatalf("admin: %v", err)
	}
	ts, err := c.Auth.ClientCredentialsToken(ctx)
	if err != nil {
		t.Fatalf("client credentials: %v", err)
	}
	ar := c.Auth.CreateAuthorizationRequest("https://app/cb")
	// ⚠️ 카나리아가 실제로 흘러 들어갔는가 — 안 흘렀으면 아래 누출 검사는 없는 것을 찾으며 통과한다.
	if tok, _ := def.tp.Token(ctx); tok != dumpCanaryAccess ||
		ts.AccessToken != dumpCanaryAccess || ts.RefreshToken != dumpCanaryRefresh || ts.IDToken != dumpCanaryID ||
		ar.CodeVerifier == "" {
		t.Fatalf("카나리아가 뿌리에 안 흘렀다 — 가짜 IdP 응답이나 매핑이 바뀌었다(provider %q, TokenSet %+v)", tok, *ts)
	}
	ir, err := c.Auth.Introspect(ctx, dumpCanaryAccess)
	if err != nil {
		t.Fatalf("introspect: %v", err)
	}
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "k1"))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := jwt.Signed(sig).Claims(jwt.Claims{
		Issuer: srv.URL + "/realms/r", Subject: "u1", Audience: jwt.Audience{"c"},
		Expiry: jwt.NewNumericDate(time.Now().Add(time.Minute)), IssuedAt: jwt.NewNumericDate(time.Now()),
	}).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	vt, err := c.Auth.Validate(ctx, raw)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}

	// 주입 경로 — 소비자가 직접 만드는 provider 와 admin.
	prov := NewClientCredentialsTokenProvider(func(context.Context) (*TokenSet, error) {
		return &TokenSet{AccessToken: dumpCanaryAccess, RefreshToken: dumpCanaryRefresh, ExpiresIn: 300}, nil
	}, 0)
	injected, err := NewAdminClient(ctx, cfg, prov)
	if err != nil {
		t.Fatalf("injected admin: %v", err)
	}

	// 오류 타입 — 실제 실패 호출에서 얻는다(원인 사슬이 요청 본문의 비밀을 쥔다).
	bad, err := New(Config{ServerURL: srv.URL, Realm: "bad", ClientID: "c", ClientSecret: dumpCanarySecret})
	if err != nil {
		t.Fatal(err)
	}
	_, authErr := bad.Auth.ClientCredentialsToken(ctx)
	_, valErr := c.Auth.Validate(ctx, dumpCanaryGarbage)
	_, adminErr := injected.Users.Get(ctx, "missing")
	down, err := New(Config{ServerURL: "http://127.0.0.1:1", Realm: "r", ClientID: "c", ClientSecret: dumpCanarySecret})
	if err != nil {
		t.Fatal(err)
	}
	// TransportError 는 postForm 경로(introspect·logout)에서 난다 — client-credentials 는 oauth2 를 거쳐 AuthError 다.
	_, transportErr := down.Auth.Introspect(ctx, dumpCanaryAccess)
	_, cfgErr := New(Config{})
	for name, e := range map[string]error{"auth": authErr, "validation": valErr, "admin": adminErr, "transport": transportErr, "config": cfgErr} {
		if e == nil {
			t.Fatalf("%s 오류 뿌리를 못 만들었다 — 가짜 IdP 가 실패를 안 냈다", name)
		}
	}

	roots := []dumpRoot{
		{"New", c}, {"ClientCredentialsToken", ts}, {"CreateAuthorizationRequest", ar},
		{"Introspect", ir}, {"Validate", vt}, {"NewClientCredentialsTokenProvider", prov},
		{"NewAdminClient", injected}, {"AuthError", authErr}, {"TokenValidationError", valErr},
		{"AdminError", adminErr}, {"TransportError", transportErr}, {"ConfigError", cfgErr},
	}
	canaries := []string{dumpCanarySecret, dumpCanaryAccess, dumpCanaryRefresh, dumpCanaryID,
		dumpCanaryGarbage, ar.CodeVerifier, raw}
	return roots, canaries
}

var dumpOwnPkg = reflect.TypeOf(Config{}).PkgPath()

func dumpIsOwn(t reflect.Type) bool { return t.PkgPath() == dumpOwnPkg && t.Name() != "" }

var dumpLockTypes = map[reflect.Type]bool{
	reflect.TypeOf(sync.Mutex{}): true, reflect.TypeOf(sync.RWMutex{}): true,
	reflect.TypeOf(singleflight.Group{}): true,
}

// 잠금을 품은 타입의 **값**은 `go vet`(copylocks)이 복사를 막으므로 소비자가 쥘 수 없다 — 포인터만 잰다.
func dumpHoldsLock(t reflect.Type) bool {
	if dumpLockTypes[t] {
		return true
	}
	if t.Kind() != reflect.Struct {
		return false
	}
	for i := 0; i < t.NumField(); i++ {
		if dumpHoldsLock(t.Field(i).Type) {
			return true
		}
	}
	return false
}

type dumpWalker struct {
	t        *testing.T
	canaries []string
	seen     map[uintptr]bool
	types    map[string]bool
}

// 비공개 필드도 읽는다 — fmt 가 바로 그 필드를 찍기 때문이다.
func dumpExpose(v reflect.Value) reflect.Value {
	if v.CanInterface() || !v.CanAddr() {
		return v
	}
	return reflect.NewAt(v.Type(), unsafe.Pointer(v.UnsafeAddr())).Elem()
}

func (w *dumpWalker) visit(v reflect.Value, path string) {
	switch v.Kind() {
	case reflect.Pointer:
		if v.IsNil() || w.seen[v.Pointer()] {
			return
		}
		w.seen[v.Pointer()] = true
		if dumpIsOwn(v.Type().Elem()) {
			w.render(v, path)
		}
		w.visit(v.Elem(), path)
	case reflect.Interface:
		if !v.IsNil() {
			w.visit(v.Elem(), path)
		}
	case reflect.Struct:
		if !dumpIsOwn(v.Type()) {
			return
		}
		if !v.CanAddr() {
			cp := reflect.New(v.Type()).Elem()
			cp.Set(v)
			v = cp
		}
		if !dumpHoldsLock(v.Type()) {
			w.render(v, path+"(값)")
		}
		for i := 0; i < v.NumField(); i++ {
			w.visit(dumpExpose(v.Field(i)), path+"."+v.Type().Field(i).Name)
		}
	case reflect.Slice, reflect.Array:
		for i := 0; i < v.Len(); i++ {
			w.visit(dumpExpose(v.Index(i)), path)
		}
	case reflect.Map:
		it := v.MapRange()
		for it.Next() {
			w.visit(it.Value(), path)
		}
	}
}

func (w *dumpWalker) render(v reflect.Value, path string) {
	w.t.Helper()
	if !v.CanInterface() {
		w.t.Fatalf("%s: 값을 꺼낼 수 없다 — 걷기가 이 자리를 못 잰다(%s)", path, v.Type())
	}
	base := v.Type()
	if base.Kind() == reflect.Pointer {
		base = base.Elem()
	}
	w.types[base.Name()] = true
	x := v.Interface()
	outs := map[string]string{}
	for _, verb := range []string{"%v", "%+v", "%#v", "%s", "%q"} {
		outs[verb] = fmt.Sprintf(verb, x)
	}
	var text, js bytes.Buffer
	slog.New(slog.NewTextHandler(&text, nil)).Info("m", "v", x)
	slog.New(slog.NewJSONHandler(&js, nil)).Info("m", "v", x)
	outs["slog.Text"], outs["slog.JSON"] = text.String(), js.String()
	for how, out := range outs {
		for _, c := range w.canaries {
			if strings.Contains(out, c) {
				w.t.Errorf("%s [%s] %s: 비밀이 원문으로 찍혔다(%.24s…)", path, v.Type(), how, c)
			}
		}
	}
}

// 이 패키지 비테스트 소스의 구조체 타입 전수 — 손 목록이 아니라 트리에서 파생한다.
func dumpDeclaredStructs(t *testing.T) []string {
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
			gd, ok := d.(*ast.GenDecl)
			if !ok || gd.Tok != token.TYPE {
				continue
			}
			for _, s := range gd.Specs {
				ts := s.(*ast.TypeSpec)
				if _, ok := ts.Type.(*ast.StructType); ok {
					out = append(out, ts.Name.Name)
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

func TestReachableObjectsDoNotRenderSecrets(t *testing.T) {
	roots, canaries := dumpRoots(t)
	w := &dumpWalker{t: t, canaries: canaries, seen: map[uintptr]bool{}, types: map[string]bool{}}
	for _, r := range roots {
		w.visit(reflect.ValueOf(r.v), r.name)
	}

	declared := dumpDeclaredStructs(t)
	if len(declared) == 0 {
		t.Fatal("구조체 선언을 하나도 못 찾았다 — 파생이 공허하다")
	}
	for _, name := range declared {
		reason, exempt := dumpWalkExempt[name]
		switch {
		case w.types[name] && exempt:
			t.Errorf("%s: 걷기에 닿는데 면제 표에도 있다 — 면제를 지워라(%s)", name, reason)
		case !w.types[name] && !exempt:
			t.Errorf("%s: 공개 API 뿌리에서 닿지 않는 구조체다 — 그 타입을 만드는 경로를 뿌리에 더하거나, 이유와 함께 면제하라", name)
		}
	}
	for name := range dumpWalkExempt {
		if !slices.Contains(declared, name) {
			t.Errorf("%s: 면제 표에 있지만 선언이 없다 — 낡은 면제다", name)
		}
	}
}
