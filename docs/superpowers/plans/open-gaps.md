# 미해소 갭 — 문서가 주장하는데 코드가 안 하는 자리 · 가드가 한 언어에만 걸린 자리

<!-- doc-status: active -->

> **이 문서가 사는 이유**: 완료된 「문서 IA 재설계 SDD」를 `archive/docs-history-2026-08c` 태그로 내리면서, 그 안에서만 살아 있던 **미해소 항목**을 여기로 옮겼다. 원 계획서의 WBS 11이 이 목록을 「범위 밖 — 코드측 결함 트랙이 열릴 때 인계」로 기각했는데, 인계처가 없으면 그 기각은 곧 유실이다.
>
> 아래 넷은 **전부 지금 트리에서 재측정했다**(2026-08-23). 측정 명령을 함께 적었으니 고칠 때 그대로 다시 돌린다.

---

## 1 · `TokenStore`가 9언어 공통 보안 기본선으로 선언돼 있으나 Java에만 있고, 그 Java도 안 쓴다

- [ ] **끝나는 조건**: `CLAUDE.md`의 문구가 실제와 맞거나(범위를 Java로 좁힌다), 프로덕션 경로가 실제로 `TokenStore`를 받는다. 후자를 고르면 §4 동형성 때문에 나머지 여덟도 함께 간다 — **그건 이 항목이 아니라 새 WBS다.**

`CLAUDE.md:104`가 「인메모리 토큰저장 + 교체 가능 `TokenStore`」를 교차언어 보안 기본선으로 적는다. 측정:

```
grep -rniE "token_?store" java/*/src python/src node/src go dotnet/src php/src rust/src ruby/lib kotlin/src
  → java  TokenStore.java(인터페이스) · InMemoryTokenStore.java(구현) · InMemoryTokenStoreTest.java
  → 나머지 8개 언어 히트 0
grep -rn "TokenStore" java/*/src/main --include=*.java | grep -v "core/TokenStore.java|core/InMemoryTokenStore.java"
  → 0   (프로덕션 경로가 이 타입을 생성하지도 받지도 않는다 — 참조는 테스트뿐)
```

## 2 · `python/README.md`가 `with` 블록이 admin 세션을 정리한다고 말하나 admin `close()`는 no-op

- [ ] **끝나는 조건**: README 문장이 auth 세션만 말하도록 좁혀지거나, `AdminClient.close()`가 실제로 무언가를 닫는다.

`python/README.md:36`이 이렇게 적는다 — `# The "with" block cleans up the admin and auth sessions on exit.` 측정하면 둘 중 **auth 쪽만 참**이다.

```
python/src/keycloak_sdk/auth.py:279   close()  → 하위 KeycloakOpenID 의 requests 세션을 실제로 닫는다
python/src/keycloak_sdk/client.py:71  close()  → auth 는 항상, admin 은 생성됐을 때만 위임
python/src/keycloak_sdk/admin/__init__.py:83  close() → `return None` (독스트링이 "현재 no-op"이라고 적는다)
```

## 3 · 커버리지 임계값 대조기가 `.NET` 경로에서만 돈다

- [ ] **끝나는 조건**: `check-coverage.mjs`가 경로 필터 없는 잡에서 돌거나, 나머지 여덟 언어 CI에 각각 배선된다.

`scripts/check-coverage.mjs`는 각 언어 빌드 설정의 90/85 임계값을 기계 대조한다. 측정한 호출처는 하나다.

```
grep -rln "check-coverage.mjs" .github/workflows/ scripts/ CONTRIBUTING.md
  → .github/workflows/dotnet-ci.yml · scripts/test/test-check-coverage.sh(자가테스트) · CONTRIBUTING.md(산문)
grep -n "paths:" .github/workflows/dotnet-ci.yml
  → paths: ['dotnet/**', '.github/workflows/dotnet-ci.yml']
```

즉 `python/pyproject.toml`의 임계값이 바뀌어도 이 대조기는 **생성조차 되지 않는다**.

## 4 · 태그 룰셋 App 분할(1/0/0)을 고정하는 가드가 비-required 잡에 있다

- [ ] **끝나는 조건**: 사람이 required 목록을 바꾸기로 판정한다. ⚠️ **판정 전에 `.claude/rules/ci.md`의 잠금 위험을 읽는다** — `paths:` 필터가 걸린 워크플로를 required에 넣으면 체크가 생성되지 않아 저장소가 잠긴다. `repo-hygiene.yml`은 그 필터가 없다는 점이 이 항목이 다른 이유다.

```
grep -rln "test-repo-config.sh" .github/workflows/   → .github/workflows/repo-hygiene.yml (잡 이름 repo-config)
grep -n "context" .github/rulesets/main.json         → "doc-facts" · "shell-exec-bits"  (둘뿐)
```

`.claude/rules/ci.md`가 「Keep the tag-cutting App in `tags-create.json` only」를 규칙으로 적고 그 집행자로 이 자가테스트를 지목하는데, 그 잡은 머지를 막지 못한다.

---

## 여기 없는 것

원 SDD는 **WBS 20항목이 전부 닫힌 채로**(미체크 0) 아카이브됐다. 위 넷은 그중 **11번이 「범위 밖 — 9개 언어 소스 수정」으로 밀어낸 것**이라, 계획서의 닫힘 표기에도 불구하고 트리에는 남아 있다. P2(사실 복제)·P3(청중 혼재)·P4(독트린 위반)의 판정 근거와 이후 PR 이력은 `archive/docs-history-2026-08c` 태그에 있다.

**살아 있어야 하는 기각 셋**(`claim_at` 신설 · `DEPLOY.md` 3분할 · 릴리스 순차머지 가드)은 [작업 프로세스](../../governance/process.md) §3 표로 옮겼다 — 기각은 계획서가 아니라 그 표가 소유한다.
