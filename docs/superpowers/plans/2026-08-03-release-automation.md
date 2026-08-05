# 릴리스 자동화 구현 계획

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.
>
> ⚠️ **예외 — Task 3 Step 8은 아직 남았다.** GitHub App을 `.github/rulesets/tags-create.json`의
> bypass에 추가하는 일이다(App이 없어 `actor_id`를 모른다). 그때까지 `dispatch-release.yml`은
> 태그를 만들지 못하고 fail-closed이며, 이 계획의 Goal("머지만으로 릴리스가 실행")에는 도달하지
> 않았다. 절차: [DEPLOY.md §2-F](../../../DEPLOY.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사람이 릴리스 PR을 머지하는 것만으로 릴리스가 실행되게 하고, 승인 없는 태그 생성 경로를 룰셋으로 차단한다.

**Architecture:** Claude가 `.github/release-request.json`을 담은 PR을 올리고 사람이 머지한다. 그 머지가 `dispatch-release.yml`을 깨워 요청을 검증하고 태그를 파생·생성하면, **기존 9개 릴리스 워크플로가 무수정으로** 그 태그에 반응해 게시한다. Go는 태그가 곧 게시라 자동화에서 제외하며, 그 예외를 워크플로가 아니라 **태그 룰셋(서버 상태)**이 집행한다.

**Tech Stack:** GitHub Actions · GitHub rulesets API · POSIX sh(`scripts/lib/deploy-facts.sh` 재사용) · node(JSON 파싱·버전 추출) · `actions/create-github-app-token`

**설계 스펙:** [docs/superpowers/specs/2026-08-03-release-automation-design.md](../specs/2026-08-03-release-automation-design.md)

## Global Constraints

- **문서 언어**: `docs/superpowers/`·`CLAUDE.md`는 한글, `DEPLOY.md`·`CONTRIBUTING.md`는 영문(문서 언어 규칙).
- **서드파티 액션은 40자 SHA로 핀**하고 `# <tag>` 주석을 단다(저장소 전체 예외 없음).
- **릴리스 워크플로 권한 관용**: 워크플로 레벨 `permissions:` 블록을 두지 않고 **잡마다 선언**하며 모든 `write`에 근거 주석을 단다.
- **셸 스크립트는 `100755`로 커밋**한다(`shell-exec-bits` required 체크).
- **기존 9개 `*-release.yml`을 수정하지 않는다.**
- ⚠️ **`.github/release-request.json`을 이 계획에서 생성하지 않는다.** 파일이 생기는 순간 경로 필터가 발동해 실제 태그가 잘린다. 첫 실제 릴리스 PR이 만든다.
- **Go 자동화 금지**: `lang: "go"`는 어떤 경로로도 태그를 만들지 않는다.

---

## 파일 구조

| 파일 | 책임 |
|---|---|
| `.github/rulesets/tags-create.json` | Go 아닌 8개 릴리스 태그의 **생성** 권한 제한 |
| `.github/rulesets/tags-create-go.json` | `go/v*` 생성을 소유자 전용으로 — Go 정책의 집행자 |
| `.github/rulesets/tags-immutable.json` | 9개 릴리스 태그의 **수정·삭제** 차단(불변성) |
| `scripts/release-request.sh` | 요청 검증 + 태그 파생(순수 로직, `--lib`로 테스트 가능) |
| `scripts/test/test-release-request.sh` | 위 스크립트의 자가테스트 |
| `.github/workflows/dispatch-release.yml` | 머지 감지 → 검증 → 태그 push |

---

## Task 1: 태그 룰셋 — 승인 없는 태그 생성 차단

이 태스크만으로도 독립적인 가치가 있다. 자동화가 없어도 §2-A의 구멍(현재 아무 자격증명이나 `go/v9.9.9`를 밀 수 있음)이 닫힌다.

**Files:**
- Create: `.github/rulesets/tags-create.json`
- Create: `.github/rulesets/tags-create-go.json`
- Create: `.github/rulesets/tags-immutable.json`
- Modify: `CONTRIBUTING.md` (§4 브랜치 보호 설명 뒤에 태그 룰셋 절 추가)

**Interfaces:**
- Consumes: `scripts/repo-config.mjs`(기존) — `.github/rulesets/*.json`을 **글로브로 자동 발견**하고 `name` 필드로 라이브 룰셋과 대조한다. 코드 수정 불필요.
- Produces: 룰셋 이름 3종 `RELEASE-TAGS-CREATE` · `RELEASE-TAGS-CREATE-GO` · `RELEASE-TAGS-IMMUTABLE`. Task 3의 워크플로가 존재 여부를 확인한다.

- [ ] **Step 1: 세 룰셋 파일을 작성한다**

`bypass_actors`의 `actor_id: 5` / `actor_type: "RepositoryRole"`은 **admin 역할**이다(저장소 소유자가 해당). GitHub App은 아직 존재하지 않으므로 **지금은 넣지 않는다** — App 생성 후 Task 3 Step 8이 추가한다. 지금 상태로도 룰셋은 완전히 동작한다(소유자만 태그 생성 가능).

`.github/rulesets/tags-create.json`:

```json
{
  "name": "RELEASE-TAGS-CREATE",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/tags/v*",
        "refs/tags/py-v*",
        "refs/tags/node-v*",
        "refs/tags/dotnet-v*",
        "refs/tags/php-v*",
        "refs/tags/rust-v*",
        "refs/tags/ruby-v*",
        "refs/tags/kotlin-v*"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "creation"
    }
  ]
}
```

`.github/rulesets/tags-create-go.json`:

```json
{
  "name": "RELEASE-TAGS-CREATE-GO",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/tags/go/v*"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "creation"
    }
  ]
}
```

`.github/rulesets/tags-immutable.json`:

```json
{
  "name": "RELEASE-TAGS-IMMUTABLE",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": [
        "refs/tags/v*",
        "refs/tags/py-v*",
        "refs/tags/node-v*",
        "refs/tags/dotnet-v*",
        "refs/tags/php-v*",
        "refs/tags/rust-v*",
        "refs/tags/ruby-v*",
        "refs/tags/kotlin-v*",
        "refs/tags/go/v*"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "update"
    },
    {
      "type": "deletion"
    }
  ]
}
```

⚠️ **파일이 셋인 이유**: `bypass_actors`는 룰셋 **전체**에 적용되므로, "App은 생성 가능하되 삭제는 불가"를 한 파일로 표현할 수 없다. 생성 권한(언어별로 다름)과 불변성(전 언어 동일)을 분리해야 App에 생성만 허용할 수 있다.

- [ ] **Step 2: 기존 룰셋 자가테스트가 여전히 통과하는지 확인한다**

Run: `sh scripts/test/test-repo-config.sh`
Expected: PASS (`N passed, 0 failed`) — 이 테스트는 파일 개수를 고정하지 않으므로 파일 추가로 깨지지 않아야 한다. 만약 깨진다면 개수를 못박은 어서션이 있다는 뜻이므로 그 어서션을 고친다(가드가 파일 추가를 막으면 안 된다).

- [ ] **Step 3: JSON 문법과 필수 필드를 확인한다**

Run:
```bash
for f in .github/rulesets/*.json; do node -e "
  const o=require('fs').readFileSync('$f','utf8');
  const j=JSON.parse(o);
  if(!j.name||!j.target||!j.enforcement) { console.error('$f: 필수 필드 누락'); process.exit(1); }
  console.log('$f', j.name, j.target);
"; done
```
Expected: 네 줄 출력(main.json + 신규 3종), 오류 없음

- [ ] **Step 4: CONTRIBUTING.md에 태그 룰셋 절을 추가한다**

`CONTRIBUTING.md`의 §4(브랜치 보호) 끝에 다음을 영문으로 추가한다. **핵심은 `main.json`과 `bypass_actors` 방향이 정반대라는 경고다** — 다음 사람이 "일관성" 명목으로 맞추면 아홉 릴리스가 전부 잠긴다.

```markdown
### Tag rulesets — deliberately the mirror image of `main.json`

`main.json` has `bypass_actors: []` — nobody bypasses, not even the owner. The three
tag rulesets do the opposite on purpose, and they **must**: a tag ruleset with an empty
bypass list can never be satisfied by anyone, so every one of the nine releases would be
permanently blocked with no way to unblock it.

| Ruleset | Refs | Rule | Who may bypass |
|---|---|---|---|
| `RELEASE-TAGS-CREATE` | the eight non-Go release tags | `creation` | repository admin (+ the release App once it exists) |
| `RELEASE-TAGS-CREATE-GO` | `go/v*` | `creation` | repository admin **only** |
| `RELEASE-TAGS-IMMUTABLE` | all nine | `update`, `deletion` | repository admin |

**Why Go is separated:** Go's tag *is* its publication — `proxy.golang.org` serves whatever
the tag points at, regardless of CI. No gate can exist after the tag, so Go is excluded from
automated release. Keeping that exclusion in a workflow file would not be enough: `on: push`
runs the workflow as it exists in the pushed commit, so a single merge editing that workflow
would erase the exclusion. A ruleset is server-side state and survives it.

**Why creation and immutability are separate files:** `bypass_actors` applies to a whole
ruleset, so "the App may create but may not delete" cannot be expressed in one file.

⚠️ Do not "harmonize" these with `main.json`.
```

- [ ] **Step 5: 커밋**

```bash
git add .github/rulesets/tags-create.json .github/rulesets/tags-create-go.json .github/rulesets/tags-immutable.json CONTRIBUTING.md
git commit -m "feat(ci): 릴리스 태그 룰셋 3종 — 승인 없는 태그 생성을 차단하고 Go 예외를 서버 상태로 집행

지금까지 main은 bypass_actors:[]로 소유자조차 못 뚫게 잠겨 있었는데, 정작 가장
되돌릴 수 없는 행위인 릴리스 태그 push에는 룰셋이 없었다(실측: rulesets는
PRIMARY/branch 하나뿐). human-gate는 강제가 아니라 release-trigger.sh가 스스로
push를 안 하는 자제였다.

- RELEASE-TAGS-CREATE: Go 아닌 8개 릴리스 태그 생성 제한
- RELEASE-TAGS-CREATE-GO: go/v* 생성을 소유자 전용으로 — Go 자동화 금지를
  워크플로가 아니라 서버 상태가 집행한다(on:push는 밀린 커밋의 워크플로가
  실행되므로 워크플로 안의 예외는 머지 하나로 증발한다)
- RELEASE-TAGS-IMMUTABLE: 릴리스 태그 수정·삭제 차단(복구는 전진만)

파일이 셋인 이유는 bypass_actors가 룰셋 전체에 적용되기 때문이다 — 생성 권한과
불변성을 한 파일에 담으면 \"App은 생성 가능하되 삭제 불가\"를 표현할 수 없다."
```

- [ ] **Step 6: 적용은 소유자가 한다(코드 아님 — 계획에 기록만)**

```bash
node scripts/repo-config.mjs apply    # admin 토큰 필요
node scripts/repo-config.mjs check    # 적용 직후 드리프트 확인
```
⚠️ `check`가 드리프트를 보고하면 `pull`로 라이브 본문을 받아 diff한다 — `repo-config.mjs`의 `SERVER_FIELDS`가 브랜치 룰셋 응답에서 유도된 목록이라 tag 타깃에서 서버 관리 필드가 더 올 수 있다(스펙 §10 N5).

---

## Task 2: 릴리스 요청 검증 스크립트

**Files:**
- Create: `scripts/release-request.sh` (mode 100755)
- Create: `scripts/test/test-release-request.sh` (mode 100755)
- Modify: `.github/workflows/repo-hygiene.yml` (배포 자가테스트 목록에 추가)

**Interfaces:**
- Consumes: `scripts/lib/deploy-facts.sh`의 `df_known` · `df_tag` · `df_version_re` · `df_version_hint`
- Produces:
  - `rq_derive_tag <lang> <version>` → stdout에 태그, exit 0
  - `rq_validate_file <path>` → stdout에 `<lang> <version> <tag>`(공백 구분), exit 0 = 진행 · 1 = 거부 · 3 = 요청 없음
  - CLI: `sh scripts/release-request.sh <path>` (같은 계약) · `--lib`로 소싱 시 함수만 로드

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`scripts/test/test-release-request.sh`:

```sh
#!/usr/bin/env sh
# 릴리스 요청 검증 자가테스트.
#
# 이 스크립트가 잘못 통과하면 승인되지 않은 태그가 밀린다 — 그래서 "거부해야 하는 것"을
# 통과 케이스보다 많이 고정한다. 특히 go 거부와 태그 파생은 회귀하면 조용히 위험해진다.
#
# ⚠️ 환경 의존 어서션을 쓰지 않는다. 이 저장소는 test-deploy-md.sh·test-release-readiness.sh가
# 각각 실제 태그·게시 상태에 기대다가 사실이 바뀌자 뒤집힌 이력이 있다. 여기서는 임시 파일만 쓴다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../release-request.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

. "$SH" --lib

# ── 태그 파생: 요청이 태그를 말하지 않고 lang+version에서 나온다 ──────────────
# 태그를 데이터로 받으면 "싼 언어를 선언하고 비싼 태그를 민다"가 성립한다.
assert_eq "py-v0.1.0rc2"   "$(rq_derive_tag python 0.1.0rc2)"   "python 태그 파생"
assert_eq "dotnet-v0.1.0"  "$(rq_derive_tag dotnet 0.1.0)"      "dotnet 태그 파생"
assert_eq "v0.1.0"         "$(rq_derive_tag java 0.1.0)"        "java 태그 파생(접두 없음)"
assert_eq "ruby-v0.1.0.rc1" "$(rq_derive_tag ruby 0.1.0.rc1)"   "ruby 태그 파생(RubyGems 표기)"

# ── 정상 요청 ────────────────────────────────────────────────────────────────
printf '{"lang":"python","version":"0.1.0rc2"}\n' > "$TMP/ok.json"
assert_eq "python 0.1.0rc2 py-v0.1.0rc2" "$(rq_validate_file "$TMP/ok.json")" "정상 요청은 lang/version/tag를 낸다"
assert_ok rq_validate_file "$TMP/ok.json"

# ── go 거부 ──────────────────────────────────────────────────────────────────
# 태그가 곧 게시라 머지 이후 게이트가 불가능하다. 거부는 조용하면 안 된다 — 왜인지 말해야 한다.
printf '{"lang":"go","version":"0.1.0"}\n' > "$TMP/go.json"
assert_fails rq_validate_file "$TMP/go.json"
go_err="$(rq_validate_file "$TMP/go.json" 2>&1 || true)"
assert_contains "$go_err" "go" "go 거부 메시지에 언어가 있다"
assert_contains "$go_err" "git tag go/v0.1.0" "go 거부 시 사람이 실행할 명령을 안내한다"

# ── 요청 없음 = 깨끗한 no-op (리버트로 파일이 사라진 경우) ─────────────────────
rq_validate_file "$TMP/absent.json" >/dev/null 2>&1 || rc=$?
assert_eq "3" "${rc:-0}" "요청 파일 부재는 거부(1)가 아니라 no-op(3)이다"

# ── 거부해야 하는 것들 ───────────────────────────────────────────────────────
printf '{"lang":"klingon","version":"0.1.0"}\n' > "$TMP/unknown.json"
assert_fails rq_validate_file "$TMP/unknown.json"

printf '{"lang":"python","version":"0.1.0-rc.1"}\n' > "$TMP/badver.json"
assert_fails rq_validate_file "$TMP/badver.json"   # python은 PEP 440(0.1.0rc1)이라 SemVer 표기를 거부

printf '{"lang":"python"}\n' > "$TMP/noversion.json"
assert_fails rq_validate_file "$TMP/noversion.json"

printf 'not json at all\n' > "$TMP/broken.json"
assert_fails rq_validate_file "$TMP/broken.json"

# 태그를 데이터로 넣으려는 시도 — 무시되어야 한다(파생값이 이긴다).
printf '{"lang":"python","version":"0.1.0rc2","tag":"node-v9.9.9"}\n' > "$TMP/inject.json"
inject_out="$(rq_validate_file "$TMP/inject.json" 2>/dev/null || true)"
assert_contains "$inject_out" "py-v0.1.0rc2" "요청의 tag 필드가 파생을 덮어쓰지 못한다"
assert_not_contains "$inject_out" "node-v9.9.9" "요청의 tag 필드가 무시된다"

# 셸 주입 시도 — 버전 정규식이 막아야 한다.
printf '{"lang":"python","version":"0.1.0rc2; touch /tmp/pwned"}\n' > "$TMP/shell.json"
assert_fails rq_validate_file "$TMP/shell.json"

# ── 상태 불변식: 이 스크립트는 아무것도 바꾸지 않는다 ─────────────────────────
assert_eq "0" "$(grep -cE '^[[:space:]]*(git[[:space:]]+(tag|push|commit)|rm[[:space:]]|mv[[:space:]])' "$SH" || true)" "요청 검증은 상태를 변경하지 않는다"

assert_report
```

- [ ] **Step 2: 테스트를 실행해 실패를 확인한다**

Run: `sh scripts/test/test-release-request.sh`
Expected: FAIL — `scripts/release-request.sh: No such file or directory`

- [ ] **Step 3: 최소 구현을 작성한다**

`scripts/release-request.sh`:

```sh
#!/usr/bin/env sh
# release-request.sh — .github/release-request.json을 검증하고 릴리스 태그를 파생한다.
#
# ⚠️ 읽기전용: 어떤 상태도 변경하지 않는다(태그를 만들지 않는다 — 만드는 것은 워크플로다).
#
# 왜 태그가 요청 파일에 없는가: 태그를 데이터로 받으면
# {"lang":"python","version":"0.1.0rc2","tag":"node-v9.9.9"} 가 유효한 JSON으로 통과해
# **싼 언어를 선언하고 비싼 태그를 미는** 권한상승이 성립한다. 태그는 lang+version에서
# df_tag로 파생한다 — release-trigger.sh:22가 이미 쓰는 방식이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
# release-readiness.sh와 같은 이유로 두 경로를 모두 시도한다(직접 실행 · 테스트에서 소싱).
if [ -f "$DIR/lib/deploy-facts.sh" ]; then
  . "$DIR/lib/deploy-facts.sh"
else
  . "$DIR/../lib/deploy-facts.sh"
fi

# JSON 파싱은 node에 맡긴다 — sed로 JSON을 긁으면 중첩·이스케이프에서 조용히 틀린다.
# 문자열이 아닌 값·파싱 실패는 빈 출력 + 비0으로 fail-closed.
rq_field() { # <file> <key> → stdout: 값
  node -e '
    const fs = require("fs")
    let obj
    try { obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) } catch { process.exit(1) }
    const v = obj[process.argv[2]]
    if (typeof v !== "string") process.exit(1)
    process.stdout.write(v)
  ' "$1" "$2" 2>/dev/null
}

rq_derive_tag() { # <lang> <version> → stdout: 태그
  printf "$(df_tag "$1")" "$2"
}

rq_validate_file() { # <path> → stdout: "<lang> <version> <tag>" · 0=진행 1=거부 3=요청없음
  f="$1"
  if [ ! -f "$f" ]; then
    echo "릴리스 요청 파일이 없다: $f — 할 일 없음(no-op)" >&2
    return 3
  fi

  lang="$(rq_field "$f" lang)" || lang=""
  ver="$(rq_field "$f" version)" || ver=""
  if [ -z "$lang" ] || [ -z "$ver" ]; then
    echo "::error::릴리스 요청을 읽지 못했다($f) — lang·version 문자열 필드가 필요하다(fail-closed)." >&2
    return 1
  fi

  if ! df_known "$lang"; then
    echo "::error::미지의 언어 '$lang' — 지원: $DEPLOY_LANGS" >&2
    return 1
  fi

  # ⚠️ Go는 자동화하지 않는다. 태그가 곧 게시라(proxy가 CI를 기다리지 않는다) 머지 이후에
  # 어떤 게이트도 둘 수 없고, sum.golang.org가 append-only라 태그를 고쳐 다시 밀면 기존
  # 소비자가 checksum mismatch를 본다 — 아홉 중 복구 시도가 원래 사고보다 해로운 유일한 곳이다.
  # 이 거부는 두 번째 방어선이다. 첫 번째는 태그 룰셋(RELEASE-TAGS-CREATE-GO)이며, 그쪽은
  # 이 워크플로를 수정해도 우회되지 않는다.
  if [ "$lang" = "go" ]; then
    echo "::error::go는 자동 릴리스 대상이 아니다 — 태그가 곧 게시이고 회수가 불가능하다." >&2
    echo "  사람이 직접 실행한다: git tag go/v${ver} && git push origin go/v${ver}" >&2
    return 1
  fi

  # 버전 표기는 레지스트리마다 다르다(PEP 440 · RubyGems · Maven · SemVer). 언어별 정규식으로
  # 검사하는 것은 오타 방지이자 **주입 차단**이다 — 이 값이 태그 문자열과 명령에 삽입된다.
  if ! echo "$ver" | grep -qE "$(df_version_re "$lang")"; then
    echo "::error::'$lang'의 버전 표기가 아니다: '$ver'" >&2
    echo "  기대: $(df_version_hint "$lang")" >&2
    return 1
  fi

  printf '%s %s %s\n' "$lang" "$ver" "$(rq_derive_tag "$lang" "$ver")"
  return 0
}

rq_main() {
  rq_validate_file "${1:-.github/release-request.json}"
}

# --lib: 함수만 로드(테스트용). 그 외: main 실행.
[ "${1:-}" = "--lib" ] || rq_main "$@"
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `sh scripts/test/test-release-request.sh`
Expected: PASS — `N passed, 0 failed`

- [ ] **Step 5: 실행 비트를 설정한다**

Run:
```bash
git update-index --add --chmod=+x scripts/release-request.sh scripts/test/test-release-request.sh
git ls-files -s scripts/release-request.sh scripts/test/test-release-request.sh
```
Expected: 두 줄 모두 `100755`로 시작

- [ ] **Step 6: CI에 배선한다 — 배선되지 않은 자가테스트는 가드가 아니라 문서다**

`.github/workflows/repo-hygiene.yml`의 "배포 문서·헬퍼 자가테스트" 스텝을 수정한다. 이름의 개수와 나열을 함께 갱신한다:

```yaml
      - name: 배포 문서·헬퍼 자가테스트(DEPLOY.md ↔ deploy-facts SSOT · readiness · trigger · request)
        run: |
          sh scripts/test/test-deploy-facts.sh
          sh scripts/test/test-deploy-md.sh
          sh scripts/test/test-release-readiness.sh
          sh scripts/test/test-release-trigger.sh
          sh scripts/test/test-release-request.sh
```

- [ ] **Step 7: 전체 위생 검사가 통과하는지 확인한다**

Run:
```bash
for t in scripts/test/test-*.sh; do printf '%-42s ' "$t"; sh "$t" >/dev/null 2>&1 && echo PASS || echo FAIL; done
node scripts/check-docs.mjs .
```
Expected: 전부 PASS, check-docs 통과

- [ ] **Step 8: 커밋**

```bash
git add scripts/release-request.sh scripts/test/test-release-request.sh .github/workflows/repo-hygiene.yml
git commit -m "feat(ci): 릴리스 요청 검증 스크립트 — 태그를 데이터가 아니라 파생값으로

요청 파일이 태그를 직접 말하면 {\"lang\":\"python\",\"tag\":\"node-v9.9.9\"}가
유효한 JSON으로 통과해 싼 언어를 선언하고 비싼 태그를 미는 권한상승이 성립한다.
태그는 lang+version에서 df_tag로 파생한다(release-trigger.sh:22의 기존 방식).

거부 규칙은 전부 fail-closed다: 미지 언어 · 언어별 버전 표기 위반(주입 차단 겸함) ·
파싱 실패 · go(태그가 곧 게시라 자동화 불가). 요청 파일 부재는 거부가 아니라
no-op(exit 3)이다 — 리버트로 파일이 사라진 경우가 실패로 보이면 안 된다.

자가테스트를 repo-hygiene의 doc-facts 잡에 배선했다. 배선되지 않은 자가테스트가
가드가 아니라는 것은 이 저장소가 이미 겪은 일이다(배포 자가테스트 4종이 오래
어떤 워크플로에도 걸려 있지 않아 DEPLOY.md 드리프트를 아무도 몰랐다)."
```

---

## Task 3: 디스패치 워크플로 — 머지가 태그를 만든다

**Files:**
- Create: `.github/workflows/dispatch-release.yml`
- Modify: `DEPLOY.md` (§1 원칙 · §4 절차에 자동화 경로 추가)

**Interfaces:**
- Consumes: Task 2의 `sh scripts/release-request.sh <path>` → stdout `<lang> <version> <tag>` · exit 0/1/3
- Consumes: Task 1의 룰셋 이름 `RELEASE-TAGS-CREATE`
- Produces: 릴리스 태그. 기존 9개 `*-release.yml`이 이를 소비한다(수정 없음).

⚠️ **파일명은 반드시 `dispatch-release.yml`이다.** `scripts/check-ci-permissions.mjs:259`의 `isRelease = (f) => /release\.ya?ml$/.test(f)`가 `release-dispatch.yml`은 매칭하지 못한다(실측 확인). 매칭되지 않으면 이 저장소에서 가장 특권적인 워크플로만 "모든 write에 근거 주석" 규칙(rule 1·2·5)을 면제받고 `--min-release=9`는 그대로 충족돼 아무 신호도 나지 않는다.

- [ ] **Step 1: 워크플로를 작성한다**

`.github/workflows/dispatch-release.yml`:

```yaml
name: Dispatch Release

# 릴리스 PR **머지**가 트리거다 — 그 머지가 사람의 승인이다.
# 이 워크플로는 검증하고 태그만 만든다. 게시는 기존 <lang>-release.yml이 태그에 반응해 수행하며
# 그쪽은 한 줄도 수정하지 않았다(verify·integration·install-smoke 게이트 전부 그대로).
#
# ⚠️ 파일명이 `dispatch-release.yml`인 것은 의도다 — scripts/check-ci-permissions.mjs의
# isRelease(/release\.ya?ml$/)에 매칭돼야 릴리스 워크플로용 강한 권한 규칙을 상속한다.
# `release-dispatch.yml`로 두면 가장 특권적인 이 파일만 조용히 검사에서 빠진다.
on:
  push:
    branches: [main]
    paths: ['.github/release-request.json']
  # 복구 경로(스펙 §4.5): 태그 삭제 후 재시도는 채택하지 않았으므로 정상 경로는 항상 새 버전이다.
  # 이 입력은 요청 파일 내용이 이미 동일해 diff가 나지 않는 상황에서 감사 가능한 수동 재실행을
  # 제공한다 — 사람이 셸에서 PAT로 태그를 미는 것보다 로그가 남는다.
  workflow_dispatch:
    inputs:
      lang:
        description: '언어 (go 제외 — go는 사람이 직접 태그한다)'
        required: true
      version:
        description: '버전 (해당 레지스트리 표기 — 예: python 0.1.0rc2, ruby 0.1.0.rc1)'
        required: true

# 태그 생성이 겹치면 원자성이 깨진다. cancel-in-progress는 반드시 false다 —
# git push 도중 취소가 곧 그 사고다.
concurrency:
  group: dispatch-release
  cancel-in-progress: false

# 최소권한: 워크플로 레벨 기본값을 두지 않고 잡이 자기 권한을 직접 선언한다(릴리스 워크플로 관용).
jobs:
  cut-tag:
    runs-on: ubuntu-latest
    permissions:
      # 체크아웃과 룰셋 조회만 GITHUB_TOKEN을 쓴다. 태그 push는 App 설치 토큰으로 하므로
      # 이 토큰에는 write가 필요 없다 — 그리고 main.json의 bypass_actors:[]가 어차피
      # 이 토큰의 main push를 막는다.
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          persist-credentials: false

      # ⚠️ GitHub은 job-level `if:`에 secrets 컨텍스트를 노출하지 않는다. 시크릿 가드는 반드시
      # 스텝 안에서 env-매핑된 값으로 해야 실제로 동작한다(php-release.yml의 선례와 동일).
      # 미설정이 "스킵"이 되면 아무것도 하지 않은 실행이 성공한 실행과 구분되지 않는다.
      - name: Fail closed when the release App credentials are unset
        env:
          APP_ID: ${{ secrets.RELEASE_APP_ID }}
          APP_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
        run: |
          missing=''
          [ -z "$APP_ID" ] && missing="$missing RELEASE_APP_ID"
          [ -z "$APP_KEY" ] && missing="$missing RELEASE_APP_PRIVATE_KEY"
          if [ -n "$missing" ]; then
            echo "::error::릴리스 App 자격증명 미설정 —$missing. 태그를 만들 수 없다(fail-closed)."
            echo "  기본 GITHUB_TOKEN으로 만든 태그는 릴리스 워크플로를 트리거하지 않으므로 App이 필수다."
            exit 1
          fi

      - name: Validate the release request and derive the tag
        id: request
        env:
          WF_LANG: ${{ github.event.inputs.lang }}
          WF_VERSION: ${{ github.event.inputs.version }}
        run: |
          # workflow_dispatch 경로도 파일 경로와 **같은 검증 코드**를 지난다 — 검증이 두 벌이면
          # 한쪽만 고쳐지는 드리프트가 생긴다. 입력을 임시 요청 파일로 만들어 같은 함수에 넣는다.
          REQ=.github/release-request.json
          if [ -n "$WF_LANG" ]; then
            REQ="$RUNNER_TEMP/release-request.json"
            node -e '
              const fs = require("fs")
              fs.writeFileSync(process.argv[1], JSON.stringify({ lang: process.argv[2], version: process.argv[3] }))
            ' "$REQ" "$WF_LANG" "$WF_VERSION"
          fi
          set +e
          OUT="$(sh scripts/release-request.sh "$REQ")"
          RC=$?
          set -e
          if [ "$RC" -eq 3 ]; then
            echo "요청 파일이 없다(리버트 등) — 할 일 없음."
            echo "proceed=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          [ "$RC" -eq 0 ] || exit "$RC"
          echo "lang=$(echo "$OUT" | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"
          echo "version=$(echo "$OUT" | cut -d' ' -f2)" >> "$GITHUB_OUTPUT"
          echo "tag=$(echo "$OUT" | cut -d' ' -f3)" >> "$GITHUB_OUTPUT"
          echo "proceed=true" >> "$GITHUB_OUTPUT"

      # 요청이 선언한 버전과 매니페스트가 어긋나면 태그를 만들지 않는다. 추출 SSOT는
      # check-versions.mjs --list 하나다 — 정규식을 여기에 복제하면 갈라진다.
      # go·php는 태그가 버전 SSOT라 매니페스트에 버전이 없어 대조 대상이 아니다(go는 이미 거부됨).
      - name: Cross-check the declared version against the language manifest
        if: steps.request.outputs.proceed == 'true'
        env:
          LANG_: ${{ steps.request.outputs.lang }}
          VERSION: ${{ steps.request.outputs.version }}
        run: |
          if [ "$LANG_" = "php" ]; then
            echo "php는 태그가 버전 SSOT라 대조할 매니페스트가 없다 — 건너뛴다."
            exit 0
          fi
          ACTUAL="$(node scripts/check-versions.mjs --list | awk -v l="$LANG_" '$1 == l { print $2 }')"
          if [ -z "$ACTUAL" ]; then
            echo "::error::$LANG_ 의 매니페스트 버전을 추출하지 못했다 — 정합성 검증 불가(fail-closed)."
            exit 1
          fi
          if [ "$ACTUAL" != "$VERSION" ]; then
            echo "::error::요청은 $LANG_ $VERSION 이지만 매니페스트는 $ACTUAL 을 선언한다. 버전 범프가 반쯤 적용됐다."
            exit 1
          fi
          echo "요청 $VERSION ↔ 매니페스트 $ACTUAL 일치"

      # 태그 룰셋이 없으면 승인 없는 태그 생성을 막는 장치가 사라진 상태다. repo-config.mjs는
      # orphan 룰셋(파일 없이 라이브에만 있음/라이브에서 삭제됨)을 감지하지 못하고 CI에서
      # check도 돌지 않으므로, 룰셋 삭제는 저장소 어디에서도 신호가 나지 않는다.
      # App 토큰을 들고 있는 이 워크플로가 유일하게 확인할 수 있는 지점이다.
      - name: Assert the tag ruleset is still in place
        if: steps.request.outputs.proceed == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          if ! RS="$(gh api "repos/${GITHUB_REPOSITORY}/rulesets" --jq '[.[] | select(.name == "RELEASE-TAGS-CREATE")] | length' 2>/dev/null)"; then
            echo "::warning::룰셋을 조회하지 못했다(권한 부족일 수 있다) — 존재 확인을 건너뛴다."
            exit 0
          fi
          if [ "$RS" -lt 1 ]; then
            echo "::error::RELEASE-TAGS-CREATE 룰셋이 없다 — 승인 없는 태그 생성을 막는 장치가 사라졌다. 태그를 만들지 않는다."
            echo "  복구: node scripts/repo-config.mjs apply"
            exit 1
          fi
          echo "RELEASE-TAGS-CREATE 확인됨"

      - name: Mint a GitHub App installation token
        # 기본 GITHUB_TOKEN으로 만든 태그는 다른 워크플로를 트리거하지 않는다(GitHub의 재귀
        # 실행 방지). 이 한 가지 제약이 App을 요구한다 — 권한은 Contents: write 하나뿐이고,
        # main.json의 bypass_actors:[]가 이 토큰의 main push를 막는다.
        if: steps.request.outputs.proceed == 'true'
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          app-id: ${{ secrets.RELEASE_APP_ID }}
          private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}

      - name: Create and push the release tag
        if: steps.request.outputs.proceed == 'true'
        env:
          APP_TOKEN: ${{ steps.app-token.outputs.token }}
          TAG: ${{ steps.request.outputs.tag }}
          LANG_: ${{ steps.request.outputs.lang }}
          VERSION: ${{ steps.request.outputs.version }}
        run: |
          # 이미 존재하면 스킵한다(멱등) — 같은 요청이 재머지되거나 워크플로가 재실행돼도
          # 안전해야 한다. 릴리스 태그는 RELEASE-TAGS-IMMUTABLE로 불변이므로 "존재한다"는
          # 종착 상태이지 되돌릴 수 있는 상태가 아니다. 재시도는 항상 새 버전으로 전진한다.
          if git ls-remote --tags --exit-code origin "refs/tags/${TAG}" >/dev/null 2>&1; then
            echo "태그 ${TAG} 가 이미 존재한다 — 아무것도 하지 않는다(멱등)."
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          # ⚠️ 토큰을 remote URL에 넣지 않는다 — 그 형태는 git remote -v·reflog·오류 출력에 남는다.
          # credential helper가 push 시점에 환경변수에서 읽게 한다(php-release.yml과 동일 기법).
          git config --local credential.helper \
            '!f() { echo username=x-access-token; echo "password=$APP_TOKEN"; }; f'
          git tag "$TAG"
          git push "https://github.com/${GITHUB_REPOSITORY}.git" "refs/tags/${TAG}"
          echo "### 릴리스 태그 생성됨" >> "$GITHUB_STEP_SUMMARY"
          echo "- 언어: \`${LANG_}\` · 버전: \`${VERSION}\` · 태그: \`${TAG}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- 게시는 \`${LANG_}\` 릴리스 워크플로가 이어서 수행한다(verify → integration → install-smoke → 레지스트리)." >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: 권한 가드가 이 워크플로를 실제로 검사하는지 확인한다**

Run: `node scripts/check-ci-permissions.mjs .github/workflows --min-release=9`
Expected: 통과. 그리고 릴리스 워크플로 개수가 **10**으로 세어지는지 확인한다:
```bash
node -e 'const {readdirSync}=require("fs"); const isRelease=(f)=>/release\.ya?ml$/.test(f);
console.log(readdirSync(".github/workflows").filter(isRelease).length)'
```
Expected: `10` (기존 9 + dispatch-release.yml)

- [ ] **Step 3: YAML 문법을 확인한다**

Run:
```bash
node -e '
  const {execSync}=require("child_process");
  execSync("node -e \"require(\x27fs\x27).readFileSync(\x27.github/workflows/dispatch-release.yml\x27,\x27utf8\x27)\"");
  console.log("readable");
'
python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/dispatch-release.yml')); print('yaml ok')" 2>/dev/null || echo "(python yaml 미설치 — GitHub이 푸시 시 검증한다)"
```
Expected: `readable`, 그리고 yaml 파서가 있으면 `yaml ok`

- [ ] **Step 4: 요청 파일을 만들지 않았는지 확인한다**

Run: `test ! -e .github/release-request.json && echo "OK: 요청 파일 없음"`
Expected: `OK: 요청 파일 없음`

⚠️ 이 파일을 지금 만들면 머지 즉시 **실제 태그가 잘리고 진짜 릴리스가 시작된다**. 첫 실제 릴리스 PR이 만든다.

- [ ] **Step 5: DEPLOY.md에 자동화 경로를 기록한다**

§1(Common Principles)의 `human-gate` 항목을 다음으로 교체한다(영문):

```markdown
- **human-gate**: the deployment decision must always be made **by a human**. There are two
  supported ways to express it. (1) **Merge a release PR** — Claude prepares a PR that bumps
  the version and writes `.github/release-request.json`; merging it is the approval, and
  `dispatch-release.yml` cuts the tag from `lang` + `version` (never from a `tag` field, which
  would let a cheap language declare an expensive tag). (2) **Push the tag by hand** — still
  supported, and **mandatory for Go**, whose tag *is* its publication. `release-trigger.sh`
  only prints the commands and never runs `git tag`/`git push` itself.
- **Tag creation is now enforced, not merely conventional.** Three tag rulesets restrict who
  may create release tags; `go/v*` is restricted to the repository admin, so no workflow change
  can make Go release automatically. See CONTRIBUTING §4.
```

§4(Release Procedure Summary)의 5번 항목을 교체한다:

```markdown
5. **A human approves** — either merge the release PR (steps 1–2 are then already in it), or,
   for Go, copy and run the printed `git tag ... && git push origin ...` as-is.
```

- [ ] **Step 6: 문서 가드가 통과하는지 확인한다**

Run:
```bash
node scripts/check-docs.mjs .
sh scripts/test/test-deploy-md.sh
```
Expected: 둘 다 통과

- [ ] **Step 7: 커밋**

```bash
git add .github/workflows/dispatch-release.yml DEPLOY.md
git commit -m "feat(ci): dispatch-release.yml — 릴리스 PR 머지가 태그를 만든다

머지가 사람의 승인이다. 이 워크플로는 검증하고 태그만 만들며, 게시는 기존 9개
릴리스 워크플로가 태그에 반응해 수행한다(한 줄도 수정하지 않았다 — verify·
integration·install-smoke 게이트 전부 그대로).

fail-closed 지점: App 자격증명 미설정 · 요청 검증 실패 · 매니페스트 버전 불일치 ·
태그 룰셋 부재. 요청 파일 부재는 no-op이고 태그가 이미 있으면 멱등 스킵이다.

⚠️ 파일명이 dispatch-release.yml인 것은 의도다 — check-ci-permissions.mjs의
isRelease(/release\.ya?ml\$/)에 매칭돼야 릴리스용 강한 권한 규칙을 상속한다.
release-dispatch.yml로 두면 가장 특권적인 이 파일만 조용히 검사에서 빠지고
--min-release=9는 그대로 충족돼 신호가 나지 않는다.

App이 필요한 이유는 하나다: 기본 GITHUB_TOKEN으로 만든 태그는 다른 워크플로를
트리거하지 않는다. 권한은 Contents: write 하나뿐이고 main.json의 bypass_actors:[]가
그 토큰의 main push를 막는다."
```

- [ ] **Step 8: App 생성 후 룰셋에 App을 추가한다(소유자 작업 완료 후)**

App이 만들어지면 App의 숫자 ID를 얻어 `tags-create.json`의 `bypass_actors`에 추가한다. **`tags-create-go.json`에는 추가하지 않는다** — Go를 소유자 전용으로 두는 것이 이 설계의 핵심이다.

```bash
# App ID는 App 설정 페이지에 표시된다. slug로도 조회할 수 있다:
gh api /apps/<app-slug> --jq '.id'
```

`tags-create.json`의 `bypass_actors`에 추가:
```json
    {
      "actor_id": <APP_ID>,
      "actor_type": "Integration",
      "bypass_mode": "always"
    }
```

그다음 `node scripts/repo-config.mjs apply && node scripts/repo-config.mjs check`.

---

## Self-Review

**1. 스펙 커버리지**

| 스펙 요구 | 구현 |
|---|---|
| §4.2(a) 요청 파일, `tag` 필드 없음 | Task 2 Step 3 `rq_validate_file` + Task 2 Step 1 주입 테스트 |
| §4.2(b) `dispatch-release.yml` 명명·트리거·concurrency·App 토큰·fail-closed | Task 3 Step 1 |
| §4.2(c) 룰셋 3종, Go는 소유자 전용, deletion 규칙 | Task 1 Step 1 |
| §4.2(d) 기존 9개 워크플로 무수정 | 어느 태스크도 건드리지 않음(Global Constraints) |
| §4.4 오류 처리표 8행 | Task 2 Step 3(6행) + Task 3 Step 1(룰셋 부재·App 미설정) |
| §4.5 복구는 전진만 | `tags-immutable.json` + 멱등 스킵 주석 + `workflow_dispatch` 복구 경로 |
| §4.6 자기수정 경계 3종 | (1) `main.json` 무변경 (2) Task 1 룰셋 (3) 기존 워크플로 무수정 |
| §5 environment 미추가 | 어느 태스크도 `environment:`를 추가하지 않음 |
| §6 테스트 불변식 6종 | Task 2 Step 1에 전부 있음 |
| §7-A 소유자 작업 | Task 1 Step 6 · Task 3 Step 8에 명령까지 기록 |

⚠️ **스펙에서 의도적으로 벗어난 점 하나**: 스펙 §6은 "디스패처의 검증 블록을 마커로 추출해 실행한다"고 했으나, 검증 로직을 `scripts/release-request.sh`로 **분리**하고 워크플로가 그것을 호출하게 했다. 마커 추출은 로직이 세 워크플로에 중복될 수밖에 없던 `test-release-prerelease.sh`의 사정에서 나온 기법이다. 여기서는 소비자가 하나뿐이라 스크립트 분리가 더 단순하고, **테스트가 워크플로와 같은 파일을 실행한다**는 원래 목적("검증 대상은 실제로 배포되는 그 문자열")은 그대로 달성된다.

**2. 자리표시자 스캔** — `<APP_ID>`(Task 3 Step 8)와 `<app-slug>`는 App이 존재해야 알 수 있는 값이며, 얻는 명령을 함께 적었다. 그 외 TBD/TODO 없음.

**3. 타입 정합성** — `rq_derive_tag`·`rq_validate_file`·`rq_field`가 Task 2에서 정의되고 Task 3이 CLI 계약(`stdout: <lang> <version> <tag>` · exit 0/1/3)으로만 소비한다. 룰셋 이름 `RELEASE-TAGS-CREATE`가 Task 1(정의)과 Task 3(조회)에서 동일하다. 시크릿 이름 `RELEASE_APP_ID`·`RELEASE_APP_PRIVATE_KEY`가 Task 3 안에서 두 스텝에 걸쳐 동일하다.
