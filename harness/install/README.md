# Install-&-Operate Harness

Without a real release (public registry), this harness **installs each language's SDK "as if it were a published package" from a local registry and verifies that it actually operates against a real Keycloak**. Unlike the existing harness (`harness/`), which consumes the SDK via a **source path**, this harness verifies the **install path** of the actual release artifact (manifest, file list, entrypoint, metadata, dependency resolution).

- Design: [docs/superpowers/specs/2026-07-07-install-operate-harness-design.md](../../docs/superpowers/specs/2026-07-07-install-operate-harness-design.md)
- Exact per-language commands (authoritative source): [docs/superpowers/specs/2026-07-07-install-recipes-research.md](../../docs/superpowers/specs/2026-07-07-install-recipes-research.md)

## Running

```bash
cd harness/install
./install-verify.sh                                  # all 9 languages (default)
./install-verify.sh go python                        # a subset
```

Output: `report/INSTALL-MATRIX.md` (per-language step-status table) + `report/signals/<lang>.install.json` (raw signals). Both are git-ignored (generated artifacts).

**A single language's failure is isolated** — it is recorded as `error` in that language's signal and the remaining languages continue (`install-verify.sh` always exits 0; the matrix is the result carrier).

## Pipeline (4 steps per language)

```
A. Publish   publish/<lang>.sh builds the actual release artifact → publishes it to the local registry.
B. Install   consume/<lang>.Dockerfile (files only) → the runtime entrypoint consume/<lang>-run.sh, on
             install-net: installs from the registry → runs the quickstart smoke → boots the harness app.
             State is recovered via marker files (installed.ok, quickstart.ok) under the host-mounted /status.
C. Operate   re-runs the existing conformance.mjs (26 contract checks) + security/probe.mjs (9 JWT probes) against the installed-package app.
D. Report    report/install-matrix.mjs turns signals/*.install.json → INSTALL-MATRIX.md.
```

**Maximum reuse**: the app code (`harness/apps/<lang>`), conformance, security, and the Keycloak realm are reused as-is, and **only the dependency-resolution source** changes from a source path to the local registry. Pass/fail therefore means exactly "does the published package actually install and operate?"

## Per-language local registry (hybrid = ecosystem-native local)

| Language | Local source | Consumer's real command (only the source URL is local) |
|---|---|---|
| node | Verdaccio (real npm protocol) | `npm install @xzawed/keycloak-sdk@0.1.0 --registry …` |
| python | pypiserver (PEP 503 simple) | `pip install "keycloak-sdk==0.1.0"` (+`PIP_EXTRA_INDEX_URL`) |
| go | file GOPROXY (directory volume) | `GOPROXY=file:///proxy,… go get …/go@v0.1.0` |
| dotnet | BaGetter (NuGet V3) | `dotnet add package Xzawed.Keycloak.Sdk --version 0.1.0` |
| java | nginx static staged .m2 | POM: `keycloak-sdk-bom:0.1.0` (import) + `keycloak-sdk` |
| ruby | static gem repo (generate_index) | `gem install keycloak-sdk --version 0.1.0 --source …` |
| php | Satis (static type:composer) | `composer require xzawed/keycloak-sdk:^0.1` |
| rust | cargo-local-registry (source replacement) | `cargo build --offline` (Cargo.toml `keycloak-sdk="0.1.0"`) |
| kotlin | nginx static staged .m2 (mvn-repo-kotlin) | Gradle: `maven { url }` + `keycloak-sdk-kotlin:0.1.0` (transitive deps from Central) |

Host ports: node 18090 · python 18091 · go 18092 · dotnet 18093 · java 18094 · ruby 18095 · php 18096 · rust 18097 (for polling the app's healthz). go and rust mount a directory volume into the consume container instead of running a registry service.

## Reading the report (INSTALL-MATRIX.md)

| Column | Meaning |
|---|---|
| artifact | The actual release artifact built successfully |
| publish | Published to the local registry successfully |
| install | The consume container installed from the registry successfully (marker installed.ok) |
| quickstart | The quickstart smoke succeeded with the installed package (marker quickstart.ok) |
| app-boot | The harness app booted and responded to healthz |
| conformance | Contract-conformance checks passed / total (out of 26) |
| security | JWT hardening probes defended / total (out of 9) |
| notes | Failure reason (error) |

## ⚠️ Notes

- **All containers use an Alpine/musl base** — this avoids the gotcha where the Windows Docker Desktop built-in DNS proxy hands the registry's CNAME chain back to a Debian/glibc resolver as a failure. On install-net, consumers resolve the registry by **service name** (embedded DNS).
- **Local Windows**: the lightweight pure-language ones (node, go, python) are recommended for local runs. The heavier languages (java, dotnet, ruby, php, rust) have long build times, so CI is recommended first.
- **CI**: the `install-all` job in [.github/workflows/harness.yml](../../.github/workflows/harness.yml) (nightly 03:00 UTC + manual `workflow_dispatch`, `timeout-minutes: 90`) runs all 8 languages and uploads `INSTALL-MATRIX.md` + `signals/` as artifacts. It does not run on PR/push (it's heavy).
- Deploying to real registries is still human-gated ([DEPLOY.md](../../DEPLOY.md)) — this harness serves as the final verification before release.
