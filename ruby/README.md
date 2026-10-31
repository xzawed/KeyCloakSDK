# Keycloak SDK for Ruby

Authentication (OIDC / OAuth2) and the Admin REST API for [Keycloak](https://www.keycloak.org/) behind one consistent facade, with hardened JWT validation.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) — one API surface, isomorphic across all of them: [github.com/xzawed/KeyCloakSDK](https://github.com/xzawed/KeyCloakSDK).

> **`1.4.1` is on RubyGems** — a patch release on top of `1.4.0`; `1.0.0` was the first release carrying the stability guarantee. A bare `gem install keycloak-sdk` resolves it. **Security**: the admin client now holds the access token it sends as a Bearer to one rule shared by all nine SDKs: leading and trailing SP, HTAB, CR and LF are stripped, and unless what remains is a non-empty RFC 6750 `b64token` (ASCII letters and digits and `-._~+/`, with `=` only at the end) the request is not sent and the call fails with `AuthError`, which does not quote the token. `BearerAuth` (the facade and `raw`) and the SDK's provider apply it, and the provider does not cache such a token. It used to reject a leading or trailing space or tab and to send an inner space or a non-ASCII character as is. ⚠️ A token that ends in a newline, or starts or ends with a space or tab, used to be rejected and is now stripped and sent. An access token that is not a String now gets the same check, on the text that goes into the header: a consumer `TokenProvider` that returned a Symbol holding CR or LF made the `raw` connection raise a raw `ArgumentError` quoting the whole Bearer and the facade raise `TransportError` (`admin transport error: ArgumentError`), a Symbol holding NUL or a trailing space went out as is or with the space removed, and `nil` or `""` went out as `Authorization: Bearer` (measured). These now raise the same `AuthError` as a String, and an empty token sends no request (`admin request not sent: the access token is empty`). A Symbol or number that passes the check still goes out as that text, and the SDK's `ClientCredentialsTokenProvider` always yields a non-empty String, so it is unaffected. The responses the SDK reads itself (token, introspection, JWKS and admin) are now read in full within the configured timeout, counted from when the request is sent. The timeout used to apply to each read only, so a server that trickled bytes, each just inside the read timeout, held one call for about the size cap times the read timeout (7 seconds with a 1-second setting); such a call now ends with the existing timeout error, within the deadline plus one read. A JWKS key set now expires 300 seconds after the load that fetched it finished, and an expired set is treated as a cold cache: the next validation fetches it again through the cold-load path (the same single flight and the same failure backoff) and rejects the token if that fetch fails, instead of validating with the stale keys. Until now the Ruby SDK gave a key set no lifetime, so it kept accepting a key the IdP had removed until a token with a new `kid` arrived. ⚠️ If the JWKS cannot be reached for more than 300 seconds, validation fails — by design, because the SDK cannot tell an unreachable JWKS from a key the IdP has removed. The failure backoff's jitter (×[0.5, 1.0)) was drawn again at every check, so the same failure could refuse a validation at 190 ms and send the next one to the IdP at 191 ms; it is now drawn once, when the failure happens. **Fixed**: building a `KeycloakClient` set the `Config` timeouts on rack-oauth2's process-wide `Rack::OAuth2.http_config`, and rack-oauth2 keeps only the first block set, so when the SDK was built first, a block the host application set later was silently dropped. The SDK's requests do not use that connection, so it no longer sets it. ⚠️ Code in the same process that uses rack-oauth2 directly no longer inherits the SDK's timeouts — set `Rack::OAuth2.http_config` yourself if it needs them. **Changed**: ⚠️ an admin response — lists and `raw` success bodies included — must now arrive in full within the configured timeout (the response deadline above). The timeout used to apply per read, so a large list over a slow link was received to its end; that is now a timeout error, so raise the timeout if you fetch large lists over a slow link. The Go, Rust, Node, PHP and .NET admin clients already behaved this way. The documentation YARD renders (the public API, including the comments shown in the source view of public methods) is now in English; the code is unchanged. No public API changed.
>
> `1.4.0` was a minor release on top of `1.3.2`. It is a minor release because the public API grew by two module functions, `KeycloakSdk::Http.settling` and `KeycloakSdk::Http.read_error_body`, which the admin change below is built on; the admin middleware itself, `Admin::SettleBody`, is a private constant. **Security**: the admin client read a response body to its end even after it had the result. faraday-net_http returns a response only after it has read the body to its end, so a server wrote all of the 64 MiB it attached to the 201 body of a `create` or the 2xx body of an `update` or `delete` (182–522 ms), and a server that stalled after a 2xx head turned a write call — even a `create` that already had its `Location` — into a `TransportError` at the end of the read timeout (4,037–4,060 ms across the fifteen write calls with a 4-second timeout). Error bodies were read to their end too: a 404 with 64 MiB made one call allocate 203 MB, and net-http asked for gzip on its own and decompressed it above the cap (202 MB for a gzip error body that inflates to 64 MiB). The facade's fifteen write calls (`create`, `update` and `delete` on the five resources) now leave a 2xx body unread (the server wrote at most 393,218 bytes; 26–45 ms in front of a stalled server), and an error body (3xx and above) is held only up to 1,048,576 bytes, the token-response cap (4.2–4.3 MB for one call with a 64 MiB error body). The status class (`NotFoundError` and the like) and the message are unchanged — the message does not carry the body. An error body that stalls after passing the cap ends with its status without waiting out the read timeout (it used to end in `TransportError` after 4,042–4,072 ms). Admin requests now ask for `Accept-Encoding: identity`, so net-http no longer asks for gzip and decompresses it, and an error body sent gzipped anyway is capped by the bytes received (0.42 MB for that gzip error body). ⚠️ Against a server that sends gzip even when asked for identity, a success body cannot be parsed and becomes a `TransportError`, and on the `raw` connection such a JSON error body becomes a `Faraday::ParsingError` (net-http used to ask for gzip and decompress it). The `raw` connection still receives a 2xx body (its error body has the same cap), the body of a request streamed with `on_data` goes to the caller uncapped, and success bodies (`get`, `list`) are not capped. `validate` also used memory in proportion to a token's length before it checked the signature: ruby-jwt 3.3.0 decodes the header without a length limit (it has only a JSON depth limit of 100), so one forged token allocated 12.8–18.7 bytes per input byte (measured with `memsize_of_all` while GC was stopped). A token longer than 256,000 bytes (`bytesize`) is now rejected before anything else with `TokenValidationError` (`JWT validation failed: token exceeds 256000 bytes`), and the id_token of `exchange_code` goes through the same check. ⚠️ An empty `audience:` passed together with an over-cap token now raises `TokenValidationError` rather than `ConfigError`, because the cap comes first. The new length constant is a private constant.
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
