# Admin capability reference

> Extracted from [Getting Started](../guides/getting-started.md) — that guide is the install and
> quickstart path; this file is the per-language admin surface, kept separate so it can be read as
> an API reference rather than scrolled past.
>
> ⚠️ The **U (update)** column of the table below is machine-checked against the nine sources by
> `scripts/check-admin-capability.mjs`. It locates the table by the two headings below and by the
> legend line that closes it — **those three lines are load-bearing; do not reword them**, and do
> not quote them anywhere above the table (the guard takes the *first* match in the file).

## Admin capability matrix

The nine SDKs are isomorphic in **layering and flow**, not in method-for-method coverage. The admin facade wraps a different underlying library in each language, and those libraries do not expose the same surface. This table tells you what you can call directly, what you get back, and — where a convenience method is absent — what to call instead.

Every SDK also exposes a `raw` escape hatch that returns the underlying client. Reaching for it is normal and expected for the blank cells below. **One caveat that applies everywhere:** the `raw` path bypasses the SDK's error translation, so lower-library exception types surface there. The "no lower-library types leak" guarantee covers the facade path only.

### Direct coverage

✅ present · — absent (use the escape hatch)

| | users | clients | realms | roles | groups |
|---|---|---|---|---|---|
| | C G L U D | C G L U D | C G L U D | C G L U D | C G L U D |
| **Ruby** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Java** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Kotlin** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Python** (sync + `aio`) | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Node** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Go** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **.NET** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **PHP** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Rust** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |

C=create G=get L=list/find U=update D=delete

**All nine are at 25/25.** What still differs is naming and argument shape, not coverage — see the notes below and [What you get back](#what-you-get-back).

Three things worth knowing about these operations:

- **Path and body stay separate on `update`.** Keycloak renames a resource with `PUT /{current address}` carrying the *new* name in the body. If an implementation derives the path from the representation, a rename silently becomes a no-op — same 2xx, nothing changed. ⚠️ Go is the one language where this forced a departure: gocloak builds the request path from the representation, so `realms.update` is the single method there that does not delegate to gocloak.
- **Partial updates behave differently per library.** On Java and Kotlin the admin-client serializes with `NON_NULL`, so unset fields are not sent and the server leaves them alone — you cannot null a field out this way.
- **Rust's facade is flat and its `list_*` take an explicit page.** Methods are `admin.update_role(name, rep)`, `admin.list_roles(first, max)` — not `admin.roles().update(…)`. `max` is deliberately not optional: Keycloak silently applies a default cap when the parameter is absent, so an optional argument would read as "no limit" while truncating. `list_realms()` is the exception — that endpoint takes no pagination.

### What you get back

| Returns representation types from the wrapped library | Returns plain maps |
|---|---|
| Java · Kotlin (`org.keycloak.representations.idm.*`) · Node (`@keycloak/keycloak-admin-client` defs) · Go (`gocloak.*`, **as pointers** — nil-check) · .NET (`Keycloak.AuthServices.Sdk.Admin.Models.*`) · PHP (`Fschmtt\Keycloak\Representation\*`, **lists come back as `*Collection` wrappers**) · Rust (`keycloak::types::*`, re-exported as `keycloak_sdk::types` so you need no extra dependency) | Python — `dict[str, Any]` · Ruby — `Hash` |

This is a deliberate, documented decision: re-wrapping stable Keycloak representation types in SDK-owned DTOs was judged not worth the cost.

### Filling the gaps

| Language | Escape hatch | Example — the `realms.update` gap |
|---|---|---|
| Java | `raw()` → `org.keycloak.admin.client.Keycloak` | no gaps; the facade's `realms().update(currentName, rep)` wraps exactly this call |
| Kotlin | `raw()` → `org.keycloak.admin.client.Keycloak` | no gaps; the facade's `realms().update(currentName, rep)` wraps exactly this call |
| Python | `raw` → `keycloak.KeycloakAdmin` | no gaps; the facade's `realms.update(current_name, rep)` wraps exactly this call (the `aio` mirror wraps `a_update_realm`) |
| Node | `raw()` → `KcAdminClient` | no gaps; the facade's `realms.update(currentName, rep)` wraps exactly this call |
| Go | `Raw()` → `*gocloak.GoCloak` | no gaps; ⚠️ do **not** reach for `Raw().UpdateRealm` — it builds the path from the representation and so cannot rename. The facade's `Realms.Update(ctx, currentName, rep)` issues the request directly for that reason |
| PHP | `raw()` → `Fschmtt\Keycloak\Keycloak` | no gaps; the hatch is the typed fschmtt client |
| Rust | `raw()` → `&KeycloakAdmin<SdkTokenSupplier>` | no gaps; the facade's `update_realm(current_name, rep)` wraps exactly this call (`realm_put`) |
| Ruby | `raw` → `Faraday::Connection` | no gaps; the hatch is a general bearer-authed connection |
| .NET | `Raw` → `IKeycloakClient` (users, groups, realm-read only) | no gaps; for anything outside that typed surface the facade already uses raw Admin REST internally |

⚠️ **Go's hatch needs a token.** Every `gocloak` method takes a bearer token, and the admin facade's cached provider is not exported. Get one with `client.Auth.ClientCredentialsToken(ctx)`. Note this performs a fresh grant rather than reusing the facade's cached, single-flighted token.

⚠️ **Kotlin's hatch is blocking.** `raw()` returns the JAX-RS client directly; calls are not wrapped in `runInterruptible(Dispatchers.IO)` and will block the coroutine dispatcher. Wrap them yourself.

### Known rough edges

These are real and worth knowing before you port code between languages.

- **.NET has full coverage, for a specific reason.** Its `Raw` accessor is a *typed* client covering only users, groups, and realm-read, so `realms.list`, `realms.update`, and `roles.update` were once reachable by no route at all — short of hand-rolling a parallel `HttpClient`, which forfeits the facade's error translation, timeout injection, and redirect hardening. They are now implemented directly on the facade via raw Admin REST, the same mechanism it already used for clients and roles. Do not assume `Raw` covers everything in .NET; prefer the facade.
- **Rust `search_users` requires you to state the page explicitly** — `search_users(username, first, max)`. There is deliberately no default: Keycloak silently applies 100 when `max` is omitted, so an optional parameter would read as "no limit" and truncate anyway. Pass a negative `max` if you really want no server-side cap. For an exact single-user lookup use `find_user_by_username`, which cannot truncate. (It used to hardcode `max=20` and match exactly, with no way to detect the truncation.)
- **`findByClientId` returns different things.** Java, Kotlin, Node, Go, and .NET return a list of client representations. **Python returns the client's UUID string** (or `None`). Ruby has no such method — use `clients.list(clientId: "…")`.
- **`create` return values differ.** Most languages give you the new id. **PHP returns nothing** — for users, follow up with `findIdByUsername`; for groups there is no equivalent lookup. **Rust returns `Option<String>`**, so a successful create may still yield no id. Go returns `(string, error)`.
- **PHP uses `import`, not `create`, for clients and realms** (users, roles, and groups still use `create`). Both require the id/realm pre-set on the object you pass in.
- **Rust's admin facade is flat** — `create_user`, `get_client`, `delete_group` directly on the client, with no `users`/`clients`/… sub-objects. And **`get_realm()` takes no argument**: it returns the configured realm, while `delete_realm(name)` is name-addressed.
- **Pagination is spelled differently.** Java, Kotlin, and Go take positional `(first, max)` with no defaults; Python, Node, and .NET default them; Ruby takes free-form keyword params; PHP takes a `Criteria` object. Kotlin also requires a non-null `username` for `search`, so "list all users" is not expressible there the way it is in Node, Python, or .NET.
- **`realms.create` exists everywhere but is master-realm-only at runtime.** A realm-scoped service account gets 403 regardless of its roles.
- **Java's `Optional` and Python's `| None` on `get` are never actually empty.** Both raise a not-found error instead. Kotlin deliberately returns the value directly rather than copying the Java idiom.
