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

The detail behind the security gotcha stubs in the root `CLAUDE.md`. **A security fact that applies to only one language does not live here** — that belongs in `.claude/rules/<lang>.md`. What lives here is only what the nine must move **together**, so changing one language alone is itself the defect. Hence `paths:` lists all nine directories — whichever you touch, this file comes with it.

## Aligned defaults — JWKS minimum refetch interval and `clockSkew` (both 30s)

⚠️ **The JWKS minimum refetch interval defaults to 30 seconds in all nine languages** (aligned 2026-07-31, when it was split 10/30/60 and Ruby hit the IdP six times as often as Python). 30s equals Nimbus's `DEFAULT_RATE_LIMIT_MIN_INTERVAL`, which makes it **the only candidate with an external justification**.

⚠️ **What dropping 60s cost.** 30s halves the key-rotation recovery window, but also doubles how often the rate limit reopens — **twice the DoS amplification**. Do not read "the window got smaller" as "we tightened it".

⚠️ **The ceiling is not "one refetch per window" everywhere.** The five languages that gate it themselves (python · go · rust · php · ruby) allow exactly one. **Java and Kotlin allow two** — Nimbus's `RateLimitedJWKSetSource` opens each window with one request already credited. To reproduce: tighten each SDK's own rate-limit test to `<= 1` and it reports `실제 2` for a flood of 8 unresolved key ids. The JVM consumer docs must say "no more than two".

⚠️ **Do not "fix" the other seven — they were already right.** Node's test bounds hits at `<= 2`, which reads like the same defect, but tightening it to `== 1` **passes** (jose's cooldown allows exactly one). `.NET`'s README never makes the claim. Only the two Nimbus-backed SDKs overclaimed.

⚠️ **Every count above is WARM-cache only — the 30s gate never sees the initial load**, because it sits on the *forced* (unresolved-kid) path, which needs a populated cache. Probe (2026-09-04 · cold cache · JWKS 503 · 20 validations · IdP requests) **before → after**: rust·go·python·php·node·ruby all **20→1**; **dotnet 40→2** (two requests per validation there, so one window costs two). Healthy controls (20 forced) stayed 1-4. ⚠️ **java·kotlin were NOT measured** (Nimbus owns their fetch) — `jwks-cold-cache-ungated` stays open for those two.

**The fix, in all seven** (reference: `ruby/lib/keycloak_sdk/jwks_store.rb`): back off *failed* fetches — 0.2s doubling to a 5s cap, jitter ×[0.5, 1.0) — and inside the window fail immediately **without touching the IdP**. Four rules, each paid for by measurement: (1) ⚠️ **never reuse the 30s here** — one transient 503 would mean "no token validates for 30s", worse than the defect; (2) ⚠️ **never sleep** — pacing retries is the consumer's job, not a library's; (3) ⚠️ **success resets the counter**, or a long-lived process stays pinned at the cap; (4) ⚠️ **a warm-cache unresolved-kid rejection is not a fetch failure** — counting it lets a forged-kid flood raise the backoff and block legitimate tokens (node checks `remote.jwks() === undefined` for exactly this).

⚠️ **Rust needed one more thing** — its cold load also sat outside the single-flight lock (`.claude/rules/rust.md`).

⚠️ **`.NET` refetches on a bad signature too — the other eight do not.** `Microsoft.IdentityModel` reads a *recoverable* signature failure as a key-rotation signal and calls `RequestRefresh()` (an `aud`/`exp` rejection does not); disabling it means giving up genuine rotation refresh. The same 30-second interval is what bounds it. Detail and the "do not assert zero refetches" rule: `.claude/rules/dotnet.md`; consumer wording: `SECURITY.md` and `dotnet/README.md`.

⚠️ **The interval is consumer-configurable in eight languages, not nine.** `.NET` exposes it on `JwtValidatorOptions` but not on `KeycloakConfig`, so a consumer going through the facade gets the 30-second default and cannot change it. Do not write "configurable in all nine".

**`clockSkew` (the `exp`/`nbf` tolerance on a JWT) is the same invariant and is likewise 30 seconds** — if it grows in one language, expired tokens live longer in that language alone.

Change either one **in all nine at once**. The guard is `scripts/test/test-security-defaults.sh`, which inspects the code, the docs and the secondary definition sites.

⚠️ These values also have a **per-language ceiling** — on Java and Kotlin they must stay below the Nimbus cache TTL (`.claude/rules/java.md` · `kotlin.md`). Not repeated here: that would create a second definition site.

## Secret memory hygiene — it has a boundary (do not oversell it)

⚠️ **This is not an end-to-end erasure guarantee.** Java's `KeycloakConfig` holds the secret as a `char[]` (defensive copies), but the libraries underneath — Nimbus `Secret`, the admin client, Python's `str` — require a `String`, so **at the point of use it is copied into a `String` that cannot be erased**. Defence in depth, nothing more. PHP and Ruby cannot do it at all at the language level (`.claude/rules/php.md` · `ruby.md`).

So **do not write "secrets are erased from memory" in consumer documentation.** Overselling makes a consumer skip the mitigations that work — short TTLs, process isolation.
