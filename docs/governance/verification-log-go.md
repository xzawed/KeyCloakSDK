# 검증 로그 — Go SDK

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 Go SDK(`github.com/xzawed/KeyCloakSDK/go`) 태스크별 정량 검증 기록. 브랜치 `feature/go-sdk`.

**툴체인**: Go **1.26.4** 포터블 설치(`C:\Users\dirtc\tools\go`, 리포지토리 미커밋). 명령: `PATH="/c/Users/dirtc/tools/go/bin:$PATH" GOTOOLCHAIN=local go -C go <cmd>`. **최소 지원 Go 1.25**(`golang.org/x/oauth2` v0.36 요구 → `go.mod`의 `go 1.25`).

**게이트**: G1 빌드/vet(`go build`·`go vet`·`gofmt`) · G2 단위테스트(`go test`) · G3 커버리지(로직 파일 statement ≥90; 네트워크 경계 `auth.go`/`admin*.go`/`client.go` omit) · G4 스펙리뷰 · G5 교차검증(다중에이전트 어드버서리얼) · G6 보안.

> **실행 방식**: 승인된 WBS → 인라인 executing-plans + G1~G6 + 다중에이전트 리뷰 + Loops + 딥리서치. 각 태스크 TDD·계층별 커밋(의존순서상 Task 3을 Task 2보다 먼저).

---

## 딥리서치 (착수 전, Task 1) — 라이브러리 API 확정

Go 프록시(`go list -m -versions`)·`go doc`·모듈 소스로 현행 버전·시그니처·라이선스를 확정:

- **golang.org/x/oauth2 `v0.36.0`**(BSD-3): `clientcredentials.Config{...}.Token(ctx)`, `oauth2.Config.AuthCodeURL(state, S256ChallengeOption(v), SetAuthURLParam)`/`.Exchange(ctx, code, VerifierOption(v))`/`.TokenSource(ctx, &Token{RefreshToken}).Token()`. `GenerateVerifier()`. introspect/logout은 수동 form POST. `Token.ExpiresIn` 미채워질 수 있어 `Expiry`로 폴백 유도.
- **go-jose/go-jose/v4 `v4.1.4`**(Apache-2.0): `jwt.ParseSigned(token, []jose.SignatureAlgorithm)` — alg 핀·`none` 거부. `Claims.ValidateWithLeeway(Expected{Issuer, AnyAudience, Time}, leeway)` — iss 정확일치·**aud 포함검사(`AnyAudience`)**·exp/nbf/iat 스큐. `JSONWebKeySet.Key(kid)[].Key`가 검증키. **⚠️ `exp` 부재 시 만료검사 스킵** → 자체로 `exp` 필수 강제.
- **Nerzal/gocloak/v13 `v13.9.0`**(Apache-2.0): `NewClient(url)`·`RestyClient().SetTimeout(ms)`·`LoginClient(ctx, id, secret, realm)` → `*JWT`. `CreateUser/GetUserByID/GetUsers/UpdateUser/DeleteUser`·clients/realms/roles/groups 대응. **⚠️ `*APIError`는 네트워크 실패도 `Code:0`으로 감쌈** → 경계에서 `Code==0`→Transport.
- **testcontainers-go `v0.43.0`**(MIT): `modules/keycloak`는 **독립 버전 태그 부재**로 해석 실패 → base `GenericContainer`(`ContainerRequest{Image, ExposedPorts, Env, Cmd, Files, WaitingFor}` + `PortEndpoint(ctx,"8080/tcp","http")`) 사용. realm은 `//go:embed`.

## 계층별 구현 (Task 1~11)

각 태스크 TDD 후 계층별 커밋. G1(build/vet/gofmt)·G2(test)·G3(커버) 통과.

| Task | 커밋 | 내용 | G1 | G2 | G3 |
|---|---|---|---|---|---|
| 1 | `619a1e2` | 스캐폴딩(go.mod·golangci-lint·doc.go) | ✅ | — | — |
| 3 | `4fd9284` | masking·errors(타입드+센티넬)·tokens(의존순서상 먼저) | ✅ | ✅ | ✅ |
| 2 | `a85ce2d` | config(검증·마스킹 String) | ✅ | ✅ | ✅ |
| 4 | `fdd79a0` | tokenprovider(single-flight) | ✅ | ✅ 3 | ✅ |
| 5 | `73a3016` | oidc 엔드포인트 조립 | ✅ | ✅ | ✅ |
| 6 | `d46c71e` | jwt Validator(강화 + DoS-safe JWKS) | ✅ | ✅ 12 | ✅ |
| 7 | `b26cbcc` | auth(x/oauth2 래핑) | ✅ | ✅ 8(omit) | — |
| 8 | `846dae0` | admin + 5 리소스 + Raw | ✅ | ✅(omit) | — |
| 9 | `6974c15` | client 통합 진입점 | ✅ | ✅ | ✅ |
| 10 | `4c6634a` | Testcontainers E2E(실제 Keycloak 26.6) | ✅ | ✅ E2E | — |
| 11 | `2ab5198` | go-ci(1.25/1.26) + go-release(태그=릴리스) + 커버리지 게이트 | ✅ | — | ✅ 94.2% |

### Loop 1 (Task 7, G2 실패 → RCA → 조치)
- **증상**: `TestClientCredentialsToken`이 `ExpiresIn:0`.
- **RCA**: x/oauth2 clientcredentials 경로가 공개 `Token.ExpiresIn`을 항상 채우지 않음(응답 파싱 경로 차이). `Expiry`(time.Time)는 항상 채워짐.
- **조치**: `tokenSetFromToken`이 `ExpiresIn==0`이면 `ExpiresAt - now`로 유도(고정시간 유닛테스트는 영향 없음). 재측정 GREEN.

## G5 — 다중에이전트 어드버서리얼 리뷰 (Task 12 직전)

4-차원(정확성·보안·동형성·테스트) 병렬 리뷰 + 독립 어드버서리얼 검증. **10건 제기 → 9건 CONFIRMED · 1건 REFUTED**. 확정 9건 전부 조치(커밋 `e8db940`):

| # | 심각도 | 결함 | 조치 |
|---|---|---|---|
| 1 | MED | `toSDKError`가 gocloak 네트워크 실패(`APIError{Code:0}`)를 `AdminError{HTTP 0}`로 오분류 | `Code==0`→`*TransportError`(§4 동형) + 테스트 |
| 2 | MED | 프로덕션 Validator가 timed httpClient 없이 `http.DefaultClient`(무한대기)로 JWKS 페치 → hung IdP에 영원히 블록 | `client.New`에서 `Config.ReadTimeout` httpClient 주입 |
| 3 | MED | `go.mod` `go 1.25`인데 문서는 1.24+로 광고 | 최소 Go 1.25로 정정(x/oauth2 v0.36 요구), CI matrix 1.24→1.25 |
| 4 | MED | `jwt.Validate`가 `exp`를 필수로 요구 안 함(go-jose는 exp 부재 시 만료검사 스킵) | `claims.Expiry==nil` 명시 거부(Java/Python 동형) + 테스트 |
| 5 | MED | 초기(non-forced) JWKS 로드가 `forcedAt` 소모 → 기동 후 minRefetch(60s) 동안 첫 키회전 재조회 오거부 | 초기 로드는 `forcedAt` 미설정(Python `-inf` 동형), 첫 강제 재조회 허용 + 테스트 |
| 6 | LOW | JWKS 페치에 single-flight 없음 → 동시 미스가 N개 병렬 페치 | `singleflight.Group`로 수렴 |
| 7 | LOW | admin clients/realms/roles/groups가 커버리지 제외인데 통합에서도 미검증(Users만) | E2E를 5 리소스 CRUD로 확장(제외가 정직하도록) |
| 8 | MED | `TestExchangeCodeAndRefresh`가 전송 form 미검증(고정 목이 잘못된 grant도 통과) | grant_type·code·code_verifier·redirect_uri·refresh_token 검증 |
| 9 | MED | (재분류) #2와 동일 근원(Validator httpClient) — 정확성·보안 두 차원에서 각각 제기 | #2로 통합 조치 |

**REFUTED 1건**: `client.Admin` single-flight/실패-미캐시 테스트 제안 — 코드가 이미 정확(단일플라이트·실패 시 캐시 안 함) 확인.

## 최종 상태 (G1~G6 종합)

- **G1**: ✅ `go build`·`go vet`·`gofmt` 통과. golangci-lint(gosec 포함)는 CI에서.
- **G2**: ✅ 단위 **40** GREEN(config·errors·masking·tokens·tokenprovider·oidc·jwt·auth·admin·client).
- **G3**: ✅ 로직 파일 statement **95.2%**(게이트 90), 네트워크 경계(`auth.go`/`admin*.go`/`client.go`) omit.
- **통합**: ✅ Testcontainers E2E **1**(다단계) GREEN(실제 Keycloak 26.6 — client-credentials→validate 다중aud→introspect→user CRUD→삭제 후 `ErrNotFound`→clients/realms/roles/groups CRUD→`Raw()`).
- **G4**: ✅ §4·Java/Python/Node와 동형(계층·오류 taxonomy·값타입·보안불변식). Go 관용 편차(no-stutter·error 값+센티넬·`context.Context`·sync)는 §4 허용.
- **G5**: ✅ 4-차원 다중에이전트 어드버서리얼 리뷰(10제기→9확정 조치·1반증).
- **G6**: ✅ JWT 강화(alg 핀·`none` 거부·iss 정확일치·aud 포함검사·**`exp` 필수**·클록 스큐·DoS-안전 JWKS single-flight+rate-limit) · 완전 마스킹(토큰·시크릿·Config) · TLS 기본(Go http.Client) · JWKS/admin 타임아웃 주입 · admin 네트워크오류→TransportError.
- **배포**: 🔒 레지스트리 없음 — `go/v*` 태그가 곧 릴리스(`proxy.golang.org` 자동 캐시), `.github/workflows/go-release.yml`(human-gated, 미실행).
