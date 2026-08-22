# Keycloak SDK for Node.js

A TypeScript SDK for [Keycloak](https://www.keycloak.org/) covering both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# / .NET · PHP · Rust · Ruby · Kotlin) — idiomatic in each language, isomorphic across all of them. Monorepo: <https://github.com/xzawed/KeyCloakSDK>

> **`0.2.0` is on npm** and holds the `latest` dist-tag, so a bare install resolves it. (The `rc` tag still points at `0.1.0-rc.2` — npm assigned `latest` to this package's first version regardless of `--tag` and then refused to let that tag be removed, which is why the `rc` label lingers.)
>
> ⚠️ **Two breaking changes since `0.1.0`, both at the type level only** — the runtime behaviour is unchanged and **the normal paths (`kc.auth.validate(token)`, `kc.admin.users.search(...)`) are untouched**. (1) `JwtValidator` can no longer be built with `new` — use `JwtValidator.forJwksUri(...)`. (2) The five admin resource classes no longer expose their constructors in the emitted declarations; `AdminClient` assembles them, and they were never a consumer construction path. Both existed because the constructors were putting `jose` and `@keycloak/keycloak-admin-client` types onto this package's public surface.

## Requirements

- **Node.js 22 or newer** (`engines: { "node": ">=22" }`)
- **ESM-only** (`"type": "module"`) and **async-only** — every network method returns a `Promise` (`createAuthorizationRequest` is the one synchronous call)
- Ships `.d.ts` type declarations, so consumers get full type checking
- A running Keycloak server (26.6 verified) to connect to

## Install

```bash
npm install @xzawed/keycloak-sdk
```

A bare install resolves `0.2.0`, and so does a `^0.2.0` range. ⚠️ **`^0.1.0` does not pick it up** — under SemVer a caret below `1.0.0` is locked to the minor, so `^0.1.0` stays on the `0.1.x` line. That is the correct behaviour for a line with breaking changes in it; move the range deliberately. Pin the exact version if you would rather not follow `latest`:

```bash
npm install @xzawed/keycloak-sdk@0.2.0
```

## Quickstart

The same three-step shape as every other language in the monorepo — **get a token → verify it → call the Admin API**.

```ts
import { KeycloakClient } from '@xzawed/keycloak-sdk'

const client = KeycloakClient.create({
  serverUrl: 'https://keycloak.example.com',
  realm: 'my-realm',
  clientId: 'my-client',
  clientSecret: process.env['KEYCLOAK_CLIENT_SECRET'], // load from env / a secret manager
})

try {
  // 1. Get a token via the client-credentials grant.
  //    TokenSet masks accessToken/refreshToken when logged or serialized.
  const token = await client.auth.clientCredentialsToken()

  // 2. Verify it with the hardened validator (algorithm pinning, exact iss, aud containment).
  const validated = await client.auth.validate(token.accessToken)
  console.log(`subject=${validated.subject} aud=${validated.audience.join(',')}`)

  // 3. Call the Admin API. `admin` is created lazily on first access (client-credentials grant).
  const admin = await client.admin()
  const users = await admin.users.search(undefined, 0, 10)
  console.log(`users=${users.map((u) => u.username).join(', ')}`)
} finally {
  await client.close() // close protocol; both halves are no-ops today (global `fetch` holds no connections)
}
```

`validate()` expects the token's `aud` to contain `clientId` by default, but a stock realm does not put the client id into a client-credentials token. Either pass `expectedAudience: 'my-api'` to `create()` to check the audience your tokens actually carry, or add an audience mapper to the client in Keycloak (Client scopes → dedicated scope → Add mapper → Audience).

`KeycloakClient` implements `AsyncDisposable`, so `await using client = KeycloakClient.create(…)` cleans up on scope exit.

For the browser/authorization-code flow, start with `client.auth.createAuthorizationRequest(redirectUri)` and exchange the callback with `client.auth.exchangeCode(code, redirectUri, codeVerifier, nonce)` — the `nonce` must be passed back for id_token validation to succeed.

## Security defaults

Hardened JWT validation, not the unsafe library defaults:

- **Algorithm pinning** — signature algorithms are pinned by configuration (`RS256` by default); `alg: none` and header-supplied algorithms are rejected.
- **Strict claim checks** — exact `iss` match, `aud` containment check, mandatory `exp`, and a bounded clock skew (30s by default).
- **DoS-safe JWKS refetch** — the key set is refetched only on an unresolved key ID and never on a bad signature, and a cooldown rate-limits refetches to a minimum interval (`jwksMinRefetchSeconds`, 30s by default) — so no volume of forged tokens makes the SDK issue more than one JWKS request per interval.
- **Secret handling** — `clientSecret` and tokens are masked as `***` in `toString`, `JSON.stringify`, and `util.inspect` output; TLS verification is on by default.

Masking covers those three serialization paths, which is what most loggers reach for. It does not cover direct property access, so it is defence in depth rather than a guarantee about your logs.

## Versioning and support

This SDK is **pre-1.0**. Under SemVer a `0.x` **minor** bump may carry breaking changes, so read the release notes before upgrading. Only the newest released version of each language SDK receives security fixes — there are no LTS lines, and older `0.x` releases are not backported to. Full policy: [SECURITY.md](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md).

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md) — install and quickstart for this language
- [Compatibility](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/reference/compatibility.md) — which Keycloak server range and base libraries each published version shipped against
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)
- [Node example](https://github.com/xzawed/KeyCloakSDK/blob/main/node/examples/quickstart.ts)

## License

Apache-2.0 — see [LICENSE](https://github.com/xzawed/KeyCloakSDK/blob/main/node/LICENSE).
