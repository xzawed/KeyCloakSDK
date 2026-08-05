# 문서 구조 재편 + 정확성 가드 구현 계획

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 루트 `CLAUDE.md`를 134KB → 34KB로 줄이되 지식 손실 0을 유지하고, 문서-코드 드리프트를 CI에서 fail-closed로 차단한다.

**Architecture:** 압축 + 가산적 중첩 — 게차의 **규칙 한 줄은 루트에 남고 상세만 하위 파일로** 내려간다(발견 실패 구조적 제거). 가드는 산문을 읽지 않고 **HTML 주석 앵커로 좌표만 선언**한 뒤 빌드 파일에서 값을 추출·대조한다(가드 자신이 드리프트 불가). 가드를 압축보다 **먼저** 넣어 이후 모든 이동을 보호한다.

**Tech Stack:** Node ESM(의존성 0) · POSIX sh + 기존 `scripts/test/assert.sh` · GitHub Actions(`repo-hygiene.yml`)

설계 근거: [2026-07-23-docs-restructure-design.md](../specs/2026-07-23-docs-restructure-design.md)

## Global Constraints

- 검증된 사실만 사용한다. 설계 스펙 §2의 로딩 시맨틱은 공식 문서 확인 완료 — `@path` import는 **eager**라 컨텍스트를 줄이지 못하므로 **사용 금지**.
- `claudeMdExcludes`는 **glob 배열이며 절대경로에 매칭**된다(`.claude/settings.json` 배치 가능).
- `.claude/rules/*.md`의 frontmatter 지원 키는 **`paths`뿐**이다.
- 가드는 **의존성 0 · Docker 불요 · 툴체인 불요 · 5초 이내**여야 한다.
- 모든 새 셸 스크립트는 **실행비트 100755** 필요(`repo-hygiene.yml`의 `shell-exec-bits` 잡이 강제).
- 새 `.md`·`.mjs`·`.json`은 **LF**로 작성한다. 워킹트리는 Windows/CRLF다.
- 커밋 메시지 끝에 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- `main` 직접 push 금지 — 브랜치 규칙이 PR을 요구한다.
- 판정 기준은 PR 델타가 아니라 **설계 스펙 §4.1의 섹션별 예산**이다.

---

## File Structure

| 파일 | 책임 |
|---|---|
| `.claude/settings.json` (신규) | `claudeMdExcludes` — 서드파티 CLAUDE.md 차단 |
| `.gitattributes` (수정) | `*.md text eol=lf` 추가 |
| `scripts/check-docs.mjs` (신규) | 가드 본체. 앵커 파싱 · 소스 추출 · 대조 · fail-closed |
| `scripts/test/test-check-docs.sh` (신규) | 변이 자가테스트. `assert.sh` 사용 |
| `scripts/test/fixtures/doc-guard/` (신규) | 동결 픽스처(정상 1 + 변이 3) |
| `.github/workflows/repo-hygiene.yml` (수정) | `doc-facts` 잡 추가 |
| `CLAUDE.md` (수정) | 앵커 부착 → 추출 → 이관 → 압축 → 게차 재작성 |
| `docs/governance/history.md` (신규) | `현재 상태` 서사 이관처 |
| `docs/guides/getting-started.md` (수정) | 드리프트 수정 + 앵커 |
| `<lang>/CLAUDE.md` ×9 (신규, Task 9) | 언어별 상세 |

---

### Task 1: 서드파티 CLAUDE.md 차단 + `.md` LF 정규화

`php/vendor/phpstan/phpstan/CLAUDE.md`는 `composer install` 산출물이며 `php/.gitignore`로 무시된다 — 파일을 고칠 수 없으므로 설정으로 배제한다. 지연 로딩 특성상 PHP 파일을 읽으면 제3자의 지시가 컨텍스트에 주입된다.

**Files:**
- Create: `.claude/settings.json`
- Modify: `.gitattributes`

**Interfaces:**
- Produces: `.claude/` 디렉터리(Task 9가 `.claude/rules/`를 쓸 수 있는 경우 재사용)

- [ ] **Step 1: 현재 노출을 확인한다**

```bash
find . -name CLAUDE.md -not -path './.git/*'
```

Expected: `./CLAUDE.md` 와 `./php/vendor/phpstan/phpstan/CLAUDE.md` 두 줄. 두 번째가 차단 대상이다.

- [ ] **Step 2: `.claude/settings.json` 생성**

```json
{
  "claudeMdExcludes": [
    "**/vendor/**/CLAUDE.md",
    "**/node_modules/**/CLAUDE.md",
    "**/target/**/CLAUDE.md",
    "**/build/**/CLAUDE.md"
  ]
}
```

의존성 디렉터리 전체를 막는다 — `php/vendor`만 막으면 다른 언어에서 같은 일이 생겼을 때 또 놓친다.

- [ ] **Step 3: `.gitattributes`에 `.md` 규칙 추가**

기존 파일 끝에 다음을 덧붙인다(기존 `*.sh`/`gradlew` 줄은 그대로 둔다):

```
# 마크다운도 LF로 고정한다. 가드(scripts/check-docs.mjs)가 `--fix`로 문서를 고칠 때
# CRLF 워킹트리에서는 파일 전체가 변경된 것처럼 보여 리뷰가 불가능해진다.
*.md    text eol=lf
```

- [ ] **Step 4: 기존 `.md`가 재정규화되는지 확인**

```bash
git add --renormalize . && git status --short | head -20
```

Expected: `.md` 파일들이 수정으로 표시될 수 있다. 표시되면 그대로 커밋한다(내용 변경 없이 줄바꿈만 정규화).

- [ ] **Step 5: 커밋**

```bash
git add .claude/settings.json .gitattributes
git add --renormalize .
git commit -m "$(cat <<'EOF'
chore: 서드파티 CLAUDE.md 차단 + 마크다운 LF 정규화

php/vendor/phpstan/phpstan/CLAUDE.md는 composer install 산출물이고 php/.gitignore로
무시되므로 파일을 고칠 수 없다. 하위 CLAUDE.md는 그 디렉터리 파일을 읽을 때 지연
로딩되므로, PHP 작업 중 제3자의 지시가 컨텍스트에 주입된다. claudeMdExcludes로
의존성 디렉터리 전체를 배제한다(vendor·node_modules·target·build) — php만 막으면
다른 언어에서 같은 일이 생겼을 때 또 놓친다.

*.md eol=lf는 후속 가드의 --fix 모드 선행 조건이다. 현재 .md가 미커버라
CRLF 워킹트리에서 자동수정을 돌리면 파일 전체가 변경된 것처럼 보인다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: 가드 — 앵커 파싱 + 의존성 버전 대조 (검사 1)

**Files:**
- Create: `scripts/check-docs.mjs`
- Create: `scripts/test/test-check-docs.sh`
- Create: `scripts/test/fixtures/doc-guard/ok.md`
- Create: `scripts/test/fixtures/doc-guard/src/build.gradle.kts`

**Interfaces:**
- Produces: `scripts/check-docs.mjs <repoRoot>` — 종료코드 0(정상)/1(불일치·추출부족). stdout에 `checked N facts across M anchors`.
- Produces: 앵커 문법 `<!-- doc-guard: kind=dep source=<경로> min=<정수> -->` + 뒤따르는 마크다운 표.

- [ ] **Step 1: 픽스처 작성**

`scripts/test/fixtures/doc-guard/src/build.gradle.kts`:

```kotlin
dependencies {
    api("org.example:alpha:1.2.3")
    implementation("org.example:beta:4.5.6")
}
```

`scripts/test/fixtures/doc-guard/ok.md`:

```markdown
# fixture

<!-- doc-guard: kind=dep source=src/build.gradle.kts min=2 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Alpha | `org.example:alpha` | 1.2.3 |
| Beta | `org.example:beta` | 4.5.6 |
```

- [ ] **Step 2: 실패하는 테스트 작성**

`scripts/test/test-check-docs.sh`:

```sh
#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/doc-guard"
GUARD="$DIR/../check-docs.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 정상 픽스처는 통과해야 한다.
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# 변이 1: 문서의 값을 훼손하면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
sed -i 's/| 1\.2\.3 |/| 9.9.9 |/' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# 변이 2: 표를 지우면 min 미달로 실패해야 한다(침묵 금지).
cp -r "$FIX/." "$TMP/"
sed -i '/org.example/d' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# 변이 3: 소스를 비우면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
: > "$TMP/src/build.gradle.kts"
assert_fails node "$GUARD" "$TMP"

assert_report
```

⚠️ **`assert_report`를 반드시 마지막에 호출한다.** `assert.sh`의 어서션들은 실패를 `_A_FAIL`에 누적만 하고 스스로 종료코드를 바꾸지 않는다 — `assert_report`가 없으면 어서션이 전부 실패해도 스크립트는 **exit 0**이 되어 CI 게이트가 조용히 무력화된다(실증: `assert_ok false`만 있는 스크립트의 종료코드는 0). 기존 `scripts/test/test-*.sh` 4개가 모두 이 호출로 끝난다.

- [ ] **Step 3: 테스트가 실패하는지 확인**

```bash
chmod +x scripts/test/test-check-docs.sh && sh scripts/test/test-check-docs.sh
```

Expected: FAIL — `node: can't open file .../check-docs.mjs` (아직 가드가 없음)

- [ ] **Step 4: 가드 구현**

`scripts/check-docs.mjs`:

```js
#!/usr/bin/env node
// 문서-소스 드리프트 가드. 산문을 읽지 않는다 — HTML 주석 앵커가 선언한 좌표만
// 읽고 값은 빌드 파일에서 추출해 대조한다. 기대값을 이 스크립트에 적지 않으므로
// 가드 자신은 드리프트할 수 없다.
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve, relative } from 'node:path'

const ROOT = resolve(process.argv[2] ?? '.')
const SKIP = new Set(['.git', 'node_modules', 'vendor', 'target', 'build', 'dist', '.gradle'])

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name)) continue
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (name.endsWith('.md')) out.push(p)
  }
  return out
}

// "org.example:alpha" -> "1.2.3"
function fromGradle(t) {
  const m = new Map()
  for (const x of t.matchAll(/["']([\w.\-]+:[\w.\-]+):([\w.\-]+)["']/g)) m.set(x[1], x[2])
  return m
}
function fromPom(t) {
  const props = new Map()
  for (const x of t.matchAll(/<([\w.\-]+)>([^<>\s]+)<\/\1>/g)) props.set(x[1], x[2])
  const m = new Map()
  for (const d of t.matchAll(/<dependency>([\s\S]*?)<\/dependency>/g)) {
    const g = /<groupId>([^<]+)<\/groupId>/.exec(d[1])
    const a = /<artifactId>([^<]+)<\/artifactId>/.exec(d[1])
    const v = /<version>([^<]+)<\/version>/.exec(d[1])
    if (!g || !a || !v) continue
    let ver = v[1].trim()
    const pm = /^\$\{(.+)\}$/.exec(ver)
    if (pm) ver = props.get(pm[1]) ?? ver
    m.set(`${g[1].trim()}:${a[1].trim()}`, ver)
  }
  return m
}
function fromPackageJson(t) {
  const j = JSON.parse(t)
  const m = new Map()
  for (const sec of ['dependencies', 'devDependencies']) {
    for (const [k, v] of Object.entries(j[sec] ?? {})) m.set(k, v)
  }
  return m
}
function fromCsproj(t) {
  const m = new Map()
  for (const x of t.matchAll(/<PackageReference\s+Include="([^"]+)"\s+Version="([^"]+)"/g)) m.set(x[1], x[2])
  return m
}

function extract(sourceRel) {
  const text = readFileSync(join(ROOT, sourceRel), 'utf8')
  if (sourceRel.endsWith('.gradle.kts')) return fromGradle(text)
  if (sourceRel.endsWith('pom.xml')) return fromPom(text)
  if (sourceRel.endsWith('package.json')) return fromPackageJson(text)
  if (sourceRel.endsWith('.csproj')) return fromCsproj(text)
  throw new Error(`no extractor for ${sourceRel}`)
}

function parseAttrs(s) {
  const o = {}
  for (const m of s.matchAll(/([\w-]+)=(\S+)/g)) o[m[1]] = m[2]
  return o
}

// 앵커 바로 뒤의 표에서 (좌표, 버전) 쌍을 뽑는다. 좌표는 행의 첫 백틱 토큰,
// 버전은 마지막 셀이다.
function rowsAfter(lines, startIdx) {
  const rows = []
  for (let i = startIdx; i < lines.length; i++) {
    const l = lines[i]
    if (!l.trim()) { if (rows.length) break; else continue }
    if (!l.trimStart().startsWith('|')) { if (rows.length) break; else continue }
    const cells = l.split('|').slice(1, -1).map((c) => c.trim())
    if (cells.every((c) => /^:?-+:?$/.test(c))) continue
    const coord = /`([^`]+)`/.exec(l)
    if (!coord) continue
    const ver = cells[cells.length - 1].replace(/[`*]/g, '').trim()
    rows.push({ coord: coord[1], ver })
  }
  return rows
}

const errors = []
let facts = 0
let anchors = 0

for (const file of walk(ROOT)) {
  const rel = relative(ROOT, file).replace(/\\/g, '/')
  const lines = readFileSync(file, 'utf8').split(/\r?\n/)
  for (let i = 0; i < lines.length; i++) {
    const a = /<!--\s*doc-guard:\s*(.*?)\s*-->/.exec(lines[i])
    if (!a) continue
    anchors++
    const attrs = parseAttrs(a[1])
    const min = Number(attrs.min ?? 1)
    let source
    try {
      source = extract(attrs.source)
    } catch (e) {
      errors.push(`${rel}:${i + 1} 소스 추출 실패 (${attrs.source}): ${e.message}`)
      continue
    }
    const rows = rowsAfter(lines, i + 1)
    let checked = 0
    for (const { coord, ver } of rows) {
      const actual = source.get(coord)
      if (actual === undefined) {
        errors.push(`${rel}:${i + 1} 좌표 '${coord}' 를 ${attrs.source} 에서 찾지 못함`)
        continue
      }
      checked++
      if (actual !== ver) {
        errors.push(`${rel}:${i + 1} '${coord}' 문서=${ver} 실제=${actual} (${attrs.source})`)
      }
    }
    if (checked < min) {
      errors.push(`${rel}:${i + 1} 추출 ${checked}건 < min=${min} — 형식이 바뀌어 가드가 무력화됐을 수 있음`)
    }
    facts += checked
  }
}

if (errors.length) {
  for (const e of errors) console.error(`::error::${e}`)
  console.error(`문서 드리프트 ${errors.length}건`)
  process.exit(1)
}
console.log(`checked ${facts} facts across ${anchors} anchors`)
```

- [ ] **Step 5: 테스트가 통과하는지 확인**

```bash
sh scripts/test/test-check-docs.sh
```

Expected: `4 passed, 0 failed` 이후 종료코드 0 (변이 3건이 전부 실패로 잡히고 정상 픽스처는 통과)

- [ ] **Step 6: 커밋**

```bash
chmod +x scripts/check-docs.mjs scripts/test/test-check-docs.sh
git add scripts/check-docs.mjs scripts/test/test-check-docs.sh scripts/test/fixtures
git commit -m "$(cat <<'EOF'
feat(guard): 문서-소스 드리프트 가드 — 앵커 기반 의존성 버전 대조

산문을 읽지 않는다. 프로토타입 실측에서 휴리스틱 산문 스캔은 11건 보고 중 대부분이
오탐이었고 진짜 드리프트 2건을 둘 다 놓쳤다. 대신 HTML 주석 앵커가 좌표만 선언하고
값은 빌드 파일에서 추출해 대조한다 — 기대값을 스크립트에 적지 않으므로 가드 자신은
드리프트할 수 없고, 표를 지우면 앵커도 함께 사라져 고아 매핑이 구조적으로 불가능하다.

min=N은 침묵 금지 장치다. 소스 형식이 바뀌어 0건을 추출하면 통과가 아니라 실패다.

변이 자가테스트 3종: 문서 값 훼손 · 표 삭제 · 소스 비움. 셋 다 실패해야 통과이므로
가드가 no-op이 되면 그 사실로 CI가 죽는다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: 가드 — 문서 간 좌표 일치(검사 2) + 최소 런타임(검사 3)

검사 2는 **문서에 버전이 하나도 없어도** 표 간 모순을 잡는다. 실제로 Java 표 `11.37.2` ↔ Kotlin 표 `11.38.1` 불일치가 사람 손으로 발견됐다.

**Files:**
- Modify: `scripts/check-docs.mjs`
- Modify: `scripts/test/test-check-docs.sh`
- Create: `scripts/test/fixtures/doc-guard/runtime.md`

**Interfaces:**
- Consumes: Task 2의 `extract()`·`rowsAfter()`·`parseAttrs()`
- Produces: 앵커 `kind=runtime` — `<!-- doc-guard: kind=runtime lang=<언어> -->` 뒤 인라인 코드로 표기된 버전 1개를 검사

- [ ] **Step 1: 실패하는 테스트 추가**

`scripts/test/test-check-docs.sh`의 `assert_report` 직전에 추가:

```sh
# 검사 2: 같은 좌표가 두 문서에서 다른 값을 말하면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
cp "$TMP/ok.md" "$TMP/other.md"
sed -i 's/| 1\.2\.3 |/| 1.2.4 |/' "$TMP/other.md"
assert_fails node "$GUARD" "$TMP"

# 검사 3: 최소 런타임 주장이 소스와 다르면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=node -->' 'Node `>=22` 이상이 필요하다.' > "$TMP/runtime.md"
mkdir -p "$TMP/node" && printf '%s\n' '{"engines":{"node":">=22"}}' > "$TMP/node/package.json"
assert_ok node "$GUARD" "$TMP"
sed -i 's/`>=22`/`>=20`/' "$TMP/runtime.md"
assert_fails node "$GUARD" "$TMP"
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
sh scripts/test/test-check-docs.sh
```

Expected: FAIL — 검사 2·3이 아직 없어 `assert_fails`가 통과하지 못한다.

- [ ] **Step 3: 검사 2·3 구현**

`scripts/check-docs.mjs`의 `const errors = []` 위에 런타임 추출기를 추가한다:

```js
// 최소 런타임 — 언어별 고정 추출기(좌표가 없는 단일 값)
const RUNTIME = {
  java: ['java/pom.xml', (t) => /<maven\.compiler\.release>([^<]+)</.exec(t)?.[1]],
  kotlin: ['kotlin/build.gradle.kts', (t) => /jvmToolchain\((\d+)\)/.exec(t)?.[1]],
  node: ['node/package.json', (t) => JSON.parse(t).engines?.node],
  go: ['go/go.mod', (t) => /^go\s+([\d.]+)/m.exec(t)?.[1]],
  dotnet: ['dotnet/Directory.Build.props', (t) => /<TargetFramework>([^<]+)</.exec(t)?.[1]],
  php: ['php/composer.json', (t) => JSON.parse(t).require?.php],
  rust: ['rust/Cargo.toml', (t) => /^rust-version\s*=\s*"([^"]+)"/m.exec(t)?.[1]],
  ruby: ['ruby/keycloak-sdk.gemspec', (t) => /required_ruby_version\s*=\s*["']([^"']+)["']/.exec(t)?.[1]],
  python: ['python/pyproject.toml', (t) => /^requires-python\s*=\s*"([^"]+)"/m.exec(t)?.[1]],
}
const seen = new Map() // coord -> [{file, ver}]
```

`for (const { coord, ver } of rows)` 루프 안, `facts += checked` 앞에 좌표 수집을 추가한다:

```js
      if (!seen.has(coord)) seen.set(coord, [])
      seen.get(coord).push({ rel, ver })
```

앵커 분기에서 `kind=runtime`을 처리하도록 `const attrs = parseAttrs(a[1])` 다음에 삽입한다:

```js
    if (attrs.kind === 'runtime') {
      const spec = RUNTIME[attrs.lang]
      if (!spec) { errors.push(`${rel}:${i + 1} 알 수 없는 lang=${attrs.lang}`); continue }
      const [srcRel, pick] = spec
      let actual
      try { actual = pick(readFileSync(join(ROOT, srcRel), 'utf8')) } catch (e) {
        errors.push(`${rel}:${i + 1} ${srcRel} 읽기 실패: ${e.message}`); continue
      }
      if (!actual) { errors.push(`${rel}:${i + 1} ${srcRel} 에서 최소 런타임을 추출하지 못함`); continue }
      const claim = /`([^`]+)`/.exec(lines.slice(i + 1, i + 4).join('\n'))
      if (!claim) { errors.push(`${rel}:${i + 1} 런타임 앵커 뒤에 백틱 버전 표기가 없음`); continue }
      facts++
      if (claim[1] !== actual) {
        errors.push(`${rel}:${i + 1} ${attrs.lang} 최소 런타임 문서=${claim[1]} 실제=${actual} (${srcRel})`)
      }
      continue
    }
```

마지막으로 문서 간 일치 검사를 `if (errors.length)` 앞에 추가한다:

```js
for (const [coord, hits] of seen) {
  const vers = [...new Set(hits.map((h) => h.ver))]
  if (vers.length > 1) {
    errors.push(`좌표 '${coord}' 가 문서마다 다름: ${hits.map((h) => `${h.rel}=${h.ver}`).join(' vs ')}`)
  }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인**

```bash
sh scripts/test/test-check-docs.sh
```

Expected: `N passed, 0 failed` 이후 종료코드 0

- [ ] **Step 5: 커밋**

```bash
git add scripts/check-docs.mjs scripts/test/test-check-docs.sh scripts/test/fixtures
git commit -m "$(cat <<'EOF'
feat(guard): 문서 간 좌표 일치 + 9언어 최소 런타임 검사 추가

검사 2(문서 간 일치)는 문서에 버전이 하나도 없어도 표 간 모순을 잡는다 — 실제로
Java 표 11.37.2 ↔ Kotlin 표 11.38.1 불일치를 사람이 손으로 찾아냈던 사건이 있다.

검사 3은 9개 언어의 최소 런타임 선언(maven.compiler.release · jvmToolchain ·
engines.node · go 지시자 · TargetFramework · composer require.php · rust-version ·
required_ruby_version · requires-python)을 각각 고정 추출기로 읽는다. 과거
"Node 20+" 잔존을 사람이 수동 발견했던 클래스다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: 앵커 부착 + 살아있는 드리프트 3건 수정 + CI 배선

가드는 압축보다 **먼저** 완성한다 — 이후 41KB를 옮기는 작업이 전부 이 보호 아래에서 일어난다.

**Files:**
- Modify: `CLAUDE.md` (앵커 부착 + dotnet 버전 수정)
- Modify: `docs/guides/getting-started.md` (앵커 부착 + Kotlin/oauth2 버전 수정)
- Modify: `.github/workflows/repo-hygiene.yml`

**Interfaces:**
- Consumes: Task 2·3의 `scripts/check-docs.mjs`

- [ ] **Step 1: 가드를 현재 저장소에 돌려 드리프트를 재현한다**

먼저 `CLAUDE.md`의 dotnet 의존성 표 위에 앵커를 넣는다(표 시작 줄 바로 위):

```markdown
<!-- doc-guard: kind=dep source=dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj min=2 -->
```

그리고 실행:

```bash
node scripts/check-docs.mjs .
```

Expected: FAIL — `'Microsoft.IdentityModel.JsonWebTokens' 문서=8.19.2 실제=8.20.0`

- [ ] **Step 2: 드리프트 3건을 수정한다**

`CLAUDE.md` 516행 — `8.19.2` → `8.20.0`.

`docs/guides/getting-started.md` 583행 — `Kotlin **2.2.20 or newer**` → `Kotlin **2.4.10 or newer**`.

`docs/guides/getting-started.md` 670행 — `oauth2-oidc-sdk` **11.37.2** → **11.38.2**.

- [ ] **Step 3: 나머지 표에 앵커를 부착한다**

`CLAUDE.md`의 Java 의존성 표 위:

```markdown
<!-- doc-guard: kind=dep source=java/pom.xml min=3 -->
```

`CLAUDE.md`의 Kotlin 의존성 표 위:

```markdown
<!-- doc-guard: kind=dep source=kotlin/build.gradle.kts min=3 -->
```

`docs/guides/getting-started.md`의 언어별 버전표 위에도 같은 방식으로 부착한다(해당 언어의 소스 파일 지정).

- [ ] **Step 4: 가드가 통과하는지 확인**

```bash
node scripts/check-docs.mjs .
```

Expected: `checked N facts across M anchors` (N ≥ 8), 종료코드 0

- [ ] **Step 5: CI 잡 추가**

`.github/workflows/repo-hygiene.yml`의 `jobs:` 아래에 추가한다:

```yaml
  doc-facts:
    # 문서가 주장하는 버전이 빌드 파일과 일치하는지 검사한다.
    #
    # 경로 필터를 두지 않는 이유: 드리프트는 문서가 아니라 `pom.xml`에서 시작한다.
    # 의존성만 올리고 문서를 안 고친 PR이 정확히 이 잡이 잡아야 할 대상인데,
    # 경로 필터를 `**.md`로 걸면 그 PR에서 잡이 아예 돌지 않는다.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v7
        with:
          node-version: '22'
      - name: 가드 자가테스트(변이 3종이 전부 잡히는지)
        run: sh scripts/test/test-check-docs.sh
      - name: 문서-소스 대조
        run: node scripts/check-docs.mjs .
```

자가테스트를 본 검사보다 **먼저** 돌린다 — 가드가 no-op이 됐다면 본 검사의 GREEN은 의미가 없다.

- [ ] **Step 6: 커밋**

```bash
git add CLAUDE.md docs/guides/getting-started.md .github/workflows/repo-hygiene.yml
git commit -m "$(cat <<'EOF'
feat(guard): 앵커 부착 + CI 배선, 살아있는 드리프트 3건 수정

가드를 켜자마자 잡힌 것:
  - CLAUDE.md: Microsoft.IdentityModel.* 8.19.2 → 실제 8.20.0 (PR #92가 만든 드리프트)
  - getting-started.md: Kotlin 2.2.20 → 실제 2.4.10
  - getting-started.md: oauth2-oidc-sdk 11.37.2 → 실제 11.38.2

뒤 둘은 사용자에게 나가는 설치 문서다. 앞선 수동 대조(PR #96)가 Java·Kotlin 의존성
표 9건만 검사해 "불일치 0"으로 판정했으나, 그 범위 밖은 그대로 썩고 있었다 —
사람이 검사 범위를 정하는 방식이 실패한다는 증거다.

CI 잡에 경로 필터를 두지 않는다. 드리프트는 문서가 아니라 빌드 파일에서 시작하므로,
`**.md` 필터를 걸면 의존성만 올린 PR에서 잡이 돌지 않는다. 자가테스트를 본 검사보다
먼저 돌려 가드가 no-op이 아님을 매번 증명한다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: 추출 — `현재 상태`에서 툴체인·게차 분리 (Δ0)

⚠️ **이 태스크를 건너뛰고 Task 6을 실행하면 9개 언어의 모든 빌드·테스트 명령과 게차 10건이 함께 삭제된다.** `### <Lang> 툴체인` 9블록(19,121B)과 게차 10건이 `## 현재 상태` 아래에 중첩돼 있다.

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: `## 툴체인` 최상위 섹션(9개 `###` 하위 블록 보유), `## 핵심 게차`에 10건 추가

- [ ] **Step 1: 이동 전 바이트 총량을 기록한다**

```bash
wc -c < CLAUDE.md > /tmp/claude-md-before.txt && cat /tmp/claude-md-before.txt
```

Expected: 약 134000대의 숫자

- [ ] **Step 2: 툴체인 9블록을 최상위 섹션으로 승격한다**

`### Java 툴체인 (빌드 명령)` ~ `### Kotlin 툴체인 (빌드 명령)` 9개 블록을 `## 현재 상태` 밖으로 옮기고, 그 앞에 새 최상위 헤딩을 만든다:

```markdown
## 툴체인 (빌드 명령)
```

9개 블록은 `###` 레벨을 유지한 채 이 헤딩 아래로 이동한다. **내용은 한 글자도 바꾸지 않는다.**

- [ ] **Step 3: `현재 상태`에 묻힌 게차 10건을 `## 핵심 게차`로 옮긴다**

대상(`현재 상태` 본문에서 `⚠️`로 시작하거나 함정을 서술하는 항목):

```bash
sed -n '22,73p' CLAUDE.md | grep -n "⚠️" | cut -c1-100
```

찾은 항목을 `## 핵심 게차` 섹션 끝으로 옮긴다. **문구는 바꾸지 않는다** — 압축은 Task 8에서 한다.

- [ ] **Step 4: 순수 이동인지 검증한다**

```bash
AFTER=$(wc -c < CLAUDE.md); BEFORE=$(cat /tmp/claude-md-before.txt)
echo "before=$BEFORE after=$AFTER delta=$((AFTER-BEFORE))"
node scripts/check-docs.mjs .
```

Expected: `delta` 절댓값이 200 이하(헤딩 추가분만), 가드 통과

- [ ] **Step 5: 커밋**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
refactor(docs): 툴체인 9블록·게차 10건을 `현재 상태`에서 분리 (내용 무변경)

`### <Lang> 툴체인` 9개 블록(19,121B)과 게차 10건이 `## 현재 상태` 아래에 중첩돼
있었다. 다음 커밋에서 그 섹션의 서사를 이관하는데, 이 분리를 먼저 하지 않으면
9개 언어의 모든 빌드·테스트 명령과 게차가 함께 사라진다.

조사 초기 이 중첩을 놓쳐 "toolchain 3,730B"로 집계했다 — 실제 19,121B다. 그 상태로
"현재 상태를 통째로 삭제" 판단을 내렸다면 손실이 발생했을 것이다.

내용은 한 글자도 바꾸지 않았다. 바이트 총량 불변으로 순수 이동임을 확인.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: 이관 — 서사 → `docs/governance/history.md`

**Files:**
- Create: `docs/governance/history.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: `## 현재 상태` 자리에 10행 상태표

- [ ] **Step 1: 이력 문서를 만든다**

`docs/governance/history.md` 머리말:

```markdown
# 구현 이력

`CLAUDE.md`에서 이관한 작업 서사다. 에이전트가 매 세션 읽는 파일에 이력을 쌓지 않는다는
규칙(전역 문서 규칙 §2)에 따라 분리했다. **삭제가 아니라 이관**인 이유: 여기 담긴 PR
#48·#62·#63·#67·#71 등의 경위는 `CHANGELOG.md`와 9개 검증 로그 어디에도 없다.
```

이어서 `## 현재 상태`의 서사 문단 전체를 그대로 옮긴다.

- [ ] **Step 2: `CLAUDE.md`의 `현재 상태`를 상태표로 교체한다**

```markdown
## 현재 상태

9개 언어 SDK 모두 `main` 병합 완료. 어떤 언어도 아직 레지스트리에 게시되지 않았다(전부 사람 승인 게이트).

| 언어 | 배포명 | 태그 접두 | 배포 |
|---|---|---|---|
| Java | `io.github.xzawed:keycloak-sdk` | `v*` | 미실행 |
| Python | `keycloak-sdk` | `py-v*` | 미실행 |
| Node | `@xzawed/keycloak-sdk` | `node-v*` | 미실행 |
| Go | `github.com/xzawed/KeyCloakSDK/go` | `go/v*` | 미실행 |
| C#/.NET | `Xzawed.Keycloak.Sdk` | `dotnet-v*` | 미실행 |
| PHP | `xzawed/keycloak-sdk` | `php-v*` | 미실행 |
| Rust | `keycloak-sdk` | `rust-v*` | 미실행 |
| Ruby | `keycloak-sdk` | `ruby-v*` | 미실행 |
| Kotlin | `io.github.xzawed:keycloak-sdk-kotlin` | `kotlin-v*` | 미실행 |

구현 경위·PR 이력: [docs/governance/history.md](docs/governance/history.md) · 배포 절차: [DEPLOY.md](DEPLOY.md)
```

- [ ] **Step 3: 예산과 가드를 확인한다**

```bash
wc -c < CLAUDE.md
node scripts/check-docs.mjs .
grep -c "PR #48\|PR #62\|PR #63" docs/governance/history.md
```

Expected: `CLAUDE.md`가 96000 이하, 가드 통과, 이력 문서에 PR 참조가 남아 있음(손실 없음)

- [ ] **Step 4: 커밋**

```bash
git add CLAUDE.md docs/governance/history.md
git commit -m "$(cat <<'EOF'
refactor(docs): `현재 상태` 서사를 history.md로 이관, 자리에 10행 상태표

40KB의 PR 서사가 매 세션 컨텍스트에 로드되고 있었다. 삭제가 아니라 이관인 이유:
PR #48·#62·#63·#67·#71의 경위가 CHANGELOG.md와 9개 검증 로그 어디에도 없다
(CHANGELOG는 아직 헤더에서 "8개 언어"라 말하며 Kotlin이 빠져 있다).

CHANGELOG가 아니라 신규 history.md로 보내는 이유: CHANGELOG는 릴리스 대외 문서이고
이미 드리프트했다. 내부 구현 서사를 거기 섞으면 둘 다 나빠진다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: 압축 — 의존성 버전 삭제 + 아키텍처 축약

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 의존성 표에서 버전 열을 제거하고 근거를 남긴다**

각 언어 의존성 표를 다음 형태로 바꾼다(Java 예):

```markdown
<!-- doc-guard: kind=dep source=java/pom.xml min=3 -->

| 의존성 | 좌표 | 버전 | 왜 이 선택인가 |
|---|---|---|---|
| Keycloak admin-client | `org.keycloak:keycloak-admin-client` | 26.0.11 | 서버와 독립 트랙 — "26.6.x admin-client"는 없다 |
```

⚠️ **버전 열은 유지한다.** 설계 스펙 §10-1은 "삭제 vs 파싱"을 열린 항목으로 뒀으나, Task 2~4에서 가드가 이미 이 열을 검증하므로 **드리프트 표면이 이미 0**이다. 삭제하면 사람이 문서만 보고 버전을 확인할 수 없어지는 손실만 남는다. 대신 **"왜 이 선택인가" 열을 추가**해 표가 정보를 담게 한다.

- [ ] **Step 2: 아키텍처 9블록을 공통 1 + 델타 9로 축약한다**

9개 언어의 디렉터리 트리는 모양이 같다. 공통 트리 1개를 제시하고 언어별 차이만 한 줄씩 쓴다:

```markdown
### 공통 모듈 구조

모든 언어가 같은 모양이다 — 파일명·확장자만 언어 관용을 따른다.

```
config · errors/masking · tokens · oidc(엔드포인트 조립, 네트워크 없음)
token_provider(캐시·single-flight) · jwks(DoS-safe) · jwt(자체 강화 검증)
auth(하위 OIDC 라이브러리 래핑) · admin/(5리소스 + raw 탈출구) · client(통합 진입점)
```

### 언어별 차이

| 언어 | 차이 |
|---|---|
| Java | 6개 Maven 모듈로 물리 분리(core·auth·admin·bom·sdk·examples) |
| Go | 전체가 단일 `package keycloak` — admin을 서브패키지로 두면 import 순환 |
| Python | `aio/` 비동기 미러 추가 |
| Kotlin | 단일 Gradle 모듈, 전부 `suspend` |
| Ruby | admin gem 부재로 Faraday raw-REST 직접 구현 |
```

나머지 4개 언어(Node·C#·PHP·Rust)는 공통 모양과 차이가 없으므로 표에 넣지 않는다.

**§4 결합 규칙과 문서화된 은닉성 예외는 원문 그대로 유지한다** — 이건 설계 계약이라 축약하면 의미가 손상된다.

- [ ] **Step 3: 남은 산문 문단을 불릿·표로 전환한다**

크기의 상당 부분은 내용이 아니라 **밀도** 문제다(줄당 227B의 긴 한글 산문). 언어는 한글로 유지하되 문단을 불릿·표로 바꾼다. 한 문단이 여러 사실을 담고 있으면 사실당 한 줄로 나눈다.

- [ ] **Step 4: 예산·가드 확인**

```bash
wc -c < CLAUDE.md
node scripts/check-docs.mjs .
```

Expected: 77000 이하, 가드 통과

- [ ] **Step 5: 커밋**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
refactor(docs): 아키텍처 9블록 축약 + 의존성 표에 근거 열 추가

아키텍처는 9개 언어가 같은 모양이라 공통 트리 1개 + 언어별 델타로 줄였다.
§4 결합 규칙과 문서화된 은닉성 예외는 설계 계약이므로 원문을 유지한다.

의존성 표의 버전 열은 **삭제하지 않았다**. 설계 스펙은 "삭제해서 드리프트 표면을
0으로" 안을 열어뒀으나, 가드가 이미 이 열을 검증하므로 표면은 이미 0이다. 삭제하면
사람이 문서만으로 버전을 확인하지 못하는 손실만 남는다. 대신 "왜 이 선택인가" 열을
추가해 표가 숫자 이상을 담게 했다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: 게차 84건 재작성 — 규칙 + 트리거 + 포인터

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: 각 게차가 `⚠️ **(언어) 규칙 한 줄** → 대응. 근거: <경로 또는 테스트명>` 형태

- [ ] **Step 1: 인과사슬을 유지할 항목을 고른다**

다음 6건은 **왜 그런지를 지우면 같은 버그가 재발**하므로 400B까지 유지한다:

1. (Java·Kotlin) `resteasyClient()`가 JacksonProvider 등록을 우회 — NON_NULL·FAIL_ON_UNKNOWN_PROPERTIES 유실
2. (Node) admin이 만료 시 재인증하도록 provider 배선 — 내장 TokenManager는 refresh만 시도
3. (Go) gocloak이 네트워크 실패를 `APIError{Code:0}`로 감쌈
4. (Node) JWKS rate-limit 회귀는 대조군 없이 잡히지 않음(jose가 기본값 30초로 폴백)
5. (PHP) firebase/php-jwt의 `&$headers`는 성공 디코드 후에만 채워짐
6. (Kotlin) MockK로 JAX-RS 추상 클래스 모킹 시 JDK 21에서 hang

- [ ] **Step 2: 나머지 78건을 스텁으로 압축한다**

형식(150B 목표):

```markdown
- ⚠️ **(Ruby) `jwt` 기본값은 안전하지 않다** — alg 핀·iss/aud/exp/nbf·클록스큐를 전부 명시해야 한다. 상세: `ruby/CLAUDE.md`
```

**교차언어 비교 게차와 harness·CI 게차는 스텁화하되 하위로 내리지 않는다**(소속 언어가 없음).

- [ ] **Step 3: 인용 게이트용 포인터를 단다**

각 게차 끝에 근거를 단다 — 테스트명 또는 소스 경로. 예: `근거: node/test/unit/jwt-jwks.test.ts`

- [ ] **Step 4: 예산·가드 확인**

```bash
wc -c < CLAUDE.md
grep -c "⚠️" CLAUDE.md
node scripts/check-docs.mjs .
```

Expected: 48000 이하, `⚠️` 84개 이상(스텁이 전부 남아 있음), 가드 통과

- [ ] **Step 5: 커밋**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
refactor(docs): 게차 84건을 규칙+트리거+포인터로 재작성

84건 전부 루트에 남긴다 — 개수를 줄이지 않는다. 커밋 120건 중 55%가 언어 디렉터리를
건드리지 않으므로(harness·CI·scripts) 하위 파일의 상세는 자주 미로드다. 그러나 규칙
한 줄이 루트에 있으면 경보는 항상 뜨고 압축 후에도 살아남는다. 상세가 없어 못 찾는
것보다 함정의 존재를 몰라 틀리는 쪽이 훨씬 나쁘다.

인과사슬 6건은 400B까지 유지한다 — 왜 그런지를 지우면 같은 버그가 재발한다.
(JacksonProvider 우회 · node admin 재인증 · gocloak Code:0 · JWKS 대조군 ·
php &$headers · MockK hang)

각 게차 끝에 근거 포인터(테스트명·소스 경로)를 달았다. 가드가 포인터 해석 여부를
검사하면 근거가 밑에서 사라진 것은 잡힌다(주장의 참을 증명하진 않는다).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: 로딩 실증 프로브 → 중첩 형태 확정 → 상세 이관

**Files:**
- Create: `<lang>/CLAUDE.md` ×9 **또는** `.claude/rules/<lang>.md` ×9 (프로브 결과가 결정)
- Modify: `CLAUDE.md`

- [ ] **Step 1: 프로브 1 — Read 없이 빌드 명령만 실행**

새 세션에서 파일을 하나도 읽지 않고 다음만 실행한 뒤, `/context`로 `kotlin/CLAUDE.md` 로드 여부를 확인한다:

```bash
gradle -p kotlin test
```

기록: 로드됨 / 안 됨

- [ ] **Step 2: 프로브 2 — 다른 트리에서 같은 언어를 건드릴 때**

새 세션에서 `harness/apps/kotlin/` 아래 파일을 Read한 뒤 `kotlin/CLAUDE.md` 로드 여부를 확인한다.

기록: 로드됨 / 안 됨

- [ ] **Step 3: 형태를 확정한다**

- 프로브 2가 **로드됨**이면 → `<lang>/CLAUDE.md` 사용
- 프로브 2가 **안 됨**이면 → `.claude/rules/<lang>.md` 사용하고 `paths:`에 3개 트리를 전부 넣는다:

```yaml
---
paths:
  - "kotlin/**"
  - "harness/apps/kotlin/**"
  - "harness/install/consume/kotlin-app/**"
  - ".github/workflows/kotlin-*.yml"
---
```

- [ ] **Step 4: 상세를 이관한다 (스텁은 루트에 남긴다)**

각 언어 파일에 담을 것: 게차 상세 · 아키텍처 트리 · 툴체인 머신 경로.
루트에는 스텁이 그대로 남아야 한다 — Task 8의 `⚠️` 개수가 줄어들면 안 된다.

- [ ] **Step 5: 최종 확인**

```bash
wc -c < CLAUDE.md
grep -c "⚠️" CLAUDE.md
node scripts/check-docs.mjs .
sh scripts/test/test-check-docs.sh
```

Expected: `CLAUDE.md` 40000 이하, `⚠️` 개수 Task 8과 동일, 가드·자가테스트 통과

- [ ] **Step 6: 커밋**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(docs): 언어별 상세를 하위 문서로 이관 (스텁은 루트 유지)

로딩 시맨틱을 실측한 뒤 형태를 정했다 — 하위 CLAUDE.md는 그 디렉터리 파일을 읽을
때만 로드되는데, 이 저장소의 언어는 3개 트리에 흩어져 있다(<lang>/ ·
harness/apps/<lang>/ · harness/install/consume/<lang>-app/).

루트의 게차 스텁 개수는 이 커밋 전후로 동일하다. 상세만 내려갔고 경보는 남았다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: 예방적 검사 3종 + 손으로 쓴 테스트 수 제거

설계 스펙 §5.4의 검사 4·5·6은 아직 발생하지 않은 드리프트를 막는 예방적 검사다. 검사 1~3(실제 사건을 잡은 것)과 달리 **한 사이클 warn-only 후 승격**한다 — `repo-hygiene.yml`은 브랜치 필터 없는 `on: push`라 fail-closed로 즉시 켜면 모든 Dependabot 브랜치가 동시에 빨개진다.

**Files:**
- Modify: `scripts/check-docs.mjs`
- Modify: `scripts/test/test-check-docs.sh`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: Task 2·3의 `errors` 배열·`facts` 카운터
- Produces: `--strict` 플래그 — 없으면 검사 4~6은 경고, 있으면 오류

- [ ] **Step 1: 실패하는 테스트 추가**

`scripts/test/test-check-docs.sh`의 `assert_report` 직전에 추가:

```sh
# 검사 5: 깨진 마크다운 링크는 --strict 에서 실패해야 한다.
cp -r "$FIX/." "$TMP/"
printf '%s\n' '[없는문서](./nope.md)' >> "$TMP/ok.md"
assert_ok node "$GUARD" "$TMP"            # 기본은 경고
assert_fails node "$GUARD" "$TMP" --strict # --strict 는 실패
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
sh scripts/test/test-check-docs.sh
```

Expected: FAIL — `--strict`가 아직 없어 `assert_fails`가 통과하지 못한다.

- [ ] **Step 3: 검사 4·5·6 구현**

`scripts/check-docs.mjs` 상단 `const ROOT = ...` 다음에 추가:

```js
const STRICT = process.argv.includes('--strict')
const warnings = []
```

`walk()` 정의 다음에 추가:

```js
// 검사 4 — 커버리지 게이트 임계값(문서가 주장한 값 ↔ 빌드 설정)
const COVERAGE = {
  java: ['java/pom.xml', (t) => [...t.matchAll(/<minimum>([\d.]+)<\/minimum>/g)].map((m) => m[1])],
  kotlin: ['kotlin/build.gradle.kts', (t) => [...t.matchAll(/minValue\s*=\s*(\d+)/g)].map((m) => m[1])],
  node: ['node/vitest.config.ts', (t) => [...t.matchAll(/(?:lines|branches):\s*(\d+)/g)].map((m) => m[1])],
}

// 검사 5 — 상대 링크 대상이 실제로 존재하는가
function checkLinks(file, rel, text) {
  for (const m of text.matchAll(/\[[^\]]*\]\((\.{0,2}\/[^)#\s]+)/g)) {
    const target = resolve(file, '..', m[1])
    try { statSync(target) } catch {
      ;(STRICT ? errors : warnings).push(`${rel} 링크 대상 없음: ${m[1]}`)
    }
  }
}

// 검사 6 — "9개 언어" 기수가 실제 언어 수와 맞는가
// ⚠️ 지역 변수를 `facts`로 짓지 말 것 — 모듈 스코프의 카운터 `let facts`를 섀도잉한다.
function checkCardinality() {
  const deployFacts = readFileSync(join(ROOT, 'scripts/lib/deploy-facts.sh'), 'utf8')
  const m = /DEPLOY_LANGS="([^"]+)"/.exec(deployFacts)
  if (!m) { errors.push('deploy-facts.sh 에서 DEPLOY_LANGS 를 찾지 못함'); return }
  const n = m[1].trim().split(/\s+/).length
  for (const f of walk(ROOT)) {
    const rel = relative(ROOT, f).replace(/\\/g, '/')
    if (rel.startsWith('docs/superpowers/')) continue // 이력 문서는 당시 기준이 맞다
    const text = readFileSync(f, 'utf8')
    for (const x of text.matchAll(/(\d+)개 언어/g)) {
      if (Number(x[1]) !== n) {
        ;(STRICT ? errors : warnings).push(`${rel} "${x[1]}개 언어" ≠ DEPLOY_LANGS ${n}개`)
      }
    }
  }
}
```

파일 순회 루프 안에서 링크 검사를 호출하고(`const lines = ...` 다음), 마지막 집계 앞에서 기수 검사를 호출한다:

```js
  checkLinks(file, rel, lines.join('\n'))
```

```js
checkCardinality()
for (const w of warnings) console.warn(`::warning::${w}`)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
sh scripts/test/test-check-docs.sh && node scripts/check-docs.mjs .
```

Expected: `N passed, 0 failed`, 그리고 본 저장소에서 `::warning::` 이 출력되되 종료코드 0

- [ ] **Step 5: 손으로 쓴 테스트 수를 제거한다**

`CLAUDE.md`의 `- **테스트 수(<언어>)**: …` 9줄을 삭제하고 한 줄로 대체한다:

```markdown
- **테스트 수·커버리지**: 문서에 적지 않는다. 각 언어 CI 잡과 커버리지 게이트가 유일한 권위다 — 손으로 적으면 반드시 어긋난다(실제로 9언어 중 8개가 세 곳에서 서로 다른 숫자를 말하고 있었다).
```

- [ ] **Step 6: 커밋**

```bash
git add scripts/check-docs.mjs scripts/test/test-check-docs.sh CLAUDE.md
git commit -m "$(cat <<'EOF'
feat(guard): 예방적 검사 3종(커버리지 게이트·링크·기수) + 테스트 수 제거

검사 1~3은 실제 사건을 잡았으므로 fail-closed다. 4~6은 아직 발생하지 않은 드리프트를
막는 예방적 검사라 기본은 경고이고 `--strict`에서만 실패한다 — repo-hygiene.yml은
브랜치 필터 없는 on:push라 즉시 fail-closed로 켜면 모든 Dependabot 브랜치가 동시에
빨개진다. 한 사이클 관찰 후 CI에 --strict를 붙여 승격한다.

손으로 쓴 테스트 수 9줄을 삭제했다. 매개변수 테스트 때문에 @Test grep은 부정확하고,
실제로 9언어 중 8개가 세 곳에서 서로 다른 숫자를 말하고 있었다. 권위는 CI 잡이다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 범위 밖 (의도적 제외)

| 항목 | 왜 제외하나 |
|---|---|
| `TEST-MATRIX.md` 자동 생성 | 권위 있는 유일한 출처가 `harness/report/signals/*.suite.json`인데 이는 60분짜리 야간 Docker 잡이 만든다. 하네스 작업이라 문서 재편과 결합하면 둘 다 늦어진다. Task 10 Step 5가 **틀린 숫자를 먼저 제거**하므로 잘못된 정보는 이미 사라진다 |
| 가드 `--fix` 자동수정 | 설계 스펙 §10-3 열린 항목. 미검토 Dependabot 범프를 "문서화된 의도"로 세탁할 위험이 있어, 가드가 한 사이클 돈 뒤 재평가한다 |
| `MEMORY.md` 축약 | 저장소 밖(`~/.claude/projects/…`) 파일이라 이 PR 흐름에 포함되지 않는다. 전역 규칙 재작성과 함께 별도로 처리 |
| 게차 진실성 검증 | 상류 *동작*에 대한 주장이라 기계 검증 불가(설계 §5.5). Task 8의 인용 포인터가 근거 소실만 잡는다 |

## 완료 조건

| 항목 | 목표 |
|---|---|
| `CLAUDE.md` 크기 | 134KB → 34KB 근처 (설계 §4.1 예산) |
| 게차 스텁 수 | 84건 전부 루트 유지 (Task 8 이후 개수 불변) |
| 지식 손실 | 0 — 모든 내용이 이관되거나 스텁+상세로 분리 |
| 가드 | 검사 1~3 fail-closed, 4~6 경고. 자가테스트가 본 검사보다 먼저 실행 |
| 살아있는 드리프트 | 3건 수정 완료 |
| 손으로 쓴 숫자 | 테스트 수 9줄 제거 |
