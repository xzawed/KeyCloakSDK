# Keycloak SDK for Java

A Keycloak client library for Java that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layers, and flows are isomorphic across every language — [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.2.1` is on Maven Central** — a minor release on top of `1.1.0`. (`1.2.0` was tagged but never published: the Central Portal rejected its bundle because `keycloak-sdk-auth`'s POM left the versions of its two new dependencies to the parent's `dependencyManagement`. `1.2.1` is the same change with those versions written out; the versions a consumer resolves are unchanged.) **Security**: the response caps now bound a response's framing, not only its body. The auth calls and the JWKS fetch went through the JDK's `HttpURLConnection`, which buffered chunked trailers without limit (a token response carrying 32 MiB of trailer lines was accepted, about 170 MB allocated for one call), drained the rest of an over-cap chunked body when closing it, and let endless `1xx` interim responses escape as a `StackOverflowError`. They now go through Apache HttpClient 4.5.14 / HttpCore 4.4.16, which the admin client already used. Both lanes read response lines up to 8,192 bytes and header (trailer) sections up to 100 fields; the auth lane also holds the framing read with a body to 8 times the body cap, accepts at most 8 `1xx` responses and refuses a first line that is not a status line. A response over a limit fails with that lane's `KeycloakTransportException`, and on the auth lane its connection is closed rather than drained; an admin framing error no longer quotes the offending line in its cause chain. The admin client also stops reading a token response it rejects, and refuses an access token an HTTP header cannot carry (CR, LF, NUL, another C0 control other than HTAB, or DEL) before any admin request — HttpCore used to rewrite it silently. A `KeycloakAuthException` message no longer prints a value the request sent (client secret, Basic credentials, refresh or introspected token, authorization code, verifier) that the IdP echoed in `error_description`: a verbatim echo kept its leading word once Nimbus stripped the non-ASCII characters, and encoded forms — percent-encoded as the common encoders write it, encoded twice, `%uXXXX`, HTML numeric references — were printed whole. Such spans are now masked as `***`, and an `error_description` over 4,096 characters is replaced by `(error_description omitted: N chars > 4096)`. ⚠️ The admin client's token-request error keeps its type and message, but its cause chain is now a copy holding only type names and stack frames — code that pulled a `WebApplicationException` (and its buffered response body) out of it no longer finds one. **Added**: `ResponseLimits.MAX_LINE_LENGTH` and `ResponseLimits.MAX_HEADER_COUNT` in `io.github.xzawed.keycloak.core` — the two additions that make this release a minor one. ⚠️ **`keycloak-sdk-auth` has new direct dependencies**: `org.apache.httpcomponents:httpclient` 4.5.14 (with `httpcore` 4.4.16 and `commons-logging` 1.2) and `commons-codec` 1.15 at runtime — the versions the admin module already brought in. ⚠️ **Connections are now pooled** in one process-wide pool, up to 50 per route (host, port, proxy): idle connections do not close on their own (the next call closes those idle for 5 seconds, or for the server's shorter `Keep-Alive` timeout), a call beyond 50 concurrent connections to one route waits for one, the JVM-wide `CookieHandler`, `ResponseCache` and `java.net.Authenticator` are no longer consulted, and a new connection dropped before its status line is not retried. ⚠️ **Maven never picks a version for you**: a `<dependency>` with no `<version>` and no BOM managing it fails the build rather than resolving to the newest release, so name `1.2.0` explicitly as shown below.

## Requirements

- **JDK 17+** — artifacts are compiled with `--release 17`, so an older JDK raises `UnsupportedClassVersionError`. ⚠️ **`1.0.0` needed JDK 21**; `1.0.1` is the release that lowered the floor.
- Maven 3.9+.
- A Keycloak server to connect to (integration-tested against Keycloak 26.6).

## Install

The SDK ships as several Maven modules, but **most users need exactly one**: `io.github.xzawed:keycloak-sdk`. It is the aggregate facade artifact and pulls in `keycloak-sdk-core`, `-auth`, and `-admin` transitively.

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>1.2.1</version>
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
      <version>1.2.1</version>
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

Masking covers this SDK's own `toString()`. ⚠️ It does **not** cover serialization: these types carry no serialization hook, so Jackson or Gson reading their getters emits the raw value — [SECURITY.md](../SECURITY.md) lists exactly that as a measured gap, and this line used to claim the opposite. Nor can masking cover what your logging framework, a debugger, or a heap dump does with a value you hand it. The `char[]` secret is defence in depth rather than an erasure guarantee — `keycloak-admin-client` and Nimbus both take `String`, so the secret is copied into an unerasable heap string at the point of use.

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
