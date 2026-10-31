# Keycloak SDK for Go

An idiomatic Go SDK for [Keycloak](https://www.keycloak.org/) covering both OIDC/OAuth2 authentication and the Admin REST API behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API shape, nine idioms: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`v1.2.5` is on the Go module proxy** — a patch release on top of `v1.2.4`, and what a bare `go get github.com/xzawed/KeyCloakSDK/go` (or `@latest`) resolves to (`v1.0.0` was the first release carrying the stability guarantee below). **Security**: the admin client now holds the access token it sends as a Bearer to one rule shared by all nine SDKs: leading and trailing SP, HTAB, CR and LF are stripped, and unless what remains is a non-empty RFC 6750 `b64token` (ASCII letters and digits and `-._~+/`, with `=` only at the end) the request is not sent and the call fails with `*AuthError`, which does not quote the token. `AdminClient` and the public `NewClientCredentialsTokenProvider` apply it, and neither caches such a token — a whitespace-only token used to be sent with **no** `Authorization` header, and the public provider cached an unusable token until it expired. ⚠️ A token that ends in a newline used to be rejected and is now stripped and sent. A consumer `TokenSource` that returns `(nil, nil)` used to kill the process with a nil-dereference panic — inside the shared flight, where no caller could recover it — and now gives `*AuthError`. A JWKS key set now expires 300 seconds after the load that fetched it finished, and an expired set is treated as a cold cache: the next validation fetches it again through the cold-load path (the same single flight and the same failure backoff) and rejects the token if that fetch fails, instead of validating with the stale keys. Until now the Go SDK gave a key set no lifetime, so it kept accepting a key the IdP had removed until a token with a new `kid` arrived. ⚠️ If the JWKS cannot be reached for more than 300 seconds, validation fails — by design, because the SDK cannot tell an unreachable JWKS from a key the IdP has removed. The failure backoff's jitter (×[0.5, 1.0)) was drawn again at every check, so the same failure could refuse a validation at 190 ms and send the next one to the IdP at 191 ms; it is now drawn once, when the failure happens. **Fixed**: when the result of a shared flight (the first `Client.Admin`, a client_credentials token, a JWKS fetch) and the cancellation of the caller's `ctx` were ready together, either one was returned at random (`context.Canceled` in 93–103 of 200 ties); the ready result now wins, as it already did on a cache hit. With no result yet, the `ctx` error is returned as before. **Changed**: the doc comments pkg.go.dev renders — the six masking hooks and the ⚠️ notes on the three admin `Update` methods — are now in English, like the rest; the code is unchanged. No public API changed. ⚠️ **It requires Go 1.26+** (see Requirements). Go has no registry: the `go/v1.2.5` **tag** is the release, `proxy.golang.org` caches it on first request, and ⚠️ that cache is immutable — every published version stays fetchable by exact version forever, and the only remedy for a bad one is a `retract` directive in a *later* release.
>
> `v1.2.4` was a patch release on top of `v1.2.3`. **Security**: the admin client read a response body to its end even after it had the result. resty reads every body to its end before gocloak looks at the result, so a server wrote all of the 64 MiB it attached to the 201 body of a `Create` or the 2xx body of an `Update` or `Delete` (72–157 ms), and a server that stalled after a 201's head turned a `Create` that already had its `Location` into a `*TransportError` at the end of the read timeout (4,000–4,002 ms with a 4-second timeout). Error bodies were read to their end too: a 404 with 64 MiB made one call allocate 165.5 MB, and the body went into the error message (a 404 carrying a 2 MiB `errorMessage` gave a 2,097,194-byte message). The facade's fifteen write calls (`Create`, `Update` and `Delete` on the five resources) now leave a 2xx body unread (the server wrote at most 262,144 bytes; 0–20 ms in front of a stalled server, plaintext and TLS 1.3), and an error body (3xx and above) is held only up to 1,048,576 bytes, the token-response cap — one byte more is read to see whether it goes over, and the rest is not read (4.5–4.6 MB for one call with a 64 MiB error body). An error body over the cap is not parsed, so the status (`ErrNotFound` and the like) is unchanged and the message carries only the status line (40 bytes for the 2 MiB 404 above). When a consumer set `Accept-Encoding` on the resty client through `Raw()`, net/http left that gzip alone and resty decompressed it above every cap — a 65,280-byte gzip error body inflated to 64 MiB and one call allocated 165.6 MB, and the admin lane's token refresh accepted a gzip token response that inflated to 16 MiB. The SDK transport now decompresses that gzip itself, so this cap and the token-response cap count decompressed bytes (that bomb: 4.6 MB; that token response: refused as over the cap); such a response looks decompressed, with no `Content-Encoding` or `Content-Length` (as when net/http asks for gzip itself), and an empty body labelled gzip (the answer to a HEAD, a chunked body with no data) is simply empty — resty used to fail it with `EOF`, so `Delete` reported a user the server had deleted as a `*TransportError`. A gocloak method called through `Raw()` still receives a 2xx body (its error body has the same cap), and success bodies (`Get`, `Search`, lists) are not capped. The connection of a response not read to its end is discarded on HTTP/1.1, and on HTTP/2 only that stream is reset; the connection of a 2xx with no body (an empty 201, a 204) is reused as before. `Validate` also used memory in proportion to a token's length before it checked the signature: go-jose v4.1.6's `jwt.ParseSigned` decodes the protected header up to three times before it looks up the key, so one forged token allocated 35.3–54.5 bytes per input byte (`TotalAlloc`, measured), and `net/http` accepts a 1 MiB header by default (a 1,048,576-byte Bearer → 200, measured). A token longer than 256,000 bytes is now rejected with `*TokenValidationError` (`token exceeds 256000 bytes`) before it is decoded and before the JWKS is loaded, and the id_token of `ExchangeCode` goes through the same check (wrapped in `*AuthError`). **Fixed**: a deadline that arrived mid-exchange — after the response head, while the body was being read — lost its identity. Whether it was the caller's `ctx` deadline or the SDK's read timeout (`Config.ReadTimeout`), `ClientCredentialsToken`, `Refresh` and `ExchangeCode` returned an `*AuthError`, and an admin facade call a `*TransportError`, for which `errors.Is(err, context.DeadlineExceeded)` was false, because x/oauth2 flattens a body-read error into a string and gocloak flattens every request error. So the admin facade was false also on a deadline before the response head and on an already cancelled `ctx`, and the admin token request was false on the read timeout. The SDK transport now remembers the error that ended the request and attaches it as the SDK error's `Cause`, so on a deadline `errors.Is(err, context.DeadlineExceeded)` holds and `errors.As` finds a `net.Error` whose `Timeout()` is true, and a call made with an already cancelled `ctx` satisfies `errors.Is(err, context.Canceled)`. Error types and messages are unchanged, and `errors.As` still reaches `*gocloak.APIError` in an admin error's cause. `Introspect`, `Logout` and `Validate` were already right. No public API changed.
>
> `v1.2.3` was a patch release on top of `v1.2.2`. **Security**: the module now requires `github.com/go-jose/go-jose/v4` 4.1.6, for [GHSA-mgcc-cww5-fp2q](https://github.com/go-jose/go-jose/security/advisories/GHSA-mgcc-cww5-fp2q) (high). In 4.1.5, `jwt.ParseSigned` validated the RSA private-key parameters of a `jwk` carried in the protected header — at a cost cubic in the prime size, and before any key lookup or signature check — so one unauthenticated token held `Validate` (2.5 seconds for a 4,250-byte token carrying 16,384-bit primes). Such a token is now refused while parsing, in about 1 ms, with `*TokenValidationError` (`… JWK contains private parameters`); it sends no JWKS request, and the error no longer quotes the header's key. The SDK never uses a key from the header — keys come from the JWKS by `kid`. ⚠️ Go's minimal version selection raises your go-jose to 4.1.6 or later once you take this release; until then, running `go get github.com/go-jose/go-jose/v4@v4.1.6` yourself closes it. The transport the SDK builds — the one auth, JWKS and admin share — now reads a response's header block (status line through the blank line) only up to 65,536 bytes. net/http's default is 10 MiB, so a 16 MiB header line made one call read about 10 MiB and allocate 73 MB before it failed, and a header block between 65,537 bytes and 10 MiB was accepted. A longer one now fails, on HTTP/1.1 and HTTP/2 alike, with the error that lane gives a failed response — `*AuthError` for the three grants, `*TransportError` for `Introspect`, `Logout` and admin, `*TokenValidationError` for `Validate` — and a failed admin token request sends no admin request. 65,536 bytes is .NET `HttpClient`'s default; Keycloak 26.6 sends at most 339 bytes of header block to the endpoints the SDK calls, and 3,018 bytes anywhere in a browser login. **Fixed**: an access token an HTTP header cannot carry (CR, LF, NUL, another control character other than HTAB, or DEL) from the token endpoint was cached by the admin lane, and every admin call then failed without sending a request, with an opaque `*TransportError` that blamed the IdP's response. Such a token is now not cached and the next call requests a new one; ⚠️ the call fails with `*AuthError` (`client-credentials login returned an access token an HTTP header cannot carry …`) instead. A token from the `TokenProvider` passed to `NewAdminClient` gets the same check at construction and on every admin call (`*AuthError`, `admin request not sent: …`). Neither error has a `Cause` or quotes the token, and HTAB, spaces and non-ASCII bytes are sent as before. ⚠️ `AuthError.OAuthError` now carries the token endpoint's `error` only when it fits the RFC 6749 §5.2 grammar exactly (`1*NQSCHAR` — printable ASCII without `"` and `\`), and is empty otherwise; it used to carry CR, LF, NUL, DEL, HTAB, non-ASCII, `"` or `\` verbatim. The module now requires `golang.org/x/sync` v0.24.0 (it was v0.23.0). No public API changed.

## Requirements

Go **1.26+** for the published `1.2.5` (the `go.mod` on that tag declares `go 1.26.0`, as on `1.1.0`), against a Keycloak 26.6.x server. ⚠️ **`1.0.0` needed only Go 1.25** — `golang.org/x/oauth2` v0.37 and `golang.org/x/sync` v0.23 raised the floor, so a module still on 1.25 stays on `v1.0.0`.

## Install

Go modules have no registry — the VCS tag *is* the release. This SDK lives in the `go/` subdirectory of a monorepo, so its release tags are prefixed `go/v...` while the import path carries the `/go` suffix and the package name is `keycloak`. The `go/v1.2.5` tag is published, so the module resolves from the Go module proxy:

```bash
go get github.com/xzawed/KeyCloakSDK/go@v1.2.5
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
- **Hardened claims** — exact `iss` match, `aud` containment check (against `Config.ExpectedAudience`, the client id by default; the id_token checked by `ExchangeCode` must always name the client id), mandatory `exp` (a token without one is rejected — go-jose skips the expiry check when the claim is absent, so the SDK enforces it), and a bounded clock skew (`Config.ClockSkew`, default 30s).
- **Bounded token input** — a token longer than 256,000 bytes is rejected with `*TokenValidationError` (wrapped in the `*AuthError` that `ExchangeCode` returns for its id_token) before it is decoded and before any JWKS request.
- **DoS-safe JWKS** — a fetched key set is used for 300 seconds; after that the next validation fetches it again as on a cold cache and fails if that fetch fails (expired keys are never used, not even during an IdP outage). Until then a refetch is triggered only by an unresolved key ID (rotation) and never by a bad signature, and is rate-limited by `Config.JwksMinRefetch` (default 30s) — so **while the key set is fresh**, no volume of forged random `kid`s makes the SDK issue more than one JWKS request per interval. A *failed* fetch is bounded separately: consecutive failures back off exponentially (0.2s, doubling, capped at 5s, with jitter), and inside that window the SDK **fails fast without contacting the IdP**. So a cold or expired cache during an IdP outage no longer turns every validation into a request (measured: 20 attempts → 1 request, down from 20). ⚠️ The SDK never sleeps — it returns the error immediately, so retry pacing stays the caller's decision.
- **Secret handling** — `Config`, `TokenSet` and `AuthorizationRequest` mask secrets, tokens and the PKCE verifier fully (`***`, no prefix) in both `String()` and their `slog.LogValuer` hook; TLS verification is on by default and both connect and read timeouts are always applied.

Masking covers this SDK's own `String()` methods, which is what `%v`/`%s` formatting reaches, its `GoString()` methods, which is what `%#v` reaches, and its `LogValue() slog.Value` hook, which is what `log/slog`'s JSON and Text handlers reach. It does not cover a third-party structured logger that reflects over the struct fields without honouring `slog.LogValuer` — masking is defence in depth, not a guarantee about your logs. (⚠️ This line used to say `%#v` was *not* covered; `GoString()` landed on all three masked types and [SECURITY.md](../SECURITY.md) already said so.)

## Versioning and support

This SDK is **`1.0`** and follows SemVer: a breaking change to the public API requires a **major** bump. That promise is machine-backed — CI diffs this lane's public API against the **previously published artifact** on every build (`gorelease`, judged on its report body), and a removal or an incompatible change fails the build. ⚠️ **The gate compares the API _surface_.** A change that leaves the surface identical but alters behaviour is not caught by it, so read the release notes before upgrading.

Only the newest released version of each language SDK receives security fixes; there are no long-term-support lines and older releases are not backported to.

**Each of the nine languages versions independently.** All nine reached `1.0.0` in the same release wave because they earned the same guarantee at the same time — they do **not** move in lockstep afterwards.

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md) — install and quickstart for this language
- [Compatibility](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/reference/compatibility.md) — which Keycloak server range and base libraries each published version shipped against
- [Full Go example](https://github.com/xzawed/KeyCloakSDK/blob/main/go/example_test.go) — the runnable godoc example
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/go/LICENSE)
