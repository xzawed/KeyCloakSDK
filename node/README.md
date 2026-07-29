# Keycloak SDK for Node.js

A TypeScript SDK for [Keycloak](https://www.keycloak.org/) covering both **Authentication (OIDC / OAuth2)** and the **Admin REST API** behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# / .NET · PHP · Rust · Ruby · Kotlin) — idiomatic in each language, isomorphic across all of them. Monorepo: <https://github.com/xzawed/KeyCloakSDK>

> **Pre-release** — not yet published to npm.

## Requirements

- **Node.js 22 or newer** (`engines: { "node": ">=22" }`)
- **ESM-only** (`"type": "module"`) and **async-only** — every network method returns a `Promise` (`createAuthorizationRequest` is the one synchronous call)
- Ships `.d.ts` type declarations, so consumers get full type checking
- A running Keycloak server (26.6 verified) to connect to

## Install

```bash
npm install @xzawed/keycloak-sdk
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
  await client.close() // cleans up admin + auth resources
}
```

`KeycloakClient` implements `AsyncDisposable`, so `await using client = KeycloakClient.create(…)` cleans up on scope exit.

For the browser/authorization-code flow, start with `client.auth.createAuthorizationRequest(redirectUri)` and exchange the callback with `client.auth.exchangeCode(code, redirectUri, codeVerifier, nonce)` — the `nonce` must be passed back for id_token validation to succeed.

## Secure by default

Hardened JWT validation, not the unsafe library defaults:

- **Algorithm pinning** — signature algorithms are pinned by configuration (`RS256` by default); `alg: none` and header-supplied algorithms are rejected.
- **Strict claim checks** — exact `iss` match, `aud` containment check, mandatory `exp`, and a bounded clock skew (30s by default).
- **DoS-safe JWKS refetch** — the key set is refetched only on an unresolved key ID, and rate-limited by a cooldown so forged tokens cannot amplify traffic to the IdP.
- **Safe handling of secrets** — `clientSecret` and tokens are fully masked (`***`) in `toString`, `JSON.stringify`, and `util.inspect` output; TLS verification is on by default.

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md) — install, quickstart, and the compatibility matrix for all nine languages
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)
- [Node example](https://github.com/xzawed/KeyCloakSDK/blob/main/node/examples/quickstart.ts)

## License

Apache-2.0 — see [LICENSE](https://github.com/xzawed/KeyCloakSDK/blob/main/node/LICENSE).
