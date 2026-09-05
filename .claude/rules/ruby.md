---
paths:
  - "ruby/**"
  - "harness/apps/ruby/**"
  - "harness/install/consume/ruby*"
  - ".github/workflows/ruby-*.yml"
---
<!-- doc-budget: max-bytes=6305 -->

# Ruby rules

## Toolchain

System install — ask `node scripts/doctor.mjs ruby` where it is rather than assuming a path (⚠️ this line said `${KCSDK_TOOLS:-$HOME/tools}/ruby`, which does not exist on this machine). Development on 3.4; `required_ruby_version >= 3.2` (CI runs 3.2, 3.3, 3.4 and 4.0).

```bash
cd ruby && bundle install   # ruby 는 PATH 에 있다. 없으면 `node scripts/doctor.mjs ruby`
cd ruby && bundle exec rspec                    # unit + coverage gate 90 lines / 85 branches. No Docker
cd ruby && RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration   # needs Docker (KC 26.6)
cd ruby && bundle exec rubocop
cd ruby && bundle exec bundler-audit check --update
cd ruby && gem build keycloak-sdk.gemspec       # release build check
```

- A single test: `bundle exec rspec spec/unit/<path>_spec.rb -e "<example name>"`
- The gem is `keycloak-sdk` (hyphen); the require path and module name are `keycloak_sdk` / `KeycloakSdk` (underscore) — this avoids colliding with the `Keycloak` module of the existing `keycloak` gem.
- Releasing goes `ruby-v*` tag → RubyGems **Trusted Publishing** (OIDC, no stored secret). The only prerequisite is one **pending** Trusted Publisher registration on the rubygems.org profile, and it can be used for a gem that does not exist yet. ⚠️ A pending registration is believed to expire after 12 hours, so **do the registration and the tag push in one sitting**. ⚠️ Never `gem push` by hand — it bypasses `install-smoke`, the integration gate and the tag ↔ manifest guard.
- ⚠️ **A local Windows build needs MSYS2/DevKit** (racc, prism and bigdecimal compile natively; CI on ubuntu is unaffected). MSYS2 pacman's c-ares resolver cannot resolve DNS on this network, so work around it with `XferCommand = /usr/bin/wget …` in `pacman.conf` plus a pinned mirrorlist and `/etc/hosts`, then run `ridk install 3` (once).
- ⚠️ `rubocop -a` can write CRLF on Windows — overwrite with the Edit/Write tools to keep LF.
- ⚠️ **SimpleCov's `minimum_coverage` is a process-wide gate** — running `spec/integration` on its own fails on branch coverage, so guard it with `unless ENV["RUN_INTEGRATION"]`.

## JWT · JWKS

- ⚠️ **The `jwt` (ruby-jwt) defaults are not safe** — with no `algorithms:` it allows a wide set including `none`, so pin `["RS256"]`. `verify_iss` / `verify_aud` / `verify_expiration` / `verify_not_before` are all off by default → turn them all on, with `required_claims: %w[exp iss aud]` and `leeway: config.clock_skew`. The alg pin fires **before** key lookup and signature verification (unlike PHP, no header pre-decode is needed).
- ⚠️ **Passing a nil `issuer`/`audience` to `JwtValidator.new` silently turns verify_iss/verify_aud into no-ops** — the constructor fails closed with a `ConfigError` on nil or blank.
- ⚠️ **`JwksStore`'s rate-limit guard has to apply to a nil cache as well (cold start plus an IdP outage)** — in the order `@cache && force && !refetch_allowed?` the rate limit is bypassed entirely whenever there is no cache. `force && !refetch_allowed?` — the cache-independent gate first — is the correct order.

## auth · admin

- ⚠️ **`rack-oauth2`'s PKCE is a passthrough** — the SDK builds the S256 verifier and challenge by hand out of `SecureRandom` + SHA256 + base64url and passes it to `access_token!(code_verifier:)` (omit it and you get invalid_grant). scope is **keyword-only** as well: a positional argument is dropped silently. `Client::Error` has no `#error`, so read it as `e.response[:error]`, and take the id_token out of `raw_attributes[:id_token]`.
- `create_authorization_request` **always** generates `nonce:` alongside `state:` and puts it in the URL. `exchange_code(expected_nonce:)` is optional (omit it and id_token validation is skipped).
- ⚠️ **admin has no mature gem, so the Admin REST API is wrapped directly with `faraday`** (`looorent/keycloak-admin` has no seam for injecting a TokenProvider, which makes it §4-incompatible). **The base_url is `"{server_url}/"` plus a full path per resource** — assembling relative paths onto `"{server_url}/admin/realms/"` diverges from a real server over the trailing slash. The `create` family takes the id out of the 201's `Location` header.
- ⚠️ **admin does not depend on `auth` — the `TokenProvider` duck interface is the only glue.** admin takes a dedicated `ClientCredentialsTokenProvider`. `AuthClient` implements `TokenProvider` too, but **it is not injected into admin directly** (plugging in an uncached provider fetches a fresh token on every call).

## Error boundary (§4)

- ⚠️ **`Faraday::SSLError` and `ParsingError` descend directly from `Faraday::Error`** — they are siblings of ConnectionFailed and TimeoutError, not subclasses of them — so all four boundaries have to catch **broadly**, with `rescue Faraday::Error`, for a TLS or parsing failure to become a `TransportError`. Catching broadly is safe here because the `RaiseError` middleware is not installed (each resource checks `resp.success?` by hand), so a status-derived `Faraday::ClientError` never reaches this boundary.
- ⚠️ **`Rack::OAuth2::Client::Error` has to be converted too** — catch only the Faraday family and the rack-oauth2 exceptions from the auth path leak out through the public API.
- ⚠️ **`client.auth.validate` can raise a `TransportError` when the IdP is down** (fail-closed, intended) — a caller has to handle that as well as `TokenValidationError`.
- ⚠️ **The shared Faraday connection factory (`http.rb`) deliberately does not install `follow_redirects`** (SSRF hardening). All four paths — token_provider, jwks, admin, introspect/logout — go through this factory, so **this is the single enforcement point**. `spec/unit/http_spec.rb` catches the regression, but ⚠️ that check inspects the middleware **list**; it is not a probe that actually drives a 302.
- **Limits**: `Config`'s string attributes are frozen at the instance level only, not deep-frozen. Secret memory hygiene is impossible at the language level because a Ruby `String` cannot be erased — masking is only defence in depth.
