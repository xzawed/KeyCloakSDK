---
paths:
  - "go/**"
  - "harness/apps/go/**"
  - "harness/install/consume/go*"
  - ".github/workflows/go-*.yml"
---

# Go 규칙

## 툴체인 (빌드 명령)

Go는 포터블 설치 `C:\Users\dirtc\tools\go`(1.26.4, 리포지토리 미커밋)를 사용한다. 프리픽스를 인라인 지정하고 `go -C go`로 실행한다(cwd를 go/로 바꾸지 않아 git과 충돌 방지):
```bash
export PATH="/c/Users/dirtc/tools/go/bin:$PATH" GOTOOLCHAIN=local
go -C /d/Source/KeyCloakSDK/go build ./...      # 빌드
go -C /d/Source/KeyCloakSDK/go test ./...        # 단위테스트 40개(integration 태그 없이 — E2E 제외)
go -C /d/Source/KeyCloakSDK/go test -tags=integration -run TestE2E -count=1 ./...  # 통합 E2E(Docker 필요)
go -C /d/Source/KeyCloakSDK/go vet ./...         # 정적 분석
gofmt -l /d/Source/KeyCloakSDK/go                # 포맷 검사(출력 없으면 OK; -w로 수정)
```
- 단일 테스트: `go -C go test -run TestValidateValidToken ./...`
- 커버리지 게이트(로직 statement ≥90, 네트워크 경계 omit): `go test ./... -coverprofile=cover.out` → `grep -vE '/(auth|admin|admin_users|admin_clients|admin_realms|admin_roles|admin_groups|client)\.go:' cover.out`로 경계 제외 → `go tool cover -func`로 total 확인(실측 95.2%)
- ⚠️ **최소 Go는 1.25**(`golang.org/x/oauth2` v0.36이 요구 → `go.mod`의 `go 1.25`). CI matrix는 1.25·1.26. `golangci-lint`는 로컬 미설치(CI에서 `golangci/golangci-lint-action@v6`) — 로컬은 `go vet`·`gofmt`로 대체
- **배포는 레지스트리 없음** — Go 모듈은 `go/v*` 태그가 곧 릴리스(`proxy.golang.org` 자동 캐시). `.github/workflows/go-release.yml`이 태그 push 시 verify + GitHub Release + 프록시 워밍(사람 승인 게이트). 소비자: `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z`

## 게차

- ⚠️ **(Go) gocloak은 네트워크 실패까지 `*gocloak.APIError`로 감싼다(`Code:0`).** `toSDKError`는 `Code==0`이면 `*TransportError`, `>0`이면 `*AdminError`로 나눈다 — 그러지 않으면 연결 거부/DNS 실패가 `AdminError{HTTP 0}`로 오분류되고 `errors.As(err, &TransportError)` 경로가 死코드가 된다(리뷰 포착).
- ⚠️ **(Go) go-jose는 `exp` 부재 시 만료검사를 건너뛴다.** `jwt.Validate`에서 `claims.Expiry == nil`을 명시 거부해야 함(Java/Python 동형) — `ValidateWithLeeway`만으론 불충분. JWKS 초기 로드는 `forcedAt` 미소모로 첫 키회전 재조회 허용(Python `-inf` 동형), 동시미스는 `singleflight`로 수렴.
- ⚠️ **(Go) 최소 런타임 Go 1.25**(`x/oauth2` v0.36 요구 — `go.mod`를 낮춰도 `go mod tidy`가 재상향). Validator JWKS `http.Client`는 `Config.ReadTimeout` 미주입 시 `http.DefaultClient` 무한대기. TLS는 `http.Client` 기본검증이라 `allowInsecure` 로직 불필요(Node와 차이).
