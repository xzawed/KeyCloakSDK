package keycloak

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Nerzal/gocloak/v13"
)

func TestNewAdminClientRequiresSecret(t *testing.T) {
	_, err := newAdminClient(context.Background(),
		Config{ServerURL: "https://kc", Realm: "r", ClientID: "c"}.withDefaults())
	var ce *ConfigError
	if !errors.As(err, &ce) {
		t.Fatalf("missing clientSecret must yield *ConfigError, got %v", err)
	}
}

func TestToSDKError(t *testing.T) {
	// *gocloak.APIError → *AdminError, matching sentinels.
	for status, sentinel := range map[int]error{404: ErrNotFound, 409: ErrConflict, 403: ErrForbidden} {
		err := toSDKError(&gocloak.APIError{Code: status, Message: "x"})
		if !errors.Is(err, sentinel) {
			t.Errorf("status %d must match its sentinel", status)
		}
		var ae *AdminError
		if !errors.As(err, &ae) || ae.StatusCode != status {
			t.Errorf("status %d: errors.As → *AdminError{%d}", status, status)
		}
	}
	// non-APIError → *TransportError.
	var te *TransportError
	if !errors.As(toSDKError(errors.New("boom")), &te) {
		t.Fatal("non-API error must become *TransportError")
	}
	// gocloak wraps network failures in *APIError with Code 0 → *TransportError, not AdminError.
	err := toSDKError(&gocloak.APIError{Code: 0, Message: "dial tcp: connection refused"})
	var te2 *TransportError
	if !errors.As(err, &te2) {
		t.Fatalf("Code-0 APIError (no HTTP response) must become *TransportError, got %T", err)
	}
	var ae *AdminError
	if errors.As(err, &ae) {
		t.Fatal("Code-0 APIError must NOT be an *AdminError (HTTP 0 is nonsensical)")
	}
}

func TestCallRunWrapErrors(t *testing.T) {
	_, err := call(func() (int, error) { return 0, &gocloak.APIError{Code: 404} })
	if !errors.Is(err, ErrNotFound) {
		t.Fatal("call must convert APIError via toSDKError")
	}
	if err := run(func() error { return &gocloak.APIError{Code: 409} }); !errors.Is(err, ErrConflict) {
		t.Fatal("run must convert APIError via toSDKError")
	}
	if _, err := call(func() (int, error) { return 5, nil }); err != nil {
		t.Fatal("call must pass through success")
	}
}

// staticToken은 이 파일 전용 TokenProvider 스텁이다. 실제 grant를 태우지 않는 이유는
// UpdateRealmRole이 베어러 **문자열**을 인자로 받기 때문 — 로그인 왕복이 필요 없다.
type staticToken string

func (s staticToken) Token(context.Context) (string, error) { return string(s), nil }

// ⚠️ **이 테스트가 없으면 `.claude/rules/go.md`가 가장 길게 경고하는 게차를 아무도 못 잡는다.**
// gocloak의 UpdateRealmRole은 경로를 `name` 인자에서 만들고 body를 그대로 보낸다. 그래서
// `role.Name = &name`을 주입하면 **rename이 조용한 no-op**이 된다 — 서버는 200을 주고
// 이름은 그대로다. Users·Clients·Groups는 반대로 body에 식별자를 주입해야 해서, 그 관용을
// Roles에 복사하는 것이 실제로 일어나는 회귀다.
//
// ⚠️ **경로만 단언하면 공허하다.** 경로에 옛 이름이 실리는 것은 gocloak이 `name` 인자로 이미
// 하는 일이고, 주입이 망가뜨리는 것은 **body** 다. 그래서 둘을 함께 본다(Rust의 같은 테스트도
// 경로와 body를 동시에 건다). 핸들러 기본값을 404로 두는 것도 같은 이유 — 아무 2xx나 돌려주면
// 경로가 틀려도 통과한다.
func TestRolesUpdateAddressesByCurrentNameAndCarriesNewNameInBody(t *testing.T) {
	const wantPath = "/admin/realms/it-realm/roles/old-role"
	var gotPath, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut || r.URL.Path != wantPath {
			w.WriteHeader(http.StatusNotFound) // 느슨한 매칭 금지
			return
		}
		b, _ := io.ReadAll(r.Body)
		gotPath, gotBody = r.URL.Path, string(b)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	a := &AdminClient{
		gc:      gocloak.NewClient(srv.URL),
		baseURL: strings.TrimRight(srv.URL, "/"),
		realm:   "it-realm",
		tp:      staticToken("test-token"),
	}
	a.Roles = &RolesResource{a: a}

	err := a.Roles.Update(context.Background(), "old-role",
		gocloak.Role{Name: gocloak.StringP("new-role")})
	if err != nil {
		t.Fatalf("Update must succeed against the current-name path: %v", err)
	}
	if gotPath != wantPath {
		t.Fatalf("주소는 **현재 이름**이어야 한다: want %q got %q", wantPath, gotPath)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(gotBody), &body); err != nil {
		t.Fatalf("body를 읽지 못했다(%v): %s", err, gotBody)
	}
	if body["name"] != "new-role" {
		t.Fatalf("body는 **새 이름**을 날라야 한다 — `role.Name = &name` 주입은 rename을 "+
			"조용한 no-op으로 만든다. got %v", body["name"])
	}
}

// admin 레인의 SSRF 하드닝. config.go의 CheckRedirect 주석은 「token/JWKS/**admin** 엔드포인트」를
// 덮는다고 적지만 그 정책은 Config.httpClient()에만 있었고 admin은 gocloak의 resty 클라이언트를
// 쓴다 — 즉 admin은 Go 기본값대로 3xx를 최대 10홉 따라갔고, LoginClient는 client_secret을 싣는다.
// 두 가지를 함께 단언한다: (a) 리다이렉트 표적에 도달하지 않는다 (b) 3xx가 성공으로 보고되지 않는다.
// (b)가 없으면 ErrUseLastResponse가 302 본문을 토큰으로 언마셜해 fail-open이 될 수 있다.
// admin 레인이 실제 API 호출에서도 fail-closed 인지 — 토큰 발급은 성공시키고 그 다음 PUT 만
// 3xx 로 답한다. `admin_realms.go` 의 raw PUT 은 이 파사드에서 유일하게 손으로 만든 요청이라
// resty 의 `IsError()`(= status > 399)를 물려받으면 3xx 를 성공으로 읽는다.
func TestAdminRawPutFailsClosedOnRedirect(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/protocol/openid-connect/token") {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"access_token":"tok","expires_in":300}`))
			return
		}
		http.Redirect(w, r, "/elsewhere", http.StatusFound)
	}))
	defer srv.Close()

	cfg := Config{ServerURL: srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s"}.withDefaults()
	a, err := newAdminClient(context.Background(), cfg)
	if err != nil {
		t.Fatalf("newAdminClient(토큰은 정상): %v", err)
	}
	err = a.Realms.Update(context.Background(), "r", gocloak.RealmRepresentation{})
	if err == nil {
		t.Fatal("raw PUT 이 302 를 성공으로 읽었다 — realm 이 안 바뀌었는데 nil 이다")
	}
}

// 302와 307을 함께 돈다. 실측(수정 전 RED)에서 **둘 다 표적에 도달했고 client_secret은 두 경우
// 모두 빈 문자열이었다** — 302는 Go가 POST→GET으로 바꾸며 본문을 버리고, 307도 resty의 본문이
// 재생되지 않았다. 그러므로 이 결함은 「자격증명 유출」이 아니라 **SSRF**다: SDK가 공격자가 고른
// URL(사내망일 수 있다)로 우리 전송 설정을 태워 요청을 보낸다. 관측된 메서드·시크릿을 실패
// 메시지에 함께 찍어, 다음 세션이 이 구분을 다시 재현할 수 있게 한다.
func TestAdminLaneDoesNotFollowRedirects(t *testing.T) {
	for _, tc := range []struct {
		name string
		code int
	}{
		{"302", http.StatusFound},
		{"307", http.StatusTemporaryRedirect},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var reachedInternal int32
			var gotMethod, gotSecret string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/internal" {
					atomic.AddInt32(&reachedInternal, 1)
					_ = r.ParseForm()
					gotMethod, gotSecret = r.Method, r.PostFormValue("client_secret")
					w.Header().Set("Content-Type", "application/json")
					_, _ = w.Write([]byte(`{"access_token":"attacker-token","expires_in":300}`))
					return
				}
				http.Redirect(w, r, "/internal", tc.code)
			}))
			defer srv.Close()

			cfg := Config{ServerURL: srv.URL, Realm: "r", ClientID: "c", ClientSecret: "s3cret"}.withDefaults()
			// newAdminClient는 끝에서 eager 인증을 한다. 3xx면 여기서 이미 실패해야 하고,
			// 혹시 구성이 통과하더라도 토큰 발급이 실패해야 한다 — 둘 중 어디서 막히든 fail-closed다.
			var tok string
			a, err := newAdminClient(context.Background(), cfg)
			if err == nil {
				tok, err = a.tp.Token(context.Background())
			}

			if n := atomic.LoadInt32(&reachedInternal); n != 0 {
				t.Fatalf("SSRF: admin 레인이 %d를 따라갔다(%d회) — 요청이 리다이렉트 표적에 도달했다"+
					"(표적이 받은 메서드=%q, client_secret=%q)", tc.code, n, gotMethod, gotSecret)
			}
			if err == nil {
				t.Fatalf("토큰 엔드포인트의 %d는 성공으로 보고되면 안 된다 — fail-open. got token %q",
					tc.code, tok)
			}
		})
	}
}
