# Deployment Guide (DEPLOY)

All nine language SDKs have a **tag-driven release CI** ready to go. Actual deployment is a human-gated approval step that is triggered **only when a human pushes a tag**, and the prerequisites below (accounts, keys, tokens) can only be performed by the repository owner.

> ⚠️ Deployment is irreversible (you cannot re-publish the same coordinate/version). Verify your artifacts first with a dry-run (at the end of each section).
>
> ✅ **Final verification before real deployment**: the install-&-operate verification harness in [`harness/install/`](harness/install/README.md) installs each SDK **like a published package from a local registry** and verifies it works (quickstart + conformance + security) against real Keycloak — a pre-check of the install path, which is isomorphic to real deployment. `cd harness/install && ./install-verify.sh <lang>` (9/9 languages GREEN in local measurements). Before pushing a real deployment tag, it is recommended to pass the relevant language here.
>
> 🛠️ **Helper scripts**: the tables and commands in this document come from `scripts/lib/deploy-facts.sh` (single source of truth). Rather than scanning the tables yourself, use the two helpers below to check status and obtain the commands.
> - `./scripts/release-readiness.sh [lang ...]` — reports each language's secret/registry/tag readiness read-only (no values exposed; with no arguments, all nine).
> - `./scripts/release-trigger.sh <lang> <version>` — **only prints** the version-bump guidance + dry-run command + exact tag push command (human-gate — it never runs `git tag`/`push` itself).

---

## §0. Overview + Readiness Matrix

| Language | Registry | Auth | Tag | Version bump | Secrets (count) | Install after release |
|---|---|---|---|---|---|---|
| **Go** | Go module proxy (proxy.golang.org) | none | `go/v*` | none (tag = SSOT) | 0 | `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z` |
| **PHP** | Packagist | webhook | `php-v*` | none (tag = SSOT) | 0 (webhook) | `composer require xzawed/keycloak-sdk` |
| **Rust** | crates.io | api-token | `rust-v*` | `rust/Cargo.toml` `[package].version` | 1 (`CARGO_REGISTRY_TOKEN`) | `cargo add keycloak-sdk` |
| **.NET** | NuGet | api-token | `dotnet-v*` | none (tag injected via `-p:Version`) | 1 (`NUGET_API_KEY` · silently skipped if unset) | `dotnet add package Xzawed.Keycloak.Sdk` |
| **Python** | PyPI | OIDC | `py-v*` | `python/pyproject.toml` `[project].version` | 0 (OIDC) | `pip install keycloak-sdk` |
| **Node** | npm | OIDC | `node-v*` | `node/package.json` `version` | 0 (OIDC + provenance) | `npm install @xzawed/keycloak-sdk` |
| **Ruby** | RubyGems | OIDC | `ruby-v*` | `ruby/lib/keycloak_sdk/version.rb` `VERSION` | 0 (OIDC + `release` environment) | `gem install keycloak-sdk` |
| **Java** | Maven Central | maven-gpg | `v*` | automatic (versions-maven-plugin, tag value injected) | 4 (GPG 2 + Portal token 2) | `io.github.xzawed:keycloak-sdk` |
| **Kotlin** | Maven Central | maven-gpg | `kotlin-v*` | `kotlin/build.gradle.kts` `version` (manual) | 4 (vanniktech names) | `io.github.xzawed:keycloak-sdk-kotlin` |

**Recommended deployment order (easy auth → hard auth)**:

```
go → php → rust → dotnet → python → node → ruby → java → kotlin
```

**Check the current status**: `./scripts/release-readiness.sh` (with no arguments, it reports all nine languages at once).

---

## §1. Common Principles

- **Tag-driven**: all nine release workflows are triggered only by pushing a tag in a specific format (the "Tag" column of the §0 table).
- **`needs: verify` gate**: most release workflows run a separate `verify` job that confirms lint/test are green on the commit the tag points to before running the publish job — so before pushing a tag, the language's usual verification (unit tests, lint) must already pass. Note, however, that this gate is only effective for the **direct publish step** of the token/OIDC/Maven languages. For PHP (webhook) and Go (proxy), the registry reacts directly to the tag push, so the verify job only gates GitHub Release creation / proxy warming — for these two languages, be sure to pass the dry-run before pushing the tag. **Java has no separate `verify` job at all** — a single `release` job runs `mvn -Prelease deploy` directly, and since it does not specify `-DskipTests`, the Maven lifecycle runs the test + integration-test phases inline before deploy (if tests fail, it never reaches the deploy phase, so deployment fails too) — there is no job separation, but the same operational guarantee holds: "nothing is deployed unless tests are green."
- **human-gate**: the actual deployment trigger (tag push) must always be performed **by a human directly**. `release-trigger.sh` only prints the commands and does not run `git tag`/`git push` itself.
- **Irreversible**: no registry allows re-publishing the same version — if you push a wrong tag, that version number is effectively burned.
- **Dry-run required**: before pushing a tag, always confirm with a local dry-run (building only the artifacts, without deploying) that the artifacts are generated correctly (per-language in the §0 table; also included in the `release-trigger.sh` output).

**Version-bump rules**:

| Type | Languages | Description |
|---|---|---|
| Automatic (4) | go · php · dotnet · java | The tag itself is the version SSOT — the workflow injects the tag value into the build (no file edits needed). Java is the sole exception: `versions-maven-plugin` replaces the POM's `-SNAPSHOT` with the tag value before deploying (the main POM keeps `-SNAPSHOT`). |
| Manual (5) | rust · python · node · ruby · kotlin | **Before** pushing the tag, a human must bump the source's version field directly and commit (the exact location is in the "Version bump" column of the §0 table). |

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

5. **⚠️ Behavior when unset differs per language (be sure to understand this to prevent accidents)**: for Java, if any one of the four secrets is missing, `mvn -Prelease deploy` **hard-fails** (the workflow itself ends in failure, so it is hard to miss). Kotlin, on the other hand, is isomorphic to §2-C's .NET: if any one of the four secrets is missing, the publish job leaves a `::warning::` log and **silently skips (exit 0)** — Actions ends green but nothing may have been uploaded to the Central Portal. After pushing a `kotlin-v*` tag, do not rest easy on a green Actions run alone; always check the Central Portal Deployments directly.
6. **Two-step manual release**: the workflow only auto-uploads **as far as Central Portal staging**. The actual public release (Publish) is completed only when **a human manually Publishes** from the Deployments screen in the [Central Portal](https://central.sonatype.com) (when autoPublish is not configured).

### B. OIDC / Trusted Publisher (Python · Node · Ruby)

1. **Pre-register a Pending Publisher (one-time, no secret needed)**: you must register this in each registry's Publishing settings screen **before deployment** (since the package does not exist yet, there is no per-project registration screen, so use the account-level "pending publisher" registration). The registration values are commonly **owner=`xzawed`** · **repo=`KeyCloakSDK`**, and the workflow filename differs per language:
   - Python: `python-release.yml`
   - Node: `node-release.yml`
   - Ruby: `ruby-release.yml` · **environment is `release`** (the other two languages leave it blank)
2. **Ruby chicken-and-egg caution**: RubyGems' Trusted Publisher can only be registered in the UI **once the gem already exists** — that is, the first time you must either publish manually with an API key, or go through rubygems.org's pre-registration procedure for new projects, after which you can switch to tag-based OIDC deployment.
3. Since this is OIDC, no stored secrets are needed (the workflow exchanges directly with the registry using a GitHub Actions OIDC token).

### C. API Token (.NET · Rust)

1. Issue an API token from the registry (NuGet: nuget.org → API Keys, crates.io: Account Settings → API Tokens).
2. Register it in GitHub Secrets:
   - .NET: `NUGET_API_KEY`
   - Rust: `CARGO_REGISTRY_TOKEN`
3. **Behavior when unset differs** — be sure to understand this to prevent accidents:
   - .NET: if the secret is missing, the push step is **silently skipped** (the workflow itself succeeds and a GitHub Release is even created, so it is easy to miss whether it actually went up to NuGet — always check the Actions log).
   - Rust: if the secret is missing, `cargo publish` **hard-fails** (the workflow itself ends in failure).

### D. Webhook (PHP)

1. **Register the Packagist repository once**: log in to https://packagist.org and register the `xzawed/keycloak-sdk` GitHub repository via Submit.
2. The release workflow itself publishes nowhere — Packagist auto-detects new tags via a GitHub webhook and publishes them. **Before the repository is registered, pushing a tag does nothing on Packagist.**

### E. No Setup (Go)

1. No prior setup is needed at all. When you push a `go/v*` tag, `proxy.golang.org` caches the module on-demand on the first `go get`/`go install` request. Since it is a monorepo submodule, the tag must have the `go/` prefix.

---

## §3. Per-Language Details (recommended order)

For each language: one-time setup (see §2) → version-bump location → dry-run → tag/trigger → deployment check → install coordinate.

### 1. Go

- One-time setup: §2-E (none).
- Version bump: none (the tag is the SSOT).
- dry-run: `go -C go build ./... && go -C go vet ./... && go -C go test ./...`
- Tag: `go/vX.Y.Z` — guidance command: `./scripts/release-trigger.sh go 0.1.0`
  ```bash
  git tag go/v0.1.0 && git push origin go/v0.1.0
  ```
- Deployment check: confirm GitHub Actions `go-release.yml` succeeded. The proxy cache happens on the first `go get` request, so it may not be queryable immediately.
- Install: `go get github.com/xzawed/KeyCloakSDK/go@v0.1.0`

### 2. PHP

- One-time setup: §2-D (Packagist repository registration).
- Version bump: none (the tag is the SSOT).
- dry-run: `cd php && composer install && composer audit && vendor/bin/phpstan analyse && vendor/bin/phpunit --testsuite unit`
- Tag: `php-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh php 0.1.0`
  ```bash
  git tag php-v0.1.0 && git push origin php-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `php-release.yml` (verify + GitHub Release creation) succeeded → check that the new version is reflected on the Packagist page (`xzawed/keycloak-sdk`).
- Install: `composer require xzawed/keycloak-sdk`

### 3. Rust

- One-time setup: §2-C (`CARGO_REGISTRY_TOKEN`).
- Version bump: `rust/Cargo.toml` `[package].version`.
- dry-run: `cd rust && cargo build --all-targets && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --all --check` (optional: pre-validate the crates.io upload with `cargo publish --dry-run`)
- Tag: `rust-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh rust 0.1.0`
  ```bash
  git tag rust-v0.1.0 && git push origin rust-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `rust-release.yml` (`cargo publish`) succeeded. If the secret is unset, it surfaces immediately as a **hard failure**.
- Install: `cargo add keycloak-sdk`

### 4. .NET

- One-time setup: §2-C (`NUGET_API_KEY`).
- Version bump: none (the tag is injected via `-p:Version`).
- dry-run: `dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release`
- Tag: `dotnet-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh dotnet 0.1.0`
  ```bash
  git tag dotnet-v0.1.0 && git push origin dotnet-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `dotnet-release.yml` succeeded, **then be sure to check the NuGet page directly** (if the secret is unset, the workflow succeeds but the push is silently skipped — see §2-C).
- Install: `dotnet add package Xzawed.Keycloak.Sdk`

### 5. Python

- One-time setup: §2-B (Pending Publisher, workflow=`python-release.yml`).
- Version bump: `python/pyproject.toml` `[project].version`.
- dry-run: `cd python && python -m build` (when using the local venv, `/d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m build`)
- Tag: `py-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh python 0.1.0`
  ```bash
  git tag py-v0.1.0 && git push origin py-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `python-release.yml` succeeded → https://pypi.org/project/keycloak-sdk/
- Install: `pip install keycloak-sdk`

### 6. Node

- One-time setup: §2-B (Pending Publisher, workflow=`node-release.yml`).
- Version bump: `node/package.json` `version`.
- dry-run: `cd node && npm run build && npm pack --dry-run`
- Tag: `node-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh node 0.1.0`
  ```bash
  git tag node-v0.1.0 && git push origin node-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `node-release.yml` (OIDC + provenance, including `npm install -g npm@latest`) succeeded → https://www.npmjs.com/package/@xzawed/keycloak-sdk
- Install: `npm install @xzawed/keycloak-sdk`

### 7. Ruby

- One-time setup: §2-B (Pending Publisher, workflow=`ruby-release.yml`, environment=`release`, chicken-and-egg caution).
- Version bump: `ruby/lib/keycloak_sdk/version.rb` `VERSION`.
- dry-run: `cd ruby && gem build keycloak-sdk.gemspec`
- Tag: `ruby-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh ruby 0.1.0`
  ```bash
  git tag ruby-v0.1.0 && git push origin ruby-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `ruby-release.yml` succeeded → https://rubygems.org/gems/keycloak-sdk
- Install: `gem install keycloak-sdk`

### 8. Java

- One-time setup: §2-A (secrets `MAVEN_GPG_PRIVATE_KEY`/`MAVEN_GPG_PASSPHRASE`/`CENTRAL_TOKEN_USER`/`CENTRAL_TOKEN_PW`).
- Version bump: automatic (`versions-maven-plugin` injects the tag value — `java/pom.xml` keeps `-SNAPSHOT`, no file edits needed).
- dry-run:
  ```bash
  JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/apache-maven-3.9.9/bin:$PATH" \
    mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package
  # → confirm *-sources.jar / *-javadoc.jar are generated under each target/ of core/auth/admin/keycloak-sdk
  ```
- Tag: `vX.Y.Z` — guidance command: `./scripts/release-trigger.sh java 0.1.0`
  ```bash
  git tag v0.1.0 && git push origin v0.1.0
  ```
  > ℹ️ The tag value **determines the release version** — match the tag exactly to the desired release version.
- Deployment check: confirm GitHub Actions `release.yml` succeeded (through the staging upload) → verify in the [Central Portal](https://central.sonatype.com) Deployments, then **a human manually Publishes**.
- Install: `io.github.xzawed:keycloak-sdk:0.1.0` (+ BOM)

### 9. Kotlin

- One-time setup: §2-A (secrets `SIGNING_IN_MEMORY_KEY`/`SIGNING_IN_MEMORY_KEY_PASSWORD`/`MAVEN_CENTRAL_USERNAME`/`MAVEN_CENTRAL_PASSWORD`).
- Version bump: `kotlin/build.gradle.kts` `version` (**manual** — unlike Java, the tag does not auto-inject it. Commit it matching the tag value exactly).
- dry-run:
  ```bash
  export JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/gradle-9.6.1/bin:$PATH" GRADLE_USER_HOME="/c/Users/dirtc/.gradle"
  gradle -p kotlin publishToMavenLocal
  # → confirm keycloak-sdk-kotlin-0.1.0.jar (+sources/javadoc) is generated in the local ~/.m2
  ```
- Tag: `kotlin-vX.Y.Z` — guidance command: `./scripts/release-trigger.sh kotlin 0.1.0`
  ```bash
  git tag kotlin-v0.1.0 && git push origin kotlin-v0.1.0
  ```
- Deployment check: confirm GitHub Actions `kotlin-release.yml` (vanniktech `publishToMavenCentral`, Central Portal staging) succeeded → **a human manually Publishes** in the [Central Portal](https://central.sonatype.com) Deployments (same two steps as Java).
- Install: `io.github.xzawed:keycloak-sdk-kotlin:0.1.0`

---

## §4. Release Procedure Summary

1. **Version bump** (if the language is subject to manual bump — see the §1 table) — commit.
2. **dry-run** — locally confirm artifact generation without deploying (the relevant language in §3).
3. **`./scripts/release-readiness.sh <lang>`** — check the secret/registry/tag readiness.
4. **`./scripts/release-trigger.sh <lang> <ver>`** — prints the version-bump guidance, dry-run command, pre-checks, and exact tag command (does not execute them).
5. **A human pushes the tag** — copy and run the printed `git tag ... && git push origin ...` as-is.
6. **Check GitHub Actions** — confirm the relevant release workflow ended green (watch out for silent skips like §2-C's .NET **and §2-A's Kotlin** — Java is a hard failure).
7. **(Maven Central family only) Portal manual release** — for Java and Kotlin, a human must click Publish in the Central Portal Deployments for the final public release.

---

## §5. Common Cautions

- **When bumping the version**: bump the exact file/field in the "Version bump" column of the §0 table together, and match the tag (the "Tag" column of the §0 table) to that version. Auto-bump languages (go/php/dotnet/java) need no file edits.
- **Post-deployment coordinate**: see the "Install after release" column of the §0 table. SemVer is based on the SDK's own API and is decoupled from Keycloak/dependency library versions (compatibility is guided by the README matrix).
- **Release workflows are not the subject of this document**: the nine `.github/workflows/*-release.yml` are already verified, and this document and `scripts/release-readiness.sh`/`scripts/release-trigger.sh` only guide those workflows — they do not modify them.
- **⚠️ Name-collision caution**: even if `release-readiness.sh` reports `registry=published` (already published), it does not rule out the possibility that this is **a same-named package registered by someone else first** (a registry existence check only looks at whether the response is HTTP 200, not who owns it). **Before the first deployment** of each language, a human must directly confirm on the relevant registry (PyPI `keycloak-sdk`, npm `@xzawed/keycloak-sdk`, crates.io `keycloak-sdk`, RubyGems `keycloak-sdk`, NuGet `Xzawed.Keycloak.Sdk`, Packagist `xzawed/keycloak-sdk`, etc.) that the deployment name is **unclaimed or owned by you (`xzawed`)** — scoped packages (`@xzawed/keycloak-sdk`) and Maven Central where the groupId belongs to a GitHub account (`io.github.xzawed`) have low collision risk, but PyPI/crates.io/RubyGems, which use short generic names (`keycloak-sdk`), have a relatively higher chance of having been claimed by someone else.
- **Never query/record secret values**: `release-readiness.sh` uses `gh secret list` to confirm only names and existence and never prints values. This document also records no actual token/key values.
