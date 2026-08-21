---
paths:
  - "node/**"
  - "harness/apps/node/**"
  - "harness/install/consume/node*"
  - ".github/workflows/node-*.yml"
---

# Node rules

## Toolchain

System install. `engines` is `>=22` (do not write "20+" in the docs). Commands run from `node/`.

```bash
cd node && npm ci
cd node && npm test            # unit + coverage gate 90 lines / 85 branches. No Docker
cd node && npm run test:it     # integration. Needs Docker (KC 26.6)
cd node && npm run typecheck   # tsc --noEmit (strict)
cd node && npm run lint
cd node && npm run build       # tsc → dist/
```

- A single test: `npx vitest run test/unit/<name>.test.ts`
- Coverage omits `src/auth.ts`, `src/admin/**` and `src/index.ts` (the network boundary — the integration tests cover it). Everything else is at 100% lines / 94% branches.
- Release check: `npm run build && npm pack --dry-run`. ⚠️ Even with `files:["dist"]`, npm **always** includes `package.json`, `README` and `LICENSE`, so without `node/README.md` and `node/LICENSE` the npmjs.com landing page ships empty. Write every README link as an absolute URL (relative links break on the registry page).
- Releasing goes `node-v*` tag → npm **Trusted Publishing** (OIDC + provenance, no stored token). The tag ↔ `package.json` consistency guard and the integration E2E are both in `needs:`.
- The package `@xzawed/keycloak-sdk` is ESM-only (`"type":"module"`) and ships `.d.ts`.
- ⚠️ **The public type surface is the emitted `dist/**/*.d.ts`, not the source.** Writing `import type` does not keep a foreign type out of it — a `public` constructor parameter puts the type in the declaration and the import comes with it. That is how jose's `JWTVerifyGetKey` and `KcAdminClient` ended up in the published API. Hide a seam with `private` (tsc drops the parameters) or `@internal` (`stripInternal` drops the whole member). The guard is `scripts/check-node-public-surface.mjs`, which runs after `npm run build` in CI and **fails when `dist` is absent** so it cannot pass on zero files.
- ⚠️ **Type-check with `tsconfig.typecheck.json`, not `tsconfig.json`** — that is what `npm run typecheck` runs, and it is the only config that covers `test/`. The build config emits (`rootDir: src`, `outDir: dist`), so adding `test` to *its* `include` is not the fix: it produces 13 × `TS6059 File is not under rootDir`. The two concerns were tangled in one file; they are now separate.
  - **The blind spot was real, not hypothetical.** While tests went unchecked, vitest ran them through esbuild, which strips types without checking them, so **17 type errors passed CI**: 12 × `new JwtValidator(...)` after that constructor became `private`, and 5 × `new TokenSet(...)` missing the 4th argument `expiresAt`. Nothing was wrong at runtime — which is exactly why nothing caught it.
  - **A test that needs a seam gets an `@internal` factory, not a public one.** `JwtValidator.forKeySource(keys, opts)` exists so tests can inject a local JWKS; `stripInternal` removes it from the emitted `.d.ts`, so `forJwksUri` stays the only construction path a consumer can see. Verified after the change: `dist/jwt.d.ts` contains neither `forKeySource` nor `from 'jose'`.

## admin

- ⚠️ **To re-authenticate on expiry, wire the SDK provider in with `registerTokenProvider` — do not call `kc.auth()`.** The admin-client's built-in TokenManager only attempts a refresh_token grant on expiry and has no client_credentials re-auth fallback, so delegating to it makes every admin call a permanent 500 once the first token expires (~4.5 min). **Of all nine languages, node is the only one carrying this weakness** (the JVM ones have a re-auth fallback; go, dotnet, rust and ruby have their own caching provider; python and php re-authenticate inside the underlying library). To reproduce: lower the realm's `accessTokenLifespan`, make an admin call, wait 45 seconds, call again.
- **The admin-client pin `~26.7.0` is a product of its history.** A `decodeToken(undefined).split()` crash regression in 26.7.0 pushed it down to `~26.6.4`; then the integration tests demonstrated that the wiring above cuts that path off at the root, and it moved forward again. **Look at the wiring before reverting to the narrower pin.**
- ⚠️ **The `findOne` family returns `null` on a 404** (the declared type says `undefined`) — treat both `null` and `undefined` as absence. Checking `=== undefined` alone lets a lookup-after-delete leak through as a bug.

## auth · JWT

- ⚠️ **Two timeouts, two different units** — `Configuration.timeout` is in **seconds**, the admin-client's `ConnectionConfig.timeout` is in **milliseconds**. A signal cannot be injected through `requestOptions`.
- ⚠️ **Always pass `nonce` to the PKCE `exchangeCode`.** Keycloak returns the nonce inside the id_token and openid-client v6 verifies it automatically, so with no expected nonce the whole exchange is rejected as "unexpected nonce".
- TLS: `allowInsecureRequests` applies only when `serverUrl` is `http://` (https stays enforced).
- ⚠️ **A JWKS rate-limit regression cannot be caught without a control case.** If `cooldownDuration` is renamed or removed, JS silently ignores it — and **jose falls back to its own 30-second default**, so the normal case, where our setting is also 30 seconds, keeps passing. Only the `cooldown=0` control fails. Do not delete the second case in `test/unit/jwt-jwks.test.ts`.

## Dependency ranges

⚠️ **Do not narrow `^6` to `~` for `jose` or `openid-client`.** The reason is not "duplication in the tree" — that rationale was once written down here wrongly: npm reuses the hoisted root version whenever it satisfies the dependent's range, and does not nest a copy merely because a newer version exists. **The real reason is that this is a published library**, so our range is resolved in the **consumer's** tree, not ours. Narrowing it raises the odds of clashing with the jose the consumer already has and forcing duplication on their side, and they cannot do anything about it until we ship a new version (the same logic as the ban on exact pins in Rust). Reproducibility comes from `package-lock.json`, not from the declared range.
