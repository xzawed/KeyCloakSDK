// CHANGELOG 물결 — 대기 조각(changelog.d/)을 릴리스 한 번(물결)의 날짜 절로 컴파일하고, 그 글을 **독립으로** 대조한다.
// scripts/changelog.mjs 가 부른다(preview · 이어서 release · check). 문법은 셋이 나눠 갖는다 — 원장의 꼴(changelog-ledger.mjs) ·
// 조각 파일과 언어 표(changelog-fragments.mjs) · 물결(여기).
//
// 물결 = { date: 'YYYY-MM-DD', versions: { <lang>: '<판>' } }. 컴파일 규칙:
//   - 판이 같은 언어끼리 한 절 `## [<판>] - <날짜> (<표시명 · …>)` — 절 순서는 그 절 첫 언어의 DEPLOY_LANGS 순서
//   - 절이 둘 이상이면 맨 앞에 공통 절 `## [물결] - <날짜> (<표시명> <판> · …)`
//   - 조각마다 S = langs ∩ 물결 언어(비면 건너뛴다) — S 의 판이 하나면 그 언어 절, 둘 이상이면 공통 절에 compileItem(S, 본문)
//   - 블록 = 제목 · 생성 문단 · `### <section>`(SECTIONS 순, 빈 절은 쓰지 않는다, 항목은 조각 이름순) — 빈 줄 하나로 끝난다
//   - 생성 문단 — 공통 절과 절이 하나뿐인 물결은 물결 머리말 자리, 공통 절 아래 언어 절은 공통 절 가리킴 + 손글 자리
// ⚠️ 글은 문자열 안의 `\n` 으로만 만든다 — 이 저장소의 .mjs 는 체크아웃에서 CRLF 가 될 수 있어, 여러 줄 리터럴은 바이트가 갈린다.
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { DISPLAY, FRAGMENT_DIR, SECTIONS, compileItem, readDeployLangs, readFragmentDir, tagOf } from './changelog-fragments.mjs'
import { BULLET_MAX_BYTES, HAND_MARK, ROOT_FILE, UNRELEASED_POINTER, bytes, itemsOf, parseLedgerFile } from './changelog-ledger.mjs'
import { DOC_TRIPWIRE_BYTES } from './doc-tripwire.mjs'

const COMMON = '물결'
const WAVE_INTRO = `${HAND_MARK} 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.`
const HAND_NOTE = `${HAND_MARK} 이 절의 판 종류 · 공개 API 변경 수 · 같은 번호 경고를 쓴다.`
const commonPointer = (date) => `같은 물결의 머리말과 여러 절에 걸친 항목은 위 \`[${COMMON}] - ${date}\` 절에 있습니다.`

// 물결의 날짜 — `YYYY-MM-DD` 꼴이고 달력에 있는 날이다(2026-02-30 은 아니다). CLI 의 `--date=` 도 이것으로 본다.
export function isWaveDate(s) {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false
  const t = Date.parse(`${s}T00:00:00Z`)
  return !Number.isNaN(t) && new Date(t).toISOString().slice(0, 10) === s
}
// 물결 자체의 결함(부르는 쪽의 잘못) — compileWave 는 던지고, verifyWave 는 오류로 돌려준다.
function waveProblems(wave, order) {
  const out = []
  if (!isWaveDate(wave?.date)) out.push(`물결 날짜가 있는 날짜의 YYYY-MM-DD 가 아니다 — ${wave?.date}`)
  const langs = Object.keys(wave?.versions ?? {})
  if (!langs.length) out.push('물결에 언어가 없다')
  for (const l of langs) {
    if (!order.includes(l)) out.push(`물결 언어 ${l} 는 DEPLOY_LANGS 밖이다`)
    else if (typeof wave.versions[l] !== 'string' || wave.versions[l] === '') out.push(`${l} 의 판이 비었다`)
  }
  return out
}

const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
// 블록 안의 `### <section>` 절들 — SECTIONS 순, 항목이 없는 절은 쓰지 않는다. items 는 이미 조각 이름순이다.
const renderSections = (items) =>
  SECTIONS.map((s) => {
    const lines = items.filter((i) => i.section === s).map((i) => i.line)
    return lines.length ? `### ${s}\n${lines.join('\n')}\n\n` : ''
  }).join('')
const renderBlock = (b) => `${b.heading}\n\n${b.paras.map((p) => `${p}\n\n`).join('')}${renderSections(b.items)}`

// → { text, updates: [{ name, langs }] } — updates 는 이 물결이 내보낸 조각마다 남는 langs(DEPLOY_LANGS 순)다. 비면 지울 조각이다.
// 물결에 걸리지 않은 조각은 updates 에 없다(그대로 둔다).
export function compileWave(fragments, wave, order) {
  const problems = waveProblems(wave, order)
  if (problems.length) throw new Error(`compileWave: ${problems.join(' · ')}`)
  const shipped = (l) => Object.hasOwn(wave.versions, l)
  const ver = (l) => wave.versions[l]
  const langs = order.filter(shipped)
  const groups = new Map() // 판 → 언어들 — 넣는 차례가 곧 「그 절 첫 언어의 DEPLOY_LANGS 순서」다
  for (const l of langs) groups.set(ver(l), [...(groups.get(ver(l)) ?? []), l])
  const multi = groups.size > 1
  const common = multi
    ? { heading: `## [${COMMON}] - ${wave.date} (${langs.map((l) => `${DISPLAY[l]} ${ver(l)}`).join(' · ')})`, paras: [WAVE_INTRO], items: [] }
    : null
  const sections = new Map()
  for (const [v, ls] of groups) {
    sections.set(v, {
      heading: `## [${v}] - ${wave.date} (${tagOf(ls, order)})`,
      paras: multi ? [commonPointer(wave.date), HAND_NOTE] : [WAVE_INTRO],
      items: [],
    })
  }
  const updates = []
  for (const f of [...fragments].sort(byName)) {
    const S = order.filter((l) => f.langs.includes(l) && shipped(l))
    if (!S.length) continue
    const vs = new Set(S.map(ver))
    const home = vs.size === 1 ? sections.get([...vs][0]) : common
    home.items.push({ section: f.section, line: compileItem(S, f.body, order) })
    updates.push({ name: f.name, langs: order.filter((l) => f.langs.includes(l) && !shipped(l)) })
  }
  const blocks = common ? [common, ...sections.values()] : [...sections.values()]
  return { text: blocks.map(renderBlock).join(''), updates }
}

// 대기 조각 전부를 지금의 `[Unreleased]` 꼴로 — 태그는 langs 전부.
export const renderPreview = (fragments, order) =>
  `## [Unreleased]\n\n${renderSections([...fragments].sort(byName).map((f) => ({ section: f.section, line: compileItem(f.langs, f.body, order) })))}`

// ⚠️ **독립 대조다** — compileWave 의 묶기 식(판으로 묶기 · 조각의 절 고르기)도, 그 식이 쓰는 도우미(compileItem · tagOf ·
// renderSections · renderBlock)도 부르지 않는다. 같은 식을 부르면 그 버그를 함께 놓친다. 기대는 조각 · 물결 · 언어 순서에서만
// 세우고, 글은 원장 파서(parseLedgerFile · itemsOf)로 다시 읽어 여섯을 모두 본다(오류는 `물결 대조 <n>: ` 로 시작한다):
//   1 머리말이 비고, 모든 블록이 `## [<판>] - <물결의 날짜> (<…>)` 릴리스 절이다
//   2 항목은 넷뿐 — 블록 제목 · `### <SECTIONS>` · 생성 문단(그 절 자리의 것, 첫 `###` 앞) · `### ` 아래의 `- **(태그)** 본문`
//   3 항목마다 bytes ≤ BULLET_MAX_BYTES — 8d 와 같은 잼이라 제목 줄도 잰다(긴 판 문자열의 제목이 8d 에서 처음 걸리지 않게)
//   4 공통 절이 아닌 블록 — 괄호 안 언어 = 물결에서 대괄호 판인 언어 전부, 모으면 물결 언어 전부이고 겹치지 않는다
//   5 판이 둘 이상이면 첫 블록만 공통 절이고 괄호 안은 물결 언어 전부의 `<표시명> <판>` — 판이 하나면 공통 절이 없다
//   6 기대 다중집합(조각마다 S 가 비지 않으면 `<판 또는 물결> | <section> | <S> | <본문>` 하나)과 글의 항목이 같다
const HEADING_RE = /^## \[([^\]]+)\] - (\d{4}-\d{2}-\d{2}) \(([^()]+)\)$/
const BULLET_RE = /^- \*\*\(([^()\n]+)\)\*\* ([^\n]+)$/
export function verifyWave(fragments, wave, text, order) {
  const problems = waveProblems(wave, order)
  if (problems.length) return problems.map((m) => `물결 대조: ${m}`)
  const errors = []
  const E = (n, m) => errors.push(`물결 대조 ${n}: ${m}`)
  const at = (h) => `「${h.length > 64 ? `${h.slice(0, 64)}…` : h}」`
  const cut = (s) => `「${s.length > 48 ? `${s.slice(0, 48)}…` : s}」`
  const shipped = (l) => Object.hasOwn(wave.versions, l)
  const ver = (l) => wave.versions[l]
  const waveLangs = order.filter(shipped)
  const multi = new Set(waveLangs.map(ver)).size > 1
  const token = new Map(order.map((l) => [DISPLAY[l], l]))
  const pointer = commonPointer(wave.date)
  const label = new Map([[WAVE_INTRO, '물결 머리말 자리'], [pointer, '공통 절 가리킴'], [HAND_NOTE, '손글 자리']])
  const key = (place, section, langs, body) => `${place} | ${section} | ${langs.join(' ')} | ${body}`

  // 1 — 머리말 · 블록 종류 · 제목 꼴과 날짜
  const { head, order: all } = parseLedgerFile(text)
  if (head !== '') E(1, `물결 글에 머리말이 있다 ${cut(head.trim())} — 물결은 \`## \` 절로만 이뤄진다`)
  const blocks = []
  for (const b of all) {
    const m = HEADING_RE.exec(b.heading)
    if (b.kind !== 'release' || !m) {
      E(1, `${at(b.heading)} — 물결의 절은 \`## [<판>] - <날짜> (<표시명 · …>)\` 꼴이다`)
      continue
    }
    if (m[2] !== wave.date) E(1, `${at(b.heading)} — 날짜가 물결의 날짜(${wave.date})가 아니다`)
    blocks.push({ ...b, bracket: m[1], paren: m[3], common: m[1] === COMMON })
  }

  // 2 · 3 — 블록마다 항목을 차례로
  const actual = []
  for (const b of blocks) {
    let section = null
    const paras = []
    for (const [i, item] of itemsOf(b.text).entries()) {
      const n = bytes(item)
      if (n > BULLET_MAX_BYTES) E(3, `${at(b.heading)} — 항목 ${n}B > ${BULLET_MAX_BYTES}B ${cut(item.trim())}`)
      if (i === 0) continue // 블록 제목 — itemsOf 는 제목 줄을 그 줄 하나로 낸다
      const t = item.replace(/\n$/, '')
      if (t.startsWith('#')) {
        const s = /^### (.+)$/.exec(t)?.[1]
        if (SECTIONS.includes(s)) section = s
        else E(2, `${at(b.heading)} — 모르는 제목 줄 ${cut(t)} — \`### \` 은 ${SECTIONS.join(' · ')} 뿐이다`)
      } else if (label.has(t)) {
        if (section) E(2, `${at(b.heading)} — 생성 문단은 첫 \`###\` 앞에 둔다 ${cut(t)}`)
        else paras.push(t)
      } else {
        const m = BULLET_RE.exec(t)
        if (!m) E(2, `${at(b.heading)} — 모르는 문단이거나 꼴이 다른 항목 ${cut(t)}`)
        else if (!section) E(2, `${at(b.heading)} — \`###\` 앞의 목록 항목 ${cut(t)}`)
        else {
          const langs = m[1].split(' · ').map((x) => token.get(x))
          if (langs.includes(undefined)) E(2, `${at(b.heading)} — 태그에 모르는 표시명이 있다 ${cut(t)}`)
          else actual.push(key(b.common ? COMMON : b.bracket, section, langs.sort((x, y) => order.indexOf(x) - order.indexOf(y)), m[2]))
        }
      }
    }
    const want = b.common || !multi ? [WAVE_INTRO] : [pointer, HAND_NOTE]
    if (paras.join('\n') !== want.join('\n'))
      E(2, `${at(b.heading)} — 생성 문단이 이 절의 자리와 다르다 — 기대 ${want.map((p) => label.get(p)).join(' · ')}, 글 ${paras.map((p) => label.get(p)).join(' · ') || '없음'}`)
  }

  // 4 — 언어 절이 물결 언어를 판대로 나눠 갖는다
  const home = new Map() // 언어 → 그 언어가 든 절의 제목
  for (const b of blocks.filter((x) => !x.common)) {
    const ls = []
    for (const x of b.paren.split(' · ')) {
      const l = token.get(x)
      if (l === undefined) E(4, `${at(b.heading)} — 괄호 안의 모르는 표시명 「${x}」`)
      else ls.push(l)
    }
    for (const l of ls) {
      if (!shipped(l)) E(4, `${at(b.heading)} — ${DISPLAY[l]} 은 이 물결이 내보내지 않는다`)
      else if (ver(l) !== b.bracket) E(4, `${at(b.heading)} — ${DISPLAY[l]} 의 물결 판은 ${ver(l)} 다`)
      if (home.has(l)) E(4, `${DISPLAY[l]} 이 언어 절 둘에 있다 — ${at(home.get(l))} · ${at(b.heading)}`)
      else home.set(l, b.heading)
    }
    const want = waveLangs.filter((l) => ver(l) === b.bracket)
    if (want.length && (want.length !== ls.length || want.some((l) => !ls.includes(l))))
      E(4, `${at(b.heading)} — 판 ${b.bracket} 의 언어 전부(${want.map((l) => DISPLAY[l]).join(' · ')})가 아니다`)
  }
  for (const l of waveLangs) if (!home.has(l)) E(4, `물결 언어 ${DISPLAY[l]}(${ver(l)}) 의 언어 절이 없다`)

  // 5 — 공통 절
  const commons = blocks.filter((b) => b.common)
  if (multi) {
    if (!blocks[0]?.common) E(5, `판이 둘 이상인 물결은 첫 절이 공통 절 \`## [${COMMON}] - ${wave.date} (…)\` 이다`)
    for (const b of commons) if (b !== blocks[0]) E(5, `${at(b.heading)} — 공통 절은 맨 앞에 하나만 둔다`)
    const want = waveLangs.map((l) => `${DISPLAY[l]} ${ver(l)}`).join(' · ')
    if (blocks[0]?.common && blocks[0].paren !== want)
      E(5, `${at(blocks[0].heading)} — 공통 절의 괄호 안은 물결 언어 전부의 \`<표시명> <판>\` 이다 — 기대 (${want})`)
  } else {
    for (const b of commons) E(5, `${at(b.heading)} — 판이 하나인 물결에는 공통 절이 없다`)
  }

  // 6 — 항목 다중집합: 조각에서 세운 기대 − 글에서 읽은 것
  const count = new Map()
  for (const f of fragments) {
    const S = order.filter((l) => f.langs.includes(l) && shipped(l))
    if (!S.length) continue
    const vs = new Set(S.map(ver))
    const k = key(vs.size === 1 ? [...vs][0] : COMMON, f.section, S, f.body)
    count.set(k, (count.get(k) ?? 0) + 1)
  }
  for (const k of actual) count.set(k, (count.get(k) ?? 0) - 1)
  for (const [k, n] of count) {
    if (n > 0) E(6, `빠진 항목${n > 1 ? ` ${n}개` : ''} — ${k}`)
    else if (n < 0) E(6, `남는 항목${n < -1 ? ` ${-n}개` : ''} — ${k}`)
  }
  return errors
}

// ---- 트리 검사(check · preview --stats) ----
// 시험 물결 열 — 판 `0.0.1`… 은 모두 다르고 날짜는 정해둔 하나다. 조각이 자기 langs 를 내보내는 물결마다 정확히 한 번, 그 밖에는 0 번 나오는지는
// verifyWave 의 6 이 잰다(아홉 언어 물결 하나 + 한 언어씩 아홉 — 한 언어 물결이 「그 언어만 나가는 릴리스」를 덮는다).
const TEST_DATE = '2000-01-01'
const WARN_NUM = 3 // 경고선 = 전역 상한의 3/4 — 아홉 언어 물결로 내면 루트가 이 선을 넘는 대기 노트
const WARN_DEN = 4
export const percentOf = (n) => Math.floor((n * 100) / DOC_TRIPWIRE_BYTES) // check-docs 8c 의 경고가 쓰는 식

// → { errors, warnings, stats: { perLang: { <lang>: { count, bytes } }, projected, tripwire } }.
// count = 그 언어를 langs 에 든 조각 수 · bytes = 그 언어 한 언어 물결 글의 바이트 · projected = 루트 머리말 + 포인터 블록 + 아홉 언어 물결의 바이트.
// `changelog.d/` 가 없으면 빈 결과다(오류 · 경고 없음, 수는 0). deploy-facts.sh 를 못 읽으면 던진다(부르는 쪽이 먼저 읽어 rc 1 로 바꾼다).
// ⚠️ 루트 `[Unreleased]` 의 고정 문단은 여기서 보지 않는다 — 그것은 CLI check 의 몫이다(8d 도 같은 isUnreleasedPointer 를 부른다).
export function checkFragmentTree(repoRoot) {
  const order = readDeployLangs(repoRoot)
  const zero = Object.fromEntries(order.map((l) => [l, { count: 0, bytes: 0 }]))
  const stats = { perLang: zero, projected: 0, tripwire: DOC_TRIPWIRE_BYTES }
  if (!existsSync(join(repoRoot, FRAGMENT_DIR))) return { errors: [], warnings: [], stats }
  const { fragments, errors: grammar } = readFragmentDir(repoRoot, order)
  const errors = [...grammar]
  const trial = (label, versions) => {
    const wave = { date: TEST_DATE, versions }
    const { text } = compileWave(fragments, wave, order)
    for (const e of verifyWave(fragments, wave, text, order)) errors.push(`changelog: 시험 물결(${label}) — ${e}`)
    return text
  }
  const nine = trial('아홉 언어', Object.fromEntries(order.map((l, i) => [l, `0.0.${i + 1}`])))
  const perLang = {}
  for (const l of order) {
    perLang[l] = { count: fragments.filter((f) => f.langs.includes(l)).length, bytes: bytes(trial(`${l} 하나`, { [l]: '0.0.1' })) }
  }
  const file = join(repoRoot, ROOT_FILE)
  const head = existsSync(file) ? parseLedgerFile(readFileSync(file, 'utf8').replace(/\r\n/g, '\n')).head : ''
  const projected = bytes(`${head}## [Unreleased]\n\n${UNRELEASED_POINTER}\n\n${nine}`)
  const warnings = []
  if (projected * WARN_DEN >= DOC_TRIPWIRE_BYTES * WARN_NUM)
    warnings.push(`대기 노트를 아홉 언어 물결로 내면 루트가 ${projected}B — 전역 상한 ${DOC_TRIPWIRE_BYTES}B 의 ${percentOf(projected)}%`)
  return { errors, warnings, stats: { perLang, projected, tripwire: DOC_TRIPWIRE_BYTES } }
}
