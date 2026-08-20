package keycloak

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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
