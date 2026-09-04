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
<!-- doc-budget: max-bytes=5500 -->
<!--
  4824 → 5500 (2026-09-04). 래칫 인상 사유는 규약 (2) — **이 문서의 역할이 넓어졌다.**
  여기까지 이 파일은 「아홉 언어가 함께 움직여야 하는 값」만 담았다. 이제 그 값들이 **캐시가 찬
  뒤에만 성립한다**는 실측 조건을 함께 담는다. 그 조건이 없으면 27·29행의 숫자가 무조건적인
  보장으로 읽힌다(실제로 그렇게 읽혀 여덟 README 가 거짓을 적었다).

  압축으로 지불하려 했고 일부는 지불했다 — 29행이 27행의 다섯 언어 목록을 그대로 반복하던
  것을 지웠다. 남은 초과분은 **프로브 레시피와 일곱 숫자**다. 이것을 지우면 다음 세션이 판정을
  재현할 수 없고, 그때는 「압축이 아니라 손실」이라는 것이 이 저장소의 명문 규칙이다.
  ⚠️ 사람이 이 판정에 동의하지 않는다면 되돌릴 자리는 31행 한 문단이다.
-->

# Cross-language security invariants

The detail behind the security gotcha stubs in the root `CLAUDE.md`. **A security fact that applies to only one language does not live here** — that belongs in `.claude/rules/<lang>.md`. What lives here is only what the nine languages must move **together**, so changing one language alone is itself the defect.

That is why `paths:` lists all nine language directories — whichever one you touch, this file comes with it.

## Aligned defaults — JWKS minimum refetch interval and `clockSkew` (both 30s)

⚠️ **The JWKS minimum refetch interval defaults to 30 seconds in all nine languages** (aligned 2026-07-31). Before that it was split three ways — 10, 30 and 60 seconds — a **by-product** of PR #71 making the value configurable while leaving each language's hardcoded value in place (on the same burst of forged `kid`s, Ruby hit the IdP six times as often as Python). 30s equals Nimbus's `DEFAULT_RATE_LIMIT_MIN_INTERVAL`, which makes it **the only candidate with an external justification**.

⚠️ **What dropping 60s cost.** 30s halves the key-rotation recovery window, but it also doubles how often the rate limit reopens — **twice the DoS amplification**. In a security context, do not read "the window got smaller" as "we tightened it".

⚠️ **The ceiling is not "one refetch per window" everywhere.** The five languages that implement the gate themselves (python · go · rust · php · ruby) allow exactly one forced refetch per interval. **Java and Kotlin allow two**: Nimbus's `RateLimitedJWKSetSource` opens each window with one request already credited, so two pass before it starts rejecting. Measured on both — tighten each SDK's own rate-limit test to `<= 1` and it reports `실제 2` for a flood of 8 unresolved key ids. Write "no more than two" in the JVM consumer docs; the two `<lang>/README.md` files said "more than one" until this was measured.

⚠️ **Do not "fix" the other seven — they were already right.** Node's test bounds hits at `<= 2`, which reads like the same defect, but tightening it to `== 1` **passes**: jose's cooldown allows exactly one. `.NET`'s README does not make the "one per interval" claim at all. Only the two Nimbus-backed SDKs overclaimed.

⚠️ **Every count above is WARM-cache only — no gate covers the initial load.** Probe (2026-09-04): cold cache · JWKS 503 · 20 validations · requests reaching the IdP → **rust 20 · go 20 · python 20 · php 20 · node 20 · ruby 20 · dotnet 40**; controls (healthy, 20 forced) 1–4, so the counter was sound. Cause: the gate sits only on the *forced* (unresolved-kid) path, which needs a populated cache — while a fetch keeps failing the cache stays empty and every validation retries. ⚠️ **java·kotlin NOT measured** (Nimbus owns their fetch). ⚠️ **Do not gate the cold load at the same 30s** — one transient 503 then means "no token validates for 30s"; use a negative cache with short backoff on *failed* fetches. Item: `jwks-cold-cache-ungated`.

⚠️ **`.NET` refetches on a bad signature too — the other eight do not.** `Microsoft.IdentityModel` treats a *recoverable* signature failure (an invalid signature, or a signature key that cannot be found) as a key-rotation signal and calls `RequestRefresh()`. It is not "any failed validation" — an `aud`/`exp` rejection does not trigger it — and it can be disabled only by setting `RefreshInterval` to its maximum, which also disables genuine rotation refresh. What bounds the damage is the same 30-second interval. The per-language detail and the "do not assert zero refetches" rule live in `.claude/rules/dotnet.md`; the consumer-facing wording is in `SECURITY.md` and `dotnet/README.md`.

⚠️ **The interval is consumer-configurable in eight languages, not nine.** `.NET` exposes it on `JwtValidatorOptions` but not on `KeycloakConfig`, so a consumer going through the facade gets the 30-second default and cannot change it. Do not write "configurable in all nine".

**`clockSkew` (the `exp`/`nbf` tolerance on a JWT) is the same invariant and is likewise 30 seconds** — if it grows in one language, expired tokens live longer in that language alone.

Change either one **in all nine at once**. The guard is `scripts/test/test-security-defaults.sh`, which inspects the code, the docs and the secondary definition sites.

⚠️ These values also have a **per-language ceiling** — on Java and Kotlin they must stay below the Nimbus cache TTL (`.claude/rules/java.md` · `kotlin.md`). Not repeated here: that would create a second definition site.

## Secret memory hygiene — it has a boundary (do not oversell it)

⚠️ **This is not an end-to-end erasure guarantee.** Java's `KeycloakConfig` holds the secret as a `char[]` (defensive copies), but the libraries underneath — Nimbus `Secret` and the admin client, Python's `str` — require a `String`, so **at the point of use it is copied into a `String` that cannot be erased**. The `char[]` is defence in depth, nothing more.

PHP and Ruby cannot do it at all at the language level (`.claude/rules/php.md` · `.claude/rules/ruby.md` respectively).

So **do not write "secrets are erased from memory" in consumer documentation.** Overselling this class makes a consumer skip the mitigations that actually work — short TTLs, process isolation.
