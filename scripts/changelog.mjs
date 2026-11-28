#!/usr/bin/env node
// CHANGELOG 조각 도구 — `changelog.d/` 의 조각을 검사하고(check) 모아 보이고(preview) 릴리스 날짜 절로 옮긴다(release).
// 옛 꼴 `[Unreleased]` 를 조각으로 바꾸는 것은 migrate. 그 범위가 더한 언어는 covered.
//
// 사용: node scripts/changelog.mjs check [--root=<디렉터리>]
//       node scripts/changelog.mjs preview [<lang>] [--date=YYYY-MM-DD] [--root=<디렉터리>]
//       node scripts/changelog.mjs preview --stats [--root=<디렉터리>]
//       node scripts/changelog.mjs migrate [--root=<디렉터리>] [--date=YYYY-MM-DD]
//       node scripts/changelog.mjs release [--root=<디렉터리>] [--date=YYYY-MM-DD] <lang>=<판> …
//       node scripts/changelog.mjs covered [--root=<디렉터리>] --base=<rev>
//
// 종료 코드: 0 성공 · 1 거부(트리 상태 · 검사 실패 — 아무것도 쓰지 않는다) · 2 사용법.
// ⚠️ 인자 규칙은 changelog-rotate.mjs 를 따른다 — 하위명령마다 받는 `--<이름>=<값>` · 불리언 플래그 `--<이름>` 과 위치 인자 수가
// 아래 표에 있고, 그 밖의 인자 · 모르는 하위명령 · 빈/겹친 `--root=` · `--<이름>=` · 겹친 플래그 · `--<이름>=<값>` 꼴의 플래그는
// 사용법 오류다(플래그는 정확히 `--<이름>` 한 번만 받는다). 오타가 기본 동작으로 떨어지면 「검사가 비었다」가 통과로 읽힌다.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { readDeployLangs, readFragmentDir, parseFragment, renderFragment, FRAGMENT_DIR, SECTIONS, DISPLAY } from './lib/changelog-fragments.mjs'
import { compileWave, verifyWave, renderPreview, isWaveDate, checkFragmentTree, percentOf } from './lib/changelog-wave.mjs'
import { ROOT_FILE, UNRELEASED_POINTER, VOLUME_DIR, VOLUME_RE, isUnreleasedPointer, parseLedgerFile, itemsOf } from './lib/changelog-ledger.mjs'

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
// 루트 원장 — 줄 끝을 LF 로 맞춰 읽는다. 없거나 `## [Unreleased]` 가 하나가 아니면 거부(rc 1)다. migrate · release 가 쓴다.
const readRoot = (root) => {
  const file = join(root, ROOT_FILE)
  if (!existsSync(file)) reject([`changelog: ${ROOT_FILE} 가 없다 — ${file}`])
  const ledger = parseLedgerFile(readFileSync(file, 'utf8').replace(/\r\n/g, '\n'))
  if (ledger.unreleased.length !== 1) reject([`changelog: ${ROOT_FILE} 에 \`## [Unreleased]\` 가 ${ledger.unreleased.length === 0 ? '없다' : '둘이다'}`])
  return { file, ledger, block: ledger.unreleased[0] }
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
    items.push({ section, langs: names[0] === ALL_LANGS ? [...order] : order.filter((l) => known.includes(DISPLAY[l])), body: m[2], line: e })
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
    // 조각 문법(공백 · 상한)의 소유자는 parseFragment 하나다 — 그 사유를 그대로 싣고 쓰이지 않은 조각 대신 원래 항목 줄을 가리킨다.
    for (const msg of r.errors) errors.push(`changelog: ${ROOT_FILE} [Unreleased]: ${msg.slice(`${FRAGMENT_DIR}/${f.name}: `.length)} — ${f.line.split('\n')[0]}`)
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

// ---- release: 판 꼴 · 이미 나간 (언어, 판) ----
// 판은 `<주>.<부>.<수>` 에 `-<꼬리>` 하나까지 — 제목의 대괄호 · 괄호를 깨는 글자와 공통 절의 대괄호 글 `물결` 을 받지 않는다.
const VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$/
// 보관본(changelog/<YYYY-MM>.md)마다 [그 경로, 그 `## ` 제목들] — 디렉터리가 없으면 보관본도 없다.
function volumeHeadings(root) {
  const dir = join(root, VOLUME_DIR)
  if (!existsSync(dir)) return []
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && VOLUME_RE.test(`${VOLUME_DIR}/${e.name}`))
    .map((e) => e.name)
    .sort()
    .map((n) => [`${VOLUME_DIR}/${n}`, parseLedgerFile(readFileSync(join(dir, n), 'utf8').replace(/\r\n/g, '\n')).order.map((b) => b.heading)])
}
// 이미 나간 (언어, 판) — 꼴이 `## [<판>] - <YYYY-MM-DD> (<표시명 · …>)` 인 제목의 괄호 안 표시명마다 하나. 괄호가 없는 제목과
// 표시명이 아닌 조각은 건너뛴다(제목의 꼴은 8d 의 몫이다). `[Unreleased]` 는 날짜가 없어 이 꼴 밖이고, `[물결]` 절의 괄호 안은
// `<표시명> <판>` 이라 표시명이 아니다 — 따로 거르는 줄을 두지 않는다(그 줄에는 어떤 입력도 닿지 않는다: 판 꼴을 지난 물결 판이
// `물결` · `Unreleased` 일 수 없다). files = [[경로, 제목들], …] — 루트 먼저, 보관본은 이름순. → Map(pairKey → 처음 나온 { heading, where }).
const DATED_HEADING_RE = /^## \[([^\]]+)\] - \d{4}-\d{2}-\d{2} \(([^()]+)\)$/
const pairKey = (lang, ver) => `${lang} ${ver}`
function shippedPairs(files) {
  const token = new Map(Object.entries(DISPLAY).map(([tok, name]) => [name, tok]))
  const pairs = new Map()
  for (const [where, headings] of files) {
    for (const heading of headings) {
      const m = DATED_HEADING_RE.exec(heading)
      if (!m) continue
      for (const name of m[2].split(' · ')) {
        const lang = token.get(name)
        if (lang !== undefined && !pairs.has(pairKey(lang, m[1]))) pairs.set(pairKey(lang, m[1]), { heading, where })
      }
    }
  }
  return pairs
}

// 루트 `[Unreleased]` 가 고정 문단인가(§5.2) — CHANGELOG.md 가 없으면 볼 것이 없다(오류 아님). 오류 줄들을 돌려준다.
const rootPointerErrors = (root) => {
  const file = join(root, ROOT_FILE)
  if (!existsSync(file)) return []
  const { unreleased } = parseLedgerFile(readFileSync(file, 'utf8').replace(/\r\n/g, '\n'))
  if (unreleased.length !== 1)
    return [`changelog: ${ROOT_FILE} 에 \`## [Unreleased]\` 가 ${unreleased.length === 0 ? '없다' : '둘 이상이다'} — 고정 문단 하나가 든 \`[Unreleased]\` 가 정확히 하나여야 한다`]
  if (!isUnreleasedPointer(unreleased[0].text))
    return [`changelog: ${ROOT_FILE} 의 \`## [Unreleased]\` 가 고정 문단이 아니다 — 미출시 항목은 \`${FRAGMENT_DIR}/\` 의 조각이다(옛 항목은 \`node scripts/changelog.mjs migrate\` 로 옮긴다)`]
  return []
}

// 하위명령 표 — 과제마다 한 줄씩 늘린다. args = 위치 인자 수 [최소, 최대](최대 Infinity 는 위가 열림) · values = 받는 `--<이름>=<값>` 의 이름 ·
// flags = 받는 불리언 플래그 `--<이름>` 의 이름 · run({ root, args, values, flags }) 이 종료 코드를 정한다(values 는 이름 → 값,
// flags 는 이름 → true, 둘 다 준 것만 있다).
const COMMANDS = {
  check: {
    usage: 'check [--root=<디렉터리>]',
    args: [0, 0],
    values: [],
    flags: [],
    run({ root }) {
      const order = deployLangs(root)
      const { errors, warnings } = checkFragmentTree(root)
      errors.push(...rootPointerErrors(root))
      if (errors.length) reject(errors)
      const fragments = pendingFragments(root, order)
      console.log(fragments.length
        ? `ok   ${FRAGMENT_DIR}/ ${fragments.length}개 조각`
        : `ok   ${FRAGMENT_DIR}/ — 대기 중인 조각이 없다`)
      for (const w of warnings) console.log(`⚠️  ${w}`)
    },
  },
  // 언어 없이 — 대기 조각 전부를 지금의 `[Unreleased]` 꼴로(태그는 langs 전부). 언어 하나 — 그 언어만 내보내는 물결의
  // 절(판 자리는 `?`, 태그는 그 언어뿐)이고, release 와 같은 컴파일 · 독립 대조를 거친다.
  preview: {
    usage: 'preview [<lang>] [--date=YYYY-MM-DD] [--root=<디렉터리>] | preview --stats [--root=<디렉터리>]',
    args: [0, 1],
    values: ['date'],
    flags: ['stats'],
    run({ root, args: [lang], values, flags }) {
      // `--stats` — 통계 줄만 찍는다(미리보기 글 없음): 언어마다 대기 조각 수 · 한 언어 물결의 바이트, 끝에 아홉 언어 물결 예상.
      if (flags.stats) {
        if (lang !== undefined || values.date !== undefined) usage('--stats 는 <lang> · --date= 와 함께 쓰지 않는다')
        const order = deployLangs(root)
        const { errors, stats } = checkFragmentTree(root)
        if (errors.length) reject(errors)
        for (const l of order) console.log(`${l} 대기 ${stats.perLang[l].count}개 · ${stats.perLang[l].bytes}B`)
        console.log(`아홉 언어 물결 예상 ${stats.projected}B / 8c 상한 ${stats.tripwire}B (${percentOf(stats.projected)}%)`)
        return
      }
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
    flags: [],
    run({ root, values }) {
      const date = dateOf(values)
      const { file, ledger, block } = readRoot(root)
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
  // 물결 하나(버전 범프 커밋 하나)를 `[Unreleased]` 바로 아래 날짜 절로 만들고, 내보낸 언어를 조각의 langs 에서 뺀다(비면 지운다).
  // 확인 1–6 을 차례로 모두 지나야 쓴다 — 하나라도 걸리면 아무것도 쓰지 않는다. 되돌리기 장치는 없다(git 이 되돌린다 — migrate 와 같다).
  release: {
    usage: 'release [--root=<디렉터리>] [--date=YYYY-MM-DD] <lang>=<판> …',
    args: [1, Infinity],
    values: ['date'],
    flags: [],
    run({ root, args, values }) {
      // 1 인자 — 날짜 · `<lang>=<판>` 꼴 · 판 꼴 · 겹침(rc 2) → DEPLOY_LANGS(못 읽으면 rc 1) → 그 밖의 언어(rc 2)
      const date = dateOf(values)
      const versions = new Map() // 언어 → 판 — 객체가 아니라 Map 이라 `__proto__=…` 도 그냥 모르는 언어다
      for (const a of args) {
        const i = a.indexOf('=')
        if (i <= 0 || i === a.length - 1) usage(`\`<lang>=<판>\` 꼴이 아니다 — ${a}`)
        const lang = a.slice(0, i)
        const ver = a.slice(i + 1)
        if (!VERSION_RE.test(ver)) usage(`판 꼴이 아니다 — ${a} (<주>.<부>.<수> 또는 <주>.<부>.<수>-<꼬리>)`)
        if (versions.has(lang)) usage(`언어가 겹친다 — ${lang}`)
        versions.set(lang, ver)
      }
      const order = deployLangs(root)
      for (const lang of versions.keys()) if (!order.includes(lang)) usage(`모르는 언어 — ${lang} (DEPLOY_LANGS: ${order.join(' ')})`)
      // 2 루트 `[Unreleased]` 가 고정 문단이다
      const { file, ledger, block } = readRoot(root)
      if (!isUnreleasedPointer(block.text))
        reject([`changelog: ${ROOT_FILE} 의 \`## [Unreleased]\` 가 고정 문단이 아니다 — 먼저 migrate(\`node scripts/changelog.mjs migrate\`)로 옛 항목을 조각으로 옮긴다`])
      // 3 조각 문법
      const fragments = pendingFragments(root, order)
      // 4 날짜 ≥ 루트의 최신 날짜 절(공통 절도 센다) — 같은 날은 받고, 날짜 절이 없으면 아래 한계가 없다
      const newest = ledger.releases.map((b) => b.date).sort().pop()
      if (newest !== undefined && date < newest)
        reject([`changelog: 물결의 날짜(${date})가 ${ROOT_FILE} 의 최신 날짜(${newest})보다 이르다 — 물결은 \`[Unreleased]\` 바로 아래에 들어가 원장의 최신순을 깬다`])
      // 5 물결의 (언어, 판)이 루트 · 보관본의 날짜 절 제목에 없다 — 같은 물결을 다시 돌렸거나 그 언어의 그 판이 이미 나갔다(날짜는
      // 보지 않는다 — 다른 날에 다시 내도 거부한다). 같은 번호의 다른 언어는 받는다(§5.3 「같은 번호 경고」).
      const shipped = shippedPairs([[ROOT_FILE, ledger.order.map((b) => b.heading)], ...volumeHeadings(root)])
      const dups = order.filter((l) => versions.has(l)).map((l) => [l, shipped.get(pairKey(l, versions.get(l)))]).filter(([, s]) => s)
      if (dups.length) reject(dups.map(([l, s]) => `changelog: 이미 있는 판 — ${DISPLAY[l]} ${versions.get(l)}: 「${s.heading}」(${s.where})`))
      // 6 컴파일 → 독립 대조 → 새 루트를 원장 파서로 다시 읽어 `[Unreleased]` 하나 · 모르는 제목 0
      const wave = { date, versions: Object.fromEntries(versions) }
      const { text, updates } = compileWave(fragments, wave, order)
      const mismatch = verifyWave(fragments, wave, text, order)
      if (mismatch.length) reject(mismatch)
      const out = ledger.head + ledger.order.map((b) => (b === block ? `${block.heading}\n\n${UNRELEASED_POINTER}\n\n${text}` : b.text)).join('')
      const again = parseLedgerFile(out)
      const shape = again.unknown.map((b) => `changelog: ${ROOT_FILE} 의 「${b.heading}」 — 원장의 \`## \` 제목은 \`[Unreleased]\` 와 \`[<판>] - <YYYY-MM-DD> …\` 뿐이다`)
      if (again.unreleased.length !== 1) shape.push(`changelog: 새 ${ROOT_FILE} 에 \`## [Unreleased]\` 가 ${again.unreleased.length}개다`)
      if (shape.length) reject(shape)
      // 7 쓰기 — 루트가 먼저다: 도중에 멈춰도 다시 돌린 release 는 확인 5 가 거부한다(물결의 (언어, 판)이 이미 루트의 언어 절 제목에
      // 있다 — 조각을 먼저 지우면 둘째 실행이 노트를 잃은 물결을 쓴다). 물결이 닿은 조각은 남은 langs 로 renderFragment 하고, 비면 지운다.
      writeFileSync(file, out)
      const byName = new Map(fragments.map((f) => [f.name, f]))
      let rewritten = 0
      let deleted = 0
      for (const { name, langs } of updates) {
        const path = join(root, FRAGMENT_DIR, name)
        if (langs.length) {
          writeFileSync(path, renderFragment({ ...byName.get(name), langs }, order))
          rewritten++
        } else {
          unlinkSync(path)
          deleted++
        }
      }
      // 8 출력 — ok 줄, 이어서 대기 노트가 없는 물결 언어마다 알림(DEPLOY_LANGS 순서 · 토큰)
      const bullets = text.split('\n').filter((l) => l.startsWith('- ')).length
      console.log(`ok   release ${date}: 절 ${parseLedgerFile(text).order.length}개 · 항목 ${bullets}개 · 조각 갱신 ${rewritten} · 삭제 ${deleted}`)
      for (const l of order) {
        if (versions.has(l) && !fragments.some((f) => f.langs.includes(l))) console.log(`⚠️  ${l}: 대기 노트가 없다 — 절에는 손글 자리만 있다`)
      }
    },
  },
  // 범위가 조각으로 **얻은** 언어 — 한 줄(DEPLOY_LANGS 순 · 공백 구분 · 없으면 빈 줄). 착지 게이트가 「이 범위가 그 언어의 노트를 더했는가」를 묻는 자리다.
  // 조각마다 기준 langs = 같은 경로의 기준 조각 → 없으면 본문이 같은 기준 조각들의 합집합(이름만 바꾼 조각은 새 노트가 아니다) → 없으면 ∅.
  // ⚠️ 기준은 먼저 sha 로 풀고(옵션처럼 생긴 값은 `--end-of-options` 가 막는다) 그 sha 로만 읽는다. 기준의 조각도 같은 문법으로 읽고 깨졌으면 거부(rc 1)다.
  covered: {
    usage: 'covered [--root=<디렉터리>] --base=<rev>',
    args: [0, 0],
    values: ['base'],
    flags: [],
    run({ root, values }) {
      if (values.base === undefined) usage('--base= 가 필요하다')
      const git = (...a) => execFileSync('git', ['-C', root, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 1 << 28 })
      let sha
      try {
        sha = git('rev-parse', '--verify', '--quiet', '--end-of-options', `${values.base}^{commit}`).trim()
      } catch {
        reject([`changelog: 기준 리비전을 읽지 못했다 — ${values.base}`])
      }
      const order = deployLangs(root)
      const work = pendingFragments(root, order)
      const at = sha.slice(0, 12)
      const base = []
      const errors = []
      try {
        for (const path of git('ls-tree', '-r', '-z', '--name-only', sha, '--', FRAGMENT_DIR).split('\0').filter(Boolean)) {
          const name = path.slice(`${FRAGMENT_DIR}/`.length)
          // 하위 경로(`sub/x.txt`)는 이름 꼴(FRAGMENT_NAME_RE)이 거부한다 — 따로 거르는 줄을 두지 않는다(같은 조건 둘은 변이를 공허하게 한다).
          const r = parseFragment(name, git('show', `${sha}:${path}`), order)
          errors.push(...r.errors.map((m) => `${m} (기준 ${at})`))
          if (r.fragment) base.push(r.fragment)
        }
      } catch {
        reject([`changelog: 기준 ${at} 의 ${FRAGMENT_DIR}/ 를 읽지 못했다`])
      }
      if (errors.length) reject(errors)
      const gained = new Set()
      for (const f of work) {
        const same = base.find((b) => b.name === f.name)
        const had = new Set(same ? same.langs : base.filter((b) => b.body === f.body).flatMap((b) => b.langs))
        for (const l of f.langs) if (!had.has(l)) gained.add(l)
      }
      console.log(order.filter((l) => gained.has(l)).join(' '))
    },
  },
}
const USAGE = Object.values(COMMANDS).map((c) => `node scripts/changelog.mjs ${c.usage}`).join(' | ')

const [cmd, ...rest] = process.argv.slice(2)
if (!cmd || cmd.startsWith('--') || !Object.hasOwn(COMMANDS, cmd)) usage(`모르는 하위명령 — ${cmd ?? '(없음)'}`)
const spec = COMMANDS[cmd]
const roots = []
const given = {} // 이름 → 받은 값들
const flagged = [] // 받은 불리언 플래그 이름들(겹침을 보려고 센다)
const args = []
const unknown = []
for (const a of rest) {
  const m = /^--([a-z]+)=/.exec(a)
  if (a.startsWith('--root=')) roots.push(a)
  else if (m && spec.values.includes(m[1])) (given[m[1]] ??= []).push(a.slice(m[0].length))
  else if (a.startsWith('--') && spec.flags.includes(a.slice(2))) flagged.push(a.slice(2)) // 정확히 `--<이름>` 뿐 — `--stats=x` 는 아래 unknown
  else if (a.startsWith('--')) unknown.push(a)
  else args.push(a)
}
if (unknown.length) usage(`모르는 인자 — ${unknown.join(' ')}`)
for (const f of flagged) if (flagged.indexOf(f) !== flagged.lastIndexOf(f)) usage(`--${f} 는 한 번만 준다`)
if (roots.length > 1 || roots.includes('--root=')) usage(`--root= 는 값과 함께 한 번만 준다 — ${roots.join(' ')}`)
for (const [name, vs] of Object.entries(given)) {
  if (vs.length > 1 || vs.includes('')) usage(`--${name}= 는 값과 함께 한 번만 준다 — ${vs.map((v) => `--${name}=${v}`).join(' ')}`)
}
const [min, max] = spec.args
const want = min === max ? `${min}개` : max === Infinity ? `${min}개 이상이` : `${min}–${max}개`
if (args.length < min || args.length > max) usage(`${cmd} 의 위치 인자는 ${want}다 — ${args.join(' ') || '(없음)'}`)
spec.run({
  root: roots.length ? roots[0].slice('--root='.length) : '.',
  args,
  values: Object.fromEntries(Object.entries(given).map(([name, [v]]) => [name, v])),
  flags: Object.fromEntries(flagged.map((f) => [f, true])),
})
