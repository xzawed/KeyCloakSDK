---
paths:
  - "go/**"
  - "harness/apps/go/**"
  - "harness/install/consume/go*"
  - ".github/workflows/go-*.yml"
---

# Go rules

## Toolchain

Portable install at `${KCSDK_TOOLS:-$HOME/tools}/go`. Run it as `go -C go` (that leaves the cwd alone, so it never collides with git).

```bash
export PATH="${KCSDK_TOOLS:-$HOME/tools}/go/bin:$PATH" GOTOOLCHAIN=local
go -C go build ./...
go -C go test ./...                                          # unit (E2E excluded)
go -C go test -tags=integration -run TestE2E -count=1 ./...   # integration E2E. Needs Docker
go -C go vet ./...
gofmt -l go                                                  # no output means OK
```

- A single test: `go -C go test -run TestValidateValidToken ./...`
- Coverage (logic statements ≥90, network boundary omitted): `go test ./... -coverprofile=cover.out`, then drop the boundary with `grep -vE '/(auth|admin|admin_users|admin_clients|admin_realms|admin_roles|admin_groups|client)\.go:'` and read `go tool cover -func`. Measured 95.7%.
- ⚠️ **The minimum Go is 1.25** (required by `golang.org/x/oauth2` v0.36 — lower `go.mod` and `go mod tidy` puts it back). The CI matrix is 1.25 and 1.26. `golangci-lint` is CI-only; locally `go vet` and `gofmt` stand in for it.
- **There is no registry — the `go/v*` tag *is* the release** (`proxy.golang.org` caches it automatically). Consumers run `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z`.
  - ⚠️ **The module path contains capitals, so the proxy URL is `!`-escaped** (`github.com/xzawed/!key!cloak!s!d!k/go`) — querying it in lowercase gives a 404.
  - ⚠️ With no stable version out, a bare `go get <module>` and `@latest` **fall back to the RC** (same as pip and Cargo, unlike RubyGems).
  - ⚠️ **The proxy cache is immutable** — the only way to withdraw something is `retract` in a later release.
- ⚠️ **Do not read `// indirect` as "a dependency we chose".** Go has no notion of a dev dependency, so the dependency table carries only the modules we actually import. (For example: we never import `testify`; `testcontainers-go` drags it in.)

## Gotchas

- ⚠️ **`Realms.Update` is the one place that bypasses gocloak — it issues a raw PUT.** gocloak's `UpdateRealm` builds the path out of the body's `.Realm` (`Put(getAdminRealmURL(PString(realm.Realm)))`), so path and body cannot be separated and **a rename cannot be expressed** (Ruby, .NET and PHP do `PUT /admin/realms/{current name}` with the body untouched, so rename works there). To hold the §4 isomorphism this one call is made directly, and the error is re-wrapped as `*gocloak.APIError` so that `toSDKError` classifies it **exactly like every other method**. `AdminClient.baseURL` exists to assemble that URL and is normalised on the way in by **the same rule** gocloak uses for `basePath` (`strings.TrimRight(url, "/")`).
- ⚠️ **Do not inject `role.Name = &name` into `Roles.Update`.** gocloak builds the path from the `name` argument and sends the body as-is, so injecting it turns **a rename into a silent no-op**. The opposite holds for **`Groups.Update`, which requires injecting `group.ID = &id`** — gocloak builds that path from the body's `.ID`, and when it is empty the call dies before HTTP with an `errors.Wrap` (i.e. not an `APIError`), which `toSDKError` then misclassifies as a `TransportError`. Three methods all named `Update`, three different rules.
- ⚠️ **gocloak wraps even network failures as `*gocloak.APIError` (with `Code:0`).** `toSDKError` splits on that: `Code==0` becomes `*TransportError`, `>0` becomes `*AdminError`. Without the split, a refused connection or a DNS failure is misclassified as `AdminError{HTTP 0}` and the `errors.As(err, &TransportError)` path becomes dead code.
- ⚠️ **go-jose skips the expiry check when `exp` is absent** — `jwt.Validate` has to reject `claims.Expiry == nil` explicitly (`ValidateWithLeeway` alone is not enough). The initial JWKS load does not consume `forcedAt`, which keeps the first key-rotation refetch available, and concurrent misses converge through `singleflight`.
- ⚠️ **Without `Config.ReadTimeout` injected into the validator's JWKS `http.Client`, it falls back to `http.DefaultClient` and waits forever.**
- TLS is the `http.Client` default verification, so no `allowInsecure` logic is needed (unlike Node).
- `go-oidc` was never adopted: discovery is assembling a convention, and the verifier is hardened in-house on top of go-jose, so there is nothing to gain.
