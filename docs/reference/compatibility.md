<!-- doc-budget: max-bytes=5329 -->
<!-- 5220 → 5329 (2026-09-23). 규약 (1) — 태그 `kotlin-v1.0.1` 이 생겨 kotlin 앵커의
     `published=21` 도 반대 방향으로 실패했다. java 와 같은 정정을 kotlin 자리에 한다.
     이제 **JVM 둘 다 17** 이므로 「어느 쪽이 아직 안 내려갔는가」 단서는 필요 없어졌고,
     대신 **다음 격차에서 무엇을 읽어야 하는가**(매니페스트가 아니라 태그)를 남긴다 —
     그 지침이 없으면 다음 세션이 같은 실수를 반복한다. -->
<!-- 5138 → 5220 (2026-09-23, +82B). 규약 (1) — 태그 `v1.0.1` 이 생기면서 `kind=runtime` 오라클이
     **반대 방향으로** 실패했다(「격차가 없는데 published=21 가 남아 있다」). 그 속성과 격차 서술을
     지우고, 소비자에게 21 을 말하던 java 자리를 17 로 내린다.
     ⚠️ **kotlin 은 그대로 21 이다** — `kotlin-v1.0.1` 이 아직 없다. 늘어난 것은 **어느 쪽이 아직
     안 내려갔는지**와 그것을 다시 재는 명령(`git show kotlin-v1.0.0:…`)이다. 그 한 줄이 없으면
     다음 세션이 kotlin 행을 읽고 17 로 「고쳐」 게시본에 대해 거짓을 말하게 된다.
     ⚠️ 같은 커밋이 **선행 렌더링 결함**도 고쳤다 — 이 ⚠️ 줄이 헤더 구분선과 첫 행 **사이**에
     있어 마크다운 표가 거기서 끊기고 아래 아홉 행이 헤더 없는 표가 됐다(내가 옮긴 것이 아니라
     원래 그 자리였다). 표 **위**로 올렸고 인용(`>`)으로 바꿨다. -->
# Compatibility reference

> Extracted from [Getting Started](../guides/getting-started.md) — that guide installs and runs one
> language; this file answers "which server and which base libraries did that published version
> actually ship against", which is a different question asked at a different time.
>
> ⚠️ The version cell of every row is machine-checked against `scripts/lib/deploy-facts.sh`
> (`df_published_version`) by `scripts/test/test-publication-claims.sh`. It finds a row by the
> language label followed by a backtick — **keep the row shape**, and do not add a second table
> above this one whose rows start the same way.

## Compatibility

Each SDK's own SemVer is decoupled from the Keycloak server and underlying library versions. See the table below for the supported server range and the base libraries · runtimes.

> ⚠️ **Each row describes what that row's published version actually shipped.** The library versions in a cell are the values in the release named in the first column, not whatever `main` happens to pin today. `main` can already be ahead; the next release of that language is when this table should move. Java and Kotlin have no lockfile — their published POM / `build.gradle.kts` pins are the source; Go has no lockfile either, so its row is the `go/go.mod` of the tagged commit (`go/v1.2.0`, which the proxy serves as the module's `.mod`). Every row now names a published version — there is no "current `main`" row left. The contract a *new* consumer resolves is still the range in each manifest; read the manifest, not this table, when that difference matters.

> ⚠️ **The JVM rows state the floor of the *published* artifact, not of the source tree.** Both are **JDK 17** as of `1.0.1` — that pair of releases is what lowered it; `v1.0.0`/`kotlin-v1.0.0` were compiled for 21, so anyone still pinned there must build against 21. ⚠️ **When the tree and the published artifact next diverge, do not "correct" these rows from the manifest** — read the tag (`git show v1.0.1:java/pom.xml | grep maven.compiler.release`, `git show kotlin-v1.0.1:kotlin/build.gradle.kts | grep -E 'jvmTarget|jvmToolchain'`) and lower them only in the release that actually publishes the new floor. Detail: [getting-started.md](../guides/getting-started.md#java).


| SDK | Target Keycloak server | Base libraries · runtime |
|---|---|---|
| Java `1.0.3` | 26.6.x (integration tests: actual **26.6**) | `keycloak-admin-client` **26.0.12** (an independent version track from the server — there is no "26.6.x admin-client") · Nimbus `oauth2-oidc-sdk` **11.38.2** · `nimbus-jose-jwt` **10.10** · JDK 17+ |
| Python `1.0.2` | 26.6.x (integration tests: actual **26.6**) | `python-keycloak` **7.1.x** · `joserfc` **1.7.x** · Python 3.10+ |
| Node `1.0.1` | 26.6.x (integration tests: actual **26.6**) | `@keycloak/keycloak-admin-client` **26.7.4** · `openid-client` **6.8.8** · `jose` **6.2.12** · Node 22+ |
| Go `1.2.0` | 26.6.x (integration tests: actual **26.6**) | `Nerzal/gocloak/v13` **13.9.0** · `golang.org/x/oauth2` **0.37.0** · `go-jose/v4` **4.1.5** · Go 1.26+ |
| C#/.NET `1.0.2` | 26.6.x (integration tests: actual **26.6**) | `Keycloak.AuthServices.Sdk` **2.7.0** · `Duende.IdentityModel` **8.1.0** · `Microsoft.IdentityModel.JsonWebTokens` **8.23.0** · .NET 8+ |
| PHP `1.2.0` | 26.6.x (integration tests: actual **26.6**, docker CLI shell-out) | `fschmtt/keycloak-rest-api-client-php` **0.42.0** · `league/oauth2-client` **^2.8** · `stevenmaguire/oauth2-keycloak` **^6.1** · `firebase/php-jwt` **^7.1** · PHP 8.3+ |
| Rust `1.1.1` | 26.6.x (integration tests: actual **26.6**, Testcontainers) | `keycloak` **~26.6.2** (`reqwest12` feature) · `openidconnect` **4.0.1** · `jsonwebtoken` **11.0.0** · Rust 1.88+ (edition 2024) |
| Ruby `1.1.0` | 26.6.x (integration tests: actual **26.6**, docker CLI shell-out) | `rack-oauth2` **~>2.3** · `faraday` **~>2.0** · `jwt` (ruby-jwt) **~>3.2** · Ruby 3.2+ |
| Kotlin `1.0.3` | 26.6.x (integration tests: actual **26.6**, Testcontainers) | `keycloak-admin-client` **26.0.12** · `oauth2-oidc-sdk` **11.38.2** · `nimbus-jose-jwt` **10.10** (same JVM stack as Java) · Kotlin 2.2+ consumers (built with 2.4.20, metadata pinned to 2.2) · JDK 17+ |

> Note on the server column: all nine pin the **same** image tag, `quay.io/keycloak/keycloak:26.6` — there is no per-language branch, and this column used to claim one (`26.6.4` for Java and Python). `26.6` is a floating minor, so what a run pulls is whatever it resolved to that day; measured 2026-09-06, that container reports **Keycloak 26.6.4**. Write the pinned tag here, not a resolution — a resolution is a snapshot nobody can reproduce later.
>
> Note on the Rust row: those are **ranges, not exact `=` pins**. An exact pin in a *library* crate hard-fails dependency resolution for any consumer whose tree also wants a newer compatible version. `openidconnect`/`jsonwebtoken` are ordinary semver crates and take a caret; the `keycloak` crate takes a tilde (`>=26.6.2, <26.7.0`) because its version tracks the Keycloak **server** line rather than semver. Reproducibility of *our* builds comes from the committed [`rust/Cargo.lock`](../../rust/Cargo.lock) — cargo ignores a dependency's lockfile, so as a consumer you pin with your own.

---
