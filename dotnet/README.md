# Keycloak SDK for .NET

An async-first Keycloak client library for .NET that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layers, and flows are isomorphic across every language — [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **Pre-release** — not yet published to NuGet.

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

## Secure by default

- **Algorithm pinning** — the accepted signature algorithms are fixed by config (`RS256` by default); `alg: none` and header-supplied algorithms are rejected.
- **Strict claim checks** — exact `iss` match, `aud` containment check, mandatory `exp`, and a bounded clock skew (30s by default).
- **DoS-safe JWKS refetch** — key sets are cached and rate-limited, and a refetch happens only for an unresolved key ID, so forged tokens cannot amplify traffic to your IdP.
- **Secrets stay secret** — `KeycloakConfig` and `TokenSet` mask secrets and tokens (`***`) in `ToString()` and JSON serialization, and TLS verification is on by default.

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#c--net) — install, quickstart, and the compatibility matrix for all nine languages
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

Apache-2.0 — see [LICENSE](https://github.com/xzawed/KeyCloakSDK/blob/main/dotnet/LICENSE).
