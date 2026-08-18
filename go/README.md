# Keycloak SDK for Go

An idiomatic Go SDK for [Keycloak](https://www.keycloak.org/) covering both OIDC/OAuth2 authentication and the Admin REST API behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API shape, nine idioms: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`v0.1.0` is on the Go module proxy** — the first stable release. Go has no registry: the `go/v0.1.0` **tag** is the release, and `proxy.golang.org` cached it on first request. A bare `go get github.com/xzawed/KeyCloakSDK/go` (and `@latest`) now resolves it rather than the earlier `v0.1.0-rc.1`, since the `go` command only falls back to a pre-release when a module has no stable version. ⚠️ The proxy cache is immutable: every published version stays fetchable by exact version forever, and the only remedy for a bad one is a `retract` directive in a *later* release.

## Requirements

Go **1.25+** (`go.mod` declares `go 1.25.0`; `golang.org/x/oauth2` v0.36 sets the floor), against a Keycloak 26.6.x server.

## Install

Go modules have no registry — the VCS tag *is* the release. This SDK lives in the `go/` subdirectory of a monorepo, so its release tags are prefixed `go/v...` while the import path carries the `/go` suffix and the package name is `keycloak`. The `go/v0.1.0` tag is published, so the module resolves from the Go module proxy:

```bash
go get github.com/xzawed/KeyCloakSDK/go@v0.1.0
```

To work against a local checkout instead, clone the monorepo and build under `go/`, or add a `replace`:

```bash
cd go && go build ./... && go test ./...
# from a consuming module: replace github.com/xzawed/KeyCloakSDK/go => ../KeyCloakSDK/go
```

## Quickstart

The SDK is synchronous and every network method takes a `context.Context` as its first argument (only `CreateAuthorizationRequest` needs no context — it performs no I/O).

```go
package main

import (
	"context"
	"fmt"

	"github.com/Nerzal/gocloak/v13"
	keycloak "github.com/xzawed/KeyCloakSDK/go"
)

func main() {
	client, err := keycloak.New(keycloak.Config{
		ServerURL:    "https://kc.example.com",
		Realm:        "myrealm",
		ClientID:     "my-app",
		ClientSecret: "…", // load from an env var / secret manager; Config masks it when logged
	})
	if err != nil {
		panic(err)
	}
	defer func() { _ = client.Close() }()

	ctx := context.Background()

	// 1) client-credentials token. TokenSet.String masks the token when logged.
	token, err := client.Auth.ClientCredentialsToken(ctx)
	if err != nil {
		panic(err)
	}

	// 2) hardened verification (alg pinning · exact iss · aud membership · clock skew).
	vt, err := client.Auth.Validate(ctx, token.AccessToken)
	if err != nil {
		panic(err)
	}
	fmt.Println(vt.Subject, vt.Audience)

	// 3) admin API (created lazily on first call; requires ClientSecret).
	admin, err := client.Admin(ctx)
	if err != nil {
		panic(err)
	}
	id, err := admin.Users.Create(ctx, gocloak.User{
		Username: gocloak.StringP("alice"), Enabled: gocloak.BoolP(true),
	})
	if err != nil {
		panic(err)
	}
	fmt.Println("created user", id)
}
```

A stock realm does **not** put the client id in a client-credentials token's `aud`, so step 2 fails until the audience matches: either add an *Audience* protocol mapper to the client in Keycloak, or set `Config.ExpectedAudience` to the value your tokens actually carry (the API/resource name, when the token is audienced at a resource server).

Errors are values, not panics: match outcomes with `errors.Is` against `ErrNotFound` / `ErrConflict` / `ErrForbidden`, or reach the concrete `*AuthError`, `*AdminError`, `*TokenValidationError`, `*TransportError` with `errors.As`.

## Security defaults

- **Algorithm pinning** — the accepted JWT signature algorithms are pinned (`RS256` by default, configurable via `Config.SignatureAlgorithms`); the header-supplied `alg`, including `none`, is never trusted.
- **Hardened claims** — exact `iss` match, `aud` containment check (against `Config.ExpectedAudience`, the client id by default), mandatory `exp` (a token without one is rejected — go-jose skips the expiry check when the claim is absent, so the SDK enforces it), and a bounded clock skew (`Config.ClockSkew`, default 30s).
- **DoS-safe JWKS** — a refetch is triggered only by an unresolved key ID (rotation) and never by a bad signature, and is rate-limited by `Config.JwksMinRefetch` (default 30s) — so no volume of forged random `kid`s makes the SDK issue more than one JWKS request per interval.
- **Secret handling** — `Config.String` and `TokenSet.String` mask secrets and tokens fully (`***`, no prefix); TLS verification is on by default and both connect and read timeouts are always applied.

Masking covers this SDK's own `String()` methods, which is what `%v`/`%s` formatting reaches. It does not cover `%#v`, reflection-based structured loggers, or anything else that reads the fields directly — masking is defence in depth, not a guarantee about your logs.

## Versioning and support

This SDK is **pre-1.0**. Under SemVer a `0.x` **minor** bump may carry breaking changes, so read the release notes before upgrading. Only the newest released version of each language SDK receives security fixes — there are no LTS lines, and older `0.x` releases are not backported to. Full policy: [SECURITY.md](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md).

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md) — per-language install, quickstart, and compatibility matrix
- [Full Go example](https://github.com/xzawed/KeyCloakSDK/blob/main/go/example_test.go) — the runnable godoc example
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/go/LICENSE)
