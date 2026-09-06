# Contribution Guide (CONTRIBUTING)
<!-- doc-budget: max-bytes=15950 -->
<!-- 15940 → 15950 (2026-09-06, +10B). 규약 (1) — `--min-count-anchors=4` 를 붙였다.
     이 블록은 「exactly what CI runs」라고 말하므로 CI 와 **함께** 옮겨야 한다. -->
<!-- 15856 → 15940 (2026-09-06): 래칫 조건 (1) — **정확성 수정이 판정 방법을 사 온다.** §4 의
     「네 쌍이 충돌한다」가 거짓이었다(실측 세 쌍). 숫자만 3 으로 고치면 같은 드리프트가 세 번째로
     돌아오므로 **재는 법**을 함께 적었다 — 맨 잡 id 는 `name:` 도 `strategy.matrix` 도 없을 때만
     컨텍스트다. 그 한 문장이 순증분이고, 원래 있던 경위 서술(2026-08-22 · build-test)은 지웠다.
     ⚠️ 이 인상은 사람 리뷰 대상이다 — PR 본문에 명시했다. -->

<!-- 15838 → 15856 (2026-09-02): 래칫 조건 (1) — 18B 가 기계 검증을 사 온다. `--min-blob-refs=4`
     는 신설된 검사 10c(아카이브 참조 `git show <sha>:<path>` 가 해석되는가)의 공허함 방어
     하한이고, 이 줄은 「exactly what CI runs」라고 말한다. ⚠️ CI 와 **함께** 옮겨야 하는 이유가
     A2 다 — 여기가 CI 문자열과 갈리면 로컬 초록·CI 빨강이 다시 만들어진다. -->

This is the **single source of truth for the verification workflow** across all nine language SDKs
(Java · Python · Node · Go · C#/.NET · PHP · Rust · Ruby · Kotlin). It covers the gates you must
pass before merging, where tests go, and the PR checklist.

| You want | Read |
|---|---|
| Set up a machine to build this repo | [docs/guides/development-setup.md](docs/guides/development-setup.md) |
| Full command sheet for one language (single-test, coverage, lint, gotchas) | [`.claude/rules/<lang>.md`](.claude/rules/) |
| Architecture, cross-language contract, dependency choices | [CLAUDE.md](CLAUDE.md) |
| Release / publish procedure | [DEPLOY.md](DEPLOY.md) |
| How we work (phases · WBS · gates) | [docs/governance/process.md](docs/governance/process.md) |
| Every document under `docs/`, and what only that one tells you | [docs/README.md](docs/README.md) |

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

Every language enforces the same *kinds* of gate. This table names the **mechanisms**; it does not
repeat the thresholds (each language's build configuration owns those) and it does not repeat the
commands. **The command sheet for a language is [`.claude/rules/<lang>.md`](.claude/rules/)** — one
file per language, opening with the entry command, the single-test invocation and the lint command.

| Language | Compile | Unit | Coverage gate | Lint / format | Types | Integration (Docker) |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Java | ✓ | ✓ | JaCoCo `jacoco:check` | enforcer | — | failsafe `*IT` |
| Python | — | ✓ | `fail_under` | ruff (incl. bandit) | mypy strict | `pytest -m integration` |
| Node | tsc | ✓ | vitest thresholds | eslint + prettier | `npm run typecheck` | `npm run test:it` |
| Go | ✓ | ✓ | `go tool cover` | `go vet` + `gofmt` | ✓ (compiler) | `-tags=integration` |
| C#/.NET | ✓ | ✓ | coverlet **collector** → `scripts/check-coverage.mjs` | `dotnet format` | ✓ (compiler) | `Category=Integration` |
| PHP | — | ✓ | clover + Xdebug | php-cs-fixer | PHPStan level max | `--testsuite integration` |
| Rust | ✓ | ✓ | `cargo llvm-cov` | `cargo fmt` + clippy `-D warnings` | ✓ (compiler) | `--test integration_test -- --ignored` |
| Ruby | — | ✓ | SimpleCov `minimum_coverage` | rubocop | — | `RUN_INTEGRATION=1 … --tag integration` |
| Kotlin | ✓ | ✓ | Kover `koverVerify` | ktlint | ✓ (compiler) | `cd kotlin && ./gradlew integrationTest` |

Repo-wide, on every push and PR (`repo-hygiene.yml`):

```bash
node scripts/check-docs.mjs . --strict --min-facts=78 --min-anchors=26 --min-anchor-links=24 --min-blob-refs=4 --min-count-anchors=4   # exactly what CI runs
sh scripts/test/test-check-docs.sh
sh scripts/test/test-doctor.sh
```

> ⚠️ **Java's coverage gate is bound to the `verify` phase.** `mvn test` alone does *not* run
> `jacoco:check`, so a change can pass locally and fail CI. Use
> `mvn -pl <module> -am verify -DskipITs` when you want the gate without integration tests.

> ⚠️ **Adding a shell script or a self-test?** Two invariants block the PR and neither is visible
> from the code you are writing: a tracked `*.sh` needs the exec bit in the git index
> (`git update-index --chmod=+x`), and a self-test must end with `assert_report` or its failures
> never become an exit code. Those and three more are listed in
> [`.claude/rules/ci.md`](.claude/rules/ci.md).

> ⚠️ **`gofmt` / `prettier` / `php-cs-fixer` flag every file on a Windows CRLF working tree.**
> Normalize the files you changed to LF and re-check, rather than reformatting the tree.

### Dependency CVE gate (all nine languages)

Every language CI workflow also fails on a **known-vulnerable dependency**. It is a hard gate, not a
report. None of them runs as part of a language's entry command, so a clean local run does not
prove this gate green — **when you add or bump a dependency, expect this, not the
test suite, to be what stops the PR.**

Four run as their own CI job:

| Language | Job | Workflow |
|---|---|---|
| Java | `dependency-audit` (OSV.dev query over `mvn dependency:list -DincludeScope=runtime`) | `ci.yml` |
| Kotlin | `dependency-audit` (OSV.dev query over `runtimeClasspath`) | `kotlin-ci.yml` |
| Go | `vulncheck` (`govulncheck ./...`) | `go-ci.yml` |
| Rust | `audit` (`cargo audit`) | `rust-ci.yml` |

The other five run as a step inside the language's existing build job: `pip-audit` (Python) ·
`npm audit --audit-level=high --omit=dev` (Node) ·
`dotnet list package --vulnerable --include-transitive` (C#/.NET) · `composer audit` (PHP) ·
`bundler-audit check --update` (Ruby).

The rationale, the documented scope exceptions, and why the JVM languages query OSV.dev rather than
running OWASP dependency-check are in [SECURITY.md](SECURITY.md).

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
- [ ] (Governance tasks) the verdict — and its revival condition, if rejected — is in the commit message

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

Among `pull_request` workflows only `repo-hygiene.yml` and `sonarcloud.yml` run without a
workflow-level `paths:` filter (`test-selftest-hygiene.sh` 7b pins it). All nine
language CI workflows are path-filtered, and a path-filtered workflow **never creates a check run at
all** for a PR that misses its paths — GitHub's docs are explicit: *"checks associated with that
workflow will remain in a 'Pending' state. A pull request that requires those checks to be successful
will be blocked from merging."* With `bypass_actors: []` nobody could clear it.

Not theoretical: a merged docs-only PR produced six check runs (`doc-facts` ×2, `shell-exec-bits` ×2,
`SonarCloud` ×2) and **zero** language CI checks. Requiring any language job would have deadlocked it.

Note the contrast that decides the rule: a job skipped by a **job-level `if:`** does create a check
run, reports `skipped`, and counts as success (this is why `SonarCloud` is mechanically safe to
require). A workflow skipped by a **workflow-level `paths:`** filter creates nothing.

**So this protection gates repository hygiene, not code correctness.** A PR that breaks a language's
unit tests still shows a red check and can still be merged. Treat section 1's gates as binding by
convention; only these two are binding by machine.

### Tag rulesets — deliberately the mirror image of `main.json`

`main.json` has `bypass_actors: []` — nobody bypasses, not even the owner. The three
tag rulesets do the opposite on purpose, and they **must**: a tag ruleset with an empty
bypass list can never be satisfied by anyone, so every one of the nine releases would be
permanently blocked with no way to unblock it.

| Ruleset | Refs | Rule | Who may bypass (as committed) |
|---|---|---|---|
| `RELEASE-TAGS-CREATE` | the eight non-Go release tags | `creation` | repository admin **and the release App** (`Integration`) — the only file the App may appear in |
| `RELEASE-TAGS-CREATE-GO` | `go/v*` | `creation` | repository admin **only** — never the App |
| `RELEASE-TAGS-IMMUTABLE` | all nine | `update`, `deletion` | repository admin **only** — never the App |

**The release App belongs to `RELEASE-TAGS-CREATE` and to nothing else** — that is what makes the
automated release path work. It is in that one file and no other: `tags-create-go.json` and
`tags-immutable.json` still list the admin alone, which is what makes "Go is released by a human"
and "a release tag cannot be moved or deleted" facts about server state rather than promises inside
a workflow file. `scripts/test/test-repo-config.sh` pins the split (one `Integration` bypass in
`tags-create.json`, zero in the other two) so that adding the App to the wrong file is a red check
rather than a silent loss of the only server-side enforcement point. The full procedure — including
why a web-UI edit is erased by the next `repo-config.mjs apply` (it sends a full `PUT` of the
committed file) — is [DEPLOY.md §2-F](DEPLOY.md). If a secret or ruleset ever goes missing,
`dispatch-release.yml` fails closed again and releases fall back to hand-pushed tags.

**Whether all four rulesets are currently applied is answered by `node scripts/repo-config.mjs
check`**, which compares the live repository against the committed definitions (`PRIMARY` on `main`,
plus the three tag rulesets above). Read it from that command, not from a date written here. The hand-pushed release path is unaffected — every tag ruleset carries the repository
admin as a bypass actor, verified against the live API after applying.

⚠️ **A committed ruleset is still not an applied ruleset**, and that asymmetry has not gone away.
`repo-config.mjs` only walks the files in `.github/rulesets/`, so it cannot see a ruleset that exists
on github.com but has no file, and CI runs the checker's *self-test* rather than `check` (no admin
token is stored here). So a ruleset **deactivated on the web UI would not be reported by anything in
CI**. The only thing that notices a missing or deactivated tag ruleset is `dispatch-release.yml`,
which queries the API before cutting a tag and **stops** if any of the three names is absent or not
`enforcement: active`. Re-run `check` locally after any web-UI change to repository rules.

**Why Go is separated:** Go's tag *is* its publication — `proxy.golang.org` serves whatever
the tag points at, regardless of CI. No gate can exist after the tag, so Go is excluded from
automated release. Keeping that exclusion in a workflow file would not be enough: `on: push`
runs the workflow as it exists in the pushed commit, so a single merge editing that workflow
would erase the exclusion. A ruleset is server-side state and survives it.

**Why creation and immutability are separate files:** `bypass_actors` applies to a whole
ruleset, so "the App may create but may not delete" cannot be expressed in one file.

⚠️ Do not "harmonize" these with `main.json`.

### Making the language CI requireable (follow-up, not done)

Move the filtering from workflow level to job level: a small `changes` job that always runs (e.g.
`dorny/paths-filter`), with every real job gated by `if: needs.changes.outputs.<lang> == 'true'`.
Skipped jobs then still report, so they can be required. Three things must be fixed along with it:

- ⚠️ A job skipped because a `needs:` dependency **failed** also reports `skipped` — so the `changes`
  job itself must be a required check, or a broken detector silently turns everything green.
- ⚠️ **Three** check names currently collide across the `pull_request` workflows, so requiring them
  is ambiguous: `integration` (dotnet + php — neither declares a `name:`, so the job id becomes the
  context), `Integration (testcontainers, 실제 Keycloak 26.6)` (kotlin + rust), and `Integration
  tests (testcontainers, 실제 Keycloak)` (node + python). ⚠️ **Re-measure before acting on that
  number** (YAML parser, matrices expanded): a bare job id is the context only when the job has
  neither `name:` nor `strategy.matrix`. It has drifted twice.
- ⚠️ No workflow declares a `merge_group:` trigger. **Do not enable a merge queue** before adding it
  to at least `repo-hygiene.yml`, or every queued PR will deadlock.
