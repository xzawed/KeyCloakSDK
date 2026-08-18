# Add-a-Language Playbook

> **Audience:** Implementation agents, reviewers, and human approvers who want to add a **new-language implementation** to the Keycloak polyglot SDK at the same quality bar as Java and Python.
> **Required reading first:** [Language-neutral contract §4](../../CLAUDE.md) (in `CLAUDE.md` — not a frozen design spec) · [work process](../governance/process.md) · any existing language tree (`java/`, `python/`, …) as a worked example.

**Nine languages are done** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin). Kotlin is a published ninth SDK (`io.github.xzawed:keycloak-sdk-kotlin` on Maven Central): it reuses the sibling Java library stack (`keycloak-admin-client` · `oauth2-oidc-sdk` · `nimbus-jose-jwt`) but is a **separate implementation**, not an interoperability-verification track. The former recommended order (TypeScript/Node → Go → C# → PHP → Rust → Ruby) is **history, not a roadmap**.

This playbook is the six-stage procedure for adding a **tenth** language at the same quality bar. The strategy stays **depth-first**: there is no code generator and no low-quality tier — **every language is hand-implemented**. Each language is idiomatic (only the surface differs, e.g. camelCase ↔ snake_case), but its **concepts, layers, and flows must be isomorphic to the §4 language-neutral contract**. In other words, no matter which language you open, you will find the same layering `config → auth → jwt → admin → client`, the same exception hierarchy, the same security invariants, and the same test scenarios.

This document is a **copy-pasteable checklist plus per-stage deliverables and gates**. Each stage ends with an independently verifiable deliverable and states its pass criteria (gate). When starting a new language, walk through these six stages exactly as written, and derive the language-specific WBS document in the same format as the Java/Python WBS.

---

## The 6-stage procedure

### Stage 1 — Reconfirm the contract & select the foundation client (deep research)

The first task for a new language is not code but **research and decisions**.

- [ ] **Re-read the §4 language-neutral contract** — the source of truth is always [CLAUDE.md §4](../../CLAUDE.md). A new language *implements* this contract; it does not redesign it. Map naming, layering, the exception hierarchy, the value types (`TokenSet`/`ValidatedToken`/`IntrospectionResult`), and the security invariants verbatim.
- [ ] **Deep research on foundation libraries** — pick the "best foundation" for each language. If a mature official/semi-official client exists, **wrap it** (Java = `keycloak-admin-client`, Python = `python-keycloak`); if not, hand-assemble standard HTTP + OIDC. Decision criteria:
  - Admin REST coverage, maintenance activity, license compatibility (consumable under Apache-2.0).
  - Support for OIDC/OAuth2 flows (Authorization Code + PKCE, Client Credentials, Refresh, Logout, Introspection).
  - **Choose the JWT/JOSE library separately** — validation is a self-hardened implementation in every language, so do **not** rely on the foundation client's built-in token decoder (see Stage 3).
- [ ] **Confirm the gotchas** — admin-client version ≠ server version, absence of safe defaults per library, DoS-amplification paths, etc. Re-examine the "core gotchas" in [CLAUDE.md](../../CLAUDE.md) against the language at hand.
- [ ] **Fix the runtime floor** — settle on the language baseline, build tool, package manager, static type checker, linter, and formatter. (Reference: Java = **JDK 21+** — artifacts are compiled with `--release 21` and fail with `UnsupportedClassVersionError` on lower JDKs. Python = **3.10+**.)

**Deliverable:** A draft of the language-specific WBS document (same format as the Java/Python WBS) — a table transcribing the foundation library, version pins, toolchain, baseline, and Global Constraints from §4.
**Gate:** A human approves the foundation-library selection and the baseline. The WBS draft maps every §4 item without omission (self-review table).

---

### Stage 2 — Implement the layers (config → auth → jwt → admin → client)

Build up **layers isomorphic** to Java's `core`/`auth`/`admin`/`keycloak-sdk` and Python's `config.py`/`auth.py`/`jwt.py`/`admin/`/`client.py`, in order, via TDD. Each subtask is failing test → implementation → pass → commit.

- [ ] **config** — immutable config object + validation. Missing required values (`serverUrl`/`realm`/`clientId`) raise the `KeycloakConfigError` family. Secrets get the best hygiene the language allows (Java's defensive `char[]` clone; other languages use an immutable string + masking). Mask in `toString()`/`repr`. Fix defaults for timeouts, clock skew, and scopes.
- [ ] **oidc endpoints** — assemble URLs from the `{serverUrl}/realms/{realm}` convention (no network). issuer, token, authorization, introspection, end_session, jwks.
- [ ] **auth (OIDC wrapper)** — thinly wrap the foundation client's OIDC surface. Authorization Code + **PKCE** (S256), Client Credentials, Refresh, Logout, Introspection, and mapping responses into `TokenSet`. Since this is a network boundary, keep logic in mapping helpers and unit-verify it, while integration tests cover the actual calls.
- [ ] **jwt (self-hardened validation — 🔴 the highest-priority accuracy task)** — implement directly with the language's JOSE library, not the foundation library. Satisfy **all** of the following invariants:
  - **Algorithm pinning** — specify the allowed algorithms (e.g. `RS256`). Do not trust the token header's `alg`.
  - **Reject `none`/unsigned**.
  - **Exact issuer match** (`==`).
  - **Audience membership check** — if `aud` is a string, equality; if a list, membership (accept multiple audiences).
  - **exp/nbf + clock skew** (default 30s).
  - **DoS-safe JWKS refetch** — signature forgery does not trigger a certs refetch; only an unresolved kid triggers a refetch; and the refetch itself is rate-limited to a minimum interval. Block the unauthenticated DoS amplification of hitting the IdP on every forged Bearer.
- [ ] **admin (facade + raw())** — a resource facade wrapping the foundation admin client (`users`/`clients`/`realms`/`roles`/`groups`). Expose the underlying client via the **`raw()` escape hatch** (for advanced users). Admin calls **must inject config's timeouts** (not injecting them = unbounded waits and thread-exhaustion DoS).
- [ ] **client (unified entry point)** — initialize `auth` **eagerly** and `admin` **lazily** (a public client can use `auth` alone without a secret). Provide `close()`/`aclose()` via a context manager/`AutoCloseable` — cleaning up not just admin but **the auth session (HTTP connection pool) as well** (not cleaning up = FD/connection leaks).

**Rules common to all layers:**
- **Hide underlying types** — keep foundation-library types behind the primary consumption path (the facade). Only the documented hiding exceptions ([CLAUDE.md](../../CLAUDE.md) §architecture) are allowed (reusing stable representation types; low-level injection/configuration points).
- **Boundary exception translation** — foundation-library exceptions **must always be translated into SDK exceptions at the boundary**. The exception hierarchy follows language idiom — all prefixed `Keycloak` with a language-specific suffix: Java `Keycloak*Exception` (e.g. `KeycloakNotFoundException`·`KeycloakConflictException`·`KeycloakForbiddenException`·`KeycloakAdminException`·`KeycloakAuthException`·`KeycloakTransportException`), Python `Keycloak*Error` (e.g. `KeycloakNotFoundError`·`KeycloakConflictError`·`KeycloakForbiddenError`·`KeycloakAdminError`·`KeycloakAuthError`·`KeycloakTransportError`). Underlying exception types must not leak into the public API.
- **Coupling rule** — `admin` does not know `auth` directly. The only glue is the `TokenProvider` interface (or each authenticating independently via client-credentials).

**Deliverable:** Implementations of the 5 layers + unit tests for each layer, committed per layer (with the WBS id).
**Gate:** G1 (build) + G2 (unit 100%) pass per layer. Exception/type-hiding review passes (G4/G6).

---

### Stage 3 — Security invariants + CI enforcement

Nail down the security properties implemented in Stage 2 **so that CI prevents regressions**. Properties held only by review eventually break — pin them with automated gates.

- [ ] **Masking (fully opaque)** — tokens/secrets must never appear in logs, `toString`/`repr`, or exception messages. Masking is a **fully opaque `***` with no prefix exposure**. Enforce with unit tests (the plaintext does not appear in the string representation).
- [ ] **TLS verification on by default** — no no-op config options (an option that is stored but not wired to the transport is misleading — remove it). Keep verification on by default.
- [ ] **DoS-safe JWKS** — pin Stage 2 jwt's refetch rate-limit and conditional refetch with unit tests (a forged signature does not trigger a refetch; only an unresolved kid refetches; the minimum interval is honored).
- [ ] **admin timeout injection** — verify that config timeouts are actually passed to the real HTTP client.
- [ ] **No default typing** — statically typed languages run in strict mode (e.g. `mypy --strict`, warnings escalated). CI rejects implicit any/loose types.
- [ ] **Linter security ruleset** — make the language's security lint (bandit/`ruff S`, gosec, ESLint security, etc.) a required CI job.

**Deliverable:** A security unit-test set + linter, type-check, and format-check jobs integrated into CI.
**Gate:** G6 (security) — zero token/secret logging and zero internal-type leakage. Strict typing, security lint, and masking tests are required (merge-blocking) jobs in CI.

---

### Stage 4 — Test parity matrix

The new language must verify the **same scenarios** as Java and Python. Counts may differ per language (test idiom differences), but the **set of covered scenarios must be isomorphic**.

| Level | Content | Reference (Java / Python) |
|---|---|---|
| **Unit** | PKCE generation, config validation & defaults, token-response parsing (`from_response`), expiry & clock-skew decisions, JWT hardening (alg pin · reject none · iss · aud · exp/nbf), **exception boundary mapping** (404 → `KeycloakNotFoundError`/`KeycloakNotFoundException`, etc.), masking | see each language's CI job and coverage gate (counts are not hand-maintained) |
| **Integration (Testcontainers)** | **Real Keycloak 26.6** container + realm import. client-credentials token issuance, `validate` (accept multiple aud), introspect, user/client CRUD, the `raw()` escape hatch, lookup after delete → `KeycloakNotFoundError`/`KeycloakNotFoundException` | Java `SmokeIT`·`AuthFlowIT`·`AdminOpsIT` / Python sync + async integration suites |
| **Coverage gate** | Line/branch thresholds on logic modules. Network-boundary classes (`auth`/`admin` creation) are verified by integration and omit/excluded from coverage | Java line ≥90%/branch ≥85% (JaCoCo) · Python logic 100% enforced (`--cov-fail-under`, boundaries omit) |

- [ ] Cover all the scenarios above with unit tests (isolate the network with mocks/stubs).
- [ ] Testcontainers harness + realm JSON (`<realm>-realm.json`, the `--import-realm` convention) — **Java's `it-realm-realm.json` is reusable** (confidential client + service account + audience mapper).
- [ ] Enforce the coverage gate in the build (below threshold = build failure). State the boundary-class omit rules explicitly.

**Deliverable:** Unit + integration test suites, and a build with the coverage gate wired in.
**Gate:** G2 (unit 100%) + G3 (coverage threshold) + integration tests GREEN (Docker). Review scenario parity against the Java/Python matrix in a table.

---

### Stage 5 — CI · publishing (tag-driven, human-gated) · docs

- [ ] **CI matrix** — build + unit + type + lint across every supported runtime version (e.g. a per-language matrix comparable to Java 21+, Python 3.10–3.13). Integration tests need Docker, so keep them in a separate job/local.
- [ ] **Local install path** — consumers must be able to use it locally *before* it is published, and a new language always starts unpublished. Every existing language keeps this path working regardless of registry status:
  - Java: `mvn -f java/pom.xml install -DskipITs=true` → coordinate `io.github.xzawed:keycloak-sdk:0.1.0-SNAPSHOT`
  - Python: `pip install -e python` (or `cd python && python -m build`) → distribution name `keycloak-sdk`
  - Make sure the new language likewise supports "local install → run the example" without publishing.
  - For which languages are already on a public registry, see [DEPLOY.md](../../DEPLOY.md) — do not restate it here, it goes stale.
- [ ] **Tag-driven release (human-gated)** — actual publishing runs only via a workflow triggered when a human pushes a tag. Existing examples: [`.github/workflows/release.yml`](../../.github/workflows/release.yml) (Java, `v*` tag → Maven Central), [`.github/workflows/python-release.yml`](../../.github/workflows/python-release.yml) (Python, `py-v*` tag → PyPI Trusted Publisher/OIDC). The new language follows the same pattern with a language-specific tag prefix + the appropriate registry (npm/Go proxy/NuGet/Packagist/crates.io/RubyGems). The full procedure is in [DEPLOY.md](../../DEPLOY.md).
  - ⚠️ **Never let an agent auto-run an irreversible publish** — credentials only via CI secrets/OIDC, and the tag push is done by a human.
- [ ] **Docs** — a new-language section in getting-started (install · QuickStart · cross-language mapping table · compatibility matrix), the README, and updates to the structure tree and build commands in [CLAUDE.md](../../CLAUDE.md) (do **not** hand-copy test counts — see the scenario table above). Gate history belongs in the PR / commit message — a separate verification-log file is **not** a required deliverable.

**Deliverable:** A CI workflow + a release workflow (prepared, not executed) + updated docs.
**Gate:** CI GREEN. The release workflow is in a prepared state (human-gated, not executed). Docs match the actual implementation (do not hand-copy test counts — CI is the authority).

---

### Stage 6 — Governance G1–G6 + Codex dual verification + loop

Every task follows the [work process](../governance/process.md) — six phases (plan → WBS → review → schedule → build → verify) with a WBS as the backbone. **Separation of duties**: implementer ≠ reviewer ≠ verifier, and the verifier uses a **different model (Codex/GPT-5)** to offset correlated blind spots.

- [ ] **G1–G6 gates** — all must pass per task to be considered done:
  - **G1 Build** (0 compile errors) · **G2 Unit tests** (100%) · **G3 Coverage** (threshold) · **G4 Spec conformance** (0 unresolved Critical/Important, reviewer approval) · **G5 Codex cross-verification** (0 discrepancies, verdict "confirmed") · **G6 Security** (0 token/secret · internal-type leakage).
- [ ] **Codex dual verification (G5)** — Codex independently reviews every task diff. No self-approving your own code.
- [ ] **Loop engineering** — on a gate miss, RCA (joint Claude+Codex diagnosis) → remediation (minimal change) → re-verification (G1–G6) → re-measurement. **Up to 3 iterations per gate**; escalate to a human if exceeded. Record every iteration in the PR as "prior metric → action → post metric → RCA".
- [ ] **Governance guardrails** — `feature/<lang>-sdk` branch isolation, main via PR (human approval), publishing on human approval, secret handling (masking + review), reproducibility (pinned dependency BOM/lockfile, pinned Keycloak container tag, pinned toolchain versions).

**Deliverable:** A PR that records the gate-pass history and a Codex "confirmed" verdict.
**Gate:** All gates GREEN + a whole-branch final review including Codex → PR (human-approved merge).

---

## Stage ↔ gate mapping

| Stage | Key deliverable | Required gates | How it's measured |
|---|---|---|---|
| 1. Reconfirm contract & select client | Language WBS draft, foundation-library decision | G4 (spec mapping) + human approval | §4 comparison table, human review |
| 2. Layer implementation | config/auth/jwt/admin/client + unit | G1·G2·G4·G6 | build · unit · type-hiding/exception-translation review |
| 3. Security invariants + CI enforcement | Security tests + strict/security lint jobs | **G6** | masking · JWKS DoS · timeout tests, required CI jobs |
| 4. Test parity matrix | Unit + Testcontainers integration | G2·G3 + integration GREEN | coverage gate, scenario-parity table |
| 5. CI · publishing · docs | CI + tag-driven release (not executed) + docs | CI GREEN + docs match | matrix build, local-install verification, docs comparison |
| 6. Governance | Codex verdict, PR | **All of G1–G6** + Codex confirmed | gate measurement + loop + human approval |

---

## Real-world cases (worked examples)

This playbook is induced from the completed implementations. When writing a new language's WBS, take the **format** from any existing tree and the **contract** from [CLAUDE.md §4](../../CLAUDE.md):

- **Java (baseline, hand-wrapped):** `java/` — 6 Maven modules, JaCoCo 90/85 gate, `v*` tag → Maven Central.
- **Python (2nd language, wrapping `python-keycloak`):** `python/` — a single package with the `src/` layout + an `aio` async mirror, self JWT validation with `joserfc`, logic coverage enforced at 100%, `py-v*` tag → PyPI Trusted Publisher.

The key thing the two cases prove: **even with different starting points (hand-wrapping vs. wrapping a mature library), keeping the §4 contract in CLAUDE.md as the source of truth makes the results isomorphic.** A new language implements that contract too — it does not redesign it.
