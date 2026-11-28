#!/usr/bin/env node
// CHANGELOG 조각 도구 — `changelog.d/` 의 조각을 검사하고(check) 모아 보인다(preview). 이어서 release · migrate · covered.
//
// 사용: node scripts/changelog.mjs check [--root=<디렉터리>]
//       node scripts/changelog.mjs preview [<lang>] [--date=YYYY-MM-DD] [--root=<디렉터리>]
//
// 종료 코드: 0 성공 · 1 거부(트리 상태 · 검사 실패 — 아무것도 쓰지 않는다) · 2 사용법.
// ⚠️ 인자 규칙은 changelog-rotate.mjs 를 따른다 — 하위명령마다 받는 `--<이름>=<값>` 과 위치 인자 수가 아래 표에 있고, 그 밖의
// 인자 · 모르는 하위명령 · 빈/겹친 `--root=` · `--<이름>=` 은 사용법 오류다. 오타가 기본 동작으로 떨어지면 「검사가 비었다」가
// 통과로 읽힌다.
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { readDeployLangs, readFragmentDir, parseFragment, renderFragment, FRAGMENT_DIR, SECTIONS, DISPLAY } from './lib/changelog-fragments.mjs'
import { compileWave, verifyWave, renderPreview, isWaveDate } from './lib/changelog-wave.mjs'
import { ROOT_FILE, UNRELEASED_POINTER, isUnreleasedPointer, parseLedgerFile, itemsOf } from './lib/changelog-ledger.mjs'

const usage = (msg) => {
  console.error(`changelog: ${msg}\n사용: ${USAGE} — 아무것도 쓰지 않았다`)
  process.exit(2)
}
const reject = (lines) => {
  for (const l of lines) console.error(l)
  process.exit(1)
}
// 트리를 읽는다 — DEPLOY_LANGS 를 못 읽거나 조각 문법이 틀리면 거부(rc 1)다.
const deployLangs = (root) => {
  try {
    return readDeployLangs(root)
  } catch (e) {
    reject([`changelog: ${e.message}`])
  }
}
const pendingFragments = (root, order) => {
  const { fragments, errors } = readFragmentDir(root, order)
  if (errors.length) reject(errors)
  return fragments
}
// `--date=` — 없으면 오늘(이 기계의 지역 날짜). 꼴이 틀리거나 달력에 없는 날이면 사용법 오류다. release 도 이것으로 읽는다.
const today = () => {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
const dateOf = (values) => {
  const date = values.date ?? today()
  if (!isWaveDate(date)) usage(`--date= 는 있는 날짜의 YYYY-MM-DD 다 — ${date}`)
  return date
}

// ---- migrate: 옛 꼴 항목 읽기 · 쓰기 전 대조 ----
const ALL_LANGS = '전 언어'
const OLD_ITEM = /^- \*\*\(([^()\n]*)\)\*\* (.*)$/
// `[Unreleased]` 의 항목 글(블록 제목은 뺐다)을 읽는다 → [{ section, langs(DEPLOY_LANGS 순서), body }]. 못 읽는 것은 모아서 거부(rc 1).
function parseOldItems(entries, order) {
  const items = []
  const errors = []
  const E = (why, line) => errors.push(`changelog: ${ROOT_FILE} [Unreleased]: ${why} — ${line.split('\n')[0]}`)
  const byName = Object.fromEntries(Object.entries(DISPLAY).map(([tok, name]) => [name, tok]))
  let section = null
  for (const e of entries) {
    if (e.startsWith('#')) {
      const m = /^### (.+)$/.exec(e)
      if (m && SECTIONS.includes(m[1])) section = m[1]
      else { section = null; E(`모르는 \`###\` 제목 — ${m ? m[1] : e}`, e) }
      continue
    }
    if (e.includes('\n')) { E('항목이 여러 줄(또는 여러 줄 문단)이다 — 한 줄만 받는다', e); continue }
    if (!e.startsWith('- ')) { E('항목이 아니다(문단)', e); continue }
    const m = OLD_ITEM.exec(e)
    if (!m) { E('`- **(<태그>)** <본문>` 꼴이 아니다(태그가 없다)', e); continue }
    if (section === null) { E('`### <절>` 밖의 항목', e); continue }
    const names = m[1].split('·').map((n) => n.trim())
    const bad = []
    if (names.includes('')) bad.push('빈 언어 이름')
    if (names.includes(ALL_LANGS) && names.length > 1) bad.push(`\`${ALL_LANGS}\` 는 혼자 쓴다`)
    for (const n of names) if (n !== '' && n !== ALL_LANGS && !(n in byName)) bad.push(`모르는 언어 이름 — ${n}`)
    const known = names.filter((n) => n in byName)
    const dup = known.find((n, i) => known.indexOf(n) !== i)
    if (dup !== undefined) bad.push(`언어 이름이 겹친다 — ${dup}`)
    if (bad.length) { for (const b of bad) E(b, e); continue }
    items.push({ section, langs: names[0] === ALL_LANGS ? [...order] : order.filter((l) => known.includes(DISPLAY[l])), body: m[2] })
  }
  if (errors.length) reject(errors)
  return items
}
// 쓰기 전 대조 셋 — 어긋나면 거부(rc 1)한다: (a) 렌더한 조각을 parseFragment 로 다시 읽어 같은 값 (b) 원래 항목과 조각의
// (section · 언어 집합 · 본문) 다중집합 (c) renderPreview 의 항목을 원장 파서로 다시 읽은 다중집합.
const keyOf = (section, langs, body) => `${section} | ${[...langs].sort().join(' ')} | ${body}`
const multiset = (keys) => keys.sort().join('\n')
function crossCheck(items, fragments, order) {
  const errors = []
  const parsed = []
  for (const f of fragments) {
    const r = parseFragment(f.name, renderFragment(f, order), order)
    errors.push(...r.errors)
    if (!r.fragment) continue
    parsed.push(r.fragment)
    if (JSON.stringify(r.fragment) !== JSON.stringify({ name: f.name, langs: f.langs, section: f.section, body: f.body })) errors.push(`changelog: 대조 (a): ${f.name} — 렌더한 조각을 다시 읽으면 다른 값이다`)
  }
  if (errors.length) reject(errors)
  const want = multiset(items.map((it) => keyOf(it.section, it.langs, it.body)))
  if (multiset(parsed.map((f) => keyOf(f.section, f.langs, f.body))) !== want) errors.push('changelog: 대조 (b): 원래 항목과 조각의 (section · 언어 집합 · 본문) 다중집합이 다르다')
  const byDisplay = Object.fromEntries(Object.entries(DISPLAY).map(([tok, name]) => [name, tok]))
  const seen = []
  let section = null
  for (const e of itemsOf(renderPreview(parsed, order)).slice(1)) {
    const h = /^### (.+)\n$/.exec(e)
    const m = /^- \*\*\(([^()\n]*)\)\*\* (.*)\n?$/.exec(e)
    if (h) section = h[1]
    else if (m) seen.push(keyOf(section, m[1].split('·').map((n) => byDisplay[n.trim()]), m[2]))
    else seen.push(`? ${e}`)
  }
  if (multiset(seen) !== want) errors.push('changelog: 대조 (c): renderPreview 의 항목을 다시 읽은 다중집합이 원래 항목과 다르다')
  if (errors.length) reject(errors)
}

// 하위명령 표 — 과제마다 한 줄씩 늘린다. args = 위치 인자 수 [최소, 최대] · values = 받는 `--<이름>=<값>` 의 이름 ·
// run({ root, args, values }) 이 종료 코드를 정한다(values 는 이름 → 값, 준 것만 있다).
const COMMANDS = {
  check: {
    usage: 'check [--root=<디렉터리>]',
    args: [0, 0],
    values: [],
    run({ root }) {
      const fragments = pendingFragments(root, deployLangs(root))
      console.log(fragments.length
        ? `ok   ${FRAGMENT_DIR}/ ${fragments.length}개 조각`
        : `ok   ${FRAGMENT_DIR}/ — 대기 중인 조각이 없다`)
    },
  },
  // 언어 없이 — 대기 조각 전부를 지금의 `[Unreleased]` 꼴로(태그는 langs 전부). 언어 하나 — 그 언어만 내보내는 물결의
  // 절(판 자리는 `?`, 태그는 그 언어뿐)이고, release 와 같은 컴파일 · 독립 대조를 거친다.
  preview: {
    usage: 'preview [<lang>] [--date=YYYY-MM-DD] [--root=<디렉터리>]',
    args: [0, 1],
    values: ['date'],
    run({ root, args: [lang], values }) {
      if (lang === undefined && values.date !== undefined) usage('--date= 는 <lang> 과 함께 준다 — 모든 언어의 미리보기는 날짜가 없는 [Unreleased] 꼴이다')
      const date = lang === undefined ? null : dateOf(values)
      const order = deployLangs(root)
      if (lang !== undefined && !order.includes(lang)) usage(`모르는 언어 — ${lang} (DEPLOY_LANGS: ${order.join(' ')})`)
      const fragments = pendingFragments(root, order)
      if (lang === undefined) {
        process.stdout.write(renderPreview(fragments, order))
        return
      }
      const wave = { date, versions: { [lang]: '?' } }
      const { text } = compileWave(fragments, wave, order)
      const errors = verifyWave(fragments, wave, text, order)
      if (errors.length) reject(errors)
      process.stdout.write(text)
    },
  },
  // 옛 꼴 `[Unreleased]` 항목을 조각으로 바꾼다 — 루트에는 고정 문단만 남는다. 빈 `[Unreleased]` 를 포인터로 바꾸는 것이 픽스처 생성기다.
  // 받는 꼴: `### <SECTIONS>` 아래의 한 줄 `- **(<표시명> · …>)** <본문>`(`전 언어` 는 아홉). 그 밖은 모아서 거부(rc 1)한다.
  // ⚠️ DEPLOY_LANGS 는 항목이 있을 때만 읽는다(빈 `[Unreleased]` 는 deploy-facts.sh 없이 돈다). 포인터 문구는 ledger 의 상수 하나다.
  migrate: {
    usage: 'migrate [--root=<디렉터리>] [--date=YYYY-MM-DD]',
    args: [0, 0],
    values: ['date'],
    run({ root, values }) {
      const date = dateOf(values)
      const file = join(root, ROOT_FILE)
      if (!existsSync(file)) reject([`changelog: ${ROOT_FILE} 가 없다 — ${file}`])
      const text = readFileSync(file, 'utf8').replace(/\r\n/g, '\n')
      const ledger = parseLedgerFile(text)
      if (ledger.unreleased.length !== 1) reject([`changelog: ${ROOT_FILE} 에 \`## [Unreleased]\` 가 ${ledger.unreleased.length === 0 ? '없다' : '둘이다'}`])
      const [block] = ledger.unreleased
      if (isUnreleasedPointer(block.text)) {
        console.log('이미 전환됐다 — [Unreleased] 는 고정 문단뿐이다')
        return
      }
      const dir = join(root, FRAGMENT_DIR)
      if (existsSync(dir) && readdirSync(dir).length) reject([`changelog: \`${FRAGMENT_DIR}/\` 에 파일이 있다 — 옛 항목과 섞지 않는다`])
      const entries = itemsOf(block.text).slice(1).map((e) => e.replace(/\n$/, '')) // 첫 줄은 블록 제목이다
      const order = entries.length ? deployLangs(root) : []
      const items = parseOldItems(entries, order)
      const fragments = items.map((it, i) => ({ ...it, name: `${date}-unreleased-${String(i + 1).padStart(3, '0')}.txt` }))
      if (fragments.length) crossCheck(items, fragments, order)
      const out = ledger.order.map((b) => (b === block ? `${block.heading}\n\n${UNRELEASED_POINTER}\n\n` : b.text)).join('')
      if (fragments.length) mkdirSync(dir, { recursive: true })
      for (const f of fragments) writeFileSync(join(dir, f.name), renderFragment(f, order))
      writeFileSync(file, ledger.head + out)
      console.log(`ok   migrate: 항목 ${items.length}개 → 조각 ${fragments.length}개`)
    },
  },
}
const USAGE = Object.values(COMMANDS).map((c) => `node scripts/changelog.mjs ${c.usage}`).join(' | ')

const [cmd, ...rest] = process.argv.slice(2)
if (!cmd || cmd.startsWith('--') || !Object.hasOwn(COMMANDS, cmd)) usage(`모르는 하위명령 — ${cmd ?? '(없음)'}`)
const spec = COMMANDS[cmd]
const roots = []
const given = {} // 이름 → 받은 값들
const args = []
const unknown = []
for (const a of rest) {
  const m = /^--([a-z]+)=/.exec(a)
  if (a.startsWith('--root=')) roots.push(a)
  else if (m && spec.values.includes(m[1])) (given[m[1]] ??= []).push(a.slice(m[0].length))
  else if (a.startsWith('--')) unknown.push(a)
  else args.push(a)
}
if (unknown.length) usage(`모르는 인자 — ${unknown.join(' ')}`)
if (roots.length > 1 || roots.includes('--root=')) usage(`--root= 는 값과 함께 한 번만 준다 — ${roots.join(' ')}`)
for (const [name, vs] of Object.entries(given)) {
  if (vs.length > 1 || vs.includes('')) usage(`--${name}= 는 값과 함께 한 번만 준다 — ${vs.map((v) => `--${name}=${v}`).join(' ')}`)
}
const [min, max] = spec.args
if (args.length < min || args.length > max) usage(`${cmd} 의 위치 인자는 ${min === max ? `${min}개` : `${min}–${max}개`}다 — ${args.join(' ') || '(없음)'}`)
spec.run({
  root: roots.length ? roots[0].slice('--root='.length) : '.',
  args,
  values: Object.fromEntries(Object.entries(given).map(([name, [v]]) => [name, v])),
})
