# Security Policy

## Reporting a Vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report suspected vulnerabilities privately through GitHub's
[Private Vulnerability Reporting](https://github.com/xzawed/KeyCloakSDK/security/advisories/new)
(the **Security → Advisories → Report a vulnerability** button on this repository).
This keeps the report confidential until a fix is available and lets us
coordinate a disclosure with you.

When reporting, please include:

- The affected language SDK(s) (Java, Python, Node, Go, C#/.NET, PHP, Rust, Ruby, Kotlin) and version/commit.
- A description of the issue and its impact.
- Reproduction steps or a proof of concept, if possible.

We aim to acknowledge reports within a few business days and will keep you
informed of progress toward a fix.

## Scope

This project is a multi-language SDK for Keycloak covering authentication
(OIDC/OAuth2) and the Admin REST API. Security-relevant areas include, but are
not limited to:

- **JWT validation** — algorithm pinning, `iss`/`aud`/`exp`/`nbf` enforcement,
  DoS-safe JWKS refetch (all nine SDKs implement hardened, self-verified validation).
- **OIDC flows** — PKCE (S256), nonce/`id_token` replay protection, state handling.
- **Secret handling** — client-secret masking in logs/serialization.
- **Transport** — TLS verification on by default, timeouts, SSRF hardening (no
  automatic redirect following where applicable).

Issues in Keycloak itself (the server) should be reported to the
[Keycloak project](https://www.keycloak.org/), not here.

## Supported Versions

This project is **pre-1.0**. Six SDKs have shipped a first **release candidate** to
a public registry — PHP (`0.1.0-rc.1`, Packagist), Python (`0.1.0rc1`, PyPI),
.NET (`0.1.0-rc.1`, NuGet), Rust (`0.1.0-rc.1`, crates.io), Ruby
(`0.1.0.rc1`, RubyGems) and Node (`0.1.0-rc.2`, npm). The other three
(Java, Go, Kotlin) are at `0.1.0` (Java: `0.1.0-SNAPSHOT`) and are not
on a registry. **No language has a stable release yet.** Each release is
human-gated, see [DEPLOY.md](DEPLOY.md).

What pre-1.0 means here:

- **No cross-version compatibility guarantee.** Under SemVer a `0.x` minor bump
  may contain breaking changes. Read the release notes before upgrading.
- **Only the newest released version of each language SDK receives security
  fixes.** There are no long-term-support lines and older `0.x` releases are not
  backported to. Until the first publication, fixes land on `main`.
- A security fix ships as a new release of the affected SDK plus a
  [GitHub Security Advisory](https://github.com/xzawed/KeyCloakSDK/security/advisories)
  on this repository.

**Each of the nine languages versions independently.** They share a design
contract, not a version number, and they release under separate tag prefixes
(`v*` Java · `py-v*` · `node-v*` · `go/v*` · `dotnet-v*` · `php-v*` · `rust-v*` ·
`ruby-v*` · `kotlin-v*`). A security fix is released for a language **as soon as
it is ready for that language and does not wait for the other eight.**
Cross-language isomorphism is a design goal; it is never a reason to hold a
vulnerability fix. Expect the nine version numbers to diverge after any such fix.

**Keycloak server versions.** Integration tests run against **Keycloak 26.6**
(the exact container tag per language is recorded in the compatibility matrix in
[docs/guides/getting-started.md](docs/guides/getting-started.md#compatibility) —
`26.6.4` for Java and Python, `26.6` for the others). That is the only server
range verified. Other server versions may work but are untested — do not read
this as a claim about 25.x or 27.x.

## Dependency Security

Every language SDK has a dependency-vulnerability gate in CI, and it is a **hard
gate**: a known-vulnerable dependency fails the build rather than being reported
and ignored.

| Language | Tool | Job / step |
|---|---|---|
| Java | OSV.dev batch query over the resolved runtime tree (`mvn dependency:list -DincludeScope=runtime`) | `dependency-audit` in [`ci.yml`](.github/workflows/ci.yml) |
| Kotlin | OSV.dev batch query over the resolved `runtimeClasspath` | `dependency-audit` in [`kotlin-ci.yml`](.github/workflows/kotlin-ci.yml) |
| Go | `govulncheck` (vuln.go.dev — reachable-symbol analysis, covers the standard library too) | `vulncheck` in [`go-ci.yml`](.github/workflows/go-ci.yml) |
| Python | `pip-audit` over `pip freeze --exclude-editable` | `test` job in [`python-ci.yml`](.github/workflows/python-ci.yml) |
| Node | `npm audit --audit-level=high --omit=dev` | `build` job in [`node-ci.yml`](.github/workflows/node-ci.yml) |
| C#/.NET | `dotnet list package --vulnerable --include-transitive` on the shipped SDK project | `build-test` job in [`dotnet-ci.yml`](.github/workflows/dotnet-ci.yml) |
| PHP | `composer audit` | `build-test` job in [`php-ci.yml`](.github/workflows/php-ci.yml) |
| Rust | `cargo audit` | `audit` job in [`rust-ci.yml`](.github/workflows/rust-ci.yml) |
| Ruby | `bundler-audit check --update` | `build-test` job in [`ruby-ci.yml`](.github/workflows/ruby-ci.yml) |

Java and Kotlin query [OSV.dev](https://osv.dev) rather than running OWASP
dependency-check: dependency-check needs an NVD API key to fetch CVE data at a
usable rate, and this repository holds no Actions secrets, so such a job would
fail for environmental reasons on every run and become noise instead of signal.
Both OSV jobs are **fail-closed** — an empty coordinate list, or a response whose
length does not match the query, fails the job instead of reporting "no
vulnerabilities found".

Two documented scope exceptions:

- Rust ignores `RUSTSEC-2023-0071`. It concerns the `rsa` crate, which is a
  dev-dependency used only to generate test keys; the shipped SDK only verifies
  signatures with public keys, so there is no reachable path.
- .NET audits the shipped SDK project only, so test-only dependencies (for
  example WireMock's transitive tree) are deliberately out of scope.

[Dependabot](.github/dependabot.yml) additionally raises weekly update PRs for
all nine package ecosystems plus GitHub Actions.

**Workflow supply chain.** Every third-party GitHub Action used by this
repository is pinned to a full 40-character commit SHA (with the human-readable
ref in a trailing comment), so a moved or re-pointed tag cannot change what runs
in CI or in a release.

## Compromised or bad release

Publishing is irreversible per `(coordinate, version)` on every registry this
project targets — **no registry lets you re-publish the same version with
different bytes.** If a published release turns out to be compromised, to leak a
secret, or to be dangerously broken, the response is always:

1. publish a **fixed version** of that language SDK,
2. file a **GitHub Security Advisory** on this repository, and
3. apply the registry's own withdrawal mechanism, where one exists.

What each registry actually allows:

| Registry | Withdrawal mechanism |
|---|---|
| PyPI (`keycloak-sdk`) | **yank** — the version stops being selected by resolvers; an exact pin can still install it |
| npm (`@xzawed/keycloak-sdk`) | **deprecate** — `unpublish` is possible only within 72 hours of publish and only if nothing depends on it; after that, deprecate is the only option |
| crates.io (`keycloak-sdk`) | `cargo yank` — existing `Cargo.lock` files keep resolving, new resolutions skip it; nothing is deleted |
| RubyGems (`keycloak-sdk`) | `gem yank` — same semantics; the version cannot be re-pushed afterwards |
| NuGet (`Xzawed.Keycloak.Sdk`) | **unlist** — hidden from search and listings, still restorable by exact version |
| Maven Central (`io.github.xzawed:keycloak-sdk`, `…-kotlin`) | **none — fully immutable.** Nothing can be withdrawn. A new version plus an advisory is the only response |
| Go module proxy (`github.com/xzawed/KeyCloakSDK/go`) | **none once cached.** Publish a later version carrying a `retract` directive for the bad one — deleting the git tag does not remove it from the proxy |
| Packagist (`xzawed/keycloak-sdk`) | Packagist tracks VCS rather than storing artifacts: delete the `vX.Y.Z` tag on the source repository (the split mirror `xzawed/keycloak-sdk-php`) and resync the package |

⚠️ **Have the registry account credentials ready before the first release.**
Yank / deprecate / unlist is generally an interactive, account-authenticated
action (a web UI or a logged-in CLI session), not something the CI publishing
credential can perform — and Python, Node and Ruby publish over OIDC, so there is
no long-lived token to fall back on at all. The account logins and their 2FA
recovery codes must be in place **before** the first publication, not improvised
during an incident.

Step-by-step publishing commands and per-registry setup live in
[DEPLOY.md](DEPLOY.md); this section states the policy only.
