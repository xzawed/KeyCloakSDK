---
paths:
  - "go/**"
  - "harness/apps/go/**"
  - "harness/install/consume/go*"
  - ".github/workflows/go-*.yml"
---

# Go 규칙

## 툴체인

포터블 설치 `${KCSDK_TOOLS:-$HOME/tools}/go`. `go -C go`로 실행한다(cwd를 바꾸지 않아 git과 충돌하지 않는다).

```bash
export PATH="${KCSDK_TOOLS:-$HOME/tools}/go/bin:$PATH" GOTOOLCHAIN=local
go -C go build ./...
go -C go test ./...                                          # 단위(E2E 제외)
go -C go test -tags=integration -run TestE2E -count=1 ./...  # 통합 E2E. Docker 필요
go -C go vet ./...
gofmt -l go                                                  # 출력 없으면 OK
```

- 단일 테스트: `go -C go test -run TestValidateValidToken ./...`
- 커버리지(로직 statement ≥90, 네트워크 경계 omit): `go test ./... -coverprofile=cover.out` → `grep -vE '/(auth|admin|admin_users|admin_clients|admin_realms|admin_roles|admin_groups|client)\.go:'`로 경계를 뺀 뒤 `go tool cover -func`. 실측 95.7%.
- ⚠️ **최소 Go는 1.25**(`golang.org/x/oauth2` v0.36 요구 — `go.mod`를 낮춰도 `go mod tidy`가 되돌린다). CI 매트릭스 1.25·1.26. `golangci-lint`는 CI 전용이고 로컬은 `go vet`·`gofmt`로 대체한다.
- **레지스트리가 없다 — `go/v*` 태그가 곧 릴리스**(`proxy.golang.org` 자동 캐시). 소비자는 `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z`.
  - ⚠️ **모듈 경로에 대문자가 있어 프록시 URL은 `!` 이스케이프다**(`github.com/xzawed/!key!cloak!s!d!k/go`) — 소문자로 조회하면 404다.
  - ⚠️ 정식 버전이 없으면 맨 `go get <module>`과 `@latest`가 **RC로 폴백한다**(pip·Cargo와 같고 RubyGems와 다르다).
  - ⚠️ **프록시 캐시는 불변이다** — 회수 수단은 후속 릴리스의 `retract`뿐이다.
- ⚠️ **`// indirect`를 "우리가 고른 의존성"으로 읽지 않는다.** Go에는 dev-dependency 개념이 없다 — 의존성 표에는 실제로 import하는 모듈만 담는다. (예: `testify`는 우리가 import하지 않고 `testcontainers-go`가 끌어온다.)

## 게차

- ⚠️ **`Realms.Update`만 gocloak을 거치지 않는다 — 그 한 자리에서 raw PUT을 쓴다.** gocloak의 `UpdateRealm`은 경로를 body의 `.Realm`에서 만들어(`Put(getAdminRealmURL(PString(realm.Realm)))`) 경로와 body를 분리할 수 없고, 그래서 **rename을 표현할 수 없다**(Ruby·.NET·PHP는 `PUT /admin/realms/{현재이름}` + body 그대로라 rename이 된다). §4 동형을 지키려고 여기만 직접 요청하고, 오류는 `*gocloak.APIError`로 되싸서 `toSDKError`가 **다른 메서드와 동일하게** 분류하게 한다. `AdminClient.baseURL`은 그 URL 조립용이고 gocloak의 `basePath`와 **같은 규칙**(`strings.TrimRight(url, "/")`)으로 정규화해 보관한다.
- ⚠️ **`Roles.Update`에 `role.Name = &name`을 주입하지 말 것.** gocloak이 경로를 `name` 인자에서 만들고 body를 그대로 보내므로, 주입하면 **rename이 조용한 no-op**이 된다. 반대로 **`Groups.Update`는 `group.ID = &id`를 주입해야 한다** — gocloak이 경로를 body의 `.ID`에서 만들고, 비어 있으면 HTTP 이전에 `errors.Wrap`(= `APIError` 아님)으로 죽어 `toSDKError`가 `TransportError`로 오분류한다. 같은 `Update`라도 셋이 서로 다르다.
- ⚠️ **gocloak은 네트워크 실패까지 `*gocloak.APIError`로 감싼다(`Code:0`).** `toSDKError`는 `Code==0`이면 `*TransportError`, `>0`이면 `*AdminError`로 나눈다 — 그러지 않으면 연결 거부·DNS 실패가 `AdminError{HTTP 0}`로 오분류되고 `errors.As(err, &TransportError)` 경로가 죽은 코드가 된다.
- ⚠️ **go-jose는 `exp` 부재 시 만료 검사를 건너뛴다** — `jwt.Validate`에서 `claims.Expiry == nil`을 명시적으로 거부해야 한다(`ValidateWithLeeway`만으로는 불충분). JWKS 초기 로드는 `forcedAt`을 소모하지 않아 첫 키 회전 재조회를 허용하고, 동시 미스는 `singleflight`로 수렴한다.
- ⚠️ **Validator의 JWKS `http.Client`에 `Config.ReadTimeout`을 주입하지 않으면 `http.DefaultClient`로 무한 대기한다.**
- TLS는 `http.Client` 기본 검증이라 `allowInsecure` 로직이 필요 없다(Node와 다르다).
- `go-oidc`는 애초에 채택하지 않았다 — discovery는 규약 조립이고 verifier는 go-jose로 자체 강화하므로 얻을 것이 없다.
