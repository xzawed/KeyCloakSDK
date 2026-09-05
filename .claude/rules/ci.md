---
paths:
  - ".github/**"
  - "scripts/**"
  - "harness/**"
  - "DEPLOY.md"
---
<!-- doc-budget: max-bytes=9985 -->
<!-- 9720 → 9985 (2026-09-02): 래칫 조건 (1) — 증가분이 **기계 검증을 사 온다**. 이 절의 규약이
     「가드가 강제하는데 아무 데도 안 적힌 불변식을 한 줄씩」이고, 이번 줄이 가리키는
     `test-selftest-hygiene.sh` 규칙 5 는 **이 PR 에서 새로 생긴 검사**다(그전에는 아무도 안 봤다).
     ⚠️ 직전 주석이 「다음 증가는 더 엄격히 봐야 한다」고 적어 두었으므로 그 기준으로 잰다:
     초안 373B → 문장을 다듬어 265B 로 줄인 뒤 **남은 만큼만** 올렸다(목표 바이트가 아니라
     필요 바이트). 담은 것 셋이 전부 수행 방법이다 — (1) 규칙, (2) `paths:` 가 잡을 스킵하는 것이
     아니라 **체크를 안 만든다**는 성질(그것이 왜 레인 배선으로는 부족한지), (3) 소유자와
     그 소유자가 **전제부터 검사한다**는 사실. 하나를 빼면 다음 세션이 레인에 배선하고 끝낸다.
     9200 → 9720 (2026-08-29, 같은 날 두 번째): 주간 `schedule` 규약 한 줄. ⚠️ 하루에 두 번 올린
     것을 그대로 적는다 — 래칫 크리프로 보일 수 있고, 실제로 다음 증가는 더 엄격히 봐야 한다.
     그럼에도 올린 근거: 이 줄이 담은 넷이 전부 **수행 방법**이다 — (1) 주간 스케줄이 있다는 사실,
     (2) `paths` 가 그것을 안 거른다는 성질, (3) 겨누는 것이 환경 드리프트라는 범위, (4) **크론을
     기다리지 말고 `workflow_dispatch` 로 당겨서 재라**는 지시. 넷 중 하나를 빼면 다음 세션이
     스케줄을 검증하지 못하거나 목적을 오해한다. 압축 대신 문장을 다듬어 506B → 477B 로 줄인 뒤
     남은 만큼만 올렸다(목표 바이트가 아니라 필요 바이트).
     8432 → 9200 (2026-08-29): 래칫 조건 (2) 사람이 문서의 역할을 바꿨다(판정 원문은
     docs/governance/process.md 머리의 같은 날짜 주석). 세 번째 핀 종류(**CI 매트릭스 하한**)와
     「막힌 범프는 스킵이 아니라 에러다」가 들어온다. ⚠️ 직전 세션은 예산이 0이라 이 둘을 한 줄로
     뭉개고 3번 항목을 아예 지웠는데, 그러면 `parallel < 2` 가 왜 있는지 아무 데서도 읽히지 않는다.
     `ruby/` 어디에도 그 이유가 없기 때문이다 — 값이 낮은 원인이 코드가 아니라 테스트 매트릭스다. -->
<!-- 7770 → 8432 (2026-08-23): 래칫 조건 (1). 이 줄이 사 오는 것은 산문이 아니라 **기계 검증**이다 —
     `.github/security-config.json` 이 SSOT 가 되고 `repo-config.mjs check` 가 라이브와 대조한다(변이검증:
     securityDrift 를 빈 배열로 만들면 자가테스트가 운다. 대조군 origin/main 판은 통과했다).
     ⚠️ PHP·Rust 미지원은 실측으로만 알 수 있었다(GET 은 rust 를 포함했고 PATCH 가 422 로 거절했다). -->

# CI · release · harness rules

Per-language CI gotchas live in `.claude/rules/<lang>.md`.

## Repository rulesets

The definitions are `.github/rulesets/*.json` (the committed JSON is the SSOT); check them with `node scripts/repo-config.mjs check`.

- ⚠️ **Every language CI also runs weekly on a `schedule`, and `paths:` does not filter that run** — that is the point. Locks/pins already block dependency drift; the weekly run hunts **environment** drift (runner image, action, API). Measured: harness's scheduled run fired 6 days straight while its paths changed on 2. Slot table lives in `ci.yml`'s `on:` comment. Every lane has `workflow_dispatch`, so **measure the scheduled path by pulling it forward, not by waiting for the cron**.
- ⚠️ **`main` has exactly two required checks — `doc-facts` and `shell-exec-bits` — and adding a language CI to that list locks the repository.** All nine language CI workflows sit behind a workflow-level `paths:` filter, so on a PR that misses those paths the check is **never created** and blocks on Pending forever (`bypass_actors: []` — not even the owner clears it). A job-level `if:` skip does the opposite: the check *is* created and counts as success. **Do not confuse the two.**
- Also watch for: **four** pairs of colliding context names (enumerated in CONTRIBUTING §4 — do not copy it here) and the absence of a `merge_group:` trigger (turn the merge queue on and everything deadlocks). Resolutions: [CONTRIBUTING.md §4](../../CONTRIBUTING.md).
- **The three tag rulesets** (`RELEASE-TAGS-CREATE` · `-CREATE-GO` · `-IMMUTABLE`) are active but carry an admin bypass, so **a human pushing a tag by hand is still open**. They block a `contents: write` credential creating release tags at will.
- ⚠️ **Keep the tag-cutting App in `tags-create.json` only.** Adding it to the other two collapses the single server-side enforcement point for both the Go exception and tag immutability. `scripts/test/test-repo-config.sh` pins the Integration bypass counts across the three files at **1/0/0**.
- ⚠️ **Secret scanning (+ push protection) and CodeQL default setup are on, and their desired state is `.github/security-config.json`** — `repo-config.mjs check` compares it with the live settings (admin token, so local like the rulesets). **CodeQL covers 7 of the 9 SDK languages: PHP and Rust cannot be selected in default setup** (PATCH rejects them; its 422 lists the allowed values). ⚠️ Do not read the allowed set off `GET …/default-setup` — that `languages` field is what CodeQL *detected*, and it listed `rust` while PATCH refused it. Validity checks and non-provider patterns stay off deliberately (reasons in that JSON).
- ⚠️ **Ruleset drift is invisible to CI** — CI only runs the guards' own self-tests and holds no admin token, so `repo-config.mjs check` has to be run **locally**. Do not treat "I did not touch the web UI" as a reason to skip it: GitHub grows **new parameters on an existing rule type**, which the committed JSON then lacks though nobody edited anything (measured: a new `pull_request` field appeared while PRIMARY's `updated_at` was unchanged). ⚠️ **Do not fix that with `repo-config.mjs pull`** — it rewrites all four files, sorting keys and arrays, so a one-field change arrives as a 60-line diff and real drift hides inside it. `check` compares canonically: **add the field by hand**.

## Release

- ⚠️ **An unset deployment secret is a failure, not a skip.** A run that publishes nothing and finishes green is indistinguishable from a successful one, and quietly leaves the tag and Release with an empty registry. Same reason we avoid `dotnet nuget push --skip-duplicate` (it disguises an already-burned version as success).
- ⚠️ **That guard only works on an env-mapped value inside the step** — a job-level `if:` cannot read secrets.

## Dependabot

- ⚠️ **A Dependabot-triggered run has no Actions secrets** — `SONAR_TOKEN` is empty and SonarCloud is guaranteed to fail (not a signal about the code); `sonarcloud.yml` skips Dependabot PRs **only**. Duplicating the token was rejected: unreviewed package code would share the job with it.
- ⚠️ **A bump the constraint forbids makes dependabot *error*, not skip** — leaving one pin out of the `ignore` list in `.github/dependabot.yml` reddens that ecosystem's whole job every week, and the failure shows up only under Insights → Dependency graph → Dependabot, **never in CI**. So a green CI says nothing about dependabot's health. Which pins are held, why, the condition to release each, and the `gh api …/branches/<branch> --jq .commit.sha` needed to bump a branch-ref action are **owned by that file's `ignore` comments** — do not restate them here (the count lived in two places and drifted twice in two days; the root `CLAUDE.md` paragraph is now machine-checked against the file, this one is not).

## Local ↔ CI divergence

- The formatters flag an entire Windows CRLF working tree (Go `gofmt` · Node `prettier` · PHP `cs-fixer`) — normalise the changed files to LF and check again.
- ⚠️ **Do not dismiss a red SonarCloud coverage gate as "kover only".** Eight languages generate coverage and `sonar-project.properties` wires report paths for all but C#, so "0% Coverage on New Code" is a signal about **that language's report**, not expected noise. Non-blocking, which makes it easy to wave through — read it first.

## Harness

- ⚠️ **Every stage that downloads packages is Alpine (musl) based.** On Debian/glibc, Windows Docker Desktop's DNS proxy hands the registry's CNAME chain back to the glibc resolver as a failure, blocking `dotnet restore`, `pip install` and the Maven/npm downloads (native Docker on CI is unaffected). ⚠️ The constraint is about **build** stages, not every image: `harness/apps/dotnet/Dockerfile` builds on `sdk:8.0-alpine` then runs on Debian `aspnet:8.0` — fine, because the runtime stage downloads nothing.
- ⚠️ **The isolation model and the provenance assertion are different axes.** Isolation is 6/3 (source-added / structurally isolated), but **provenance is asserted in all 9** (`grep -l PROVENANCE_OK harness/install/consume/*-run.sh | wc -l` → 9). It looks at the **actual download origin**, not configuration: if it did not come from the local registry, `installed.ok` is not written. Guard: `scripts/test/test-harness-registries.sh`.
- ⚠️ **`install-verify.sh`'s per-language version derivation does not share globals** (they are separated by `PKG_VER_DEFAULT`). Order-dependent bugs of this class show up **only in a subset run**, which is why the nightly CI was green — keep **both** the default order and the order that reproduced the incident in the test.

## Invariants CI enforces that nothing else stated

Enforced by a guard and written down nowhere else. One line each; the named guard owns the detail.

- ⚠️ **Every tracked `*.sh` needs the exec bit (`100755`) in the git index.** `shell-exec-bits` is one of only two required checks on `main`, so a script added without it blocks the PR outright. Fix with `git update-index --chmod=+x <file>` — changing the file mode on disk is not enough on Windows.
- ⚠️ **Every self-test file must call `assert_report` as its last line.** That call is the *only* place the failure count becomes an exit code (`scripts/test/assert.sh`) — omit it and a file whose assertions all fail still exits 0, which reads as a passing guard.
- ⚠️ **A job that runs `govulncheck` must pin `check-latest: true` on `setup-go`.** Without it the job can resolve a cached toolchain and scan against a stale vulnerability database — a green scan that proves nothing. `scripts/check-ci-permissions.mjs` requires the literal.
- ⚠️ **`check-ci-permissions.mjs` takes a `--min-release=<n>` floor.** A guard that selects its targets by glob goes vacuous the moment the glob stops matching; the floor makes that failure loud instead. The number lives in `repo-hygiene.yml`, not here.
- ⚠️ **A guard under `scripts/` must be exercised by `repo-hygiene.yml`** — directly or via a self-test it runs. Among `pull_request` workflows, only `repo-hygiene.yml` and `sonarcloud.yml` have no workflow-level `paths:` filter — ⚠️ count it with a YAML parser, not a regex (`on:` here uses inline flow maps). So a lane-only guard creates **no check** on the PR editing it. `test-selftest-hygiene.sh` rule 5 owns it and asserts that premise first.
- ⚠️ **Release workflows carry `# >>> prerelease-classify` / `# <<< prerelease-classify` marker blocks.** `scripts/test/test-release-prerelease.sh` finds the classification logic by those markers, not by line position — delete or rename them and the prerelease/stable classification stops being checked.
