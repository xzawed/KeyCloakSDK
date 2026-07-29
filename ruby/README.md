# Keycloak SDK for Ruby

Authentication (OIDC / OAuth2) and the Admin REST API for [Keycloak](https://www.keycloak.org/) behind one consistent facade, with hardened JWT validation.

English · [한국어](https://github.com/xzawed/KeyCloakSDK/blob/main/ruby/README.ko.md)

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API surface, isomorphic across all of them: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **Pre-release** — not yet published to RubyGems.

## Requirements

- Ruby **3.2+**
- Sync-only (every wrapped gem is synchronous); exception-based error handling under `KeycloakSdk::Error`

## Install

```bash
gem install keycloak-sdk
```

Or in a `Gemfile`:

```ruby
gem "keycloak-sdk"
```

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

## Secure by default

The SDK replaces the unsafe library defaults rather than inheriting them:

- **Algorithm pinning** — the header-supplied `alg` is never trusted, so `alg: none` and HS/RS confusion are rejected structurally.
- **Strict claim checks** — exact `iss` match, `aud` containment, mandatory `exp`, `nbf`, and a bounded clock skew.
- **DoS-safe JWKS** — refetch happens only for an unresolved key ID, and is rate-limited, so forged tokens cannot amplify traffic onto your IdP.
- **Secrets stay out of logs** — `Config`, `TokenSet`, and `AuthorizationRequest` mask secrets and tokens in `#inspect` (`***`, no prefix leak), TLS verification is on by default, timeouts are always applied, and redirect-following middleware is never installed (SSRF hardening).

## Documentation

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#ruby) — install, quickstart, and the compatibility matrix
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md) — the server this SDK talks to
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)
- Full example: [`examples/quickstart.rb`](https://github.com/xzawed/KeyCloakSDK/blob/main/ruby/examples/quickstart.rb)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/ruby/LICENSE)
