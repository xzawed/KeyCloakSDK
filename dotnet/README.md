# Keycloak SDK for .NET

An async-first Keycloak client library for .NET that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layers, and flows are isomorphic across every language — [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`0.1.0` is on NuGet** — the first stable release. `dotnet add package Xzawed.Keycloak.Sdk` now resolves it without `--prerelease`.

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
- **Rate-limited JWKS refetch** — key sets are cached and refetches are throttled to a minimum interval (`JwtValidatorOptions.RefreshIntervalSeconds`, 30s by default — the same value as the other eight SDKs). Read this one precisely: unlike its sibling SDKs, this one **cannot** promise that a bad signature never causes a refetch. `Microsoft.IdentityModel` treats signature-validation failure as a possible key rotation and refreshes through its `ConfigurationManager`, and that behaviour cannot be disabled without giving up the manager entirely. The refresh interval is what bounds the amplification — measured, 6 forged tokens produce 1 extra fetch, not 6.
- **Secret handling** — `KeycloakConfig` and `TokenSet` mask secrets and tokens as `***` in `ToString()` and JSON serialization, and TLS verification is on by default.

Masking covers `ToString()` and the types' JSON converters. It does **not** cover Serilog-style destructuring — `{@Config}` reads the properties directly and will print the raw secret, so log these two types with `{Config}`, not `{@Config}`.

## Versioning and support

This SDK is **pre-1.0**. Under SemVer a `0.x` **minor** bump may carry breaking changes, so read the release notes before upgrading. Only the newest released version of each language SDK receives security fixes — there are no LTS lines, and older `0.x` releases are not backported to. Full policy: [SECURITY.md](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md).

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#c--net) — install, quickstart, and the compatibility matrix for all nine languages
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

Apache-2.0 — see [LICENSE](https://github.com/xzawed/KeyCloakSDK/blob/main/dotnet/LICENSE).
