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

This SDK is pre-1.0 and not yet published to public package registries
(releases are human-gated). Security fixes are applied to the `main` branch.
Once published, this section will list the supported release lines.

## Dependency Security

Each language SDK runs a dependency vulnerability audit in CI
(`cargo audit`, `pip-audit`, `npm audit`, `dotnet list package --vulnerable`,
OWASP dependency-check, `composer audit`, `bundler-audit`) and
[Dependabot](.github/dependabot.yml) monitors all nine package ecosystems plus
GitHub Actions for known-vulnerable dependencies.
