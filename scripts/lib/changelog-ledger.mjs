// CHANGELOG 원장의 **하나뿐인 파서** — check-docs 검사 8d 와 scripts/changelog-rotate.mjs 가 같이 쓴다.
// 둘이 따로 파싱하면 「회전은 옳게 했는데 검사가 다르게 읽는다」가 생긴다 — 그래서 여기 하나다.
//
// 원장은 둘로 산다:
//   CHANGELOG.md            — 머리말 · `## [Unreleased]` · 최신 날짜의 릴리스 절(루트 상한 안)
//   changelog/<YYYY-MM>.md  — 그보다 오래된 절을 날짜 그대로 옮긴 월별 보관본(지우지 않는다)
//
// ⚠️ 두 상한은 **사람 판정**이다(2026-10-28). 근거 실측: 10 월 전 항목 121 개 p95 1,005 B ·
// 10 월 항목 73 개 중앙값 1,445 B(최대 5,198 B) — 커진 것은 절 수가 아니라 항목 하나의 길이였다.
// 루트 상한을 넘으면 나가는 길은 **회전**(옮기기)뿐이고 상한을 올리는 분기는 없다 — CHANGELOG 를
// 예산에서 뺀 이유(「릴리스마다 올리게 되어 고무도장이 된다」, check-docs 8c)에 대한 답이 그것이다.
export const ROOT_FILE = 'CHANGELOG.md'
export const VOLUME_DIR = 'changelog'
export const VOLUME_RE = /^changelog\/(\d{4}-\d{2})\.md$/
export const ROOT_MAX_BYTES = 64 * 1024
export const BULLET_MAX_BYTES = 1024
export const INDEX_PREFIX = '> 이전 릴리스(월별 보관본): '

const UNRELEASED = '## [Unreleased]'
const RELEASE_RE = /^## \[[^\]]+\] - ((\d{4}-\d{2})-\d{2})(?:[\s(].*)?$/

export const bytes = (s) => Buffer.byteLength(s, 'utf8')

// 줄 끝을 보존하며 `## ` 경계에서 자른다. head + 모든 block.text 를 이으면 **원문과 바이트까지 같다**
// (회전이 그 성질에 기대므로 `assertSplitIdentity` 가 매번 확인한다).
function split(text) {
  const lines = text.split(/(?<=\n)/)
  let head = ''
  const blocks = []
  for (const line of lines) {
    if (line.startsWith('## ')) blocks.push({ heading: line.replace(/\r?\n$/, ''), text: line })
    else if (blocks.length) blocks[blocks.length - 1].text += line
    else head += line
  }
  return { head, blocks }
}
function classify(b) {
  const m = RELEASE_RE.exec(b.heading)
  if (m) return { ...b, kind: 'release', date: m[1], month: m[2] }
  if (b.heading === UNRELEASED) return { ...b, kind: 'unreleased' }
  return { ...b, kind: 'unknown' }
}
export function parseLedgerFile(text) {
  const { head, blocks } = split(text)
  const all = blocks.map(classify)
  return {
    head,
    unreleased: all.filter((b) => b.kind === 'unreleased'),
    releases: all.filter((b) => b.kind === 'release'),
    unknown: all.filter((b) => b.kind === 'unknown'),
    order: all, // 파일 순서 그대로
  }
}
export function assertSplitIdentity(text) {
  const { head, blocks } = split(text)
  if (head + blocks.map((b) => b.text).join('') !== text) throw new Error('ledger split is not byte-identical')
}

// 보관본은 한 단계 아래 디렉터리라 상대 링크에 `../` 를 붙인다. 되돌리기는 정확히 그 하나만 뗀다 —
// 회전은 각 절에서 `fromVolume(toVolume(x)) === x` 를 확인하고, 아니면 멈춘다(fail-closed).
const LINK = /\]\(([^)\s]+)\)/g
const isRelPath = (t) =>
  !/^[a-z][a-z0-9+.-]*:/i.test(t) && !t.startsWith('#') && !t.startsWith('/') && (t.includes('/') || /\.[A-Za-z0-9]+(#.*)?$/.test(t))
export const toVolume = (s) => s.replace(LINK, (m, t) => (isRelPath(t) ? `](../${t})` : m))
export const fromVolume = (s) => s.replace(LINK, (m, t) => (t.startsWith('../') && isRelPath(t.slice(3)) ? `](${t.slice(3)})` : m))

export function volumeHead(month) {
  return (
    `# Changelog — ${month}\n\n` +
    `${month} 에 나간 릴리스 절을 [CHANGELOG.md](../CHANGELOG.md) 에서 날짜 그대로 옮겨 둔 보관본입니다. ` +
    `내용은 바꾸지 않았고 상대 링크만 이 디렉터리 기준으로 고쳤습니다. 최신 릴리스는 [CHANGELOG.md](../CHANGELOG.md) 에 있습니다.\n\n`
  )
}
export const volumePath = (month) => `${VOLUME_DIR}/${month}.md`
export const indexLine = (monthsDesc) =>
  INDEX_PREFIX + monthsDesc.map((m) => `[${m}](${volumePath(m)})`).join(' · ') + '\n'

// 항목 = 원장 글의 단위, 셋이다. ① 목록 항목 — 0 열 표지(`- ` `* ` `+ ` `1. ` `1) `)부터 빈 줄·제목·다음
// 항목 전까지의 모든 줄(들여쓴 줄도, 들여쓰지 않은 「게으른 이어짐」 줄도). ② 표지 없는 문단. ③ 제목 줄
// 하나하나(블록 자신의 제목 포함). ⚠️ 하나라도 빼면 그 모양으로 긴 글이 상한을 지나갔다 — `* ` 표지·
// 게으른 이어짐·문단(PM 적대 패스), 제목 줄·새 절의 머리말 문단(독립 레그 2 차·PM 2 차 패스, 2026-10-28).
const ITEM_START = /^(?:[-*+]|\d+[.)])[ \t]/
export function itemsOf(blockText) {
  const out = []
  let cur = null
  const flush = () => {
    if (cur !== null) out.push(cur)
    cur = null
  }
  for (const line of blockText.split(/(?<=\n)/)) {
    if (line.startsWith('#')) {
      flush()
      out.push(line)
    } else if (/^\s*$/.test(line)) flush()
    else if (ITEM_START.test(line)) {
      flush()
      cur = line
    } else if (cur !== null) cur += line
    else cur = line
  }
  flush()
  return out
}
