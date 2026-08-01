# Deployment Guide (DEPLOY)

All nine language SDKs have a **tag-driven release CI** wired up — though none of it has ever run: the repository has zero tags and nothing has been published to any public registry (§5 spells out exactly what is and is not proven). Actual deployment is a human-gated approval step triggered **only when a human pushes a tag**, and the prerequisites below (accounts, keys, tokens) can only be performed by the repository owner.

> ⚠️ Deployment is irreversible (you cannot re-publish the same coordinate/version). Verify your artifacts first with a dry-run (at the end of each section), and read §6 **before** you need it — what "irreversible" costs you differs enormously per registry.
>
> ✅ **Pre-check before real deployment**: the install-&-operate verification harness in [`harness/install/`](harness/install/README.md) installs each SDK **from a local registry, as if it were a published package**, and verifies that it actually works (quickstart + conformance + security) against a real Keycloak. `cd harness/install && ./install-verify.sh <lang>`. Passing it for a language is a useful pre-check of the install path before you push that language's tag.
>
> ⚠️ **What that harness does not prove.** It swaps only the *dependency-resolution source* — a local Verdaccio / pypiserver / BaGetter / Satis / staged `.m2` / file `GOPROXY` — for the real one. Every failure mode that is unique to a **public** registry is therefore outside its reach: PyPI, npm and RubyGems OIDC trusted publishing; GPG signing and Central Portal staging; Packagist's view of the repository; crates.io name ownership; npm provenance attestation; Go module-proxy immutability. It is **not** "isomorphic to real deployment", and passing it is not a release gate. Note also that the nightly `harness` workflow's `install-all` job had been **RED on Kotlin for seven consecutive nights** — the published jar carried `@Metadata(mv=[2,4,0])`, which the consumer app on Kotlin 2.2.20 cannot read. That cause was fixed by pinning `languageVersion`/`apiVersion` to 2.2 in `kotlin/build.gradle.kts` (measured in a container: the jar then carries `mv=[2,2,0]`), and **a green run has since been observed** — run `30676364773` finished `install-all: success` with all nine rows ✓ in `INSTALL-MATRIX.md` (Kotlin included: artifact · publish · install · quickstart · app-boot, conformance 26/26, security 9/9). The limitation stated above still stands regardless: a green matrix is evidence about the *install path*, not about the public-registry-specific failure modes listed here.
>
> 🛠️ **Helper scripts**: the tables and commands in this document come from `scripts/lib/deploy-facts.sh` (single source of truth). Rather than scanning the tables yourself, use the two helpers below to check status and obtain the commands.
> - `./scripts/release-readiness.sh [lang ...]` — reports each language's secret/registry/tag readiness read-only (no values exposed; with no arguments, all nine).
> - `./scripts/release-trigger.sh <lang> <version>` — **only prints** the version-bump guidance + dry-run command + exact tag push command (human-gate — it never runs `git tag`/`push` itself).

---

## §0. Overview + Readiness Matrix

Rows are in the recommended deployment order explained below.

| Language | Registry | Auth | Tag | Version bump | Secrets (count) | Install after release |
|---|---|---|---|---|---|---|
| **Python** | PyPI | OIDC | `py-v*` | `python/pyproject.toml` `[project].version` | 0 (OIDC) | `pip install keycloak-sdk` |
| **.NET** | NuGet | api-token | `dotnet-v*` | none (tag injected via `-p:Version`) | 1 (`NUGET_API_KEY` · **hard-fails if unset**) | `dotnet add package Xzawed.Keycloak.Sdk` |
| **Ruby** | RubyGems | OIDC | `ruby-v*` | `ruby/lib/keycloak_sdk/version.rb` `VERSION` | 0 (OIDC + `release` environment) | `gem install keycloak-sdk` |
| **Node** | npm | OIDC | `node-v*` | `node/package.json` `version` | 0 (OIDC + provenance) | `npm install @xzawed/keycloak-sdk` |
| **Rust** | crates.io | api-token | `rust-v*` | `rust/Cargo.toml` `[package].version` | 1 (`CARGO_REGISTRY_TOKEN` · hard-fails if unset) | `cargo add keycloak-sdk` |
| **Java** | Maven Central | maven-gpg | `v*` | automatic (versions-maven-plugin, tag value injected) | 4 (GPG 2 + Portal token 2 · **all four checked, hard-fails if any is unset**) | `io.github.xzawed:keycloak-sdk` |
| **Kotlin** | Maven Central | maven-gpg | `kotlin-v*` | `kotlin/build.gradle.kts` `version` (manual) | 4 (vanniktech names · **all four checked, hard-fails if any is unset**) | `io.github.xzawed:keycloak-sdk-kotlin` |
| **Go** | Go module proxy (proxy.golang.org) | none | `go/v*` | none (tag = SSOT) | 0 | `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z` |
| **PHP** | Packagist — **via the mirror repository `xzawed/keycloak-sdk-php`** | split-token | `php-v*` | none (tag = SSOT) | 1 (`PHP_SPLIT_TOKEN` · **hard-fails if unset**) | `composer require xzawed/keycloak-sdk` |

> ⚠️ **PHP does not publish from this repository, and it never could.** Composer's VCS driver only reads a `composer.json` at a repository's **root**; it cannot treat a subdirectory as the package root, and Packagist does not support subdirectories either. This monorepo has no root `composer.json` (only `php/composer.json`), so Packagist was never able to track `xzawed/KeyCloakSDK`. `php-release.yml` therefore runs `git subtree split --prefix=php` and pushes the result to a separate read-only mirror repository, **`xzawed/keycloak-sdk-php`**, tagging it `vX.Y.Z` there (Composer cannot parse `php-vX.Y.Z` as a version). **That mirror is what gets registered on Packagist.** It now exists (`xzawed/keycloak-sdk-php`, public, still empty) and `PHP_SPLIT_TOKEN` is set; what remains is the Packagist registration, which **cannot happen until the first release populates the mirror** (Packagist needs a `composer.json` on a default branch, and an empty repository has neither). See §2-D.

**Recommended deployment order — ordered by recoverability, not by how easy the auth setup is**:

```
python → dotnet → ruby → node → rust → java → kotlin → go → php
```

### Step 0 — spend the first tag on PHP as a rehearsal, before that order starts

⚠️ **This is not a real publish, which is exactly why it goes first.** Until the mirror is registered on Packagist (§2-D step 3), the `split` job pushes to a GitHub repository that **no registry is watching**, and `main` is force-pushed on every release anyway — so nothing consumable is created and the whole thing is undoable with a tag delete. What it *does* exercise, for real, is the machinery every other language depends on: a human tag push → `verify` → `integration` against a live Keycloak → `install-smoke` → **a real stored credential** (`PHP_SPLIT_TOKEN`) → an authenticated push to an external repository → `gh release create`. None of that has ever run (§5). Spending the first execution on the one language where a failure costs nothing is worth more than the ordering purity of going by recoverability alone.

This also happens to match what is actually set up: `./scripts/release-readiness.sh` currently reports **php as the only language whose credential is in place** (`secrets=set`); the four token/GPG languages are `unset` and the three OIDC languages still need their publisher registered.

Once the rehearsal has passed and the mirror is registered on Packagist, PHP takes its normal place in the order above (last, group 4 below).

### Why that order

The first publish of a coordinate is irreversible everywhere, so the axis that actually matters is "if this version turns out to be broken, what can I do about it?" (§6 has the per-registry detail):

1. **python · dotnet · ruby · node · rust** — the registry supports yank / unlist / deprecate, so a bad version can at least be pulled out of resolution.
2. **java · kotlin** — Maven Central is immutable once released, but the Central Portal puts a human staging step in front of it: a bad upload can be dropped *before* it is published, at zero cost.
3. **go** — nothing to set up, and the weakest recovery of all nine. Once `proxy.golang.org` has cached the version it is immutable and there is no yank; the only remedy is a `retract` directive in a *later* release.
4. **php** — recovery is the *best* of the nine while Packagist registration is still pending (see the rehearsal note above), which is why it moved to the front rather than the back. Once the mirror **is** registered, PHP joins group 1: withdrawal is a tag delete on the mirror plus a Packagist update.

> The order this document used to recommend ("easy auth → hard auth", starting with Go) optimised for the wrong axis: Go is the easiest to *set up* and the hardest to *undo*. A later revision put PHP last for a reason that has since expired — the mirror repository did not exist then; it does now.

### Before the first tag — what has and has not been proven

Measured locally (this is the "Tier 1" pre-flight; none of it touches a public registry):

| Check | Result |
|---|---|
| `cargo publish --dry-run --locked` | **pass** — 19 files packaged, and the packaged tree *compiles*. The only true registry-equivalent dry-run of the nine |
| `npm publish --dry-run` | **pass** — 75 files, `LICENSE` + `README.md` present, name/version correct |
| `twine check --strict` (wheel + sdist) | **pass** |
| `dotnet pack` → nuspec | **pass** — `LICENSE`, `README`, XML docs; `<repository>` at repo root, `<projectUrl>` at `tree/main/dotnet` |
| `gem build` | **pass, warning-free** |
| `mvn -Prelease package` | **pass** — `META-INF/LICENSE` in all five jars, byte-identical to root `LICENSE` |
| Name availability (7 registries) | **all unregistered** — crates.io · PyPI · npm · RubyGems · NuGet · Packagist · Maven Central |

⚠️ **Still unproven, and only a real publish can prove it**: OIDC claim matching (PyPI · npm · RubyGems), GPG signing, Central Portal staging, npm provenance attestation, `sum.golang.org` inclusion, and Packagist's VCS driver actually reading the mirror. Treat every first tag as a first execution, not a regression check.

**Check the current status**: `./scripts/release-readiness.sh` (with no arguments, it reports all nine languages at once, in this order).

---

## §1. Common Principles

- **Tag-driven**: all nine release workflows are triggered only by pushing a tag in a specific format (the "Tag" column of the §0 table).
- **`needs:` gate**: nothing publishes unless the tagged commit's checks are green. Eight languages (python · node · go · rust · dotnet · ruby · kotlin · php) now run their **integration suite against a real Keycloak** in a dedicated `integration` job that the publishing job lists in `needs:`, so a tag can no longer publish on unit tests alone. PHP was the last exception and no longer is: `php-release.yml` gained an `integration` job (`phpunit --testsuite integration`) that its `split` job lists in `needs:` alongside `verify`. **Java** used to be the odd one out — a single `release` job relied on the Maven lifecycle running the test and integration-test phases inline before `deploy`. That worked, but the guarantee lived in a lifecycle rather than at a job boundary, so a single `-DskipITs` could have removed it silently. `release.yml` now has its own `integration` job (`mvn -B -f java/pom.xml verify`) that the `release` job lists in `needs:`, so all **nine** languages state the gate the same way.
- **`install-smoke` gate**: unit and integration suites both run *inside the monorepo*, so neither can catch a defect that only exists in the **packaged artifact** — manifest metadata, file include/exclude rules, published-artifact compatibility. That layer is exactly where the Kotlin binary-metadata problem lived. Every release workflow now calls the reusable [`install-smoke.yml`](.github/workflows/install-smoke.yml) for its own language before publishing: it publishes to a **local** registry and then installs from it into a clean container outside the monorepo and runs the quickstart. The publishing job lists `install-smoke` in `needs:`, so a package that cannot actually be consumed never reaches a public registry. It reuses `harness/install/install-verify.sh` — the same recipe the nightly `harness` workflow already runs — and that script exits non-zero if any language's matrix row is ✗. ⚠️ It builds Docker images, so it is slow (45-minute timeout) and is deliberately wired only into the tag path, never into PRs.
- **Go's gate is different in kind**: `go-release.yml`'s `verify`/`integration` jobs run before the `release` job, but the module proxy serves whatever the *tag* points at — it does not wait for CI. Once the tag is pushed, the version is effectively public.
- **PHP's gate is real now**: `verify` + `integration` → `split`, and GitHub Release creation lives inside `split`, **after** the mirror push succeeds — so the release notes can no longer announce a publication that did not happen.
- **human-gate**: the actual deployment trigger (tag push) must always be performed **by a human directly**. `release-trigger.sh` only prints the commands and does not run `git tag`/`git push` itself.
- **Irreversible**: no registry allows re-publishing the same version — if you push a wrong tag, that version number is effectively burned.
- **Dry-run required**: before pushing a tag, always confirm with a local dry-run (building only the artifacts, without deploying) that the artifacts are generated correctly (per-language in the §0 table; also included in the `release-trigger.sh` output).

**Version-bump rules**:

| Type | Languages | Description |
|---|---|---|
| Automatic (4) | go · php · dotnet · java | The tag itself is the version SSOT — the workflow injects the tag value into the build (no file edits needed). Java is the sole exception: `versions-maven-plugin` replaces the POM's `-SNAPSHOT` with the tag value before deploying (the main POM keeps `-SNAPSHOT`). |
| Manual (5) | rust · python · node · ruby · kotlin | **Before** pushing the tag, a human must bump the source's version field directly and commit (the exact location is in the "Version bump" column of the §0 table). |

**Tag ↔ version guard (the five manual-bump languages)** — bumping the version file is still a human responsibility, but it is no longer *only* that. `rust-release.yml` · `python-release.yml` · `node-release.yml` · `ruby-release.yml` · `kotlin-release.yml` each begin, as the first step after checkout, by extracting the declared version from the manifest (`Cargo.toml` · `pyproject.toml` · `package.json` · `lib/keycloak_sdk/version.rb` · `build.gradle.kts`) and comparing it with the version implied by the tag. On mismatch the job stops with `::error::` **before any toolchain is installed and before anything is built**. An empty extraction is treated as failure too (fail-closed) — a silently blank value would never compare "different" from anything and would let the check pass vacuously. So this runbook's classic accident — pushing `py-v0.2.0` while `pyproject.toml` still says `0.1.0` — is now caught by CI instead of by PyPI.

The comparison is **literal string equality** against the tag suffix, which matters for prerelease spellings (§7). The four auto-bump languages (go · php · dotnet · java) have no such guard and need none: the tag *is* the version there, so there is no second place for it to disagree with.

---

## §2. One-Time Setup per Auth Model

Since the same auth model has the same setup procedure, it is explained once per group. Only the secret **names** differ per language.

### A. Maven Central + GPG (Java · Kotlin)

1. **Namespace verification (one-time)**: log in to https://central.sonatype.com **with your GitHub account (`xzawed`)** → the `io.github.xzawed` namespace is automatically verified/provisioned (if not, go to View Namespaces → add `io.github.xzawed` → create a **public temporary repository** with the displayed key name on GitHub to confirm ownership).
2. **Central Portal token issuance (one-time)**: Central Portal → Account → **Generate User Token** → obtain a username/password.
3. **GPG signing key generation and keyserver distribution (one-time)**:
   ```bash
   gpg --gen-key                          # enter name / email (xzawed31@gmail.com) / passphrase
   gpg --list-secret-keys --keyid-format=long   # find the KEYID
   gpg --keyserver keyserver.ubuntu.com --send-keys <KEYID>   # distribute the public key (required — signature verification fails if not done first)
   gpg --armor --export-secret-keys <KEYID> > private.asc     # export the private key armored
   ```
4. **Register GitHub Secrets** (Settings → Secrets and variables → Actions) — **the names differ per language**:

   | Secret | Java | Kotlin | Value |
   |---|---|---|---|
   | GPG/signing private key | `MAVEN_GPG_PRIVATE_KEY` | `SIGNING_IN_MEMORY_KEY` | full contents of `private.asc` (armored) |
   | GPG/signing passphrase | `MAVEN_GPG_PASSPHRASE` | `SIGNING_IN_MEMORY_KEY_PASSWORD` | the GPG passphrase |
   | Portal token username | `CENTRAL_TOKEN_USER` | `MAVEN_CENTRAL_USERNAME` | the token username from step 2 |
   | Portal token password | `CENTRAL_TOKEN_PW` | `MAVEN_CENTRAL_PASSWORD` | the token password from step 2 |

5. **Behavior when a secret is unset — both languages fail closed, and both now name the missing secret**: each job checks **all four** of its own secrets in a step and, if any are missing, emits `::error::` naming exactly which ones and exits 1. Java (`MAVEN_GPG_PRIVATE_KEY` · `MAVEN_GPG_PASSPHRASE` · `CENTRAL_TOKEN_USER` · `CENTRAL_TOKEN_PW`) does this in a preflight right after checkout, before `setup-java` even imports the GPG key; Kotlin (`MAVEN_CENTRAL_USERNAME` · `MAVEN_CENTRAL_PASSWORD` · `SIGNING_IN_MEMORY_KEY` · `SIGNING_IN_MEMORY_KEY_PASSWORD`) does it immediately before the upload. Java previously failed later instead, inside `mvn -Prelease deploy` — fail-closed either way, but a noisier error that never said the cause was an unset secret.

   > ⚠️ **This used to be much worse.** The old Kotlin guard checked only `MAVEN_CENTRAL_USERNAME` and exited 0 when it was missing — a silent skip that ended green — and it did not check the signing key at all, which permitted an **unsigned** Central Portal upload on a green run. That is fixed. (Note that a job-level `if:` cannot read the `secrets` context in GitHub Actions, which is why the guard has to live inside the step, on env-mapped values.)
6. **Two-step manual release**: the workflow only auto-uploads **as far as Central Portal staging**. The actual public release (Publish) is completed only when **a human manually Publishes** from the Deployments screen in the [Central Portal](https://central.sonatype.com) (when autoPublish is not configured).

### B. OIDC / Trusted Publisher (Python · Node · Ruby)

⚠️ **These three registries do not behave the same way, and the difference decides whether the first publish can use OIDC at all.** Verified against each registry's own documentation:

| Registry | Pending publisher for a package that does not exist yet? | First publish over OIDC with no stored secret? |
|---|---|---|
| **PyPI** | **Yes** — *"Trusted Publishers are not just for pre-existing PyPI projects: you can also use them to create a PyPI project!"* | Yes. Pending publishers *"are converted into 'normal' publishers on first use"* |
| **RubyGems** | **Yes** — *"Trusted publishers are not just for existing gems, they can also be used to push new gems!"* Register a *pending* publisher under your profile | Yes. Converted to a normal publisher on first successful push, and you are added as gem owner |
| **npm** | **No.** `npm trust` states the prerequisite plainly: *"The package you're configuring must already exist on the npm registry."* The trusted-publishers guide never mentions it | **No** — one bootstrap publish is required first (see below) |

1. **Pre-register a Pending Publisher (Python and Ruby only — one-time, no secret needed)**: register in the registry's Publishing settings **before** pushing the tag. Values are **owner=`xzawed`** · **repo=`KeyCloakSDK`**, workflow filename per language:
   - Python: `python-release.yml` — no expiry is documented for a pending publisher, so this can be registered well in advance.
   - Ruby: `ruby-release.yml` · **environment is `release`** (Python leaves it blank). ⚠️ **Register it and push the tag in the same sitting.** RubyGems creates pending publishers with `expires_at: 12.hours.from_now` (read from the `pending_trusted_publishers_controller` source — this is *not* in the published guide, so treat it as a strong operational assumption rather than a documented contract).
2. **Node needs one bootstrap publish, and the safe way to do it is through CI.** Because `npm trust` requires the package to exist, `node-v0.1.0*` will reach the publish step and fail authentication. Nothing is burned (npm never receives the tarball), but the OIDC path cannot make the *first* publish.
   ⚠️ **Do not bootstrap with a local `npm publish`.** `node/package.json` sets `publishConfig.provenance: true`, and provenance cannot be generated outside a supported CI — a local publish errors, and reaching for `--provenance=false` hand-publishes the real coordinate with no provenance, no `install-smoke`, no integration gate and no tag↔manifest check. Do it in CI instead, keeping every gate:
   1. Add a temporary `NPM_TOKEN` secret and map it as `NODE_AUTH_TOKEN` on the existing publish step in `node-release.yml`.
   2. Push the RC tag (`node-v0.1.0-rc.1`) through the normal pipeline.
   3. `npm trust github @xzawed/keycloak-sdk --repo xzawed/KeyCloakSDK --file node-release.yml --allow-publish` — requires **npm ≥ 11.15.0** (higher than the version needed for trusted publishing itself) and **account-level 2FA**; granular tokens with the bypass-2FA option are rejected.
   4. Delete the secret and the env mapping, then let `0.1.0` go out over pure OIDC.
3. Since this is OIDC, no stored secrets are needed **after** the bootstrap above (the workflow exchanges directly with the registry using a GitHub Actions OIDC token).

> This section previously said the opposite for two of the three: that pending registration worked for all three (wrong for npm), and that RubyGems required a manual API-key publish first (wrong, and wrong in the costly direction — a hand-pushed `gem push` bypasses `install-smoke`, the integration gate and the tag↔version guard, and burns the coordinate outside the pipeline).

### C. API Token (.NET · Rust)

1. Issue an API token from the registry (NuGet: nuget.org → API Keys, crates.io: Account Settings → API Tokens).
2. Register it in GitHub Secrets:
   - .NET: `NUGET_API_KEY`
   - Rust: `CARGO_REGISTRY_TOKEN`
3. **Behavior when unset — both fail closed now**:
   - .NET: if `NUGET_API_KEY` is missing, the publish step emits `::error::` and exits 1. **This changed.** It used to exit 0 (a silent skip) while the workflow went on to create a GitHub Release anyway — a green run and a release page for a version that had never reached NuGet.
   - Rust: if `CARGO_REGISTRY_TOKEN` is missing, `cargo publish` hard-fails, as it always has.
4. **`--skip-duplicate` has been removed from `dotnet nuget push`.** It reported a push of an already-published version as success, which is exactly the signal you need when a version has been burned. A duplicate now fails the job.

### D. Subtree Split → Mirror Repository (PHP)

**There is no webhook path for PHP, and there never was.** Composer's VCS driver reads only the `composer.json` at a repository's **root**; there is no way to point it at a subdirectory, and Packagist does not support subdirectories either. This monorepo has no root `composer.json` — only `php/composer.json` — so "push a tag and Packagist picks it up" could not have worked here at any point.

What `php-release.yml` does instead: once `verify` passes, the `split` job runs `git subtree split --prefix=php`, force-pushes the resulting history to the `main` branch of a **separate read-only mirror repository**, and pushes a bare `vX.Y.Z` tag there (derived from `php-vX.Y.Z`, because Composer cannot parse the prefixed tag as a version). Packagist watches that mirror.

**One-time human setup:**

⚠️ **The Packagist registration cannot come before the first release.** Packagist reads a `composer.json` from the default branch of the repository you submit; the mirror starts out empty, with no default branch and no files, so a submission at that point has nothing to read. The workable order is therefore **create → token → first release (this populates the mirror) → register**, not create → register → token.

1. ✅ **Create the mirror repository `xzawed/keycloak-sdk-php`** — public and empty (no README, no license, no initial commit; the split force-pushes over `main`). It is a generated artifact: never commit to it directly. *(Done — public, empty.)*
2. ✅ **Create the `PHP_SPLIT_TOKEN` secret in *this* repository** (Settings → Secrets and variables → Actions) — a token with write access to the mirror (a fine-grained PAT scoped to `xzawed/keycloak-sdk-php` with Contents: read and write suffices; `Workflows` is **not** needed, because the split carries no workflow files — `php/vendor/` is untracked). If it is unset, the `split` job emits `::error::` and exits 1; nothing is pushed and no GitHub Release is created. *(Done — verify with `./scripts/release-readiness.sh php`, which reports `secrets=set`.)*
3. ⬜ **Register the mirror on Packagist**, *after* the first `php-v*` release has populated it — https://packagist.org → Submit → `https://github.com/xzawed/keycloak-sdk-php`. Register the **mirror**, not this monorepo.

> One consequence worth knowing: until step 3 is done, a push to the mirror publishes nothing consumable — no registry is watching it, and the mirror's `main` is force-pushed on every release anyway. That makes the first PHP release the one language whose "publish" step is genuinely reversible.

**Notes:**

- The package name on Packagist is still `xzawed/keycloak-sdk` — it comes from `php/composer.json`, which the split carries along. Only the *source repository* Packagist reads is different.
- The mirror's `main` is force-pushed on every release; the version tag is **not** forced. If `vX.Y.Z` already exists on the mirror the tag push fails on purpose, so a burned version cannot be silently overwritten — the same principle as removing `--skip-duplicate` from the .NET push.
- GitHub Release creation lives in the `split` job, after the mirror push. That ordering is deliberate: the notes cannot claim a publication that did not happen.

### E. No Setup (Go)

1. No prior setup is needed at all. When you push a `go/v*` tag, `proxy.golang.org` caches the module on-demand on the first `go get`/`go install` request. Since it is a monorepo submodule, the tag must have the `go/` prefix.

---

## §3. Per-Language Details (in the §0 recommended order)

For each language: one-time setup (see §2) → version-bump location → dry-run → tag/trigger → deployment check → install coordinate.

### 1. Python

- One-time setup: §2-B (Pending Publisher, workflow=`python-release.yml`).
- Version bump: `python/pyproject.toml` `[project].version` — the tag↔version guard (§1) stops the job before the build if it disagrees with the tag.
- dry-run: `cd python && python -m build` (with the repo-local venv on Windows: `cd python && .venv/Scripts/python.exe -m build`)
- Tag: `py-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh python 0.1.0`
  ```bash
  git tag py-v0.1.0 && git push origin py-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `python-release.yml` succeeded → https://pypi.org/project/keycloak-sdk/
- Install: `pip install keycloak-sdk`

### 2. .NET

- One-time setup: §2-C (`NUGET_API_KEY`).
- Version bump: none (the tag is injected via `-p:Version`).
- dry-run: `dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release` — confirm the `.nupkg` contains the README and the licence (both are now packed).
- Tag: `dotnet-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh dotnet 0.1.0`
  ```bash
  git tag dotnet-v0.1.0 && git push origin dotnet-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `dotnet-release.yml` succeeded → https://www.nuget.org/packages/Xzawed.Keycloak.Sdk. A green run now means the push actually happened: a missing `NUGET_API_KEY` fails the job, and `--skip-duplicate` is gone, so an already-published version fails rather than reporting success (§2-C).
- Install: `dotnet add package Xzawed.Keycloak.Sdk`

### 3. Ruby

- One-time setup: §2-B (Pending Publisher, workflow=`ruby-release.yml`, environment=`release`, chicken-and-egg caution).
- Version bump: `ruby/lib/keycloak_sdk/version.rb` `VERSION` — guarded against the tag (§1).
- dry-run: `cd ruby && gem build keycloak-sdk.gemspec`
- Tag: `ruby-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh ruby 0.1.0`
  ```bash
  git tag ruby-v0.1.0 && git push origin ruby-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `ruby-release.yml` succeeded → https://rubygems.org/gems/keycloak-sdk
- Install: `gem install keycloak-sdk`

### 4. Node

- One-time setup: §2-B (Pending Publisher, workflow=`node-release.yml`).
- Version bump: `node/package.json` `version` — guarded against the tag (§1).
- dry-run: `cd node && npm run build && npm pack --dry-run` — check the printed file list, not just the exit code: it must include `LICENSE` and `README.md` alongside `dist/`.
- Tag: `node-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh node 0.1.0`
  ```bash
  git tag node-v0.1.0 && git push origin node-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `node-release.yml` (OIDC + provenance, including `npm install -g npm@latest`) succeeded → https://www.npmjs.com/package/@xzawed/keycloak-sdk
- Install: `npm install @xzawed/keycloak-sdk`
- ⚠️ The publish step derives the dist-tag from the version: a SemVer prerelease (anything containing a hyphen, e.g. `0.1.0-rc.1`) publishes under `rc`, anything else under `latest`. That matters for a release candidate — see §7.

### 5. Rust

- One-time setup: §2-C (`CARGO_REGISTRY_TOKEN`).
- Version bump: `rust/Cargo.toml` `[package].version` — guarded against the tag (§1).
- dry-run: `cd rust && cargo build --locked --all-targets && cargo test --locked && cargo clippy --all-targets -- -D warnings && cargo fmt --all --check && cargo publish --dry-run --locked`
  > `rust/Cargo.lock` is committed, so `--locked` verifies exactly the dependency graph that will be built. `cargo publish --dry-run` is the only way to see the file list that would actually be uploaded (the crate now declares an `exclude` for `tests/`) and to validate the packaging metadata — a plain `cargo build` does not check any of it.
- Tag: `rust-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh rust 0.1.0`
  ```bash
  git tag rust-v0.1.0 && git push origin rust-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `rust-release.yml` (`cargo publish`) succeeded → https://crates.io/crates/keycloak-sdk. A missing secret surfaces immediately as a hard failure.
- Install: `cargo add keycloak-sdk`

### 6. Java

- One-time setup: §2-A (secrets `MAVEN_GPG_PRIVATE_KEY`/`MAVEN_GPG_PASSPHRASE`/`CENTRAL_TOKEN_USER`/`CENTRAL_TOKEN_PW`).
- Version bump: automatic (`versions-maven-plugin` injects the tag value — `java/pom.xml` keeps `-SNAPSHOT`, no file edits needed).
- dry-run:
  ```bash
  export JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot}" PATH="${KCSDK_TOOLS:-$HOME/tools}/apache-maven-3.9.9/bin:$PATH"
  mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package
  # → confirm *-sources.jar / *-javadoc.jar are generated under each target/ of core/auth/admin/keycloak-sdk
  ```
- Tag: `vX.Y.Z` — guidance command: `./scripts/release-trigger.sh java 0.1.0`
  ```bash
  git tag v0.1.0 && git push origin v0.1.0
  ```
  > ℹ️ The tag value **determines the release version** — match the tag exactly to the desired release version.
- Deployment check: confirm GitHub Actions `release.yml` succeeded (through the staging upload) → verify in the [Central Portal](https://central.sonatype.com) Deployments, then **a human manually Publishes**. This staging step is your last chance to reject the build: once published, Maven Central is immutable (§6).
- Install: `io.github.xzawed:keycloak-sdk:0.1.0` (+ BOM)

### 7. Kotlin

- One-time setup: §2-A (secrets `SIGNING_IN_MEMORY_KEY`/`SIGNING_IN_MEMORY_KEY_PASSWORD`/`MAVEN_CENTRAL_USERNAME`/`MAVEN_CENTRAL_PASSWORD`).
- Version bump: `kotlin/build.gradle.kts` `version` (**manual** — unlike Java, the tag does not auto-inject it; commit it matching the tag value exactly). The tag↔version guard (§1) enforces this.
- dry-run:
  ```bash
  export JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot}" PATH="${KCSDK_TOOLS:-$HOME/tools}/gradle-9.6.1/bin:$PATH" GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
  gradle -p kotlin publishToMavenLocal
  # → confirm keycloak-sdk-kotlin-0.1.0.jar (+sources/javadoc) is generated in the local ~/.m2
  ```
- Tag: `kotlin-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh kotlin 0.1.0`
  ```bash
  git tag kotlin-v0.1.0 && git push origin kotlin-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `kotlin-release.yml` (vanniktech `publishToMavenCentral`, Central Portal staging) succeeded → **a human manually Publishes** in the [Central Portal](https://central.sonatype.com) Deployments (same two steps as Java). A green run now also means all four secrets were present (§2-A step 5).
- ⚠️ **Consumer floor**: the build pins `languageVersion`/`apiVersion` to `KOTLIN_2_2`, so the published jar carries `@Metadata(mv=[2,2,0])` and consumers need **Kotlin 2.2+** — not 2.4.10. Say so in the release notes; raising this floor later cuts consumers off.
- Install: `io.github.xzawed:keycloak-sdk-kotlin:0.1.0`

### 8. Go

- One-time setup: §2-E (none).
- Version bump: none (the tag is the SSOT).
- dry-run: `go -C go build ./... && go -C go vet ./... && go -C go test ./...`
- Tag: `go/vX.Y.Z` — guidance command: `./scripts/release-trigger.sh go 0.1.0`
  ```bash
  git tag go/v0.1.0 && git push origin go/v0.1.0
  ```
- Deployment check: confirm GitHub Actions `go-release.yml` succeeded. The proxy caches on the first `go get` request, so the version may not be queryable immediately.
- Install: `go get github.com/xzawed/KeyCloakSDK/go@v0.1.0`
- ⚠️ **The weakest recovery of the nine.** The tag alone makes the version fetchable — CI does not gate that — and once the proxy has cached it, it is immutable and cannot be yanked. Your only remedy is a `retract` directive in a later release (§6). Be correspondingly careful with the tag.

### 9. PHP

- One-time setup: §2-D — the mirror repository `xzawed/keycloak-sdk-php` and the `PHP_SPLIT_TOKEN` secret are **done**; **registering the mirror on Packagist remains**, and it can only be done *after* the first `php-v*` release populates the mirror (an empty repository has no `composer.json` for Packagist to read).
- Version bump: none (the tag is the SSOT; the mirror tag `vX.Y.Z` is derived from `php-vX.Y.Z`).
- dry-run: `cd php && composer install && composer audit && vendor/bin/phpstan analyse && vendor/bin/phpunit --testsuite unit`
  > This mirrors the tag path's `verify` job exactly. The integration suite that `split` now also requires (§1) needs Docker and runs in CI, not here.
- Tag: `php-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh php 0.1.0`
  ```bash
  git tag php-v0.1.0 && git push origin php-v0.1.0
  ```
- Deployment check: confirm the `split` job of GitHub Actions `php-release.yml` succeeded (it prints the pushed mirror commit) → confirm the mirror https://github.com/xzawed/keycloak-sdk-php carries the `v0.1.0` tag → confirm the new version appears on the Packagist page for `xzawed/keycloak-sdk`. The GitHub Release here is created *after* the mirror push, so its existence is evidence the push happened.
- Install: `composer require xzawed/keycloak-sdk`

---

## §4. Release Procedure Summary

0. **Decide the version** — for a language's *first* release, make it a release candidate (§7), not `0.1.0`.
1. **Version bump** (if the language is subject to manual bump — see the §1 table) — commit. The tag↔version guard will reject a mismatch, so this must land before the tag.
2. **dry-run** — locally confirm artifact generation without deploying (the relevant language in §3).
3. **`./scripts/release-readiness.sh <lang>`** — check the secret/registry/tag readiness.
4. **`./scripts/release-trigger.sh <lang> <ver>`** — prints the version-bump guidance, dry-run command, pre-checks, and exact tag command (does not execute them). ✅ It validates the version **per language**, so it accepts prereleases in each registry's own spelling (`0.1.0rc1` for Python, `0.1.0.rc1` for Ruby, `0.1.0-rc.1` for SemVer registries) and rejects the wrong one with the expected form in the error. **Do not skip it for an RC** — that is precisely when it earns its keep, because the tag↔manifest guard is literal string equality (§7).
5. **A human pushes the tag** — copy and run the printed `git tag ... && git push origin ...` as-is.
6. **Check GitHub Actions** — confirm the relevant release workflow ended green. Every secret-backed path now fails closed when its secret is unset, so green no longer hides a skipped publish (that was previously false for .NET and Kotlin — §2-C, §2-A step 5). Note the phrasing: Go has no secret at all, and the three OIDC languages authenticate by a registered publisher rather than a stored secret — for those, an unset/misregistered publisher fails at the publish call, not at a preflight. What green still does *not* tell you: for Java and Kotlin it means "uploaded to Central Portal staging", not "published" (step 7); for Go it means "tag and GitHub Release created", not "the proxy serves the module"; for PHP it means "pushed to the mirror", after which Packagist still has to pick the tag up.
7. **(Maven Central family only) Portal manual release** — for Java and Kotlin, a human must click Publish in the Central Portal Deployments for the final public release.
8. **Verify on the registry itself** — open the package page and confirm the version, the README rendering, and the file list. This is the only step that actually proves the release happened.

---

## §5. Common Cautions

- **When bumping the version**: bump the exact file/field in the "Version bump" column of the §0 table together, and match the tag (the "Tag" column of the §0 table) to that version. Auto-bump languages (go/php/dotnet/java) need no file edits.
- **Post-deployment coordinate**: see the "Install after release" column of the §0 table. SemVer is based on the SDK's own API and is decoupled from Keycloak/dependency library versions (compatibility is guided by the README matrix).
- **⚠️ What "the release workflows work" does and does not mean.** This document and `scripts/release-readiness.sh`/`scripts/release-trigger.sh` only guide the nine `.github/workflows/*-release.yml`; they do not modify them. But be precise about their status: **nothing has ever been published to a public registry from this repository, and the repository has zero tags — so no release workflow has ever executed, not once.** What *is* evidenced: their non-publishing steps (checkout, build, lint, unit tests, integration against a real Keycloak) are the same steps the per-language CI runs green on every push; the artifacts build locally via the §3 dry-runs; and the packages install and run via `harness/install/`. What is **not** evidenced: every step from the publishing credential onward — OIDC trusted-publisher exchange, GPG signing, Central Portal upload, `cargo publish`, `dotnet nuget push`, `gem push`, the subtree-split push to the PHP mirror, Go proxy warming — has never run against the real service. Treat each language's first release as a first execution, not a regression check. That is exactly why §7 recommends spending a release candidate on it.
- **⚠️ Name-collision caution**: even if `release-readiness.sh` reports `registry=published` (already published), it does not rule out the possibility that this is **a same-named package registered by someone else first** (a registry existence check only looks at whether the response is HTTP 200, not who owns it). **Before the first deployment** of each language, a human must directly confirm on the relevant registry (PyPI `keycloak-sdk`, npm `@xzawed/keycloak-sdk`, crates.io `keycloak-sdk`, RubyGems `keycloak-sdk`, NuGet `Xzawed.Keycloak.Sdk`, Packagist `xzawed/keycloak-sdk`, etc.) that the deployment name is **unclaimed or owned by you (`xzawed`)** — scoped packages (`@xzawed/keycloak-sdk`) and Maven Central where the groupId belongs to a GitHub account (`io.github.xzawed`) have low collision risk, but PyPI/crates.io/RubyGems, which use short generic names (`keycloak-sdk`), have a relatively higher chance of having been claimed by someone else.
- **Never query/record secret values**: `release-readiness.sh` uses `gh secret list` to confirm only names and existence and never prints values. This document also records no actual token/key values.

---

## §6. When a Bad Version Is Already Public

Publishing is irreversible everywhere, but "irreversible" costs a different amount in each registry. Know which situation you are in **before** you push the tag — this table is the reasoning behind the deployment order in §0.

| Registry | What you can do | What that achieves | What it does *not* do |
|---|---|---|---|
| **PyPI** (python) | **Yank** the release — project page → Manage → Releases → Options → Yank | Resolvers skip it; an exact pin (`==0.1.0`) still installs it | Does not free the version number. Deleting a release does not free it either — the filename is burned permanently |
| **npm** (node) | `npm deprecate @xzawed/keycloak-sdk@0.1.0 "reason"` — always available. `npm unpublish` **only within 72 hours** of publishing, and only if no other package depends on it | Deprecate attaches a warning to every install; unpublish removes the version | After an unpublish the same version cannot be republished for 24 hours, and the number stays burned |
| **crates.io** (rust) | `cargo yank --version 0.1.0` (reversible with `--undo`) | New resolutions skip it; existing `Cargo.lock`s can still download it | Deletion is impossible; the version number is permanently taken |
| **RubyGems** (ruby) | `gem yank keycloak-sdk -v 0.1.0` | Removes the version from the index | The version number cannot be reused |
| **NuGet** (dotnet) | **Unlist** — nuget.org → Manage package → Listing, or `dotnet nuget delete <id> <version>`, which unlists rather than deletes | Hidden from search and from floating version ranges | Restoring by exact version keeps working. Unlist is not deletion |
| **Maven Central** (java · kotlin) | **Nothing.** Released coordinates are immutable — no yank, no unlist, no delete | — | Your only remedy is publishing a corrected higher version, plus a public advisory if it is a security issue. This is why the Central Portal's manual Publish step is the real last line of defence: dropping a *staged* deployment costs nothing |
| **Go proxy** (go) | Add a `retract` directive for the bad version to `go/go.mod` and **release a new version containing it** | `go get` and `go list -m -u` then warn about / skip the retracted version | The old version stays in the proxy cache forever and remains fetchable by exact version. A retraction that is never itself released does nothing at all |
| **Packagist** (php) | Delete the `vX.Y.Z` tag in the mirror `xzawed/keycloak-sdk-php`, then trigger an Update on the Packagist page | The version disappears from Packagist's metadata | Composer caches and existing `composer.lock` files are unaffected, and anyone who already installed keeps the code |

**⚠️ Go: never move a `go/v*` tag once it is pushed — go forward only.** The withdrawal row above understates Go, because the proxy cache is not the whole story: `sum.golang.org` is an append-only **transparency log**, and once `github.com/xzawed/KeyCloakSDK/go@vX.Y.Z` is recorded there, the hash of that exact tree is public and permanent. So the obvious instinct — delete the tag, fix the commit, re-push the same tag — does not undo anything. It makes things strictly worse: every consumer who already fetched the module now gets a `checksum mismatch / SECURITY ERROR` from `go get`, which reads as "this module may have been compromised". Leaving a bad version in place and releasing a fixed one with a `retract` directive is the *better* outcome. This is the only registry of the nine where the recovery attempt is more damaging than the original mistake.

**⚠️ Get the incident-response credentials in place before the first release, not during the incident.** The credential that publishes and the credential that withdraws are usually not the same thing:

- **python · node · ruby** publish via OIDC, and this repository stores **no secret at all** for them (`release-readiness.sh` shows `secrets=na`). There is therefore nothing anywhere that can withdraw a release — a yank/deprecate needs an interactive, logged-in account session, and PyPI's yank is web-UI only. Confirm you can log in to pypi.org, npmjs.com and rubygems.org — including 2FA and recovery codes — **before** you publish.
- **rust · dotnet** can yank/unlist with an API token, but those tokens live in GitHub Actions secrets, where you cannot read them back. Keep a usable copy, or make sure you can log in to crates.io and nuget.org.
- **java · kotlin** have no withdrawal mechanism whatsoever. All of your leverage is in the Central Portal staging step, so do not skip the manual review there.
- **php** withdrawal is a `git push --delete` against the mirror repository, so `PHP_SPLIT_TOKEN` (or your own account access to `xzawed/keycloak-sdk-php`) is what you need.

---

## §7. Make the First Tag a Release Candidate

All nine registries support prerelease versions, and most resolvers exclude them from ordinary version ranges by default. Since no release workflow here has ever executed (§5), each language's first tag is a **first execution of an irreversible pipeline**. Spend a release candidate on it instead of `0.1.0`: if the OIDC claim does not match, the GPG public key was never distributed, or the PHP mirror does not exist, you find that out on `0.1.0-rc.1` and `0.1.0` is still yours to use.

| Language | Version to write in the manifest | Tag to push | Resolver behaviour |
|---|---|---|---|
| Python | `0.1.0rc1` (PEP 440 normal form) | `py-v0.1.0rc1` | `pip install keycloak-sdk` skips prereleases; `--pre` or an exact pin opts in |
| .NET | — (injected from the tag) | `dotnet-v0.1.0-rc.1` | `dotnet add package` skips prereleases unless given `--prerelease` |
| Ruby | `0.1.0.rc1` (a letter in a segment marks it prerelease) | `ruby-v0.1.0.rc1` | `gem install` skips it unless given `--prerelease` |
| Node | `0.1.0-rc.1` (SemVer) | `node-v0.1.0-rc.1` | `^0.1.0` excludes prereleases — see the dist-tag note below |
| Rust | `0.1.0-rc.1` (SemVer) | `rust-v0.1.0-rc.1` | `^0.1.0` excludes prereleases |
| Java | — (injected from the tag) | `v0.1.0-RC1` | Maven has no prerelease concept; this is simply a different, lower-sorting coordinate — and just as immutable |
| Kotlin | `0.1.0-RC1` | `kotlin-v0.1.0-RC1` | Same as Java |
| Go | — (the tag is the version) | `go/v0.1.0-rc.1` | `go get …@latest` prefers released versions and will not select a prerelease |
| PHP | — (the tag is the version) | `php-v0.1.0-rc.1` → mirror tag `v0.1.0-rc.1` | Composer's default `minimum-stability: stable` excludes it; `composer require xzawed/keycloak-sdk:^0.1@rc` opts in |

**npm's dist-tag is handled for you.** npm gives the `latest` dist-tag to whatever you publish unless `npm publish` is passed `--tag`, which would have made an RC the default install for everyone. `node-release.yml` now derives the dist-tag from the version instead: a SemVer prerelease (anything containing a hyphen — `0.1.0-rc.1`) publishes under `rc`, and a normal version publishes under `latest`. So a bare `npm install @xzawed/keycloak-sdk` keeps resolving to the last non-prerelease, and the RC is opt-in via `npm install @xzawed/keycloak-sdk@rc`. Nothing to do by hand — should you ever need to move the pointer yourself, it is `npm dist-tag add @xzawed/keycloak-sdk@<real-version> latest`.

**The GitHub Release prerelease flag is handled for you.** Only three workflows create a GitHub Release — `go-release.yml`, `dotnet-release.yml`, `php-release.yml`. The other six publish to their registries and create none. All three used to call `gh release create` without `--prerelease`, so GitHub presented `php-v0.1.0-rc.1` as the repository's **Latest release** on the first live run; every job in that pipeline was green, because this is not something a pipeline can fail on. They now derive the flag in the same `version` job that derives the version — one derivation, threaded like the version itself — and pass `--prerelease=true|false` explicitly, so a corrupted value makes `gh` exit rather than quietly defaulting to "release".

The rule is deliberately not a list of suffixes, because the nine registries spell prereleases four different ways (see the table above) and a list is silently wrong the moment a spelling shifts. Instead: build metadata (`+…`) is stripped first — `1.0.0+incompatible` is a *release* in Go — then a version that is only digits and dots (`0.1.0`, `0.10.0`, `1.2.3.4`) is a release, one containing a hyphen or a letter (`0.1.0-rc.1`, `0.1.0-RC1`, `0.1.0rc1`, `0.1.0.rc1`, `0.1.0-SNAPSHOT`) is a prerelease, and anything matching neither **fails the job** instead of guessing. Failing closed is the right trade here: marking a real `0.1.0` as a prerelease would hide it from `releases/latest`, which is worse than the bug this replaces. `scripts/test/test-release-prerelease.sh` lifts the block straight out of the three workflows, asserts they are byte-identical, and runs it against that table — verifying the shipped logic without burning a tag.

**✅ `release-trigger.sh` handles prereleases — use it, do not skip it.** It validates the version against a **per-language** pattern (`df_version_re` in `scripts/lib/deploy-facts.sh`), so it accepts `0.1.0rc1` for Python and rejects `0.1.0-rc.1` with the expected spelling in the error message. Since the tag↔manifest guard is literal string equality (next note), getting that spelling right is exactly the failure this helper prevents — it is the *most* useful for an RC, not the least. Verified by running it: `sh scripts/release-trigger.sh python 0.1.0rc1` prints an RC advisory block and the `git tag py-v0.1.0rc1` command.

> This paragraph used to say the opposite — that the helper rejected all prereleases and should be skipped for an RC. That was stale, and it pointed the operator away from the one tool that gives the correct per-registry spelling.

**⚠️ The tag↔version guard is literal string equality** (§1), so for the five manual-bump languages the manifest must carry exactly the spelling in the "Version to write" column — `0.1.0rc1` for Python, not `0.1.0-rc1`; `0.1.0.rc1` for Ruby, not `0.1.0-rc.1`.

**⚠️ An RC still burns its own coordinate.** `0.1.0-rc.1` is as unrepublishable as `0.1.0` — if the RC needs a fix, go to `-rc.2`. And on Maven Central an RC is a permanent public artifact like any other; it protects `0.1.0`, it does not make the upload reversible.
