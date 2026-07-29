# Keycloak SDK for Java

A Keycloak client library for Java that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layers, and flows are isomorphic across every language — [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **Pre-release** — not yet published to Maven Central.

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
  <version>0.1.0</version>
</dependency>
```

| Module | What it is |
|---|---|
| `keycloak-sdk` | **Aggregate facade — start here.** `KeycloakClient` entry point |
| `keycloak-sdk-bom` | Dependency management only (import scope) |
| `keycloak-sdk-core` | Config, error hierarchy, secret masking, tokens, OIDC endpoints |
| `keycloak-sdk-auth` | OIDC / OAuth2 flows and hardened JWT validation |
| `keycloak-sdk-admin` | Admin REST resources: users, clients, realms, roles, groups |

If you depend on the modules individually, import the BOM so their versions stay aligned:

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>io.github.xzawed</groupId>
      <artifactId>keycloak-sdk-bom</artifactId>
      <version>0.1.0</version>
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

// try-with-resources: close() releases the auth session and, if used, the admin client.
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

## Secure by default

- **Algorithm pinning** — the accepted signature algorithms are fixed by config (`RS256` by default); `alg: none` and header-supplied algorithms are rejected.
- **Strict claim checks** — exact `iss` match, `aud` containment check, mandatory `exp`, and a bounded clock skew (30s by default).
- **DoS-safe JWKS refetch** — key sets are cached and rate-limited, and a refetch happens only for an unresolved key ID, so forged tokens cannot amplify traffic to your IdP.
- **Secrets stay secret** — tokens and client secrets are fully masked (`***`) in logs and `toString()`, and TLS verification is on by default.

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md) — install, quickstart, and the compatibility matrix for all nine languages
- [Full Java example](https://github.com/xzawed/KeyCloakSDK/blob/main/java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java)
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

Apache-2.0 — see [LICENSE](https://github.com/xzawed/KeyCloakSDK/blob/main/java/LICENSE).
