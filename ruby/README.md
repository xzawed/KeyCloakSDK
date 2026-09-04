# Keycloak SDK for Ruby

Authentication (OIDC / OAuth2) and the Admin REST API for [Keycloak](https://www.keycloak.org/) behind one consistent facade, with hardened JWT validation.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API surface, isomorphic across all of them: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.0.0` is on RubyGems** — the first release carrying the stability guarantee. A bare `gem install keycloak-sdk` resolves it.

## Requirements

- Ruby **3.2+**
- Sync-only (every wrapped gem is synchronous); exception-based error handling under `KeycloakSdk::Error`

## Install

```bash
gem install keycloak-sdk
```

Or in a `Gemfile`:

```ruby
gem "keycloak-sdk", "~> 1.0"
```

`~> 1.0` accepts every `1.x` release and stops before `2.0` — the boundary a breaking change has to cross under the promise below.

> **Name mismatch, on purpose:** the gem is `keycloak-sdk` (hyphen) but the require path and module are `keycloak_sdk` / `KeycloakSdk` (underscore) — this avoids colliding with the existing `keycloak` gem's `Keycloak` module.

## Quickstart

```ruby
require "keycloak_sdk"

config = KeycloakSdk::Config.new(
  server_url: "https://kc.example.com",
  realm: "myrealm",
  client_id: "admin-cli",
  client_secret: "changeme" # load the real value from an env var / secrets manager
)

client = KeycloakSdk::KeycloakClient.new(config)

# 1) Issue a token via the client-credentials grant. TokenSet#inspect masks every token value.
token = client.auth.client_credentials_token

# 2) Validate it — algorithm pinning, exact iss, aud containment, mandatory exp, nbf, clock skew.
validated = client.auth.validate(token.access_token)
puts "subject=#{validated.subject} aud=#{validated.audience}"

# 3) Admin API — admin is created lazily on first access. create() returns the new user id.
user_id = client.admin.users.create({ username: "alice", enabled: true })
client.admin.users.delete(user_id)

client.close
```

> **Audience:** validation requires the token's `aud` to contain `client_id`. A stock realm does *not* put the client id in a client-credentials token's `aud`, so on a default realm either pass `expected_audience: "my-api"` (the audience your realm actually issues), or add an *Audience* protocol mapper to the client in Keycloak.

The five admin resources — `users` / `clients` / `roles` / `groups` / `realms` — offer symmetric CRUD, and `client.admin.raw` is the escape hatch to the underlying bearer-authenticated `Faraday::Connection`.

## Security defaults

The SDK replaces the unsafe library defaults rather than inheriting them:

- **Algorithm pinning** — the header-supplied `alg` is never trusted, so `alg: none` and HS/RS confusion are rejected structurally: the pin is applied before key lookup and signature verification, not after.
- **Strict claim checks** — exact `iss` match, `aud` containment, mandatory `exp`, `nbf`, and a bounded clock skew.
- **DoS-safe JWKS** — a refetch is triggered only by an unresolved key ID and never by a bad signature, and is rate-limited to a minimum interval (`jwks_min_refetch`, 30s by default) — so **once the key set has been fetched**, no volume of forged tokens makes the SDK issue more than one JWKS request per interval. ⚠️ **The gate does not cover the initial load.** Until the first fetch succeeds the cache is empty, so while the JWKS endpoint is failing every validation attempt retries it (measured: 20 attempts → 20 requests). Read this as a bound on forged-key-ID amplification against a reachable IdP, not as an availability guarantee during an IdP outage.
- **OIDC nonce / `id_token` replay protection** — `create_authorization_request` always issues a nonce (same default as `state:`) and puts it on the authorization URL. Pass it back as `exchange_code(expected_nonce:)` and the SDK fully validates the `id_token` before comparing the nonce claim. Omit `expected_nonce:` and id_token validation is skipped (same opt-out as the other eight languages).
- **Secret handling** — `Config`, `TokenSet`, and `AuthorizationRequest` mask secrets and tokens in `#inspect` (`***`, no prefix leak), TLS verification is on by default, timeouts are always applied, and redirect-following middleware is never installed (SSRF hardening).

Masking covers this SDK's own `#inspect`; it cannot cover what your logging framework or a backtrace does with a value you hand it. Ruby has no erasable string type, so the client secret lives in an ordinary `String` for its lifetime — masking is defence in depth, not an erasure guarantee.

## Versioning and support

This SDK is **`1.0`** and follows SemVer: a breaking change to the public API requires a **major** bump. That promise is machine-backed — CI diffs this lane's public API against the **previously published artifact** on every build (`yard diff`), and a removal or an incompatible change fails the build. ⚠️ **This lane’s gate is narrower than its siblings’**: Ruby has no equivalent of `japicmp`/`gorelease`, so the gate catches a **removed** public object but not a changed method signature — that case is caught by review, not by machine. ⚠️ **The gate compares the API _surface_.** A change that leaves the surface identical but alters behaviour is not caught by it, so read the release notes before upgrading.

Only the newest released version of each language SDK receives security fixes; there are no long-term-support lines and older releases are not backported to.

**Each of the nine languages versions independently.** All nine reached `1.0.0` on the same day because they earned the same guarantee at the same time — they do **not** move in lockstep afterwards.

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#ruby) — install and quickstart for this language
- [Compatibility](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/reference/compatibility.md) — which Keycloak server range and base libraries each published version shipped against
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md) — the server this SDK talks to
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)
- Full example: [`examples/quickstart.rb`](https://github.com/xzawed/KeyCloakSDK/blob/main/ruby/examples/quickstart.rb)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/ruby/LICENSE)
