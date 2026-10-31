# Keycloak SDK for Java

A Keycloak client library for Java that covers both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layers, and flows are isomorphic across every language — [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.2.4` is on Maven Central** — a patch release on top of `1.2.3`. **Security**: the admin client now holds the access token it sends as a Bearer to one rule shared by all nine SDKs — after leading and trailing SP, HTAB, CR and LF are stripped, it must be a non-empty RFC 6750 `b64token` (ASCII letters and digits and `-._~+/`, with `=` only at the end). Because the admin library attaches the stored token itself, the admin client accepts the access token of a grant response only when it already is such a `b64token`, with nothing to strip; anything else fails with `KeycloakTransportException` and is not cached. HTAB, SP and Latin-1 used to be sent as is, and HttpCore replaced C1 characters and characters above U+0100 with `?` (measured). The responses the SDK reads itself (token, introspection, JWKS and admin) are now read in full within the configured timeout, counted from when the request is sent. The timeout used to apply to each read only, so a server that trickled bytes, each just inside the read timeout, held one call for about the size cap times the read timeout (on the JVM, 33.6 seconds with one trickled TLS record); such a call now ends with the existing timeout error, within the deadline plus one read. Still open: the admin client's header and chunk framing is timed per read. JWKS key sets now follow one rule in all nine SDKs — a set expires 300 seconds after the load that fetched it finished, and an expired set is treated as a cold cache: the next validation fetches it again through the cold-load path (the same single flight and the same failure backoff) and rejects the token if that fetch fails, instead of validating with the stale keys. The Java SDK's lifetime was already 300 seconds; it now states Nimbus's default 300-second TTL and the disabled outage tolerance explicitly (the behaviour is unchanged) and keeps refresh-ahead: a validation in the last 30 seconds before expiry refreshes the set once in the background, and a failed refresh does not extend its lifetime. ⚠️ If the JWKS cannot be reached for more than 300 seconds, validation fails — by design, because the SDK cannot tell an unreachable JWKS from a key the IdP has removed. **Changed**: ⚠️ an admin response — lists and `raw()` success bodies included — must now arrive in full within the configured timeout (the response deadline above). The timeout used to apply per read, so a large list over a slow link was received to its end; that is now a timeout error, so raise the timeout if you fetch large lists over a slow link. The Go, Rust, Node, PHP and .NET admin clients already behaved this way. The javadoc published to Maven Central (the public API in `-javadoc.jar`) and the comments of `QuickStart.java` are now in English — Java had been left out when the other SDKs were translated, and with it the rendered documentation of all nine SDKs is in English; the code is unchanged. No public API changed. ⚠️ **Maven never picks a version for you**: a `<dependency>` with no `<version>` and no BOM managing it fails the build rather than resolving to the newest release, so name `1.2.4` explicitly as shown below.
>
> `1.2.3` was a patch release on top of `1.2.2`. **Security**: the admin client read a resource response to its end even after it had the result. When RESTEasy closed a response, HttpCore drained the rest of its body to EOF, so a server wrote all of the 64 MiB it attached to the 201 body of a `create` or the 2xx body of an `update` or `delete` (with or without a media type), and when the server stalled after the result, closing the response waited out the read timeout and turned a usable response into a `KeycloakTransportException` (4,020–4,042 ms with a 4-second read timeout in plaintext; 8,041–8,091 ms over TLS 1.3, where the close reads once more). For an error status with a media type (404, 409 and the like), RESTEasy buffered the whole body: one call allocated about 475 MB for a 64 MiB error body and put all of it in `KeycloakAdminException.getKeycloakError()`. Now only a response read to EOF returns its connection to the pool; any other response is peeked at for 1 ms to see whether it has ended, and then its connection is closed (the server wrote 0.2–0.33 MB; 11–70 ms in front of a stalled server). An error body is held only up to 1,048,576 bytes, the token-response cap: the exception class (`KeycloakNotFoundException` and the like) is unchanged and `getKeycloakError()` is cut at that length (10–13 MB for one call with a 64 MiB error body). ⚠️ Reading an error response's stream through `raw()` also reaches its end at that length — an end, not an exception. The error body of the logout that `AdminClient.close()` sends through the built-in TokenManager is held to the same cap, and `close()` still swallows that failure. ⚠️ A JSON success body with a media type (`get`, `search`) is read as before: Jackson reads the whitespace after the value to validate it, and success bodies are not capped. `JwtValidator.validate()` also used memory in proportion to a token's length before it looked at the signature: Nimbus decoded the header (`JWTParser.parse`) and the claims (`DefaultJWTProcessor`, ahead of signature verification) as JSON without a limit, so one forged token allocated 34.0–38.4 bytes per input byte before it was rejected (141–161 MB for a 4 MiB token, measured as thread-allocated bytes). A token longer than 256,000 bytes (`String.length()`) is now rejected with `TokenValidationException` (`token exceeds 256000 bytes`) before it is split or decoded and before any JWKS request, and the id_token that `exchangeCode` verifies goes through the same check — ⚠️ but Nimbus's `OIDCTokenResponseParser` parses that id_token first, along with the token response (inside its 1,048,576-byte cap). The Jackson versions managed in `keycloak-sdk-parent` move from 2.22.3 to 2.22.4 (six artifacts; `jackson-annotations` stays at 2.22). No public API changed.
>
> `1.2.2` was a minor release on top of `1.1.0`. (`1.2.0` and `1.2.1` were tagged but never published: the Central Portal rejected both bundles because the build runner's Maven 3.10.0 left local-repository bookkeeping files in them, which `central-publishing-maven-plugin` 0.11.0 did not remove. `1.2.2` is the same change built with 0.12.0; the versions a consumer resolves are unchanged.) **Security**: the response caps now bound a response's framing, not only its body. The auth calls and the JWKS fetch went through the JDK's `HttpURLConnection`, which buffered chunked trailers without limit (a token response carrying 32 MiB of trailer lines was accepted, about 170 MB allocated for one call), drained the rest of an over-cap chunked body when closing it, and let endless `1xx` interim responses escape as a `StackOverflowError`. They now go through Apache HttpClient 4.5.14 / HttpCore 4.4.16, which the admin client already used. Both lanes read response lines up to 8,192 bytes and header (trailer) sections up to 100 fields; the auth lane also holds the framing read with a body to 8 times the body cap, accepts at most 8 `1xx` responses and refuses a first line that is not a status line. A response over a limit fails with that lane's `KeycloakTransportException`, and on the auth lane its connection is closed rather than drained; an admin framing error no longer quotes the offending line in its cause chain. The admin client also stops reading a token response it rejects, and refuses an access token an HTTP header cannot carry (CR, LF, NUL, another C0 control other than HTAB, or DEL) before any admin request — HttpCore used to rewrite it silently. A `KeycloakAuthException` message no longer prints a value the request sent (client secret, Basic credentials, refresh or introspected token, authorization code, verifier) that the IdP echoed in `error_description`: a verbatim echo kept its leading word once Nimbus stripped the non-ASCII characters, and encoded forms — percent-encoded as the common encoders write it, encoded twice, `%uXXXX`, HTML numeric references — were printed whole. Such spans are now masked as `***`, and an `error_description` over 4,096 characters is replaced by `(error_description omitted: N chars > 4096)`. ⚠️ The admin client's token-request error keeps its type and message, but its cause chain is now a copy holding only type names and stack frames — code that pulled a `WebApplicationException` (and its buffered response body) out of it no longer finds one. **Added**: `ResponseLimits.MAX_LINE_LENGTH` and `ResponseLimits.MAX_HEADER_COUNT` in `io.github.xzawed.keycloak.core` — the two additions that made `1.2.2` a minor release. ⚠️ **`keycloak-sdk-auth` has new direct dependencies**: `org.apache.httpcomponents:httpclient` 4.5.14 (with `httpcore` 4.4.16 and `commons-logging` 1.2) and `commons-codec` 1.15 at runtime — the versions the admin module already brought in. ⚠️ **Connections are now pooled** in one process-wide pool, up to 50 per route (host, port, proxy): idle connections do not close on their own (the next call closes those idle for 5 seconds, or for the server's shorter `Keep-Alive` timeout), a call beyond 50 concurrent connections to one route waits for one, the JVM-wide `CookieHandler`, `ResponseCache` and `java.net.Authenticator` are no longer consulted, and a new connection dropped before its status line is not retried.

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
  <version>1.2.4</version>
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
      <version>1.2.4</version>
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
- **DoS-safe JWKS refetch** — key sets are cached for at most 300 s; the next validation then fetches the set again, and if that fetch fails the validation fails — no fallback to the old keys, even during an IdP outage (a validation in the last 30 s of that age refreshes the set in the background). Before that, a refetch is triggered only by an unresolved key ID and never by a bad signature, and refetches are rate-limited to a minimum interval (`jwksMinRefetch`, 30s by default) — so no volume of forged tokens makes this SDK issue more than **two** JWKS requests per interval. (Two, not one: the underlying Nimbus rate limiter opens each window with one request already credited. Measured against a flood of unresolved key ids.)
- **Bounded token input** — a token longer than 256,000 bytes is rejected with `TokenValidationException` before it is decoded and before any JWKS request. ⚠️ The id_token that `exchangeCode` verifies meets the same bound before any JWKS request, but not before it is decoded: Nimbus's `OIDCTokenResponseParser` parses it along with the token response, which is capped at 1,048,576 bytes.
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
