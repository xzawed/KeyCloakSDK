# Contribution Guide (CONTRIBUTING)

This is the **single source of truth for the verification workflow** across all nine language SDKs
(Java · Python · Node · Go · C#/.NET · PHP · Rust · Ruby · Kotlin). It covers the gates you must
pass before merging, where tests go, and the PR checklist.

| You want | Read |
|---|---|
| Set up a machine to build this repo | [docs/guides/development-setup.md](docs/guides/development-setup.md) |
| Full command sheet for one language (single-test, coverage, lint, gotchas) | [`.claude/rules/<lang>.md`](.claude/rules/) |
| Architecture, cross-language contract, dependency choices | [CLAUDE.md](CLAUDE.md) |
| Release / publish procedure | [DEPLOY.md](DEPLOY.md) |
| Verification history | [docs/governance/](docs/governance/) |

---

## 0. Before you start

```bash
node scripts/doctor.mjs <lang>   # is this machine able to build that language?
```

`doctor` reads each language's declared minimum runtime from its build file and compares it with
what is installed. Fix whatever it reports before touching code — see
[development-setup.md](docs/guides/development-setup.md).

---

## 1. Gates you must pass before merging

CI runs per language (`.github/workflows/<lang>-ci.yml`, plus `ci.yml` for Java and
`repo-hygiene.yml` repo-wide). **If any of them is red, do not merge.**

Every language enforces the same *kinds* of gate. The thresholds themselves are declared in each
language's build configuration — that is the source of truth, so this table does not repeat them.

| Language | Runs every local gate | Compile | Unit | Coverage gate | Lint / format | Types | Integration (Docker) |
|---|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Java | `mvn -f java/pom.xml verify` | ✓ | ✓ | JaCoCo `jacoco:check` | enforcer | — | failsafe `*IT` |
| Python | `pytest -m "not integration" --cov=keycloak_sdk` | — | ✓ | `fail_under` | ruff (incl. bandit) | mypy strict | `pytest -m integration` |
| Node | `npm test` | tsc | ✓ | vitest thresholds | eslint + prettier | `npm run typecheck` | `npm run test:it` |
| Go | `go -C go test ./...` | ✓ | ✓ | `go tool cover` | `go vet` + `gofmt` | ✓ (compiler) | `-tags=integration` |
| C#/.NET | `dotnet test --filter "Category!=Integration"` | ✓ | ✓ | coverlet `/p:Threshold` | `dotnet format` | ✓ (compiler) | `Category=Integration` |
| PHP | `vendor/bin/phpunit --testsuite unit` | — | ✓ | clover + Xdebug | php-cs-fixer | PHPStan level max | `--testsuite integration` |
| Rust | `cargo test` | ✓ | ✓ | `cargo llvm-cov` | `cargo fmt` + clippy `-D warnings` | ✓ (compiler) | `--test integration_test -- --ignored` |
| Ruby | `bundle exec rspec` | — | ✓ | SimpleCov `minimum_coverage` | rubocop | — | `RUN_INTEGRATION=1 … --tag integration` |
| Kotlin | `./gradlew test` | ✓ | ✓ | Kover `koverVerify` | ktlint | ✓ (compiler) | `./gradlew integrationTest` |

Repo-wide, on every push and PR (`repo-hygiene.yml`):

```bash
node scripts/check-docs.mjs .     # docs must not contradict the build files
sh scripts/test/test-check-docs.sh
sh scripts/test/test-doctor.sh
```

> ⚠️ **Java's coverage gate is bound to the `verify` phase.** `mvn test` alone does *not* run
> `jacoco:check`, so a change can pass locally and fail CI. Use
> `mvn -pl <module> -am verify -DskipITs` when you want the gate without integration tests.

> ⚠️ **`gofmt` / `prettier` / `php-cs-fixer` flag every file on a Windows CRLF working tree.**
> Normalize the files you changed to LF and re-check, rather than reformatting the tree.

### Network-boundary coverage exemption (all nine languages)

The modules that own the actual HTTP boundary — `AuthClient`, the `admin` package/namespace, and
the composed client entry point — are **omitted from the coverage gate in every language** and are
verified by integration tests instead. Their exact names per language are in each build config and
in [`.claude/rules/<lang>.md`](.claude/rules/).

**So whenever you change boundary code, run that language's integration tests too.** The unit
coverage gate will not protect you there, by design.

---

## 2. Where tests go

| Language | Unit tests | Integration tests | Convention |
|---|---|---|---|
| Java | `java/<module>/src/test/java/` | `java/keycloak-sdk/src/test/java/` | unit `*Test`, integration `*IT` (surefire/failsafe split) |
| Python | `python/tests/unit/` (async under `unit/aio/`) | `python/tests/integration/` | `test_*`, integration via `@pytest.mark.integration` |
| Node | `node/test/unit/` | `node/test/integration/` | `*.test.ts` |
| Go | `go/*_test.go` | same files, `//go:build integration` | `TestXxx` |
| C#/.NET | `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/` | same project | integration marked `Category=Integration` |
| PHP | `php/tests/Unit/` | `php/tests/Integration/` | `*Test.php`, suites split in `phpunit.xml` |
| Rust | `#[cfg(test)]` in `rust/src/` | `rust/tests/integration_test.rs` | integration marked `#[ignore]` |
| Ruby | `ruby/spec/unit/` | `ruby/spec/integration/` | `*_spec.rb`, integration `:integration` tag |
| Kotlin | `kotlin/src/test/` | `kotlin/src/integrationTest/` | jvm-test-suite source sets |

All nine share the same real-Keycloak realm fixture for integration tests (`it-realm`).

**Security-critical code needs negative tests.** When you touch JWT validation, JWKS handling, or
token masking, add the attack cases alongside the happy path — `alg=none`, unsigned tokens,
algorithm confusion (HS/RS), wrong `iss` / `aud`, missing `exp`, clock-skew boundaries, unknown
`kid` flood. Follow the existing `JwtValidatorTest` / `test_jwt.py` patterns, and make the
assertions **non-vacuous** (sign the fixtures for real) so an accidental pass is ruled out.

---

## 3. PR checklist

- [ ] Work on a feature branch — no direct commits to `main`
- [ ] `node scripts/doctor.mjs <lang>` is clean for the languages you touched
- [ ] Every gate in section 1 is green locally for those languages
- [ ] New code has tests; security code has negative tests; the coverage gate still passes
- [ ] Boundary code changed → integration tests run as well
- [ ] No underlying library type leaks into the public API (hide it behind the facade — a rule
      shared by all nine languages; the documented exceptions are listed in [CLAUDE.md](CLAUDE.md))
- [ ] Docs updated where the *behaviour* changed. Do **not** hand-copy versions or test counts
      into prose — the build files and CI output are the source of truth, and
      `node scripts/check-docs.mjs .` enforces the anchored subset
- [ ] (Governance tasks) verdict recorded in [docs/governance/](docs/governance/)

---

## 4. Branch protection — what actually gates `main`

Branch protection is GitHub server state, not a repository file, so it is easy for it to drift from
what anyone believes it to be. This repository therefore keeps the intended state **in the repo**
at [`.github/rulesets/main.json`](.github/rulesets/main.json) and compares it against GitHub:

```bash
node scripts/repo-config.mjs check    # does GitHub match the committed definition?
node scripts/repo-config.mjs apply    # make GitHub match it (needs admin rights)
node scripts/repo-config.mjs pull     # accept the live config as the new definition
```

The live ruleset `PRIMARY` enforces, on `refs/heads/main`:

| Rule | Effect |
|---|---|
| `pull_request` (0 approvals) | every change goes through a PR; a solo maintainer can still self-merge |
| `deletion` · `non_fast_forward` | `main` cannot be deleted or force-pushed |
| `required_status_checks` | `doc-facts` and `shell-exec-bits` must be green — pinned to the GitHub Actions app so no other app can satisfy them by name |
| `bypass_actors: []` | **nobody bypasses, including the owner** |

Required checks also block direct pushes, not just merges — `git push origin main` is rejected with
`2 of 2 required status checks are expected`.

### ⚠️ Why the language CI jobs are *not* required

Only `repo-hygiene.yml` and `sonarcloud.yml` run without a workflow-level `paths:` filter. All nine
language CI workflows are path-filtered, and a path-filtered workflow **never creates a check run at
all** for a PR that misses its paths — GitHub's documentation is explicit: *"checks associated with
that workflow will remain in a 'Pending' state. A pull request that requires those checks to be
successful will be blocked from merging."* With `bypass_actors: []` nobody could clear it.

This is not theoretical here: the merged docs-only PR #101 produced exactly six check runs
(`doc-facts` ×2, `shell-exec-bits` ×2, `SonarCloud`, `SonarCloud Code Analysis`) and **zero** language
CI checks. Requiring any language job would have deadlocked it permanently.

Note the contrast that decides the rule: a job skipped by a **job-level `if:`** does create a check
run, reports `skipped`, and counts as success (this is why `SonarCloud` is mechanically safe to
require). A workflow skipped by a **workflow-level `paths:`** filter creates nothing.

**So this protection gates repository hygiene, not code correctness.** A PR that breaks a language's
unit tests still shows a red check and can still be merged. Treat section 1's gates as binding by
convention; only these two are binding by machine.

### Making the language CI requireable (follow-up, not done)

Move the filtering from workflow level to job level: a small `changes` job that always runs (e.g.
`dorny/paths-filter`), with every real job gated by `if: needs.changes.outputs.<lang> == 'true'`.
Skipped jobs then still report, so they can be required. Three things must be fixed along with it:

- ⚠️ A job skipped because a `needs:` dependency **failed** also reports `skipped` — so the `changes`
  job itself must be a required check, or a broken detector silently turns everything green.
- ⚠️ Three check names currently collide across workflows, so requiring them is ambiguous:
  `integration` (dotnet + php), `Integration (testcontainers, 실제 Keycloak 26.6)` (kotlin + rust),
  and `Integration tests (testcontainers, 실제 Keycloak)` (node + python).
- ⚠️ No workflow declares a `merge_group:` trigger. **Do not enable a merge queue** before adding it
  to at least `repo-hygiene.yml`, or every queued PR will deadlock.

---

## 5. Advisory quality roadmap (optional · not enforced in CI)

Coverage proves the code *ran*, not that the tests *catch defects*. These close part of that gap;
adopt them as advisory first, gate them only once stable.

- **Mutation testing** — Java: [pitest](https://pitest.org) (`org.pitest:pitest-maven`; confirm
  `pitest-junit5-plugin` compatibility with the JUnit Platform version this project pins before
  relying on it). Python: [mutmut](https://github.com/boxed/mutmut) — no native Windows support,
  run it in CI or WSL. Priority targets are the security-critical modules (`jwt.*` / `JwtValidator`).
- **Extended static analysis** — Python's ruff already enforces security (S/bandit), bugginess (B)
  and modernization (UP). Java enforces only dependency rules today; [SpotBugs](https://spotbugs.github.io),
  Checkstyle or Spotless would be the advisory addition.
- **Widening type checking** — `mypy src` is strict; extending it to `tests` needs the test types
  cleaned up first.
