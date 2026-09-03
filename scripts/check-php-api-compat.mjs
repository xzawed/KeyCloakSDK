#!/usr/bin/env node
// php-semver-checker 의 판정을 **소스로 반증**해 정밀도를 올린다.
//
// 왜 필요한가: 그 도구는 클래스에 `implements` 절이 하나 붙는 것만으로 손대지 않은 생성자를
// 「기본값이 바뀌었다」(V097)고, 대소문자를 바꾸지 않은 클래스명을 「대소문자가 바뀌었다」(V154)고
// 보고한다. 최소 A/B 로 확인했다 — `php-v1.0.0` 의 KeycloakConfig 에 `implements \JsonSerializable`
// **한 절만** 넣고 다른 문자는 하나도 건드리지 않은 트리가 그 둘을 그대로 낸다.
// 또 `final` 클래스에 public 메서드를 더하는 것(V015)은 상속이 불가능하므로 semver 상 MINOR 인데
// 도구는 무조건 MAJOR 로 센다.
//
// ⚠️ **블랭킷 억제가 아니다.** 면제는 셋뿐이고 각각 **소스로 반증 가능한 술어**를 통과해야 한다 —
// 술어가 거짓이면(진짜로 바뀌었으면) 면제되지 않고 MAJOR 로 남는다. 그래서 이 스크립트는
// 도구의 눈을 가리는 것이 아니라 도구의 주장을 **대조**한다.
//
// 사용:
//   node scripts/check-php-api-compat.mjs --report <파일> --base <디렉터리> --new <디렉터리>
//
// 리포트를 인자로 받는 이유는 자가테스트가 PHP 툴체인 없이 돌 수 있게 하기 위해서다.

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, basename } from 'node:path'

const argv = process.argv.slice(2)
const flag = (name) => {
  const i = argv.indexOf(name)
  return i >= 0 && argv[i + 1] != null && !argv[i + 1].startsWith('--') ? argv[i + 1] : null
}
const reportPath = flag('--report')
const baseDir = flag('--base')
const newDir = flag('--new')

const die = (code, ...lines) => {
  console.error(`::error::${code}`)
  for (const l of lines) console.error(`  ${l}`)
  process.exit(1)
}

if (!reportPath || !baseDir || !newDir) {
  die('usage', '--report <파일> --base <디렉터리> --new <디렉터리> 가 모두 필요하다')
}
for (const [label, p] of [['--report', reportPath], ['--base', baseDir], ['--new', newDir]]) {
  if (!existsSync(p)) die('input-missing', `${label} 경로가 없다: ${p}`)
}

const report = readFileSync(reportPath, 'utf8')

// ── 공허성 하한 ──────────────────────────────────────────────────────────────
// 비교가 일어나지 않았는데 「변경 없음」으로 읽히는 것이 이 부류의 대표 실패다.
if (!/Suggested semantic versioning change:/.test(report)) {
  die('report-invalid', '판정 줄이 없다 — 비교가 일어나지 않았다', '리포트를 그대로 붙여 확인할 것')
}
const countPhp = (dir) => {
  let n = 0
  const walk = (d) => {
    for (const e of readdirSync(d)) {
      const p = join(d, e)
      if (statSync(p).isDirectory()) walk(p)
      else if (e.endsWith('.php')) n++
    }
  }
  walk(dir)
  return n
}
const baseCount = countPhp(baseDir)
const newCount = countPhp(newDir)
if (baseCount === 0 || newCount === 0) {
  die('empty-tree', `비교 대상이 비었다 — base ${baseCount}개 · new ${newCount}개`,
    '빈 트리 비교는 「전부 동일」로 조용히 통과한다')
}

// ── 리포트 표 파싱 ───────────────────────────────────────────────────────────
// | Level | Location | Target | Reason | Code |
const rows = []
for (const line of report.split(/\r?\n/)) {
  if (!line.trim().startsWith('|')) continue
  const cells = line.split('|').map((c) => c.trim())
  if (cells.length < 6) continue
  const [, level, location, target, reason, code] = cells
  if (level === 'Level' || /^[-+]+$/.test(level)) continue
  if (!/^(MAJOR|MINOR|PATCH)$/.test(level)) continue
  rows.push({ level, location, target, reason, code })
}

const majors = rows.filter((r) => r.level === 'MAJOR')
const declaredMajor = /Suggested semantic versioning change: MAJOR/.test(report)

// 판정 줄이 MAJOR 인데 MAJOR 행이 하나도 안 잡혔으면 파서가 어긋난 것이다 —
// 그 상태로 통과시키면 이 스크립트가 곧 게이트를 무력화한다.
if (declaredMajor && majors.length === 0) {
  die('parser-drift', '판정은 MAJOR 인데 MAJOR 행을 하나도 파싱하지 못했다',
    '표 서식이 바뀌었을 수 있다 — 파서를 고치기 전에는 통과시키지 않는다')
}

// ── 소스 조회 헬퍼 (결정적 스캐너 — 정규식으로 구조를 읽지 않는다) ──────────
const fileCache = new Map()
const readSrc = (dir, loc) => {
  // location 은 `<접두>/src/Token/TokenSet.php:87` 꼴이다. 접두는 실행 환경마다 다르므로
  // `src/` 이후만 취해 각 트리에 붙인다.
  const noLine = loc.replace(/:\d+$/, '').replace(/\\/g, '/')
  const idx = noLine.lastIndexOf('/src/')
  const rel = idx >= 0 ? noLine.slice(idx + 1) : `src/${basename(noLine)}`
  const p = join(dir, rel)
  const key = p
  if (fileCache.has(key)) return fileCache.get(key)
  const v = existsSync(p) ? readFileSync(p, 'utf8') : null
  fileCache.set(key, v)
  return v
}

/** `function name(` 의 여는 괄호부터 짝이 맞는 닫는 괄호까지를 돌려준다. 주석·공백은 지운다. */
const methodParams = (src, method) => {
  if (src == null) return null
  const re = new RegExp(`\\bfunction\\s+${method}\\s*\\(`, 'i')
  const m = re.exec(src)
  if (!m) return null
  let i = m.index + m[0].length
  let depth = 1
  const start = i
  while (i < src.length && depth > 0) {
    const c = src[i]
    if (c === '(') depth++
    else if (c === ')') depth--
    i++
  }
  if (depth !== 0) return null
  const raw = src.slice(start, i - 1)
  return raw
    .replace(/\/\*[\s\S]*?\*\//g, '') // 블록 주석
    .replace(/\/\/[^\n]*/g, '') // 줄 주석
    .replace(/#\[[^\]]*\]/g, '') // 어트리뷰트(#[\SensitiveParameter])는 기본값이 아니다
    .replace(/\s+/g, '')
}

const shortOf = (target) => {
  const cls = target.split('::')[0]
  return cls.split('\\').pop()
}

// ── 면제 술어 셋 ─────────────────────────────────────────────────────────────
const exemptions = []
const remaining = []

for (const r of majors) {
  const short = shortOf(r.target)
  const newSrc = readSrc(newDir, r.location)
  const oldSrc = readSrc(baseDir, r.location)

  // (1) V015 — final 클래스에 메서드가 늘었다. 상속이 불가능하므로 충돌할 수 없다 = MINOR.
  if (r.code === 'V015' && /Method has been added/i.test(r.reason)) {
    if (newSrc != null && new RegExp(`\\bfinal\\b[^\\n]*\\bclass\\s+${short}\\b`).test(newSrc)) {
      exemptions.push({ r, why: `final class ${short} — 상속 불가라 메서드 추가가 충돌을 만들 수 없다 (MINOR)` })
      continue
    }
    remaining.push({ r, why: `클래스 ${short} 가 final 이 아니다 — 하위 클래스와 충돌할 수 있다` })
    continue
  }

  // ⚠️ V154(「클래스명 대소문자가 바뀌었다」)도 같은 `implements` 오탐으로 나오지만 **면제하지
  // 않는다** — 도구가 그것을 PATCH 로 내므로 이 게이트(MAJOR 만 본다)에 애초에 닿지 않는다.
  // 닿지 않는 면제를 넣으면 시험되지 않는 코드가 된다. 언젠가 도구가 그것을 MAJOR 로 올리면
  // 여기서 fail-closed 로 막히고 사람이 본다 — 그게 옳은 방향이다.

  // (2) V097 — 파라미터 기본값이 바뀌었다는 주장. 파라미터 목록이 같으면 거짓이다.
  if (r.code === 'V097') {
    const method = r.target.includes('::') ? r.target.split('::')[1] : null
    if (method) {
      const a = methodParams(oldSrc, method)
      const b = methodParams(newSrc, method)
      if (a != null && b != null && a === b) {
        exemptions.push({ r, why: `${method}() 의 파라미터 목록이 바이트 동일하다 — 기본값은 바뀌지 않았다` })
        continue
      }
      remaining.push({ r, why: `${method}() 의 파라미터 목록이 실제로 다르다` })
      continue
    }
  }

  remaining.push({ r, why: '면제 술어에 해당하지 않는다' })
}

// ── 보고 ─────────────────────────────────────────────────────────────────────
console.log(`php API 호환성: base ${baseCount}개 · new ${newCount}개 · 표 ${rows.length}행 · MAJOR ${majors.length}행`)
if (exemptions.length > 0) {
  console.log(`면제 ${exemptions.length}건 — 각각 소스로 반증했다:`)
  for (const e of exemptions) console.log(`  - [${e.r.code}] ${e.r.target}\n      ${e.why}`)
}
if (remaining.length > 0) {
  console.error(`::error::직전 릴리스 대비 파괴적 변경이 ${remaining.length}건 남는다 — 1.0 은 major 없이 허용하지 않는다`)
  for (const x of remaining) {
    console.error(`  - [${x.r.code}] ${x.r.target} (${x.r.location})`)
    console.error(`      도구: ${x.r.reason}`)
    console.error(`      판정: ${x.why}`)
  }
  process.exit(1)
}
console.log('파괴적 변경 없음 — 남은 MAJOR 0건')
