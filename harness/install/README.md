# Install-&-Operate Harness

Without a real release (public registry), this harness **installs each language's SDK "as if it were a published package" from a local registry and verifies that it actually operates against a real Keycloak**. Unlike the existing harness (`harness/`), which consumes the SDK via a **source path**, this harness verifies the **install path** of the actual release artifact (manifest, file list, entrypoint, metadata, dependency resolution).

- Design: [docs/superpowers/specs/2026-07-07-install-operate-harness-design.md](../../docs/superpowers/specs/2026-07-07-install-operate-harness-design.md)
- Exact per-language commands (authoritative source): [docs/superpowers/specs/2026-07-07-install-recipes-research.md](../../docs/superpowers/specs/2026-07-07-install-recipes-research.md)

## Running

```bash
cd harness/install
./install-verify.sh                                  # all 9 languages (default), version 0.1.0
./install-verify.sh go python                        # a subset
./install-verify.sh --version 0.2.0 node             # verify a specific release version
PKG_VER=0.2.0 ./install-verify.sh node               # same, via the environment
```

**The version is part of what is being verified.** `--version` (or `PKG_VER`) is threaded through every
publish and consume step, so the harness publishes *that* version to the local registry and installs
*that* version in the clean consumer. The release workflows pass the tag suffix here — without it a
green run on a `v0.2.0` tag would certify `0.1.0`. Five languages build from their manifest
(python · node · rust · ruby · kotlin) and fail loudly if the requested version does not match it;
four override the version at build time (java · dotnet · go · php) and would otherwise pass while
testing the wrong artifact.

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

`$PKG_VER` below is the version under verification (`--version`, default `0.1.0`). Every command pins it
**exactly** — a range would let the consumer resolve some other version still sitting in the local
registry, which is precisely what this gate must not allow.

| Language | Local source | Consumer's real command (only the source URL is local) |
|---|---|---|
| node | Verdaccio (real npm protocol) | `npm install @xzawed/keycloak-sdk@$PKG_VER --registry …` |
| python | pypiserver (PEP 503 simple) | `pip install "keycloak-sdk==$PKG_VER"` (+`PIP_EXTRA_INDEX_URL`) |
| go | file GOPROXY (directory volume) | `GOPROXY=file:///proxy,… go get …/go@v$PKG_VER` |
| dotnet | BaGetter (NuGet V3) | `dotnet add package Xzawed.Keycloak.Sdk --version $PKG_VER` |
| java | nginx static staged .m2 | POM: `keycloak-sdk-bom:$PKG_VER` (import) + `keycloak-sdk` |
| ruby | static gem repo (generate_index) | `gem install keycloak-sdk --version $PKG_VER --source …` |
| php | Satis (static type:composer) | `composer require xzawed/keycloak-sdk:$PKG_VER` |
| rust | cargo-local-registry (source replacement) | `cargo build --offline` (Cargo.toml `keycloak-sdk="$PKG_VER"`) |
| kotlin | nginx static staged .m2 (mvn-repo-kotlin) | Gradle: `maven { url }` + `keycloak-sdk-kotlin:$PKG_VER` (transitive deps from Central) |

Files the consume container reads rather than commands it runs — the two Java POMs,
`consume/kotlin-app/build.gradle.kts`, and `quickstart/rust/Cargo.toml` — cannot interpolate an
environment variable, so their run scripts substitute the SDK coordinate's version at container start
and **fail closed** if the substitution does not match (a changed manifest layout must not silently
fall back to the baked-in literal).

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
