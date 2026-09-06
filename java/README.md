# Keycloak SDK for Java

A Keycloak client library for Java that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layers, and flows are isomorphic across every language — [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.0.0` is on Maven Central** — the first release carrying the stability guarantee below. ⚠️ **Maven never picks a version for you**: a `<dependency>` with no `<version>` and no BOM managing it fails the build rather than resolving to the newest release, so name `1.0.0` explicitly as shown below.

## Requirements

- **JDK 21+** — artifacts are compiled with `--release 21`, so an older JDK raises `UnsupportedClassVersionError`.
- Maven 3.9+.
- A Keycloak server to connect to (integration-tested against Keycloak 26.6).

## Install

The SDK ships as several Maven modules, but **most users need exactly one**: `io.github.xzawed:keycloak-sdk`. It is the aggregate facade artifact and pulls in `keycloak-sdk-core`, `-auth`, and `-admin` transitively.

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>1.0.0</version>
</dependency>
```

| Module | What it is |
|---|---|
| `keycloak-sdk` | **Aggregate facade — start here.** `KeycloakClient` entry point |
| `keycloak-sdk-bom` | Dependency management only (import scope) |
| `keycloak-sdk-core` | Config, error hierarchy, secret masking, tokens |
| `keycloak-sdk-auth` | OIDC / OAuth2 flows and hardened JWT validation |
| `keycloak-sdk-admin` | Admin REST resources: users, clients, realms, roles, groups |

If you depend on the modules individually, import the BOM so their versions stay aligned:

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>io.github.xzawed</groupId>
      <artifactId>keycloak-sdk-bom</artifactId>
      <version>1.0.0</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
```

## Quickstart

```java
import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.auth.ValidatedToken;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.Secrets;
import io.github.xzawed.keycloak.core.TokenSet;
import org.keycloak.representations.idm.UserRepresentation;

KeycloakConfig config = KeycloakConfig.builder()
    .serverUrl("https://kc.example.com")
    .realm("myrealm")
    .clientId("admin-cli")
    .clientSecret("changeme".toCharArray())   // load from an env var / secret manager
    .build();

// try-with-resources: close() releases the admin client if it was created (AuthClient holds no closeable session).
try (KeycloakClient client = KeycloakClient.create(config)) {
  // 1. Get a token (client-credentials grant). Never log the raw value.
  TokenSet tokens = client.auth().clientCredentialsToken();
  System.out.println("access token: " + Secrets.mask(tokens.getAccessToken()));

  // 2. Validate it (hardened, see below).
  ValidatedToken vt = client.auth().validate(tokens.getAccessToken());
  System.out.println("subject=" + vt.getSubject() + " aud=" + vt.getAudience());

  // 3. Call the Admin API. admin() is created lazily on first access.
  UserRepresentation alice = new UserRepresentation();
  alice.setUsername("alice");
  alice.setEnabled(true);
  String userId = client.admin().users().create(alice);
  System.out.println("created userId=" + userId);
}
```

> **Audience on a default realm** — `validate()` requires the token's `aud` to contain `expectedAudience`, which defaults to your `clientId`. A stock Keycloak realm does *not* put the client id into a client-credentials token's `aud`, so on a default realm step 2 fails until you either set `.expectedAudience("my-api")` to the audience your realm actually issues (also the right setting when the token targets a resource server rather than the requesting client), or add an *Audience* protocol mapper to the client in Keycloak.

## Security defaults

- **Algorithm pinning** — the accepted signature algorithms are fixed by config (`RS256` by default); `alg: none` and header-supplied algorithms are rejected.
- **Strict claim checks** — exact `iss` match, `aud` containment check, mandatory `exp`, and a bounded clock skew (30s by default).
- **DoS-safe JWKS refetch** — key sets are cached, a refetch is triggered only by an unresolved key ID and never by a bad signature, and refetches are rate-limited to a minimum interval (`jwksMinRefetch`, 30s by default) — so no volume of forged tokens makes this SDK issue more than **two** JWKS requests per interval. (Two, not one: the underlying Nimbus rate limiter opens each window with one request already credited. Measured against a flood of unresolved key ids.)
- **Secret handling** — `TokenSet.toString()` masks tokens as `***` (no prefix), `KeycloakConfig` holds the client secret in a `char[]` and has no field-printing `toString()`, and `Secrets.mask(…)` is provided for your own log statements. TLS verification is on by default.

Masking covers this SDK's own `toString()` and serialization; it cannot cover what your logging framework, a debugger, or a heap dump does with a value you hand it. The `char[]` secret is defence in depth rather than an erasure guarantee — `keycloak-admin-client` and Nimbus both take `String`, so the secret is copied into an unerasable heap string at the point of use.

## Versioning and support

This SDK is **`1.0`** and follows SemVer: a breaking change to the public API requires a **major** bump. That promise is machine-backed — CI diffs this lane's public API against the **previously published artifact** on every build (`japicmp`, bound to `mvn verify`), and a removal or an incompatible change fails the build. ⚠️ **The gate compares the API _surface_.** A change that leaves the surface identical but alters behaviour is not caught by it, so read the release notes before upgrading.

Only the newest released version of each language SDK receives security fixes; there are no long-term-support lines and older releases are not backported to.

**Each of the nine languages versions independently.** All nine reached `1.0.0` in the same release wave because they earned the same guarantee at the same time — they do **not** move in lockstep afterwards.

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md) — install and quickstart for this language
- [Compatibility](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/reference/compatibility.md) — which Keycloak server range and base libraries each published version shipped against
- [Full Java example](https://github.com/xzawed/KeyCloakSDK/blob/main/java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java)
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

Apache-2.0 — see [LICENSE](https://github.com/xzawed/KeyCloakSDK/blob/main/java/LICENSE).
