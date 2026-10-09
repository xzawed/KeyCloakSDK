#!/usr/bin/env node
// integration-coverage.mjs — 통합 실행만의 「네트워크 경계」 커버리지 리포트. **보고 모드(하한 없음)** · 파일럿 go · python.
//
// 왜: 아홉 언어가 「경계는 통합으로 검증한다」며 그 파일을 단위 커버리지 게이트에서 빼는데, 통합 실행에서
// 커버리지를 재는 언어가 0 이었다(등록부 `integration-coverage-never-measured`). 이 스크립트가 그 3 걸음째다 —
// 레인 통합 잡에 리포트를 붙인다. 하한(4 걸음째)은 CI 관측 세 번 뒤에 사람이 정한다. **낮은 수치는 실패가 아니다.**
//
// 등록부가 붙인 세 조건:
//  · 리포트할 파일 집합은 단위 omit SSOT 에서 **파생**한다 — 측정 트리의 `scripts/coverage-boundary.mjs list --json`.
//    목록 사본을 측정에 쓰지 않는다.
//  · 그 집합을 **고정**한다 — `scripts/integration-coverage.json` 의 `pinned` 와 다르면 FAIL. 파생이 너무 적게 고르면
//    %가 오른다(등록부 실측: coverlet `<Include>` 를 뒤집자 중첩 async 타입이 빠져 211/312). 핀은 측정 대상이 아니라
//    **오라클**이다 — SSOT 를 바꾸는 PR 이 「리포트의 분모가 바뀐다」를 같은 diff 에서 보이게 한다.
//  · 통합이 한 번도 실행하지 않는 함수 목록 — 항목마다 **열린** 등록부 id 가 소유자다(같은 JSON 의 `owners`).
//
// ⚠️ 「파생 = 핀」만으로는 부족하다 — **도구가 데이터에서 파일을 떨어뜨리는** 길이 따로 있다. 그래서 파생한 파일마다
// 데이터에 실제로 있는지 본다(없으면 FAIL). 실측(2026-10-09, coverage.py 7.15): `[run] include` 만 쓰면 한 번도
// import 안 된 경계 파일이 리포트에서 **조용히 사라져** 75.0% 가 84.0% 가 된다 — 그래서 run 은 `source` 를 디렉터리로
// 준다(안 불린 파일도 0% 로 든다). go 는 빌드 태그로 빠진 파일이 같은 꼴이다.
// ⚠️ coverage.py 의 JSON 은 함수 영역을 **이름으로** 묶는다(`jsonreport.py` 의 `region_data[region.name]`). 같은 이름
// (property getter/setter · 재정의)이면 앞 영역이 덮여 미실행 목록에서 빠진다 — 영역 문장 수의 합이 파일 문장 수와
// 같아야 한다(실측: setter 를 더하자 9 문장 중 8 만 영역에 남았다). 다르면 FAIL.
// ⚠️ python 의 `lines` 는 import 때 도는 모듈·클래스 수준 줄을 덮인 것으로 센다 — 실제 트리에서 경계 395 문장 중
// 160 이 그렇다(실측 2026-10-09, 전부 100%). 그래서 함수 몸통만 센 `bodies` 를 함께 내고, 측정 실패 판정도 몸통으로 한다.
// go 의 문장은 전부 함수(리터럴) 몸통이다.
// ⚠️ go 의 미실행 함수는 소스를 직접 읽어 판정한다 — `go tool cover -func` 은 수신자 타입을 안 내고(같은 파일의
// `String` 둘을 못 가른다) 패키지 수준 함수 리터럴의 문장을 합계에서 뺀다(실측: 픽스처 9/20 vs 9/19).
//
// 종료코드 — 셋을 가른다. 「낮은 수치」는 어디에도 없다:
//   0 OK     리포트가 섰고, 미실행 함수가 전부 열린 항목 소유다
//   1 DRIFT  소유 문제(소유자 없음 · 열린 항목이 아님 · 낡은 항목) — 수치는 유효하다. CI 는 경고로만 본다(보고 모드)
//   2 FAIL   무결성 실패 — 파생 실패·빈 파생·핀과 다름·데이터 없음·데이터에서 경계 파일 빠짐·아무것도 안 돈 실행·
//            함수 영역 회계 불일치·못 읽는 입력. **이때는 수치를 내지 않는다**(인용될 숫자를 만들지 않는다).
//
// 사용:
//   node scripts/integration-coverage.mjs <go|python> [--out DIR]                 로컬 — 통합 테스트(Docker) 후 리포트
//   node scripts/integration-coverage.mjs run    <go|python> [ROOT] [--out DIR]   CI 테스트 스텝 — 종료코드는 테스트의 것
//   node scripts/integration-coverage.mjs report <go|python> [ROOT] [--out DIR]   CI 리포트 스텝(보고 모드)
//   node scripts/integration-coverage.mjs check  [ROOT]                            파생 ↔ 핀 ↔ 소유자(데이터·Docker 불필요)
// python 인터프리터는 `KCSDK_PY` → `python/.venv` → PATH 의 `python` 순이다. DIR 기본값은 OS 임시 디렉터리 아래다.
import { readFileSync, existsSync, writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { join, dirname, resolve, posix } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

const PINS = 'scripts/integration-coverage.json'
const REGISTRY = 'docs/superpowers/plans/remaining-work.md'
const BOUNDARY = 'scripts/coverage-boundary.mjs'
const LANGS = ['go', 'python']

// ── CLI ──────────────────────────────────────────────────────────────────────────────────
function usage(msg) {
  if (msg) console.error(msg)
  console.error('usage: node scripts/integration-coverage.mjs <go|python> [--out DIR]')
  console.error('       node scripts/integration-coverage.mjs run|report <go|python> [ROOT] [--out DIR]')
  console.error('       node scripts/integration-coverage.mjs check [ROOT]')
  process.exit(2)
}
const argv = process.argv.slice(2)
let cmd = argv[0]
let rest = argv.slice(1)
if (cmd !== undefined && !['run', 'report', 'check'].includes(cmd) && !cmd.startsWith('-')) {
  rest = argv
  cmd = 'local'
}
let out = null
const pos = []
for (let i = 0; i < rest.length; i++) {
  const a = rest[i]
  if (a === '--out') {
    out = rest[++i]
    if (!out) usage('--out needs a directory')
  } else if (a.startsWith('--out=')) out = a.slice(6)
  else if (a.startsWith('-')) usage(`unknown option: ${a}`)
  else pos.push(a)
}
let lang = null
let root = null
if (cmd === 'check') {
  if (pos.length > 1) usage(`too many arguments: ${pos.join(' ')}`)
  root = pos[0] ?? null
} else if (['local', 'run', 'report'].includes(cmd)) {
  lang = pos[0]
  if (!LANGS.includes(lang)) usage(`this pilot measures ${LANGS.join(' · ')} — got ${lang ?? 'nothing'}`)
  if (pos.length > (cmd === 'local' ? 1 : 2)) usage(`too many arguments: ${pos.join(' ')}`)
  root = pos[1] ?? null
} else usage(cmd ? `unknown command: ${cmd}` : '')
root = resolve(root ?? join(dirname(fileURLToPath(import.meta.url)), '..'))
const rootPosix = root.replace(/\\/g, '/')
out = resolve(out ?? join(tmpdir(), 'kcsdk-integration-coverage', lang ?? ''))

// ── 판정 기록 ─────────────────────────────────────────────────────────────────────────────
const findings = []
const fail = (l, msg) => void findings.push({ kind: 'FAIL', lang: l, msg })
const drift = (l, msg) => void findings.push({ kind: 'DRIFT', lang: l, msg })
const fails = (l) => findings.some((f) => f.kind === 'FAIL' && (f.lang === l || f.lang === null))
const pct = (c, t) => (t ? `${((100 * c) / t).toFixed(1)}%` : 'n/a')
const sortU = (xs) => [...new Set(xs)].sort()

// ── 파생 — 측정 트리 자신의 coverage-boundary 로 ──────────────────────────────────────────
// ⚠️ 그 도구는 **어느** 언어든 FAIL 이면 exit 2 다. 다른 언어의 파생 실패가 이 언어를 막지 않도록 종료코드가 아니라
// JSON 의 `findings` 를 언어별로 본다. 이 언어의 전개가 없으면(FAIL 이든 아니든) 리포트하지 않는다.
let derivation
function derive() {
  if (derivation !== undefined) return derivation
  derivation = null
  const tool = join(root, BOUNDARY)
  if (!existsSync(tool)) {
    fail(null, `${BOUNDARY} is missing from ${rootPosix} — the boundary cannot be derived`)
    return null
  }
  const r = spawnSync(process.execPath, [tool, 'list', root, '--json'], { encoding: 'utf8', maxBuffer: 64 << 20 })
  let j
  try {
    j = JSON.parse(r.stdout)
  } catch {
    const first = `${r.stderr || ''}${r.stdout || ''}`.trim().split('\n')[0] ?? ''
    fail(null, `${BOUNDARY} list --json did not return JSON (exit ${r.status ?? r.signal}): ${first}`)
    return null
  }
  if (!j || typeof j.langs !== 'object' || j.langs === null || !Array.isArray(j.findings)) {
    fail(null, `${BOUNDARY} list --json returned an unexpected shape (want { langs, findings })`)
    return null
  }
  derivation = j
  return j
}
function derivedFor(l) {
  const j = derive()
  if (!j) return null
  const mine = j.findings.filter((f) => f.lang === l)
  for (const f of mine) fail(l, `coverage-boundary could not derive the boundary — ${f.site}: ${f.msg}`)
  if (mine.length) return null
  const d = j.langs[l]
  if (!d) {
    fail(l, `coverage-boundary returned no derivation for ${l}`)
    return null
  }
  if (!Array.isArray(d.files) || d.files.length === 0) {
    fail(l, 'the derived boundary is empty — a report over no files is vacuous')
    return null
  }
  return d
}

// ── 핀 · 소유자 · 등록부 ──────────────────────────────────────────────────────────────────
let pins
function loadPins() {
  if (pins !== undefined) return pins
  pins = null
  let p
  try {
    p = JSON.parse(readFileSync(join(root, PINS), 'utf8'))
  } catch {
    fail(null, `${PINS} is missing or not JSON`)
    return null
  }
  if (!p || typeof p !== 'object' || Array.isArray(p)) {
    fail(null, `${PINS} must be an object keyed by language`)
    return null
  }
  for (const k of Object.keys(p)) if (!LANGS.includes(k)) fail(null, `${PINS} names ${k}, which this pilot does not measure (${LANGS.join(' · ')})`)
  pins = p
  return p
}
function pinFor(l) {
  const p = loadPins()
  if (!p) return null
  const e = p[l]
  if (!e) {
    fail(l, `${PINS} has no pin for ${l}`)
    return null
  }
  if (!Array.isArray(e.pinned) || !e.pinned.every((x) => typeof x === 'string')) {
    fail(l, `${PINS}: ${l}.pinned must be an array of repository paths`)
    return null
  }
  const owners = e.owners ?? {}
  if (typeof owners !== 'object' || owners === null || Array.isArray(owners) || !Object.values(owners).every((v) => typeof v === 'string')) {
    fail(l, `${PINS}: ${l}.owners must map "<file>:<function>" to a registry id`)
    return null
  }
  return { pinned: e.pinned, owners }
}
// 파생 = 핀. 다르면 어느 쪽에만 있는지 이름으로 댄다.
function matchesPin(l, d, pin) {
  const D = new Set(d.files)
  const P = new Set(pin.pinned)
  const extra = sortU(d.files.filter((f) => !P.has(f)))
  const missing = sortU(pin.pinned.filter((f) => !D.has(f)))
  if (!extra.length && !missing.length) return true
  const parts = []
  if (extra.length) parts.push(`derived, not pinned: ${extra.join(', ')}`)
  if (missing.length) parts.push(`pinned, not derived: ${missing.join(', ')}`)
  fail(l, `the derived boundary differs from the pin in ${PINS} — ${parts.join(' · ')}`)
  return false
}
// 등록부의 항목은 **열 0** 의 체크박스 줄이다(`test-remaining-work-shape.sh` 와 같은 정의). 들여쓴 하위 불릿은 항목이 아니다.
let registry
function loadRegistry() {
  if (registry !== undefined) return registry
  registry = null
  const f = join(root, REGISTRY)
  if (!existsSync(f)) {
    fail(null, `${REGISTRY} is missing — owners cannot be checked against open items`)
    return null
  }
  const open = new Set()
  let items = 0
  for (const l of readFileSync(f, 'utf8').replace(/\r\n/g, '\n').split('\n')) {
    const m = l.match(/^- \[([ x])\] `([a-z0-9][a-z0-9-]*)`/)
    if (!m) continue
    items++
    if (m[1] === ' ') open.add(m[2])
  }
  // 공허 방지 — 표기가 바뀌어 0 건을 읽으면 모든 소유자가 「열린 항목 아님」이 되어 원인이 가려진다.
  if (!items) {
    fail(null, `${REGISTRY} has no items — the item format changed or the file is empty`)
    return null
  }
  registry = { open }
  return registry
}

// ── go: 커버 프로필 + 소스의 함수 범위 ────────────────────────────────────────────────────
// 주석·문자열·룬·원시 문자열을 같은 길이의 공백으로 지운다(줄 번호 보존) — 그 안의 `{`·`}`·`func` 가 구조로 읽히면 안 된다.
function blankGo(src) {
  let res = ''
  for (let i = 0; i < src.length; ) {
    let j
    if (src.startsWith('//', i)) {
      j = src.indexOf('\n', i)
      if (j < 0) j = src.length
    } else if (src.startsWith('/*', i)) {
      j = src.indexOf('*/', i + 2)
      j = j < 0 ? src.length : j + 2
    } else if (src[i] === '`') {
      j = src.indexOf('`', i + 1)
      j = j < 0 ? src.length : j + 1
    } else if (src[i] === '"' || src[i] === "'") {
      const q = src[i]
      j = i + 1
      while (j < src.length && src[j] !== q && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1
      j = Math.min(src.length, j + 1)
    } else {
      res += src[i++]
      continue
    }
    res += src.slice(i, j).replace(/[^\n]/g, ' ')
    i = j
  }
  return res
}
// 최상위 함수 선언의 범위. gofmt 가 보장하는 모양에 기댄다: 최상위 `func` 는 열 0 에서 시작하고, 여러 줄 몸통은
// 열 0 의 `}` 한 글자 줄로 끝난다. 첫 줄에서 중괄호가 짝이 맞으면 한 줄 함수다(지운 뒤에 센다).
function goFuncs(file) {
  const L = blankGo(readFileSync(join(root, file), 'utf8').replace(/\r\n/g, '\n')).split('\n')
  const funcs = []
  for (let k = 0; k < L.length; k++) {
    if (!/^func\b/.test(L[k])) continue
    const m = L[k].match(/^func\s*(?:\(([^)]*)\)\s*)?([A-Za-z_]\w*)/)
    if (!m) {
      fail('go', `${file}:${k + 1}: cannot read the function name`)
      return null
    }
    let name = m[2]
    if (m[1] !== undefined) {
      // 수신자의 마지막 식별자가 타입이다(`a *AdminClient` · `*AdminClient` · `r *Store[K, V]`).
      const r = m[1].trim().match(/([A-Za-z_]\w*)(?:\[[^\]]*\])?$/)
      if (!r) {
        fail('go', `${file}:${k + 1}: cannot read the receiver type of ${name}`)
        return null
      }
      name = `${r[1]}.${name}`
    }
    const opens = (L[k].match(/\{/g) ?? []).length
    const closes = (L[k].match(/\}/g) ?? []).length
    let end = k
    if (!(opens > 0 && opens === closes)) {
      end = L.findIndex((l, x) => x > k && l.replace(/\s+$/, '') === '}')
      if (end < 0) {
        fail('go', `${file}:${k + 1}: cannot find the end of ${name} (gofmt closes a top-level body with "}" at column 0)`)
        return null
      }
    }
    if (funcs.some((f) => f.name === name)) {
      fail('go', `${file}: two functions are both named ${name} — the never-executed list cannot tell them apart`)
      return null
    }
    funcs.push({ name, start: k + 1, end: end + 1, stmts: 0, covered: 0 })
  }
  return funcs
}
function goReport(d) {
  const path = join(out, 'go.cover')
  if (!existsSync(path)) {
    fail('go', `no coverage data at ${path.replace(/\\/g, '/')} — run the integration suite first (node scripts/integration-coverage.mjs run go)`)
    return null
  }
  const modFile = join(root, d.dir, 'go.mod')
  const mod = existsSync(modFile) ? readFileSync(modFile, 'utf8').match(/^module\s+(\S+)/m)?.[1] : null
  if (!mod) {
    fail('go', `${d.dir}/go.mod has no module line — profile paths cannot be mapped to files`)
    return null
  }
  const lines = readFileSync(path, 'utf8').replace(/\r\n/g, '\n').split('\n').filter(Boolean)
  if (!/^mode: (set|count|atomic)$/.test(lines[0] ?? '')) {
    fail('go', `${path.replace(/\\/g, '/')} is not a Go cover profile (first line: ${lines[0] ?? 'empty'})`)
    return null
  }
  // 같은 블록이 여러 번 나올 수 있다(여러 테스트 바이너리의 프로필을 합친 꼴) — 문장은 한 번, 덮임은 어느 쪽이든.
  const blocks = new Map()
  for (const l of lines.slice(1)) {
    const m = l.match(/^(.+):(\d+)\.(\d+),(\d+)\.(\d+) (\d+) (\d+)$/)
    if (!m) {
      fail('go', `cannot read the profile line: ${l}`)
      return null
    }
    if (!m[1].startsWith(`${mod}/`)) continue
    const file = `${d.dir}/${m[1].slice(mod.length + 1)}`
    const key = `${file}:${m[2]}.${m[3]},${m[4]}.${m[5]}`
    const n = Number(m[6])
    const c = Number(m[7])
    const b = blocks.get(key)
    if (!b) blocks.set(key, { file, line: Number(m[2]), n, c })
    else if (b.n !== n) {
      fail('go', `${key} appears with ${b.n} and ${n} statements — the profile contradicts itself`)
      return null
    } else b.c += c
  }
  const files = []
  const never = []
  for (const f of sortU(d.files)) {
    const bs = [...blocks.values()].filter((b) => b.file === f)
    if (!bs.length) {
      fail('go', `${f} is not in the coverage data — a boundary file the run never instrumented would silently leave the denominator`)
      continue
    }
    if (!existsSync(join(root, f))) {
      fail('go', `${f} is in the profile but not in the tree — the data belongs to another checkout`)
      continue
    }
    const funcs = goFuncs(f)
    if (!funcs) continue
    const outside = { stmts: 0, covered: 0 }
    let stmts = 0
    let covered = 0
    for (const b of bs) {
      stmts += b.n
      if (b.c > 0) covered += b.n
      const fn = funcs.find((x) => b.line >= x.start && b.line <= x.end) ?? outside
      fn.stmts += b.n
      if (b.c > 0) fn.covered += b.n
    }
    files.push({ file: f, stmts, covered, outside })
    for (const fn of funcs) if (fn.stmts > 0 && fn.covered === 0) never.push({ file: f, line: fn.start, name: fn.name, stmts: fn.stmts })
  }
  return { path, files, never }
}

// ── python: coverage.py JSON(format 3 — 함수 영역) ────────────────────────────────────────
function toRepoPath(key, dir) {
  const n = key.replace(/\\/g, '/')
  if (/^([A-Za-z]:)?\//.test(n)) {
    const pre = `${rootPosix}/`
    const win = /^[A-Za-z]:/.test(n)
    const hit = win ? n.toLowerCase().startsWith(pre.toLowerCase()) : n.startsWith(pre)
    return hit ? posix.normalize(n.slice(pre.length)) : n
  }
  return posix.normalize(`${dir}/${n}`)
}
function pyReport(d) {
  const path = join(out, 'python.json')
  if (!existsSync(path)) {
    fail('python', `no coverage data at ${path.replace(/\\/g, '/')} — run the integration suite first (node scripts/integration-coverage.mjs run python)`)
    return null
  }
  let j
  try {
    j = JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    fail('python', `${path.replace(/\\/g, '/')} is not JSON`)
    return null
  }
  if (j?.meta?.format !== 3 || typeof j.files !== 'object' || j.files === null) {
    fail('python', `${path.replace(/\\/g, '/')} is not a coverage.py JSON report of format 3 (function regions are required)`)
    return null
  }
  const byPath = new Map()
  for (const [k, v] of Object.entries(j.files)) byPath.set(toRepoPath(k, d.dir), v)
  const files = []
  const never = []
  for (const f of sortU(d.files)) {
    const v = byPath.get(f)
    if (!v) {
      fail('python', `${f} is not in the coverage data — a boundary file the run never instrumented would silently leave the denominator`)
      continue
    }
    if (!v.summary || typeof v.functions !== 'object' || v.functions === null) {
      fail('python', `${f}: the report has no function regions`)
      continue
    }
    const lines = { stmts: v.summary.num_statements, covered: v.summary.covered_lines }
    const bodies = { stmts: 0, covered: 0 }
    let sum = 0
    for (const [q, r] of Object.entries(v.functions)) {
      sum += r.summary.num_statements
      if (q === '') continue
      bodies.stmts += r.summary.num_statements
      bodies.covered += r.summary.covered_lines
      if (r.summary.num_statements > 0 && r.summary.covered_lines === 0) never.push({ file: f, line: r.start_line, name: q, stmts: r.summary.num_statements })
    }
    if (sum !== lines.stmts) {
      fail('python', `${f}: function regions add up to ${sum} of ${lines.stmts} statements — coverage.py keys regions by name, so a same-named function overwrote another and the never-executed list could miss it`)
      continue
    }
    files.push({ file: f, stmts: lines.stmts, covered: lines.covered, bodies })
  }
  return { path, files, never }
}

// ── report ───────────────────────────────────────────────────────────────────────────────
function emitFindings(l) {
  for (const f of findings) if (f.lang === l || f.lang === null) console.log(`${f.kind} [${f.lang ?? '-'}] ${f.msg}`)
}
function report(l) {
  const d = derivedFor(l)
  const pin = pinFor(l)
  const reg = loadRegistry()
  if (d && pin) matchesPin(l, d, pin)
  const data = fails(l) ? null : l === 'go' ? goReport(d) : pyReport(d)
  if (data && !fails(l)) {
    const tot = data.files.reduce((a, f) => ({ stmts: a.stmts + f.stmts, covered: a.covered + f.covered }), { stmts: 0, covered: 0 })
    // 아무 경계 문장도 안 돈 실행은 「낮은 수치」가 아니라 측정 실패다(테스트가 경계를 한 줄도 안 지나고 통과할 수 없다).
    // ⚠️ python 은 **함수 몸통**으로 판정한다 — import 만으로 모듈·클래스 수준 줄이 덮인다. conftest 가 패키지를 import
    // 하므로 통합 테스트가 전부 skip 돼 pytest 가 exit 0 으로 끝나도 lines 는 0 이 아니다(실측: 실제 트리 import 만으로
    // 160/395 = 40.5% · 몸통 0/235). lines 로 판정하면 그 실행이 「40.5%」로 보고된다.
    const ran =
      l === 'python'
        ? data.files.reduce((a, f) => ({ stmts: a.stmts + f.bodies.stmts, covered: a.covered + f.bodies.covered }), { stmts: 0, covered: 0 })
        : tot
    if (ran.covered === 0) {
      const scope = l === 'python' ? 'boundary statements inside functions' : 'boundary statements'
      const why = l === 'python' && tot.covered ? `import alone credits ${tot.covered} module-level lines` : 'did the integration tests run against this tree?'
      fail(l, `the run executed 0 of ${ran.stmts} ${scope} — a measurement failure, not a low number (${why})`)
    } else {
      const neverKeys = new Set()
      for (const x of data.never) {
        const key = `${x.file}:${x.name}`
        neverKeys.add(key)
        x.owner = pin.owners[key] ?? 'NONE'
        if (!pin.owners[key]) drift(l, `unowned never-executed function ${key} — name an open item of ${REGISTRY} for it in ${PINS}`)
        else if (reg && !reg.open.has(x.owner)) drift(l, `${key} is owned by ${x.owner}, which is not an open item of ${REGISTRY}`)
      }
      for (const key of Object.keys(pin.owners)) if (!neverKeys.has(key)) drift(l, `stale owner ${key} — the integration run executes it now (or it no longer exists); drop the entry`)
      printReport(l, d, data, tot)
    }
  }
  emitFindings(l)
  const nf = findings.filter((f) => f.kind === 'FAIL' && (f.lang === l || f.lang === null)).length
  const nd = findings.filter((f) => f.kind === 'DRIFT' && f.lang === l).length
  if (nf) {
    console.log(`integration-coverage [${l}]: FAIL — ${nf} integrity failure${nf > 1 ? 's' : ''}; no numbers are reported from a run that failed one`)
    return 2
  }
  const t = data.files.reduce((a, f) => ({ stmts: a.stmts + f.stmts, covered: a.covered + f.covered }), { stmts: 0, covered: 0 })
  let head = `${t.covered}/${t.stmts} statements (${pct(t.covered, t.stmts)})`
  if (l === 'python') {
    const b = data.files.reduce((a, f) => ({ stmts: a.stmts + f.bodies.stmts, covered: a.covered + f.bodies.covered }), { stmts: 0, covered: 0 })
    head = `lines ${t.covered}/${t.stmts} (${pct(t.covered, t.stmts)}) · bodies ${b.covered}/${b.stmts} (${pct(b.covered, b.stmts)})`
  }
  const n = data.never.length
  const fns = n ? `${n} never-executed function${n > 1 ? 's' : ''}` : 'no never-executed functions'
  if (nd) {
    console.log(`integration-coverage [${l}]: DRIFT — ${head} · ${fns} · ${nd} ownership problem${nd > 1 ? 's' : ''} (report mode — not a gate)`)
    return 1
  }
  console.log(`integration-coverage [${l}]: OK — ${head} · ${fns}${n ? ', all owned by open registry items' : ''}`)
  return 0
}
function printReport(l, d, data, tot) {
  const stmt = (k) => `${k} stmt${k > 1 ? 's' : ''}`
  console.log(`[${l}] integration-only coverage — report mode, no floor`)
  console.log(`  boundary: ${d.files.length} files derived from ${d.site} (${d.label}) — equal to the pin in ${PINS}`)
  console.log(`  data: ${data.path.replace(/\\/g, '/')}`)
  if (l === 'go') {
    for (const f of data.files) {
      const pkg = f.outside.stmts ? ` (package-level ${f.outside.covered}/${f.outside.stmts})` : ''
      console.log(`  ${f.file} ${f.covered}/${f.stmts} ${pct(f.covered, f.stmts)}${pkg}`)
    }
    console.log(`  total ${tot.covered}/${tot.stmts} ${pct(tot.covered, tot.stmts)}`)
  } else {
    const b = { stmts: 0, covered: 0 }
    for (const f of data.files) {
      b.stmts += f.bodies.stmts
      b.covered += f.bodies.covered
      console.log(`  ${f.file} lines ${f.covered}/${f.stmts} ${pct(f.covered, f.stmts)} · bodies ${f.bodies.covered}/${f.bodies.stmts} ${pct(f.bodies.covered, f.bodies.stmts)}`)
    }
    console.log(`  total lines ${tot.covered}/${tot.stmts} ${pct(tot.covered, tot.stmts)} · bodies ${b.covered}/${b.stmts} ${pct(b.covered, b.stmts)}`)
    console.log('  (bodies = statements inside functions; module- and class-level lines run at import, so "lines" also credits what the run merely imported)')
  }
  // 표와 같은 순서(코드 단위) — localeCompare 는 `admin_users.go` 를 `admin.go` 앞에 둔다.
  const never = [...data.never].sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line))
  console.log(`  never executed by the integration run — ${never.length} function${never.length === 1 ? '' : 's'} (none of its statements ran):`)
  for (const x of never) console.log(`  NEVER ${x.file}:${x.line} ${x.name} · ${stmt(x.stmts)} · owner ${x.owner}`)
}

// ── check — 데이터 없이: 파생 ↔ 핀 ↔ 소유자 ───────────────────────────────────────────────
function check() {
  const reg = loadRegistry()
  const p = loadPins()
  const counts = []
  let owners = 0
  for (const l of LANGS) {
    const d = derivedFor(l)
    const pin = p ? pinFor(l) : null
    if (d && pin && matchesPin(l, d, pin)) console.log(`[${l}] pin OK — ${d.files.length} files equal the derivation from ${d.site} (${d.label})`)
    if (!pin) continue
    counts.push(`${l} ${pin.pinned.length}`)
    const P = new Set(pin.pinned)
    for (const [key, id] of Object.entries(pin.owners)) {
      owners++
      const at = key.indexOf(':')
      if (at < 0 || !P.has(key.slice(0, at))) drift(l, `owner entry ${key} names a file outside the pin`)
      if (reg && !reg.open.has(id)) drift(l, `${key} is owned by ${id}, which is not an open item of ${REGISTRY}`)
    }
    console.log(`[${l}] owners: ${Object.keys(pin.owners).length} entries (${sortU(Object.values(pin.owners)).join(' · ') || 'none'})`)
  }
  for (const f of findings) console.log(`${f.kind} [${f.lang ?? '-'}] ${f.msg}`)
  const nf = findings.filter((f) => f.kind === 'FAIL').length
  const nd = findings.length - nf
  if (nf || nd) {
    console.log(`integration-coverage check: ${nf ? 'FAIL' : 'DRIFT'} — ${nf} fail · ${nd} drift`)
    return nf ? 2 : 1
  }
  console.log(`integration-coverage check: OK — ${counts.join(' · ')} files pinned · ${owners} owner entries, all open`)
  return 0
}

// ── run — 통합 테스트를 커버리지와 함께(종료코드는 테스트의 것) ────────────────────────────
function spawnStep(file, args, cwd, env = process.env) {
  console.log(`$ ${[file, ...args].join(' ')}   (in ${cwd.replace(/\\/g, '/')})`)
  const r = spawnSync(file, args, { cwd, env, stdio: 'inherit' })
  if (r.error) {
    console.log(`FAIL [${lang}] could not start ${file}: ${r.error.message}`)
    return 2
  }
  if (r.signal) {
    console.log(`FAIL [${lang}] ${file} was killed by ${r.signal}`)
    return 2
  }
  return r.status
}
// 파생 파일들의 공통 디렉터리(언어 디렉터리 기준). coverage.py `source` 를 **디렉터리로** 주면 한 번도 import 안 된
// 파일도 0% 로 보고된다 — 이름(`include`)으로 주면 사라진다(위 머리 주석의 실측).
function commonDir(files) {
  const parts = files.map((f) => f.split('/').slice(0, -1))
  const out = []
  for (let i = 0; parts.every((p) => i < p.length && p[i] === parts[0][i]); i++) out.push(parts[0][i])
  return out.join('/')
}
function run(l) {
  const d = derivedFor(l)
  if (!d) {
    emitFindings(l)
    return 2
  }
  mkdirSync(out, { recursive: true })
  const cwd = join(root, d.dir)
  if (l === 'go') {
    const prof = join(out, 'go.cover')
    rmSync(prof, { force: true })
    return spawnStep('go', ['test', '-tags=integration', '-run', 'TestE2E', '-count=1', `-coverprofile=${prof}`, './...'], cwd)
  }
  const common = commonDir(d.files)
  if (!common.startsWith(`${d.dir}/`)) {
    fail(l, `the derived files share no directory under ${d.dir}/ — cannot choose a coverage source`)
    emitFindings(l)
    return 2
  }
  // import 루트 = 공통 디렉터리에서 위로 올라가 처음 만나는 「__init__.py 없는」 디렉터리. 측정할 것이 이 트리이고
  // 설치된 다른 사본이 아니도록 PYTHONPATH 맨 앞에 둔다(다른 워크트리의 editable 설치가 이기지 못하게).
  let imp = common
  while (imp.includes('/') && existsSync(join(root, imp, '__init__.py'))) imp = imp.slice(0, imp.lastIndexOf('/'))
  const rel = (p) => p.slice(d.dir.length + 1)
  // `KCSDK_PY` 의 관례는 python/ 기준 상대 경로다(.claude/rules/python.md) — 경로면 거기서 풀고, 명령 이름이면 PATH 에 맡긴다.
  const envPy = process.env.KCSDK_PY
  const py = envPy
    ? /[\\/]/.test(envPy)
      ? resolve(cwd, envPy)
      : envPy
    : ['.venv/Scripts/python.exe', '.venv/bin/python'].map((p) => join(cwd, p)).find((p) => existsSync(p)) || 'python'
  const rc = join(out, 'python.coveragerc')
  const json = join(out, 'python.json')
  for (const f of [json, join(out, 'python.coverage')]) rmSync(f, { force: true })
  writeFileSync(rc, `[run]\nsource = ${rel(common)}\ndata_file = ${join(out, 'python.coverage')}\n`)
  const sep = process.platform === 'win32' ? ';' : ':'
  // 절대 경로 — 상대 항목은 cwd 가 다른 하위 프로세스에서 다른 곳을 가리킨다.
  const env = { ...process.env, PYTHONPATH: [join(root, imp), process.env.PYTHONPATH].filter(Boolean).join(sep) }
  const t = spawnStep(py, ['-m', 'coverage', 'run', `--rcfile=${rc}`, '-m', 'pytest', '-m', 'integration'], cwd, env)
  if (t !== 0) return t
  const j = spawnStep(py, ['-m', 'coverage', 'json', `--rcfile=${rc}`, '-o', json], cwd, env)
  return j === 0 ? 0 : 2
}

let code
if (cmd === 'check') code = check()
else if (cmd === 'report') code = report(lang)
else if (cmd === 'run') code = run(lang)
else {
  code = run(lang)
  if (code === 0) code = report(lang)
}
process.exit(code)
