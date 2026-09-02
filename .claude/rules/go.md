---
paths:
  - "go/**"
  - "harness/apps/go/**"
  - "harness/install/consume/go*"
  - ".github/workflows/go-*.yml"
---
<!-- doc-budget: max-bytes=7105 -->
<!-- 래칫 인상 6263 → 7105 (2026-09-02). 사유 (1) 이 아니라 **판정 방법의 복원**이다 —
     go 프록시 음성 캐시 교훈이 계획서(#362)에 적혔다가 그 계획서가 아카이브(#365)되면서
     살아 있는 문서에서 **0건**이 됐다(실측). 다음 릴리스가 같은 404 앞에서 서고, 이 파일이
     그 레인의 게차 소재지다. 압축이 판정 방법을 지우면 손실이라는 CLAUDE.md 규칙의 적용이다. -->
<!-- 6,056 → 6263 (2026-08-23): 래칫 조건 (1). 기각 사유가 목표보다 좁게 적혀 있어
     조건 커버리지를 영영 안 재게 만들고 있었다. 정정하면서 실측 수치와 그 결과 닫은 테스트 이름을 넣었다 —
     그 문장이 없으면 다음 사람이 같은 오해로 되돌린다. -->

# Go rules

## Toolchain

System install — ask `node scripts/doctor.mjs go` where it is rather than assuming a path (⚠️ this line said `${KCSDK_TOOLS:-$HOME/tools}/go`, which does not exist on the development machine). Run it as `go -C go` (that leaves the cwd alone, so it never collides with git).

```bash
export GOTOOLCHAIN=local   # go 는 PATH 에 있다. 없으면 `node scripts/doctor.mjs go` 가 어디 있는지 말해준다
go -C go build ./...
go -C go test ./...                                          # unit (E2E excluded)
go -C go test -tags=integration -run TestE2E -count=1 ./...   # integration E2E. Needs Docker
go -C go vet ./...
gofmt -l go                                                  # no output means OK
```

- A single test: `go -C go test -run TestValidateValidToken ./...`
- Coverage (logic statements ≥90, network boundary omitted): `go test ./... -coverprofile=cover.out`, then drop the boundary with `grep -vE '/(auth|admin|admin_users|admin_clients|admin_realms|admin_roles|admin_groups|client)\.go:'` and read `go tool cover -func`. Measured 95.7%.
- ⚠️ **There is no branch-coverage *gate* — but condition coverage is measurable, and it was measured.** `go test -covermode` takes `set`/`count`/`atomic` only, so there is no percentage comparable to the JaCoCo/Kover 85 the other six gate against; that is why there is no gate. It is **not** a reason to leave `&&`/`||` unmeasured. `gobco` instruments conditions — measured on this tree: 69 one-sided conditions, 14 on the JWT/token path, and one was a real gap (the JWKS rate-limit window was only ever tested **while it held**, never after it elapsed; `TestValidateRefetchAllowedAgainAfterRateLimitWindowElapses` closes it). **Revival condition** for a *gate*: a condition-coverage percentage comparable with the other six. Until then run `gobco` by hand when you touch security code.
- ⚠️ **A rename test has to assert the body, not just the path** — `TestRolesUpdateAddressesByCurrentNameAndCarriesNewNameInBody` in `admin_test.go` is that test, and it exists because the hazard above was otherwise uncaught: the E2E puts `"e2e-role"` in the path *and* in the body, so injecting `role.Name = &name` still passed. Measured with the injection in place: asserting the path alone **passes**; asserting the body fails with `got old-role`. gocloak already puts the `name` argument on the path, so the path can never disagree — the body is the only thing the injection breaks. The test needs no login round-trip (`UpdateRealmRole` takes the bearer string), and its handler answers 404 by default so a wrong path cannot slip through on a lenient 2xx.
- ⚠️ **The minimum Go is 1.25** (required by `golang.org/x/oauth2` v0.36 — lower `go.mod` and `go mod tidy` puts it back). The CI matrix is 1.25 and 1.26. `golangci-lint` is CI-only; locally `go vet` and `gofmt` stand in for it.
- **There is no registry — the `go/v*` tag *is* the release** (`proxy.golang.org` caches it automatically). Consumers run `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z`.
  - ⚠️ **The module path contains capitals, so the proxy URL is `!`-escaped** (`github.com/xzawed/!key!cloak!s!d!k/go`) — querying it in lowercase gives a 404.
  - ⚠️ **If no stable version is published**, a bare `go get <module>` and `@latest` **fall back to the RC** (same as pip and Cargo, unlike RubyGems).
  - ⚠️ **The proxy cache is immutable** — the only way to withdraw something is `retract` in a later release.
  - ⚠️ **Never probe `@v/<version>.info` *before* pushing the tag — it poisons a negative cache.** Measured (`go/v1.0.0`, 2026-09-01): that probe cached `unknown revision`, and after the push the endpoint stayed **404 for over 20 minutes** while the module was already published. `go-release.yml`'s warm step hit the same 404 and swallowed it (`|| true`), so the workflow went green regardless.
  - ⚠️ **The true post-publish check is the consumer path, not one endpoint.** At the same moment `@latest` returned `{"Version":"v1.0.0","Ref":"refs/tags/go/v1.0.0"}`, `@v/list` contained it, `sum.golang.org/lookup/...` returned the `h1:` hash, and `go list -m <module>@vX.Y.Z` succeeded from a clean `GOMODCACHE`. To split "bad tag" from "stale cache": `GOPROXY=direct go list -m <module>@vX.Y.Z` — if that works, the tag is fine.
- ⚠️ **Do not read `// indirect` as "a dependency we chose".** Go has no notion of a dev dependency, so the dependency table carries only the modules we actually import. (For example: we never import `testify`; `testcontainers-go` drags it in.)

## Gotchas

- ⚠️ **`Realms.Update` is the one place that bypasses gocloak — it issues a raw PUT.** gocloak's `UpdateRealm` builds the path out of the body's `.Realm` (`Put(getAdminRealmURL(PString(realm.Realm)))`), so path and body cannot be separated and **a rename cannot be expressed** (Ruby, .NET and PHP do `PUT /admin/realms/{current name}` with the body untouched, so rename works there). To hold the §4 isomorphism this one call is made directly, and the error is re-wrapped as `*gocloak.APIError` so that `toSDKError` classifies it **exactly like every other method**. `AdminClient.baseURL` exists to assemble that URL and is normalised on the way in by **the same rule** gocloak uses for `basePath` (`strings.TrimRight(url, "/")`).
- ⚠️ **Do not inject `role.Name = &name` into `Roles.Update`.** gocloak builds the path from the `name` argument and sends the body as-is, so injecting it turns **a rename into a silent no-op**. The opposite holds for **`Groups.Update`, which requires injecting `group.ID = &id`** — gocloak builds that path from the body's `.ID`, and when it is empty the call dies before HTTP with an `errors.Wrap` (i.e. not an `APIError`), which `toSDKError` then misclassifies as a `TransportError`. Three methods all named `Update`, three different rules.
- ⚠️ **gocloak wraps even network failures as `*gocloak.APIError` (with `Code:0`).** `toSDKError` splits on that: `Code==0` becomes `*TransportError`, `>0` becomes `*AdminError`. Without the split, a refused connection or a DNS failure is misclassified as `AdminError{HTTP 0}` and the `errors.As(err, &TransportError)` path becomes dead code.
- ⚠️ **go-jose skips the expiry check when `exp` is absent** — `jwt.Validate` has to reject `claims.Expiry == nil` explicitly (`ValidateWithLeeway` alone is not enough). The initial JWKS load does not consume `forcedAt`, which keeps the first key-rotation refetch available, and concurrent misses converge through `singleflight`.
- ⚠️ **Without `Config.ReadTimeout` injected into the validator's JWKS `http.Client`, it falls back to `http.DefaultClient` and waits forever.**
- TLS is the `http.Client` default verification, so no `allowInsecure` logic is needed (unlike Node).
- `go-oidc` was never adopted: discovery is assembling a convention, and the verifier is hardened in-house on top of go-jose, so there is nothing to gain.
