# Keycloak SDK for .NET

An async-first Keycloak client library for .NET that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layers, and flows are isomorphic across every language — [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.0.7` is on NuGet** — a patch release on top of `1.0.6`; `1.0.0` was the first release carrying the stability guarantee set out under *Versioning and support* below. A bare `dotnet add package Xzawed.Keycloak.Sdk` resolves it. **Security**: the admin client now holds the access token it sends as a Bearer to one rule shared by all nine SDKs: leading and trailing SP, HTAB, CR and LF are stripped, and unless what remains is a non-empty RFC 6750 `b64token` (ASCII letters and digits and `-._~+/`, with `=` only at the end) the request is not sent, and the error does not quote the token. `BearerHandler` (typed, raw REST and `Raw`) and the SDK's token provider apply it — `KeycloakTransportException` when sending, `KeycloakAuthException` from the SDK's grant — and the provider does not cache such a token. Inner HTAB and SP used to be sent as is (Keycloak 26.6 answers 401), a null or empty token went out as a bare `Bearer`, and a non-ASCII character escaped through `Raw` as an `HttpRequestException` from outside the SDK. ⚠️ A token that ends in a newline used to be rejected and is now stripped and sent. The responses the SDK reads itself (token, introspection, discovery, JWKS and admin) are now read in full within the configured timeout, counted from when the request is sent. The timeout used to apply to each read only, and the discovery and JWKS bodies had not even that, so a server that trickled bytes, each just inside the read timeout, held one call for about the size cap times the read timeout (7 seconds with a 1-second setting); such a call now ends with the existing timeout error, within the deadline plus one read (exactly at the deadline for the JWKS). A JWKS key set now expires 300 seconds after the load that fetched it finished (it was 12 hours), and an expired set is treated as a cold cache: the next validation fetches it again through the cold-load path (the same single flight and the same failure backoff) and rejects the token if that fetch fails, instead of validating with the stale keys — the .NET SDK used to keep accepting them even during an outage. Two paths that accepted tokens on a stale configuration are closed: `ConfigurationManager` handed out the configuration it held even past its refresh interval while it fetched a new one in the background, and only logged a failure; and the handler validated again after a load failure (IDX10500) against the last-known-good configuration, which lived for 1 hour after the last acceptance. When the SDK refetches it now builds a new manager and loads cold, and last-known-good is off, so a token signed with a key the IdP removed in a rotation is no longer accepted. ⚠️ If the JWKS cannot be reached for more than 300 seconds, validation fails — by design, because the SDK cannot tell an unreachable JWKS from a key the IdP has removed. The failure backoff's jitter (×[0.5, 1.0)) was drawn again at every check, so the same failure could refuse a validation at 190 ms and send the next one to the IdP at 191 ms; it is now drawn once, when the failure happens. **Fixed**: when the IdP rotated its signing key, the first token with the new `kid` was rejected with IDX10503 and only the next one was accepted (measured) — the Microsoft.IdentityModel handler that could not find the key called `RequestRefresh()`, the manager started the refetch in the background (`Task.Run`) and returned at once, and the handler, handed the same configuration again, did not retry. The SDK now runs that refetch itself, and the validation that needed it waits for it within the same call and validates again with the new key (one refetch). The 30-second window (stamped when the refetch is decided; a failure uses the window too), the single flight, a refetch that runs to completion even when its caller cancels, and the failure backoff are unchanged; a token whose key resolves does not wait; and no process-wide AppContext switch is touched. A `JsonException` thrown by your `ITokenProvider` inside an admin call was turned by the nine typed read and write calls, even a `DeleteAsync` with no body, into a `KeycloakTransportException` saying the request body could not be encoded as JSON (measured): the token provider runs before the request body is written, but every `JsonException` before the response was read as a request-body failure. The provider's exception now propagates as is, as it already did from the warm-up in `AdminClient.CreateAsync`, typed creation and raw calls; a request body that cannot be written keeps that message. The package now depends on `Microsoft.Extensions.DependencyInjection.Abstractions` 9.0.22 or later (it was 9.0.21). No public API changed.
>
> `1.0.6` was a patch release on top of `1.0.5`. **Security**: the admin client read a response body to its end even after it had the result. The typed client (Keycloak.AuthServices) and the raw path both sent with `ResponseContentRead`, so `HttpClient` buffered the whole body before the result was looked at: a server wrote all of the 64 MiB it attached to the 201 body of a `CreateAsync` or the 2xx body of an `UpdateAsync` or `DeleteAsync` (38–183 ms), and a server that stalled after a 2xx head turned a write call — even a `CreateAsync` that already had its `Location` — into a `KeycloakTransportException` (`admin request timed out`) at the end of the read timeout (4,003–4,020 ms across the fifteen write calls with a 4-second timeout). Error bodies were read to their end too: a 404 or 300 with 64 MiB put 67,108,864 characters in the exception message (one call allocated 201–337 MB), and the `Raw` client handed over those 67,108,864 bytes as well. The facade's fifteen write calls (`CreateAsync`, `UpdateAsync` and `DeleteAsync` on the five resources) now leave a 2xx body unread (the server wrote at most 196,610 bytes; 1–24 ms in front of a stalled server), and an error body (3xx and above) is held only up to 1,048,576 bytes, the token-response cap — one byte more is read to see whether it goes over, and the rest is not read (4.3–7.4 MB for one call with a 64 MiB error body). The exception class (`KeycloakNotFoundException` and the like) is unchanged and the message is cut at that length; where the cut splits the JSON, a call whose error body the typed client parses itself (`GetAsync`, `SearchAsync`, `UpdateAsync` and `DeleteAsync` on `Users`; `GetAsync`, `ListAsync`, `UpdateAsync` and `DeleteAsync` on `Groups`; `Realms.GetAsync`) has the message `admin error response body could not be decoded`. An error body that stalls after passing the cap ends with its status without waiting out the read timeout (it used to end in `admin request timed out` after 4,001–4,014 ms). The `Raw` client still receives a 2xx body (its error body has the same cap, and that response's `Content-Length` is the length kept), success bodies (`GetAsync`, `SearchAsync`, lists) are not capped, the connection of a response not read to its end is discarded, and the connection of a 2xx with no body (an empty 201, a 204) is reused as before. Admin responses are not decompressed, so the cap counts the bytes received. The 256,000-byte cap on a token to validate is now the SDK's own: it used to rely on Microsoft.IdentityModel's default (`DefaultMaximumTokenSizeInBytes` — a token over it was refused as IDX10209 without a discovery or JWKS request, measured); the handler now sets that value explicitly (`MaximumTokenSizeInBytes`) and the SDK checks first. The only change is the message for a token over the cap: `KeycloakTokenValidationException` says `token exceeds 256000 bytes` instead of IDX10209. No public API changed.
>
> `1.0.5` was a patch release on top of `1.0.4`. **Security**: an admin response whose `Content-Type` names a charset .NET does not decode — an unknown name (`charset=bogus-cs`, a quoted name, an empty `charset=""`) or the disabled UTF-7 — no longer escapes an admin call that reads its body as a raw `InvalidOperationException` (whose `ToString()` quoted the charset name) or `NotSupportedException`. It now raises the SDK exception that call gives any body it cannot decode: `KeycloakAdminException` (500, `admin response body could not be decoded`) for a 2xx body, and for an error body an exception that keeps the HTTP status (`KeycloakNotFoundException` for a 404, `admin error response body could not be decoded`); the cause chain keeps only the lower exception's type. A response refused for its size by the clients `KeycloakClient.Create` builds is no longer read after the refusal — `SocketsHttpHandler` used to drain the rest (up to `MaxResponseDrainSize`, 1 MiB by default, for up to 2 seconds) to reuse the connection, and the handler the SDK builds (one shared by auth, JWKS and admin) now closes it instead. Responses read to the end are reused as before, and an `HttpClient` passed to the `AuthClient` or `JwtValidator` public constructor keeps its own handler's drain. An admin bearer holding NUL, DEL or another C0 control character other than HTAB — from your `ITokenProvider` or from the token endpoint — now fails before it is sent, as CR and LF already did, with `KeycloakTransportException` (`admin request failed: the access token holds a NUL, DEL or other control character, which an HTTP header cannot carry`); .NET used to send it. **Fixed**: once the cached OIDC configuration (JWKS) was past its 12-hour automatic refresh, a failing IdP (discovery or JWKS `503`, or `200` with `{"keys":[]}`) got a refetch on every validation, because `Microsoft.IdentityModel` moves the next refresh time only on success; and concurrent validations on a cold cache each refetched when the first load failed. Every discovery and JWKS fetch now goes through the cold cache's failure backoff (0.2 seconds, doubling to at most 5, reset by a success), so the IdP gets one request per window; meanwhile tokens that validate against the stale configuration are still accepted, and a successful refresh after the window brings in rotated keys. The 12-hour refresh and the 30-second forced-refetch interval are unchanged, and so is the request count against a healthy IdP. The package now depends on `Microsoft.Extensions.DependencyInjection.Abstractions` 9.0.21 or later (it was 9.0.20). No public API changed.

## Requirements

- **.NET 8+** — the package targets `net8.0`.
- A Keycloak server to connect to (integration-tested against Keycloak 26.6).

Every network method returns `Task<T>` and takes a trailing `CancellationToken ct = default`; only `CreateAuthorizationRequest` is synchronous, because it needs no network.

## Install

```bash
dotnet add package Xzawed.Keycloak.Sdk
```

The root namespace is `Xzawed.Keycloak` (Admin resources live in `Xzawed.Keycloak.Admin`).

## Quickstart

```csharp
using Keycloak.AuthServices.Sdk.Admin.Models;
using Xzawed.Keycloak;

var config = new KeycloakConfig
{
    ServerUrl = "https://kc.example.com",
    Realm = "myrealm",
    ClientId = "admin-cli",
    ClientSecret = "changeme", // load from an env var / secret manager
};

// await using: DisposeAsync() releases the auth resources and, if used, the admin client.
await using var kc = KeycloakClient.Create(config);

// 1. Get a token (client-credentials grant). TokenSet.ToString() masks the tokens as "***".
var tokens = await kc.Auth.ClientCredentialsTokenAsync();
Console.WriteLine(tokens);

// 2. Validate it (hardened, see below).
var vt = await kc.Auth.ValidateAsync(tokens.AccessToken);
Console.WriteLine($"subject={vt.Subject} aud=[{string.Join(",", vt.Audience)}]");

// 3. Call the Admin API. The admin facade is built lazily on first AdminAsync().
var admin = await kc.AdminAsync();
var userId = await admin.Users.CreateAsync(new UserRepresentation { Username = "alice", Enabled = true });
Console.WriteLine($"created userId={userId}");
```

> **Audience** — validation requires the token's `aud` to contain `ClientId`. A stock realm does *not* put the client id in a client-credentials token's `aud`, so on a default realm either set `ExpectedAudience = "my-api"` to the audience your realm issues, or add an *Audience* protocol mapper to the client in Keycloak.

Dependency injection is **optional** — `KeycloakClient.Create(config)` works standalone. If you do use a container, register the client as a singleton:

```csharp
builder.Services.AddKeycloak(config); // registers KeycloakConfig + KeycloakClient as singletons
```

Admin failures surface as `KeycloakNotFoundException` / `KeycloakConflictException` / `KeycloakForbiddenException` (all carrying `KeycloakAdminException.StatusCode`), or `KeycloakTransportException` on a network failure.

## Security defaults

- **Algorithm pinning** — the accepted signature algorithms are fixed by config (`RS256` by default); `alg: none` and unsigned tokens are rejected. `Microsoft.IdentityModel` leaves `ValidAlgorithms` unset, which accepts every algorithm it supports, so the SDK pins it explicitly.
- **Strict claim checks** — exact `iss` match, `aud` containment check, mandatory `exp`, and a bounded clock skew (30s by default, down from the library's 5 minutes).
- **Bounded token input** — a token longer than 256,000 bytes is rejected with `KeycloakTokenValidationException` (the inner exception of the `KeycloakAuthException` that `ExchangeCodeAsync` throws for its id_token) before it is decoded and before any discovery or JWKS request.
- **Rate-limited JWKS refetch** — key sets are cached for 300 seconds. The first validation after that fetches the key set again, inside the call, and if that fetch fails the validation fails (`KeycloakTokenValidationException`): keys older than 300 seconds are never used, even during an IdP outage — `Microsoft.IdentityModel`'s last-known-good fallback is turned off for that reason. Within those 300 seconds refetches are throttled to a minimum interval (`JwtValidatorOptions.RefreshIntervalSeconds`, 30s by default — the same value as the other eight SDKs). Read this one precisely: unlike its sibling SDKs, this one **cannot** promise that a bad signature never causes a refetch. `Microsoft.IdentityModel` treats signature-validation failure as a possible key rotation and refreshes through its `ConfigurationManager`, and that behaviour cannot be disabled without giving up the manager entirely. The refresh interval is what bounds the amplification — measured, 6 forged tokens produce 1 extra fetch, not 6. A *failed* fetch is bounded separately: consecutive failures back off exponentially (0.2s, doubling, capped at 5s, with jitter), and inside that window the SDK **fails fast without contacting the IdP**. So a cold cache during an IdP outage no longer turns every validation into a request (measured: 20 attempts → 2 requests, down from 40 — this lane spends two requests per attempt, so one window costs two). ⚠️ The SDK never sleeps — it returns the error immediately, so retry pacing stays the caller's decision.
- **Secret handling** — `KeycloakConfig`, `TokenSet` and `AuthorizationRequest` mask secrets, tokens and the PKCE `CodeVerifier` as `***` in `ToString()` and JSON serialization, and TLS verification is on by default.

Masking covers `ToString()` and the types' JSON converters. It does **not** cover Serilog-style destructuring — `{@Config}` reads the properties directly and will print the raw secret, so log these three types with `{Config}`, not `{@Config}`.

## Versioning and support

This SDK is **`1.0`** and follows SemVer: a breaking change to the public API requires a **major** bump. That promise is machine-backed — CI diffs this lane's public API against the **previously published artifact** on every build (the .NET SDK’s **Package Validation**, run during `dotnet pack`), and a removal or an incompatible change fails the build. ⚠️ **The gate compares the API _surface_.** A change that leaves the surface identical but alters behaviour is not caught by it, so read the release notes before upgrading.

Only the newest released version of each language SDK receives security fixes; there are no long-term-support lines and older releases are not backported to.

**Each of the nine languages versions independently.** All nine reached `1.0.0` in the same release wave because they earned the same guarantee at the same time — they do **not** move in lockstep afterwards.

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#c--net) — install and quickstart for this language
- [Compatibility](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/reference/compatibility.md) — which Keycloak server range and base libraries each published version shipped against
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

Apache-2.0 — see [LICENSE](https://github.com/xzawed/KeyCloakSDK/blob/main/dotnet/LICENSE).
