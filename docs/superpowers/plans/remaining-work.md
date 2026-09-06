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
| 작업 패키지 | **165** (원장 유래 104 · 원장 밖 46 · 재스캔 신규 2 · 문서감사 신규 13) — 열림 **135** · 닫힘 **30** |
| 심각도 | high 27 · medium 76 · low 47 |
| 작업량 | S 68 · M 70 · L 12 |

### 다음 세션 진입점 (2026-09-06 기준 · #415 · #416 반영)

135건 중 어디부터인지가 안 보이므로 순서를 못박는다. **위에서부터 밟는다.**

1. **`doc-audit-batch2-3-not-started` [M]** — 미검증 20개. 방법·회수율 실측이 그 항목에 있다. ⚠️ **감사자 처방의 임계치를 그대로 옮기지 말 것**(배치 1 에서 여러 건이 `--min-facts=64 --min-anchors=21` 을 전제했으나 이 트리는 **74/22**).
2. **`jvm-cold-cache-unmeasured` [M]** — java·kotlin 만 미측정. **먼저 재고, 그 다음에 고칠지 정한다.**

⚠️ **배치 1 이 남긴 것: 문서 셋이 예산에 붙어 있다.** `CLAUDE.md`(여유 0) · `CONTRIBUTING.md` · `DEPLOY.md` · `process.md` 는 **정확성 수정 한 줄도 예산을 넘긴다**. 배치 2·3 은 수정 건수가 더 많으므로 **착수 전에 예산 정책을 사람과 합의할 것** — 매 건 압축하다 보면 결론만 남고 판정 방법이 지워진다(배치 1 실측: CONTRIBUTING 306→71B · DEPLOY 1203→223B 로 깎고도 초과라 래칫을 올렸다).

⚠️ **`jvm-17-floor-never-shipped` [H] 는 여기 없다 — 남은 것이 릴리스뿐이기 때문이다**(비가역·사람 승인 게이트, 2026-09-06 사람 판정 「릴리스는 하지 않는다」). 문서는 #413 이, **가드는 #415 가** 닫았다: 이제 `kind=runtime` 이 트리와 최신 릴리스 태그를 함께 읽어 격차가 기록되지 않으면 fail-closed 한다. 릴리스가 나가면 `getting-started.md` 의 `published=21` 두 개를 **지워야** 통과한다(가드가 반대 방향으로도 실패한다).

**#415 가 남긴 부류 시험**(다른 주장에도 적용한다): **「소비자가 틀릴 수 있는데 HEAD 는 맞다면, 오라클은 트리가 아니라 태그·레지스트리다.」** 후보 — 게시된 공개 API 표면 · 게시 매니페스트의 의존성 하한 · 릴리스 바이너리에 컴파일된 기능 · 배포 아티팩트의 라이선스 · 「vX 에 포함됨」류 CHANGELOG 결속.

⚠️ **이 세션이 반복해서 밟은 함정 넷**(전부 실측으로 잡혔다) — 착수 전 읽는다.
   (a) **「사본이면 지운다」를 네 번 잘못 적용**했다. 지우려던 것이 **인접 판정의 입력**이었다(`18/20` 을 지우면 다음 줄의 「two branches」가 `20−18` 을 잃는다). 지우기 전에 앞뒤 문장의 유도 관계와 `git blame -L n-1,n+1` 로 같은 커밋인지 본다.
   (b) **계측기가 네 번 고장났다.** 줄단위 정규식이 **인라인 플로우 맵**을 놓치고(`matrix: { java: [...] }`), `git log -S'<속성이름>'` 은 **값만 바뀐 커밋을 못 잡는다**(개수가 안 변한다). 「N 개가 전부」를 말하기 전에 전수를 세고, 알려진 정답으로 계측기를 먼저 잰다.
   (c) **가드가 초록인 것은 삭제·안전의 근거가 못 된다.** 그 값을 읽는 스크립트가 0건이면 「안전」이 아니라 **「문서가 유일한 소재지」**다.
   (d) **서브에이전트가 리포 git 을 하이재킹했다** — 실제 `.git/config` 에 `core.worktree` 를 써서 `git status` 가 거짓 clean 을 냈다. 워크플로 직후 `git rev-parse --show-toplevel` 을 먼저 찍는다.

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
| #415 | `registry-contract-claims-use-tree-oracle` · `consumer-floor-change-needs-release-or-registered-gap` | 가드가 **작업 트리**만 오라클로 써서 소비자에게 거짓을 집행했다 — `kind=runtime` 에 최신 릴리스 태그를 두 번째 오라클로 붙였다. ⚠️ 공허 경로 둘을 실측으로 막았다: 빈 태그를 보간하면 `git show ":path"` 가 **인덱스**를 읽고, 버전 문자열 정렬은 **RC 를 정식 뒤에** 세운다. ⚠️ 본문 대조를 맨 `includes` 로 두면 `>=2` 가 `>=24` 에 걸린다(독립 검증 레그 지목) |
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

## B. 재검증 대상 — 27건 (열림 20)

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
- [x] `dependabot-ignore-kinds-uncounted` **[M/S · 신규·닫힘 2026-09-05]** 「올려선 안 되는 핀 N 종류」가 두 곳에 손으로 적혀 이틀 만에 두 번 어긋났다(ci.md 셋 · CLAUDE.md 넷 · 실측 `ignore` 8건) · `.github/dependabot.yml`
  - **닫힘.** `check-docs.mjs` 에 `kind=ignores` 앵커를 넣어 CLAUDE.md 문단을 dependabot.yml 과 **양방향** 대조한다(추가→문단이 빨강 · 삭제→`min` 이 빨강). facts 64→72 · anchors 21→22, 진입 명령 4곳 동기화.
  - 변이검증 5건 전부 잡힘 + 대조군(앵커 제거) 통과: 이름 제거 · yml 추가 · yml 삭제 · `@types/node`→`node`(느슨해짐 방지, npm 스코프는 세그먼트 축약 불허) · `kind` 오타는 조용히 통과하지 않는다.
  - ⚠️ **분류를 「다섯 종류」로 접지 말 것** — 초안이 그렇게 썼다가 되돌렸다. `vitest`·`@vitest/coverage-v8` 은 종류가 아니라 **일시적 이관 보류**다(실측: dependabot.yml 주석 중 「그때 이 항목을 지운다」는 이 둘뿐). 「네 종류 + 나머지」가 참이다.
  - 같은 사실이 두 곳에 있던 것이 원인이므로 `.claude/rules/ci.md` 에서 개수·열거를 지웠다(해제 조건·`gh api` 명령은 이미 dependabot.yml 주석이 소유 · 8,870B/9,985B 로 여유 확보).
- [x] `php-readiness-no-api-claim` **[M/S · 신규·닫힘 2026-09-05]** `.claude/rules/php.md` 가 「미러·Packagist 는 API 로 확인할 수 없다」고 적었으나 스크립트는 둘 다 조회한다 — 저장소가 스스로 「거짓이었다」고 기록한 문장이 정본 규칙에 남아 있었다 · `.claude/rules/php.md:38`
  - **닫힘.** `rr_mirror_tag`(`git ls-remote`)·`rr_packagist_source`(Packagist p2)가 실재하고 둘 다 확인되면 `✅`, `ℹ️ 수동 확인` 은 **조회 실패(rc=2)일 때만**이다(`release-readiness.sh:176-185`). 정정 근거는 `scripts/test/test-release-readiness.sh:166`.
  - 예산은 **등가 교환**으로 맞췄다 — 스냅샷 측정치(`measured 100.00%`)를 지우고 한계값(`≥90%`)만 남겼다. 래칫 없음.
  - ⚠️ 이 부류는 명령 한 번으로 안 드러난다: `sh scripts/release-readiness.sh php` 는 `ℹ️ 태그 이미 존재`로 앞단에서 단락돼 이 분기를 안 탄다. 스텁 단위테스트가 유일한 현재성 증거다.
- [ ] `node-rules-history-prose` **[S/S · 신규 2026-09-05]** `.claude/rules/node.md` 에 「무엇이 일어났는가」형 사후분석 산문 약 800B(예산 6,255B 의 13%)가 행동 지침을 밀어내고 있다 · `.claude/rules/node.md:26,32,38`
  - 삭제 대상: `17 type errors passed CI: 12 × … 5 × …`(이미 고쳐진 과거 계수) · `is a product of its history` 로 시작하는 `26.7.0 → ~26.6.4 → ~26.7.0` 왕복 서술(마지막 행동 규칙 한 문장만 남긴다) · `it had four entries while this line listed three`(해소된 드리프트 기록).
  - ⚠️ **보존 대상과 섞지 말 것** — `13 × TS6059`(include 에 test 를 넣으면 무슨 일이 나는가)와 `~4.5 min / wait 45 seconds`(재현 절차)는 이력이 아니라 **다음 세션이 다시 잴 한계**다. 지우면 손실이다.
- [x] `doc-audit-2026-09-05-confirmed-six` **[M/M · 신규·닫힘 2026-09-05]** 고정 스냅샷 문서감사가 확정한 6건 — 전부 「가드받는 SSOT 의 사본이 갈렸다」 부류다 · `.claude/rules/`
  - **닫힘.** 6건 측정 → 렌즈 2개(손실 · 진실성/가드)로 적대 검증 12회, **3건 refuted 후 재작성**. 최종 반영: `rejected.md`↔`sonar-project.properties` 판정 분기 제거(사본→포인터, −423B) · `security.md:40` 낡은 원장 포인터(`jwks-cold-cache-ungated`→`jvm-cold-cache-unmeasured`) · `rust.md:41-45` 가드 없는 `~26.6.2` 사본 삭제 + SSOT 위임 문장 이동 · `ruby.md:14` CI 레그 3→4(4.0 은 차단 레그) · `kotlin.md:60` 「the four」→ 개수 없이 이름으로 · `dotnet.md:32,39,59` 전사 숫자 전부 삭제.
  - ⚠️ **반박이 잡은 것 셋 — 제안을 그대로 넣었으면 결함을 새로 심었다.** (1) ruby 안이 「기계 국소 사실」을 **금지문**으로 뒤집어 `doctor.mjs:97-99` 가 정상이라 적은 이식형 설치 규약과 충돌했다. (2) dotnet 안이 「이력은 git 이 소유한다」에 기대 삭제했는데 실측하니 `git log -S'188/194'` 는 규칙 발생 커밋을 **안 잡는다**(그건 `-S'213 and 52'` → f19bda2). (3) kotlin 안의 「all six definition sites」는 **거짓 전수 주장**이었다.
  - ⚠️ **개수를 고칠 때 개수를 다시 쓰지 말 것.** kotlin 은 「넷 → 여섯」이 아니라 **개수를 빼고 이름으로** 갔다 — 가드가 세는 자리를 늘리면 그 낱말이 또 낡는다(fe28f54 가 고친 것과 같은 부류).
  - 예산: 전부 등가 교환 또는 음수. 래칫 인상 0건. `doc-facts` 가 도는 명령 8개 PASS.
- [x] `harness-gradle-version-copies-unguarded` **[M/S · 신규·닫힘 2026-09-05]** 하네스의 gradle 버전 사본이 어느 가드도 안 읽고, **그중 하나는 이미 낡았다** · `harness/install/install-verify.sh:906`
  - **닫힘.** `check-versions.mjs` 의 미러↔래퍼 대조를 `kotlin/` 하드코딩에서 **발견 기반 트리 순회**로 바꿨다(`<tree>/gradle/wrapper/gradle-wrapper.properties` 를 훑어 짝을 찾는다). 이제 세 트리를 전부 본다: `kotlin/`(9.5.0) · `harness/apps/kotlin/`(8.14) · `harness/install/consume/kotlin-app/`(8.14).
  - ⚠️ **경로를 박지 않았다** — 이 항목의 원인 자체가 「사본이 셋」이라 적었다가 다섯이었던 것이다. 넷째 짝(`scripts/test/fixtures/version-ssot/kotlin`)은 이 가드의 픽스처라 경로로 제외한다(자가테스트는 픽스처를 **root 로 넘겨** 돌리므로 그때는 그 경로 조각이 나타나지 않는다).
  - 가드 3요건 실측: **(a)** 세 트리 각각 미러 변이 → `rc=1` · **(b)** 복원 → `rc=0` · **(c)** 구 스크립트 + 같은 하네스 변이 → `rc=0`(= 새 순회가 원인임을 확정). 부재도 실패로 잡는다(미러 줄 삭제 → 「래퍼 미러 주석(…) 을 읽지 못했다」).
  - ⚠️ **중복 게이트를 만들지 않았다** — kotlin 블록에서 미러 검사를 **떼어냈다**. 남겨뒀으면 같은 조건이 두 곳에 있어 어느 한쪽을 지워도 동작이 안 바뀌고 변이가 양쪽 다 통과한다([[redundant-guards-void-mutation-testing]]).
  - ⚠️ **공허 방어는 「없음」과 「못 찾음」을 가른다.** 래퍼가 아예 없는 부분 체크아웃은 대상이 아니다(기존 대조군이 그것을 고정한다 — 처음엔 여기서 오탐이 났다). 실패는 `kotlin/gradle/wrapper/…` 가 디스크에 있는데 순회가 **놓친** 경우뿐이다.
  - ⚠️ **픽스처를 함께 넓혔다** — `fixtures/version-ssot/harness/apps/kotlin/` 에 래퍼+미러 짝이 없어 새 루프가 **한 트리만 태우고 있었다**. 짝을 넣어 두 트리를 태운다(자가테스트 74 → 80건).
  - 실측: `install-verify.sh:906` 은 `install-consume-kotlin` 컨테이너를 「gradle 9.5.0 배포판」이라 적는데, 그 앱의 래퍼는 `harness/install/consume/kotlin-app/gradle/wrapper/gradle-wrapper.properties` → **gradle-8.14** 다(`kotlin-run.sh:39` 이 `sh ./gradlew` 로 그 래퍼를 실제로 쓴다).
  - ⚠️ **`harness/suites/kotlin.sh:3,7` 은 낡지 않았다 — 세지 말 것.** 그쪽은 본체 `kotlin/gradlew`(실측 9.5.0)를 가리키므로 참이다. 「사본이 셋이니 셋 다 틀렸다」로 뭉뚱그리면 오탐이 된다.
  - **906줄은 고쳤다**(버전을 빼고 래퍼를 가리킨다). ⚠️ **항목은 닫히지 않는다 — 「셋」이 과소계수였다.** 재스캔으로 `// gradle/wrapper:` **미러 사본 둘**이 더 나왔고 둘 다 가드 밖이다: `harness/apps/kotlin/build.gradle.kts:4` · `harness/install/consume/kotlin-app/build.gradle.kts:9`(둘 다 `8.14`).
  - 변이검증(격리 사본 · 대조군 포함): 미러 둘을 `7.0.0-FALSE` 로 바꿔도 `check-versions.mjs` **rc=0**(공허). 같은 변이를 본체 `kotlin/build.gradle.kts:1` 에 하면 **rc=1** 로 잡힌다(「미러 주석이 … 인데 gradle-wrapper.properties 는 …」) — 계측기는 정상이고 **범위만 `kotlin/` 하나**다.
  - ⚠️ **하네스 두 앱은 KGP 2.2.20 을 의도적으로 붙들고 있어**(소비자 하한 검증) 언젠가 래퍼를 함께 올린다. 그날 이 미러 둘은 906줄이 그랬듯 조용히 낡는다. **닫는 자리**: `scripts/check-versions.mjs:301-302` 의 `bgk`/`wrapProps` 를 세 쌍(`kotlin/` · `harness/apps/kotlin/` · `harness/install/consume/kotlin-app/`)을 도는 배열로 바꾼다.
  - ⚠️ **`harness/suites/kotlin.sh:3,7` 은 여전히 손대지 말 것.** 한 번 지웠다가 **되돌렸다** — 그 `9.5.0` 은 참이고(본체 `kotlin/gradlew`), `kotlin/build.gradle.kts:1` 에 가드받는 집이 있으며, 무엇보다 「본체 9.5.0 ↔ 하네스 8.14」라는 **두 래퍼 구분의 유일한 텍스트 단서**다. 지우면 906줄과 문장 모양이 같아져 그 구분이 사라진다.
- [x] `rulefile-matrix-vs-workflow-unguarded` **[M/M · 신규·닫힘 2026-09-05]** 규칙 파일이 적는 CI 매트릭스를 워크플로의 `strategy.matrix` 와 대조하는 기계가 없다 · `.claude/rules/{java,ruby}.md`
  - **닫힘.** `check-docs.mjs` 검사 **4b**(`checkMatrixClaims`) — `MATRIX` 표가 lang → (워크플로 경로, 축 키)를 들고 문서의 「CI runs …」 목록과 대조한다. **문서 비용 0B**(앵커 없음, 바로 위 `checkCoverageGates` 와 같은 모양). facts 72 → 74, 진입 명령 4곳 동기화.
  - ⚠️ **앵커(`kind=matrix`)를 만들지 않았다.** `kind=runtime` 관용(「첫 버전 모양 백틱 스팬」)을 그대로 쓰면 두 줄 다 **매트릭스가 아니라 하한**을 집는다(`maven.compiler.release=17` · `required_ruby_version >= 3.2`). 백틱을 새로 씌우려면 java.md 에 2B 가 드는데 여유가 정확히 **0B** 다.
  - ⚠️ **부재를 통과시키지 않는다** — `checkCoverageGates` 의 `if (!claim) continue` 를 베끼지 않았다. 표에 등재됐다는 것은 「이 목록은 지울 수 없다」(#409)는 판정이 걸려 있다는 뜻이고, 그것을 기계로 고정하는 자리가 여기뿐이다(앵커류는 못 한다 — 앵커 하나 삭제는 `--min-anchors` 를 함께 안 올리면 조용히 통과한다).
  - 세 함정을 실측으로 확인하고 막았다: **(i)** `#` 주석을 인용부호 인식으로 지운다(안 지우면 ruby-ci 주석의 `gem "parallel", "< 2"` 가 값으로 섞인다) · **(ii)** 탐색은 `matrix:` **키**로 한다(`grep matrix` 는 `name: install-matrix` 를 잡는다 — `harness.yml:91`·`install-smoke.yml:72`) · **(iii)** 주장 추출은 「CI runs」 뒤 **버전 토큰 연속열만** 탐욕 소비하고 첫 비버전에서 멈춘다(줄끝까지 읽으면 java 가 `major ≤ 61` 의 61 을 먹고, 첫 마침표에서 끊으면 ruby 가 `["3"]` 이 된다).
  - 변이 5건 전부 양방향 검출 + 대조군: 워크플로 레그 추가 · 문서 레그 삭제 · 워크플로 하한 레그 삭제 · **문서 목록 문장 자체 삭제**(부재=실패) · java 값 변조 → 전부 `rc=1`. 구 스크립트 + 같은 변이 → **4b 에러 0**(새 검사가 원인 확정). 인용부호 딸린 디코이 주석 삽입 → **4b 에러 0**(면역).
- [ ] `rust-msrv-leg-vs-manifest-unguarded` **[S/S · 신규 2026-09-05]** `rust-ci.yml:21` 의 `'1.88'` 레그가 `rust/Cargo.toml:6` 의 `rust-version = "1.88"` 과 대조되지 않는다 · `.github/workflows/rust-ci.yml:21`
  - ⚠️ **「가드가 rust-version 을 안 읽는다」는 부정확하다** — `check-docs.mjs:538` 이 읽는다. 다만 그건 `kind=runtime` 앵커용(문서의 백틱 값 ↔ 매니페스트)이고, **워크플로 레그와의 대조는 없다**. 축이 다르다(문서↔매니페스트 vs 워크플로↔매니페스트).
  - 검사 4b 로는 못 덮는다 — rust.md 는 #409 에서 매트릭스 주장을 지웠으므로 문서 쪽 주장이 없다. MSRV 를 올릴 때 워크플로 레그가 따라오지 않으면 「MSRV 라 적힌 값이 실제로는 검증되지 않는」 상태가 된다.
  - 이번에 ruby 가 어긋난 채 발견됐고(3레그 ↔ 실제 4레그), 나머지 셋은 **지금은** 일치한다(전수 대조: java 17/21/25 · go 1.25/1.26 · rust 1.88/stable). 즉 오늘 참인 문장을 산문으로 다시 적었을 뿐이고 같은 방식으로 또 어긋난다.
  - **넷 중 둘만 지웠다(go·rust). java·ruby 는 지우려다 되돌렸다 — 그 목록은 사본이 아니라 인접 판정의 입력이다.**
    - `java.md:19` 의 `17·21·25` 는 뒤 절의 **전제**다. `ci.yml:40` 이 「**CI 가 21·25 에서도 도는 한** 그 사고는 CI 에 보이지 않으므로 산출물을 직접 본다」라고 적는다 — 「CI 는 하한을 돈다」로 바꾸면 `check-jvm-bytecode-floor.mjs` 가 **중복 가드로 읽혀** 다음 세션이 지울 근거가 된다.
    - `ruby.md:14` 의 4레그 열거는 바로 아래 곁가지 위험의 **입력값**이다. 「하한 레그 하나」만 남기면 *다른 레그가 있다*는 사실이 사라져 「취소될 수 있다」를 ruby.md 만 읽고 재구성할 수 없다.
  - ⚠️ **그래서 남은 범위는 「지우기」가 아니라 「java·ruby 두 목록을 기계 대조」다.** 앵커를 만들면 **양쪽 YAML 형태를 다 파싱해야 한다** — 실측: 매트릭스 축 9개 중 **5개가 인라인 플로우 맵**(`matrix: { java: [...] }`)이고, 블록만 읽는 스캐너는 4개만 찾는다(내 첫 스캐너가 그랬다). `include`/`exclude`/`fromJSON` 은 현재 0건.
  - 곁가지 둘은 아래 `matrix-fail-fast-cancels-floor-leg` 로 분리해 **닫았다**.
- [x] `matrix-fail-fast-cancels-floor-leg` **[M/S · 신규·닫힘 2026-09-05]** 매트릭스 워크플로 8개 중 **6개에 `fail-fast: false` 가 없어** 최신 레그가 깨지면 소비자 하한 레그가 취소된다 · `.github/workflows/`
  - 실측: `fail-fast` 가 있던 곳은 `ci.yml`·`dotnet-ci.yml` **둘뿐**(등록부는 셋만 적었다 — 과소계수). 나머지 여섯(go·node·php·python·ruby·rust)은 GitHub 기본값 `fail-fast: true` 였다.
  - **여덟 전부 하한 레그가 매니페스트 하한과 정확히 일치한다**: java 17(`maven.compiler.release`) · dotnet net8.0(TFM) · go 1.25(`go.mod`) · node 22(`engines`) · php 8.3(`composer.json`) · python 3.10(`requires-python`) · ruby 3.2(`gemspec`) · rust 1.88(`rust-version`).
  - ⚠️ **하한 레그가 유일한 검증이다** — `check-docs.mjs:534-540` 이 하한을 읽지만 그건 `kind=runtime` 앵커용, 즉 **문서가 하한을 옳게 적었는가**만 본다. 코드가 그 하한에서 실제로 도는지는 이 레그뿐이다.
  - ⚠️ **머지 규칙은 안 바뀐다** — required 는 `doc-facts`·`shell-exec-bits` 둘뿐이라(`.github/rulesets/main.json:43-49`) 언어 CI 는 애초에 머지를 막지 않는다. 이 변경이 사는 것은 **진단**이지 차단이 아니다.
  - **회귀 가드**: `test-selftest-hygiene.sh` 규칙 8 — 매트릭스가 있는데 `fail-fast` 가 없으면 실패. 3요건 실측: 변이(rust-ci 의 줄 삭제) → `135 passed, 1 failed` · 복원 → `136/0` · 구 스크립트 + 같은 변이 → **`134 passed, 0 failed`**(새 규칙이 원인 확정). 공허 방지로 「매트릭스 보유 워크플로 ≥ 8」 하한을 함께 둔다.
  - 함께: `ci.yml:27-28` 주석이 `maven.compiler.release=21`·`[21,)` 라 적었으나 pom 은 **17**(`java/pom.xml:61`)·`[17,)`(`:188`) 다 — 실측해 정정했다.
- [ ] `jvm-17-floor-never-shipped` **[H/M · 신규 2026-09-06]** #389 가 소비자 하한을 21→17 로 내렸으나 **게시된 적이 없다** — Maven Central 의 `1.0.0` 은 여전히 JDK 21 을 요구한다 · `java/pom.xml:61` · `kotlin/build.gradle.kts:50`
  - 실측: `git show v1.0.0:java/pom.xml` → `<maven.compiler.release>21`. `kotlin-v1.0.0` 은 `jvmToolchain(21)` 만 있고 `jvmTarget`·`-Xjdk-release` 가 **없어** 바이트코드도 21(트리 주석 `kotlin/build.gradle.kts:47` 이 그 인과를 적는다). 태그 `v1.0.0` 2026-09-01 · 하향 커밋 `6a9d620` 2026-09-04 · **그 뒤 JVM 릴리스 0건**(`git tag -l 'v*' 'kotlin-v*'`).
  - **문서 쪽은 닫았다**(이 항목이 남긴 것은 릴리스뿐): `getting-started.md` 의 java·kotlin 절이 「트리 17 / 게시본 21」을 함께 말하고 재확인 명령을 든다. `compatibility.md`·`kotlin/README.md`·양쪽 README 는 21 을 **게시본 값으로 명시**해, 다음 세션이 트리를 보고 「고치려다」 거짓으로 만드는 것을 막는다.
  - ⚠️ **비가역 · 사람 승인 게이트.** JVM 패치 릴리스(`v1.0.1`·`kotlin-v1.0.1`)를 내야 17 이 소비자에게 닿는다. 릴리스 시 **함께** 내려야 하는 자리: `getting-started.md`(표 2행 + 가드 문단 2개) · `compatibility.md`(경고 문단 + JVM 2행) · `kotlin/README.md:11` · `README.md:103,111` · `README.ko.md:103,111`.
  - ⚠️ 이 항목을 닫기 전에 아래 `registry-contract-claims-use-tree-oracle` 를 먼저 볼 것 — 같은 부류가 다른 주장에도 있다.
- [x] `registry-contract-claims-use-tree-oracle` **[H/L · 신규 2026-09-06 · 닫힘 2026-09-06 #415]** `doc-guard: kind=runtime` 이 **작업 트리**를 오라클로 썼다 — 소비자가 받는 것은 태그·레지스트리라, 트리가 맞는 동안 소비자에게 거짓을 **집행**할 수 있다 · `scripts/check-docs.mjs:526-545`
  - 실현된 사례가 위 `jvm-17-floor-never-shipped` 다. 가드는 **초록이었다** — 문서(17)와 `java/pom.xml`(17)이 일치했기 때문이고, 그동안 소비자는 21 짜리 jar 를 받고 있었다. 가드 설계 자체는 옳다(주석이 `jvmToolchain` 대신 `jvmTarget` 을 읽는 이유를 정확히 적는다) — 빠진 것은 「**어느 빌드가 방출한 것인가**」다.
  - **부류를 찾는 시험**: 「**소비자가 틀릴 수 있는데 HEAD 는 맞다면, 오라클은 트리가 아니라 태그·레지스트리다.**」 해당 후보 — 바이트코드/언어/MSRV 하한 · 게시된 공개 API 표면 · 게시 매니페스트의 의존성 하한 · 릴리스 바이너리에 컴파일된 기능 · 배포 아티팩트의 라이선스 · 「vX 에 포함됨」류 CHANGELOG 결속.
  - **닫힘(#415).** `kind=runtime` 이 오라클 둘을 갖는다 — 트리(=곧)와 **최신 릴리스 태그**(=지금, `git show <tag>:<manifest>`). 격차가 있으면 앵커의 `published=<게시본 값>` 과 **본문의 그 값**을 요구하고 없으면 fail-closed, 릴리스로 격차가 닫히면 잔여 속성을 **반대 방향으로** 실패시킨다. 소스 하향 자체는 막지 않는다 — 막는 것은 **기록되지 않은 주장**이다. 즉시 잡힌 것은 java(트리 17 ↔ `v1.0.0` 21)와 kotlin(트리 17 ↔ `kotlin-v1.0.0` 21), 나머지 일곱은 오탐 0.
  - **3요건 실측**: 신 가드 **212 passed / 0 failed** · 구 가드 + 같은 케이스 **200 passed / 9 failed**(새 규칙이 원인 확정) · 대조군으로 「저장소가 아니면 오라클 B 가 안 돈다」를 고정.
  - ⚠️ **공허해지는 경로 둘을 실측으로 막았다.** (1) 태그 이름이 비면 `git show ":path"` 가 **인덱스**를 읽어 트리와 같은 값을 돌려준다 — 그래서 `rev-parse --verify` 로 먼저 해석하고, 태그가 하나도 안 잡히면 스킵이 아니라 **실패**한다(`repo-hygiene.yml` 의 `fetch-tags: true` 가 짝). (2) 버전 문자열 정렬은 `v1.0.0 < v1.0.0-RC1` 로 **RC 를 정식보다 뒤에** 세운다 — `--sort=-creatordate` 로 고른다.
  - ⚠️ **독립 검증 레그가 잡은 오탐부재 하나**: 본문 대조가 맨 `includes` 면 게시본 `>=2` 가 `>=24` 안에 걸려 통과한다. 토큰 경계를 넣되 **뒤쪽 점은 막지 않는다**(문장 끝 `… JDK 21.` 이 거짓 실패한다).
  - ⚠️ 남은 것: `kind=runtime` 앵커가 **없는** 문서(`README*.md` · `compatibility.md` · `kotlin/README.md`)는 여전히 기계 대조 밖이다. 그 자리를 사람 쪽에서 붙드는 것이 아래 `consumer-floor-change-…` 다.
- [x] `consumer-floor-change-needs-release-or-registered-gap` **[M/S · 신규 2026-09-06 · 닫힘 2026-09-06 #415]** 소비자 가시 하한을 바꾸는 PR 이 릴리스 없이 머지되면 문서가 즉시 거짓이 된다 — 기각 체크리스트에 항목이 없었다 · `docs/governance/process.md`
  - #389 가 그 경로로 갔다. 규칙안(독립 검증 레그 판정): 「소비자 가시 하한 변경은 **같은 체인지셋의 릴리스**를 동반하거나, **등록된 후속**이 게시본 값을 주장하는 모든 문서를 붙들어야 한다」. 선언 하나만으로는 과대제약이 아니다 — **선택지 둘 중 하나**라는 형태가 핵심이다(릴리스는 사람 게이트라 강제할 수 없다).
  - **닫힘(#415).** `process.md` §3 에 **8번**으로 들어갔다(체크리스트가 7→8 항목이 되어 `CLAUDE.md`·§1 표·③ 절의 계수도 함께 옮겼다). ⑥ 검증은 백스톱이지 소유자가 아니다 — 기존 가드는 **검증을 했고, 오라클이 틀렸다**.
  - ⚠️ **doc-budget 여유가 9B 였다.** 초안 1015B 를 288B 로 압축한 뒤에도 초과라, 래칫을 19400→19700 으로 올렸다(**사람 판정 2026-09-06**). 조건 (1)로 적었으나 통상 지표(facts/anchors 상승)가 아니라 **같은 PR 의 가드 + 자가테스트 3요건**이 대가다 — facts 를 안 올린 이유는 격차가 릴리스로 닫히면 사라져 「릴리스하면 CI 가 빨개진다」가 되기 때문이다.
- [x] `doc-audit-batch1-remainder` **[H/L · 신규 2026-09-06 · 닫힘 2026-09-06 #416]** 소비자 문서 배치 1(10개) 감사의 **잔여 9건** — 인용 181건 전건 실재(계측기 5/5 자가검증), 반박 10건 중 2건 refuted · `docs/guides/` · `docs/reference/`
  - **닫힘 내역: 7건 수정 · 2건 반박 확정(무변경).** 수정 (1)(3)(4)(5)(6)(7)(8) · 무변경 (2)(9).
  - **(1)이 부류가 달랐다 — 문서 오류가 아니라 보안 위험이다.** 실서버 실측(Keycloak **26.6.4**, `--users` 기본값 `different_files`): `kc.sh export --dir … --realm master` 가 `master-users-0.json` 을 함께 쓰고 그 안에 `credentials[].secretData` — **argon2 해시와 salt** 가 평문 JSON 으로 들어 있다. 주석은 「user passwords excluded by default」라 적고 있었다. 대조군 `--users skip` → 파일 하나(`master-realm.json`) · `secretData` **0건**.
  - ⚠️ **(9)의 「DEPLOY.md F1~F5」 중 원장이 이름을 적은 것은 셋뿐이고**(:95↔:441 npm OIDC 모순 · `git tag -l 'node-*'` 6개 · :186 「Node and Ruby remain」), 그 셋을 고쳤다. 나머지 둘이 무엇이었는지는 원장에 없다 — 워크플로 산출물에만 있었다면 **회수 불가**다.
  - ⚠️ **문서 셋이 예산에 붙어 있어 정확성 수정이 예산을 넘겼다.** CONTRIBUTING 15856→15940 · DEPLOY 79274→79510. 둘 다 먼저 압축했고(경위 서술을 커밋으로 보냈다) 남은 순증만 올렸다. `process.md` 는 별건으로 #415 에서 19400→19700.
  - ⚠️ **착수 전 필독 — 반박자가 감사자의 수치를 여러 건 정정했다.** 특히 여러 감사자가 처방에 `--min-facts=64 --min-anchors=21` 을 전제로 썼는데 이 트리는 이미 **74/22** 다(`repo-hygiene.yml:87`·`CLAUDE.md:69`). 감사 처방의 숫자를 그대로 옮기지 말 것.
  - **(1) `docs/guides/deploying-keycloak-server.md` [H]** §7 백업 절차 181행 주석 `# per-realm export (config-focused — user passwords excluded by default)` 이 26.6.4 서버에서 거짓 — 바로 아랫줄 명령을 그대로 돌리면 `--users` 관련 동작이 다르다. 반박 통과.
  - **(2) `docs/guides/development-setup.md` [H]** §3 환경변수 표가 `KCSDK_PY` 를 저장소 루트 기준(`python/.venv/...`)으로 적으나 실제 해석 기준이 다르다. ⚠️ **반박자가 F2 는 채택하지 말라고 판정** — 75행 셀은 참이고, `KCSDK_TOOLS` 가 무엇을 고르는지는 `doctor.mjs:122-132` 의 `toolsChildDirs()` 가 정한다(실측으로 67행 레이아웃이 그대로 동작).
  - **(3) `CONTRIBUTING.md` [H]** §4 254-258행 — `.claude/rules/ci.md:44` 가 **이 문서를 소유자로 명시**한 열거(「enumerated in CONTRIBUTING §4 — do not copy it here」)가 틀렸다. 개수가 4가 아니다. 반박자 처방: `**Four**`→`**Three**`, `build-test` 지목 삭제(php 는 인라인 matrix 라 맨 `build-test` 컨텍스트가 **존재조차 안 한다**), **같은 커밋에서** `ci.md:44` 의 `**four** pairs` 도 함께 고칠 것.
  - **(4) `SECURITY.md` [M]** 90·92행이 존재하지 않는 분기를 가르친다 — 「`26.6.4` for Java and Python, `26.6` for the others」인데 실측하면 아홉이 전부 같은 태그다.
  - **(5) `DEPLOY.md` [M]** §4 「릴리스 PR 머지」 경로가 **적힌 대로 따르면 작동하지 않는다** — 태그를 만드는 유일한 트리거는 `.github/release-request.json` 의 push 인데(`dispatch-release.yml:18`) §4 절차 어디에도 그 파일이 없다. ⚠️ 반박자 정정: 「블록쿼트 8개」는 과소계수, **9개**(71·143·206·266·354·421·490·559·630)이고 바이트도 8,733 이 아니라 **8,744**.
  - **(6) `README.ko.md` [M]** = README.md 의 `expiresAt` 건과 같은 자리(117행). **PHP·Ruby 가 미만료로 본다**는 서술이 거짓 — #399 가 아홉 전부 「미상=만료」로 통일했다(`php TokenSet.php:75-76` · `ruby tokens.rb:25` · `java TokenSet.java:20`). ⚠️ 반박자: 대체 문구에 **미측정 단정을 넣지 말 것**(`ls php/vendor` 부재라 이 트리에서 못 잰다).
  - **(7) `README.md` 잔여 [M]** 118행 `list pagination is explicit in Rust and Go` → 실제 **넷**(Rust·Go·Java·Kotlin). SSOT 는 `admin-capability.md:81`. 이 세션에 반복된 과소계수 부류.
  - **(8) `docs/reference/admin-capability.md` [M]** 42행 「Partial updates behave differently per library」 — 이 문서의 존재 이유가 언어 간 포팅인데 그 서술이 어긋난다. ⚠️ 반박자: 사본 계수 정정 — 출처는 `kotlin-ci.yml:57` 이 아니라 **`ci.yml:62-63`**.
  - **(9) `docs/guides/getting-started.md` 잔여 [M]** 538행 `(dev/CI top end 3.4)` — ruby CI 는 `['3.2','3.3','3.4','4.0']`. **반박됨**이나 DEPLOY.md 쪽 5건(F1~F5)이 실측으로 살아남았다: :95 가 npm OIDC 를 증명 완료라 하는데 :441 은 `still not evidenced … the one publish so far used a token` 이라 하고, `git tag -l 'node-*'` 는 **6개**를 보인다(「one publish」도 거짓). :186 `Node and Ruby remain.` 도 :188·:95 와 모순.
  - 재현: 워크플로 `doc-audit-consumer-batch1`(run `wf_444f054c-58a`) · 핀 `3c306a0` · 인용 게이트 `scratchpad/citegate2.mjs`(계측기 자가검증 내장).
- [ ] `doc-audit-batch2-3-not-started` **[M/L · 신규 2026-09-06]** 문서 41개 중 **20개가 현재 트리에서 미검증** — 배치 2(언어별 README 9 + `language-support.md`), 배치 3(하네스·내부 7 + 1차 확정 3건 재검증)
  - ⚠️ **1차 확정 3건(`go.md`·`python.md`·`java.md`)도 재검증 대상이다** — 낡은 트리(4b40445)에서 판정됐고 그 뒤 커밋 7건·`.md` 12개가 움직였다. 자체 변경은 `go.md` 1건뿐이라 위험은 낮으니 배치 3 마지막에 둘 것.
  - 방법은 배치 1과 동일: 고정 스냅샷(`git worktree` · **커밋된 상태로**) · 구조화 인용 `(path,line,exact_quote)` · 인용 게이트 선실행 · **렌즈 하나 + 실행강제**(「X 가 소유한다」·「N 개가 전부」는 조회를 실행해 출력을 붙일 것) · 서브에이전트에 `git config` 금지 명시.
  - 회수율 실측: 배치 1 은 10개 문서에서 **H 4건 포함 전건 지적**, 그중 최고가치는 **가드가 소비자에게 거짓을 집행하던 것**이었다(`jvm-17-floor-never-shipped`). 소비자 문서가 내부 규칙 파일보다 안전할 것이라는 사전 가정은 **틀렸다**.
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

- [x] `selftest-enforcer-cannot-guard-itself` **[H/M]** 자가테스트 종료코드 규약의 집행자가 자기 자신과 '실패 삼킴'을 못 본다 · `scripts/test/test-selftest-hygiene.sh:19`
  - ⚠️ **범위가 「자기 자신」보다 26배 넓다.** 규칙 1 은 `grep -q 'assert_report' "$f"` 라 **raw 텍스트**를 본다 — 주석 처리된 `# assert_report` 도 통과한다(실측: 그런 파일을 만들어 `grep -q` 를 돌리면 히트). 루프가 `test-*.sh` **26개 전부**를 도니 약점도 26개 전부에 걸린다.
  - **닫힘(#405).** 판정을 구조적으로 바꿨다 — 주석을 걷어낸 뒤 **단독 호출 줄**(`^\s*assert_report\s*$`)만 세고, 그것이 **마지막 실행 명령**인지까지 본다. 자기 제외(`continue`)를 지워 집행자도 같은 규칙을 받는다. 실측: 26개 파일 전부 통과(오탐 0) · 옛 판정이 통과시키던 4형태(주석 · `|| true` · 문자열 · 자기 인용) 전부 거부 · dash(`debian:stable-slim`)에서 동일.
  - ⚠️ **활성 아니라 잠복이었다** — 실제 코퍼스에 위반 0건. 다만 `test-check-versions.sh`·`test-publication-claims.sh` 둘은 본문에 `assert_report` 를 주석으로도 인용해, **진짜 호출을 지워도 규칙 1이 초록**이었다(실측 2/25).
  - ⚠️ **집행자 자신은 아무도 안 봤다** — 그 파일의 `assert_report` 를 주석 처리하면 **exit 0 · 출력 0줄**이었고, 저장소 전체 grep 으로 그것을 겨누는 다른 가드가 **0건**이었다.
  - **재발 시 CI 가 잡는 자리**: `repo-hygiene.yml` 의 `sh scripts/test/test-selftest-hygiene.sh`(required `doc-facts` 잡). 가드 3요건 — 변이(집행자 자신의 호출 제거) → 2 FAIL · 복원 → 129 passed · 가드 OFF(이 커밋 이전 스크립트) + 같은 변이 → **exit 0**.
  - ⚠️ **대조군을 사본으로 쓰면 공허하다** — 정규식을 대조군에 베껴 적었더니 본체를 옛 `grep -q` 로 되돌려도 **129 passed 0 failed 로 변이가 살아남았다**. 판정을 `mjs_wired()` 로 뽑아 대조군이 **본체를 부르게** 한 뒤에야 그 변이가 죽는다(127 passed 2 failed).
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

- [x] `selftest-hygiene-textual-rules` **[H/M]** '존재'가 아니라 '실행'을 센다던 규칙이 주석·비활성화·`|| true`를 실행으로 센다 · `scripts/test/test-selftest-hygiene.sh:20`
  - **닫힘(#405)** — `selftest-enforcer-cannot-guard-itself` 와 **같은 뿌리**이고 같은 커밋에서 함께 닫혔다(구조적 판정 + 마지막 실행 명령). 실측·가드는 그 항목에 적었다.
- [ ] `coverage-exclusions-swallow-pure-logic` **[H/L]** '네트워크 경계' 커버리지 제외가 I/O 없는 순수 로직까지 삼켰다 — 다섯 언어 · `node/src/transport.ts:38`
- [ ] `security-invariant-use-site-scope` **[H/M]** 보안 불변식의 '2차 정의 자리 금지'가 아홉 중 셋만 본다 — 미검사 언어에 리터럴 네 곳이 살아 있다 · `scripts/test/test-security-defaults.sh:297`
- [ ] `selftest-assert-counter-subshell` **[M/M]** 어서션 카운터가 서브셸에서 증발한다 — 자가테스트 프레임워크의 구조적 맹점 · `scripts/test/assert.sh:10`
- [ ] `guard-paths-never-exercised` **[M/M]** 자가테스트가 가드의 한 경로만 태워, 나머지 경로를 지워도 초록이다 · `scripts/test/test-check-coverage.sh:41`
- [ ] `selftests-with-no-negative-case` **[M/L]** 일곱 자가테스트가 라이브 상태만 단언한다 — 판정기가 나쁜 입력을 거부한다는 증거가 없다 · `scripts/test/test-deploy-md.sh:7`
- [ ] `probes-that-discard-the-result` **[M/M]** 프로브가 결과를 버린다 — 예외 타입 미단언·반환값 미단언 · `php/tests/Unit/Jwks/JwksStoreTest.php:188`
- [ ] `wall-clock-ordering-in-tests` **[M/M]** 동시성·시간창 테스트가 벽시계에 매달려 있다 — 조용한 퇴화와 거짓 실패 · `go/jwt_test.go:322`

### 가드·CI — 16

- [ ] `selftest-exit-code-contract-two-leaks` **[H/M]** 자가테스트의 「실패하면 비영 종료」 계약이 두 곳에서 샌다 — 탐지기도 계수기도 · `scripts/test/test-selftest-hygiene.sh:20`
  - **절반 닫힘(#405) — 탐지기 쪽만.** 집행자가 「등장」을 「호출」로 세던 것을 구조적 판정으로 바꿨다(`selftest-enforcer-cannot-guard-itself` 참조).
  - ⚠️ **계수기 쪽은 그대로 열려 있다** — `assert.sh` 의 `_A_FAIL` 이 서브셸에서 증발하는 문제이고, 아래 `selftest-assert-counter-subshell` 이 그 자리를 소유한다. **둘을 한 항목으로 읽어 닫지 말 것.**
- [ ] `sweeps-without-vacuity-floor` **[H/M]** 세 개의 스윕/스캔이 0건을 훑고 통과한다 — 이 저장소의 하한 관용이 적용되지 않았다 · `.github/workflows/repo-hygiene.yml:234`
- [ ] `seven-selftests-have-no-negative-control` **[H/L]** 일곱 자가테스트가 라이브 상태만 단언한다 — 검출기를 지워도 통과한다 · `scripts/test/test-deploy-md.sh:7`
- [ ] `irreversible-publish-no-reentry` **[H/M]** 비가역 게시 뒤 재진입 경로가 없다 — 세 레인의 gh release create와 php 미러 순서 · `.github/workflows/go-release.yml:156`
- [ ] `operator-commands-that-do-not-work` **[H/S]** 저장소가 사람에게 시키는 명령 둘이 실제로는 원하는 답을 주지 않는다 · `scripts/release-trigger.sh:53`
- [x] `guard-neutering-wiring-unprotected` **[H/M]** [세션 발견·원장 밖] 가드 스텝을 무력화하는 배선이 무보호다 — 워킹트리에 continue-on-error가 살아 있다 · `.github/workflows/repo-hygiene.yml:119`
- [ ] `guard-probes-count-mentions-not-declarations` **[M/S]** 가드 프로브가 「선언」이 아니라 「문자열 등장」을 센다 — 배선 규칙 3과 node update 프로브 · `scripts/test/test-selftest-hygiene.sh:84`
  - **절반 닫힘(#405) — 배선 규칙 3 만.** `grep -q "node $m"` 의 두 누수를 규칙 2 와 같은 엄격도로 맞췄다(실측: 경로 미이스케이프로 `install-matrixXtest.mjs` 가 매치 · 단어경계 없어 `node <path>.disabled` 도 배선으로 계수 — 3파일 × 2형태 = 6건).
  - ⚠️ **「node update 프로브」를 찾지 못했다 — 그래서 닫지 않는다.** 다음 검색이 전부 0건이다: `grep -rn "npm update\|node update" scripts/test/*.sh` · `grep -rn "grep -q \"" scripts/test/*.sh`(자가테스트 2건은 무관: LICENSE 문자열·주석). 원장의 그 절반이 **다른 파일을 가리키거나 서술이 부정확**하다 — 착수 전 기계용 원장(`ledger-dedup.json`)에서 이 항목의 원문을 먼저 볼 것.
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
- [ ] `sonar-suppression-premises` **[M/M]** sonar 억제 셋의 근거가 트리 안의 다른 사실에 묶여 있는데, 그 사실이 바뀌면 억제가 오탐이 아니라 진짜를 숨긴다 · `sonar-project.properties:200`
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
