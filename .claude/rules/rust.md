---
paths:
  - "rust/**"
  - "harness/apps/rust/**"
  - "harness/install/consume/rust*"
  - ".github/workflows/rust-*.yml"
---
<!-- doc-budget: max-bytes=8877 -->
<!--
  8645 → 8877 (2026-09-04). 규약 (2). 52행의 「IdP 가 죽어도 게이트가 소모돼 위조 kid 흐름을
  막는다」가 **캐시가 찼을 때만 참**임을 실측으로 확인했다(콜드 20→20, 웜 대조군 2). 그 조건을
  안 적으면 이 줄은 장애 중 보장으로 읽힌다 — rust README 가 실제로 그렇게 적고 있었다.
  되돌릴 자리는 52행 뒤 한 문장이다.
-->

# Rust rules

## Toolchain

System install. MSRV **1.88** (edition 2024 + let-chain syntax). The CI matrix is 1.88 and stable.
⚠️ **A local Windows build needs the VS2019 BuildTools MSVC environment (`vcvars64.bat`)** — `ring` and `rsa` compile natively; CI on ubuntu is unaffected.

```bash
cd rust && cargo build --all-targets
cd rust && cargo fmt --all --check
cd rust && cargo clippy --all-targets -- -D warnings
cd rust && cargo test                                         # unit. No Docker
cd rust && cargo test --test integration_test -- --ignored    # integration E2E. Needs Docker (KC 26.6)
```

- A single test: `cargo test <test_name>`
- Coverage (logic lines ≥90%, network boundary omitted): `rustup component add llvm-tools-preview`, then `cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90`. Measured 96.48% (35 of 993 lines unexecuted).
  - ⚠️ **Install `llvm-tools-preview` first** — without it, `cargo-llvm-cov` raises an interactive confirmation and **hangs indefinitely** in a non-interactive shell (diagnose it by the zero CPU time).
  - ⚠️ In PowerShell the `|` inside the regex can be taken for a pipe — wrap the whole value as `--ignore-filename-regex="…"`.
  - ⚠️ **There is no branch-coverage gate here, and there cannot be on the pinned toolchain.** `cargo llvm-cov --branch` is marked *(unstable)*: it passes `-Z coverage-options=branch`, which on stable dies with `error: the option \`Z\` is only accepted on the nightly compiler` (measured on 1.97.1). So the `Branches` column of a normal `--summary-only` run reads `0 0 -` — "not collected", not "none exist". Six of the nine SDKs gate branches, so this looks like an omission and invites a "fix"; it is a toolchain constraint. **Revival condition**: `-Z coverage-options=branch` **lands on stable** (not merely loses the *(unstable)* label). ⚠️ Refusing nightly is **policy, not MSRV** — the coverage job already carries its own toolchain pin, so nightly would not touch `rust-version`; it is refused because `-Z` flags move, it adds a pin for dependabot to track, and the number would not be comparable to the JaCoCo/Kover 85 the other six gate against.
- Releasing goes `rust-v*` tag → `rust-release.yml` (human approval gate). The tag ↔ `Cargo.toml` consistency guard and the integration E2E are both in `needs:`.
- The crate is `keycloak-sdk` (root module `keycloak_sdk`).

## Dependency policy

- ⚠️ **Never use an exact pin (`=`) in a library crate — it hard-fails dependency resolution for the consumer.** cargo unifies semver-compatible requirements into one, so an `=` pin leaves no satisfiable combination with a crate in the same tree that asks for a later patch, and the consumer has no way around it.
- **The operator differs per crate**: `openidconnect` and `jsonwebtoken` are ordinary semver, so **caret**; `keycloak` gets a **tilde** — that crate's version is not semver but **tracks the Keycloak server line**, so a minor *is* a server minor upgrade, and the reqwest feature layout has been reshuffled at such a boundary before. The pins' SSOT is the dependency table in the root `CLAUDE.md`.
- ⚠️ **The committed `Cargo.lock` does not reach the consumer** — cargo ignores the lockfile of a dependency crate. What the lock pins is CI, local and `--locked` builds; what actually protects downstream is the range choice above. Raise a major or a minor version **by hand**, refreshing the lock and re-checking the gotchas below.
- ⚠️ **The `keycloak` crate and `openidconnect` have to agree on the reqwest major** — `keycloak` needs the `reqwest12` feature declared explicitly (`default-features=false`) for them to share the same `reqwest::Client`. Mismatched, it fails to compile.
- The dev-dependency `testcontainers` is pre-1.0, so breaking changes arrive in minors — always run the integration tests when bumping it.
- RUSTSEC-2023-0071 (the rsa Marvin Attack) does not apply — `rsa` is used only to generate test keys as a dev-dependency, and the runtime only verifies signatures.

## Re-exports (§4(b))

⚠️ **The admin facade's public signatures use foreign types, so without re-exports the published quickstart does not compile.** The five representation types from `keycloak::types` are mirrored back out as `keycloak_sdk::types`, and `KeycloakAdmin`, `SdkTokenSupplier` (needed to name the return type of `AdminClient::raw()`) and the `reqwest` the low-level ctor takes are re-exported from the crate root. **Whenever a foreign type enters a new public signature, extend the re-exports with it.**

## Library gotchas

- ⚠️ **Do not make `search_users`'s `max` an `Option` — Keycloak silently applies 100 when it is not sent** (`Constants.DEFAULT_MAX_RESULTS`). `None` means "truncated at 100", not "unlimited", and as an option that cap is invisible at the call site; unlimited is a negative `max` (-1). For an exact single match use `find_user_by_username`, which asks `max=2` so a uniqueness violation is distinguishable from truncation and surfaces as `Conflict` — with `max=1` the two are indistinguishable.
- ⚠️ **`openidconnect`'s `CoreClient` is generic over the typestate of six endpoints** — only auth, introspection and token need to be marked `EndpointSet` in a type alias (`KcOidcClient`) for the builder to be callable without `?`. The id_token is validated by the SDK's `JwtValidator` rather than by openidconnect's own check (a deliberate design choice).
- ⚠️ **`jsonwebtoken`'s `Validation` defaults are not safe** — `validate_nbf` false→true, `leeway` 60s→`config.clock_skew` (30 seconds), `set_required_spec_claims(["exp","iss","aud"])`, `algorithms=[RS256]` (`Algorithm` has no `none` variant at all, so it is structurally rejected).
- ⚠️ **From jsonwebtoken 11.0.0 on, a malformed JWKS is rejected at key construction rather than at parsing** (`Transport` → `TokenValidation`). Fail-closed still holds, and an unknown `kty` mixed into the set no longer kills the whole set — on 10.x, one unrecognised key made the perfectly good RSA keys unusable too, which was an availability incident. ⚠️ **Do not add a set-wide check after `fetch` to restore the old error class** — that throws away the tolerance we just gained.
- ⚠️ **The JWKS rate limit is stamped when the refetch is *decided*** (isomorphic with Go and Python) — so even when the fetch fails because the IdP is down the gate is consumed, capping forged kids injected during the outage. That cap needs a populated cache; the cold path has its own failed-fetch backoff (`security.md` owns both).
- ⚠️ **`get_key` takes the gate mutex *before* the cold load — load-bearing.** It used to sit above the lock, so 20 concurrent first validations issued 20 fetches, **against a healthy IdP too** (measured 20/20; go's `singleflight` and ruby/python's lock never had this). Move it back out and backoff and single-flight vanish together (`concurrent_cold_start_collapses_to_one_fetch`). The gate clock is `tokio::time::Instant` so `start_paused` tests cross the window without sleeping.
- ⚠️ **The shared `reqwest::Client` blocks redirects outright with `redirect::Policy::none()`** (SSRF hardening); auth, admin and JWKS all reuse it.

## SDK structure

- ⚠️ **admin uses the caching `ClientCredentialsTokenProvider` — not a directly injected, uncached `AuthClient`.** Injecting it directly re-issues a token on every admin call and breaks the §4 cache and single-flight invariants. The shared `http` is reused, but the provider instance is separate.
- **The admin boundary conversion is `map_admin`** — this is where `keycloak::KeycloakError` becomes an SDK type. `AuthClient` implements `TokenProvider` and `SdkTokenSupplier` adapts that to the crate's `KeycloakTokenSupplier`. **Those two steps are the whole of §4's hiding, so skipping either one leaks a foreign type.**
- **The facade is flat** (`update_role(name, rep)`, not the `roles().update(…)` of the other eight), exposing all 25 of the five resources × five operations.
- ⚠️ **`list_*`'s `max` is not an `Option`** — same reason as `search_users` above. `list_realms()` is the one exception: `GET /admin/realms` has no pagination parameters.
- ⚠️ **`update_*` passes the path and the body separately.** `realm_put(realm, body)`, `realm_roles_with_role_name_put(realm, role_name, body)` and friends take the two apart, so rename is native. Build the path out of the representation and rename becomes a silent no-op (gocloak does that, which is why the Go `realms.Update` routes around it with raw REST). A unit test sets the body name **differently** from the path so wiremock catches such a merge as a 404.
