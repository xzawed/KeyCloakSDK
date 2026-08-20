---
paths:
  - "java/**"
  - "kotlin/**"
  - "python/**"
  - "node/**"
  - "go/**"
  - "dotnet/**"
  - "php/**"
  - "rust/**"
  - "ruby/**"
---

# Cross-language security invariants

The detail behind the security gotcha stubs in the root `CLAUDE.md`. **A security fact that applies to only one language does not live here** — that belongs in `.claude/rules/<lang>.md`. What lives here is only what the nine languages must move **together**, so changing one language alone is itself the defect.

That is why `paths:` lists all nine language directories — whichever one you touch, this file comes with it.

## Aligned defaults — JWKS minimum refetch interval and `clockSkew` (both 30s)

⚠️ **The JWKS minimum refetch interval defaults to 30 seconds in all nine languages** (aligned 2026-07-31). Before that it was split three ways — 10, 30 and 60 seconds — a **by-product** of PR #71 making the value configurable while leaving each language's hardcoded value in place (on the same burst of forged `kid`s, Ruby hit the IdP six times as often as Python). 30s equals Nimbus's `DEFAULT_RATE_LIMIT_MIN_INTERVAL`, which makes it **the only candidate with an external justification**.

⚠️ **What dropping 60s cost.** 30s halves the key-rotation recovery window, but it also doubles how often the rate limit reopens — **twice the DoS amplification**. In a security context, do not read "the window got smaller" as "we tightened it".

⚠️ **The ceiling is not "one refetch per window" everywhere.** The five languages that implement the gate themselves (python · go · rust · php · ruby) allow exactly one forced refetch per interval. **Java and Kotlin allow two**: Nimbus's `RateLimitedJWKSetSource` opens each window with one request already credited, so two pass before it starts rejecting. Measured on both — tighten each SDK's own rate-limit test to `<= 1` and it reports `실제 2` for a flood of 8 unresolved key ids. Write "no more than two" in the JVM consumer docs; the two `<lang>/README.md` files said "more than one" until this was measured.

⚠️ **Do not "fix" the other seven — they were already right.** Node's test bounds hits at `<= 2`, which reads like the same defect, but tightening it to `== 1` **passes**: jose's cooldown allows exactly one. The five self-gating languages (python · go · rust · php · ruby) allow one by construction, and `.NET`'s README does not make the "one per interval" claim at all. Only the two Nimbus-backed SDKs overclaimed.

⚠️ **`.NET` refetches on a bad signature too — the other eight do not.** `Microsoft.IdentityModel` treats a *recoverable* signature failure (an invalid signature, or a signature key that cannot be found) as a key-rotation signal and calls `RequestRefresh()`. It is not "any failed validation" — an `aud`/`exp` rejection does not trigger it — and it can be disabled only by setting `RefreshInterval` to its maximum, which also disables genuine rotation refresh. What bounds the damage is the same 30-second interval. The per-language detail and the "do not assert zero refetches" rule live in `.claude/rules/dotnet.md`; the consumer-facing wording is in `SECURITY.md` and `dotnet/README.md`.

⚠️ **The interval is consumer-configurable in eight languages, not nine.** `.NET` exposes it on `JwtValidatorOptions` but not on `KeycloakConfig`, so a consumer going through the facade gets the 30-second default and cannot change it. Do not write "configurable in all nine".

**`clockSkew` (the `exp`/`nbf` tolerance on a JWT) is the same invariant and is likewise 30 seconds** — if it grows in one language, expired tokens live longer in that language alone.

Change either one **in all nine at once**. The guard is `scripts/test/test-security-defaults.sh`, which inspects the code, the docs and the secondary definition sites.

⚠️ These values also have a **per-language ceiling** — on Java and Kotlin they must stay below the Nimbus cache TTL (`.claude/rules/java.md` · `kotlin.md`). Not repeated here: that would create a second definition site.

## Secret memory hygiene — it has a boundary (do not oversell it)

⚠️ **This is not an end-to-end erasure guarantee.** Java's `KeycloakConfig` holds the secret as a `char[]` (defensive copies), but the libraries underneath — Nimbus `Secret` and the admin client, Python's `str` — require a `String`, so **at the point of use it is copied into a `String` that cannot be erased**. The `char[]` is defence in depth, nothing more.

PHP and Ruby cannot do it at all at the language level (`.claude/rules/php.md` · `.claude/rules/ruby.md` respectively).

So **do not write "secrets are erased from memory" in consumer documentation.** Overselling this class makes a consumer skip the mitigations that actually work — short TTLs, process isolation.
