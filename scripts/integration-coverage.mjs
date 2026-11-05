#!/usr/bin/env node
// integration-coverage.mjs — 통합 실행만의 「네트워크 경계」 커버리지 리포트. go · python 은 **하한 무장(2026-11-02)**,
// node · rust 는 보고 모드(3 걸음째 — 하한은 CI 관측 셋 뒤).
//
// 왜: 아홉 언어가 「경계는 통합으로 검증한다」며 그 파일을 단위 커버리지 게이트에서 빼는데, 통합 실행에서
// 커버리지를 재는 언어가 0 이었다(등록부 `integration-coverage-never-measured`). 이 스크립트가 그 3 걸음째다 —
// 레인 통합 잡에 리포트를 붙인다. 하한(4 걸음째)은 `integration-coverage.json` 의 `floor` 다(값은 거기에만 둔다) — CI 관측
// 셋 뒤 무장했다. 지표는 go 문장 · python 함수 몸통(lines 는 import 때 도는 줄로 부푼다 — 아래). 값은 관측값을 소수 한
// 자리로 내린 것이라 여유가 없다 — 여유는 다음 변경이 무심사로 채운다(문서 예산 검사 8e 와 같은 이유). 내리려면 그
// JSON 의 diff 가 판정이다. 하한이 없는 언어는 보고 모드 그대로다(**낮은 수치는 실패가 아니다**).
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
// ⚠️ node 도 이름을 소스에서 읽는다 — vitest(v8)의 istanbul `fnMap` 이름은 클래스를 안 붙이고(두 클래스의 `constructor`
// 가 `constructor`·`constructor_2`), 익명·private 메서드를 **순번** `(anonymous_N)` 으로 낸다(실측 2026-11-05: `#masked` 가
// `(anonymous_1)`) — 위에 함수 하나가 늘면 소유자 키가 바뀐다. 그래서 prettier 가 보장하는 모양(최상위 선언은 열 0,
// 클래스 멤버는 열 2, 여러 줄 몸통은 같은 들여쓰기의 `}` 줄로 닫힌다)으로 이름 범위를 잡고 문장을 그 범위에 붙인다 —
// 콜백 같은 중첩 함수는 감싼 멤버에 접힌다(go 의 함수 리터럴과 같다). `typescript` 컴파일러에 기대지 않는다 — 자가테스트
// (doc-facts)에는 node_modules 가 없다.
// ⚠️ rust 의 수치는 `cargo llvm-cov --lcov` 의 `DA`(줄마다 llvm-cov 자신이 낸 판정)다. 같은 기록의 `LF`·`LH` 와 텍스트
// 요약의 Lines 는 쓰지 않는다 — 함수 레코드마다 줄을 더해(async fn 은 바깥 함수와 몸통 둘이다) 고유 줄보다 크다(실측
// 2026-11-05 실제 트리: admin.rs LF 279 · 고유 DA 246). 이름은 소스(rustfmt 모양)에서 읽고 도구의 함수 레코드(`FN`)와
// **양쪽으로** 대조한다. 레코드가 어느 이름 범위에도 없으면 파서가 항목을 놓친 것이다(FAIL — 그 함수의 줄이 모듈 수준에
// 섞이면 미실행 목록에서 조용히 빠진다). 이름 범위에 레코드가 없으면 그 함수는 이 실행의 데이터에 **없다** — 크레이트 밖에
// 안 보이고 아무도 참조 안 한 fn · 인스턴스화 안 된 제네릭 · 한 번도 poll 안 된 async 몸통은 줄째 빠진다(분모에서도 — 실측:
// 픽스처의 `unused_helper` · 제네릭 `From::from`. `pub` fn 은 모듈이 링크되면 0 회 레코드가 남는다). 그래서 미실행 목록에
// `no record` 로 든다. 참조 안 된 모듈은 파일째 빠진다(→ 「데이터에 없음」 FAIL — 그 모듈의 오브젝트가 링크되지 않는다). 부른
// async fn 의 몸통 레코드가 한 번도 안 돌았으면(퓨처를 만들고 버렸다) 그것도 미실행이다 — 줄이 아니라 FNDA 로 잰다(rustReport).
// `test` 없이는 컴파일되지 않는 항목(`#[cfg(test)]` · 접힌 `#[cfg(all(test, …))]` 도)은 통합 빌드에 없으므로 읽지 않는다 — 그
// 안에 레코드가 있으면 단위 테스트가 같은 빌드에서 돈 것이라(통합 전용이 아니다) FAIL 이다. 레코드 없이 줄만 있는 범위
// (`--skip-functions` 로 낸 데이터) · 매크로가 만든 함수(레코드가 `macro_rules!` 몸통을 가리킨다 — 줄을 나눠 써 안 돈 것을
// 못 가른다)도 FAIL 이다. ⚠️ cfg 쌍둥이 중 「no record」 쪽은 플랫폼마다 다르다 — 소유자는 CI(리눅스) 실행을 기준으로 단다.
//
// 종료코드 — 넷을 가른다. 「낮은 수치」는 하한이 무장된 언어에서만 실패다(3):
//   0 OK     리포트가 섰고, 하한 이상이며, 미실행 함수가 전부 열린 항목 소유다
//   1 DRIFT  소유 문제(소유자 없음 · 열린 항목이 아님 · 낡은 항목) — 수치는 유효하다. CI 는 경고로만 본다
//   2 FAIL   무결성 실패 — 파생 실패·빈 파생·핀과 다름·데이터 없음·데이터에서 경계 파일 빠짐·아무것도 안 돈 실행·
//            함수 영역 회계 불일치·못 읽는 입력·잘못 적은 하한. **이때는 수치를 내지 않는다**(인용될 숫자를 만들지 않는다).
//   3 BELOW  하한 아래 — 수치는 유효하다. CI 는 실패로 본다. 비교는 정수식(covered × 100 < percent × 분모)이고 같으면 통과다.
//
// 사용(LANG = go · python · node · rust):
//   node scripts/integration-coverage.mjs <LANG> [--out DIR]                 로컬 — 통합 테스트(Docker) 후 리포트
//   node scripts/integration-coverage.mjs run    <LANG> [ROOT] [--out DIR]   CI 테스트 스텝 — 종료코드는 테스트의 것
//   node scripts/integration-coverage.mjs report <LANG> [ROOT] [--out DIR]   CI 리포트 스텝(하한이 있으면 게이트)
//   node scripts/integration-coverage.mjs check  [ROOT]                      파생 ↔ 핀 ↔ 소유자(데이터·Docker 불필요)
// python 인터프리터는 `KCSDK_PY` → `python/.venv` → PATH 의 `python` 순이다. node 는 `node/node_modules` 의 vitest 를
// 이 node 로 직접 띄운다(npm 을 거치지 않는다 — 윈도의 `npm.cmd` 는 셸 없이 못 띄운다). rust 는 PATH 의 `cargo` 에
// `cargo-llvm-cov`(+ `llvm-tools-preview`)가 있어야 한다. DIR 기본값은 OS 임시 디렉터리 아래다.
import { readFileSync, existsSync, writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { join, dirname, resolve, posix } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

const PINS = 'scripts/integration-coverage.json'
const REGISTRY = 'docs/superpowers/plans/remaining-work.md'
const BOUNDARY = 'scripts/coverage-boundary.mjs'
const LANGS = ['go', 'python', 'node', 'rust']
// 하한 지표 — go 의 문장은 전부 함수 몸통이고, python 은 lines(import 때 도는 줄 포함)와 bodies(함수 안 문장)가 갈린다.
// node 는 istanbul 문장이다(모듈 수준 문장은 import 때 돌지만 경계 파일은 거의 전부 클래스 멤버다 — 표가 따로 보인다).
// rust 는 llvm-cov 의 고유 줄(DA)이다 — import 때 도는 코드가 없다.
const FLOOR_METRICS = { go: ['statements'], python: ['lines', 'bodies'], node: ['statements'], rust: ['lines'] }

// ── CLI ──────────────────────────────────────────────────────────────────────────────────
function usage(msg) {
  if (msg) console.error(msg)
  console.error('usage: node scripts/integration-coverage.mjs <go|python|node|rust> [--out DIR]')
  console.error('       node scripts/integration-coverage.mjs run|report <go|python|node|rust> [ROOT] [--out DIR]')
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
  // 하한 — 없으면 보고 모드. 잘못 적은 하한을 무시하면 하한이 꺼진 줄 모르므로 무결성 실패다.
  let floor = null
  if (e.floor !== undefined) {
    const f = e.floor
    if (typeof f !== 'object' || f === null || Array.isArray(f) || !FLOOR_METRICS[l].includes(f.metric)) {
      fail(l, `${PINS}: ${l}.floor.metric must be one of ${FLOOR_METRICS[l].join(' · ')}`)
      return null
    }
    if (typeof f.percent !== 'number' || !(f.percent > 0 && f.percent <= 100)) {
      fail(l, `${PINS}: ${l}.floor.percent must be a number in (0, 100]`)
      return null
    }
    floor = { metric: f.metric, percent: f.percent }
  }
  return { pinned: e.pinned, owners, floor }
}
const floorText = (pin) => (pin?.floor ? `floor ${pin.floor.metric} ≥ ${pin.floor.percent}%` : null)
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

// ── node: vitest(v8) 의 istanbul JSON + 소스의 이름 범위 ──────────────────────────────────
// 주석·문자열·템플릿 리터럴의 글자를 공백으로 지운다(줄 번호 보존). 템플릿의 `${…}` 안은 코드다 — 그 안의 문자열·템플릿도
// 같은 규칙으로 지운다(중첩은 `${` 마다 중괄호 깊이를 하나 쌓는다). 정규식 리터럴은 가리지 않는다 — 그 안의 백틱은 템플릿을
// 열어 파일 끝까지 지운다. 그래서 파일이 열린 템플릿·`${…}` 안에서 끝나면 nodeFuncs 가 FAIL 한다(실측: 정규식 `` /`/ `` 하나로
// 세 함수가 지워진 채 「OK · 미실행 0」이었다 — #953 독립 레그). 따옴표는 줄 끝에서 닫혀 한 줄만 어긋난다.
function blankTs(src) {
  let res = ''
  const subs = [] // 열린 `${…}` 마다 그 안의 중괄호 깊이
  let inTemplate = false
  for (let i = 0; i < src.length; ) {
    const c = src[i]
    if (inTemplate) {
      if (c === '\\') {
        res += src.slice(i, i + 2).replace(/[^\n]/g, ' ')
        i += 2
      } else if (c === '`') {
        res += ' '
        i++
        inTemplate = false
      } else if (src.startsWith('${', i)) {
        res += '  '
        i += 2
        subs.push(0)
        inTemplate = false
      } else {
        res += c === '\n' ? '\n' : ' '
        i++
      }
      continue
    }
    let j
    if (src.startsWith('//', i)) {
      j = src.indexOf('\n', i)
      if (j < 0) j = src.length
    } else if (src.startsWith('/*', i)) {
      j = src.indexOf('*/', i + 2)
      j = j < 0 ? src.length : j + 2
    } else if (c === '"' || c === "'") {
      j = i + 1
      while (j < src.length && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1
      j = Math.min(src.length, j + 1)
    } else if (c === '`') {
      res += ' '
      i++
      inTemplate = true
      continue
    } else {
      if (subs.length && c === '{') subs[subs.length - 1]++
      else if (subs.length && c === '}') {
        if (subs[subs.length - 1] === 0) {
          subs.pop()
          res += ' '
          i++
          inTemplate = true
          continue
        }
        subs[subs.length - 1]--
      }
      res += src[i++]
      continue
    }
    res += src.slice(i, j).replace(/[^\n]/g, ' ')
    i = j
  }
  return { text: res, open: inTemplate || subs.length > 0 }
}
// 이름 범위 — 열 0 의 함수 선언 · 함수를 받는 const/let · 클래스의 열 2 멤버(메서드 · 생성자 · 접근자 · 화살표 함수
// 속성). interface·type·객체 리터럴의 멤버는 함수가 아니라 세지 않는다. 최상위 범위는 머리 줄부터 다음 최상위 머리 줄
// 직전까지다(열 0 의 `}`·`)`·`]` 는 머리가 아니다 — 닫는 줄은 앞 범위의 것). 멤버 범위는 머리 줄부터, 한 줄이면 그 줄, 아니면
// 열 2 에서 `}` 로 시작하는 첫 줄까지다(`}` · `})` · `};`). 그 줄이 다음 멤버 전에 없으면 몸통 없는 선언(오버로드 · abstract ·
// 함수 타입 속성)이라 범위가 아니다 — 중괄호 없는 한 줄 화살표만 그 줄이 범위다. 멤버 이름은 `클래스.멤버`(접근자는
// `클래스.get x` — 짝인 setter 와 갈린다).
const TS_MODS = '(?:(?:public|private|protected|static|readonly|override|abstract|declare|async)\\s+)*'
const TS_TOP_FN = /^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\*?\s*([A-Za-z_$][\w$]*)/
const TS_TOP_CLASS = /^(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/
const TS_TOP_CONST = /^(?:export\s+)?(?:const|let)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]*)?=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::[^=]*)?=>|\(\s*$|[A-Za-z_$][\w$]*\s*=>)/
// 그룹: 1 수식어(static 이면 이름에 붙인다 — `static from()` 과 `from()` 이 갈린다) · 2 get/set · 3 이름. 제네릭은 `>`·`=>` 를
// 품을 수 있어(`<T extends Record<string, unknown>>` · `<T extends (a: string) => void>`) 탐욕 `<.*>` 로 받고 `(` 까지 되돌아간다.
// `d` — 계산된 이름(`[Symbol.for('x')]`)은 지우기 전 원문의 같은 자리에서 읽는다(지운 글자로는 이름이 불안정하다).
const TS_MEMBER = new RegExp(`^ {2}(${TS_MODS})(?:(get|set)\\s+)?(?:\\*\\s*)?(#?[A-Za-z_$][\\w$]*|\\[[^\\]]+\\])\\s*(?:<.*>)?\\s*\\(`, 'd')
// 화살표·함수식을 받는 속성만 — 값이 식별자뿐인 필드(`#closed = false`)는 함수가 아니다(그 분기가 가짜 범위를 만들었다).
const TS_PROP_FN = new RegExp(`^ {2}(${TS_MODS})(#?[A-Za-z_$][\\w$]*)\\s*(?:[?!]?\\s*:[^=]*)?=\\s*(?:async\\s+)?(?:function\\b|\\([^)]*\\)\\s*(?::[^=]*)?=>|\\(\\s*$|<.*>\\s*\\(|[A-Za-z_$][\\w$]*\\s*=>)`)
function nodeFuncs(file) {
  const raw = readFileSync(join(root, file), 'utf8').replace(/\r\n/g, '\n')
  const blanked = blankTs(raw)
  if (blanked.open) {
    fail('node', `${file}: a template literal or \${…} runs to the end of the file — the name ranges cannot be read (a regex literal with a backtick?)`)
    return null
  }
  const L = blanked.text.split('\n')
  const R = raw.split('\n')
  const count = (k, ch) => L[k].split(ch).length - 1
  const oneLine = (k) => count(k, '{') > 0 && count(k, '{') === count(k, '}')
  // 중괄호 없이 그 줄에서 끝나는 화살표(`x = (a) => a + 1`) — 줄 끝이 여는 글자나 `=>` 가 아니다.
  const exprArrow = (k) => /=>/.test(L[k]) && count(k, '{') === 0 && !/(?:[{([]|=>)\s*$/.test(L[k])
  const isTopHead = (x) => /^[^\s})\]]/.test(L[x])
  const nextTop = (k) => {
    for (let x = k + 1; x < L.length; x++) if (isTopHead(x)) return x
    return L.length
  }
  const lastFilled = (from, before) => {
    let e = before - 1
    while (e > from && !L[e].trim()) e--
    return e
  }
  // 멤버의 닫는 줄 — 열 2 의 `}`, 또는 여러 줄 시그니처를 닫으며 그 줄에서 몸통도 닫는 `) {}` · `): void {}`(실측: 실제
  // auth.ts 의 매개변수 속성 생성자가 `  ) {}` 로 닫혀 「몸통 없는 선언」으로 빠졌고 그 문장이 모듈 수준에 섞였다 — #953 독립 레그).
  const memberClose = (x, limit) => {
    for (let y = x + 1; y < limit; y++) if (/^ {2}\}/.test(L[y]) || (/^ {2}\)/.test(L[y]) && oneLine(y))) return y
    return -1
  }
  const funcs = []
  // kind: 'decl'(함수 선언 · 메서드 · 생성자 · 접근자) 또는 'value'(함수를 값으로 받는 const · 속성 — 머리 줄의 대입 문장은
  // 함수가 아니다, nodeReport).
  const add = (name, start, end, kind) => {
    if (funcs.some((f) => f.name === name)) {
      fail('node', `${file}: two functions are both named ${name} — the never-executed list cannot tell them apart`)
      return false
    }
    funcs.push({ name, start: start + 1, end: end + 1, kind, stmts: 0, covered: 0 })
    return true
  }
  for (let k = 0; k < L.length; k++) {
    if (!isTopHead(k)) continue
    const top = nextTop(k)
    const cls = L[k].match(TS_TOP_CLASS)
    if (cls) {
      const heads = []
      const isStatic = (mods) => /(?:^|\s)static\s/.test(` ${mods}`)
      for (let x = k + 1; x < top; x++) {
        const m = TS_MEMBER.exec(L[x])
        const p = m ? null : L[x].match(TS_PROP_FN)
        if (m) {
          const [s, e] = m.indices[3]
          const name = m[3].startsWith('[') ? R[x].slice(s, e) : m[3]
          heads.push({ x, name: `${isStatic(m[1]) ? 'static ' : ''}${m[2] ? `${m[2]} ` : ''}${name}`, kind: 'decl' })
        } else if (p) heads.push({ x, name: `${isStatic(p[1]) ? 'static ' : ''}${p[2]}`, kind: 'value' })
      }
      for (let h = 0; h < heads.length; h++) {
        const { x, name, kind } = heads[h]
        const limit = h + 1 < heads.length ? heads[h + 1].x : top
        const end = oneLine(x) || exprArrow(x) ? x : memberClose(x, limit)
        if (end < 0) continue // 몸통 없는 선언(오버로드 · abstract · 함수 타입 속성)
        if (!add(`${cls[1]}.${name}`, x, end, kind)) return null
      }
    } else {
      const fn = L[k].match(TS_TOP_FN)
      const val = fn ? null : L[k].match(TS_TOP_CONST)
      if ((fn || val) && !add((fn ?? val)[1], k, lastFilled(k, top), fn ? 'decl' : 'value')) return null
    }
    k = top - 1
  }
  return funcs
}
function nodeReport(d) {
  const path = join(out, 'node', 'coverage-final.json')
  if (!existsSync(path)) {
    fail('node', `no coverage data at ${path.replace(/\\/g, '/')} — run the integration suite first (node scripts/integration-coverage.mjs run node)`)
    return null
  }
  let j
  try {
    j = JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    fail('node', `${path.replace(/\\/g, '/')} is not JSON`)
    return null
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) {
    fail('node', `${path.replace(/\\/g, '/')} is not an istanbul coverage map (an object keyed by file)`)
    return null
  }
  const byPath = new Map()
  for (const [k, v] of Object.entries(j)) byPath.set(toRepoPath(k, d.dir), v)
  const files = []
  const never = []
  for (const f of sortU(d.files)) {
    const v = byPath.get(f)
    if (!v) {
      fail('node', `${f} is not in the coverage data — a boundary file the run never instrumented would silently leave the denominator`)
      continue
    }
    if (typeof v.statementMap !== 'object' || v.statementMap === null || typeof v.s !== 'object' || v.s === null) {
      fail('node', `${f}: the entry has no statementMap and s — not an istanbul file coverage`)
      continue
    }
    if (!existsSync(join(root, f))) {
      fail('node', `${f} is in the data but not in the tree — the data belongs to another checkout`)
      continue
    }
    const funcs = nodeFuncs(f)
    if (!funcs) continue
    // 'value' 범위(`const f = (…) => …` · 속성 `f = (…) => …`)의 머리 줄에는 대입 문장이 따로 있다 — 그것은 import 나 생성 때
    // 돌므로 함수의 것이 아니다(실측: `inc` 의 선언 41:13 은 1, 본문 41:42 는 0 — 줄로만 붙이면 한 번도 안 불린 `inc` 가
    // 미실행 목록에서 빠졌다). 그래서 그 줄에서 fnMap 이 잡은 함수 본문(`loc.start`)보다 앞에서 시작하는 문장은 바깥이다.
    // 'decl'(메서드 · 생성자)은 줄로 붙인다 — 생성자의 매개변수 속성(`constructor(readonly name)`)은 몸통 앞이지만 그 생성자의 것이다.
    const bodyAt = new Map()
    for (const fn of Object.values(v.fnMap ?? {})) {
      const decl = fn?.decl?.start?.line
      const at = fn?.loc?.start
      if (typeof decl === 'number' && typeof at?.line === 'number' && !bodyAt.has(decl)) bodyAt.set(decl, at)
    }
    const outside = { stmts: 0, covered: 0 }
    let stmts = 0
    let covered = 0
    for (const [id, loc] of Object.entries(v.statementMap)) {
      const line = loc?.start?.line
      const col = loc?.start?.column
      const c = v.s[id]
      if (typeof line !== 'number' || typeof col !== 'number' || typeof c !== 'number') {
        fail('node', `${f}: statement ${id} has no start position or count`)
        return null
      }
      stmts++
      if (c > 0) covered++
      let fn = funcs.find((x) => line >= x.start && line <= x.end) ?? outside
      if (fn !== outside && fn.kind === 'value' && line === fn.start) {
        const body = bodyAt.get(fn.start)
        if (body && (line < body.line || col < body.column)) fn = outside
      }
      fn.stmts++
      if (c > 0) fn.covered++
    }
    files.push({ file: f, stmts, covered, outside })
    for (const fn of funcs) if (fn.stmts > 0 && fn.covered === 0) never.push({ file: f, line: fn.start, name: fn.name, stmts: fn.stmts })
  }
  return { path, files, never }
}

// ── rust: cargo llvm-cov 의 lcov + 소스의 이름 범위 ───────────────────────────────────────────
// 주석·문자열·문자 리터럴의 글자를 공백으로 지운다(줄 번호 보존). 블록 주석은 중첩되고(`/* /* */ */`), 문자열은 줄을 넘고,
// 원시 문자열(`r#"…"#` · `br"…"`)은 같은 수의 `#` 로만 닫힌다(이스케이프 없음). `'` 는 문자 리터럴(`'"'` · `'\''` ·
// `'\u{7f}'`)과 수명·라벨(`'a` · `'static` · `'outer:`)이 나눠 쓴다 — 닫는 `'` 가 한 글자 뒤에 있을 때만 리터럴이다(`'"'`
// 를 수명으로 읽으면 그 `"` 가 문자열을 열어 다음 `"` 까지 코드를 지운다). 파일이 열린 문자열·주석 안에서 끝나면 FAIL 이다.
// `kept` 는 같은 길이의 둘째 사본 — 주석만 지우고 리터럴은 남긴다(cfg 이름 꼬리의 `feature = "x"` 를 원문대로 쓰되, 줄 끝
// 주석이 소유자 키에 들어가지 않게 한다 — 독립 레그 실측).
function blankRust(src) {
  let res = ''
  let kept = ''
  let open = false
  const n = src.length
  for (let i = 0; i < n; ) {
    const c = src[i]
    let j = -1
    let comment = false
    if (c === '/' && src[i + 1] === '/') {
      comment = true
      j = src.indexOf('\n', i)
      if (j < 0) j = n
    } else if (c === '/' && src[i + 1] === '*') {
      comment = true
      let depth = 1
      j = i + 2
      while (j < n && depth > 0) {
        if (src[j] === '/' && src[j + 1] === '*') {
          depth++
          j += 2
        } else if (src[j] === '*' && src[j + 1] === '/') {
          depth--
          j += 2
        } else j++
      }
      if (depth > 0) open = true
    } else if ((c === 'r' || c === 'b' || c === 'c') && !/\w/.test(src[i - 1] ?? '')) {
      const m = /^[bc]?r(#*)"/.exec(src.slice(i, i + 300))
      if (m) {
        const close = `"${m[1]}`
        const k = src.indexOf(close, i + m[0].length)
        if (k < 0) {
          open = true
          j = n
        } else j = k + close.length
      }
    } else if (c === '"') {
      j = i + 1
      while (j < n && src[j] !== '"') j += src[j] === '\\' ? 2 : 1
      if (j >= n) open = true
      j = Math.min(n, j + 1)
    } else if (c === "'") {
      if (src[i + 1] === '\\') {
        j = i + 3 // 이스케이프된 글자(`\'` 의 `'` 포함)를 건너 닫는 `'` 를 찾는다
        while (j < n && src[j] !== "'" && src[j] !== '\n') j++
        j = Math.min(n, j + 1)
      } else if (i + 1 < n && src[i + 1] !== '\n') {
        const w = src.codePointAt(i + 1) > 0xffff ? 2 : 1
        if (src[i + 1 + w] === "'") j = i + 2 + w
      }
    }
    if (j < 0) {
      res += src[i]
      kept += src[i++]
      continue
    }
    const blank = src.slice(i, j).replace(/[^\n]/g, ' ')
    res += blank
    kept += comment ? blank : src.slice(i, j)
    i = j
  }
  return { text: res, kept, open }
}
// 이름 범위 — rustfmt 가 보장하는 모양: 항목은 감싼 것보다 네 칸 깊고, 여러 줄 몸통은 항목의 들여쓰기에서 `}` 한 글자
// 줄로 닫힌다(빈 몸통만 한 줄 `fn x() {}`). 머리의 끝은 `{` · `;` · `}` 로 끝나는 첫 줄이다(여러 줄 시그니처와 where 절의
// 줄은 `(` · `,` 로 끝난다) — `;` 이면 몸통 없는 선언(트레이트의 필수 메서드 · extern fn · `mod x;`)이라 범위가 아니다.
// `fn` 은 범위, `impl` · `trait` · 인라인 `mod` 는 네 칸 안쪽을 다시 읽는다. 함수 안의 클로저 · 중첩 fn · async 몸통은 감싼
// 함수에 접힌다. `static` · `const` 도 범위다 — 값의 클로저(`LazyLock::new(|| …)`)가 그 줄에 함수 레코드를 낳는다(독립 레그
// 실측: 범위가 아니면 「범위 밖 레코드」 FAIL). 이름은 rust 의 경로 꼴이다 — `Type::m` · `<Type as Trait>::m`(머리 그대로,
// 공백만 접는다 — 같은 타입의 `Debug::fmt` 와 `Display::fmt`, `Wrapper<u8>::get` 과 `Wrapper<u16>::get` 이 갈린다) · `mod::f` ·
// `static NAME`. `#[cfg(…)]` 는 `test` 가 꺼진 빌드(통합 테스트가 링크하는 라이브러리)로 평가한다 — 거짓이면(`test` ·
// `all(test, …)`) 그 항목은 통합 빌드에 없으므로 읽지 않고, 모르면(`windows` · `feature = …`) 이름 뒤에 붙인다(플랫폼 쌍둥이가
// 갈린다 — 이 실행에서 컴파일되지 않은 쪽은 `no record` 로 남는다). `macro_rules!` 몸통은 범위가 아니다 — 매크로가 만든
// 함수의 레코드는 몸통을 가리키고 같은 줄을 나눠 쓰므로, 그중 안 돈 것을 줄로는 가를 수 없다(→ FAIL, rustReport).
const RS_ID = String.raw`(?:r#)?[\p{XID_Start}_]\p{XID_Continue}*`
const RS_VIS = String.raw`(?:pub(?:\s*\([^)]*\))?\s+)?`
// 한정자(그룹 1 — `async` 를 본다) 뒤의 `fn 이름`(그룹 2) — `extern "C"` 의 ABI 문자열은 지운 뒤라 공백이다.
const RS_FN = new RegExp(String.raw`^(${RS_VIS}(?:(?:default|const|async|unsafe|safe|extern)\s+)*)fn\s+(${RS_ID})`, 'u')
const RS_IMPL = /^(?:(?:default|unsafe)\s+)*impl\b/
const RS_TRAIT = new RegExp(String.raw`^${RS_VIS}(?:(?:unsafe|auto)\s+)*trait\s+(${RS_ID})`, 'u')
const RS_MOD = new RegExp(String.raw`^${RS_VIS}mod\s+(${RS_ID})\s*\{$`, 'u')
const RS_VALUE = new RegExp(String.raw`^${RS_VIS}(static|const)\s+(?:mut\s+)?(${RS_ID})\s*:`, 'u')
const RS_MACRO = new RegExp(String.raw`^macro_rules!\s*(${RS_ID})\s*\{$`, 'u')
// 속성의 경로(`#[a::b(…)]` → `a::b`) — 이 목록과 도구 속성(rustfmt:: · clippy:: · diagnostic::) 밖은 속성 매크로로 본다.
const RS_ATTR_PATH = new RegExp(String.raw`^#!?\[\s*((?:::\s*)?${RS_ID}(?:\s*::\s*${RS_ID})*)`, 'u')
const RS_BUILTIN_ATTRS = new Set(
  ('cfg cfg_attr doc allow warn deny forbid expect must_use inline cold track_caller deprecated non_exhaustive repr derive ' +
    'automatically_derived no_mangle export_name link_section link_name used target_feature test ignore should_panic ' +
    'macro_export macro_use path coverage optimize naked instruction_set debugger_visualizer collapse_debuginfo unsafe').split(' '),
)
// `#[cfg(…)]` 술어를 `test` 가 꺼진 빌드에서 평가한다 — true · false · null(모름: target · feature …). 못 읽는 꼴도 null.
function cfgEval(expr) {
  const toks = expr.match(/[\p{XID_Start}_]\p{XID_Continue}*|[(),=]/gu) ?? []
  let i = 0
  const pred = () => {
    const t = toks[i++]
    if (t === undefined || '(),='.includes(t)) throw new Error('shape')
    if (toks[i] === '(' && (t === 'all' || t === 'any' || t === 'not')) {
      i++
      const vs = []
      while (toks[i] !== ')') {
        vs.push(pred())
        if (toks[i] === ',') i++
        else if (toks[i] !== ')') throw new Error('shape')
      }
      i++
      if (t === 'not') return vs.length !== 1 || vs[0] === null ? null : !vs[0]
      if (t === 'all') return vs.includes(false) ? false : vs.every((v) => v === true) ? true : null
      return vs.includes(true) ? true : vs.every((v) => v === false) ? false : null
    }
    if (toks[i] === '=') {
      i++ // `key = "value"` — 값(문자열)은 지운 뒤라 토큰이 없다
      return null
    }
    return t === 'test' ? false : null
  }
  try {
    const v = pred()
    return i === toks.length ? v : null
  } catch {
    return null
  }
}
// 글자마다 괄호 깊이(`<>` · `()` · `[]`) — `->` · `=>` 의 `>` 는 괄호가 아니다.
function rsDepths(s) {
  const at = []
  let d = 0
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    const arrow = c === '>' && (s[i - 1] === '-' || s[i - 1] === '=')
    if (!arrow && (c === '>' || c === ')' || c === ']')) d--
    at.push(d)
    if (c === '<' || c === '(' || c === '[') d++
  }
  return at
}
// impl 머리(지운 텍스트, 여러 줄이면 이은 것) → 멤버 이름의 접두. 읽지 못하면 null.
function rsImplPrefix(head) {
  let s = head.replace(/\s+/g, ' ').trim().replace(/\s*\{$/, '').replace(/^(?:(?:default|unsafe) )*impl ?/, '')
  if (s.startsWith('<')) {
    const at = rsDepths(s)
    const k = at.findIndex((d, x) => x > 0 && d === 0 && s[x] === '>' && s[x - 1] !== '-' && s[x - 1] !== '=')
    if (k < 0) return null
    s = s.slice(k + 1).trim()
  }
  const firstAtTop = (re) => {
    const at = rsDepths(s)
    for (const m of s.matchAll(re)) if (at[m.index] === 0) return m.index
    return -1
  }
  const w = firstAtTop(/\bwhere\b/g)
  if (w >= 0) s = s.slice(0, w).trim()
  if (!s) return null
  const norm = (x) => x.trim().replace(/<\s+/g, '<').replace(/,?\s*>/g, '>').replace(/\s*::\s*/g, '::')
  const f = firstAtTop(/ for /g)
  return f >= 0 ? `<${norm(s.slice(f + 5))} as ${norm(s.slice(0, f))}>::` : `${norm(s)}::`
}
function rustFuncs(file) {
  const raw = readFileSync(join(root, file), 'utf8').replace(/\r\n/g, '\n')
  const blanked = blankRust(raw)
  if (blanked.open) {
    fail('rust', `${file}: a string or block comment runs to the end of the file — the name ranges cannot be read`)
    return null
  }
  const L = blanked.text.split('\n').map((l) => l.replace(/\s+$/, ''))
  const K = blanked.kept.split('\n') // 주석만 지운 사본 — L 과 글자 자리가 같다
  const funcs = []
  const tests = [] // `test` 없이는 컴파일되지 않는 항목의 줄 범위 — 통합 빌드에는 없다
  const macros = [] // `macro_rules!` 몸통의 줄 범위
  let ok = true
  const bad = (k, msg) => {
    fail('rust', `${file}:${k + 1}: ${msg}`)
    ok = false
  }
  const count = (s, ch) => s.split(ch).length - 1
  // 속성 하나 — `#[` 에서 짝 맞는 `]` 까지(rustfmt 는 긴 cfg 술어를 여러 줄로 접는다 — 독립 레그 실측: 한 줄만 읽으면 접힌
  // `all(test, …)` 모듈의 단위 테스트 줄이 통합 커버리지로 셌다). 이름 꼬리(`shown`)는 같은 구간의 K — `]` 뒤 주석은 안 든다.
  const attrAt = (x, pad) => {
    let d = 0
    const text = []
    const shown = []
    for (let y = x; y < L.length; y++) {
      const from = y === x ? pad.length : 0
      for (let c = from; c < L[y].length; c++) {
        if (L[y][c] === '[') d++
        else if (L[y][c] === ']' && --d === 0) {
          text.push(L[y].slice(from, c + 1))
          shown.push(K[y].slice(from, c + 1))
          return { text: text.join(' '), shown: shown.join(' ') }
        }
      }
      text.push(L[y].slice(from))
      shown.push(K[y].slice(from))
    }
    return null
  }
  // 항목 위의 속성들(빈 줄 · 같은 들여쓰기의 `#` 줄 · 그보다 깊은 이어진 줄 — 접힌 속성의 몸 · 닫는 `))]` — 을 건넌다).
  // cfgs — `#[cfg(…)]` 의 값과 이름 꼬리. rewritten — 속성 매크로가 있다(내장 · 도구 속성 밖의 경로). 속성 매크로는 몸통을 다시
  // 쓸 수 있다 — `#[async_trait]` 은 async 몸통을 블록으로 옮겨 그 레코드가 사라진다(rustReport). 철자가 여럿이라(`::async_trait::
  // async_trait` · `use … as at; #[at]` — 독립 레그 4차 실측) 이름이 아니라 「내장이 아니다」로 가른다.
  const attrsOf = (k, pad) => {
    const cfgs = []
    let rewritten = false
    for (let x = k - 1; x >= 0; x--) {
      if (!L[x]) continue
      if (L[x].startsWith(`${pad}#`)) {
        const a = attrAt(x, pad)
        const text = a ? a.text.replace(/\s+/g, ' ') : ''
        const m = /^#\[\s*cfg\s*\((.*)\)\s*\]$/.exec(text)
        if (m) {
          const shown = a.shown.replace(/\s+/g, ' ').replace(/\(\s+/g, '(').replace(/,?\s+\)/g, ')').replace(/,\)/g, ')')
          cfgs.push({ value: cfgEval(m[1]), text: shown })
        }
        const path = RS_ATTR_PATH.exec(text)?.[1].replace(/\s+/g, '').replace(/^::/, '')
        if (path && !RS_BUILTIN_ATTRS.has(path) && !/^(?:rustfmt|clippy|diagnostic)::/.test(path)) rewritten = true
      } else if (!(L[x].startsWith(`${pad} `) || L[x].startsWith(`${pad})`) || L[x].startsWith(`${pad}]`))) break
    }
    return { cfgs, rewritten }
  }
  const add = (entry) => {
    if (funcs.some((f) => f.name === entry.name)) {
      fail('rust', `${file}: two functions are both named ${entry.name} — the never-executed list cannot tell them apart`)
      ok = false
      return false
    }
    funcs.push({ records: 0, hit: 0, stmts: 0, covered: 0, ...entry })
    return true
  }
  // static · const 의 끝 — 괄호(`()` · `[]` · `{}`) 깊이 0 의 `;`(rustfmt 는 긴 값을 `=` 뒤에서 더 깊이 접는다).
  const statementEnd = (k, to) => {
    let d = 0
    for (let y = k; y < to; y++)
      for (const c of L[y]) {
        if (c === '(' || c === '[' || c === '{') d++
        else if (c === ')' || c === ']' || c === '}') d--
        else if (c === ';' && d === 0) return y
      }
    return -1
  }
  // ctx — prefix(자유 항목 이름 앞) · typePrefix(impl · trait 이름 앞 — `const _` 블록 안에서도 타입 경로는 그대로다) ·
  // suffix(감싼 컨테이너의 cfg(모름) 꼬리 — 멤버 이름 뒤) · rewritten(감싼 impl · trait 에 속성 매크로).
  let unnamed = 0
  const walk = (from, to, ind, ctx) => {
    const pad = ' '.repeat(ind)
    for (let k = from; k < to && ok; k++) {
      const line = L[k]
      if (line.length <= ind || !line.startsWith(pad) || line[ind] === ' ') continue
      const t = line.slice(ind)
      const fn = RS_FN.exec(t)
      const impl = !fn && RS_IMPL.test(t)
      const tr = fn || impl ? null : RS_TRAIT.exec(t)
      const md = fn || impl || tr ? null : RS_MOD.exec(t)
      const val = fn || impl || tr || md ? null : RS_VALUE.exec(t)
      const mac = fn || impl || tr || md || val ? null : RS_MACRO.exec(t)
      if (!fn && !impl && !tr && !md && !val && !mac) continue
      const { cfgs, rewritten: own } = attrsOf(k, pad)
      const testOnly = cfgs.some((c) => c.value === false)
      const tail = `${cfgs
        .filter((c) => c.value === null)
        .reverse()
        .map((c) => ` ${c.text}`)
        .join('')}${ctx.suffix}`
      if (val) {
        const e = statementEnd(k, to)
        if (e < 0) return bad(k, `cannot find the end of the ${val[1]} item (a ";" outside brackets)`)
        // `const _` 는 이름이 없다 — 컴파일 때 단언(`const _: () = assert!(…)`)이 보통이라 한 파일에 여럿이어도 정당하다(독립
        // 레그 실측: 이름으로 두면 「같은 이름 둘」 FAIL). 블록 값(`const _: () = { impl … }`)은 안쪽 항목을 읽는다(레그 3차) — 자유
        // 항목은 `const _::` 로 가른다(바깥의 같은 이름 fn 과 겹치지 않게 — 레그 4차), impl 의 멤버는 타입에 속하니 타입 경로 그대로다.
        // 블록이 아닌 값(클로저 · 단언)은 파일 안 순번 `const _#N` 의 범위다(클로저 값은 레코드를 낳는다 — 레그 4차).
        if (val[2] === '_' && /=\s*\{$/.test(L[k]) && e > k) {
          if (!testOnly) walk(k + 1, e, ind + 4, { ...ctx, prefix: `${ctx.prefix}const _::`, suffix: tail })
          k = e
          continue
        }
        const name = val[2] === '_' ? `const ${ctx.prefix}_#${++unnamed}${tail}` : `${val[1]} ${ctx.prefix}${val[2]}${tail}`
        if (testOnly) tests.push({ start: k + 1, end: e + 1 })
        else if (!add({ name, start: k + 1, end: e + 1, ind, kind: 'value' })) return
        k = e
        continue
      }
      let h = k
      while (h < to && !/[{;}]$/.test(L[h])) h++
      if (h >= to) return bad(k, 'cannot find the end of the item head')
      if (L[h].endsWith(';')) {
        k = h
        continue
      }
      let end = h
      if (L[h].endsWith('{')) {
        end = -1
        for (let y = h + 1; y < to; y++)
          if (L[y] === `${pad}}`) {
            end = y
            break
          }
        if (end < 0) return bad(k, `cannot find the end of the item (rustfmt closes a body with "}" at the item's indent)`)
      } else if (count(L[h], '{') !== count(L[h], '}')) return bad(h, 'a one-line item whose braces do not pair')
      if (testOnly) tests.push({ start: k + 1, end: end + 1 })
      else if (mac) macros.push({ name: mac[1], start: k + 1, end: end + 1 })
      else if (fn) {
        // async 판정(rustReport)은 몸통이 따로 남는 평범한 async fn 에만 건다 — 자기나 감싼 impl · trait 에 속성 매크로가 있으면
        // (`#[async_trait]` · `#[tracing::instrument]` …) 보통 fn 처럼 읽는다.
        const isAsync = /\basync\s/.test(fn[1]) && !own && !ctx.rewritten
        if (!add({ name: `${ctx.prefix}${fn[2]}${tail}`, start: k + 1, end: end + 1, ind, kind: 'fn', async: isAsync })) return
      } else if (end > h) {
        if (md) {
          const p = `${md[1]}::`
          walk(h + 1, end, ind + 4, { prefix: `${ctx.prefix}${p}`, typePrefix: `${ctx.typePrefix}${p}`, suffix: tail, rewritten: false })
        } else {
          const p = tr ? `${tr[1]}::` : rsImplPrefix(L.slice(k, h + 1).join(' '))
          if (p === null) return bad(k, 'cannot read the type this impl is for')
          const base = `${ctx.typePrefix}${p}`
          walk(h + 1, end, ind + 4, { prefix: base, typePrefix: base, suffix: tail, rewritten: own })
        }
      }
      k = end
    }
  }
  walk(0, L.length, 0, { prefix: '', typePrefix: '', suffix: '', rewritten: false })
  // 범위 안에서 그 함수와 같은 들여쓰기의 `fn` 머리 — 범위가 닫는 줄을 지나쳐 다음 함수를 삼켰다는 뜻이다.
  const swallows = (fn, line) => {
    const pad = ' '.repeat(fn.ind)
    const t = L[line - 1] ?? ''
    return line !== fn.start && t.startsWith(pad) && t[fn.ind] !== ' ' && RS_FN.test(t.slice(fn.ind))
  }
  return ok ? { funcs, tests, macros, swallows, lines: L.length - (L.at(-1) === '' ? 1 : 0) } : null
}
function rustReport(d) {
  const path = join(out, 'rust.lcov')
  const shown = path.replace(/\\/g, '/')
  if (!existsSync(path)) {
    fail('rust', `no coverage data at ${shown} — run the integration suite first (node scripts/integration-coverage.mjs run rust)`)
    return null
  }
  const recs = new Map()
  let cur = null
  for (const l of readFileSync(path, 'utf8').replace(/\r\n/g, '\n').split('\n')) {
    if (l === '') continue
    if (l === 'end_of_record') {
      cur = null
      continue
    }
    // 기록의 줄은 전부 `TAG:` 꼴이다. ⚠️ llvm-cov 의 lcov 는 마지막 줄바꿈 없이 끝난다 — 두 보고서를 `cat` 으로 이으면
    // `end_of_recordSF:…` 한 줄이 되어 뒤 기록의 줄이 앞 파일에 섞인다(실측). 그런 줄은 못 읽는 줄이다.
    if (!/^[A-Z]+:/.test(l)) {
      fail('rust', `cannot read the lcov line: ${l.slice(0, 160)}`)
      return null
    }
    if (l.startsWith('SF:')) {
      const f = toRepoPath(l.slice(3), d.dir)
      if (recs.has(f)) {
        fail('rust', `${f} has two records in ${shown} — the data contradicts itself`)
        return null
      }
      cur = { file: f, da: new Map(), fns: [], fnda: new Map() }
      recs.set(f, cur)
      continue
    }
    if (!cur || !/^(?:DA|FN|FNDA):/.test(l)) continue
    const da = /^DA:(\d+),(\d+)(?:,.*)?$/.exec(l)
    const fnr = da ? null : /^FN:(\d+),(.+)$/.exec(l)
    const fnda = da || fnr ? null : /^FNDA:(\d+),(.+)$/.exec(l)
    if (!da && !fnr && !fnda) {
      fail('rust', `cannot read the lcov line: ${l}`)
      return null
    }
    if (fnda) cur.fnda.set(fnda[2], Number(fnda[1]))
    else if (fnr) cur.fns.push({ line: Number(fnr[1]), name: fnr[2] })
    else if (cur.da.has(Number(da[1]))) {
      fail('rust', `${cur.file}: line ${da[1]} is counted twice in one record — the data contradicts itself`)
      return null
    } else cur.da.set(Number(da[1]), Number(da[2]))
  }
  if (!recs.size) {
    fail('rust', `${shown} has no SF records — not an lcov report`)
    return null
  }
  const files = []
  const never = []
  for (const f of sortU(d.files)) {
    const r = recs.get(f)
    if (!r) {
      fail('rust', `${f} is not in the coverage data — a boundary file the run never linked would silently leave the denominator (an unreferenced module's object is not linked)`)
      continue
    }
    if (!existsSync(join(root, f))) {
      fail('rust', `${f} is in the data but not in the tree — the data belongs to another checkout`)
      continue
    }
    const src = rustFuncs(f)
    if (!src) continue
    const rangeOf = (x) => src.funcs.find((fn) => x >= fn.start && x <= fn.end)
    const within = (list, x) => list.find((t) => x >= t.start && x <= t.end)
    // 레코드의 호출 횟수(FNDA) — async 판정이 쓴다. 횟수 없는 레코드가 하나라도 있으면 그 판정을 할 수 없다(0 으로 읽으면
    // 돈 몸통을 「안 돌았다」로 낸다). llvm-cov 는 FN 마다 FNDA 를 쓴다.
    const uncounted = r.fns.find((rec) => !r.fnda.has(rec.name))
    if (uncounted) {
      fail('rust', `${f}:${uncounted.line}: the data has a function record (${uncounted.name}) without an FNDA count — whether an async body ran cannot be read`)
      continue
    }
    let broken = false
    for (const rec of r.fns) {
      if (within(src.tests, rec.line)) {
        fail('rust', `${f}:${rec.line}: the data has a function inside an item compiled only with cfg(test) (${rec.name}) — unit tests ran in this build, so the report would not be integration-only`)
        broken = true
        break
      }
      const mac = within(src.macros, rec.line)
      if (mac) {
        fail('rust', `${f}:${rec.line}: the data has a function (${rec.name}) inside macro_rules! ${mac.name} — the functions a macro generates share its lines, so one that never ran cannot be told apart from one that did; keep boundary functions out of macro_rules`)
        broken = true
        break
      }
      const fn = rangeOf(rec.line)
      if (!fn || src.swallows(fn, rec.line)) {
        const where = fn ? `starts at a function head inside ${fn.name}'s range (${fn.start}–${fn.end}) — the range ran past its end` : 'starts outside every name range — the parser missed an item, or code runs at module level'
        fail('rust', `${f}:${rec.line}: the data has a function (${rec.name}) that ${where}; the never-executed list cannot be trusted`)
        broken = true
        break
      }
      fn.records++
      if ((r.fnda.get(rec.name) ?? 0) > 0) fn.hit++
    }
    if (broken) continue
    const outside = { stmts: 0, covered: 0 }
    let stmts = 0
    let covered = 0
    for (const [line, c] of r.da) {
      if (line < 1 || line > src.lines) {
        fail('rust', `${f}: the data counts line ${line}, past the end of the file (${src.lines} lines) — the data belongs to another checkout`)
        broken = true
        break
      }
      stmts++
      if (c > 0) covered++
      const fn = rangeOf(line) ?? outside
      fn.stmts++
      if (c > 0) fn.covered++
    }
    if (broken) continue
    const mine = []
    for (const fn of src.funcs) {
      const at = { file: f, line: fn.start, name: fn.name, stmts: fn.stmts }
      if (!fn.records) {
        // 줄은 함수 레코드의 영역에서만 나온다 — 레코드 없이 줄이 있으면 데이터가 함수 레코드를 뺐다(`--skip-functions`).
        if (fn.stmts) {
          fail('rust', `${f}:${fn.start}: the data counts ${fn.stmts} line(s) inside ${fn.name} but has no function record there — a report without function records (cargo llvm-cov --skip-functions?) cannot name never-executed functions`)
          broken = true
          break
        }
        // 레코드가 없는 fn — 크레이트 밖에 안 보이고 아무도 참조 안 한 fn · 인스턴스화 안 된 제네릭 · 이 빌드에서 cfg 로 빠진 쌍둥이.
        // static · const 는 코드가 없는 것이 보통이라(문자열 상수) 레코드가 없어도 목록에 올리지 않는다.
        if (fn.kind === 'fn') mine.push({ ...at, label: 'no record in the data' })
      } else if (fn.stmts > 0 && fn.covered === 0) mine.push(at)
      // 부른 async fn 은 퓨처만 만든다 — 몸통은 poll 될 때 도는 별도 레코드다. 범위 안에서 횟수 > 0 인 레코드가 바깥 함수 하나뿐이면
      // 몸통은 안 돌았다(퓨처를 만들고 버렸다 — 독립 레그 실측: 바깥 `FNDA:1`). 줄로는 못 잰다 — 주석뿐인 몸통을 poll 하면 DA 는
      // 머리·닫는 줄뿐이다(실측). ⚠️ 속성 매크로가 붙은 async fn(자기나 감싼 impl · trait 에 — rustFuncs)은 이 판정에서 뺀다 —
      // `#[async_trait]` 의 몸통(async 블록)은 레코드도 DA 도 안 남는다(실측, async-trait 0.1.92 · rustc 1.89: poll 한 메서드도 버린
      // 메서드도 머리·닫는 줄에 바깥 횟수뿐). 이 판정을 걸면 돈 메서드가 전부 「안 돌았다」가 된다(독립 레그 3차) — 그래서 보통 fn
      // 처럼 「부르면 실행」이다. 한계 둘: 속성 매크로 async fn 의 버린 퓨처 · 제네릭 · 기본 메서드 async fn 을 두 타입으로 부르고
      // 하나도 poll 안 한 것은 실행으로 읽힌다(바깥 레코드 둘).
      else if (fn.async && fn.hit < 2) mine.push({ ...at, label: 'called, but its async body never ran' })
    }
    if (broken) continue
    files.push({ file: f, stmts, covered, outside })
    never.push(...mine)
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
  const reader = { go: goReport, python: pyReport, node: nodeReport, rust: rustReport }[l]
  const data = fails(l) ? null : reader(d)
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
      const scope = l === 'python' ? 'boundary statements inside functions' : l === 'rust' ? 'boundary lines' : 'boundary statements'
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
      printReport(l, d, data, tot, pin)
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
  const b = data.files.reduce((a, f) => ({ stmts: a.stmts + (f.bodies?.stmts ?? 0), covered: a.covered + (f.bodies?.covered ?? 0) }), { stmts: 0, covered: 0 })
  let head = `${t.covered}/${t.stmts} ${l === 'rust' ? 'lines' : 'statements'} (${pct(t.covered, t.stmts)})`
  if (l === 'python') head = `lines ${t.covered}/${t.stmts} (${pct(t.covered, t.stmts)}) · bodies ${b.covered}/${b.stmts} (${pct(b.covered, b.stmts)})`
  const n = data.never.length
  const fns = n ? `${n} never-executed function${n > 1 ? 's' : ''}` : 'no never-executed functions'
  const owned = n && !nd ? ', all owned by open registry items' : ''
  const problems = nd ? ` · ${nd} ownership problem${nd > 1 ? 's' : ''}` : ''
  const fl = floorText(pin) ? ` · ${floorText(pin)}` : ''
  // 하한 — 분모가 0 이면 위 「아무것도 안 돈 실행」이 이미 FAIL 이다. 정수식으로 비교한다(같으면 통과).
  const m = pin.floor && { statements: t, lines: t, bodies: b }[pin.floor.metric]
  if (m && m.covered * 100 < pin.floor.percent * m.stmts) {
    console.log(`integration-coverage [${l}]: BELOW — ${head}${fl} · ${fns}${owned}${problems}`)
    return 3
  }
  if (nd) {
    console.log(`integration-coverage [${l}]: DRIFT — ${head}${fl} · ${fns}${problems} (ownership is a warning, not a gate)`)
    return 1
  }
  console.log(`integration-coverage [${l}]: OK — ${head}${fl} · ${fns}${owned}`)
  return 0
}
function printReport(l, d, data, tot, pin) {
  const unit = l === 'rust' ? 'line' : 'stmt'
  const stmt = (k) => `${k} ${unit}${k > 1 ? 's' : ''}`
  console.log(`[${l}] integration-only coverage — ${floorText(pin) ?? 'report mode, no floor'}`)
  console.log(`  boundary: ${d.files.length} files derived from ${d.site} (${d.label}) — equal to the pin in ${PINS}`)
  console.log(`  data: ${data.path.replace(/\\/g, '/')}`)
  if (l !== 'python') {
    // 어느 이름 범위에도 속하지 않는 문장 — go 의 패키지 수준 함수 리터럴, node 의 모듈·클래스 수준 문장, rust 의 항목 밖 줄
    // (매크로가 펼친 코드가 항목 밖 자리를 가리킬 때 — 함수 레코드가 범위 밖이면 그 전에 FAIL 이다).
    const level = l === 'go' ? 'package-level' : 'module-level'
    for (const f of data.files) {
      const pkg = f.outside.stmts ? ` (${level} ${f.outside.covered}/${f.outside.stmts})` : ''
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
  const what = l === 'rust' ? 'none of its lines ran, its async body never ran, or the data has no record of it' : 'none of its statements ran'
  console.log(`  never executed by the integration run — ${never.length} function${never.length === 1 ? '' : 's'} (${what}):`)
  for (const x of never) console.log(`  NEVER ${x.file}:${x.line} ${x.name} · ${x.label ?? stmt(x.stmts)} · owner ${x.owner}`)
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
    console.log(`[${l}] ${floorText(pin)?.replace(/^floor /, 'floor: ') ?? 'floor: none (report mode)'}`)
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
  if (l === 'rust') {
    const lcov = join(out, 'rust.lcov')
    rmSync(lcov, { force: true })
    // 통합 대상 하나만 — 라이브러리가 cfg(test) 없이 링크된다(단위 테스트가 같은 빌드에서 돌면 리포트가 FAIL 한다).
    // `--locked` 는 레인의 다른 빌드와 같은 이유다(커밋된 Cargo.lock 그대로).
    return spawnStep('cargo', ['llvm-cov', '--locked', '--test', 'integration_test', '--lcov', '--output-path', lcov, '--', '--ignored'], cwd)
  }
  const common = commonDir(d.files)
  if (l === 'node') {
    const vitest = join(cwd, 'node_modules', 'vitest', 'vitest.mjs')
    if (!existsSync(vitest)) {
      fail(l, `${d.dir}/node_modules/vitest is missing — install the lane's dependencies first (npm ci)`)
      emitFindings(l)
      return 2
    }
    if (!common.startsWith(`${d.dir}/`)) {
      fail(l, `the derived files share no directory under ${d.dir}/ — cannot choose a coverage include`)
      emitFindings(l)
      return 2
    }
    const dir = join(out, 'node')
    rmSync(dir, { recursive: true, force: true })
    // include 는 경계 파일들의 공통 디렉터리 전부다 — v8 은 include 에 맞는 파일을 한 번도 import 안 됐어도 0% 로 싣는다
    // (실측: 20 파일 전부). 이름으로 좁히지 않는다(python 의 `source` 와 같은 이유).
    return spawnStep(
      process.execPath,
      [vitest, 'run', '--config', 'vitest.integration.config.ts', '--coverage.enabled', '--coverage.provider=v8',
        `--coverage.include=${common.slice(d.dir.length + 1)}/**/*.ts`, '--coverage.reporter=json', `--coverage.reportsDirectory=${dir}`],
      cwd,
    )
  }
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
