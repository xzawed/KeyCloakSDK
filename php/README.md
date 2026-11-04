# Keycloak SDK for PHP

An idiomatic PHP SDK for [Keycloak](https://www.keycloak.org/) covering both OIDC/OAuth2 authentication and the Admin REST API behind one consistent facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API shape, nine idioms: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.5.2` is on Packagist** — where `ext-curl` is enabled, `composer require xzawed/keycloak-sdk` resolves `1.5.2` under Composer's default `minimum-stability: stable`. A patch release on top of `1.5.1`. **Changed**: ⚠️ the token grants of `AuthClient` (`clientCredentialsToken`, `refresh` and `exchangeCode`) now throw `KeycloakAuthError` instead of `KeycloakTransportError` when the token endpoint answers with a response that is not JSON (a 503 HTML page, a 200 with a non-JSON body and the like) or with JSON that has no `access_token`. `ClientCredentialsTokenProvider` already threw `KeycloakAuthError` for the same responses, and `KeycloakTransportError` means a network failure only — code that caught those responses as a transport error to retry them should look at the auth error instead. The message for a response that is not JSON is unchanged; JSON without `access_token` now says `token response has no usable access_token` instead of `token request failed` (this note used to say the messages were unchanged). A response over the cap (`KeycloakTransportError`) and an OAuth error response (`KeycloakAuthError`) are unchanged. No public API changed.
>
> `1.5.1` was a patch release on top of `1.5.0`. **Security**: the admin lane now holds the access token it sends as a Bearer to one rule shared by all nine SDKs — after leading and trailing SP, HTAB, CR and LF are stripped, it must be a non-empty RFC 6750 `b64token` (ASCII letters and digits and `-._~+/`, with `=` only at the end). Because the underlying admin library builds the Bearer itself, the admin lane accepts the access token of a grant response only when it already is such a `b64token`, with nothing to strip; anything else fails with `KeycloakAdminError` (no status), is not cached, and is not quoted. On PHP without sodium, a JWT's inner spaces and tabs used to be sent as is, and the psr7 exception from `raw()` quoted the whole Bearer. The standalone `ClientCredentialsTokenProvider` strips the leading and trailing characters and accepts. A JWKS key set now expires 300 seconds after the load that fetched it finished, and an expired set is treated as a cold cache: the next validation fetches it again through the cold-load path (the same single flight and the same failure backoff) and rejects the token if that fetch fails, instead of validating with the stale keys. Until now the PHP SDK gave a key set no lifetime, so it kept accepting a key the IdP had removed until a token with a new `kid` arrived. ⚠️ If the JWKS cannot be reached for more than 300 seconds, validation fails — by design, because the SDK cannot tell an unreachable JWKS from a key the IdP has removed. The failure backoff's jitter (×[0.5, 1.0)) was drawn again at every check, so the same failure could refuse a validation at 190 ms and send the next one to the IdP at 191 ms; it is now drawn once, when the failure happens. **Changed**: `composer.json` now requires `ext-curl` and raises its floors to `guzzlehttp/guzzle` `^7.15.2` and `guzzlehttp/psr7` `^2.12.3`. Without curl, Guzzle fell back to PHP's stream handler, which read a response header line with no length limit (+57 MB for one 16 MiB line, with nothing to configure), and psr7 below 2.11 could not stop a transfer at the cap, so a large error body was received to its end. The two floors also close GHSA-v5mv-p594-2x33 and GHSA-f7vp-7xgx-4w4r (Guzzle) and GHSA-c2w2-prh8-qm98 (psr7). ⚠️ Without `ext-curl`, Composer does not pick this release: a bare `composer require xzawed/keycloak-sdk` warns that it cannot use the latest version because it requires `ext-curl`, and installs `1.5.0` with exit code 0; a constraint naming `1.5.1` is refused (`Your requirements could not be resolved …`), and so is `composer install` from a lock that holds `1.5.1` (`Your lock file does not contain a compatible set of packages …`). The docblocks your IDE shows (classes and their public and protected members) and the comments of `examples/quickstart.php` are now in English; the code and the PHPDoc tags and types are unchanged. No public API changed.
>
> `1.5.0` was a minor release on top of `1.4.1`, and a security release. **Security**: `validate()` and `validateIdToken()` (and so `exchangeCode()`) split and JSON-decoded a token before checking its signature, with no length limit — an attacker-chosen 768 KiB token ended the request with a fatal out-of-memory error under PHP's default `memory_limit`, the kind of attacker-reachable fatal error that PHP2Shell (CVE-2026-109618 / CVE-2026-109619) can turn into code execution on an unpatched runtime. A token longer than the new public constant `JwtValidator::JWT_MAX_BYTES` (256,000 bytes) is now rejected with `TokenValidationError` before it is split or decoded and without a JWKS request, and a token without exactly two dots is rejected before it is split. ⚠️ This does not patch your interpreter — see [Requirements](https://github.com/xzawed/KeyCloakSDK/blob/main/php/README.md#requirements). The admin facade also stops receiving bodies it does not use: the 2xx body of a write (`create`, `update`, `delete`, and `import` for clients and realms) is no longer received, and an error body (3xx or above) is received only up to 1,048,576 bytes, so a server that sends 64 MiB no longer makes the call receive all of it or wait out the read timeout; status classes are unchanged and a `raw()` error response is cut at the same length. ⚠️ Without `ext-curl`, the stream handler stops the transfer at that cap only with `guzzlehttp/psr7` 2.11.0 or later. One public API addition (`JwtValidator::JWT_MAX_BYTES`); the measurements and caveats are in the [changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md).
>
> ⚠️ **Coming from `1.0.0`–`1.5.1`?** No public API changed, but behaviour did — exception classes, refused inputs, read limits and what gets printed. See [Upgrading from `1.0.0`](https://github.com/xzawed/KeyCloakSDK/blob/main/php/README.md#upgrading-from-100).
>
> ⚠️ **Coming from `0.1.0`? `roles()->update()` changed signature.** It takes the current name as its first argument — `update(string $name, Role $role)` — because the old one-argument form **could not express a rename at all**. See [Upgrading from `0.1.0`](https://github.com/xzawed/KeyCloakSDK/blob/main/php/README.md#upgrading-from-010).

## Requirements

- PHP **8.3+** (`composer.json` requires `^8.3`)
  - ⚠️ Run a PHP build that carries the PHP2Shell fixes (CVE-2026-109618 / CVE-2026-109619) — **8.3.36, 8.4.27, 8.5.12** or later, or your distribution's patched package. The SDK cannot protect an unpatched interpreter, and Composer cannot enforce this for you: distributions backport the fix without changing the version PHP reports, so a version floor in `composer.json` would also reject patched servers.
- The `curl` extension — `composer.json` requires `ext-curl` (`1.5.0` and earlier did not). Without it Guzzle falls back to PHP's stream wrapper, which reads a response header line of any length. ⚠️ Composer checks extensions when it installs, not at run time (its default `platform-check` covers only the PHP version), so without the extension a bare `composer require xzawed/keycloak-sdk` stays on `1.5.0`.
- Keycloak server 26.6.x (verified by the integration suite)

## Install

The SDK is developed in the `php/` directory of a polyglot monorepo, and Packagist cannot install from a subdirectory. Releases are therefore subtree-split into the dedicated read-only repository [`xzawed/keycloak-sdk-php`](https://github.com/xzawed/keycloak-sdk-php), which is what Packagist reads — the package name stays `xzawed/keycloak-sdk`:

```bash
composer require "xzawed/keycloak-sdk:^1.0"
```

```php
use Xzawed\Keycloak\{KeycloakClient, KeycloakConfig};   // admin lives under Xzawed\Keycloak\Admin
```

## Quickstart

`KeycloakClient::create()` assembles auth immediately (no network); `admin()` is created lazily on first call and needs a client secret. Value types are `final readonly class`, and failures throw the `KeycloakException` hierarchy.

```php
<?php

declare(strict_types=1);

require __DIR__ . '/vendor/autoload.php';

use Fschmtt\Keycloak\Representation\User;
use Xzawed\Keycloak\KeycloakClient;
use Xzawed\Keycloak\KeycloakConfig;

$client = KeycloakClient::create(new KeycloakConfig(
    serverUrl: 'https://kc.example.com',
    realm: 'myrealm',
    clientId: 'my-app',
    clientSecret: '…', // load from an env var / secret manager; __toString is auto-masked
));

// 1) client-credentials grant. TokenSet::__toString() masks the tokens (accessToken=***).
$token = $client->auth()->clientCredentialsToken();
echo "token type: {$token->tokenType}, expires in: {$token->expiresIn}s\n";

// 2) hardened verification (alg pinning · exact iss · aud containment · mandatory exp · clock skew).
$validated = $client->auth()->validate($token->accessToken);
echo "subject: {$validated->subject}, issuer: {$validated->issuer}\n";

// 3) admin API — create/update return void (sister-language isomorphism). Look the id up with findIdByUsername().
$users = $client->admin()->users();
$users->create(new User(username: 'alice', enabled: true));
$userId = $users->findIdByUsername('alice');
$users->update($userId, $users->get($userId)->withEmail('alice@example.com'));
echo "created userId={$userId}\n";
```

> **Audience:** validation requires the token's `aud` to contain `clientId`. A stock realm does *not* put the client id in a client-credentials token's `aud`, so on a default realm either pass `expectedAudience: 'my-api'` (the audience your realm actually issues), or add an *Audience* protocol mapper to the client in Keycloak.

Admin failures surface as `KeycloakNotFoundError` / `KeycloakConflictError` / `KeycloakForbiddenError` (all carrying `KeycloakAdminError::getStatusCode()`), network failures as `KeycloakTransportError`. `admin()->raw()` is the escape hatch to the underlying typed client.

## Security defaults

- **Algorithm pinning** — the accepted JWT signature algorithms are pinned (`RS256` by default, configurable via `signatureAlgorithms:`); the header-supplied `alg`, including `none`, is never trusted. The SDK decodes the raw header segment itself to gate on `alg` *before* verification, because `firebase/php-jwt` only fills its `&$headers` out-parameter after a successful decode.
- **Hardened claims** — exact `iss` match, `aud` containment check, mandatory `exp` (a token without one is rejected), and a bounded clock skew (`clockSkew:`, default 30s).
- **Bounded token input** — `validate()` and `validateIdToken()` reject a token longer than `JwtValidator::JWT_MAX_BYTES` with `TokenValidationError` before splitting or decoding it (and without a JWKS request), and a token without exactly two dots before splitting it. Verification has to decode the header and payload before it can check the signature, so without that bound an attacker-chosen token made the validator allocate up to about 167 bytes per input byte, and a 768 KiB token ended the request with a fatal out-of-memory error under PHP's default `memory_limit` — the kind of attacker-reachable fatal error that PHP2Shell (above) can turn into code execution on an unpatched runtime.
- **DoS-safe JWKS** — a fetched key set is used for 300 seconds. The first validation after that fetches it again, and if that fetch fails the validation fails (`KeycloakTransportError`): keys older than 300 seconds are never used, even during an IdP outage. Within those 300 seconds a refetch is triggered only by an unresolved key ID (rotation) and never by a bad signature, and is rate-limited by `jwksMinRefetchSeconds:` (default 30s) — so **once the key set has been fetched**, no volume of forged random `kid`s makes the SDK issue more than one JWKS request per interval on top of that 300-second refetch. A *failed* fetch is bounded separately: consecutive failures back off exponentially (0.2s, doubling, capped at 5s, with jitter), and inside that window the SDK **fails fast without contacting the IdP**. So a cold cache during an IdP outage no longer turns every validation into a request (measured: 20 attempts → 1 request, down from 20). ⚠️ The SDK never sleeps — it returns the error immediately, so retry pacing stays the caller's decision. ⚠️ Like the refetch gate itself, this state is per-instance: under classic PHP-FPM a fresh store is built per request, so the bound holds within one request.
- **OIDC nonce / `id_token` replay protection** — `createAuthorizationRequest()` always issues a cryptographic nonce, puts it on the authorization URL, and returns it on `AuthorizationRequest::$nonce`. Pass that value as the optional third argument to `exchangeCode()` and the SDK fully validates the `id_token` (signature · `iss` · `aud` · `exp`) before comparing the nonce claim. The id_token's `aud` must contain `clientId` (OIDC Core §3.1.3.7) — `expectedAudience` narrows access-token validation only, so overriding it does not break the exchange. Omit it and id_token validation is skipped (same opt-out as the other eight languages).
- **Secret handling** — `KeycloakConfig`, `TokenSet` and `AuthorizationRequest` mask secrets, tokens and the PKCE verifier fully (`***`, no prefix) in both `__toString()` and `json_encode()` (all three implement `JsonSerializable`); TLS verification is on by default and both connect and read timeouts are always applied.

Two scope limits worth knowing. The JWKS cache and its rate limit are per-`JwksStore` in-memory state, so their reach follows your deployment model: under a long-running worker (Swoole, RoadRunner) they span requests, but under classic PHP-FPM every request builds a fresh store and the limit only binds within that one request. And masking covers this SDK's own `__toString()` and `json_encode()`, plus the engine dumps that honour `__debugInfo()` — `var_dump()`, `print_r()` and `debug_zval_dump()`. It does **not** cover `var_export()`, which reads the properties directly and prints the raw value. (⚠️ This line used to say `var_dump()` and `print_r()` printed the raw value too; `__debugInfo()` is implemented on the masked types and [SECURITY.md](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md) already said so.) PHP also has no erasable string type, so the client secret lives in an ordinary `string` for its lifetime: masking is defence in depth, not a guarantee about your logs.

## Upgrading from `1.0.0`

**No public API was removed or changed incompatibly since `1.0.0`.** CI compares the API with every published release (see [Versioning and support](https://github.com/xzawed/KeyCloakSDK/blob/main/php/README.md#versioning-and-support)). What changed is **behaviour**, which that comparison cannot see. Below is every change from `1.1.0` to `1.5.2` that code written against `1.0.0` can notice without being edited. Each item names the release that brought it, so on a later `1.x` you can skip the ones at or below your version.

**Return values**

- `TokenSet::isExpired()` returns `true` when the token response had no `expires_in` (`1.1.0`; it returned `false`). `ClientCredentialsTokenProvider` therefore fetches a new token instead of reusing one whose lifetime is unknown.

**Exception classes**

- The token grants of `AuthClient` (`clientCredentialsToken`, `refresh`, `exchangeCode`) throw `KeycloakAuthError`, not `KeycloakTransportError`, for a response that is not JSON or JSON without a usable `access_token` (`1.5.2`). `KeycloakTransportError` now means a network failure only.
- `getPrevious()` on an SDK exception is a `SanitizedCause` instead of the original exception (auth `1.2.0`, admin `1.3.0`). It keeps the original class name (`originalClass`), code, file, line and a trace without arguments. Code that reached the Guzzle or league exception through `getPrevious()` no longer can.
- `exchangeCode()` with a nonce reports an invalid `id_token` as `KeycloakAuthError` (`authorization code exchange failed: invalid id_token: …`) whose `getPrevious()` is the `TokenValidationError` — as it did in `1.0.0`, and also for the over-long token that `1.5.0` refuses. The `1.5.0` release notes said `TokenValidationError`; that was wrong.
- `admin()->raw()`: a failure before the server version is detected surfaces as the admin library's `VersionDetectionException` (`1.4.1`).

**Exception messages and `oauthError`**

- An auth error quotes only a code-shaped OAuth `error`, and `oauthError` holds only such a code (`1.2.0`). A code with trailing whitespace such as `"invalid_client\n"` no longer counts as one, so `oauthError` is `null` (`1.4.0`).
- An admin error says `admin request failed: HTTP <status>` without the response body; a failed admin token request says `admin token request failed: HTTP <status> (<code>)` (`1.3.0`).
- A cause message that would quote a header value is replaced with `(message withheld: it quotes a header value)` (`1.4.0`).
- JSON without `access_token` says `token response has no usable access_token` instead of `token request failed` (`1.5.2`).

**Inputs that are now refused**

- `KeycloakConfig`: a connect or read timeout that is `<= 0` or not finite, and a negative `clockSkew`, throw `KeycloakConfigError` (`1.1.0`). `0` used to mean no timeout at all.
- A token response whose `access_token` is missing, empty or not a string is a `KeycloakAuthError` from `TokenSet::fromArray()` and `ClientCredentialsTokenProvider`, and `new TokenSet(accessToken: '')` throws (`1.1.0`).
- The admin lane refuses an access token that is not an RFC 6750 `b64token` with `KeycloakAdminError` (no status). The standalone `ClientCredentialsTokenProvider` strips leading and trailing whitespace and otherwise throws `KeycloakAuthError` (`1.5.1`).
- `validate()` and `validateIdToken()` refuse a token longer than `JwtValidator::JWT_MAX_BYTES` (256,000 bytes), or without exactly two dots, with `TokenValidationError` (`1.5.0`).
- The nonce path of `exchangeCode()` checks the `id_token`'s `aud` against `clientId` rather than `expectedAudience` (`1.3.0`).

**Limits on what the SDK reads** — each is a `KeycloakTransportError`

- A JWKS body over 51,200 bytes at any status, and a key set with no keys; the cached set is kept (`1.1.0`).
- A token, introspection, logout or admin-token response body over 1,048,576 bytes (`1.4.0`). Through `raw()` it is Guzzle's `RequestException`.
- A JWKS, token, introspection or logout body that stalls before its end (`1.4.1`).

Admin writes (`create`, `update`, `delete`, and `import` for clients and realms) no longer receive their 2xx body, so a write whose 2xx body is cut off now succeeds, and an error body is received only up to 1,048,576 bytes (`1.5.0`).

**Timing**

- Consecutive JWKS fetch failures back off exponentially, and inside that window the SDK fails fast without contacting the IdP (`1.1.0`). The jitter is drawn once per failure (`1.5.1`).
- A key set is used for 300 seconds; after that, a failed refetch fails the validation instead of falling back to the old keys (`1.5.1`).

**What gets printed**

- `json_encode()` of `TokenSet`, `KeycloakConfig` and `AuthorizationRequest` masks the tokens, the client secret and the PKCE verifier as `***`, including a `null` token. `AuthorizationRequest` gained `__toString()` (`1.1.0`).
- `var_dump()` and `print_r()` of the client and the auth and admin facades no longer print the client secret or an in-flight PKCE verifier, and `JwtValidator` no longer leaves the start of a token in stack traces (`1.1.0`).

**Inputs that are now accepted**

- A numeric `refresh_token` and a fractional `expires_in` are accepted (`1.2.0`; they raised `\TypeError`).

**Requirements**

- `ext-curl` is required, and the floors are `guzzlehttp/guzzle` `^7.15.2` and `guzzlehttp/psr7` `^2.12.3` (`1.5.1`). Without curl, Composer stays on `1.5.0` — see [Requirements](https://github.com/xzawed/KeyCloakSDK/blob/main/php/README.md#requirements).
- The admin library pin moved from `fschmtt/keycloak-rest-api-client-php` `0.42.0` to `0.43.0` (`1.4.0`) and `0.44.0` (`1.4.1`). `admin()->raw()` returns that library's client, so read its changelog if you call it.

**Additions** — nothing to do: an optional `$redirectUri` on `createAuthorizationRequest()` and `exchangeCode()` (`1.1.0`), `validateIdToken()` (`1.3.0`), and the public constants `JwksStore::JWKS_MAX_BYTES` and `JwksStore::JWKS_READ_CHUNK_BYTES` (`1.1.0`), `ErrorTranslation::TOKEN_PATH` (`1.4.0`) and `JwtValidator::JWT_MAX_BYTES` (`1.5.0`).

## Upgrading from `0.1.0`

**One signature changed, and it is a fix rather than a rearrangement.**

`roles()->update(Role $role)` became **`roles()->update(string $name, Role $role)`**. The old form took only the representation, and the library underneath builds the request path out of `$role->getName()` — so the path and the body came from the same value and **a rename could not be expressed**. Measured on `0.1.0`: asking to rename `old-name` to `new-name` sent `PUT /roles/new-name` with body `{"name":"new-name"}`, and the current name appeared nowhere in the request. Keycloak renames with `PUT /{current name}` carrying the new name in the body, so that request was not a rename — it was an update aimed at a role that does not exist yet.

```php
// before — the one-argument form could only update a role in place
$admin->roles()->update(new Role(name: 'reporting'));

// now — address by the current name, put the new one in the body
$admin->roles()->update('reporting', new Role(name: 'analytics'));

// updating without renaming: repeat the name
$admin->roles()->update('reporting', new Role(name: 'reporting', description: 'Read-only'));
```

The other eight language SDKs always took `(name, representation)`; this brings PHP back in line with them. Nothing else changed — `users()`, `clients()`, `realms()` and `groups()` already took a separate identifier and are untouched.

## Upgrading from `0.1.0-rc.1`

`0.1.0-rc.2` adds OIDC `nonce` so `id_token` replay can be detected, which changes two signatures. **One of them can break your code:**

1. **`new AuthorizationRequest(...)` gains a required `string $nonce`.** If you construct this type by hand you will get a `TypeError` for the missing argument. Let the SDK build it instead — `$client->auth()->createAuthorizationRequest(...)` returns a fully populated instance. Reading fields off the returned object is unaffected (a field was *added*, none removed).
2. **`exchangeCode()` gains an optional third argument.** Two-argument calls keep working unchanged — but that path still does **not** verify the `id_token`. To get replay protection, pass the nonce you were given: `exchangeCode($code, $verifier, $req->nonce)`.

## Versioning and support

This SDK is **`1.0`** and follows SemVer: a breaking change to the public API requires a **major** bump. That promise is machine-backed — CI diffs this lane's public API against the **previously published artifact** on every build (`php-semver-checker`, judged on its report body), and a removal or an incompatible change fails the build. ⚠️ **The gate compares the API _surface_.** A change that leaves the surface identical but alters behaviour is not caught by it, so read the release notes before upgrading.

Only the newest released version of each language SDK receives security fixes; there are no long-term-support lines and older releases are not backported to.

**Each of the nine languages versions independently.** All nine reached `1.0.0` in the same release wave because they earned the same guarantee at the same time — they do **not** move in lockstep afterwards.

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md) — install and quickstart for this language
- [Compatibility](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/reference/compatibility.md) — which Keycloak server range and base libraries each published version shipped against
- [Full PHP example](https://github.com/xzawed/KeyCloakSDK/blob/main/php/examples/quickstart.php)
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/php/LICENSE)
