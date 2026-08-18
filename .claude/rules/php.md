---
paths:
  - "php/**"
  - "harness/apps/php/**"
  - "harness/install/consume/php*"
  - ".github/workflows/php-*.yml"
---

# PHP rules

## Toolchain

Portable PHP 8.3 + Composer (not committed). **The directory name carries a version suffix** (`php-8.3`).

```bash
export KCSDK_PHP="${KCSDK_PHP:-${KCSDK_TOOLS:-$HOME/tools}/php-8.3}"
export PATH="$KCSDK_PHP:$PATH" OPENSSL_CONF="${KCSDK_OPENSSL_CNF:-$KCSDK_PHP/extras/ssl/openssl.cnf}"
cd php && composer install
cd php && vendor/bin/phpunit --testsuite unit          # no Docker
cd php && vendor/bin/phpunit --testsuite integration   # needs Docker (docker CLI shell-out, KC 26.6)
cd php && vendor/bin/phpstan analyse                   # level max + strict-rules
cd php && vendor/bin/php-cs-fixer fix --dry-run --allow-risky=yes
```

- A single test: `vendor/bin/phpunit --filter <TestName> tests/Unit/<Path>Test.php`
- ⚠️ **Do not write the exact patch version here** — the sources of truth are `php -v` and `node scripts/doctor.mjs php`.
- ⚠️ `OPENSSL_CONF` is required for local RSA key generation (`JwtValidatorTest`) — without it, key generation fails.
- ⚠️ **This portable install has no coverage driver** (`php -m | grep -ciE 'xdebug|pcov'` → 0). The coverage gate (logic lines ≥90%, measured 100.00%) is actually enforced on CI; to measure it locally, install Xdebug or PCOV first.
- ⚠️ **The integration tests shell out to the docker CLI rather than using Testcontainers** (Windows-native PHP has no `unix://` support). The integration testsuite in `phpunit.xml` has to state `suffix="IT.php"` — leave it out and the default pattern `*Test.php` makes the ITs **skip silently**.

## Publishing (the mirror-repository path)

⚠️ **Packagist publishing goes through a mirror repository rather than a webhook — a webhook cannot work here at all.** Composer's VCS driver reads only the composer.json at the **root** of a repository and offers no way to nominate a subdirectory as the package root, and this monorepo has no composer.json at its root. So the split job in `php-release.yml` pushes the `php/` subtree to the read-only mirror `xzawed/keycloak-sdk-php`, and **what Packagist sees is that mirror** (the package name still comes from the `php/composer.json` that travels with it, so it stays `xzawed/keycloak-sdk`).

- Mirror tags have to be **unprefixed `vX.Y.Z`** (Composer cannot parse `php-vX.Y.Z`). The mirror's `main` is force-pushed on every release, but **tags are never forced** — a duplicate has to fail the push so that a human notices the burned version.
- ⚠️ **An unset `PHP_SPLIT_TOKEN` is fail-closed** (neither the mirror push nor the GitHub Release happens). The value is a fine-grained PAT with Contents write on the mirror.
- ⚠️ **Even with the secret set, `release-readiness.sh` does not report php green** — the mirror and Packagist states cannot be checked through an API, so it downgrades them to `ℹ️ 수동 확인` (the literal string the script prints, "manual check"). The procedure is in [DEPLOY.md §2-D](../../DEPLOY.md).

## Library gotchas

- ⚠️ **fschmtt's `Users::create()` returns void** — look the created id up afterwards with `findIdByUsername()`. For `Clients` and `Realms` it is not `create` but `import` (the id/realm has to be pre-set on the representation). fschmtt does not translate Guzzle exceptions, so `ErrorTranslation` has to absorb the base `RequestException` (TLS failures and the like) as well as 404/409/403.
- **The facade's `update()` returns void on all five resources** — fschmtt re-GETs the representation and hands it back, but the eight sister languages all return no value, so we drop it to hold the §4 isomorphism. `Roles::update` takes no id argument and reads the name from `$role->getName()`. `Users::all()` hits the same endpoint as `search()`, so it is not exposed.
- ⚠️ **league/stevenmaguire's `pkceMethod` constructor option is a no-op** (it is recomputed internally and ignored) — override `PkceKeycloakProvider::getPkceMethod()`. `exchangeCode()` is stateless and does not verify the OAuth `state` (the caller's responsibility — isomorphic with Node, Go and C#).
- ⚠️ **`getAuthorizationUrl(['nonce' => $n])`, by contrast, is a passthrough** — do not assume it belongs to the same class as `pkceMethod`. `createAuthorizationRequest()` **always** builds a nonce and puts it in the URL, and `exchangeCode(..., ?string $expectedNonce = null)` fully validates the id_token and then compares the nonce, but only when one is given.
- ⚠️ **firebase/php-jwt's `&$headers` out-parameter is only populated after a successful decode** — trusting the alg beforehand buys no forgery protection, so **base64url-decode the first segment of the raw token yourself** and gate the alg up front. The built-in `CachedKeySet` is not used because of a rate-limit bug (#543); we have our own `JwksStore`. The `\TypeError` thrown by a malicious JWKS modulus is a subclass of `\Error`, so `\Exception` does not catch it — `catch(\Throwable)` is required.
- ⚠️ **`JwksStore`'s rate limit is per-instance memory state** — in a long-lived worker (Swoole, RoadRunner) it holds across requests, but classic PHP-FPM builds a new store per request, so the protection only holds within a single request. **Do not oversell a limit that depends on the deployment model.**
- **Secret memory hygiene is impossible at the language level** — there is no erasable type, so `clientSecret` is always a `string` and masking is only defence in depth.
- **`jumbojett/openid-connect-php` was rejected** — it owns the session superglobals and `header()` redirects itself, which conflicts with a deterministic facade. Hence the `league/oauth2-client` + Keycloak provider combination.
