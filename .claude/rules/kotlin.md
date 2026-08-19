---
paths:
  - "kotlin/**"
  - "harness/apps/kotlin/**"
  - "harness/install/consume/kotlin*"
  - "harness/install/consume/kotlin-app/**"
  - ".github/workflows/kotlin-*.yml"
---

# Kotlin rules

## Toolchain

JDK 21. **Issue every command through the wrapper** — `cd kotlin && ./gradlew <task>`.

⚠️ **Do not install Gradle separately.** The wrapper fetches the distribution the build needs (`9.5.0`) by itself. This repository carried `gradle -p kotlin <task>` for a while, and that command only runs **on a machine that has gradle on its PATH** — measured, this PC did not (`~/tools` held only maven and php), and it had to move to the wrapper. `docs/guides/development-setup.md` had said "Kotlin — do not install Gradle" correctly from the start; this file was the one that had drifted.

```bash
export JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot}"
cd kotlin
./gradlew build
./gradlew test                # unit. No Docker
./gradlew integrationTest     # one integration E2E. Needs Docker (Testcontainers, KC 26.6)
./gradlew koverVerify         # coverage gate 90 lines / 85 branches, network boundary omitted
./gradlew ktlintCheck         # fix with ktlintFormat
./gradlew publishToMavenLocal # local check of the release build
```

- A single test: `./gradlew test --tests "*<ClassName>"` (from inside `kotlin/`)
- Coordinate `io.github.xzawed:keycloak-sdk-kotlin`. KGP 2.4.10 · `jvmToolchain(21)` · `languageVersion`/`apiVersion` = `KOTLIN_2_2` (the consumer floor) · `explicitApi()`.
- Releasing goes `kotlin-v*` tag → `kotlin-release.yml` (staging on the Central Portal) → a human releases it from the Portal. The pins' SSOT is the dependency table in the root `CLAUDE.md` (a doc-guard anchor cross-checks it against `build.gradle.kts` — do not write the numbers here).
- Measured coverage is 99.33% lines / 89.13% branches (41 of 46). ⚠️ `koverVerify` prints no percentages, so it cannot be cross-checked from the CI log — use `koverHtmlReport` for that.
- ⚠️ **Read the branch gate's slack as a count, not a percentage.** The denominator is 46, so one branch is 2.2 points. It sat at **exactly zero slack** (40 covered, 40 required) until a test for a token carrying `iat` was added — the helper in `JwtValidatorTest` had never set `issueTime`, so `validatedTokenFrom` only ever took the null path. Slack is now 1.
- ⚠️ **The five branches still uncovered in `validatedTokenFrom` are unreachable, not missing tests.** Nimbus's `JWTClaimsSet` returns an empty list from `getAudience()` and a non-null map from `getClaims()` — never null — and the processor rejects a token with no `exp` before this function runs. Reaching them needs a mock claims set, which buys a number and asserts nothing. **Do not chase 100% here.**

## Build and test constraints

- ⚠️ **Never run `gradle --stop` during a build.** Even `--no-daemon` forks a daemon, so the build in progress dies and is mistaken for a test failure. Running two gradles against the same project at once is also forbidden (lock contention). Recover with `./gradlew clean`.
- ⚠️ **Mocking the JAX-RS abstract classes (`Response`, `WebApplicationException`) with MockK hangs indefinitely on JDK 21.** byte-buddy stalls while instrumenting the RESTEasy class graph. Use real objects — `WebApplicationException(msg, status)` · `Response.status(500).entity("body").build()` · an anonymous subclass. Mocking **interfaces** (`UsersResource` and friends) is safe.
- ⚠️ **Coroutine stack-trace recovery does not preserve exception identity.** An exception that crossed a suspend boundary is a new instance — compare with `assertIs<T>` plus the message instead of `assertSame`.
- ⚠️ **Jupiter does not discover an `@Test` written as an `= runBlocking { … }` expression body.** A non-Unit last expression makes the method non-void — state `: Unit` explicitly.
- ⚠️ **Build `integrationTest` with the Gradle `jvm-test-suite` plugin.** A hand-rolled `creating` source set does not register the Kotlin compilation output in `output.classesDirs`, which produces "no tests discovered". The dependency is **`kotlin-test-junit5`**, not `kotlin("test")`.
- ⚠️ **Two things about Kover 0.9.x**: (1) it ignores an exact class-name exclude that has no wildcard — the network boundary has to be given with a `*` suffix, as in `AuthClient*`, for the top-level function class (`…Kt`) to drop out too. (2) it puts `integrationTest` into automatic instrumentation, which breaks the Docker-less unit CI — `instrumentation.disabledForTestTasks.add("integrationTest")` and `sources.excludedSourceSets.add("integrationTest")` are **both** required.
- ktlint's multi-declaration filename rule collides with this monorepo's lowercase idiom (`errors.kt` and the like), hence `ktlint_standard_filename = disabled` in `kotlin/.editorconfig`.

## Publishing constraints

- ⚠️ **Keep the Gradle wrapper inside KGP's fully supported band** (KGP 2.4.10 → 7.6.3–9.5.0). Being outside the band is not automatically broken, but staying inside it is this repository's policy. Do not raise the wrapper alone — move **KGP, the `kgp-gradle-band` record, the wrapper, and the `// gradle/wrapper:` mirror comment on line 1 of `build.gradle.kts`, together in one commit**; `scripts/check-versions.mjs` enforces that the four agree. dependabot raises the wrapper in a PR of its own (`exclude-patterns`).
- ⚠️ **The binary metadata version of the published jar is decided by `languageVersion`/`apiVersion`, not by KGP.** If you build with KGP 2.4.10 and no settings, `mv=[2,4,0]` is stamped in, which means **a consumer below Kotlin 2.4 cannot use the library at all.**
  - ⚠️ **The transitive `kotlin-stdlib` has to be lowered along with it.** If you lower only the class metadata, the consumer still resolves stdlib 2.4.10 and fails with `Class 'kotlin.Unit' was compiled with an incompatible version of Kotlin`. Put `kotlin.stdlib.default.dependency=false` in `gradle.properties` and declare `api("org.jetbrains.kotlin:kotlin-stdlib:<floor>")` explicitly. **`constraints` cannot lower it** — a constraint is a floor, so the automatic injection wins.
  - To check: run `publishToMavenLocal`, read the stdlib version in the POM, and see whether `./gradlew classes` passes in `harness/apps/kotlin` (Kotlin 2.2.20 + `mavenLocal()`). For the metadata itself, read the `mv` array of `kotlin/Metadata` with `javap -v` (grepping the constant pool cannot decide it, because of deduplication).
  - **Raising the floor cuts off exactly that many consumers, so say so in the release notes.**
- ⚠️ **If any one of the four release secrets (`MAVEN_CENTRAL_USERNAME`/`_PASSWORD` · `SIGNING_IN_MEMORY_KEY`/`_PASSWORD`) is missing, fail.** Skip instead and an unsigned artifact goes up to the Portal from a green run. A job-level `if:` cannot read secrets, so the guard has to work on an **env-mapped value inside the step**.

## SDK behaviour (isomorphic with Java)

- `exchangeCode` fully validates the id_token (signature · iss · aud · exp) **before** comparing the nonce.
- The admin facade knows nothing about auth — it owns its token through `KeycloakBuilder`'s built-in client-credentials (§4).
- `fun interface` + `suspend` compiles (KT-40978 is resolved), so `TokenProvider` is SAM-convertible.
- ⚠️ **`jwksMinRefetch` must stay below the Nimbus cache TTL (5 minutes by default).** Above it, `JWKSourceBuilder.build()` throws, and letting that foreign exception escape through the public API is a §4 violation — convert it at the boundary to `KeycloakConfigException`. ⚠️ **A JWKS rate-limit test must always include a control case (interval 0, or a rebuilt validator)** — the cache alone makes it pass, so it stays green even after a line of the hardening is deleted.
- ⚠️ **Injecting `resteasyClient(...)` bypasses the admin-client's `JacksonProvider` registration** — that loses `NON_NULL` together with `FAIL_ON_UNKNOWN_PROPERTIES=false`, which breaks version skew in both directions. `buildTimeoutClient` registers `JacksonProvider` and `StreamMessageBodyReader` itself. Keep `ClientBuilder.newBuilder()` (`createClientBuilder()` drops the connection pool from 50 to 10). **Behavioural contract**: with `NON_NULL` on, a partial update cannot blank a field by setting it to null (same as the official admin-client) — to blank one, use an empty string or the dedicated API.
