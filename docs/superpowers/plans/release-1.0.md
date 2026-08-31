<!-- doc-status: active -->

# 1.0 릴리스 기준

**이 문서가 답하는 것 하나** — 「무엇이 참이어야 1.0 을 붙일 수 있는가, 그리고 그것을 **어떤 명령으로** 확인하는가」.

기준은 산문이 아니라 **돌아가는 명령**이다. 각 항목의 「검증」칸을 그대로 붙여 넣으면 판정이 재현된다. 붙일 출력이 없는 항목은 기준이 아니라 희망이므로 여기에 두지 않는다.

⚠️ **1.0 은 기능이 아니라 약속이다.** 새 기능이 쌓여서 1.0 이 되는 것이 아니라, **호환성 약속을 지킬 수단이 갖춰져서** 1.0 이 된다. 그래서 기준의 대부분이 게이트다.

---

## 1. 1.0 이 약속하는 것 / 약속하지 않는 것

| | |
|---|---|
| **약속한다** | 공개 API 를 major 없이 깨지 않는다 · 깨지면 기계가 막는다(§2 A) · 보안 기본선은 아홉 언어가 함께 움직인다(§2 B) · 실서버 E2E 를 통과한 것만 나간다(§2 C) · 게시본은 레지스트리에서 실제로 설치돼 돌아간다(§2 E) |
| **약속하지 않는다** | 언어 간 **버전 번호 정렬**(번호는 언어별 독립이다) · LTS 라인 · 옛 minor 백포트 · 하위 라이브러리 타입의 안정성(§4(b) 예외 자리) |

⚠️ **아홉 언어가 같은 날 같은 번호가 되는 것을 1.0 의 뜻으로 삼지 않는다.** 이 저장소는 「함대 번호로 말하지 말 것」을 이미 규칙으로 갖고 있다. 1.0 은 **약속이 붙는 사건**이고, 그 약속은 아홉 곳에서 같지만 번호는 각자다.

---

## 2. 기준 — 명령과 실측 (2026-08-30 측정)

### A. 공개 API 파괴적 변경을 기계가 막는다 — **충족(9/9)**

| 레인 | 도구 | 기준선 | 판정 근거 |
|---|---|---|---|
| java | japicmp (maven `verify`) | 게시 JAR `0.1.0` | 플러그인 종료코드 |
| kotlin | japicmp CLI | 게시 JAR `0.1.0` | `--error-on-binary-incompatibility` |
| rust | cargo-semver-checks | crates.io 직전판 | 종료코드 |
| python | griffe check | `py-v1.0.0` 태그 | 종료코드 |
| dotnet | SDK Package Validation | NuGet `1.0.0` | `dotnet pack` 실패 |
| **go** | gorelease | 추론 기준선 | ⚠️ **본문**(`^## incompatible changes`) |
| **php** | php-semver-checker | `php-v0.2.0` 태그 | ⚠️ **본문**(`… change: MAJOR`) |
| **ruby** | yard diff | `ruby-v1.0.0` 태그 | ⚠️ **본문**(`^D `) |
| **node** | api-extractor ×2 | npm `1.0.0` tarball | ⚠️ **본문**(`^< `) |

⚠️ **아홉 중 넷은 도구 종료코드가 거짓말한다** — 파괴적 변경을 정확히 **출력하고도 exit 0** 이다. 그 넷은 리포트 본문을 근거로 삼는다. 새 레인을 붙일 때 가장 먼저 확인할 것이 이것이다.

⚠️ **커버리지가 좁은 둘을 감추지 않는다.**

- **ruby** — `yard diff` 는 **삭제만** 잡는다. 시그니처·arity 변경은 못 잡는다(yard 의 "modified" 는 메서드 소스 텍스트다). 생태계에 등가 도구가 없다.
- **node** — 줄 텍스트 비교라 타입 호환성을 모른다. 실측된 오차 둘: 선택적 매개변수 추가는 **비파괴적인데 실패**(안전한 방향), 입력 인터페이스에 **필수 필드 추가는 파괴적인데 통과**(안전하지 않은 방향).

**이 두 자리는 리뷰가 막는다. 기계가 막는다고 쓰지 않는다.**

⚠️ **아홉 게이트가 전부 보는 것은 「표면」이다 — 표면이 그대로인 채 동작이 바뀌는 파괴는 아홉 중 어느 것도 못 본다.** 예: `clockSkew` 기본값을 30 초에서 300 초로 바꾸면 타입도 시그니처도 그대로다. 그 부류 중 **보안 기본선만** §2 B 가 덮는다(그래서 B 가 A 와 별개 기준이다). 나머지 동작 파괴는 기계가 보지 않는다.

- [x] **A-1** 위 표를 소비자 문서에 옮긴다 — 「무엇이 기계로 보증되고 무엇이 아닌가」는 소비자가 알아야 한다. → **P-2b 에서 이미 옮겨졌고 체크만 남아 있었다**(2026-08-31 실측). 경고 (iii) 표면-한계는 아홉 `<lang>/README.md` 의 `## Versioning and support` 전부 + `SECURITY.md:59`, 경고 (ii) 협소한 둘은 `ruby/README.md`(「삭제만 잡는다」)·`node/README.md`(「필수 필드 추가는 통과」)에 **각 레인의 말로**, 경고 (i) 종료코드 거짓말은 소비자가 행동할 수 있는 형태(`judged on its report body` — go·php)로 들어가 있다.
  - ⚠️ **`compatibility.md` 에 표를 새로 넣지 않는다** — 그 파일이 소유한 것은 「게시 버전별 서버 범위 + 기반 라이브러리」이고, 도구명·한계는 `SECURITY.md`(함대)와 아홉 README(레인별)가 이미 소유한다. 세 번째 사본이 되고 SSOT 가 없다. 기준선 값을 소비자 표에 적으면 **P-4 가 도는 날 거짓이 된다**.

### B. 보안 기본선이 아홉 언어에서 함께 움직인다 — **충족**

```
sh scripts/test/test-security-defaults.sh     → 108 passed, 0 failed
```

### C. 실서버 통합 E2E — **충족(9/9)**

아홉 레인 전부 `integration` 잡을 갖고, 실제 Keycloak 26.6 을 띄운다.

```
grep -cE '^  integration' .github/workflows/*ci.yml    → 9개 파일 전부 ≥1
```

### D. 커버리지 게이트 — **충족(9/9)**

⚠️ **일곱은 워크플로에, 둘은 빌드파일에 있다** — 워크플로만 세면 7/9 로 보인다. java 는 `jacoco:check`(`verify` 바인딩), node 는 `vitest.config.ts` 의 `thresholds`.

### E. 게시본이 레지스트리에서 실제로 설치돼 돌아간다 — **충족(9/9)**

```
ls harness/install/consume/*-run.sh | wc -l          → 9
grep -l PROVENANCE_OK harness/install/consume/*-run.sh | wc -l   → 9
```

⚠️ **출처 검증은 설정이 아니라 실제 다운로드 출처를 본다** — 로컬 레지스트리에서 오지 않았으면 `installed.ok` 를 쓰지 않는다.

### F. 릴리스 경로가 fail-closed — **충족**

```
sh scripts/test/test-release-prerelease.sh   → 34 passed, 0 failed
sh scripts/test/test-repo-config.sh          → 44 passed, 0 failed
sh scripts/test/test-harness-registries.sh   → 65 passed, 0 failed
```

⚠️ **로컬 게이트의 초록은 게시 승인이 아니다.** 계정 상태·토큰 종류·이메일 인증·2FA·Portal 클릭은 어떤 로컬 명령도 보지 못한다.

### G. 문서가 매니페스트와 기계 대조된다 — **충족**

```
node scripts/check-docs.mjs . --strict --min-facts=64 --min-anchors=21 --min-anchor-links=24
```

⚠️ **숫자 없는 사실 주장은 이 가드의 사각지대다.** 실측 사례 — `SECURITY.md` 가 「아직 아홉 중 후속 릴리스를 낸 것이 없다」고 적고 있었고 여섯 레인에서 거짓이었는데, 문장에 숫자가 없어 앵커가 걸리지 않았다.

- [x] **G-1** 1.0 표기를 넣을 때 `compatibility.md`·`SECURITY.md`·양쪽 README 를 한 번에 옮긴다(버전 문자열의 SSOT 는 `deploy-facts.sh`). → **네 문서 전부 `1.0.0`, 구버전 잔재 0건**(2026-08-31 실측: `compatibility.md` 아홉 행 · `SECURITY.md` · `README.md` · `README.ko.md`).
  - ⚠️ **그런데 이 가드가 잡지 못한 잔재가 두 자리 있었다** — 루트 README 영·한이 「전부 pre-1.0」과 「전부 정식 게시」를 한 문장에서 말하고 있었다(#344). 숫자가 없는 주장이라 앵커가 걸리지 않았고, 배지 가드는 이미지 토큰만 본다. 지금은 `test-publication-claims.sh` 가 **문장 단위 부정 단언**으로 막는다.

---

## 3. 남은 일

⚠️ **P-2·P-3 을 P-4 앞에 두면 안 된다. 초안이 그렇게 적혀 있었고 틀렸다.** 게이트 기준선은 「**게시된** 직전 버전」이라, 게시 전에 `1.0.0` 으로 올리면 존재하지 않는 것을 받으러 간다 — 실측: `npm pack @xzawed/keycloak-sdk@1.0.0` → `ETARGET no matching version`, `repo1…/1.0.0/…jar` → `HTTP 404`. **fail-closed 라 잡히기는 하지만, 잡히는 자리가 버전을 올리는 그 PR 이다.** 같은 이유로 `df_published_version` 과 그것에 매달린 문서(`compatibility.md`)도 게시 **뒤**에 움직인다.

- [x] **P-1 정책 판정: 아홉을 언제 1.0 으로 올리는가.** → **아홉 전부 `1.0.0` 동시**(2026-08-30, 사람 판정). §2 A–G 가 아홉 곳에서 동시에 충족돼 자격이 같은 날 생겼고, 약속이 아홉에서 같으므로 번호도 같아진다. ⚠️ **이후에는 다시 각자 움직인다** — 이번 정렬은 우연이지 정책이 아니다.
- [x] **P-2 매니페스트 버전을 올린다.** 일곱 언어에 자리가 있고 go·php 는 태그가 SSOT다. ⚠️ **하네스 앱 핀 둘과 락파일 셋이 같은 커밋에서 따라와야 한다** — `check-versions.mjs` 가 잡는다(실측: 이 범프에서 4건을 잡았다).
- [x] **P-2b 게시되는 문서를 태그 _전에_ 고친다.** ⚠️ **P-2 만 하고 태그를 밀면 아홉 좌표가 「아직 pre-1.0」이라고 말하는 페이지로 영구 고정된다** — 레지스트리는 README 를 **버전마다** 고정한다. 릴리스 전 감사에서 아홉 레인 전부가 그 상태였다(rust `0.1.1 is on crates.io … pre-1.0` · node `a bare install resolves 0.2.1` · python 분류자 `4 - Beta`). 이 저장소는 같은 부류로 **이미 두 번 문서 전용 릴리스를 냈다**(`0.1.1` #318 · `0.2.1` a7629ef). 옮길 자리: 아홉 `<lang>/README.md` · 루트 README 영·한 · `SECURITY.md` · `compatibility.md` · `getting-started.md` · `language-support.md` · `CLAUDE.md` · `DEPLOY.md` · `CHANGELOG.md` · `python/pyproject.toml` 분류자 · **SSOT `df_published_version`**. 판정은 `sh scripts/test/test-publication-claims.sh`(60 failed → 0 failed 로 몰아간다).
- [ ] **P-3 태그 푸시(사람·비가역)** `[!]` — 좌표 하나당 버전 하나는 되돌릴 수 없다. Maven Central 은 워크플로 초록 뒤에도 Portal 클릭과 전파 지연이 남는다. **404 로 실패를 결론내지 않는다.**
- [ ] **P-4 게시 확인 뒤 API 게이트 기준선 7자리를 올린다.** `python-ci.yml`(`--against`)·`dotnet` csproj(`PackageValidationBaselineVersion`)·`ruby-ci.yml`(`BASELINE`)·`node-ci.yml`(`BASELINE`) **완료** — 그 넷만 `1.0.0` 이 실제 게시됐다. 남은 셋: `java/pom.xml`(`japicmp.baseline`) · `kotlin-ci.yml`(`BASELINE`) · `php-ci.yml`(태그). ⚠️ **게시 전에는 못 올린다** — 없는 버전을 받으러 간다(위 경고). 안 올리면 각 README 의 「직전 게시본과 대조한다」가 다음 릴리스부터 거짓이 된다.
  - ⚠️ **「기준선 == 현재 버전이면 게이트가 공허하다」는 틀렸다** — 감사 초안이 그렇게 적었고 **변이로 반증했다**. dotnet 은 `csproj` 의 `<Version>` 도 `1.0.0` 이라 둘이 같아지는데, `AuthClient.LogoutAsync` 를 `public` → `internal` 로 바꾸자 `error CP0002 … [기준선]에는 있지만 …에는 없습니다` 로 **rc=1** 이 났다. Package Validation 이 비교하는 것은 버전 번호가 아니라 **패키지 내용**이다.
  - ⚠️ **로컬에서 잴 때 NuGet HTTP 캐시를 먼저 비운다.** 게시 직후 `NU1102 … 3 버전을 찾았습니다` 가 나와 「미게시」로 오독했는데, 레지스트리는 이미 네 개를 서빙 중이었다. `dotnet nuget locals http-cache --clear` 뒤 rc=0.
  - ⚠️ **선행조건이 둘로 갈린다.** `php`·`ruby` 는 `git archive <태그>` 로 읽으므로 **태그만** 있으면 되고, `java`·`kotlin`·`node`·`dotnet` 은 **원격 아티팩트**가 실제로 받아져야 한다(전파 지연을 폴링한다). 태그 직후 여섯을 한 PR 로 묶으면 뒤 넷이 404 로 죽는다.
  - ⚠️ **범프의 근거를 「돌렸더니 rc=0」으로 적지 말 것.** python 실측: `py-v1.0.0`·`py-v0.2.1` 둘 다 rc=0 이다 — `python/src` 가 무변경이라 **어느 기준선이든 통과하는 공허한 초록**이다. 참인 근거는 「기준선 ref 가 존재해 fail-closed 로 깨지지 않는다」이고, 그 대조군이 `--against py-v9.9.9` → **rc=1**(조용히 건너뛰지 않는다)이다.

---

## 4. 이 문서를 닫는 조건

P-1~P-4 와 A-1·G-1 이 전부 체크되면 `doc-status` 를 `complete` 로 내리고 아카이브 태그로 옮긴 뒤 `docs/README.md` §3 에서 지운다. **미체크가 0 인데 `active` 로 남으면 `check-docs` 가 실패한다** — 그 가드가 이 절을 강제한다.
