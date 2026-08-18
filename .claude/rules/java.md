---
paths:
  - "java/**"
  - "harness/apps/java/**"
  - "harness/install/consume/java*"
---

# Java rules

## Toolchain

JDK 21 + Maven 3.9.x. The harness shell does not source a profile, so specify the environment inline.

```bash
JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot}" \
PATH="${KCSDK_TOOLS:-$HOME/tools}/apache-maven-3.9.9/bin:$PATH" mvn -f java/pom.xml <goal>
```

- Full build and verification: `mvn -f java/pom.xml verify` (includes the coverage gate 90/85 and the integration tests; needs Docker)
- Unit only: `mvn -f java/pom.xml test -DskipITs=true` · a single test: `-pl <module> -Dtest=<Class>#<method>`
- Checking the release artifacts locally: `mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package`
- The real release goes `v*` tag → `release.yml` (human approval gate).
- ⚠️ **Do not write the exact patch versions here** — measure them with `java -version` and `node scripts/doctor.mjs java`. Two of them once drifted apart and set inside this very file.
- ⚠️ **`jacoco:check` is bound to the `verify` phase, so `mvn test` never exercises the coverage threshold.**

## Gotchas

- ⚠️ **Stringifying a `char[]` secret unconditionally is a bare NPE on a public/PKCE client.** `getClientSecret()` is null on a public client, and `AuthClient.clientAuth()` passed it straight into `new String(...)`, producing an undiagnosable NPE on all four paths — client-credentials, refresh, logout and introspect. It now takes the name of the calling flow and throws a `KeycloakConfigException` saying that this operation requires a confidential client. **Every point that stringifies a `char[]` secret must be preceded by a null guard.**
- ⚠️ **admin-client and the Keycloak server are independent version tracks** — there is no admin-client numbered like the server line. `representation` fields can disagree with the server, so verify any field you depend on against a real server. The pin's SSOT is the dependency table in the root `CLAUDE.md`. Kotlin reuses the same coordinate.
- ⚠️ **admin timeouts and resource cleanup.** `AdminClient` has to inject connect/read timeouts through `KeycloakBuilder.resteasyClient(...)` to stop an unbounded wait (not injecting = thread-exhaustion DoS). `close()` cleans up **the auth session as well as** admin (not cleaning up = FD and connection-pool leak).
- ⚠️ **But injecting `resteasyClient(...)` bypasses the admin-client's `JacksonProvider` registration entirely.** That loses `NON_NULL` (null fields not sent) together with `FAIL_ON_UNKNOWN_PROPERTIES=false`, which breaks version skew in both directions — client ahead gives a 400 *Unrecognized field*, server ahead breaks deserialization. `buildTimeoutClient` registers `JacksonProvider` and `StreamMessageBodyReader` itself. **Keep `ClientBuilder.newBuilder()`** — switching to `createClientBuilder()` silently drops the connection pool from 50 to 10.
  - **Behavioural contract**: with `NON_NULL` on, a partial update cannot blank a field by setting it to null (an unset field is not sent, so the server treats it as unchanged) — this matches the official admin-client. To blank one, use an empty string or the dedicated API.
- ⚠️ **jackson-databind is fixed through `dependencyManagement`** (the pin lives in the root `CLAUDE.md` table). **Security invariant**: we never use our own `ObjectMapper` or default/polymorphic typing, and only deserialize trusted Keycloak responses into fixed POJOs — enabling default typing, registering a custom JAX-RS Jackson provider, and introducing polymorphic deserialization of untrusted JSON are **all forbidden**, and the CI `invariant` job blocks them.
- ⚠️ **`jwksMinRefetch` must stay below the Nimbus cache TTL (5 minutes by default)** — above it, `JWKSourceBuilder.build()` throws, and letting that foreign exception escape through the public API is a §4 violation. Convert it at the boundary to `KeycloakConfigException`. ⚠️ **A JWKS rate-limit test always needs a control case (interval 0, or a rebuilt validator)** — the cache alone makes it pass, so the test stays green even after a line of the hardening is deleted.
- **admin owns its token** — `AdminClient(KeycloakConfig)` uses the admin-client's built-in client-credentials, and the `TokenProvider`-based constructor was removed because of a RESTEasy filter clash. admin does not know about auth directly (§4).
- **No Java OIDC library is self-certified** — if certification is needed, certify the finished product with the OIDF separately.
- **The `release` profile's `maven-javadoc-plugin` needs `<doclint>none</doclint>`** — doclint is strict by default on Java 17+, so a documentation warning alone fails the `-javadoc.jar` build.
