# Keycloak Go SDK — 구현 계획 (WBS)

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development(권장) 또는 superpowers:executing-plans로 태스크 단위 구현. 스텝은 `- [ ]` 체크박스. 실행 방식: **WBS → Workflow 오케스트레이션 + AI 거버넌스(G1~G6) + 다중에이전트 어드버서리얼 리뷰 + Loops + 딥리서치**.

**Goal:** Java/Python/Node와 §4 계약에 동형인 Keycloak Go SDK를 `go/`에 구현한다 — 인증(OIDC)·관리(Admin) 파사드 + 자체 강화 JWT 검증, sync + `context.Context`, Go 모듈 배포 준비.

**Architecture:** `golang.org/x/oauth2`(auth 흐름)·`go-jose/v4`(강화 JWT)·`github.com/Nerzal/gocloak/v13`(admin)을 감싸는 파사드. 계층 `config → errors/tokens → tokenprovider → oidc → jwt → auth → admin → client`. `admin`은 `auth`를 모르고 `TokenProvider`로만 결합(기본은 gocloak client-credentials). 하위 타입은 파사드 뒤 은닉, 오류는 경계에서 SDK 타입으로 변환.

**Tech Stack:** Go 1.25+ · `x/oauth2` v0.36 · `go-jose/v4` v4.1.4 · `gocloak/v13` v13.9 · `x/sync/singleflight` · `testcontainers-go` v0.43 + `/modules/keycloak` · `testify` v1.11 · gofmt · go vet · golangci-lint.

## Global Constraints

[설계 스펙](../specs/2026-07-04-keycloak-go-sdk-design.md)에서 그대로 옮김. 모든 태스크에 암묵 적용.

- **배치**: 모노레포 `go/`(java/·python/·node/와 나란히). 모듈 `github.com/xzawed/KeyCloakSDK/go`, 패키지 `keycloak`, 배포 태그 `go/vX.Y.Z`.
- **런타임**: Go **1.25+** · sync + `context.Context`(모든 네트워크 메서드 첫 인자 `ctx`; `CreateAuthorizationRequest`만 순수 동기).
- **명명**: **no-stutter**(`keycloak.New`/`keycloak.Client`/`keycloak.Config`/`keycloak.TokenSet`). 값타입 `TokenSet`/`ValidatedToken`/`IntrospectionResult`. 오류 타입드 구조체 + 센티넬.
- **동형 계약**: [§4 언어중립계약](../specs/2026-07-02-keycloak-multilang-sdk-design.md). 참조: `java/`, `python/src/keycloak_sdk/`, `node/src/`.
- **보안 불변식**: 토큰/시크릿 **완전 마스킹**(`***`, 접두 노출 없음) · TLS 검증 기본 on(http만 완화) · JWT 강화(alg 핀·`none` 거부·`iss` 정확일치·`aud` 포함검사·클록스큐 기본 30s·**JWKS 재조회 DoS-safe**) · admin 타임아웃 주입.
- **결합 규칙**: `admin`은 `auth` 비의존 — `TokenProvider`가 유일 접착제. `Raw()` 탈출구.
- **테스트**: 단위(`go test` + `testify`, 네트워크 격리) + 통합(`testcontainers-go/modules/keycloak`, 실제 Keycloak 26.6, `java/keycloak-sdk/src/test/resources/it-realm-realm.json` 재사용). 커버리지 게이트(로직 파일 라인≥90/브랜치≥85 상당, 네트워크 경계 omit).
- **툴체인(하네스)**: Go 포터블 설치 `C:\Users\dirtc\tools\go`(1.26.4). 명령 프리픽스: `PATH="/c/Users/dirtc/tools/go/bin:$PATH" GOTOOLCHAIN=local go <cmd>` — `go/`에서 실행. CI는 setup-go.
- **커밋**: `git add -A && git commit`. 브랜치 `feature/go-sdk`(생성됨), PR로 main(사람 승인).
- **거버넌스**: 태스크마다 G1(빌드/vet)·G2(단위)·G3(커버리지)·G4(스펙리뷰)·G5(다중에이전트 리뷰)·G6(보안) 통과 후 커밋. 실패 시 Loops. verification-log-go 기록.
- **⚠️ 착수 전(Task 1) 딥리서치 재검증**: `x/oauth2`(clientcredentials·PKCE 옵션)·`go-jose/v4`(jwt 서브패키지 API)·`gocloak/v13`(Login/CRUD 시그니처·`APIError`)·`testcontainers-go/modules/keycloak`(realm import API)를 공식 문서/소스로 확인해 아래 코드의 정확한 호출을 확정한다.

## File Structure

- `go/go.mod`·`go/go.sum` — 모듈 `github.com/xzawed/KeyCloakSDK/go`, `go 1.24`. `go/.golangci.yml`·`go/.gitignore`(불필요 — 루트 .gitignore가 커버).
- `go/config.go` — `Config` + 검증(`New` 내부 `validate`).
- `go/errors.go` — 오류 계급(타입드 구조체 + 센티넬) + `mapHTTPError`.
- `go/tokens.go` — `TokenSet`/`ValidatedToken`/`IntrospectionResult` + 마스킹 + `tokenSetFromToken`.
- `go/masking.go` — `mask()` 유틸.
- `go/tokenprovider.go` — `TokenProvider` + `ClientCredentialsTokenProvider`(single-flight).
- `go/oidc.go` — 엔드포인트 조립(네트워크 없음).
- `go/jwt.go` — `Validator`(go-jose 강화 + DoS-safe JWKS). **보안 핵심**.
- `go/auth.go` — `AuthClient`(x/oauth2 래핑).
- `go/admin.go` + `admin_users.go`/`admin_clients.go`/`admin_realms.go`/`admin_roles.go`/`admin_groups.go` — `AdminClient` + `Raw()`. **⚠️ 단일 `package keycloak`(서브패키지 아님) — root↔admin 상호 참조로 인한 import 순환을 원천 차단**(Go는 패키지당 1개, 순환 금지). 파일은 `admin_` 접두로 그룹.
- `go/client.go` — `Client` 진입점.
- `go/example_test.go` — godoc 실행 예제.
- `go/internal/testsupport/` — `it-realm-realm.json` + 컨테이너 하네스.
- `go/*_test.go` — 각 파일 단위테스트.
- `.github/workflows/go-ci.yml`·`go-release.yml`.

## 태스크 순서/의존

1 스캐폴딩 → 2 config → 3 errors+tokens+masking → 4 tokenprovider → 5 oidc → 6 jwt → 7 auth → 8 admin → 9 client → 10 통합테스트 → 11 CI/release → 12 문서. (2~6 상호 독립성 높음; 7·8은 6·4 의존; 9는 7·8 의존.)

---

### Task 1: 스캐폴딩 (go/ 모듈)

**Files:** Create `go/go.mod`, `go/.golangci.yml`, `go/doc.go`

**Interfaces:** Produces: 빌드/테스트/린트 파이프라인. Consumes: 없음.

- [ ] **Step 1: 딥리서치 재검증** — 공식 소스/문서로 `x/oauth2`(clientcredentials.Config·oauth2.Config.AuthCodeURL/Exchange·GenerateVerifier/S256ChallengeOption/VerifierOption), `go-jose/v4`(`jose/jwt` ParseSigned·Claims), `gocloak/v13`(NewClient·LoginClient·CreateUser/GetUserByID/GetUsers/UpdateUser/DeleteUser·APIError), `testcontainers-go/modules/keycloak`(Run·WithRealmImportFile·GetAuthServerURL)의 현행 시그니처를 확인. 상이하면 아래 코드 갱신.
- [ ] **Step 2: `go/go.mod` 작성 + 의존성 추가**

```bash
cd go && go mod init github.com/xzawed/KeyCloakSDK/go
go get golang.org/x/oauth2@v0.36.0
go get github.com/go-jose/go-jose/v4@v4.1.4
go get github.com/Nerzal/gocloak/v13@v13.9.0
go get golang.org/x/sync/singleflight
go get github.com/stretchr/testify@v1.11.1
go get github.com/testcontainers/testcontainers-go@v0.43.0
go get github.com/testcontainers/testcontainers-go/modules/keycloak
```
`go.mod`에 `go 1.24` 지시가 들어가는지 확인(아니면 `go mod edit -go=1.24`).

- [ ] **Step 3: `go/doc.go`(패키지 doc) + `go/.golangci.yml` 작성**

```go
// Package keycloak is an idiomatic Go SDK for Keycloak — OIDC authentication
// and Admin REST API — isomorphic with the Java/Python/Node SDKs.
package keycloak
```

```yaml
# go/.golangci.yml
version: "2"
linters:
  enable:
    - govet
    - staticcheck
    - errcheck
    - ineffassign
    - unused
    - gosec        # 보안 린터
```

- [ ] **Step 4: 검증** — `cd go && go build ./... && go vet ./... && gofmt -l .`
  Expected: 빌드 성공(빈 패키지), vet 통과, gofmt 출력 없음.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(go): 스캐폴딩 — go.mod·의존성·golangci-lint (WBS 1)"`

---

### Task 2: config.go (Config)

**Files:** Create `go/config.go`, `go/config_test.go`
**Interfaces:** Produces: `type Config struct{...}`, `func (c Config) validate() error`, `func (c Config) String() string`(마스킹). 참조: `node/src/config.ts`, `python/.../config.py`. Consumes: `ConfigError`(Task 3 — 순서상 Task 3 먼저 하거나 로컬 stub).

- [ ] **Step 1: 실패 테스트**

```go
package keycloak

import "testing"

func TestConfigValidateMissing(t *testing.T) {
	err := Config{ServerURL: "", Realm: "r", ClientID: "c"}.validate()
	if err == nil { t.Fatal("expected error for empty ServerURL") }
}

func TestConfigDefaultsAndMasking(t *testing.T) {
	c := Config{ServerURL: "https://kc/", Realm: "r", ClientID: "c", ClientSecret: "sekret"}
	c = c.withDefaults()
	if c.ServerURL != "https://kc" { t.Fatalf("trailing slash not stripped: %q", c.ServerURL) }
	if c.ClockSkew != 30 { t.Fatalf("ClockSkew default = %d, want 30", c.ClockSkew) }
	if got := c.String(); !contains(got, "***") || contains(got, "sekret") {
		t.Fatalf("String() must mask clientSecret: %q", got)
	}
}

func contains(s, sub string) bool { return len(sub) == 0 || (len(s) >= len(sub) && indexOf(s, sub) >= 0) }
func indexOf(s, sub string) int { for i := 0; i+len(sub) <= len(s); i++ { if s[i:i+len(sub)] == sub { return i } }; return -1 }
```

- [ ] **Step 2: 실패 확인** — `cd go && go test ./ -run TestConfig` → FAIL(빌드 실패: Config 미정의)
- [ ] **Step 3: 구현**

```go
package keycloak

import (
	"fmt"
	"strings"
)

// Config is immutable configuration for the SDK. Build it as a struct literal
// and pass to New, which validates it.
type Config struct {
	ServerURL      string
	Realm          string
	ClientID       string
	ClientSecret   string
	Scopes         []string
	ConnectTimeout int64 // ms; default 10000
	ReadTimeout    int64 // ms; default 30000
	ClockSkew      int64 // seconds; default 30
}

func (c Config) validate() error {
	for name, v := range map[string]string{"ServerURL": c.ServerURL, "Realm": c.Realm, "ClientID": c.ClientID} {
		if strings.TrimSpace(v) == "" {
			return &ConfigError{Msg: "missing required config: " + name}
		}
	}
	return nil
}

func (c Config) withDefaults() Config {
	c.ServerURL = strings.TrimRight(c.ServerURL, "/")
	if c.ConnectTimeout == 0 { c.ConnectTimeout = 10000 }
	if c.ReadTimeout == 0 { c.ReadTimeout = 30000 }
	if c.ClockSkew == 0 { c.ClockSkew = 30 }
	return c
}

// String masks the client secret so config is never logged in plaintext.
func (c Config) String() string {
	return fmt.Sprintf("Config{ServerURL:%q, Realm:%q, ClientID:%q, ClientSecret:%s, Scopes:%v}",
		c.ServerURL, c.Realm, c.ClientID, mask(c.ClientSecret), c.Scopes)
}
```
(`validate`의 map 반복은 순서 비결정적이나 첫 누락에서 반환 — 테스트는 존재만 확인. `ConfigError`는 Task 3에서 정의; Task 3을 먼저 구현하거나 최소 stub.)

- [ ] **Step 4: 통과 확인** — 동일 명령 → PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(go): Config + 검증 + 마스킹 String (WBS 2)"`

---

### Task 3: errors.go + tokens.go + masking.go (핵심 타입)

**Files:** Create `go/masking.go`,`errors.go`,`tokens.go` + `masking_test.go`,`errors_test.go`,`tokens_test.go`
**Interfaces:** Produces: `func mask(string) string`; 오류 타입 `ConfigError`/`AuthError`/`TokenValidationError`/`AdminError`/`TransportError`(전부 공개 — admin 서브패키지 소비), 센티넬 `ErrNotFound`/`ErrConflict`/`ErrForbidden`, `AdminError.Is()`로 상태코드↔센티넬 매칭; `TokenSet`/`ValidatedToken`/`IntrospectionResult`, `func tokenSetFromToken(*oauth2.Token) *TokenSet`. 참조: Node `errors.ts`/`tokens.ts`, Python `exceptions.py`/`tokens.py`.

- [ ] **Step 1: 실패 테스트**

```go
// masking_test.go
package keycloak
import "testing"
func TestMask(t *testing.T) {
	if mask("supersecret") != "***" { t.Fatal("must be fully opaque") }
	if mask("") != "***" { t.Fatal("empty also masked") }
}
```

```go
// errors_test.go
package keycloak
import ("errors"; "testing")
func TestAdminErrorSentinels(t *testing.T) {
	if err := error(&AdminError{StatusCode: 404}); !errors.Is(err, ErrNotFound) { t.Fatal("404 → ErrNotFound") }
	if err := error(&AdminError{StatusCode: 409}); !errors.Is(err, ErrConflict) { t.Fatal("409 → ErrConflict") }
	if err := error(&AdminError{StatusCode: 403}); !errors.Is(err, ErrForbidden) { t.Fatal("403 → ErrForbidden") }
	var ae *AdminError
	err := error(&AdminError{StatusCode: 404, Msg: "gone"})
	if !errors.As(err, &ae) || ae.StatusCode != 404 { t.Fatal("errors.As → *AdminError{404}") }
}
```

```go
// tokens_test.go
package keycloak
import ("strings"; "testing"; "time"; "golang.org/x/oauth2")
func TestTokenSetFromTokenAndMask(t *testing.T) {
	tok := (&oauth2.Token{AccessToken: "AT", TokenType: "Bearer", RefreshToken: "RT",
		Expiry: time.Unix(1000300, 0)}).WithExtra(map[string]any{"expires_in": float64(300), "id_token": "IDT", "scope": "openid"})
	ts := tokenSetFromToken(tok)
	if ts.AccessToken != "AT" || ts.IDToken != "IDT" || ts.ExpiresIn != 300 { t.Fatalf("mapping: %+v", ts) }
	if s := ts.String(); strings.Contains(s, "AT") || strings.Contains(s, "RT") || !strings.Contains(s, "***") {
		t.Fatalf("String must mask access+refresh: %q", s)
	}
}
```

- [ ] **Step 2: 실패 확인** → FAIL
- [ ] **Step 3: 구현**

```go
// masking.go
package keycloak
// mask returns a fully opaque placeholder, never exposing length or prefix.
func mask(string) string { return "***" }
```

```go
// errors.go
package keycloak
import ("errors"; "fmt")

var (
	ErrNotFound  = errors.New("keycloak: not found")
	ErrConflict  = errors.New("keycloak: conflict")
	ErrForbidden = errors.New("keycloak: forbidden")
)

type ConfigError struct{ Msg string }
func (e *ConfigError) Error() string { return "keycloak: " + e.Msg }

type AuthError struct{ Msg, OAuthError string; Cause error }
func (e *AuthError) Error() string { return "keycloak: auth: " + e.Msg }
func (e *AuthError) Unwrap() error { return e.Cause }

type TokenValidationError struct{ Msg string; Cause error }
func (e *TokenValidationError) Error() string { return "keycloak: token validation: " + e.Msg }
func (e *TokenValidationError) Unwrap() error { return e.Cause }

type AdminError struct{ StatusCode int; Msg string; Cause error }
func (e *AdminError) Error() string { return fmt.Sprintf("keycloak: admin: HTTP %d: %s", e.StatusCode, e.Msg) }
func (e *AdminError) Unwrap() error { return e.Cause }
func (e *AdminError) Is(target error) bool {
	switch target {
	case ErrNotFound:  return e.StatusCode == 404
	case ErrConflict:  return e.StatusCode == 409
	case ErrForbidden: return e.StatusCode == 403
	}
	return false
}

type TransportError struct{ Msg string; Cause error }
func (e *TransportError) Error() string { return "keycloak: transport: " + e.Msg }
func (e *TransportError) Unwrap() error { return e.Cause }
```
(admin 서브패키지는 `&AdminError{StatusCode: code, ...}`를 직접 생성한다 — 별도 매핑 헬퍼 불필요. `AdminError.Is()`가 상태코드↔센티넬을 매칭.)

```go
// tokens.go
package keycloak
import ("fmt"; "golang.org/x/oauth2")

type TokenSet struct {
	AccessToken  string
	TokenType    string
	ExpiresIn    int64
	ExpiresAt    int64 // epoch seconds; 0 if unknown
	RefreshToken string
	IDToken      string
	Scope        string
}

func (t *TokenSet) IsExpired(nowSec, skewSec int64) bool {
	if t.ExpiresAt == 0 { return true }
	return nowSec+skewSec >= t.ExpiresAt
}
func (t *TokenSet) String() string {
	return fmt.Sprintf("TokenSet{TokenType:%q, ExpiresIn:%d, AccessToken:%s, RefreshToken:%s}",
		t.TokenType, t.ExpiresIn, mask(t.AccessToken), mask(t.RefreshToken))
}

// tokenSetFromToken maps an x/oauth2 token (+ extras) to a TokenSet.
func tokenSetFromToken(tok *oauth2.Token) *TokenSet {
	ts := &TokenSet{AccessToken: tok.AccessToken, TokenType: tok.TokenType, RefreshToken: tok.RefreshToken}
	if !tok.Expiry.IsZero() { ts.ExpiresAt = tok.Expiry.Unix() }
	if v, ok := tok.Extra("expires_in").(float64); ok { ts.ExpiresIn = int64(v) }
	if v, ok := tok.Extra("id_token").(string); ok { ts.IDToken = v }
	if v, ok := tok.Extra("scope").(string); ok { ts.Scope = v }
	return ts
}

type ValidatedToken struct {
	Subject   string
	Audience  []string
	Issuer    string
	ExpiresAt int64
	IssuedAt  int64
	Claims    map[string]any
}

type IntrospectionResult struct {
	Active   bool
	Username string
	ClientID string
	Claims   map[string]any
}
```

- [ ] **Step 4: 통과 확인** → PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(go): masking·오류 계급(타입드+센티넬)·값타입(TokenSet/ValidatedToken) (WBS 3)"`

---

### Task 4: tokenprovider.go

**Files:** Create `go/tokenprovider.go`, `go/tokenprovider_test.go`
**Interfaces:** Produces(공개 — admin 서브패키지가 소비): `type TokenProvider interface { Token(context.Context) (string, error) }`, `type TokenSource func(context.Context) (*TokenSet, error)`, `func NewClientCredentialsTokenProvider(src TokenSource, skewSec int64) TokenProvider`(캐시+single-flight, 비공개 `*clientCredentialsProvider` 반환). 참조: Node `token-provider.ts`.

- [ ] **Step 1~5**: 실패테스트(만료 전 캐시 재사용·동시호출 single-flight로 src 1회만·만료 시 재발급) → 구현 → 통과 → 커밋 `feat(go): TokenProvider + client-credentials(single-flight) (WBS 4)`.
  구현 핵심:

```go
package keycloak
import ("context"; "sync"; "time"; "golang.org/x/sync/singleflight")

// TokenProvider supplies access tokens to the admin facade (the only glue
// between auth and admin). Consumers may inject a custom implementation.
type TokenProvider interface { Token(ctx context.Context) (string, error) }

// TokenSource obtains a fresh token set (e.g. via client-credentials).
type TokenSource func(ctx context.Context) (*TokenSet, error)

type clientCredentialsProvider struct {
	src      TokenSource
	skewSec  int64
	group    singleflight.Group
	mu       sync.Mutex
	token    string
	expireAt int64 // epoch sec (skew 반영)
}

// NewClientCredentialsTokenProvider caches a token and refreshes it before
// expiry, collapsing concurrent requests via single-flight.
func NewClientCredentialsTokenProvider(src TokenSource, skewSec int64) TokenProvider {
	return &clientCredentialsProvider{src: src, skewSec: skewSec}
}

func (p *clientCredentialsProvider) Token(ctx context.Context) (string, error) {
	p.mu.Lock()
	if p.token != "" && time.Now().Unix() < p.expireAt { t := p.token; p.mu.Unlock(); return t, nil }
	p.mu.Unlock()
	v, err, _ := p.group.Do("token", func() (any, error) {
		ts, err := p.src(ctx)
		if err != nil { return nil, err }
		p.mu.Lock()
		p.token = ts.AccessToken
		p.expireAt = time.Now().Unix() + max64(0, ts.ExpiresIn-p.skewSec)
		p.mu.Unlock()
		return ts.AccessToken, nil
	})
	if err != nil { return "", err }
	return v.(string), nil
}

func max64(a, b int64) int64 { if a > b { return a }; return b }
```

---

### Task 5: oidc.go

**Files:** Create `go/oidc.go`, `go/oidc_test.go`
**Interfaces:** Produces: `type endpoints struct { issuer, token, authorization, introspection, endSession, jwks string }`, `func oidcEndpoints(cfg Config) endpoints`(네트워크 없이 `{ServerURL}/realms/{Realm}` 조립). 참조: Node `oidc-metadata.ts`.
- [ ] 실패테스트(issuer==`{ServerURL}/realms/{Realm}`, jwks==`{issuer}/protocol/openid-connect/certs`) → 구현(문자열 조립) → 통과 → 커밋 `feat(go): OIDC 엔드포인트 조립 (WBS 5)`.

```go
package keycloak
type endpoints struct{ issuer, token, authorization, introspection, endSession, jwks string }
func oidcEndpoints(cfg Config) endpoints {
	issuer := cfg.ServerURL + "/realms/" + cfg.Realm
	base := issuer + "/protocol/openid-connect"
	return endpoints{issuer, base + "/token", base + "/auth", base + "/token/introspect", base + "/logout", base + "/certs"}
}
```

---

### Task 6: jwt.go (Validator — 🔴 보안 핵심)

**Files:** Create `go/jwt.go`, `go/jwt_test.go`
**Interfaces:** Produces: `type Validator struct{...}`, `func newValidator(opts validatorOptions) *Validator`, `func (v *Validator) Validate(ctx context.Context, token string) (*ValidatedToken, error)`. `validatorOptions{ jwksURI, issuer, audience string; allowedAlgs []jose.SignatureAlgorithm; clockSkewSec int64; httpClient *http.Client }`. Consumes: `go-jose/v4`(`jose`+`jose/jwt`), `TokenValidationError`(T3). 참조: Node `jwt.ts`, Python `jwt.py`(DoS-safe `_load_jwks`).

- [ ] **Step 1: 실패 테스트** — go-jose로 테스트 RSA 키쌍 생성해 JWKS 서버(httptest) + 서명 토큰 발급 후: 정상 RS256 통과(subject/aud/iss/exp/iat 반환), `alg=none`/미서명 거부, 잘못된 iss 거부, `aud=["client","realm-management"]`에 기대 aud "client" 포함 → 통과(포함검사), 기대 aud 미포함 → `TokenValidationError`, exp 초과(+skew 밖) 거부. DoS-safe: 서명 위조는 JWKS 재조회를 유발하지 않고, kid 미해결만 재조회하며 재조회는 rate-limit.
- [ ] **Step 2: 실패 확인** → FAIL
- [ ] **Step 3: 구현**(골격 — 정확한 go-jose/v4 API는 Task 1 딥리서치로 확정)

```go
package keycloak
import (
	"context"; "encoding/json"; "fmt"; "io"; "net/http"; "sync"; "time"
	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

type validatorOptions struct {
	jwksURI, issuer, audience string
	allowedAlgs               []jose.SignatureAlgorithm
	clockSkewSec              int64
	httpClient                *http.Client
}

type Validator struct {
	opts        validatorOptions
	mu          sync.Mutex
	jwks        *jose.JSONWebKeySet
	forcedAt    time.Time
	minRefetch  time.Duration // DoS 증폭 상한(예: 60s)
}

func newValidator(opts validatorOptions) *Validator {
	if opts.httpClient == nil { opts.httpClient = http.DefaultClient }
	return &Validator{opts: opts, minRefetch: 60 * time.Second}
}

func (v *Validator) Validate(ctx context.Context, token string) (*ValidatedToken, error) {
	// alg 핀 — ParseSigned에 허용 알고리즘만 전달, none/미서명 거부.
	parsed, err := jwt.ParseSigned(token, v.opts.allowedAlgs)
	if err != nil { return nil, &TokenValidationError{Msg: "parse: " + err.Error(), Cause: err} }
	kid := parsed.Headers[0].KeyID

	key, err := v.resolveKey(ctx, kid) // 캐시 → kid 미해결 시에만 rate-limited 재조회
	if err != nil { return nil, &TokenValidationError{Msg: "key: " + err.Error(), Cause: err} }

	var claims jwt.Claims
	var all map[string]any
	if err := parsed.Claims(key, &claims, &all); err != nil { // 서명 검증(위조는 여기서 실패, 재조회 안 함)
		return nil, &TokenValidationError{Msg: "signature: " + err.Error(), Cause: err}
	}
	// iss 정확일치 + exp/nbf(+skew). aud는 포함검사로 별도.
	if err := claims.ValidateWithLeeway(jwt.Expected{Issuer: v.opts.issuer, Time: time.Now()},
		time.Duration(v.opts.clockSkewSec)*time.Second); err != nil {
		return nil, &TokenValidationError{Msg: "claims: " + err.Error(), Cause: err}
	}
	if !audienceContains(claims.Audience, v.opts.audience) {
		return nil, &TokenValidationError{Msg: "audience does not include " + v.opts.audience}
	}
	return &ValidatedToken{
		Subject: claims.Subject, Audience: []string(claims.Audience), Issuer: claims.Issuer,
		ExpiresAt: int64(*claims.Expiry), IssuedAt: int64(*claims.IssuedAt), Claims: all,
	}, nil
}

func audienceContains(aud jwt.Audience, want string) bool {
	for _, a := range aud { if a == want { return true } }
	return false
}

// resolveKey: 캐시된 JWKS에서 kid 조회, 없으면 rate-limited 1회 재조회(DoS-safe).
func (v *Validator) resolveKey(ctx context.Context, kid string) (any, error) {
	if k := v.lookup(kid); k != nil { return k, nil }
	v.mu.Lock()
	if time.Since(v.forcedAt) >= v.minRefetch || v.jwks == nil {
		v.forcedAt = time.Now()
		v.mu.Unlock()
		if err := v.fetch(ctx); err != nil { return nil, err }
	} else { v.mu.Unlock() }
	if k := v.lookup(kid); k != nil { return k, nil }
	return nil, fmt.Errorf("no key for kid %q", kid)
}

func (v *Validator) lookup(kid string) any {
	v.mu.Lock(); defer v.mu.Unlock()
	if v.jwks == nil { return nil }
	if keys := v.jwks.Key(kid); len(keys) > 0 { return keys[0].Key }
	return nil
}

func (v *Validator) fetch(ctx context.Context) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, v.opts.jwksURI, nil)
	resp, err := v.opts.httpClient.Do(req)
	if err != nil { return err }
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil { return err }
	var ks jose.JSONWebKeySet
	if err := json.Unmarshal(body, &ks); err != nil { return err }
	v.mu.Lock(); v.jwks = &ks; v.mu.Unlock()
	return nil
}
```
> DoS-safe: 서명 위조는 `resolveKey`가 캐시에서 kid를 해결(정상 kid)하면 재조회 없이 `Claims` 검증에서 실패한다. kid 미해결(키 회전)만 재조회하고, `minRefetch`로 rate-limit해 kid 무작위 위조의 IdP 폭주를 막는다. 이 동작을 단위테스트로 고정.
- [ ] **Step 4: 통과 확인** → PASS(모든 강화 케이스)
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(go): Validator — go-jose 자체 강화(alg핀·iss·aud포함·클록스큐·DoS-safe JWKS) (WBS 6)"`

---

### Task 7: auth.go (AuthClient — x/oauth2 래핑)

**Files:** Create `go/auth.go`, `go/auth_test.go`
**Interfaces:** Produces: `type AuthClient struct{...}`, `func newAuthClient(cfg Config, v *Validator) *AuthClient` + 메서드 `CreateAuthorizationRequest(redirectURI string) AuthorizationRequest`(동기) · `ExchangeCode(ctx, code, redirectURI, codeVerifier, nonce string) (*TokenSet, error)` · `ClientCredentialsToken(ctx) (*TokenSet, error)` · `Refresh(ctx, refreshToken string) (*TokenSet, error)` · `Introspect(ctx, token string) (*IntrospectionResult, error)` · `Logout(ctx, refreshToken string) error` · `Validate(ctx, accessToken string) (*ValidatedToken, error)`. Consumes: `x/oauth2`, `oidcEndpoints`(T5), `Validator`(T6), `tokenSetFromToken`(T3), `AuthError`(T3). 참조: Node `auth.ts`.

- [ ] **Step 1~5**: 단위테스트는 httptest 서버로 토큰/introspect/logout 엔드포인트를 목킹(네트워크 격리)해 매핑·PKCE·오류변환 검증 → 구현 → 통과 → 커밋.
  구현 핵심(x/oauth2 — Task 1 딥리서치로 정확한 심볼 확정):

```go
package keycloak
import (
	"context"; "net/http"; "net/url"; "strings"
	"golang.org/x/oauth2"; "golang.org/x/oauth2/clientcredentials"
)

type AuthClient struct {
	cfg  Config
	ep   endpoints
	val  *Validator
	http *http.Client
}

func newAuthClient(cfg Config, v *Validator) *AuthClient {
	return &AuthClient{cfg: cfg, ep: oidcEndpoints(cfg), val: v, http: &http.Client{}}
}

func (a *AuthClient) CreateAuthorizationRequest(redirectURI string) AuthorizationRequest {
	verifier := oauth2.GenerateVerifier()
	state := oauth2.GenerateVerifier() // 난수 재사용(base64url); 또는 crypto/rand
	nonce := oauth2.GenerateVerifier()
	scope := "openid"
	if len(a.cfg.Scopes) > 0 { scope = strings.Join(a.cfg.Scopes, " ") }
	conf := a.codeConfig(redirectURI, scope)
	u := conf.AuthCodeURL(state, oauth2.S256ChallengeOption(verifier), oauth2.SetAuthURLParam("nonce", nonce))
	return AuthorizationRequest{URL: u, CodeVerifier: verifier, State: state, Nonce: nonce}
}

func (a *AuthClient) ClientCredentialsToken(ctx context.Context) (*TokenSet, error) {
	cc := &clientcredentials.Config{ClientID: a.cfg.ClientID, ClientSecret: a.cfg.ClientSecret,
		TokenURL: a.ep.token, Scopes: a.cfg.Scopes, AuthStyle: oauth2.AuthStyleInParams}
	tok, err := cc.Token(a.withHTTP(ctx))
	if err != nil { return nil, &AuthError{Msg: "client credentials", OAuthError: oauthErr(err), Cause: err} }
	return tokenSetFromToken(tok), nil
}

func (a *AuthClient) Validate(ctx context.Context, accessToken string) (*ValidatedToken, error) {
	return a.val.Validate(ctx, accessToken)
}
// ExchangeCode/Refresh/Introspect/Logout — 동일 패턴(x/oauth2 대응 + 수동 POST). Introspect/Logout은
// a.ep.introspection/a.ep.endSession에 client 인증 form POST 후 응답 매핑/상태검사.
// codeConfig/withHTTP/oauthErr 헬퍼는 구현부에서 정의.
```
> ⚠️ x/oauth2의 정확한 옵션/시그니처(`GenerateVerifier`/`S256ChallengeOption`/`VerifierOption`/`clientcredentials.Config`)는 **Task 1 딥리서치로 확정**. auth.go는 네트워크 경계 → 커버리지 omit, 로직은 매핑 헬퍼로 분리해 httptest로 단위검증, 실호출은 통합테스트(Task 10). `Introspect`는 x/oauth2 미제공이라 수동 POST(Node와 동일).
- [ ] **Commit**: `feat(go): AuthClient — PKCE/client-credentials/exchangeCode/refresh/introspect/logout/validate (WBS 7)`

---

### Task 8: admin (AdminClient + 리소스 + Raw()) — 단일 `package keycloak`

**Files:** Create `go/admin.go`,`admin_users.go`,`admin_clients.go`,`admin_realms.go`,`admin_roles.go`,`admin_groups.go` + `go/admin_test.go`
**Interfaces:** Produces: `type AdminClient struct { Users *UsersResource; Clients *ClientsResource; Realms *RealmsResource; Roles *RolesResource; Groups *GroupsResource }`, `func newAdminClient(ctx context.Context, cfg Config) (*AdminClient, error)`(비공개 — `Client.Admin`이 호출; gocloak 생성 + client-credentials + 타임아웃 주입), `func (a *AdminClient) Raw() *gocloak.GoCloak`, `func (a *AdminClient) Close() error`. 각 리소스는 `Create/Get/Search/Update/Delete` 등 Java 대응 동형. Consumes: `gocloak/v13`, 같은 패키지의 `Config`/오류/`TokenProvider`. 참조: Java `AdminClient`+resources, Node `admin/`.

> ⚠️ **단일 패키지**: admin은 root와 같은 `package keycloak`다(서브패키지 아님) — `Client.Admin`이 `*AdminClient`를 반환하는데 admin이 root 타입을 쓰므로 서브패키지면 import 순환. 같은 패키지라 `Config`·`AdminError`·`TokenProvider` 등을 접두 없이 직접 사용.

- [ ] **Step 1~5**: 단위테스트는 gocloak을 좁은 인터페이스로 추상화하거나 httptest로 (a)타임아웃 주입, (b)오류 경계 변환(404→`ErrNotFound`), (c)리소스 위임 검증 → 구현 → 통과 → 커밋.
  구현 핵심:

```go
// admin.go
package keycloak
import (
	"context"; "errors"; "time"
	"github.com/Nerzal/gocloak/v13"
)

type AdminClient struct {
	gc    *gocloak.GoCloak
	realm string
	tp    TokenProvider
	Users *UsersResource
	// Clients/Realms/Roles/Groups ...
}

func newAdminClient(ctx context.Context, cfg Config) (*AdminClient, error) {
	if cfg.ClientSecret == "" {
		return nil, &ConfigError{Msg: "clientSecret is required for admin client-credentials"}
	}
	gc := gocloak.NewClient(cfg.ServerURL)
	gc.RestyClient().SetTimeout(time.Duration(cfg.ReadTimeout) * time.Millisecond)
	tp := NewClientCredentialsTokenProvider(func(ctx context.Context) (*TokenSet, error) {
		jwt, err := gc.LoginClient(ctx, cfg.ClientID, cfg.ClientSecret, cfg.Realm)
		if err != nil { return nil, toSDKError(err) }
		return &TokenSet{AccessToken: jwt.AccessToken, ExpiresIn: int64(jwt.ExpiresIn)}, nil
	}, cfg.ClockSkew)
	a := &AdminClient{gc: gc, realm: cfg.Realm, tp: tp}
	a.Users = &UsersResource{a}
	// ... 나머지 리소스
	return a, nil
}

func (a *AdminClient) Raw() *gocloak.GoCloak { return a.gc }
func (a *AdminClient) Close() error { return nil }
func (a *AdminClient) token(ctx context.Context) (string, error) { return a.tp.Token(ctx) }

// call: gocloak 호출을 실행하고 *gocloak.APIError를 SDK 오류로 변환.
func call[T any](fn func() (T, error)) (T, error) {
	v, err := fn()
	if err != nil { return v, toSDKError(err) }
	return v, nil
}

// toSDKError: *gocloak.APIError(HTTP status) → *AdminError(센티넬 Is 매칭), 그 외 → *TransportError.
func toSDKError(err error) error {
	var apiErr *gocloak.APIError
	if errors.As(err, &apiErr) {
		return &AdminError{StatusCode: apiErr.Code, Msg: apiErr.Message, Cause: err}
	}
	return &TransportError{Msg: err.Error(), Cause: err}
}

// admin_users.go
type UsersResource struct{ a *AdminClient }
func (r *UsersResource) Create(ctx context.Context, rep gocloak.User) (string, error) {
	tok, err := r.a.token(ctx); if err != nil { return "", err }
	return call(func() (string, error) { return r.a.gc.CreateUser(ctx, tok, r.a.realm, rep) })
}
func (r *UsersResource) Get(ctx context.Context, id string) (*gocloak.User, error) {
	tok, err := r.a.token(ctx); if err != nil { return nil, err }
	return call(func() (*gocloak.User, error) { return r.a.gc.GetUserByID(ctx, tok, r.a.realm, id) })
}
func (r *UsersResource) Search(ctx context.Context, username string, first, max int) ([]*gocloak.User, error) {
	tok, err := r.a.token(ctx); if err != nil { return nil, err }
	p := gocloak.GetUsersParams{First: &first, Max: &max}
	if username != "" { p.Username = &username }
	return call(func() ([]*gocloak.User, error) { return r.a.gc.GetUsers(ctx, tok, r.a.realm, p) })
}
// Update/Delete 동형. clients/realms/roles/groups는 gocloak 대응 메서드로 동형 포팅
// (roles: GetRealmRole/CreateRealmRole/DeleteRealmRole; groups: CreateGroup/GetGroup(s)/DeleteGroup; realms: GetRealm/CreateRealm/DeleteRealm).
```
> gocloak API·`APIError.Code`·representation 메서드는 Task 1 딥리서치로 확정. admin/** 파일(admin*.go)은 네트워크 경계 → 커버리지 omit, 통합테스트로 검증.
- [ ] **Commit**: `feat(go): AdminClient + users/clients/realms/roles/groups + Raw() + 타임아웃·오류변환 (WBS 8)`

---

### Task 9: client.go (Client 통합 진입점)

**Files:** Create `go/client.go`, `go/client_test.go`
**Interfaces:** Produces: `type Client struct { Auth *AuthClient; ... }`, `func New(cfg Config) (*Client, error)`, `func (c *Client) Admin(ctx context.Context) (*AdminClient, error)`(지연·캐시·single-flight; `AdminClient`는 같은 패키지), `func (c *Client) Close() error`. Consumes: T2·T7·T8. 참조: Java `KeycloakClient`, Node `client.ts`.

- [ ] **Step 1~5**: 테스트(New가 config 검증·Auth 즉시 조립·Admin 지연 생성·clientSecret 없으면 Admin 에러·동시 Admin 호출 single-flight로 1회만·Close 정리) → 구현 → 통과 → 커밋. admin은 네트워크 경계라 테스트에서 gocloak 로그인 엔드포인트를 httptest로 목킹하거나 clientSecret 없는 경로(에러)만 단위검증하고 실생성은 통합테스트로.

```go
package keycloak
import (
	"context"; "sync"
	jose "github.com/go-jose/go-jose/v4"
	"golang.org/x/sync/singleflight"
)

type Client struct {
	cfg   Config
	Auth  *AuthClient
	mu    sync.Mutex
	admin *AdminClient
	group singleflight.Group
}

func New(cfg Config) (*Client, error) {
	if err := cfg.validate(); err != nil { return nil, err }
	cfg = cfg.withDefaults()
	ep := oidcEndpoints(cfg)
	v := newValidator(validatorOptions{jwksURI: ep.jwks, issuer: ep.issuer, audience: cfg.ClientID,
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256}, clockSkewSec: cfg.ClockSkew})
	return &Client{cfg: cfg, Auth: newAuthClient(cfg, v)}, nil
}

func (c *Client) Admin(ctx context.Context) (*AdminClient, error) {
	c.mu.Lock(); a := c.admin; c.mu.Unlock()
	if a != nil { return a, nil }
	v, err, _ := c.group.Do("admin", func() (any, error) { return newAdminClient(ctx, c.cfg) })
	if err != nil { return nil, err }
	a = v.(*AdminClient)
	c.mu.Lock(); c.admin = a; c.mu.Unlock()
	return a, nil
}

func (c *Client) Close() error {
	c.mu.Lock(); a := c.admin; c.mu.Unlock()
	if a != nil { return a.Close() }
	return nil
}
```
> 단일 패키지라 import 순환 없음(`Client.Admin`이 같은 패키지의 `newAdminClient`/`*AdminClient` 사용). `New`가 client-credentials 검증(clientSecret)을 트리거하지 않으므로 secret 없는 public 클라이언트도 `Auth`만 사용 가능(admin 접근 시에만 `*ConfigError`).
- [ ] **Commit**: `feat(go): Client 통합 진입점(Auth 즉시·Admin 지연·single-flight·Close) (WBS 9)`

---

### Task 10: 통합 테스트 (testcontainers-go + 실제 Keycloak)

**Files:** Create `go/integration_test.go`, `go/internal/testsupport/keycloak.go`, copy `go/internal/testsupport/it-realm-realm.json`
**Interfaces:** Consumes: 전 계층. 참조: Java `AuthFlowIT`/`AdminOpsIT`, Node `e2e.it.test.ts`.
- [ ] **Step 1: 하네스** — `testcontainers-go/modules/keycloak`의 `keycloak.Run(ctx, "quay.io/keycloak/keycloak:26.6", keycloak.WithRealmImportFile(".../it-realm-realm.json"))` → `GetAuthServerURL(ctx)`. `java/keycloak-sdk/src/test/resources/it-realm-realm.json`을 `go/internal/testsupport/`로 복사.
- [ ] **Step 2: E2E(Java/Python/Node 동일 시나리오)** — `//go:build integration` 태그. client-credentials 토큰 발급 → `Validate`(다중 aud=it-client 포함) → `Introspect` → user 생성/조회/검색/수정/삭제 → 삭제 후 조회 `errors.Is(err, keycloak.ErrNotFound)` → `Raw()` 접근. 토큰 마스킹 불변식도 검증.
- [ ] **Step 3: 실행** — `cd go && go test -tags=integration ./... -run TestE2E -v`(Docker 필요) → 전부 GREEN.
- [ ] **Step 4: Commit** — `test(go): testcontainers E2E(client-credentials·validate·introspect·admin CRUD·Raw) (WBS 10)`

---

### Task 11: CI + release 워크플로

**Files:** Create `.github/workflows/go-ci.yml`, `.github/workflows/go-release.yml`
- [ ] **Step 1: `go-ci.yml`** — `on: {push,pull_request}: paths: ['go/**','.github/workflows/go-ci.yml']`. job `build`(matrix Go 1.24·1.26): `cd go && go build ./... && go vet ./... && test -z "$(gofmt -l .)" && golangci-lint run && go test ./... -coverprofile=cover.out` + 커버리지 임계값 검사(네트워크 경계 파일 제외). job `integration`(ubuntu, Docker): `go test -tags=integration ./...`.
- [ ] **Step 2: `go-release.yml`** — `on: push: tags: ['go/v*']`. verify(vet+test) 통과 후: GitHub Release 생성 + `GOPROXY=proxy.golang.org GONOSUMCHECK=0 go list -m github.com/xzawed/KeyCloakSDK/go@${TAG}`로 프록시 워밍. 레지스트리 배포 없음(태그=릴리스). human-gated.
- [ ] **Step 3: 검증** — YAML 파싱·로컬 `go build`/`go vet`/`go test -short`. **Commit** `ci(go): go-ci(1.24/1.26 build+integration) + go-release(태그=릴리스, human-gated) (WBS 11)`.

---

### Task 12: 문서 · 거버넌스 로그

**Files:** Modify `docs/guides/getting-started.md`(Go 섹션 4블록), `README.md`, `CLAUDE.md`(구조·명령·gotchas), `docs/roadmap/language-support.md`(매트릭스 Go ✅), `CHANGELOG.md`(`(Go)` Added); Create `docs/governance/verification-log-go.md`
- [ ] **Step 1**: getting-started에 Go 4블록(요구 런타임 Go 1.24+·로컬 `go get github.com/xzawed/KeyCloakSDK/go`·배포후 동일·최소 예제 실제 API).
- [ ] **Step 2**: 로드맵 현황 매트릭스 Go 행 ✅(설계·구현·단위·통합·CI) + 🔒 배포(human-gated). README/CLAUDE 구조 트리·테스트 수·Go 툴체인 명령·Go gotchas(gocloak 토큰 per-call·APIError.Code·go-jose alg 핀·모듈 태그 배포) 갱신. CHANGELOG `(Go) keycloak-sdk 4번째 언어 추가`.
- [ ] **Step 3**: verification-log-go.md 신설(딥리서치·태스크별 게이트·Loops·다중에이전트 리뷰 이력). 링크·일관성 스윕.
- [ ] **Step 4: Commit** — `docs(go): getting-started Go 섹션 + 로드맵·README·CLAUDE·CHANGELOG·verification-log-go (WBS 12)`

---

## Self-Review (계획 ↔ 스펙 대조)

- **스펙 커버리지**: §3 의존성→T1(딥리서치)·T6·T7·T8 · §4 구조→T1~T9 · §5 계층/값타입/결합/오류→T2~T9 · §6 보안불변식→T3(마스킹)·T6(JWT)·T8(타임아웃) · §7 테스트→T2~T9 단위+T10 통합 · §8 빌드/CI/배포→T1·T11 · §9 문서→T12. 누락 없음.
- **플레이스홀더**: x/oauth2·go-jose·gocloak의 정확한 API는 **Task 1 딥리서치로 확정** 후 골격을 채우도록 명시(라이브러리 래핑 SDK의 불가피한 부분 — 참조 구현 Java/Python/Node + 공식문서로 검증). 그 외 스텝은 구체 코드·명령·기대값 명시.
- **타입/명칭 일관**: `Config`·`TokenSet`/`ValidatedToken`/`IntrospectionResult`·`ConfigError`/`AuthError`/`AdminError`/`TransportError`·센티넬 `ErrNotFound`/`ErrConflict`/`ErrForbidden`·`TokenProvider`/`TokenSource`/`NewClientCredentialsTokenProvider`·`AuthClient`/`AdminClient`/`Client`·`Raw()`가 전 태스크·스펙·Global Constraints와 일치. **공개 심볼**(admin 서브패키지 소비): 오류 타입·센티넬·`TokenProvider`·`NewClientCredentialsTokenProvider`·`TokenSet`·`Config`는 공개(대문자), admin은 `&AdminError{...}`를 직접 생성(별도 매핑 헬퍼 불필요). **import 순환 해소**: admin을 **단일 `package keycloak`**(서브패키지 아님, `admin_*.go` 파일)로 두어 root↔admin 상호 참조 순환을 원천 차단(스펙 §4의 `admin/` 서브디렉터리 스케치에서 벗어난 확정 결정 — Go 패키지당 1개·순환 금지 제약).
