<!-- doc-status: active -->

# 잔여작업 등록부 — 2026-09-03 전수 감사 후속

**이 문서가 답하는 것 하나** — 「감사가 남긴 것 중 무엇이 아직 열려 있고, 각각을 **어떤 명령으로** 닫았다고 말할 수 있는가」.

## 왜 이 문서가 있는가

2026-09-03 전수 감사(`main` @ `deb2bbd`)는 **아무것도 커밋하지 않았다.** 원장은 `~/.claude/projects/` 아래에만 있었고 git 이력·저장소 파일 어디에도 흔적이 없었다 — 그 파일이 사라지면 209건을 통째로 잃는 상태였다. 같은 일이 이미 한 번 있었다(`docs/superpowers/plans/` 아카이브 후 지도가 가리키는 경로가 사라졌다).

그래서 **등록부를 저장소 안으로 옮긴다.** 이 문서가 열린 항목의 진실 원천이고, 항목이 전부 닫히면 `doc-status` 를 `complete` 로 내리고 아카이브 태그로 내린 뒤 지도 §3 에서 지운다.

## 규모

| | |
|---|---|
| 원장 고유 발견 | **209** (conf 12 · pend 37 · weak 3 · low 157) — 감사 시점 전부 미수정 |
| 작업 패키지 | **151** (원장 유래 104 · 원장 밖 46 · 재스캔 신규 1) — 열림 **132** · 닫힘 **19** |
| 심각도 | high 27 · medium 76 · low 47 |
| 작업량 | S 68 · M 70 · L 12 |

⚠️ **기각 11건은 이 등록부에 없다 — 의도적이다.** 게시 잡의 `environment:` 부재 · `workflow_dispatch` 우회 · admin-capability D열 무보호는 문서화된 설계이거나 되살릴 조건이 적힌 기각이다. 착수 전 [기각 레지스트리](../../governance/rejected.md)를 먼저 읽는다.

⚠️ **되살리면 안 되는 것 둘.** `harness-consume-pin-unsupported` 의 `scripts/check-versions.mjs` 확장분과 `public-registry-install-smoke` 의 `harness/install/install-verify.sh:44` 는 각각 기각된 자리다. `rust-rustdoc-jwks-refetch-says-60` 은 **주석 문자열만** 고친다 — 두 줄 아래 `with_jwks_min_refetch_secs` 에 0 강제를 넣으면 또 다른 기각을 되살린다.

## 닫힌 항목 (2026-09-03)

권장 우선순위 1~5번과 그 후속을 밟아 18건이 `main` 에 들어갔다. 체크박스만 두면 「어떻게 닫혔는지」가
사라지므로 PR 을 함께 적는다.

⚠️ **닫을 때마다 원장의 「범위」를 먼저 의심한다.** 2026-09-04 재검증에서 손댄 7항목이 **전부** 범위를
틀리게 적고 있었고, 방향이 양쪽이었다 — 축소(`jwks-cold-cache-ungated` 1→7언어 · `boundary-…` 2→6 ·
`selftest-…` 1→26)뿐 아니라 **과장**(`python-sync-admin-close-noop` 의 「영영 안 닫힌다」)도 있었다.
지목 줄이 틀린 것도 둘이다(`kotlin-ci.yml:70` 은 `java-version`, `boundary-…` 의 Ruby 줄은 clean).

| PR | 닫은 항목 | 한 줄 |
|---|---|---|
| #381 | `post-1-0-registry-missing` | 이 등록부 자체. 가드가 실제로 보는지 A/B 로 확인했다(파일을 옮기면 `check-docs` 가 세 경로로 실패) |
| #380 | `go-admin-lane-bypasses-redirect-ban` · `go-postform-treats-3xx-as-success` · `go-jwks-fetch-ignores-status-and-empty-keyset` · `jwks-fetch-ignores-http-status` | 백채널 3xx 가 SSRF 와 fail-open 을 함께 열고 있었다. ⚠️ 리다이렉트를 막자 gocloak 이 302 에 `("", nil)` 을 돌려주는 **두 번째 결함**이 드러났다(독립 검증 레그가 착수 전에 지목) |
| #382 | `dotnet-authzrequest-tostring-leaks-pkce-verifier` · `authorization-request-verifier-unmasked` · `php-default-serializers-bypass-masking` | PKCE verifier 와 토큰이 기본 직렬화기로 샜다. 가리는 범위는 Rust `Debug` impl 과 동형으로 맞췄다 |
| #383 | `ruby-admin-path-segment-unescaped` | `../` 가 경로를 재작성하고 공백이 stdlib 예외를 냈다. 부류 재스캔이 `@realm` 20곳을 더 찾아 총 35곳 |
| #385 | `ci-perms-flow-style-permissions-bypass` · `check-coverage-arg-parsing-silently-disarms-gate` · `guard-neutering-wiring-unprotected` | 가드 셋이 「거짓말하는 방향」으로 고장나 있었다 — 임계값이 사라지고, 표기 하나로 상승이 안 보이고, `continue-on-error` 로 무력화됐다 |
| #387 | (교차가드 신설) · `authorization-request-verifier-unmasked` 의 **Go 절반** | 마스킹 **바닥 계약**(기본 문자열/디버그 표현이 비밀을 `***` 로 낸다)을 9언어 축으로 켰다. ⚠️ #382 가 그 항목을 닫았다고 표시했으나 Go·Node 중 **Node 만** 고쳤었다 — Go 는 `TokenSet.String()` 이 포인터 리시버라 값이 새고 `AuthorizationRequest` 에는 String 이 없었다(프로브 실측). 기각돼 있던 `go-tokenset-json-unmasked` 는 **기각 사유가 지목한 대안**(`slog.LogValuer`)으로 구현했다 |
| #388 | (런타임 커버리지) | 하한을 건드리지 않고 위로 넓혔다 — php **8.5**(composer.json 이 이미 약속한 범위) · python 3.14 · node 26 · ruby 4.0 · JDK 25 · .NET SDK 10. ⚠️ CI 가 두 가지를 답했다: ruby 4.0 은 **SDK 가 아니라 테스트**가 `CGI.parse` 제거로 깨졌고, go 1.27 은 `staticcheck` 가 못 읽어 레그를 뺐다(되살릴 조건 워크플로 주석) |
| #389 | `runtime-eol-support-window` | JVM 소비자 하한 21 → **17**. 2026-07-03 의 반대 판정을 되돌린 것이고, **그 커밋이 스스로 「소스 무변경」이라 적어** 21 이 기술적 필요가 아니었음을 증명한다. 가드 둘을 함께 세웠다 — 산출물 바이트코드 하한(`check-jvm-bytecode-floor.mjs`)과 `check-docs` 의 추출기(`jvmToolchain` → `JvmTarget`) |
| #395 | (dependabot 정책) | rust `keycloak` 의 마이너 상향 차단 — 그 숫자는 semver 가 아니라 **대상 서버 라인**이다. ⚠️ #394 의 「실제 26.6 서버 integration」이 **초록이었는데도** 받지 않았다(그 초록은 테스트가 밟는 경로까지만 증명한다) |
| #397 | `rust-logout-ignores-http-status` | `reqwest` 의 `send()` 는 전송 실패에만 `Err` 를 줘서 400/401/404 가 `Ok(())` 였다 — 세션이 살아있는데 호출자는 로그아웃 성공으로 믿는다. ⚠️ 지운 주석이 「다른 SDK와 동형」이라 적고 있었으나 자매 여덟을 읽으면 **Rust 만 혼자**였다. 상태코드를 특별대우하지 않는다(404 를 삼키면 오설정이 안 보이고, 400 을 통과시키면 진짜 클라이언트 오류도 함께 통과) |
| #398 | `rust-rustdoc-jwks-refetch-says-60` · `python-config-comment-says-60` | 주석 3곳이 JWKS 기본값을 60 이라 말했다(실제 30). rust 둘은 **공개 rustdoc** 이라 docs.rs 에 렌더된다. ⚠️ 문서 축이 `SD_DOCS`(README·docs)만 봐서 **소스 파일이 목록에 없었다** — 아홉 언어 소스 전체를 훑는 2b 축을 세웠다(테스트 제외: `JwtValidatorTest.kt:515` 의 "캐시 TTL(기본 5분)" 이 실측 오탐) |
| #399 | `php-tokenset-null-expiry-treated-as-fresh` (+ **Ruby**) | 만료 시각 미상을 「안 만료됨」으로 읽었다. ⚠️ 원장은 「PHP만」이라 적었으나 재스캔 결과 **7 fail-safe / 2 fail-open**. PHP 는 provider 캐시가 죽은 토큰을 무한 재사용하고, Ruby 는 공개 API 만 틀리다. ⚠️ **두 언어 다 테스트가 결함을 의도로 고정**하고 있었다(`…AndNeverExpired` · `"is never expired"`) |
| #400 | `java-kotlin-jwks-response-size-unbounded` | SSRF 하드닝용 리트리버를 주입하는 **행위 자체가** Nimbus 의 51200 상한을 지웠다(바이트코드: 2-arg 가 `iconst_0`, 빌더는 `ldc 51200`). `JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT` 참조로 복원. ⚠️ 재스캔에서 **Go 가 이미 갖고 있었다** — 주석이 출처를 그 Nimbus 상수라 밝힌다 |

곁가지로 **#384**(php API 게이트 정밀도)가 필요했다 — `php-semver-checker` 가 `implements`
절 하나에 오탐을 내고 `final` 클래스의 메서드 추가를 파괴로 세어 #382 를 막았다. 사람 판정으로
게이트에 정밀도를 넣었고, 면제는 전부 **소스로 반증 가능한 술어**다.

⚠️ **되돌린 것 하나** — Ruby admin 리소스 셋을 모듈로 추출하는 리팩터를 비차단 SonarCloud 중복
때문에 넣었다가, 그것이 **required 인 `doc-facts` 를 깨뜨려**(가드가 「리소스 하나 = 파일 하나」를
전제한다) 되돌렸다. 그 중복은 아직 남아 있고 비차단이다 — 정리 방법 둘은 `repo-settings-ssot-gap`
옆에 적지 않고 여기 남긴다: (a) 리팩터 + 두 가드를 모듈 인지형으로, (b) `sonar.cpd.exclusions`.

## 착수 순서

1. **이 등록부를 저장소에 남긴다** — 나머지 149개의 전제.
2. **Go 전송 하드닝** — 게시본에서 활성인 SSRF + fail-open. (PR #380)
3. **시크릿 평문 노출**(.NET·Node·PHP) — 소비자 손에 이미 가 있다. ⚠️ 같은 결함의 Go 판이 기각돼 있어, 교차언어 가드를 켜기 전에 그 비대칭을 사람이 판정해야 한다.
4. **Ruby admin 경로 무이스케이프** — 실행으로 재현됨. 참조 구현이 저장소 안에 있다(`go/admin_realms.go` 의 `url.PathEscape`).
5. **가드 무력화 3종** — 잠복이나 S 이고, 자가테스트가 이미 배선돼 있어 가장 싸다.
6. **런타임 지원 창** — 기한이 붙은 유일한 항목. 코드 수정이 아니라 **소비자 절단 여부의 사람 판정**이다.

⚠️ 5번을 1순위로 올리자는 판단이 인벤토리 과정에서 나왔으나(「가드가 거짓말하면 이후 검증이 전부 무효」), 독립 검증 레그가 기각했고 실측이 그 기각을 지지했다 — 두 가드 결함은 **잠복**이다(실 호출부는 공백형 인자를 쓰고, 저장소에 플로우 표기 `permissions` 는 없다). 「무효」는 과장이다.

## 읽는 법

각 항목은 근본원인 하나에 대응한다 — 같은 결함이 여러 줄·여러 언어에 걸친 것은 한 줄로 접혀 있다. `[H/M/L]` 은 심각도, `[S/M/L]` 은 작업량. **가드 없는 수정은 완료가 아니다** — 항목을 닫을 때 「다시 깨지면 CI 가 어떻게 잡는가」를 함께 남긴다([작업 프로세스](../../governance/process.md) ⑤⑥).

전체 근거·수정안·동반 가드·검증 명령은 기계용 원장에 있다: `ledger-dedup.json`(원장 209건) · 인벤토리 산출물(패키지 150건). 이 문서는 **무엇이 열려 있는가**만 소유한다.

---

## A. 확정 결함 — 12건 (열림 2)

3렌즈 만장일치 + 오케스트레이터 재실행 확인.

### 확정 + weak — 12

- [x] `dotnet-authzrequest-tostring-leaks-pkce-verifier` **[H/S]** .NET AuthorizationRequest가 positional record라 ToString이 PKCE code_verifier를 그대로 찍는다 · `dotnet/src/Xzawed.Keycloak.Sdk/Tokens.cs:66`
- [x] `go-admin-lane-bypasses-redirect-ban` **[H/M]** Go admin 레인이 SDK의 리다이렉트 금지를 통째로 우회한다 — client_secret을 실은 로그인이 3xx를 따라간다 · `go/admin.go:47`
- [x] `rust-logout-ignores-http-status` **[H/S]** Rust logout이 응답 상태를 보지 않아 400/401/404에도 Ok(())를 돌려준다 — 「다른 SDK와 동형」 주석은 거짓 · `rust/src/auth.rs:236`
- [x] `ci-perms-flow-style-permissions-bypass` **[H/S]** 플로우 스타일 `permissions: {contents: write}`가 CI 권한 가드에 통째로 안 보인다 — 실측으로 「상승 1건」이 0건이 됐다 · `scripts/check-ci-permissions.mjs:100`
- [x] `rust-rustdoc-jwks-refetch-says-60` **[M/S]** Rust 공개 API의 doc 주석 두 곳이 JWKS 최소 재조회 기본값을 60초라 말한다(코드는 30) — 문서 축이 소스 주석을 안 본다 · `rust/src/config.rs:18`
- [x] `java-kotlin-jwks-response-size-unbounded` **[M/S]** Java·Kotlin의 NoRedirectResourceRetriever가 Nimbus의 51200바이트 상한을 지웠다 — JWKS 응답이 무제한으로 메모리에 들어온다 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/NoRedirectResourceRetriever.java:24`
- [x] `php-tokenset-null-expiry-treated-as-fresh` **[M/S]** ⚠️ **원장이 「PHP만」이라 적었으나 Ruby 도 같았다**(실측: 9개 중 7 fail-safe / 2 fail-open). 만료 시각 미상을 「만료 안 됨」으로 읽어 PHP 는 client-credentials 캐시가 죽은 토큰을 영원히 재사용한다 · `php/src/Token/TokenSet.php:59` + `ruby/lib/keycloak_sdk/tokens.rb:21`
- [x] `go-jwks-fetch-ignores-status-and-empty-keyset` **[M/S]** Go JWKS fetch가 상태코드도 키 유무도 안 본다 — 오류 본문 JSON이 빈 키셋으로 파싱돼 캐시를 덮는다 · `go/jwt.go:167`
- [x] `check-coverage-arg-parsing-silently-disarms-gate` **[M/S]** check-coverage.mjs의 인자 파싱이 임계값을 조용히 0/NaN으로 만든다 — 실측으로 `--min-line=99`가 「임계 0/0」으로 통과했다 · `scripts/check-coverage.mjs:29`
- [x] `php-default-serializers-bypass-masking` **[M/S]** [weak·채택] PHP는 마스킹을 __toString에만 걸어 json_encode()가 accessToken·refreshToken·clientSecret을 원문으로 뱉는다 · `php/src/Token/TokenSet.php:9`
- [ ] `java-rules-close-scope-ambiguous` **[L/S]** [weak·채택] .claude/rules/java.md가 close()의 정리 범위를 java/README.md와 반대로 읽히게 적는다 · `.claude/rules/java.md:33`
- [ ] `auto-bump-manifest-crosscheck-skip` **[L/M]** [weak·보류] auto 범프 4개 언어의 매니페스트 대조 스킵 — 기각 근거가 유효하다(잔여는 버전 역행뿐) · `.github/workflows/dispatch-release.yml:194`

## B. 재검증 대상 — 26건 (열림 20)

3렌즈 통과, 원장은 개별 재실행을 하지 않았다. 이번 인벤토리에서 전량 파일 확인 — 기각 권고 0건.

### 재검증 · 언어 소스 — 15

- [x] `jwks-fetch-ignores-http-status` **[H/S]** JWKS fetch가 HTTP 상태 코드를 보지 않는다 — Go는 게이트웨이 오류 JSON으로 키 캐시가 오염된다 · `go/jwt.go:181`
- [x] `ruby-admin-path-segment-unescaped` **[H/M]** Ruby admin 5개 리소스가 경로 세그먼트를 무이스케이프 보간한다 — 엔드포인트 우회 + stdlib 예외 누출 · `ruby/lib/keycloak_sdk/admin/users.rb:18`
- [x] `go-postform-treats-3xx-as-success` **[H/S]** Go postForm이 3xx를 성공으로 읽는다 — Logout이 세션이 살아있는데 nil을 돌려준다 · `go/auth.go:210`
- [x] `jwks-cold-cache-ungated` **[M/M→재분류]** 콜드 캐시 JWKS 로드가 rate-limit 게이트 밖 · `rust/src/jwks.rs:61`
  - ⚠️ **범위 정정(2026-09-04 실측)**: 원장은 「rust · 여섯 README」라 적었으나 **7개 언어 전부**다(java·kotlin 은 Nimbus 덕에 예외). 각 언어에서 「콜드 캐시 + JWKS 엔드포인트 503 + 20회 시도」로 IdP 도달 요청을 셌다 — **rust 20 · go 20 · python 20 · php 20 · node 20 · ruby 20 · dotnet 40**(호출당 2). 대조군(정상 엔드포인트 + 강제 재조회 20회)은 전부 1~4로 유계라 계측기는 건전하다.
  - ⚠️ **부류가 다르다 — unknown-kid DoS 가 아니라 retry storm 이다.** 30초 게이트는 *캐시가 찬 뒤* 위조 kid 홍수를 막으려는 것이고 그 경로는 실제로 동작한다. 무제한이 되는 것은 **캐시가 빈 채 fetch 가 계속 실패할 때**뿐이다.
  - **닫힘(#403 ruby 참조구현 → 나머지 여섯).** 실패한 fetch 에 지수 백오프(0.2s → 상한 5s, jitter)를 걸고 창 안에서는 IdP 를 때리지 않고 즉시 실패시킨다(negative cache · **sleep 금지**). 재측정: rust·go·python·php·node·ruby **20→1**, dotnet **40→2**(그 레인은 검증당 2요청이라 한 창이 2다). 웜 대조군은 전부 불변.
  - ⚠️ **rust 는 두 번째 결함이 함께 드러났다** — 콜드 로드가 게이트 뮤텍스 **밖**이라 동시 첫 검증 20건이 요청 20건을 냈다. **정상(200) IdP 에서도** 그랬다(실측 20/20). 백오프만으로는 안 닫혔고, 게이트 락이 콜드 경로를 덮게 고쳤다(go 는 `singleflight`, ruby·python 은 락이 이미 있었다).
  - ⚠️ **node 는 「과잉 수정」이 실제로 통과할 뻔했다** — 진입부 `cold` 게이트와 실패 계수의 `jwks()===undefined` 검사가 **서로를 가려**, 어느 한쪽을 지워도 동작이 안 변해 변이검증이 양쪽 다 초록이었다. 중복을 지우고 검사를 하나로 만든 뒤에야 대조군이 결함을 잡는다. **중복 게이트는 변이검증을 공허하게 만든다.**
  - **재발 시 CI 가 잡는 자리**: 언어별 단위테스트(결함 1 + 대조군 2~3, 각 언어 레인) + 교차언어 대칭 가드 `scripts/test/test-security-defaults.sh` §1b2(일곱 언어의 상한 상수·잔여시간 계산 존재 · 훑은 수 7 대조군). 가드 3요건 실측: go 상한을 5→9초로 바꾸면 **1 failed**, 가드를 끄고 같은 변이면 **155 passed 0 failed**.
  - ⚠️ **이 항목의 범위는 측정된 일곱이고, 그 일곱은 전부 닫혔다.** java·kotlin 은 **애초에 측정된 적이 없다**(Nimbus 가 그들의 fetch 를 소유) — 「예외」와 「미측정」은 다른 주장이고, 원장은 그 둘을 섞어 적고 있었다. 미측정은 이 항목의 잔여가 아니라 **별개의 열린 질문**이므로 아래 `jvm-cold-cache-unmeasured` 로 분리했다.
- [ ] `jvm-cold-cache-unmeasured` **[M/S · 신규 2026-09-05]** java·kotlin 의 콜드 캐시 + IdP 장애 동작이 한 번도 측정되지 않았다 — 나머지 일곱은 20→1 로 닫혔는데 이 둘만 미지수다 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/JwtValidator.java`
  - 재는 법은 이미 있다: 나머지 일곱에 쓴 프로브(요청을 세는 로컬 HTTP 서버 · JWKS 503 · 20회 검증)를 Nimbus `JWKSource` 에 물리면 된다. **먼저 재고, 그 다음에 고칠지 정한다** — Nimbus 의 `RateLimitedJWKSetSource`·`CachingJWKSetSource` 조합이 이미 막고 있을 수 있고, 그렇다면 고칠 것이 없다.
  - ⚠️ 결과가 「이미 유계」로 나오면 그 사실을 `.claude/rules/security.md` 에 적어 다음 세션이 다시 묻지 않게 한다(지금은 "NOT measured" 라고만 적혀 있다).
- [ ] `openid-scope-fallback-empty-only` **[M/S]** openid 스코프 폴백이 "비었을 때"만 걸려 Nimbus IllegalArgumentException이 공개 API로 샌다 (Java·Kotlin) · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:81`
- [ ] `boundary-exception-conversion-incomplete` **[M/M]** 경계 변환의 catch 목록이 하위 라이브러리가 실제로 던지는 예외 집합보다 좁다 · `kotlin/src/main/kotlin/io/github/xzawed/keycloak/jwt.kt:91`
  - ⚠️ **범위 정정**: 원장은 「Kotlin·Ruby」 2개라 적었으나 **Java·Node·.NET 을 빠뜨렸다**. ⚠️ 그리고 **원장이 지목한 Ruby 줄은 clean 이다** — `ruby/lib/keycloak_sdk/jwt_validator.rb:36` 의 `rescue JWT::DecodeError` 는 이미 JWKError 를 잡는다(실측: 설치된 `jwt-3.2.0/lib/jwt/error.rb:53` 이 `class JWKError < DecodeError`). **고치기 전에 지목부터 다시 잡을 것** — 안 그러면 clean 한 자리를 건드린다.
- [ ] `rust-public-client-empty-secret` **[M/S]** Rust AuthClient가 퍼블릭 클라이언트에도 빈 시크릿을 강제해 Basic 인증을 켠다 · `rust/src/auth.rs:67`
- [ ] `go-tokenprovider-injection-missing` **[M/M]** Go의 TokenProvider 주입점이 문서에만 있고 실제로는 존재하지 않는다 · `go/tokenprovider.go:11`
  - ⚠️ **§4 분류 오류는 약한 쪽이다. 게시된 소스가 거짓 약속을 담고 있다** — `go/tokenprovider.go:12` 의 godoc 이 "Consumers may inject a custom implementation." 이라 적는데, 실측상 `go/*.go` 에 **`TokenProvider` 를 받는 exported 함수가 0개**다(`grep -rnE "func [A-Z][A-Za-z]*\([^)]*TokenProvider" go/*.go` → 빈 결과). 이건 pkg.go.dev 에 그대로 렌더된다.
  - ⚠️ **고칠 때 CLAUDE.md 를 늘리지 말 것** — doc-budget 여유가 **정확히 0**이다(실측: 1바이트만 더해도 `적재 24160B > doc-budget 24159B` 로 필수 체크 `doc-facts` 가 exit 1). 산문을 더하려면 압축으로 지불하거나 예산 인상을 근거와 함께 올려야 한다.
- [ ] `python-sync-admin-close-noop` **[M/S]** Python 동기 admin의 close()가 no-op — async 미러는 닫는다 · `python/src/keycloak_sdk/admin/__init__.py:83`
  - ⚠️ **원장이 과장했다 — 「영영 안 닫힌다」는 거짓.** `ConnectionManager.__del__` 이 GC 시점에 `_s` 를 닫는다. 참인 진술은 「`close()` 가 아무것도 안 하고, 해제 시점이 **GC 에 맡겨진다**」이다(결정적 해제가 없다). 이 문장 그대로 릴리스 노트에 올리면 사실이 아닌 심각도가 된다.
  - ⚠️ **기존 테스트가 결함을 의도로 고정하고 있다** — `tests/unit/test_admin_client.py:81 test_close_is_noop` 의 docstring 이 "컨텍스트 매니저 프로토콜과 대칭을 맞추기 위한 no-op" 이라 적고 `client.raw is admin` 만 단언한다. #399(PHP·Ruby 만료)에 이어 **같은 패턴 세 번째**다.
- [ ] `python-sync-authorization-url-unencoded` **[M/S]** Python 동기 authorization_url이 퍼센트 인코딩 없이 URL을 조립한다 — async 미러는 urlencode를 쓴다 · `python/src/keycloak_sdk/auth.py:148`
- [ ] `php-sensitiveparameter-methods-missing` **[M/S]** PHP #[\SensitiveParameter]가 생성자에만 붙어 있다 — 비밀을 인자로 받는 여섯 메서드는 무보호 · `php/src/AuthClient.php:76`
- [x] `authorization-request-verifier-unmasked` **[M/M]** AuthorizationRequest.codeVerifier가 마스킹 없이 평문 출력된다 (Go·Node) — 같은 파일의 TokenSet은 마스킹한다 · `go/tokens.go:86`
- [ ] `coverage-exclusion-hides-untested-branches` **[M/M]** 네트워크 경계 커버리지 제외가 손으로 쓴 실패 분기와 미호출 공개 메서드를 숨긴다 (Kotlin·PHP) · `kotlin/src/main/kotlin/io/github/xzawed/keycloak/admin/Users.kt:47`
- [ ] `redirect-uri-signature-parity` **[L/M]** createAuthorizationRequest/exchangeCode의 redirectUri 시그니처가 Rust·PHP만 다르다 (계약 패리티) · `rust/src/auth.rs:96`
- [x] `python-config-comment-says-60` **[L/S]** python config 주석이 JWKS 재조회 기본값을 60초라고 적었다 — 두 줄 아래 실제 값은 30.0 · `python/src/keycloak_sdk/config.py:23`

### 재검증 · 가드/CI/문서 — 10

- [ ] `selftest-enforcer-cannot-guard-itself` **[H/M]** 자가테스트 종료코드 규약의 집행자가 자기 자신과 '실패 삼킴'을 못 본다 · `scripts/test/test-selftest-hygiene.sh:19`
  - ⚠️ **범위가 「자기 자신」보다 26배 넓다.** 규칙 1 은 `grep -q 'assert_report' "$f"` 라 **raw 텍스트**를 본다 — 주석 처리된 `# assert_report` 도 통과한다(실측: 그런 파일을 만들어 `grep -q` 를 돌리면 히트). 루프가 `test-*.sh` **26개 전부**를 도니 약점도 26개 전부에 걸린다.
- [ ] `guard-detection-surface-hand-narrowed` **[H/M]** 가드의 탐지 표면이 손으로 좁혀져 있어 새 자리·새 문법이 조용히 통과한다 · `scripts/test/test-security-defaults.sh:311`
  - ⚠️ **지목이 마스킹 축 하나를 가리키지만 체계적이다** — 가드의 **7축 중 5축**(1 코드/skew · 1b nonce · 1c 마스킹 · 3 2차자리 · 4 소유자)이 언어별 파일·앵커를 손으로 열거한다. 새 언어·새 자리가 생기면 `_seen == 9` 류의 대조군이 함께 늘지 않는 한 조용히 통과한다.
  - 참고: 2026-09-04 에 추가한 2b(소스 주석) 축은 `git ls-files` 로 전체를 훑어 이 부류를 피했다 — 같은 형태가 나머지 축의 목표다.

- [ ] `jwks-response-size-unbounded-non-jvm` **[M/M · 신규 2026-09-04]** JWKS 응답 크기 상한이 Go·Java·Kotlin 에만 있다 — rust `resp.json()` · php `(string) getBody()` · ruby `resp.body` 는 무제한 · `rust/src/jwks.rs:41`
  - #400(JVM 상한 복원)의 부류 재스캔에서 나왔다. Go 는 `io.LimitReader(resp.Body, 51200+1)` 로 이미 갖고 있고 주석이 출처를 Nimbus `RemoteJWKSet.DEFAULT_HTTP_SIZE_LIMIT` 이라 밝힌다.
  - ⚠️ **node·python·dotnet 은 판정하지 않았다**(jose · python-keycloak `certs()` · `HttpDocumentRetriever` 로 위임). 라이브러리 실동작을 재기 전에는 무제한이라 적지 말 것.
- [ ] `kotlin-osv-audit-fail-open` **[H/S]** Kotlin OSV 감사 두 잡이 해석 실패 좌표를 통과시켜 아무것도 감사하지 않고 초록이 된다 · `.github/workflows/kotlin-ci.yml:72-83` · `security-audit.yml:80-89`
  - ⚠️ **지목 줄이 빗나가 있었다** — `kotlin-ci.yml:70` 은 `java-version: '21'` 이다. 실제 자리는 위 두 범위.
  - **「두 잡」은 맞다**: `grep -e '--- '` 파이프라인이 3곳인데(`kotlin-ci.yml:78` · `security-audit.yml:86` · `:347`) ` FAILED$` 게이트는 harness 쪽 1곳(`:327`)에만 있다 — #320 이 3곳 중 1곳에만 적용됐다.
  - ⚠️ **저장소 자신의 주석이 원인을 틀리게 적었다.** `security-audit.yml:318-322` 는 "OSV 가 그런 좌표에 취약점이 없다고 답하므로"라 하지만, 실측상 **OSV 는 ` FAILED` 접미사에 무감각**하다(netty-codec-http 4.1.119.Final → 접미사 유무 모두 18건). 진짜 원인은 **전이 폐포 붕괴** — FAILED 루트 하나가 서브트리를 통째로 날려 CVE 를 지닌 좌표가 아예 조회되지 않는다(실측 **좌표 72개 → 5개**, 루트 하나만 깨도 **72 → 14**로 jackson-databind·resteasy·httpclient 등 59개가 조용히 빠진다).
  - ⚠️ **Java 쪽은 고치지 말 것** — 같은 셸 모양이지만 수집기가 Maven 이라 미해결 의존성에서 **도구 자체가 non-zero** 로 죽는다(실측 `MVN_EXIT=1`). 구조적으로 fail-closed 다.
- [ ] `docs-commands-that-do-not-work` **[M/S]** 소비자 문서가 적은 명령·환경변수가 실제로는 동작하지 않는다 · `docs/guides/development-setup.md:77`
- [ ] `deploy-md-omits-release-request` **[M/S]** DEPLOY.md §4 릴리스 절차가 태그를 만드는 트리거 파일을 열거하지 않는다 · `DEPLOY.md:403`
- [ ] `stale-prose-contradicts-source` **[M/S]** 산문 주석이 자기가 서술하는 값·전제·코드보다 낡았고 대조가 없다 · `python/src/keycloak_sdk/config.py:23`
- [ ] `compat-table-library-cells-drift` **[M/M]** compatibility.md Node 행의 라이브러리 셀 세 개가 태그 시점 락파일과 다르다 · `docs/reference/compatibility.md:22`
- [ ] `tokenprovider-cache-contract-untested` **[M/M]** TokenProvider 캐시 계약(만료 재조회·single-flight)이 Rust·Ruby 에서 단언되지 않는다 · `rust/src/token_provider.rs:113`
- [ ] `facade-wiring-close-contract-unasserted` **[M/S]** 파사드의 §4 계약(provider 배선·close)이 무단언 테스트 뒤에 있고 커버리지 게이트에서도 빠져 있다 · `rust/src/client.rs:65`
- [ ] `python-aio-security-test-asymmetry` **[M/S]** JWKS 강제 재조회 rate-limit 이 sync 에만 테스트되고 aio 미러에는 없다 · `python/tests/unit/aio/test_auth.py:446`

## C. 품질 부채 — 67건 (열림 66)

low 강등분 + 아무 배치도 담당하지 않았던 harness 사각지대 14건.

### 9언어 소스 — 20

- [ ] `jwks-refetch-budget-overclaimed` **[M/M]** JWKS 재조회 예산 문서가 실제보다 강하게 약속한다 — cold 로드가 예산을 안 쓴다 · `rust/src/jwks.rs:34-49`
- [ ] `jwks-response-not-validated` **[M/M]** JWKS 응답을 검증 없이 신뢰한다 — Rust는 상태코드 미확인, JVM 둘은 본문 크기 무제한 · `rust/src/jwks.rs:34`
- [ ] `authcode-flow-verification-defeated` **[M/L]** 인가 코드 흐름의 검증이 무력하거나 오적용된다 — azp 미검증·iss 자기주입·공유 검증기 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:135-149`
- [ ] `lenient-parsing-yields-false-success` **[M/M]** 응답 파싱이 관대해서 없는 값·틀린 타입을 성공으로 통과시킨다 · `rust/src/token_provider.rs:68-85`
- [ ] `nimbus-type-on-public-surface` **[L/M]** JWSAlgorithm이 두 JVM SDK의 공개 팩토리 시그니처에 올라 있다 — §4 은닉 위반 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/JwtValidator.java:27-28`
- [ ] `configured-timeout-not-propagated` **[L/M]** 설정한 타임아웃·취소 토큰이 JWKS/검증 경로에 도달하지 않는다 · `node/src/jwt.ts:47-51`
- [ ] `close-path-leaks` **[L/M]** 정리 경로가 자원을 놓친다 — 실패 시 중단·생성 중 누락·미소유 executor · `go/admin.go:66-68`
- [ ] `node-nonsdk-error-escapes` **[L/S]** Node의 두 공개 경로가 SDK 예외 계층 밖의 오류를 던진다 · `node/src/admin/call.ts:13-26`
- [ ] `rust-admin-error-cause-flattened` **[L/M]** Rust에서 admin 토큰 실패의 원인이 가짜 401로 뭉개져 사라진다 · `rust/src/admin.rs:29-40`
- [ ] `error-message-surface-unspecified` **[L/M]** 오류 메시지 표면에 규약이 없다 — 서버 본문 원문 삽입과 한글 메시지 · `dotnet/src/Xzawed.Keycloak.Sdk/Admin/AdminClient.cs:95-101`
- [ ] `config-validation-gaps` **[L/M]** 설정 진입점이 값을 검증하지 않고 잘못된 기본값으로 대체한다 · `node/src/config.ts:74-87`
- [ ] `token-provider-cache-invariants` **[L/S]** 토큰 프로바이더 캐시가 설정을 무시하거나 중복 발급한다 · `go/tokenprovider.go:36-60`
- [ ] `coverage-omit-hides-security-paths` **[L/L]** "네트워크 경계"라는 이름의 파일 단위 커버리지 제외가 보안·오류분류 로직까지 무측정으로 만든다 · `dotnet/src/Xzawed.Keycloak.Sdk/AuthClient.cs:110`
- [ ] `cross-language-surface-divergence` **[L/L]** 같은 개념의 공개 표면이 언어마다 갈린다 — 필드·타입명·메서드명·정규화 위치 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/IntrospectionResult.java:5-9`
- [ ] `php-oauth2-delegation-drift` **[L/S]** PHP가 league 프로바이더에 위임하면서 요청 모양이 다른 SDK와 갈린다 · `php/src/AuthClient.php:161-166`
- [ ] `discovery-roundtrip-divergence` **[L/S]** 엔드포인트를 조립하지 않고 discovery로 왕복하는 자리가 남아 있고 문서에 없다 · `node/src/auth.ts:227-258`
- [ ] `manifest-comment-drift` **[L/S]** 빌드 매니페스트의 주석이 바로 옆 줄의 실제 핀과 다른 값을 말한다 · `java/pom.xml:84-104`
- [ ] `packaging-surface-hygiene` **[L/M]** 게시되는 아티팩트에 불필요·깨진 것이 실리거나 재현되지 않는다 · `java/pom.xml:112-143`
- [ ] `example-and-readme-publication-drift` **[L/S]** 예제·언어 README가 게시 상태와 검증 방법을 틀리게 말하고 아무 게이트도 안 본다 · `kotlin/examples/QuickStart.kt:9-10`
- [ ] `dotnet-admin-path-escaping` **[L/S]** .NET admin 파사드의 경로 이스케이프 규약이 리소스 클래스마다 다르다 · `dotnet/src/Xzawed.Keycloak.Sdk/Admin/ClientsResource.cs:16`

### 테스트·커버리지 — 8

- [ ] `selftest-hygiene-textual-rules` **[H/M]** '존재'가 아니라 '실행'을 센다던 규칙이 주석·비활성화·`|| true`를 실행으로 센다 · `scripts/test/test-selftest-hygiene.sh:20`
- [ ] `coverage-exclusions-swallow-pure-logic` **[H/L]** '네트워크 경계' 커버리지 제외가 I/O 없는 순수 로직까지 삼켰다 — 다섯 언어 · `node/src/transport.ts:38`
- [ ] `security-invariant-use-site-scope` **[H/M]** 보안 불변식의 '2차 정의 자리 금지'가 아홉 중 셋만 본다 — 미검사 언어에 리터럴 네 곳이 살아 있다 · `scripts/test/test-security-defaults.sh:297`
- [ ] `selftest-assert-counter-subshell` **[M/M]** 어서션 카운터가 서브셸에서 증발한다 — 자가테스트 프레임워크의 구조적 맹점 · `scripts/test/assert.sh:10`
- [ ] `guard-paths-never-exercised` **[M/M]** 자가테스트가 가드의 한 경로만 태워, 나머지 경로를 지워도 초록이다 · `scripts/test/test-check-coverage.sh:41`
- [ ] `selftests-with-no-negative-case` **[M/L]** 일곱 자가테스트가 라이브 상태만 단언한다 — 판정기가 나쁜 입력을 거부한다는 증거가 없다 · `scripts/test/test-deploy-md.sh:7`
- [ ] `probes-that-discard-the-result` **[M/M]** 프로브가 결과를 버린다 — 예외 타입 미단언·반환값 미단언 · `php/tests/Unit/Jwks/JwksStoreTest.php:188`
- [ ] `wall-clock-ordering-in-tests` **[M/M]** 동시성·시간창 테스트가 벽시계에 매달려 있다 — 조용한 퇴화와 거짓 실패 · `go/jwt_test.go:322`

### 가드·CI — 16

- [ ] `selftest-exit-code-contract-two-leaks` **[H/M]** 자가테스트의 「실패하면 비영 종료」 계약이 두 곳에서 샌다 — 탐지기도 계수기도 · `scripts/test/test-selftest-hygiene.sh:20`
- [ ] `sweeps-without-vacuity-floor` **[H/M]** 세 개의 스윕/스캔이 0건을 훑고 통과한다 — 이 저장소의 하한 관용이 적용되지 않았다 · `.github/workflows/repo-hygiene.yml:234`
- [ ] `seven-selftests-have-no-negative-control` **[H/L]** 일곱 자가테스트가 라이브 상태만 단언한다 — 검출기를 지워도 통과한다 · `scripts/test/test-deploy-md.sh:7`
- [ ] `irreversible-publish-no-reentry` **[H/M]** 비가역 게시 뒤 재진입 경로가 없다 — 세 레인의 gh release create와 php 미러 순서 · `.github/workflows/go-release.yml:156`
- [ ] `operator-commands-that-do-not-work` **[H/S]** 저장소가 사람에게 시키는 명령 둘이 실제로는 원하는 답을 주지 않는다 · `scripts/release-trigger.sh:53`
- [x] `guard-neutering-wiring-unprotected` **[H/M]** [세션 발견·원장 밖] 가드 스텝을 무력화하는 배선이 무보호다 — 워킹트리에 continue-on-error가 살아 있다 · `.github/workflows/repo-hygiene.yml:119`
- [ ] `guard-probes-count-mentions-not-declarations` **[M/S]** 가드 프로브가 「선언」이 아니라 「문자열 등장」을 센다 — 배선 규칙 3과 node update 프로브 · `scripts/test/test-selftest-hygiene.sh:84`
- [ ] `guards-outside-their-own-pr-signal` **[M/M]** 자기를 고친 PR에서 신호를 못 내는 가드 — 규칙 5의 스윕 글롭 밖과 harness의 paths 필터 · `scripts/gradle/osv-audit-init.gradle:1`
- [ ] `selftests-miss-the-real-callsite` **[M/M]** 자가테스트가 CI의 실제 호출 형태를 타지 않는다 — 무인자 경로·다중 리포트·호출부 seam · `scripts/test/test-check-php-mirror.sh:29`
- [ ] `stale-comments-nobody-collates` **[M/S]** 주석에 박힌 실측값·게이트 서술이 낡았고 대조 대상이 아니다 · `.github/workflows/dotnet-ci.yml:36`
- [ ] `symmetry-guards-cover-a-subset` **[M/M]** 9언어 대칭을 주장하는 가드가 하드코딩 목록으로 부분집합만 본다 · `scripts/test/test-security-defaults.sh:297`
- [ ] `check-versions-java-child-pom-blind-spot` **[M/S]** check-versions.mjs가 자식 POM의 자체 선언 버전을 볼 수 없다 · `scripts/check-versions.mjs:76`
- [ ] `default-root-percent-encoding` **[M/S]** 무인자 기본 루트가 percent 이스케이프를 디코드하지 않아 공백 경로에서 죽는다 · `scripts/check-versions.mjs:27`
- [ ] `repo-config-apply-exit0-on-security-drift` **[M/S]** repo-config.mjs apply가 보안 설정 드리프트를 알리고도 exit 0으로 끝난다 · `scripts/repo-config.mjs:288`
- [ ] `rust-token-in-argv` **[L/S]** rust publish가 env로도 넘긴 토큰을 --token으로 argv에 한 번 더 싣는다 · `.github/workflows/rust-release.yml:127`
- [ ] `push-trigger-branches-asymmetry` **[L/S]** 여섯 워크플로의 push 트리거에 branches가 없어 PR 브랜치에서 레인이 두 번 돈다 · `.github/workflows/dotnet-ci.yml:3`

### 문서·규칙 — 15

- [ ] `docs-kcsdk-env-ssot` **[M/S]** KCSDK_* 환경변수 규약이 세 곳으로 갈려 있고 두 곳이 실측으로 부정된 경로를 가리킨다 · `CLAUDE.md:66`
- [ ] `keycloak-image-tag-fiction` **[M/M]** 9언어가 전부 같은 태그를 핀하는데 문서 셋이 '언어별로 다르다'고 적는다 · `SECURITY.md:92`
- [ ] `php-jwt-headers-rationale` **[M/S]** 세 곳이 반복하는 firebase/php-jwt 근거가 핀된 원본과 정반대다 · `.claude/rules/php.md:49`
- [ ] `deploy-narrative-stale` **[M/M]** DEPLOY.md 본문 다섯 자리가 워크플로·룰셋 개정을 못 따라갔다 · `DEPLOY.md:36`
- [ ] `deploy-php-mirror-gap` **[M/S]** PHP 미러 쪽 장치가 저장소에 실재하는데 런북이 그것을 모른다 · `DEPLOY.md:212`
- [ ] `deploy-readiness-verdict` **[M/S]** §5가 서술하는 release-readiness 판정 둘이 스크립트 개정 뒤 낡았다 · `DEPLOY.md:444`
- [ ] `governance-dead-actor` **[M/M]** 품질 게이트 G5가 저장소에 존재하지 않는 주체를 지목하고, 기각 레지스트리는 상주 진입점이 없다 · `docs/governance/process.md:204`
- [ ] `readme-mirror-contract` **[M/S]** 루트 README 영한 미러가 §4 계약을 두 자리에서 실제 코드보다 느슨하게 말한다 · `README.md:117`
- [ ] `hand-counted-enumerations` **[L/S]** 설정 파일을 손으로 센 열거 넷이 실제와 어긋나고, 그중 하나는 내부 문서끼리 모순이다 · `.claude/rules/ci.md:82`
- [ ] `doc-rule-self-violation` **[L/M]** 문서가 선언한 세 규약을 그 문서 자신이 어긴다 — 선언은 있고 계측기가 없다 · `CLAUDE.md:333`
- [ ] `contributing-gate-table` **[L/S]** '머지 전 통과할 게이트' 표의 세 칸이 실제 CI 잡과 다르다 · `CONTRIBUTING.md:47`
- [ ] `crossdoc-line-citations` **[L/M]** 문서가 다른 문서를 줄 번호로 인용하는데 그 인용을 보는 검사가 없다 · `docs/governance/process.md:46`
- [ ] `new-language-deliverables` **[L/M]** 10번째 언어 체크리스트가 필수 게이트·등록을 빠뜨렸고, 그 구멍이 .NET에 이미 결과로 남았다 · `docs/guides/add-a-language-playbook.md:69`
- [ ] `admin-capability-vestigial` **[L/S]** 25/25가 된 표를 감싼 산문이 빈 칸 시절 문장으로 남았고 두 항목이 서로 모순한다 · `docs/reference/admin-capability.md:16`
- [ ] `roadmap-vestigial` **[L/S]** 로드맵이 출처 없는 CVE를 확정 사실로 적고, 후보가 0행인 표에 '후보 전용 caveat'를 건다 · `docs/roadmap/language-support.md:11`

### harness 사각지대 — 8

- [ ] `H1-conformance-authz-vacuous` **[M/M]** conformance 의 authz-url 판정이 헛돈다 — 요청값이 앱 폴백과 같고 응답을 대조조차 하지 않는다 · `harness/conformance/conformance.mjs:39`
- [ ] `H3-harness-image-and-lock-pins` **[M/S]** 하네스 컨테이너의 이미지·락파일 핀이 세 자리에서 새어 감사한 것과 도는 것이 다르다 · `harness/apps/rust/Dockerfile:3`
- [ ] `H2-harness-judgment-module-no-test` **[L/M]** harness 판정 모듈에 「테스트가 있어야 한다」 규칙이 없다 — conformance.mjs 는 Docker 전체 런 없이는 시험 불가 · `harness/conformance/conformance.mjs:1`
- [ ] `H4-runsh-network-divergence` **[L/S]** verify.sh 가 배운 것을 run.sh 는 못 받았다 — compose 네트워크명을 아직 리터럴로 박는다 · `harness/run.sh:6`
- [ ] `H5-install-version-class-drift` **[L/M]** install 하네스의 「버전을 무엇이 정하는가」 분류가 코드·산문·SSOT 셋에서 갈렸다 — dotnet 이 정반대 · `harness/install/lib/verify-lib.sh:56`
- [ ] `H6-kotlin-consume-pin-audits-old-artifact` **[L/S]** kotlin 소비자 앱의 0.1.0 리터럴이 야간 OSV 감사가 실제로 해석하는 좌표다 · `harness/install/consume/kotlin-app/build.gradle.kts:36`
- [ ] `H7-harness-readme-vs-tree` **[L/S]** harness/README.md 가 실제 트리와 갈렸다 — install/ 64파일이 지도에 없고 ruby 프레임워크가 틀렸다 · `harness/README.md:16`
- [ ] `H8-root-config-never-rederived` **[L/M]** 리포 루트 설정 둘이 언어·락파일이 늘 때 한 번도 다시 도출되지 않았다 · `.dockerignore:2`

## D. 원장 밖 — 46건 (열림 44)

감사가 보지 않은 축 — 유예·미완 마커·로드맵 갭·CI/릴리스·테스트 실행·1.0 이후 운영·완전성 비평.

### 유예·되살릴 조건 — 9

- [ ] `go-release-persist-credentials` **[M/S]** `contents: write` 릴리스 잡 넷 중 go 하나만 checkout 자격증명을 워크스페이스에 남긴다 — 기각의 되살릴 신호가 지금 참이다 · `.github/workflows/go-release.yml:138`
- [ ] `revive-conditions-unmeasured` **[M/M]** 되살릴 조건을 「돌아가는 명령」으로 적어 두고, 그 명령을 아무도 돌리지 않는다 — 기각 22건이 전부 수동 감시다 · `docs/governance/rejected.md:44`
- [ ] `sonar-tests-revive-instrument` **[M/M]** sonar.tests 되살릴 조건이 「색인 수가 유지되는가」인데 그 수를 아무도 기록하지 않는다 — 공허한 초록을 판별할 계측기가 없다 · `.github/workflows/sonarcloud.yml:22`
- [ ] `dependabot-ignore-joins` **[M/M]** 조건부 `ignore` 셋의 해제 조건이 다른 파일의 사실에 묶여 있는데 조인이 없다 — kotlin 하나만 기계가 본다 · `.github/dependabot.yml:79`
- [ ] `gate-substitutes-unasserted` **[M/L]** 기계 게이트가 없는 자리마다 「대신 이것이 본다」가 적혀 있는데, 그 대체물의 존재는 아무도 검사하지 않는다 · `sonar-project.properties:30`
- [ ] `sonar-suppression-premises` **[M/M]** sonar 억제 셋의 근거가 트리 안의 다른 사실에 묶여 있는데, 그 사실이 바뀌면 억제가 오탐이 아니라 진짜를 숨긴다 · `sonar-project.properties:205`
- [ ] `vitest-v4-migration` **[L/M]** vitest 3에 묶인 유일한 이유가 테스트 두 파일의 `vi.mock` 클래스 팩토리 셋이다 · `node/test/unit/client.test.ts:1`
- [ ] `tenth-language-deferrals` **[L/S]** 「10번째 언어가 들어올 때」가 여러 유예의 공통 트리거인데, 그때 무엇을 함께 해야 하는지가 한 곳에 없다 · `docs/guides/add-a-language-playbook.md:105`
- [ ] `release-readiness-remote-tag-print` **[L/S]** 릴리스 준비도 도구가 로컬 클론의 태그만 보고 「태그 없음」을 답한다 — 되살릴 조건은 두 값을 나란히 인쇄하는 것 · `scripts/release-readiness.sh:93`

### 미완 마커 — 3

- [ ] `harness-suites-untested-here-marker` **[M/M]** 하네스 스위트 4종(python·rust·ruby·kotlin)이 「미실행 검증(untested-here)」 마커를 단 채 스코어카드를 만든다 · `harness/suites/python.sh:6`
- [ ] `release-yml-unpaid-measurement` **[M/S]** release.yml 헤더의 「미납 실측」 블록이 전제(태그 미푸시)가 무너진 뒤에도 그대로 남아 있다 · `.github/workflows/release.yml:16`
- [ ] `install-verify-not-implemented-wording` **[L/S]** install-verify.sh의 유일한 TODO — not_implemented가 원인을 「언어 태스크 대기 중」으로 오귀속한다 · `harness/install/install-verify.sh:100`

### 로드맵·기능 갭 — 7

- [ ] `admin-relations-role-mapping-group-membership` **[H/L]** 역할 부여·그룹 가입이 9개 언어 어디에도 없다 — CRUD만 있고 리소스 간 연결이 없다 · `docs/reference/admin-capability.md:18`
- [ ] `admin-client-roles-and-user-subresources` **[H/L]** roles 파사드는 realm role 전용 — client role·client secret·user credential/session이 0/9 · `node/src/admin/roles.ts:5`
- [ ] `auth-ropc-password-grant` **[H/M]** ROPC(password) 그랜트가 SDK에 없어 9개 하네스 앱이 전부 raw HTTP로 손수 만든다 · `harness/apps/node/server.js:62`
- [ ] `auth-surface-parity-unguarded` **[M/M]** auth·oidc 공개 표면에 가드가 없어 3곳이 이미 갈렸다 — PHP만 logoutUrl, Kotlin만 userinfo, Ruby만 access_token · `php/src/AuthClient.php:161`
- [ ] `admin-family-scope-undeclared` **[M/S]** 파사드가 안 덮는 admin 리소스 패밀리 13종에 대한 '지원 범위' 선언이 어디에도 없다 · `docs/reference/admin-capability.md:12`
- [ ] `tenth-language-registration-registry` **[M/M]** 10번째 언어를 넣으려면 38개 파일의 언어 목록을 손으로 고쳐야 한다 — 등록 지점 레지스트리가 없다 · `scripts/check-admin-capability.mjs:23`
- [ ] `cross-cutting-http-capabilities` **[L/M]** User-Agent·프록시·재시도·로깅 훅이 9개 언어 전부 없다 — 횡단 HTTP 능력이 축에서 빠졌다 · `node/src/config.ts:7`

### CI·릴리스 미결 — 6

- [ ] `dependabot-updater-failure-blind` **[M/M]** dependabot updater 잡의 실패가 어떤 CI 에도 안 보인다 — 실측 실패 2건 전부 무성 · `.github/dependabot.yml:123`
- [ ] `security-invariant-not-required` **[M/S]** Jackson 보안 불변식 잡이 required 밖이고, 그 grep 은 오류를 삼킨다 · `.github/workflows/repo-hygiene.yml:219`
- [ ] `post-publish-version-verify` **[M/M]** 게시 후 「이 버전이 라이브인가」를 답하는 도구가 없다 — readiness 는 좌표 단위이고 태그가 있으면 즉시 return 한다 · `DEPLOY.md:428`
- [ ] `ci-lane-trigger-branch-filter` **[L/S]** 언어 CI 6개가 `branches:` 없이 push 트리거 — 태그·아카이브 ref·PR 브랜치에서 중복으로 돈다 · `.github/workflows/dotnet-ci.yml:3`
- [ ] `orphan-active-workflows` **[L/S]** 파일이 없는 워크플로 2개가 Actions 에 `active` 로 남아 있다 — 라이브 26 vs 커밋 24 · `.github/workflows/repo-hygiene.yml:207`
- [ ] `repo-settings-ssot-gap` **[L/S]** 브랜치 자동삭제 등 저장소 설정이 SSOT 밖 — 원격이 깨끗한 이유가 어디에도 안 적혀 있다 · `.github/security-config.json:2`

### 테스트 실행 갭 — 6

- [ ] `integration-coverage-never-measured` **[H/L]** 9개 언어가 "경계는 통합으로 검증"이라 적고 omit했지만, 통합 실행에서 커버리지를 재는 언어가 0개다 · `.github/workflows/ci.yml:42`
- [ ] `integration-admin-surface-uneven` **[H/M]** 9개 통합 스위트가 덮는 admin 표면이 제각각이다 — clients.update는 1/9, realms.create/delete는 4/9, PHP는 roles·groups·realms를 하나도 안 부른다 · `java/keycloak-sdk/src/test/java/io/github/xzawed/keycloak/AdminOpsIT.java:48`
- [ ] `coverage-omit-overreach` **[M/M]** omit의 근거("단위테스트 불가한 네트워크 경계")가 실측으로 거짓이다 — Node는 이미 96.93%, Python은 98%인 코드를 게이트 밖에 두고 있다 · `node/vitest.config.ts:14`
- [ ] `coverage-threshold-parity` **[M/M]** 커버리지 임계값이 9언어에서 갈리고(브랜치 게이트가 아예 없는 곳 셋), 문서↔설정 대조 가드는 3개 언어만 본다 · `scripts/check-docs.mjs:552`
- [ ] `coverage-omit-no-ssot` **[M/M]** omit 목록이 열 곳에 손으로 중복 기재돼 있고 대조 가드가 0건 — Rust 제외 정규식은 앵커도 없다 · `java/pom.xml:151`
- [ ] `readme-quickstarts-ungated` **[M/M]** README가 정본이라 부르는 quickstart 예제가 어떤 게이트에도 안 걸린다 — 하네스가 실제로 돌리는 것은 별도 사본이다 · `node/examples/quickstart.ts:1`

### 1.0 이후 운영 — 9

- [ ] `registry-truth-check` **[H/M]** 게시 SSOT가 문서하고만 대조되고 실제 레지스트리와는 한 번도 대조되지 않는다 · `scripts/lib/deploy-facts.sh:138`
- [ ] `stale-release-comments` **[H/S]** 릴리스 경로의 주석 다섯이 낡았고, 그중 하나는 다음 릴리스를 정반대로 오도한다 · `F:/DEVELOPMENT/SOURCE/CLAUDE/KeyCloakSDK/.github/workflows/install-smoke.yml:57`
- [x] `post-1-0-registry-missing` **[M/S]** 1.0 이후 잔여작업 등록부가 저장소 어디에도 없다 — 안 닫힌 항목은 복원 불가능하다 · `docs/README.md:49`
- [ ] `public-registry-install-smoke` **[M/L]** 게시된 1.0.0 을 공개 레지스트리에서 받아 설치·컴파일해 보는 정기 검증이 없다 · `harness/install/install-verify.sh:11`
- [ ] `advisory-path-never-run` **[M/M]** 보안 권고·회수 경로가 문서에만 있고 한 번도 실행된 적 없다 · `SECURITY.md:141`
- [ ] `divergence-rehearsal-artifact` **[M/M]** 함대가 갈리는 릴리스에서 새로 써야 하는 분기 문장 8건에 초안이 없다 · `scripts/test/test-publication-claims.sh:704`
- [ ] `keycloak-server-tag-ssot` **[M/L]** Keycloak 서버 태그가 18개 파일에 복제된 채 떠 있고, 호환성 표의 「actual 26.6.4」는 재현 불가한 스냅샷 · `docs/reference/compatibility.md:20`
- [ ] `harness-consume-pin-unsupported` **[L/S]** 주간 OSV 감사가 지원 대상이 아닌 0.1.0 트리를 재고 있다 · `harness/install/consume/kotlin-app/build.gradle.kts:36`
- [ ] `npm-rc-dist-tag-residue` **[L/S]** npm `rc` dist-tag 가 지원하지 않는 0.1.0-rc.2 를 아직 서빙한다 · `DEPLOY.md:503`

### 완전성 비평 신규 — 6

- [x] `runtime-eol-support-window` **[H/M]** 선언된 소비자 런타임 하한 둘이 상류 지원 종료다 — Ruby 3.2는 이미 EOL, .NET 8은 68일 뒤 · `ruby/keycloak-sdk.gemspec:20`
- [ ] `consumer-intake-surface-absent` **[M/S]** 9개 레지스트리에 게시했는데 소비자 유입 표면이 통째로 없다 — 이슈 템플릿·PR 템플릿·CODEOWNERS·행동강령 0건 · `.github/ISSUE_TEMPLATE:0`
- [ ] `harness-base-images-unmanaged` **[M/M]** 하네스 Docker 베이스 이미지 20개가 dependabot·가드 양쪽 밖 — 무핀 태그와 갈린 alpine이 섞여 있다 · `.github/dependabot.yml:134`
- [ ] `release-artifact-verification-undocumented` **[M/M]** 소비자가 게시물의 무결성을 확인할 방법이 문서에 0건 — 증명 수단이 레인마다 다른데 아무도 그 표를 쓰지 않았다 · `SECURITY.md:96`
- [ ] `dependency-license-claims-unverified` **[L/M]** CLAUDE.md가 아홉 스택 전부의 라이선스 호환을 단언하는데 CI에 라이선스 검사가 0건 · `CLAUDE.md:150`
- [ ] `repo-topics-omit-four-languages` **[L/S]** 저장소 topics가 아홉 언어 중 다섯만 담고 20개 한도를 소진했다 — 그리고 topics는 SSOT 밖이다 · `.github/security-config.json:2`

---

## 닫는 조건

전 항목이 체크되면 `doc-status` 를 `complete` 로 내리고(가드가 강제한다), 아카이브 태그로 내린 뒤 [지도](../../README.md) §3 에서 지운다. 기각으로 닫는 항목은 미체크로 남기고 [기각 레지스트리](../../governance/rejected.md)에 **되살릴 조건과 함께** 옮긴다 — 미체크가 0 이 아니어도 `complete` 로 내릴 수 있는 이유가 그것이다.
