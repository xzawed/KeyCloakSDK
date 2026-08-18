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

⚠️ **What dropping 60s cost.** 30s halves the key-rotation recovery window, but it also loosens the rate-limit ceiling from once per 60s to once per 30s — **twice the DoS amplification**. In a security context, do not read "the window got smaller" as "we tightened it".

**`clockSkew` (the `exp`/`nbf` tolerance on a JWT) is the same invariant and is likewise 30 seconds** — if it grows in one language, expired tokens live longer in that language alone.

Change either one **in all nine at once**. The guard is `scripts/test/test-security-defaults.sh`, which inspects the code, the docs and the secondary definition sites.

⚠️ These values also have a **per-language ceiling** — on Java and Kotlin they must stay below the Nimbus cache TTL (`.claude/rules/java.md` · `kotlin.md`). Not repeated here: that would create a second definition site.

## Secret memory hygiene — it has a boundary (do not oversell it)

⚠️ **This is not an end-to-end erasure guarantee.** Java's `KeycloakConfig` holds the secret as a `char[]` (defensive copies), but the libraries underneath — Nimbus `Secret` and the admin client, Python's `str` — require a `String`, so **at the point of use it is copied into a `String` that cannot be erased**. The `char[]` is defence in depth, nothing more.

PHP and Ruby cannot do it at all at the language level (`.claude/rules/php.md` · `.claude/rules/ruby.md` respectively).

So **do not write "secrets are erased from memory" in consumer documentation.** Overselling this class makes a consumer skip the mitigations that actually work — short TTLs, process isolation.
