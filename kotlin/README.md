# Keycloak SDK for Kotlin

A coroutine-first Keycloak client library for Kotlin/JVM that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layers, and flows are isomorphic across every language — [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **Pre-release** — not yet published to Maven Central.

## Requirements

- **Kotlin 2.2+** on **JDK 21+** (the module targets `jvmToolchain(21)`). The SDK is built with Kotlin 2.4.10 but pins `languageVersion`/`apiVersion` to 2.2, so its published metadata is consumable by any Kotlin 2.2+ compiler.
- A Keycloak server to connect to (integration-tested against Keycloak 26.6).

Every network call is a `suspend` function — blocking calls into the underlying JVM libraries run on `Dispatchers.IO` via `runInterruptible`. Only `createAuthorizationRequest` is synchronous, because it needs no network. Public API visibility is enforced with `explicitApi()`.

This SDK reuses the verified JVM stack of its sibling Java SDK — `org.keycloak:keycloak-admin-client` 26.0.11, `com.nimbusds:oauth2-oidc-sdk` 11.38.2, and `com.nimbusds:nimbus-jose-jwt` 10.9.1 — plus `kotlinx-coroutines-core` 1.11.0 for the coroutine boundary.

## Install

Gradle Kotlin DSL:

```kotlin
dependencies {
    implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0")
}
```

## Quickstart

```kotlin
import io.github.xzawed.keycloak.KeycloakClient
import io.github.xzawed.keycloak.KeycloakConfig
import kotlinx.coroutines.runBlocking
import org.keycloak.representations.idm.UserRepresentation

fun main() = runBlocking {
    val config = KeycloakConfig(
        serverUrl = "https://kc.example.com",
        realm = "myrealm",
        clientId = "admin-cli",
        clientSecret = "changeme".toCharArray(), // load from an env var / secret manager
    )

    // use { }: close() releases the auth resources and, if used, the admin client.
    KeycloakClient.create(config).use { client ->
        // 1. Get a token (client-credentials grant). TokenSet.toString() masks the tokens as "***".
        val token = client.auth.clientCredentialsToken()
        println("token type=${token.tokenType} expiresAt=${token.expiresAt}")

        // 2. Validate it (hardened, see below).
        val validated = client.auth.validate(token.accessToken)
        println("subject=${validated.subject} issuer=${validated.issuer}")

        // 3. Call the Admin API. admin is created lazily on first access.
        val userId = client.admin.users().create(
            UserRepresentation().apply {
                username = "alice"
                isEnabled = true
            },
        )
        println("created userId=$userId")
    }
}
```

> **Audience on a default realm** — `validate` requires the token's `aud` to contain `expectedAudience`, which defaults to your `clientId`. A stock Keycloak realm does *not* put the client id into a client-credentials token's `aud`, so on a default realm step 2 fails until you either set `expectedAudience = "my-api"` to the audience your realm actually issues (also the right setting when the token targets a resource server rather than the requesting client), or add an *Audience* protocol mapper to the client in Keycloak.

Admin failures surface as the sealed `KeycloakAdminException` (`NotFound` / `Conflict` / `Forbidden` / `Other`, each carrying `status`), or `KeycloakTransportException` on a network failure — so a `when` over them is exhaustive.

## Security defaults

- **Algorithm pinning** — the accepted signature algorithms are fixed by config (`RS256` by default); `alg: none` and header-supplied algorithms are rejected.
- **Strict claim checks** — exact `iss` match, `aud` containment check, mandatory `exp`, and a bounded clock skew (30s by default).
- **DoS-safe JWKS refetch** — key sets are cached, a refetch is triggered only by an unresolved key ID and never by a bad signature, and refetches are rate-limited to a minimum interval (`jwksMinRefetch`, 30s by default) — so no volume of forged tokens makes this SDK issue more than one JWKS request per interval.
- **Secret handling** — `KeycloakConfig.toString()` and `TokenSet.toString()` mask the client secret and tokens as `***` (no prefix), and the secret is held as a `CharArray`. TLS verification is on by default.

Masking covers this SDK's own `toString()` and serialization; it cannot cover what your logging framework, a debugger, or a heap dump does with a value you hand it. The `CharArray` secret is defence in depth rather than an erasure guarantee — `keycloak-admin-client` and Nimbus both take `String`, so the secret is copied into an unerasable heap string at the point of use.

## Versioning and support

This SDK is **pre-1.0**. Under SemVer a `0.x` **minor** bump may carry breaking changes, so read the release notes before upgrading. Only the newest released version of each language SDK receives security fixes — there are no LTS lines, and older `0.x` releases are not backported to. Full policy: [SECURITY.md](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md).

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md) — install, quickstart, and the compatibility matrix for all nine languages
- [Full Kotlin example](https://github.com/xzawed/KeyCloakSDK/blob/main/kotlin/examples/quickstart.kt)
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

Apache-2.0 — see [LICENSE](https://github.com/xzawed/KeyCloakSDK/blob/main/kotlin/LICENSE).
