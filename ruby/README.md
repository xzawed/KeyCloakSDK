# Keycloak SDK for Ruby

Authentication (OIDC / OAuth2) and the Admin REST API for [Keycloak](https://www.keycloak.org/) behind one consistent facade, with hardened JWT validation.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API surface, isomorphic across all of them: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.4.0` is on RubyGems** — a minor release on top of `1.3.2`; `1.0.0` was the first release carrying the stability guarantee. A bare `gem install keycloak-sdk` resolves it. It is a minor release because the public API grew by two module functions, `KeycloakSdk::Http.settling` and `KeycloakSdk::Http.read_error_body`, which the admin change below is built on; the admin middleware itself, `Admin::SettleBody`, is a private constant. **Security**: the admin client read a response body to its end even after it had the result. faraday-net_http returns a response only after it has read the body to its end, so a server wrote all of the 64 MiB it attached to the 201 body of a `create` or the 2xx body of an `update` or `delete` (182–522 ms), and a server that stalled after a 2xx head turned a write call — even a `create` that already had its `Location` — into a `TransportError` at the end of the read timeout (4,037–4,060 ms across the fifteen write calls with a 4-second timeout). Error bodies were read to their end too: a 404 with 64 MiB made one call allocate 203 MB, and net-http asked for gzip on its own and decompressed it above the cap (202 MB for a gzip error body that inflates to 64 MiB). The facade's fifteen write calls (`create`, `update` and `delete` on the five resources) now leave a 2xx body unread (the server wrote at most 393,218 bytes; 26–45 ms in front of a stalled server), and an error body (3xx and above) is held only up to 1,048,576 bytes, the token-response cap (4.2–4.3 MB for one call with a 64 MiB error body). The status class (`NotFoundError` and the like) and the message are unchanged — the message does not carry the body. An error body that stalls after passing the cap ends with its status without waiting out the read timeout (it used to end in `TransportError` after 4,042–4,072 ms). Admin requests now ask for `Accept-Encoding: identity`, so net-http no longer asks for gzip and decompresses it, and an error body sent gzipped anyway is capped by the bytes received (0.42 MB for that gzip error body). ⚠️ Against a server that sends gzip even when asked for identity, a success body cannot be parsed and becomes a `TransportError`, and on the `raw` connection such a JSON error body becomes a `Faraday::ParsingError` (net-http used to ask for gzip and decompress it). The `raw` connection still receives a 2xx body (its error body has the same cap), the body of a request streamed with `on_data` goes to the caller uncapped, and success bodies (`get`, `list`) are not capped. `validate` also used memory in proportion to a token's length before it checked the signature: ruby-jwt 3.3.0 decodes the header without a length limit (it has only a JSON depth limit of 100), so one forged token allocated 12.8–18.7 bytes per input byte (measured with `memsize_of_all` while GC was stopped). A token longer than 256,000 bytes (`bytesize`) is now rejected before anything else with `TokenValidationError` (`JWT validation failed: token exceeds 256000 bytes`), and the id_token of `exchange_code` goes through the same check. ⚠️ An empty `audience:` passed together with an over-cap token now raises `TokenValidationError` rather than `ConfigError`, because the cap comes first. The new length constant is a private constant.
>
> `1.3.2` was a patch release on top of `1.3.1`. **Security**: an HTTPS call through a proxy (the SDK has no proxy option — Faraday reads `https_proxy`/`HTTPS_PROXY`) read the proxy's CONNECT reply outside the framing caps, because net-http reads that reply into its own buffer before the point the SDK hooks: net-http `0.9.1` read a 100,000-byte header line, 400 short header lines (82,039 bytes) or a 996,039-byte reply whole and went on to the TLS handshake with the origin, and `0.10.0` read the status line and header block up to its own 1 MiB limit. The socket that carries the CONNECT reply — the TCP socket for a plain proxy, the TLS socket with the proxy for a TLS proxy, never the TLS session with the origin — now gets the same two caps (8,192 bytes per line, 65,536 bytes per header block) and the same constant-message `KeycloakSdk::TransportError`; a well-formed reply passes as before. ⚠️ **`net-http >= 0.9` is now a runtime dependency** — the cap hooks `Net::HTTP#timeouted_connect`, which first appears in `0.9.0`. faraday-net_http already pulls net-http in, so most installs change nothing, but an application that pins net-http below `0.9` must raise it to install this release. **Fixed**: an admin error status (404, 409, 403 or any other non-2xx) whose body claims `Content-Type: application/json` but is not JSON — a proxy's HTML error page, say — raised `TransportError` (`admin transport error: Faraday::ParsingError`) instead of the status class; it now raises `NotFoundError`, `ConflictError`, `ForbiddenError` or `AdminError` with the usual `admin request failed: HTTP <status>` and quotes the body neither in the message nor in the cause chain (a 2xx that does not parse is still a `TransportError`). ⚠️ Code that rescued `KeycloakSdk::TransportError` for such responses now gets the status class. No public API change.
>
> `1.3.1` was a patch release on top of `1.3.0`. **Fixed — upgrade if you installed `1.3.0` recently**: with net-http `0.10` (what a fresh install resolves), a response header name that holds a control character or is longer than 1,024 bytes made `introspect`, `logout` and the admin client raise a raw `ArgumentError` that quoted the name; they now raise `KeycloakSdk::TransportError` (`introspection transport error: ArgumentError` and the like — the cause chain keeps only the class name), as the grants already raised `AuthError`. **Security**: the response *framing* — status line, header lines, chunk-size and extension lines, trailers — was outside the body caps, so a 16 MiB header line, chunk extension or trailer line, or 4,096 trailer lines of 4 KiB, were read whole (32–67 MB allocated per call). Every connection the SDK makes now reads at most 8,192 bytes per framing line and 65,536 bytes of framing per response, and beyond that drops the connection with a constant-message `KeycloakSdk::TransportError` that does not quote the response; default Keycloak responses are far below both. The bound works with net-http `0.9` and `0.10`, and it touches only the sockets the SDK opens. ⚠️ The framing budget also counts chunk-size lines, so a large body cut into chunks of a few dozen bytes is refused (Keycloak and mainstream reverse proxies chunk in KiB and pass). The admin client now refuses, before any request, an access token an HTTP header cannot carry — NUL, DEL and other control characters, or a leading or trailing space or tab — with `AuthError`; net-http used to strip or forward them. ⚠️ A consumer `TokenProvider` whose token ends in a space or tab now fails instead of being trimmed. No public API change.

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

> **Audience:** validation requires the token's `aud` to contain `client_id`. A stock realm does *not* put the client id in a client-credentials token's `aud`, so on a default realm either pass `expected_audience: "my-api"` (the audience your realm actually issues), or add an *Audience* protocol mapper to the client in Keycloak. `expected_audience` applies to access tokens (`validate`) only: the `id_token` that `exchange_code(expected_nonce:)` validates must always carry `client_id` in `aud` (OIDC Core §3.1.3.7).

The five admin resources — `users` / `clients` / `roles` / `groups` / `realms` — offer symmetric CRUD, and `client.admin.raw` is the escape hatch to the underlying bearer-authenticated `Faraday::Connection`.

## Security defaults

The SDK replaces the unsafe library defaults rather than inheriting them:

- **Algorithm pinning** — the header-supplied `alg` is never trusted, so `alg: none` and HS/RS confusion are rejected structurally: the pin is applied before key lookup and signature verification, not after.
- **Strict claim checks** — exact `iss` match, `aud` containment, mandatory `exp`, `nbf` enforced when present, and a bounded clock skew.
- **DoS-safe JWKS** — a fetched key set is used for 300 seconds. The first validation after that fetches it again, and if that fetch fails the validation fails (`KeycloakSdk::TransportError`): keys older than 300 seconds are never used, even during an IdP outage. Within those 300 seconds a refetch is triggered only by an unresolved key ID and never by a bad signature, and is rate-limited to a minimum interval (`jwks_min_refetch`, 30s by default) — so **once the key set has been fetched**, no volume of forged tokens makes the SDK issue more than one JWKS request per interval on top of that 300-second refetch. A *failed* fetch is bounded separately: consecutive failures back off exponentially (0.2s, doubling, capped at 5s, with jitter), and inside that window the SDK **fails fast without contacting the IdP**. So a cold cache during an IdP outage no longer turns every validation into a request (measured: 20 attempts → 1 request, down from 20). ⚠️ The SDK never sleeps — it returns the error immediately, so retry pacing stays the caller's decision.
- **Bounded token input** — a token longer than 256,000 bytes is rejected with `KeycloakSdk::TokenValidationError` before it is decoded and before any JWKS request.
- **OIDC nonce / `id_token` replay protection** — `create_authorization_request` always issues a nonce (same default as `state:`) and puts it on the authorization URL. Pass it back as `exchange_code(expected_nonce:)` and the SDK fully validates the `id_token` before comparing the nonce claim. Omit `expected_nonce:` and id_token validation is skipped (same opt-out as the other eight languages).
- **Secret handling** — `Config`, `TokenSet`, and `AuthorizationRequest` mask secrets and tokens in `#inspect` (`***`, no prefix leak), TLS verification is on by default, timeouts are always applied, and redirect-following middleware is never installed (SSRF hardening).

Masking covers this SDK's own `#inspect`; it cannot cover what your logging framework or a backtrace does with a value you hand it. Ruby has no erasable string type, so the client secret lives in an ordinary `String` for its lifetime — masking is defence in depth, not an erasure guarantee.

## Versioning and support

This SDK is **`1.0`** and follows SemVer: a breaking change to the public API requires a **major** bump. That promise is machine-backed — CI diffs this lane's public API against the **previously published artifact** on every build (`yard diff`), and a removal fails the build. ⚠️ **This lane’s gate is narrower than its siblings’**: Ruby has no equivalent of `japicmp`/`gorelease`, so the gate catches a **removed** public object but not a changed method signature — that case is caught by review, not by machine. ⚠️ **The gate compares the API _surface_.** A change that leaves the surface identical but alters behaviour is not caught by it, so read the release notes before upgrading.

Only the newest released version of each language SDK receives security fixes; there are no long-term-support lines and older releases are not backported to.

**Each of the nine languages versions independently.** All nine reached `1.0.0` in the same release wave because they earned the same guarantee at the same time — they do **not** move in lockstep afterwards.

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
