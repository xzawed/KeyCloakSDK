# Development environment setup

How to get a **new machine** building this repository. Nine SDKs live here, each with its own
toolchain; nothing is shared between them except Docker (integration tests) and Node (repo scripts).

You do **not** need all nine. Install only the languages you intend to touch — every language
builds, tests and lints independently.

> This guide deliberately contains **no version numbers**. Each language already declares its own
> minimum runtime in its build file, and that declaration is the single source of truth. Copying
> those numbers here would guarantee they drift. `scripts/doctor.mjs` reads them from the build
> files and tells you what this checkout requires *today*.

---

## 1. Clone and diagnose

```bash
git clone https://github.com/xzawed/KeyCloakSDK.git
cd KeyCloakSDK

node scripts/doctor.mjs              # diagnose all nine languages
node scripts/doctor.mjs java kotlin  # …or only the ones you need
node scripts/doctor.mjs --json       # machine-readable
```

`doctor` prints one row per tool — what the build files require, what is installed, and whether
that is good enough. It exits non-zero when something is missing or too old, so you can also use
it as a setup gate in a script. `docker` is reported but never fails the run: it is only needed
for integration tests.

Run it first, fix what it reports using the table below, then run it again.

## 2. What each language needs

The **"minimum declared in"** column is where the requirement actually lives. If you want the
number, read that file (or just run `doctor`) — do not trust a number written in prose.

| Language | Install | Minimum declared in | Also needed |
|---|---|---|---|
| Java | JDK (Temurin) + Maven | `java/pom.xml` — `maven.compiler.release`, enforcer `requireMavenVersion` | `JAVA_HOME` (see §4) |
| Python | CPython | `python/pyproject.toml` — `requires-python` | a virtualenv (see §4) |
| Node | Node.js | `node/package.json` — `engines.node` | — |
| Go | Go toolchain | `go/go.mod` — `go` directive | — |
| C# / .NET | .NET SDK | `dotnet/Directory.Build.props` — `TargetFramework` | — |
| PHP | PHP (NTS) + Composer | `php/composer.json` — `require.php` | extensions + `OPENSSL_CONF` (see §4) |
| Rust | rustup (cargo + rustc) | `rust/Cargo.toml` — `rust-version` (MSRV) | MSVC Build Tools on Windows (see §4) |
| Ruby | Ruby + Bundler | `ruby/keycloak-sdk.gemspec` — `required_ruby_version` | MSYS2/DevKit on Windows (see §4) |
| Kotlin | JDK (Temurin) only | `kotlin/build.gradle.kts` — `jvmToolchain` | **no Gradle install** — use `kotlin/gradlew` |

Repo-wide: **git**, **Node** (the `scripts/*.mjs` guards and `doctor` itself run on it), and
**Docker** for integration tests and the harnesses.

## 3. System install vs. portable install

Two styles work, and the repository supports both:

- **System install** — the toolchain is on `PATH`. Nothing else to do; `doctor` finds it.
- **Portable install** — the toolchain is unpacked under a tools directory and *not* on `PATH`.
  This is how the maintainer machine is set up — the tools directory holds whichever portable
  toolchains that machine actually needed, none of them committed to the repository.

The per-language command sheets in [`.claude/rules/`](../../.claude/rules/) are written for the
portable style, but parameterised so they work either way:

```bash
export PATH="${KCSDK_TOOLS:-$HOME/tools}/go/bin:$PATH"
```

`KCSDK_TOOLS` defaults to `$HOME/tools`. Point it somewhere else, or drop the prefix entirely if
the tool is already on `PATH` — the commands after the prefix are identical in both cases.

| Variable | Default | What it selects |
|---|---|---|
| `KCSDK_TOOLS` | `$HOME/tools` | parent directory of the portable Go / PHP / Ruby / Maven installs |
| `KCSDK_JDK21` | the maintainer machine's Temurin path | the JDK that `JAVA_HOME` is set to for Java and Kotlin builds |
| `KCSDK_PY` | `python/.venv/Scripts/python.exe` | the virtualenv interpreter (see §4 for the POSIX path) |

Set whichever ones differ on your machine — for example in `~/.bashrc`:

```bash
export KCSDK_TOOLS="$HOME/dev/toolchains"
export KCSDK_JDK21="/usr/lib/jvm/temurin-21"
export KCSDK_PY="python/.venv/bin/python"
```

## 4. Per-language notes that a fresh machine trips on

These are the things that are not obvious from "install the toolchain".

**Java and Kotlin — `JAVA_HOME` decides the build JDK, not `PATH`.** Maven and Gradle both resolve
the JDK from `JAVA_HOME`. An older `java` first on `PATH` is harmless as long as `JAVA_HOME` points
at a new enough JDK — `doctor` checks `JAVA_HOME` first for exactly this reason.

**Kotlin — do not install Gradle.** `kotlin/gradlew` downloads the exact distribution the build
declares. There is no separately installed Gradle anywhere in this project — not on CI, not on the
maintainer machine; `./gradlew` is the only form, and every documented Kotlin command uses it.

**Python — create the virtualenv.** It is not committed:

```bash
cd python
python -m venv .venv
.venv/Scripts/python.exe -m pip install -e ".[dev]"   # Windows
.venv/bin/python -m pip install -e ".[dev]"           # macOS / Linux
```

The interpreter path differs by OS (`Scripts/python.exe` vs `bin/python`) — that is what
`KCSDK_PY` exists for.

**Node — install with `npm ci`,** not `npm install`, so the lockfile decides (`cd node && npm ci`).

**Go — set `GOTOOLCHAIN=local`** when using a portable install, so the toolchain in `$PATH` is the
one that builds rather than one downloaded on demand.

**PHP — extensions and `OPENSSL_CONF`.** The build needs `openssl`, `curl`, `mbstring`,
`fileinfo`, `sodium`, `zip` and `json`. On Windows the openssl extension cannot find a default
config, so RSA key generation in the JWT tests fails unless `OPENSSL_CONF` points at an
`openssl.cnf`. Xdebug is only needed for the coverage gate.

**Rust — Windows needs the MSVC toolchain.** Native dependencies (`ring`, `rsa`) compile with
VS Build Tools; run cargo from a `vcvars64.bat` environment. Linux/macOS need nothing extra.

**Ruby — Windows needs MSYS2/DevKit.** Several gems (`racc`, `prism`, `bigdecimal`) have no
Windows precompiled build and must be compiled. `ridk install 3` provides the toolchain. Linux and
macOS need nothing extra.

**Docker — required for integration tests only.** Every language's unit tests and coverage gate
run without it. Integration tests start a real Keycloak container.

## 5. Verify the setup

Build one language end to end. **Its command sheet is [`.claude/rules/<lang>.md`](../../.claude/rules/)**
— one file per language, opening with the toolchain block: the entry command, the single-test
invocation, the coverage gate and the lint command. That sheet is the source of truth; this guide
does not copy the commands, because a copy is what drifts.

⚠️ **Install the dependencies before the entry command.** For Node, PHP and Ruby the install is the
**first line of the sheet itself** (`npm ci`, `composer install`, `bundle install`) — run the sheet
from its top on a fresh clone. Python is the exception: its venv creation lives in §4 above, not in
the sheet. Rust, Go and .NET resolve on build and need nothing extra.

Repo-wide guards (no language toolchain needed, only Node):

```bash
node scripts/check-docs.mjs .    # docs-vs-build-file drift guard
sh scripts/test/test-doctor.sh   # doctor's own self-test
```

And the repository's own GitHub configuration, which is committed rather than clicked:

```bash
node scripts/repo-config.mjs check   # does GitHub's branch ruleset match .github/rulesets/*.json?
```

This needs `gh` installed and authenticated with admin rights on the repository, so it is a
maintainer command rather than part of a normal build. It exits `1` on drift and `2` when it could
not read the config at all — the two are deliberately different, so "no token" is never reported as
"config changed". See [CONTRIBUTING.md §4](../../CONTRIBUTING.md) for what the ruleset enforces.

## 6. Where the rest lives

| You want | Read |
|---|---|
| Full per-language commands, coverage gates, gotchas | [`.claude/rules/<lang>.md`](../../.claude/rules/) |
| Gates that must be green before merging, PR checklist | [CONTRIBUTING.md](../../CONTRIBUTING.md) |
| Architecture, cross-language contract, dependency choices | [CLAUDE.md](../../CLAUDE.md) |
| Using the SDKs (rather than developing them) | [getting-started.md](getting-started.md) |
| Release/publish procedure | [DEPLOY.md](../../DEPLOY.md) |
| Cross-language verification and install harnesses | [harness/README.md](../../harness/README.md) |
