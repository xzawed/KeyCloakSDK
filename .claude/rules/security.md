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
<!-- doc-budget: max-bytes=5902 -->
<!-- 5620 → 5902 (2026-10-05): 래칫 조건 (1) — 증가분이 **기계 검증을 사 온다.** 새 「Token-response cap」
     줄은 두 번 대조된다 — 아홉 선언이 1048576 인가(`test-security-defaults.sh` 1e 축)와 이 줄의 수가
     `SD_TOKEN_CAP` 인가(같은 파일 4절 소유자 축, 값 대조군 포함). 인상분(+282B)은 그 한 문단보다 작다.
     **교환** — 같은 커밋이 거짓 둘을 지웠다: 「자체 게이트는 다섯(python·go·rust·php·ruby)」(node 가 여섯째다)
     과 「node 는 jose 의 쿨다운이 한 번을 허용한다」(node 는 `cooldownDuration: 0` 이고 자기 창을 시도할 때
     찍는다 — `node/src/jwt.ts` `remoteJwksWithRefetchWindow`). 새 재조회 규칙 줄은 기계 대조가 없고 행동은
     언어별 시험이 진다(python `test_jwks_window_cancellation.py` · java `JwksCancellationTest` 등).
     ⚠️ **압축을 먼저 했다** — 초안 적재 6457B(+844) → 5902B. 지운 것은 세 부류뿐이다: 경위(2026-07-31 정렬 ·
     10/30/60 · 6배 — 가드 머리가 소유), 다른 문장이 이미 말하는 반복(「Do not read …」 · 「Only the two
     Nimbus-backed SDKs overclaimed」 · 「Do not write "configurable in all nine"」 · 「Not repeated here …」 —
     마지막 것은 루트 CLAUDE.md 의 「같은 사실을 두 곳에 적지 않는다」가 상주한다), 한 언어 사실(jose 의
     `cooldownDuration` — 이 파일 머리가 `<lang>.md` 로 보내라는 부류). 재현 명령·수치·판정 이유는 전부 남겼다. -->
<!-- 5500 → 5620 (2026-09-06): 래칫 조건 (1) — 증가분이 **기계 검증을 사 온다.** 이 절은
     「java·kotlin 은 NOT measured」라고 적고 있었고, 그것이 열린 항목의 근거였다. 이제 쟀고
     (20 검증 → 요청 2) 그 값을 `JwksColdCacheOutageTest`(두 JVM 레인)가 대조군과 함께 고정한다.
     ⚠️ 압축을 먼저 했다 — 초안 355B 를 113B 로 낮춘 뒤 남은 만큼만 올렸다. 그 아래로 깎으면
     「왜 유계인가」(Nimbus 가 source 를 rate-limit 한다)가 사라져 다음 세션이 다시 연다.
     ⚠️ 이 인상은 사람 리뷰 대상이다 — PR 본문에 명시했다. -->
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

Only what the nine must move **together** lives here — changing one language alone is itself the defect; a one-language security fact belongs in `.claude/rules/<lang>.md`. `paths:` lists all nine directories, so this file loads with any of them.

## Aligned defaults — JWKS minimum refetch interval and `clockSkew` (both 30s)

⚠️ **The JWKS minimum refetch interval defaults to 30 seconds in all nine languages.** 30s equals Nimbus's `DEFAULT_RATE_LIMIT_MIN_INTERVAL`, which makes it **the only candidate with an external justification**.

⚠️ **Dropping 60s was a trade, not a tightening:** 30s halves the key-rotation recovery window but doubles how often the rate limit reopens — **twice the DoS amplification**.

⚠️ **The ceiling is not "one refetch per window" everywhere.** The six that gate it themselves (python · go · rust · php · ruby · node) allow exactly one. **Java and Kotlin allow two** — Nimbus's `RateLimitedJWKSetSource` opens each window with one request already credited. To reproduce: tighten each SDK's own rate-limit test to `<= 1` and it reports `실제 2` for a flood of 8 unresolved key ids. The JVM consumer docs must say "no more than two".

⚠️ **Do not "fix" the other seven — they were already right.** Node's first test bounds hits at `<= 2`, which reads like the same defect, but its per-window test pins exactly one. `.NET`'s README never makes the claim.

⚠️ **Stamp the forced-refetch window when the fetch is decided, not when it succeeds** — a success-only stamp leaves it open through an outage. So a 503 spends the window too, and a stamped fetch must run to completion under the SDK's own HTTP timeouts, whatever the caller cancels; **never roll the stamp back on cancellation** (python: each cancelled forged-kid validation then cost an IdP request — 10 vs 1).

⚠️ **Every count above is WARM-cache only — the 30s gate never sees the initial load**, because it sits on the *forced* (unresolved-kid) path, which needs a populated cache. Probe (2026-09-04 · cold cache · JWKS 503 · 20 validations · IdP requests) **before → after**: rust·go·python·php·node·ruby all **20→1**; **dotnet 40→2** (two requests per validation there, so one window costs two). Healthy controls (20 forced) stayed 1-4. ⚠️ **java·kotlin were already at 2 and were not changed** (2026-09-06): Nimbus rate-limits the *source*, so it covers the cold load the other seven missed. `JwksColdCacheOutageTest` pins both lanes — control interval 0 → **20**.

**The fix, in all seven** (reference: `ruby/lib/keycloak_sdk/jwks_store.rb`): back off *failed* fetches — 0.2s doubling to a 5s cap, jitter ×[0.5, 1.0) — and inside the window fail immediately **without touching the IdP**. Four rules, each measured: (1) ⚠️ **never reuse the 30s here** — one transient 503 would mean "no token validates for 30s", worse than the defect; (2) ⚠️ **never sleep** — pacing retries is the consumer's job, not a library's; (3) ⚠️ **success resets the counter**, or a long-lived process stays pinned at the cap; (4) ⚠️ **a warm-cache unresolved-kid rejection is not a fetch failure** — counting it lets a forged-kid flood raise the backoff and block legitimate tokens (node checks `remote.jwks() === undefined` for exactly this).

⚠️ **Rust needed one more thing** — its cold load also sat outside the single-flight lock (`.claude/rules/rust.md`).

⚠️ **`.NET` refetches on a bad signature too — the other eight do not.** `Microsoft.IdentityModel` reads a *recoverable* signature failure as a key-rotation signal and calls `RequestRefresh()` (an `aud`/`exp` rejection does not); disabling it means giving up genuine rotation refresh. The same 30-second interval is what bounds it. Detail and the "do not assert zero refetches" rule: `.claude/rules/dotnet.md`; consumer wording: `SECURITY.md` and `dotnet/README.md`.

⚠️ **The interval is consumer-configurable in eight languages, not nine.** `.NET` exposes it on `JwtValidatorOptions` but not on `KeycloakConfig`, so a consumer going through the facade gets the 30-second default and cannot change it.

**`clockSkew` (the `exp`/`nbf` tolerance on a JWT) is the same invariant and is likewise 30 seconds** — if it grows in one language, expired tokens live longer in that language alone.

Change either one **in all nine at once**. The guard is `scripts/test/test-security-defaults.sh`, which inspects the code, the docs and the secondary definition sites.

⚠️ These values also have a **per-language ceiling** — on Java and Kotlin they must stay below the Nimbus cache TTL (`.claude/rules/java.md` · `kotlin.md`).

## Token-response cap

⚠️ **Token-endpoint and introspection response bodies are capped at 1,048,576 bytes in all nine** — ≈16× the longest Bearer Keycloak 26.6 accepts by default (65,459 B; one more is HTTP 431), so it refuses no token a default server accepts. Move all nine at once; guard: axis 1e of `scripts/test/test-security-defaults.sh`.

## Secret memory hygiene — it has a boundary (do not oversell it)

⚠️ **This is not an end-to-end erasure guarantee.** Java's `KeycloakConfig` holds the secret as a `char[]` (defensive copies), but the libraries underneath — Nimbus `Secret`, the admin client, Python's `str` — require a `String`, so **at the point of use it is copied into a `String` that cannot be erased**. Defence in depth, nothing more. PHP and Ruby cannot do it at all at the language level (`.claude/rules/php.md` · `ruby.md`).

So **do not write "secrets are erased from memory" in consumer documentation.** Overselling makes a consumer skip the mitigations that work — short TTLs, process isolation.
