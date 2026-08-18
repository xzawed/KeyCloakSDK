---
paths:
  - "rust/**"
  - "harness/apps/rust/**"
  - "harness/install/consume/rust*"
  - ".github/workflows/rust-*.yml"
---

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
- Releasing goes `rust-v*` tag → `rust-release.yml` (human approval gate). The tag ↔ `Cargo.toml` consistency guard and the integration E2E are both in `needs:`.
- The crate is `keycloak-sdk` (root module `keycloak_sdk`).

## Dependency policy

- ⚠️ **Never use an exact pin (`=`) in a library crate — it hard-fails dependency resolution for the consumer.** cargo unifies semver-compatible requirements into one, so pinning `=26.6.2` leaves no satisfiable combination with a crate in the same tree that asks for 26.6.3, and the consumer has no way around it.
- **The operator differs per crate**: `openidconnect` and `jsonwebtoken` are ordinary semver, so **caret**; `keycloak` gets a **tilde, `~26.6.2`** — that crate's version is not semver but **tracks the Keycloak server line**, so "26.7" *is* a server minor upgrade, and the reqwest feature layout has been reshuffled at such a boundary before.
- ⚠️ **The committed `Cargo.lock` does not reach the consumer** — cargo ignores the lockfile of a dependency crate. What the lock pins is CI, local and `--locked` builds; what actually protects downstream is the range choice above. Raise a major or a minor version **by hand**, refreshing the lock and re-checking the gotchas below.
- ⚠️ **The `keycloak` crate and `openidconnect` have to agree on the reqwest major** — `keycloak` needs the `reqwest12` feature declared explicitly (`default-features=false`) for them to share the same `reqwest::Client`. Mismatched, it fails to compile.
- The dev-dependency `testcontainers` is pre-1.0, so breaking changes arrive in minors — always run the integration tests when bumping it. The pins' SSOT is the dependency table in the root `CLAUDE.md`.
- RUSTSEC-2023-0071 (the rsa Marvin Attack) does not apply — `rsa` is used only to generate test keys as a dev-dependency, and the runtime only verifies signatures.

## Re-exports (§4(b))

⚠️ **The admin facade's public signatures use foreign types, so without re-exports the published quickstart does not compile.** The five representation types from `keycloak::types` are mirrored back out as `keycloak_sdk::types`, and `KeycloakAdmin`, `SdkTokenSupplier` (needed to name the return type of `AdminClient::raw()`) and the `reqwest` the low-level ctor takes are re-exported from the crate root. **Whenever a foreign type enters a new public signature, extend the re-exports with it.**

## Library gotchas

- ⚠️ **Do not make `search_users`'s `max` an `Option` — Keycloak silently applies 100 when it is not sent** (`Constants.DEFAULT_MAX_RESULTS`). `None` does not mean "unlimited", it means "truncated at 100", and as an option the cap is invisible at the call site. "Unlimited" is expressed as a negative `max` (-1). For an exact single match use `find_user_by_username`, which asks for `max=2` so that a username-uniqueness violation is distinguishable from truncation and can surface as `Conflict` — with `max=1` the two are indistinguishable.
- ⚠️ **`openidconnect`'s `CoreClient` is generic over the typestate of six endpoints** — only auth, introspection and token need to be marked `EndpointSet` in a type alias (`KcOidcClient`) for the builder to be callable without `?`. The id_token is validated by the SDK's `JwtValidator` rather than by openidconnect's own check (a deliberate design choice).
- ⚠️ **`jsonwebtoken`'s `Validation` defaults are not safe** — `validate_nbf` false→true, `leeway` 60s→`config.clock_skew` (30 seconds), `set_required_spec_claims(["exp","iss","aud"])`, `algorithms=[RS256]` (`Algorithm` has no `none` variant at all, so it is structurally rejected).
- ⚠️ **From jsonwebtoken 11.0.0 on, a malformed JWKS is rejected at key construction rather than at parsing** (`Transport` → `TokenValidation`). Fail-closed still holds, and an unknown `kty` mixed into the set no longer kills the whole set — on 10.x, one unrecognised key made the perfectly good RSA keys unusable too, which was an availability incident. ⚠️ **Do not add a set-wide check after `fetch` to restore the old error class** — that throws away the tolerance we just gained.
- ⚠️ **The JWKS rate limit is stamped at the moment the refetch is *decided*** (isomorphic with Go and Python) — so even when the fetch fails because the IdP is down, the gate is consumed, which caps a stream of forged kids injected during the outage window.
- ⚠️ **The shared `reqwest::Client` blocks redirects outright with `redirect::Policy::none()`** (SSRF hardening). auth, admin and JWKS all reuse this client.

## SDK structure

- ⚠️ **admin uses the caching `ClientCredentialsTokenProvider` — not a directly injected, uncached `AuthClient`.** Injecting it directly re-issues a token on every admin call and breaks the §4 cache and single-flight invariants. The shared `http` is reused, but the provider instance is separate.
- **The admin boundary conversion is `map_admin`** — this is where `keycloak::KeycloakError` becomes an SDK type. `AuthClient` implements `TokenProvider` and `SdkTokenSupplier` adapts that to the crate's `KeycloakTokenSupplier`. **Those two steps are the whole of §4's hiding, so skipping either one leaks a foreign type.**
- **The facade is flat** (`update_role(name, rep)` — unlike the `roles().update(…)` of the other eight). It exposes all 25 of the five resources × five operations.
- ⚠️ **`list_*`'s `max` is not an `Option`** — the same reason as `search_users` (the gotcha above). `list_realms()` is the one exception, because `GET /admin/realms` has no pagination parameters at all.
- ⚠️ **`update_*` passes the path and the body separately.** The crate's `realm_put(realm, body)`, `realm_roles_with_role_name_put(realm, role_name, body)` and friends take the two apart, so rename is native. Build the path out of the representation and rename becomes a silent no-op (in the sister Go SDK, gocloak works that way, which is why `realms.Update` alone routes around it with raw REST). A unit test sets the name in the body **differently** from the path so that wiremock catches such a merge as a 404.
