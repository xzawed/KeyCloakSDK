# Keycloak SDK for Rust

An async Keycloak SDK for Rust — OIDC/OAuth2 authentication with hardened JWT validation plus the Admin REST API, behind a single facade.

Part of a **nine-language polyglot SDK** (Java · Python · Node · Go · C# · PHP · Rust · Ruby · Kotlin) whose concepts, layering and flows are isomorphic across every language — monorepo: <https://github.com/xzawed/KeyCloakSDK>

> **`1.1.5` is on crates.io** — a patch release on top of `1.1.4`; `1.0.0` was the first release that carries the stability guarantee (a breaking change to the public API requires a major bump). The bare `cargo add keycloak-sdk` below resolves `1.1.5`, and a hand-written `keycloak-sdk = "1"` or `keycloak-sdk = "1.0"` matches it too. **Security**: the admin client now holds the access token it sends as a Bearer to one rule shared by all nine SDKs: leading and trailing SP, HTAB, CR and LF are stripped, and unless what remains is a non-empty RFC 6750 `b64token` (ASCII letters and digits and `-._~+/`, with `=` only at the end) the request is not sent and the call ends with the existing error, which does not quote the token — `Transport` from the facade, the token supplier's `HttpFailure` 401 from `raw()`, and `Auth` from the provider, which does not cache such a token. Characters above U+00FF used to go out as raw UTF-8 header bytes, and inner spaces and Latin-1 as is. ⚠️ A token that ends in a newline used to be rejected and is now stripped and sent. A JWKS key set now expires 300 seconds after the load that fetched it finished, and an expired set is treated as a cold cache: the next validation fetches it again through the cold-load path (the same single flight and the same failure backoff) and rejects the token if that fetch fails, instead of validating with the stale keys. Until now the Rust SDK gave a key set no lifetime, so it kept accepting a key the IdP had removed until a token with a new `kid` arrived. ⚠️ If the JWKS cannot be reached for more than 300 seconds, validation fails — by design, because the SDK cannot tell an unreachable JWKS from a key the IdP has removed. The failure backoff's jitter (×[0.5, 1.0)) was drawn again at every check, so the same failure could refuse a validation at 190 ms and send the next one to the IdP at 191 ms; it is now drawn once, when the failure happens. **Fixed**: the auth lane accepted bytes after the JSON value of a token or introspection response — oauth2 reads only one value, so `client_credentials_token`, `refresh`, `exchange_code` (and `exchange_code_with_redirect`), `introspect` and the `TokenProvider` of `AuthClient` returned `{…}garbage`, `{…}{…}` or `{…}` followed by NUL as a success, and a 400 error body with the same tail gave `Auth`, while the admin client's `ClientCredentialsTokenProvider` rejected the same body as `Transport` (measured). Those lanes now reject it, whatever the status, with the `KeycloakError::Transport` that other malformed responses give (`token request failed: Failed to parse server response`); a body followed only by JSON whitespace (SP, HTAB, LF, CR) is accepted as before. **Changed**: the documentation docs.rs renders (public items and module docs) and the comments of `examples/quickstart.rs`, which this README links, are now in English; the code is unchanged. No public API changed.
>
> `1.1.4` was a patch release on top of `1.1.3`. **Security**: the admin client read error bodies to their end. The `keycloak` crate's generated methods read a non-2xx body whole with `text()` before they return the error, so a server wrote all of the 64 MiB it attached to a 404, 409, 403, 500 or 302, one call allocated 177–219 MB, and an error body that stalled or broke off after its head gave `Transport` (`error decoding response body`) instead of the status (4,001–4,015 ms with a 4-second `read_timeout`). The facade picks its errors by status alone, so that body was never used. The facade now sends the same requests (the encoding of path segments, the query and its order, the Bearer, the JSON body) itself, on the same `reqwest::Client`, instead of calling the crate's methods — it borrows only the representation types from the crate — classifies a non-2xx by its status, and drains the body only up to 1,048,576 bytes, the token-response cap, so that the connection can be reused: a body announced as longer is not read, and a body of unannounced length is dropped the moment it passes the cap (for the same 64 MiB the server wrote at most 458,752 bytes, in 0–2 ms, and one call allocated at most 55,159 bytes). The status (`NotFound` and the like) is unchanged, and a body announced as longer than the cap is not waited for when it stalls (`NotFound` in 0–1 ms). An error body within the cap is still drained to its end so that its connection is reused, and one that stalls within the cap still waits for the `read_timeout` but ends with its status instead of `Transport`. The 2xx body of a write is still left unread, and success bodies (`get`, `search`, lists) are not capped. When a consumer's build turns on reqwest's gzip through feature unification, the cap counts decompressed bytes (0.1 MB for one call with a gzip 404 that inflates to 64 MiB, against 135 MB before) — ⚠️ but a decompressed body's length is then unknown in advance (`content_length()` is `None`), so an announced length cannot be used to skip it, and a compressed error body that stalls while it inflates within the cap waits for the `read_timeout` (it still ends with its status). ⚠️ `raw()` is the crate as is and still reads an error body whole into the `text` of `RawKeycloakError::HttpFailure` (2,097,152 bytes for a 404 with 2 MiB): the `ClientBuilder` of reqwest 0.12.28, the version the SDK builds with, has no place to intercept a response body (`connector_layer` wraps only connection setup), so stopping it would mean changing the return type of `raw()`. `validate` also used memory in proportion to a token's length before it checked the signature: jsonwebtoken decodes the header three times (the SDK's `decode_header` included), so one forged token took 140.8–203.3 bytes of peak resident memory per input byte (213.2 MB for a 1 MiB token, measured with a global-allocator counter). A token longer than 256,000 bytes is now rejected with `KeycloakError::TokenValidation` (`token exceeds 256000 bytes`) before it is decoded and before any JWKS request, and the id_token of a nonce-checked `exchange_code` meets the same cap before any JWKS request (as `KeycloakError::Auth`) — ⚠️ but `openidconnect` decodes that id_token first, along with the token response (inside the token-response cap). No public API changed.
>
> `1.1.3` was a patch release on top of `1.1.2`. **Security**: token and introspection responses — on `client_credentials_token`, `refresh`, `exchange_code`, `exchange_code_with_redirect`, `introspect` and the admin client's `ClientCredentialsTokenProvider` — are now read only up to 1,048,576 bytes; a usable token padded with 32 MiB of JSON whitespace used to be read whole (about 95 MiB of heap). The cap is 16 times the longest bearer a default Keycloak 26.6 accepts, so no token a server accepts is refused; a larger response fails with `KeycloakError::Transport` (`token response exceeds 1048576 bytes`), and the admin facade fails as on any other token failure, with no admin request sent. **Fixed**: cancelling a validation right after a key rotation — `validate()`, or the id_token check of a code exchange with a nonce, dropped through `tokio::time::timeout`, `select!` or `JoinHandle::abort` — no longer spends the forced JWKS refetch window while the fetch dies with it; the fetch now keeps running in a detached task and fills the cache, so the rotated key's tokens are accepted without another IdP request — as long as the tokio runtime that spawned it is still running: a sync wrapper that builds a runtime per call and drops it on a timeout ends the fetch with the runtime, and the rotated key's tokens are then rejected as `unknown kid (refetch rate-limited)` until the window passes, so reuse one runtime. ⚠️ A validation waiting on that fetch now waits for it to finish even when the caller that started it was cancelled, so a low-level `JwksStore::new` given a `reqwest::Client` without a timeout lets an unresponsive IdP hold it (the shared client `KeycloakClient` builds gives up after 5 seconds to connect, 30 in total). No public API changed.

## Requirements

- Rust **1.88+** (MSRV — required by edition 2024 and let-chains)
- A [tokio](https://tokio.rs) runtime — the SDK is async-only
- A Keycloak server (verified against 26.6)

## Install

```bash
cargo add keycloak-sdk
cargo add tokio --features rt-multi-thread,macros   # the quickstart's #[tokio::main]
```

The SDK does not re-export a runtime: `tokio` is your dependency, not a transitive one, so the quickstart below does not compile without that second line.

## Quickstart

The same three steps as every sibling SDK — get a token, verify it, call the Admin API.

```rust
use keycloak_sdk::types::UserRepresentation;
use keycloak_sdk::{KeycloakClient, KeycloakConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = KeycloakConfig::new("https://keycloak.example.com", "my-realm", "my-client")?
        .with_client_secret(std::env::var("KC_CLIENT_SECRET")?); // load from env / a secret manager

    let client = KeycloakClient::new(cfg)?;

    // 1. Get a token (client-credentials grant). TokenSet's Debug masks the tokens as "***".
    let token = client.auth().client_credentials_token().await?;
    println!("token type: {}, expires in: {}s", token.token_type, token.expires_in);

    // 2. Verify it — hardened validation, not the library defaults.
    let validated = client.auth().validate(&token.access_token).await?;
    println!("subject: {}, issuer: {}", validated.subject, validated.issuer);

    // 3. Call the Admin API. The new id comes from the response Location header (None if absent).
    let user_id = client
        .admin()
        .create_user(UserRepresentation {
            username: Some("demo-user".into()),
            email: Some("demo@example.com".into()),
            enabled: Some(true),
            ..Default::default()
        })
        .await?;
    println!("created demo-user (id={user_id:?})");

    Ok(())
}
```

A stock realm does **not** put the client id in a client-credentials token's `aud`, so step 2 fails until the
audience matches: either add an *Audience* protocol mapper to the client in Keycloak, or chain
`.with_expected_audience("…")` onto the config with the value your tokens actually carry (the API/resource
name, when the token is audienced at a resource server).

Errors are values, not panics: every fallible call returns `Result<T, KeycloakError>`, whose variants are
`Config` · `Auth` · `Transport` · `Admin` · `TokenValidation`.

The Admin representation types (`UserRepresentation`, `ClientRepresentation`, `RealmRepresentation`,
`RoleRepresentation`, `GroupRepresentation`) are re-exported from `keycloak_sdk::types`, so the `keycloak`
crate does not need to be a direct dependency of your project.

## Security defaults

- **Algorithm pinning** — only the configured signature algorithms are accepted (default `RS256`); the header's `alg` is never trusted, and `alg: none` is structurally impossible: `jsonwebtoken`'s `Algorithm` enum has no `none` variant, so such a header fails to deserialize before any key is looked up.
- **Strict claim checks** — exact `iss` match, `aud` containment (against `expected_audience`, the client id by default; the id_token of a nonce-checked code exchange is always checked against the client id), mandatory `exp`, `nbf` verified, and a bounded clock skew (30s by default).
- **Bounded token input** — a token longer than 256,000 bytes is rejected with `KeycloakError::TokenValidation` before it is decoded and before any JWKS request. ⚠️ The id_token of a nonce-checked `exchange_code` meets the same bound before any JWKS request (as `KeycloakError::Auth`), but not before it is decoded: `openidconnect` parses it along with the token response, which is capped at 1,048,576 bytes.
- **DoS-safe JWKS** — keys are cached for 300 seconds; after that the next validation fetches them again as on a cold cache and fails if that fetch fails (expired keys are never used, not even during an IdP outage). Until then a refetch is triggered only by an unresolved `kid` and never by a bad signature, and it is rate-limited to a minimum interval (`with_jwks_min_refetch_secs`, 30s by default). The gate is stamped when the refetch is *decided*, not when it succeeds, so an IdP outage cannot reopen it — so **while the key set is fresh**, no volume of forged `kid`s makes the SDK issue more than one JWKS request per interval. A *failed* fetch is bounded separately: consecutive failures back off exponentially (0.2s, doubling, capped at 5s, with jitter), and inside that window the SDK **fails fast without contacting the IdP**. So a cold or expired cache during an IdP outage no longer turns every validation into a request (measured: 20 attempts → 1 request, down from 20). Concurrent first validations collapse to a single fetch as well (measured: 20 concurrent → 1). ⚠️ The SDK never sleeps — it returns the error immediately, so retry pacing stays the caller's decision.
- **Safe transport** — TLS verification on by default (rustls), redirects disabled entirely (SSRF hardening), and secrets/tokens masked as `***` in the SDK's `Debug` output.

Masking covers the SDK's own `Debug` impls; it cannot cover what your logging framework or a panic message does with a value you hand it.

## Versioning and support

This SDK is **`1.0`** and follows SemVer: a breaking change to the public API requires a **major** bump. That promise is machine-backed — CI diffs this lane's public API against the **previously published artifact** on every build (`cargo-semver-checks`), and a removal or an incompatible change fails the build. ⚠️ **The gate compares the API _surface_.** A change that leaves the surface identical but alters behaviour is not caught by it, so read the release notes before upgrading.

Only the newest released version of each language SDK receives security fixes; there are no long-term-support lines and older releases are not backported to.

**Each of the nine languages versions independently.** All nine reached `1.0.0` in the same release wave because they earned the same guarantee at the same time — they do **not** move in lockstep afterwards.

## Documentation

- [Project overview](https://github.com/xzawed/KeyCloakSDK) — all nine languages, what is identical and what is not
- [Changelog](https://github.com/xzawed/KeyCloakSDK/blob/main/CHANGELOG.md) — **read this before upgrading**; breaking changes are listed per language
- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#rust) — install and quickstart for this language
- [Compatibility](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/reference/compatibility.md) — which Keycloak server range and base libraries each published version shipped against
- [Deploying a Keycloak server](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [Full runnable example](https://github.com/xzawed/KeyCloakSDK/blob/main/rust/examples/quickstart.rs)
- [Security policy](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)

## License

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/rust/LICENSE)
