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
| python | griffe check | `py-v0.2.1` 태그 | 종료코드 |
| dotnet | SDK Package Validation | NuGet `0.1.1` | `dotnet pack` 실패 |
| **go** | gorelease | 추론 기준선 | ⚠️ **본문**(`^## incompatible changes`) |
| **php** | php-semver-checker | `php-v0.2.0` 태그 | ⚠️ **본문**(`… change: MAJOR`) |
| **ruby** | yard diff | `ruby-v0.1.0` 태그 | ⚠️ **본문**(`^D `) |
| **node** | api-extractor ×2 | npm `0.2.1` tarball | ⚠️ **본문**(`^< `) |

⚠️ **아홉 중 넷은 도구 종료코드가 거짓말한다** — 파괴적 변경을 정확히 **출력하고도 exit 0** 이다. 그 넷은 리포트 본문을 근거로 삼는다. 새 레인을 붙일 때 가장 먼저 확인할 것이 이것이다.

⚠️ **커버리지가 좁은 둘을 감추지 않는다.**

- **ruby** — `yard diff` 는 **삭제만** 잡는다. 시그니처·arity 변경은 못 잡는다(yard 의 "modified" 는 메서드 소스 텍스트다). 생태계에 등가 도구가 없다.
- **node** — 줄 텍스트 비교라 타입 호환성을 모른다. 실측된 오차 둘: 선택적 매개변수 추가는 **비파괴적인데 실패**(안전한 방향), 입력 인터페이스에 **필수 필드 추가는 파괴적인데 통과**(안전하지 않은 방향).

**이 두 자리는 리뷰가 막는다. 기계가 막는다고 쓰지 않는다.**

⚠️ **아홉 게이트가 전부 보는 것은 「표면」이다 — 표면이 그대로인 채 동작이 바뀌는 파괴는 아홉 중 어느 것도 못 본다.** 예: `clockSkew` 기본값을 30 초에서 300 초로 바꾸면 타입도 시그니처도 그대로다. 그 부류 중 **보안 기본선만** §2 B 가 덮는다(그래서 B 가 A 와 별개 기준이다). 나머지 동작 파괴는 기계가 보지 않는다.

- [ ] **A-1** 위 표를 소비자 문서에 옮긴다 — 「무엇이 기계로 보증되고 무엇이 아닌가」는 소비자가 알아야 한다.

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
node scripts/check-docs.mjs . --strict --min-facts=64 --min-anchors=21 --min-anchor-links=23
```

⚠️ **숫자 없는 사실 주장은 이 가드의 사각지대다.** 실측 사례 — `SECURITY.md` 가 「아직 아홉 중 후속 릴리스를 낸 것이 없다」고 적고 있었고 여섯 레인에서 거짓이었는데, 문장에 숫자가 없어 앵커가 걸리지 않았다.

- [ ] **G-1** 1.0 표기를 넣을 때 `compatibility.md`·`SECURITY.md`·양쪽 README 를 한 번에 옮긴다(버전 문자열의 SSOT 는 `deploy-facts.sh`).

---

## 3. 남은 일

- [ ] **P-1 정책 판정: 아홉을 언제 1.0 으로 올리는가.** §2 의 A–G 가 아홉 곳에서 동시에 충족됐으므로 **데이터상으로는 아홉이 같은 날 자격을 얻는다**. 그러나 번호를 올리는 것은 범위·버전 판정이라 PM 이 정하지 않는다 — 사람에게 올린다.
- [ ] **P-2 `SECURITY.md` 의 「What pre-1.0 means here」를 「What 1.0 means here」로 바꾼다** — §1 의 두 칸을 영문으로 옮긴다. P-1 확정 전에는 손대지 않는다(확정 전에 고치면 문서가 사실보다 앞선다).
- [ ] **P-3 각 레인 매니페스트 버전 + API 게이트 기준선을 함께 올린다.** ⚠️ **둘은 같은 커밋에서 움직여야 한다** — 기준선만 뒤에 남으면 다음 PR 이 이미 게시된 옛 버전과 비교한다. 자리: `java/pom.xml`(`japicmp.baseline`) · `kotlin-ci.yml`(`BASELINE`) · `python-ci.yml`(`--against`) · `php-ci.yml`(태그) · `ruby-ci.yml`(`BASELINE`) · `node-ci.yml`(`BASELINE`) · `dotnet` csproj(`PackageValidationBaselineVersion`).
- [ ] **P-4 태그 푸시(사람·비가역)** `[!]` — 좌표 하나당 버전 하나는 되돌릴 수 없다. Maven Central 은 워크플로 초록 뒤에도 Portal 클릭과 전파 지연이 남는다. **404 로 실패를 결론내지 않는다.**

---

## 4. 이 문서를 닫는 조건

P-1~P-4 와 A-1·G-1 이 전부 체크되면 `doc-status` 를 `complete` 로 내리고 아카이브 태그로 옮긴 뒤 `docs/README.md` §3 에서 지운다. **미체크가 0 인데 `active` 로 남으면 `check-docs` 가 실패한다** — 그 가드가 이 절을 강제한다.
