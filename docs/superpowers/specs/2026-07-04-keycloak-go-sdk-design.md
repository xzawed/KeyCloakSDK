# Keycloak Go SDK — 설계 문서 (Design Spec)

- **작성일**: 2026-07-04
- **상태**: 승인 대기 (User Review)
- **대상**: 4번째 언어 — Go (`go/`)
- **진실 원천**: [언어 중립 계약 §4](2026-07-02-keycloak-multilang-sdk-design.md) · 절차: [add-a-language 플레이북](../../guides/add-a-language-playbook.md)
- **참조 구현**: Java(`java/`) · Python(`python/`) · Node(`node/`)
- **라이선스**: Apache-2.0

---

## 1. 개요 (Overview)

Keycloak을 위한 **Go용 SDK**를 만든다. Java(`keycloak-admin-client`+Nimbus)·Python(`python-keycloak`+joserfc)·Node(`openid-client`+jose+admin-client)에 이어 **4번째 언어**로, **§4 언어 중립 계약에 동형(isomorphic)**이다 — 같은 계층(`config → auth → jwt → admin → client`)·같은 예외 분류·같은 보안 불변식·같은 테스트 시나리오. 관용은 Go를 따른다(no-stutter 명명, `error` 값, `context.Context`).

두 API 표면을 각 언어 최고의 성숙 클라이언트로 감싼다 — **인증(OIDC/OAuth2)은 `golang.org/x/oauth2`, 관리(Admin REST)는 `github.com/Nerzal/gocloak/v13`** — 그 위에 일관된 파사드를 얹는다. **JWT 검증만은 라이브러리 기본값을 신뢰하지 않고 `go-jose/v4`로 자체 강화 구현**한다.

### 핵심 결정 (브레인스토밍 승인)
- **배치**: 모노레포 — 이 저장소 최상위 `go/`(java/·python/·node/와 나란히). 모듈 경로 `github.com/xzawed/KeyCloakSDK/go`, 패키지 `keycloak`, 배포 태그 `go/vX.Y.Z`. §4 계약·거버넌스·docs·CHANGELOG 공유.
- **명명**: **Go no-stutter** — `keycloak.New`, `keycloak.Client`, `keycloak.Config`, `keycloak.TokenSet`, `keycloak.Error`(§4는 관용 명명 허용). package명(`keycloak`)을 타입에 중복하지 않는다.
- **오류**: **타입드 구조체 + 센티넬** — §6.1 분류를 Go `error` 타입으로 매핑, `errors.Is`(센티넬)·`errors.As`(구조체 필드) 둘 다 지원.
- **동시성**: **동기 + `context.Context`** — 모든 네트워크 메서드가 `ctx context.Context`를 첫 인자로 받는다(취소·데드라인). §4의 "sync 공통 계약"과 정합. 별도 async 표면 없음(고루틴이 동시성 담당).

---

## 2. 범위 (Scope) & 비목표

### 범위
- **인증 흐름**: Authorization Code + PKCE(S256), Client Credentials, Refresh, Logout, Introspection, JWT 검증.
- **관리 파사드**: `Users`/`Clients`/`Realms`/`Roles`/`Groups` + 원시 접근 `Raw()`.
- **횡단**: 통합 오류 계급, 시크릿·토큰 마스킹, TLS 검증 기본 on, 수명주기(`Close()`), 타임아웃(+`ctx`).
- **품질/배포**: 단위 + Testcontainers 통합테스트, Go 모듈 배포(태그 드리븐, human-gated), CI.

### 비목표
- 브라우저/SPA 인증(서버측 Go 파사드에 집중).
- 별도 async API(Go는 sync + `ctx` + 고루틴).
- go-oidc 기반 자동 discovery(엔드포인트를 규약으로 조립 — 네트워크 왕복 없음).

---

## 3. 의존성 (래핑 대상 · 딥리서치 2026-07-04 확정)

| 계층 | 라이브러리 | 버전 | 라이선스 | 근거 · 주의 |
|---|---|---|---|---|
| **auth 흐름** | `golang.org/x/oauth2` (+`/clientcredentials`) | v0.36.0 | BSD-3 | client-credentials/authorization-code+PKCE/refresh. Google 유지·매우 안정. introspect/logout은 수동 POST(x/oauth2 미제공). |
| **jwt** | `github.com/go-jose/go-jose/v4` | v4.1.4 | Apache-2.0 | JOSE 프리미티브(JWS 파싱·서명검증·JWK). 안전 기본값(alg 핀·none 거부)은 우리가 얹는다. JWKS DoS-safe 캐시도 자체 구현. |
| **admin** | `github.com/Nerzal/gocloak/v13` | v13.9.0 | Apache-2.0 | de-facto Go Keycloak admin 클라이언트. `gocloak.User`/`Client`/… representation 노출(문서화된 은닉성 예외). `*gocloak.APIError`(Code 필드) → 경계에서 변환. resty 기반 → 타임아웃 주입. |
| **single-flight** | `golang.org/x/sync/singleflight` | (최신) | BSD-3 | 토큰 갱신 중복 제거(thundering-herd 방지). |
| **통합테스트** | `github.com/testcontainers/testcontainers-go` + `/modules/keycloak` | v0.43.0 | MIT | **공식 Keycloak 모듈** — realm import 지원. Node의 GenericContainer 수작업 불필요. |
| **단위 assert** | `github.com/stretchr/testify` | v1.11.1 | MIT | assert/require. Go 표준 관용. |

> **`go-oidc` 제외 근거**: 주 용도(RP verifier·provider discovery) 중 verifier는 우리가 go-jose로 자체 강화하고, discovery는 Keycloak 규약 URL(`{server}/realms/{realm}/protocol/openid-connect/*`)을 코드로 조립하므로(Java/Python/Node와 동일) 불필요. 의존성 최소화.
>
> **⚠️ 착수 시 재확인**(플레이북 1단계): 유지보수 상태·라이선스(전부 Apache-2.0 호환 확인됨)·gocloak representation 필드는 실제 Keycloak 26.6으로 검증. gocloak은 서버 버전을 추종하므로 버전 핀 + CI에서 실서버 통합테스트로 확인.

---

## 4. 디렉터리 구조 (`go/`)

```
go/
├─ go.mod / go.sum          # module github.com/xzawed/KeyCloakSDK/go · go 1.24
├─ config.go                # Config(값 구조체) + 검증(New 내부)
├─ errors.go                # Error 계급(타입드 구조체 + 센티넬) + HTTP상태 매핑
├─ tokens.go                # TokenSet / ValidatedToken / IntrospectionResult + 마스킹
├─ tokenprovider.go         # TokenProvider 인터페이스 + ClientCredentialsTokenProvider(single-flight)
├─ oidc.go                  # 엔드포인트 조립(네트워크 없음)
├─ jwt.go                   # Validator — go-jose 자체 강화 + DoS-safe JWKS 캐시
├─ auth.go                  # AuthClient — x/oauth2 래핑 + 수동 introspect/logout
├─ admin.go                 # AdminClient + Raw() + call(경계변환)
├─ admin_users.go admin_clients.go admin_realms.go admin_roles.go admin_groups.go
├─ client.go                # Client 통합 진입점(Auth 즉시·Admin 지연·Close)
├─ example_test.go          # 실행 가능한 godoc 예제
└─ internal/testsupport/    # it-realm-realm.json(Java/Python/Node 재사용) + 컨테이너 하네스
```

각 파일은 단일 책임. 파사드(`client.go`·`admin.go`) 뒤에 하위 타입 은닉. **전체가 단일 `package keycloak`**(admin을 서브패키지로 두면 `Client.Admin`이 `*AdminClient`를 반환하며 admin이 root 타입을 참조해 **import 순환** — Go 금지 — 이 발생하므로 `admin_*.go` 파일로 같은 패키지에 둔다). 단위테스트는 각 파일 옆 `*_test.go`(Go 관용, 화이트박스 `package keycloak` + 블랙박스 `package keycloak_test` 병용).

---

## 5. 계층 설계 (동형 + Go 관용)

### 5.1 공개 API

```go
cfg := keycloak.Config{
    ServerURL:    "https://kc.example.com",
    Realm:        "myrealm",
    ClientID:     "my-app",
    ClientSecret: "…",                 // confidential client일 때
    Scopes:       []string{"openid"},  // 생략 시 기본 없음(auth URL에선 "openid")
}
kc, err := keycloak.New(cfg)           // 검증 실패 → *ConfigError
if err != nil { … }
defer kc.Close()                       // Auth+Admin 자원 정리

// --- auth (즉시 조립, kc.Auth 필드) ---
ts, err  := kc.Auth.ClientCredentialsToken(ctx)          // → *TokenSet
vt, err  := kc.Auth.Validate(ctx, ts.AccessToken)        // → *ValidatedToken (강화 검증)
ir, err  := kc.Auth.Introspect(ctx, ts.AccessToken)      // → *IntrospectionResult
// ar := kc.Auth.CreateAuthorizationRequest(redirectURI) // (동기, 네트워크 없음): AuthorizationRequest{URL,CodeVerifier,State,Nonce}
// ts, err := kc.Auth.ExchangeCode(ctx, code, redirectURI, ar.CodeVerifier, ar.Nonce)
// ts, err := kc.Auth.Refresh(ctx, refreshToken)
// err := kc.Auth.Logout(ctx, refreshToken)

// --- admin (지연, clientSecret 필요) ---
admin, err := kc.Admin(ctx)                              // 최초 호출 시 인증·캐시(single-flight)
id, err   := admin.Users.Create(ctx, gocloak.User{Username: gocloak.StringP("alice")})
u, err    := admin.Users.Get(ctx, id)                    // 없으면 ErrNotFound
us, err   := admin.Users.Search(ctx, "alice", 0, 20)
err        = admin.Users.Update(ctx, id, rep)
err        = admin.Users.Delete(ctx, id)
raw := admin.Raw()                                       // *gocloak.GoCloak (탈출구)
```

- **`kc.Auth`**: 필드(`*AuthClient`), `New`에서 즉시 조립(네트워크 없음).
- **`kc.Admin(ctx)`**: 메서드 `(*AdminClient, error)` — 최초 호출 시 gocloak 생성 + client-credentials 인증, 캐시·single-flight. `clientSecret` 없으면 네트워크 전 `*ConfigError`.
- **리소스 메서드**: `Create/Get/Search/Update/Delete` 등 — Java `UsersResource`와 동형. gocloak representation 타입(`gocloak.User`/`Client`/`Role`/`Group`/`RealmRepresentation`)을 데이터 모델로 노출(문서화된 은닉성 예외).
- **모든 네트워크 메서드**는 `ctx context.Context` 첫 인자(취소·데드라인). `CreateAuthorizationRequest`만 순수 동기.

### 5.2 값 타입 (`tokens.go`)

```go
type TokenSet struct {
    AccessToken  string
    TokenType    string
    ExpiresIn    int64          // 상대(초)
    ExpiresAt    int64          // 절대(epoch 초) — 0이면 미상
    RefreshToken string
    IDToken      string         // OIDC id_token(auth-code/refresh)
    Scope        string
}
func (t *TokenSet) IsExpired(nowSec, skewSec int64) bool
func (t *TokenSet) String() string   // access/refresh 마스킹

type ValidatedToken struct {
    Subject   string
    Audience  []string
    Issuer    string
    ExpiresAt int64             // exp
    IssuedAt  int64             // iat
    Claims    map[string]any
}

type IntrospectionResult struct {
    Active   bool
    Username string
    ClientID string
    Claims   map[string]any
}

type AuthorizationRequest struct {  // CreateAuthorizationRequest 반환
    URL          string
    CodeVerifier string
    State        string
    Nonce        string
}
```

값 타입은 Java/Python/Node와 동형(`expiresAt`/`idToken`/`isExpired`·`username`/`clientId`·`exp`/`iat` 포함).

### 5.3 결합 규칙

`admin`은 `auth`를 직접 모른다 — `TokenProvider` 인터페이스로만 연결.

```go
type TokenProvider interface {
    Token(ctx context.Context) (string, error)
}
```

기본 `ClientCredentialsTokenProvider`는 client-credentials로 토큰 자동 획득·캐시(만료 전 재사용)·갱신하며, 동시 요청은 `singleflight`로 단일 발급. 소비자는 자체 `TokenProvider`를 주입 가능(admin의 토큰 출처 교체).

### 5.4 오류 계급 (`errors.go`)

```go
type ConfigError struct { Msg string }                                   // 설정 검증
type AuthError  struct { Msg, OAuthError string; Cause error }           // 인증/토큰 교환(OAuth error 보존)
type TokenValidationError struct { Msg string; Cause error }             // 서명·만료·iss·aud
type AdminError struct { StatusCode int; Msg string; Cause error }       // 관리 API(HTTP status 보존)
type TransportError struct { Msg string; Cause error }                   // 네트워크/타임아웃

// 센티넬 — AdminError.Is()로 매칭
var ErrNotFound  = errors.New("keycloak: not found")   // 404
var ErrConflict  = errors.New("keycloak: conflict")    // 409
var ErrForbidden = errors.New("keycloak: forbidden")   // 403
```

- 각 타입은 `Error() string`·`Unwrap() error`(원인 체이닝) 구현.
- `AdminError`는 `Is(target error) bool`을 구현해 `errors.Is(err, keycloak.ErrNotFound)`가 `StatusCode==404`일 때 참. 구조체 접근은 `errors.As(err, &adminErr)`.
- **경계에서 하위 라이브러리 에러 변환** — `*gocloak.APIError`(Code)·`*oauth2.RetrieveError`·`*jose` 에러가 공개 API로 새지 않는다.
- 시크릿/토큰은 오류 메시지에 마스킹(§6).

---

## 6. 보안 불변식 (§4 · 게차 준수)

- **마스킹**: 토큰/시크릿은 `String()`/`fmt`(`%v`,`%s`)/오류 메시지·로그에 **완전 불투명 `***`**(접두 노출 없음). `TokenSet.String()`은 access/refresh를 마스킹, `Config`도 `String()`에서 `ClientSecret` 마스킹(Go `fmt`는 필드를 그대로 찍으므로 `Stringer` 구현 필수).
- **TLS 검증 기본 on**: `ServerURL`이 `http://`일 때만 완화(로컬/테스트). https는 강제.
- **JWT 강화(`jwt.go`)**: 허용 알고리즘 핀(`RS256` 등, 헤더 `alg` 불신)·`none`/미서명 거부·`iss` 정확일치·`aud` **포함검사**(다중 aud 수용)·`exp`/`nbf` + 클록 스큐(기본 30s)·**JWKS 재조회 DoS-안전**(서명 위조는 재조회 유발 안 함, kid 미해결만 재조회, 최소 간격 rate-limit — Python `_load_jwks` 패턴을 go-jose로 자체 구현). JWKS 소스는 issuer당 캐시.
- **admin 타임아웃 주입**: `Config`의 connect/read 타임아웃을 gocloak resty client에 주입 + 모든 호출에 `ctx` 데드라인 전달(무한대기 방지).
- **single-flight**: 만료 시점 토큰 갱신 중복 제거.
- **CI 회귀 가드**: 마스킹·TLS·JWKS DoS-safe 단위 테스트를 머지 차단 잡으로.

---

## 7. 테스트 (Java/Python/Node 패리티)

| 층위 | 도구 | 대상 |
|---|---|---|
| **단위** | `go test` + `testify` + 목/스텁 | PKCE 생성, 설정 검증·기본값, 토큰 응답 파싱, JWT 강화(alg 핀·none·iss·aud·exp/nbf), 오류 경계 매핑(gocloak `APIError`→`AdminError`/센티넬), 마스킹, single-flight |
| **통합** | `testcontainers-go/modules/keycloak` + 실제 **Keycloak 26.6** | client-credentials→`Validate`(다중 aud)→`Introspect`→user CRUD→`Raw()`→delete 후 `ErrNotFound`. **Java/Python/Node `it-realm-realm.json` 재사용** |
| **커버리지** | `go test -coverprofile` + 임계값 검사 | 로직 파일 라인≥90/브랜치≥85 상당, 네트워크 경계(`auth.go`/`admin/**`) omit. 실측 임계값은 착수 시 확정 |

시나리오 집합은 Java/Python/Node와 **동형**(개수는 언어차 허용). 통합은 Docker 필요. 커버리지 게이트는 Go에 fail-under 내장이 없어 `go tool cover -func` 파싱 스크립트 또는 CI 액션으로 강제(네트워크 경계 파일 제외 패턴 포함).

---

## 8. 빌드 · CI · 배포

- **빌드/품질**: `go build ./...`·`go vet ./...`·`gofmt -l`(포맷)·`golangci-lint`(린트, 보안 린터 포함)·`go test`.
- **모듈**: `github.com/xzawed/KeyCloakSDK/go`, `go 1.24`(최소). 저장소 대소문자(`KeyCloakSDK`)를 모듈 경로에 그대로 사용(Go 경로는 대소문자 구분·VCS 경로 일치 필수). 소비자: `import "github.com/xzawed/KeyCloakSDK/go"` → `keycloak.New(…)`.
- **CI (`.github/workflows/go-ci.yml`)**: matrix Go — **최소 지원(`go 1.24`) + 최신 마이너**(착수 시 확정, 예: `1.24`·`1.26`) — build+vet+gofmt+golangci-lint+unit+coverage 잡, integration 잡(Docker) 별도. paths `go/**`. `actions/setup-go` + 모듈 캐시.
- **배포 (`.github/workflows/go-release.yml`)**: `go/v*` 태그 → **레지스트리 배포 없음**(Go 모듈은 태그=릴리스, `proxy.golang.org`가 VCS에서 자동 캐시). 워크플로는 (a) verify(vet+test), (b) GitHub Release 생성, (c) `GOPROXY=proxy.golang.org go list -m github.com/xzawed/KeyCloakSDK/go@<태그>`로 프록시 워밍. human-gated(사람이 `go/v*` 태그 push). 저장 시크릿 불필요.
- **로컬 사전검증**: `go build ./...`·`go vet ./...`·`go test ./... -short`.

---

## 9. 문서 · 거버넌스

- getting-started에 **Go 섹션(4블록: 요구 런타임 Go 1.24+·로컬 `go get`·배포후 `go get`·최소 예제)** 추가 · README·CLAUDE 구조 트리·로드맵 현황 매트릭스 Go ✅ 갱신 · CHANGELOG `(Go)` 태그.
- **verification-log-go.md**(게이트 통과·Loops·딥리서치 이력) 기록.
- **G1~G6 게이트 + 이중검증(다중에이전트 어드버서리얼 리뷰) + Loops** 준수. 실행은 **WBS → Workflow 오케스트레이션**(플레이북 6단계 매핑). 착수 전 딥리서치 재검증.
- **툴체인**: 이 머신은 Go를 `C:\Users\dirtc\tools\go`(1.26.4, 포터블)에 설치. 명령 프리픽스 `PATH="/c/Users/dirtc/tools/go/bin:$PATH" GOTOOLCHAIN=local go <cmd>` (Java/Maven 방식과 동일, 리포지토리 미커밋 — CI는 setup-go 사용).

---

## 10. 결정 · 열린 항목

- **결정됨**: 모노레포 `go/` 서브모듈(`github.com/xzawed/KeyCloakSDK/go`, `go/vX.Y.Z` 태그) · Go no-stutter 명명 · 타입드 구조체+센티넬 오류 · sync+`context.Context` · 전체 §4 계약 동형 · 래핑(x/oauth2 + go-jose + gocloak, go-oidc 제외) · testcontainers-go 공식 keycloak 모듈 · 패키지 `keycloak`.
- **착수 시 확정**: gocloak/x/oauth2/go-jose 유지보수·API 시그니처 실검증 · 커버리지 임계값 수치 · golangci-lint 룰셋 · JWKS DoS-safe 캐시 세부(rate-limit 간격) · admin representation 필드 실서버 검증.
- **비목표 재확인**: 브라우저 지원·별도 async API·go-oidc 자동 discovery는 범위 밖.
