---
paths:
  - ".github/**"
  - "scripts/**"
  - "harness/**"
  - "DEPLOY.md"
---
<!-- doc-budget: max-bytes=8432 -->
<!-- 7770 → 8432 (2026-08-23): 래칫 조건 (1). 이 줄이 사 오는 것은 산문이 아니라 **기계 검증**이다 —
     `.github/security-config.json` 이 SSOT 가 되고 `repo-config.mjs check` 가 라이브와 대조한다(변이검증:
     securityDrift 를 빈 배열로 만들면 자가테스트가 운다. 대조군 origin/main 판은 통과했다).
     ⚠️ PHP·Rust 미지원은 실측으로만 알 수 있었다(GET 은 rust 를 포함했고 PATCH 가 422 로 거절했다). -->

# CI · release · harness rules

Per-language CI gotchas live in `.claude/rules/<lang>.md`.

## Repository rulesets

The definitions are `.github/rulesets/*.json` (the committed JSON is the SSOT); check them with `node scripts/repo-config.mjs check`.

- ⚠️ **`main` has exactly two required checks — `doc-facts` and `shell-exec-bits` — and adding a language CI to that list locks the repository.** All nine language CI workflows sit behind a workflow-level `paths:` filter, so on a PR that does not touch those paths the check is **never even created** and blocks on Pending forever (`bypass_actors: []`, so not even the owner can clear it). A job-level `if:` skip does the opposite — the check *is* created and counts as a success. **Do not confuse the two.**
- Also watch for: **four** pairs of colliding context names (the enumeration lives in CONTRIBUTING §4 — do not copy it here) and the absence of a `merge_group:` trigger (turn the merge queue on and everything deadlocks). The resolutions are in [CONTRIBUTING.md §4](../../CONTRIBUTING.md).
- **The three tag rulesets** (`RELEASE-TAGS-CREATE` · `-CREATE-GO` · `-IMMUTABLE`) are active but carry an admin bypass, so **the path where a human pushes a tag by hand is still open**. What they block is a `contents: write` credential creating release tags at will.
- ⚠️ **Keep the tag-cutting App in `tags-create.json` only.** Adding it to the other two collapses the single server-side enforcement point for both the Go exception and tag immutability. `scripts/test/test-repo-config.sh` pins the Integration bypass counts across the three files at **1/0/0**.
- ⚠️ **Secret scanning (+ push protection) and CodeQL default setup are on, and their desired state is `.github/security-config.json`** — `repo-config.mjs check` compares it with the live settings (admin token, so local like the rulesets). **CodeQL covers 7 of the 9 SDK languages: PHP and Rust cannot be selected in default setup** (the PATCH endpoint rejects them; its 422 lists the allowed values). ⚠️ Do not read the allowed set off `GET …/default-setup` — that `languages` field is what CodeQL *detected*, and it listed `rust` while PATCH refused it. Validity checks and non-provider patterns stay off deliberately (reasons are in that JSON).
- ⚠️ **Ruleset drift is invisible to CI** — CI only runs the guards' own self-tests and holds no admin token, so `repo-config.mjs check` has to be run **locally**. Do not treat "I did not touch the web UI" as a reason to skip it: GitHub also grows **new parameters on an existing rule type**, which the committed JSON then lacks even though nobody edited anything (measured 2026-08-21 — `require_extra_approval_for_unattributed_changes` appeared on the `pull_request` rule while PRIMARY's `updated_at` still read 2026-07-27). ⚠️ **Do not fix that with `repo-config.mjs pull`** — it rewrites all four files, sorting keys and arrays, so a one-field change arrives as a 60-line diff and a real drift would hide inside it. `check` compares canonically, so **add the single field by hand** and the guard goes green.

## Release

- ⚠️ **An unset deployment secret is a failure, not a skip.** A run that publishes nothing and still finishes green is indistinguishable from a successful one, and that quietly produces the state where the tag and the Release exist but the registry is empty. For the same reason we do not use `dotnet nuget push --skip-duplicate` (it disguises an already-burned version as a success).
- ⚠️ **This guard only works on an env-mapped value inside the step** — a job-level `if:` cannot read the secrets context.

## Dependabot

- ⚠️ **A Dependabot-triggered run has no Actions secrets** — `SONAR_TOKEN` becomes an empty string and SonarCloud is guaranteed to fail (that is not a signal about the code). `sonarcloud.yml` skips Dependabot PRs only. Duplicating the token was rejected: unreviewed package code would run in the same job as the token.
- ⚠️ **Pins dependabot must not bump** — `.github/dependabot.yml`'s `ignore` blocks them with reasons. A blocked bump **errors, not skips**
  1. **An action whose ref name *is* the meaning.** The pin for `dtolnay/rust-toolchain` is the head SHA of the `stable` **branch**, and dependabot swaps in the default-branch head, so the workflow dies on the spot with `'toolchain' is a required input`. `pypa/gh-action-pypi-publish` is worse — its default branch is `unstable/v1`, so instead of dying, **publishing to PyPI quietly moves to the unstable channel**. When bumping one, read the branch head directly with `gh api repos/<owner>/<repo>/branches/<branch> --jq .commit.sha`.
  2. **A version that expresses a consumer floor.** `kotlin-stdlib` is the consumer floor of the published artifact, so it has to move **together with** `languageVersion`/`apiVersion`. Take the patches, block minor and major.

## Local ↔ CI divergence

- The formatters flag an entire Windows CRLF working tree (Go `gofmt` · Node `prettier` · PHP `cs-fixer`) — normalise the changed files to LF and check again.
- SonarCloud's "0% Coverage on New Code" is fed by Kotlin kover alone, so it fails on every non-Kotlin PR (non-blocking).

## Harness

- ⚠️ **Every stage that downloads packages is Alpine (musl) based.** On Debian/glibc, the DNS proxy built into Windows Docker Desktop hands the registry's CNAME chain back to the glibc resolver as a failure, which blocks `dotnet restore`, `pip install` and the Maven and npm downloads (native Docker on CI is unaffected). ⚠️ The constraint is about **build** stages, not every image: `harness/apps/dotnet/Dockerfile` builds on `sdk:8.0-alpine` and then runs on Debian `aspnet:8.0`, which is fine because the runtime stage downloads nothing. This line said "every container" and that counterexample sits inside the repo.
- ⚠️ **The isolation model and the provenance assertion are different axes.** Isolation is 6/3 (6 source-added / 3 structurally isolated), but **provenance is recorded and asserted in all 9 languages** (`grep -l PROVENANCE_OK harness/install/consume/*-run.sh | wc -l` → 9). This class looks at the **actual download origin**, not at configuration — if it did not come from the local registry, `installed.ok` is not written. The guard is `scripts/test/test-harness-registries.sh`.
- ⚠️ **`install-verify.sh`'s per-language version derivation does not share globals** (they are separated by `PKG_VER_DEFAULT`). Order-dependent bugs of this class show up **only in a subset run**, which is why the nightly CI was green — keep **both** the default order and the order that reproduced the incident in the test.

## Invariants CI enforces that nothing else stated

Each of these was enforced by a guard and written down nowhere — so the only way to learn it was to break it and read the failure. One line each; the guard named is the owner of the detail.

- ⚠️ **Every tracked `*.sh` needs the exec bit (`100755`) in the git index.** `shell-exec-bits` is one of only two required checks on `main`, so a script added without it blocks the PR outright. Fix with `git update-index --chmod=+x <file>` — changing the file mode on disk is not enough on Windows.
- ⚠️ **Every self-test file must call `assert_report` as its last line.** That call is the *only* place the failure count becomes an exit code (`scripts/test/assert.sh`) — omit it and a file whose assertions all fail still exits 0, which reads as a passing guard.
- ⚠️ **A job that runs `govulncheck` must pin `check-latest: true` on `setup-go`.** Without it the job can resolve a cached toolchain and scan against a stale vulnerability database — a green scan that proves nothing. `scripts/check-ci-permissions.mjs` requires the literal.
- ⚠️ **`check-ci-permissions.mjs` takes a `--min-release=<n>` floor.** A guard that selects its targets by glob goes vacuous the moment the glob stops matching; the floor makes that failure loud instead. The number lives in `repo-hygiene.yml`, not here.
- ⚠️ **Release workflows carry `# >>> prerelease-classify` / `# <<< prerelease-classify` marker blocks.** `scripts/test/test-release-prerelease.sh` finds the classification logic by those markers, not by line position — delete or rename them and the prerelease/stable classification stops being checked.
