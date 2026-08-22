# 미해소 갭 — 문서가 주장하는데 코드가 안 하는 자리 · 가드가 한 언어에만 걸린 자리

<!-- doc-status: active -->

> **이 문서가 사는 이유**: 완료된 「문서 IA 재설계 SDD」를 `archive/docs-history-2026-08c` 태그로 내리면서, 그 안에서만 살아 있던 **미해소 항목**을 여기로 옮겼다. 원 계획서의 WBS 11이 이 목록을 「범위 밖 — 코드측 결함 트랙이 열릴 때 인계」로 기각했는데, 인계처가 없으면 그 기각은 곧 유실이다.
>
> 각 항목은 **끝나는 조건이 명령**이다. 닫을 때 그 명령의 출력을 여기 붙이고 `[x]`로 내린다.

---

## 1 · `[x]` `TokenStore`가 9언어 공통 보안 기본선으로 선언돼 있었다 — 문구를 실제로 좁혔다 (#296)

`CLAUDE.md:104`가 「인메모리 토큰저장 + 교체 가능 `TokenStore`」를 교차언어 보안 기본선으로 적었다. 측정:

```
grep -rniE "token_?store" java/*/src python/src node/src go dotnet/src php/src rust/src ruby/lib kotlin/src
  → java  TokenStore.java(인터페이스) · InMemoryTokenStore.java(구현) · InMemoryTokenStoreTest.java
  → 나머지 8개 언어 히트 0
java/*/src/main 에서 그 두 파일을 뺀 참조                      → 0 (프로덕션이 생성하지도 받지도 않는다)
아홉 <lang>/README.md + SECURITY.md + .claude/rules/ + scripts/  → 0 (다른 자리에 같은 주장이 없다)
```

**코드가 권위**다(문서는 「지금 이 코드에서 무엇을」을 적는다). 그래서 문장을 좁혔다 — 프로덕션에 seam을 배선하는 쪽은 §4 동형성 때문에 나머지 여덟도 함께 가야 하므로 **이 항목이 아니라 새 WBS**다.

## 2 · `[x]` `close()`가 정리한다고 적힌 자원이 실제로는 정리되지 않는 자리 — 3개 언어 6곳 (#296)

python 한 곳으로 보였으나 **부류 재스캔에서 셋으로 늘었다**. 원인은 셋 다 같다: 파사드의 `close()`가 「소유한 자원이 없어 의도적 no-op」인 컴포넌트에 위임하는데, 소비자 문서는 그 절반을 이름으로 부른다.

| 언어 | 자리 | 실측 |
|---|---|---|
| python | `README.md:36` · `getting-started.md:159` | `auth.py:279`는 실제로 닫고, `admin/__init__.py:83`은 `return None` |
| node | `README.md:58` · `getting-started.md:236` | **양쪽 다** no-op — `auth.ts:203`·`admin/index.ts:93` 둘 다 `return undefined`(전역 `fetch`라 보유 연결 없음) |
| kotlin | `README.md:44` · `getting-started.md:652` | admin은 `keycloak.close()`로 실재, **auth가** no-op(`auth.kt:183`, KDoc이 명시) |

⚠️ **java·dotnet은 이미 정확했다 — 고치지 말 것.** `java/README.md:68`의 「close() releases the admin client **if it was created** (AuthClient holds no closeable session)」이 **어느 절반이 실재인지 이름으로 밝히는** 모범 문장이고, 나머지 셋을 이 형태로 맞췄다. dotnet은 `KeycloakClient.DisposeAsync()`가 admin·`HttpClient`·세마포어를 실제로 폐기한다.

## 3 · `[-]` 「커버리지 대조기가 `.NET` 경로에만 있다」 — **기각(전제가 거짓)**. 대신 그 전제를 만든 문장 둘을 고쳤다 (#296)

이 항목은 원 SDD의 P1-4를 그대로 옮긴 것인데, **소스를 읽으니 전제가 틀렸다.**

```
scripts/check-coverage.mjs  → cobertura XML 의 lines-valid/covered·branches-* 를 읽어
                              CLI --min-line/--min-branch 와 비교한다. 언어 빌드 설정을 읽지 않는다.
                              (import 는 node:fs·node:path 뿐, child_process 히트 0)
```

그리고 **아홉 전부 G3 임계값 게이트를 갖고 있다** — 장치가 언어마다 다를 뿐이다:

```
java    java/pom.xml:164-165  jacoco LINE 0.90 / BRANCH 0.85   (ci.yml 이 mvn verify 로 집행)
node    node/vitest.config    thresholds { lines:90, branches:85, ... }
python  pyproject [tool.coverage.report] fail_under
kotlin  kotlin-ci.yml         ./gradlew ... koverVerify
ruby    spec_helper           SimpleCov minimum_coverage
go      go-ci.yml:40          awk 'p < 90 → exit 1'
php     php-ci.yml:30         coverage gate
rust    rust-ci.yml:38-39     Coverage gate (logic modules ≥90% lines)
dotnet  dotnet-ci.yml:43      scripts/check-coverage.mjs --min-line 90 --min-branch 85
```

즉 `check-coverage.mjs`는 **누락된 대조기가 아니라 .NET 전용 게이트**다(coverlet 컬렉터가 임계값으로 실패하지 않아 필요하다 — `dotnet-ci.yml:23-27`). 잘못된 전제를 만든 자리 둘을 고쳤다: `process.md`의 「커버리지 설정은 `check-coverage.mjs`가 기계 대조한다」와 이 문서의 초판 같은 문장.

**되살릴 조건**: 위 아홉 중 하나라도 게이트가 사라졌는데 CI가 초록으로 끝날 때.

## 4 · `[ ]` 태그 룰셋 App 분할(1/0/0)을 고정하는 가드가 비-required 잡에 있다 — **사람 판정 대기**

- [ ] **끝나는 조건**: 사람이 required 목록을 바꾸기로 판정한다(또는 바꾸지 않기로 판정하고 그 근거를 [작업 프로세스](../../governance/process.md) §3에 적는다).

```
grep -rln "test-repo-config.sh" .github/workflows/   → repo-hygiene.yml (잡 이름 repo-config)
grep -n "context" .github/rulesets/main.json         → "doc-facts" · "shell-exec-bits"  (둘뿐)
repo-hygiene.yml 의 on:                              → push: / pull_request:   (paths 필터 없음)
실측 소요                                             → 5–8초 (최근 5개 실행)
사용하는 시크릿                                        → 없음(github.token 뿐) → 포크·dependabot PR 에서도 통과
```

⚠️ **판정 전에 `.claude/rules/ci.md`의 잠금 위험을 읽는다** — `paths:` 필터가 걸린 워크플로를 required에 넣으면 체크가 생성되지 않아 저장소가 잠긴다. `repo-hygiene.yml`은 그 필터가 없고 `pull_request`에서 실제로 도는 것이 확인됐다는 점이 이 항목이 언어 CI와 다른 이유다. 그래도 **required 목록 변경은 사람의 몫**이다(기각 체크리스트 4).

---

## 여기 없는 것

원 SDD는 **WBS 20항목이 전부 닫힌 채로**(미체크 0) 아카이브됐다. 위 넷은 그중 **11번이 「범위 밖 — 9개 언어 소스 수정」으로 밀어낸 것**이라, 계획서의 닫힘 표기에도 불구하고 트리에는 남아 있었다. P2(사실 복제)·P3(청중 혼재)·P4(독트린 위반)의 판정 근거와 이후 PR 이력은 `archive/docs-history-2026-08c` 태그에 있다.

**살아 있어야 하는 기각 셋**(`claim_at` 신설 · `DEPLOY.md` 3분할 · 릴리스 순차머지 가드)은 [작업 프로세스](../../governance/process.md) §3 표로 옮겼다 — 기각은 계획서가 아니라 그 표가 소유한다.
