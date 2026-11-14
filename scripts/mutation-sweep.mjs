#!/usr/bin/env node
// 변이 스윕 — 자가테스트가 판정기의 **거부**를 실제로 단언하는지 변이로 잰다(등록부 selftests-with-no-negative-case).
//
// 왜 필요한가: 판정기의 거부를 단언하지 않는 자가테스트는 판정기가 늘 통과해도 초록이다. 실측(2026-11-14): M1 변이
// 39 쌍 중 SILENT 3 — 판정 함수만 먹였거나(`decide()`), 종료 코드를 버리고(`|| true`) 메시지만 봤다. 인라인 판정
// (자가테스트 자신이 판정기)도 음성 대조가 없으면 같은 부류다. 사람이 「이번엔 확인했다」를 반복하는 것은 구속하지
// 않는다 — 이 스윕이 주간으로 다시 잰다(.github/workflows/mutation-sweep.yml).
//
// 두 종류를 같은 러너(scripts/probe.sh — 0 CAUGHT · 1 SILENT · 2 INVALID)로 돌린다.
//   M1  (자가테스트, 그 테스트가 **실행하는** scripts/ 판정기) 쌍 — 판정기의 실패 종료를 전부 0 으로 바꾸고
//       (scripts/lib/m1-exit-neutral.mjs) 그 테스트를 돌린다. 쌍은 트리에서 파생한다(손 목록이 아니다). 넓게 잡고,
//       실행이 아닌 언급은 레코드 파일의 제외가 이유와 함께 좁힌다 — 파생되지 않는 제외는 낡았다고 exit 2.
//   REC 레코드 파일의 줄 변이 — 「이 줄을 이렇게 바꾸면 이 테스트가 잡아야 한다」. 인라인 판정의 음성 대조가 살아
//       있는지 본다. OLD 가 파일에 정확히 한 번 없거나 SITE 가 맞지 않으면 계획부터 서지 않는다(exit 2) — 그
//       정적 검사는 자가테스트가 PR 마다 돌린다.
// SILENT · INVALID · 시간 초과면 exit 1. --list 는 계획만 찍는다(변이 없음).
//
// ⚠️ 못 보는 것 둘(Grok 레그): (a) 판정기 **소스**를 줄 수 · 해시로 대조하는 시험은 M1 이 넣은 한 줄에 넘어져
// 거부를 단언하지 않아도 CAUGHT 이 난다 — CAUGHT 의 근거는 probe.sh 가 찍는 실패 단언 목록이다. (b) 판정기 경로를
// 문자열로 조립하면(`"$DIR/../check-$L.mjs"`) 쌍이 파생되지 않는다 — 그 시험은 이 스윕 밖이다.
//
// 사용: node scripts/mutation-sweep.mjs [--list] [--only <부분 문자열>] [--timeout <초>]
import { spawnSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

export const RECORDS = 'scripts/test/mutation-records.txt'
// 실행 표지 — 판정기 이름과 **같은 줄**에 있어야 그 줄이 실행이다(주석 줄은 보지 않는다).
const EXEC_MARK = /(node |sh |bash |import\(|\$ROOT\/scripts\/|\$DIR\/\.\.\/|\$SCRIPTS?\/|\$S\/|"\$[A-Z_]+"( |$))/
const REF = /(?:\.\.\/|scripts\/)((?:lib\/)?[A-Za-z0-9_-]+\.(?:mjs|sh))/g

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// tests = [{ name, text }] · exists(judge) · exclusions = [[test, judge, why]] → { pairs, stale }
export function pairsOf(tests, exists, exclusions = []) {
  const candidates = []
  for (const { name, text } of tests) {
    const code = text.split(/\r?\n/).filter((l) => !/^\s*#/.test(l))
    const refs = new Set([...text.matchAll(REF)].map((m) => m[1]).filter((j) => j !== 'assert.sh'))
    for (const judge of [...refs].sort()) {
      if (!exists(judge)) continue
      // scripts/lib/*.sh 는 소싱하는 사실 라이브러리다 — 시험이 사본을 만들거나 소싱할 뿐 판정기로 실행하지 않고,
      // M1 의 EXIT 트랩은 소싱한 프로세스(시험 자신)를 0 으로 만든다(실측: 두 시험이 픽스처 사본으로 쌍에 잡혔다).
      if (/^lib\/.*\.sh$/.test(judge)) continue
      const base = judge.split('/').pop()
      // 소싱하는 라이브러리는 같은 프로세스다 — M1 의 EXIT 트랩이 시험 자신을 0 으로 만들어 잴 수 없다.
      if (code.some((l) => new RegExp(`^\\s*(\\.|source)\\s+\\S*${esc(base)}`).test(l))) continue
      if (code.some((l) => l.includes(base) && EXEC_MARK.test(l))) candidates.push({ test: name, judge })
    }
  }
  const key = (t, j) => `${t}\u0000${j}`
  const excluded = new Set(exclusions.map(([t, j]) => key(t, j)))
  const derived = new Set(candidates.map((p) => key(p.test, p.judge)))
  return {
    pairs: candidates.filter((p) => !excluded.has(key(p.test, p.judge))),
    stale: exclusions.filter(([t, j]) => !derived.has(key(t, j))),
  }
}

// 레코드 파일: `### <id>` 뒤에 FIELD:값 줄들. JUDGE 가 있으면 제외(TEST · JUDGE · WHY), 없으면 줄 변이
// (FILE · TEST · OLD · NEW · SITE). 값은 콜론 바로 뒤부터다(앞 공백도 값이다 — 들여쓴 줄을 그대로 담는다).
export function parseRecords(text) {
  const blocks = []
  let cur = null
  for (const line of text.split(/\r?\n/)) {
    const h = line.match(/^### (.+)$/)
    if (h) { cur = { id: h[1].trim() }; blocks.push(cur); continue }
    const f = line.match(/^(FILE|TEST|OLD|NEW|SITE|JUDGE|WHY):(.*)$/)
    if (f && cur) cur[f[1].toLowerCase()] = f[2]
  }
  return {
    exclusions: blocks.filter((b) => b.judge !== undefined).map((b) => [b.test, b.judge, b.why ?? '']),
    mutations: blocks.filter((b) => b.judge === undefined),
  }
}

// 정적 유효성 — read(path) 는 파일 본문 또는 null.
export function recordProblems(rec, read) {
  const p = []
  for (const k of ['file', 'test', 'old', 'new', 'site']) if (rec[k] === undefined || rec[k] === '') p.push(`${k.toUpperCase()} 가 없다`)
  if (p.length) return p
  const body = read(rec.file)
  if (body == null) return [`FILE ${rec.file} 이 없다`]
  if (read(rec.test) == null) p.push(`TEST ${rec.test} 가 없다`)
  const hits = body.split(/\r?\n/).filter((l) => l === rec.old).length
  if (hits !== 1) p.push(`OLD 가 ${rec.file} 에 정확히 한 줄이 아니다(${hits} 줄) — 줄이 바뀌었으면 레코드를 고친다`)
  if (body.includes(rec.site)) p.push('SITE 가 원본에 이미 있다 — 착지를 가리지 못한다')
  if (!rec.new.includes(rec.site)) p.push('SITE 가 NEW 에 없다')
  return p
}

// 줄 하나를 통째로 바꾼다. 값은 환경 변수로 넘겨 다시 따옴표를 치지 않는다. 줄끝 CR 은 떼고 비교한 뒤 되붙인다 —
// Windows 체크아웃(autocrlf)에서 .mjs 는 CRLF 라 그대로 비교하면 한 줄도 안 맞아 INVALID 가 된다(실측).
// 정확히 한 줄이 아니면 exit 3 — probe.sh 가 INVALID 로 받는다.
const REC_MUTATION =
  `awk '{ l = $0; cr = ""; if (sub(/\\r$/, "", l)) cr = "\\r" } l == (ENVIRON["PO"] "") { print ENVIRON["PN"] cr; n++; next } { print } END { exit (n == 1 ? 0 : 3) }' "$PF" > "$PF.mut" && mv "$PF.mut" "$PF"`

function plan(root) {
  const read = (p) => { try { return readFileSync(join(root, p), 'utf8') } catch { return null } }
  const testDir = join(root, 'scripts', 'test')
  const tests = readdirSync(testDir).filter((n) => /^test-.*\.sh$/.test(n)).sort()
    .map((name) => ({ name, text: readFileSync(join(testDir, name), 'utf8') }))
  const { exclusions, mutations } = parseRecords(read(RECORDS) ?? '')
  const errors = []
  for (const [t, j, why] of exclusions) if (!t || !j || !why.trim()) errors.push(`제외 ${t} × ${j}: TEST · JUDGE · WHY 가 다 있어야 한다`)
  const { pairs, stale } = pairsOf(tests, (j) => existsSync(join(root, 'scripts', j)), exclusions)
  for (const [t, j] of stale) errors.push(`제외 ${t} × ${j} 는 더는 파생되지 않는다 — 낡은 제외를 지운다`)
  for (const r of mutations) for (const e of recordProblems(r, read)) errors.push(`레코드 ${r.id}: ${e}`)
  const items = [
    ...pairs.map((p) => ({ kind: 'M1', desc: `${p.test} × ${p.judge}`, site: 'PROBE-M1',
      mutation: `node scripts/lib/m1-exit-neutral.mjs scripts/${p.judge}`, test: `scripts/test/${p.test}`, env: {} })),
    ...mutations.map((r) => ({ kind: 'REC', desc: `${r.test.split('/').pop()} :: ${r.id}`, site: r.site,
      mutation: REC_MUTATION, test: r.test, env: { PF: r.file, PO: r.old, PN: r.new } })),
  ]
  return { items, exclusions, errors }
}

function main() {
  const argv = process.argv.slice(2)
  const opt = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : undefined }
  const root = fileURLToPath(new URL('..', import.meta.url))
  const { items, exclusions, errors } = plan(root)
  if (errors.length) {
    for (const e of errors) console.log(`::error::${e}`)
    process.exit(2)
  }
  const only = opt('--only')
  const run = only ? items.filter((i) => i.desc.includes(only)) : items
  if (argv.includes('--list')) {
    for (const i of run) console.log(`${i.kind.padEnd(3)} ${i.desc}`)
    for (const [t, j, why] of exclusions) console.log(`--  제외 ${t} × ${j} — ${why}`)
    console.log(`계획: M1 ${run.filter((i) => i.kind === 'M1').length} · REC ${run.filter((i) => i.kind === 'REC').length}`)
    process.exit(0)
  }
  const timeout = Number(opt('--timeout') ?? 1800) * 1000
  let bad = 0
  for (const i of run) {
    const r = spawnSync('sh', ['scripts/probe.sh', '--site', i.site, i.mutation, 'sh', i.test], {
      cwd: root, env: { ...process.env, ...i.env }, encoding: 'utf8', timeout, maxBuffer: 64 * 1024 * 1024, windowsHide: true,
    })
    const v = r.error ? 'TIMEOUT' : ({ 0: 'CAUGHT', 1: 'SILENT', 2: 'INVALID' }[r.status] ?? `RC${r.status}`)
    console.log(`${v.padEnd(7)} ${i.kind.padEnd(3)} ${i.desc}`)
    if (v !== 'CAUGHT') {
      bad++
      for (const l of `${r.stdout ?? ''}${r.stderr ?? ''}`.trim().split('\n').slice(-12)) console.log(`        ${l}`)
    }
  }
  console.log(`${run.length} 개 중 CAUGHT ${run.length - bad}`)
  process.exit(bad ? 1 : 0)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
