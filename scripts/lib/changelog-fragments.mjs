// CHANGELOG 조각 파일의 **하나뿐인 파서** — scripts/changelog.mjs 가 부른다(check-docs 8d · 착지 게이트도 이어서 부른다).
// 조각 `changelog.d/<YYYY-MM-DD>-<slug>.txt` 는 아직 나가지 않은 노트 하나다:
//
//   langs: python go
//   section: Fixed
//   ---
//   본문 한 줄
//
// `langs` 의 어휘는 scripts/lib/deploy-facts.sh 의 `DEPLOY_LANGS` 다(새 언어 목록을 만들지 않는다).
// 표시명(`.NET` 등)만 여기 표가 갖고, 표가 `DEPLOY_LANGS` 와 집합이 다르면 읽기를 거부한다.
import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { BULLET_MAX_BYTES, bytes } from './changelog-ledger.mjs'

export const FRAGMENT_DIR = 'changelog.d'
export const FRAGMENT_NAME_RE = /^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*\.txt$/
export const SECTIONS = ['Added', 'Changed', 'Deprecated', 'Removed', 'Fixed', 'Security']
export const DISPLAY = {
  python: 'Python', dotnet: '.NET', ruby: 'Ruby', node: 'Node', rust: 'Rust',
  java: 'Java', kotlin: 'Kotlin', go: 'Go', php: 'PHP',
}
const FACTS = 'scripts/lib/deploy-facts.sh'

// `DEPLOY_LANGS` 의 순서가 곧 표시 순서다. 못 읽거나 표시명 표와 집합이 다르면 던진다.
export function readDeployLangs(repoRoot) {
  let text
  try {
    text = readFileSync(join(repoRoot, FACTS), 'utf8')
  } catch (e) {
    throw new Error(`${FACTS} 를 읽지 못했다 — ${e.code ?? e.message}`)
  }
  const m = /^DEPLOY_LANGS="([^"]*)"\s*$/m.exec(text)
  if (!m) throw new Error(`${FACTS}: DEPLOY_LANGS="…" 줄이 없다`)
  const order = m[1].split(/\s+/).filter(Boolean)
  const known = Object.keys(DISPLAY)
  const extra = order.filter((l) => !known.includes(l))
  const missing = known.filter((l) => !order.includes(l))
  if (extra.length || missing.length || new Set(order).size !== order.length) {
    throw new Error(`${FACTS} 의 DEPLOY_LANGS 와 표시명 표(DISPLAY)가 다르다 — 표에 없음: [${extra.join(' ')}] · DEPLOY_LANGS 에 없음: [${missing.join(' ')}] · 표시명 표를 함께 고쳐라`)
  }
  return order
}

export const tagOf = (langs, order) => order.filter((l) => langs.includes(l)).map((l) => DISPLAY[l]).join(' · ')
export const compileItem = (langs, body, order) => `- **(${tagOf(langs, order)})** ${body}`
export const renderFragment = ({ langs, section, body }, order) =>
  `langs: ${order.filter((l) => langs.includes(l)).join(' ')}\nsection: ${section}\n---\n${body}\n`

// 읽을 때 줄 끝을 LF 로 맞추고 맨 앞 BOM 을 떼며 끝의 빈 줄은 무시한다. 오류는 모두 `changelog.d/<이름>: ` 로 시작한다.
export function parseFragment(name, text, order) {
  const at = `${FRAGMENT_DIR}/${name}`
  const errors = []
  const err = (m) => errors.push(`${at}: ${m}`)
  if (!FRAGMENT_NAME_RE.test(name)) {
    err('이름이 `<YYYY-MM-DD>-<slug>.txt`(slug 는 소문자·숫자·-)가 아니다')
    return { fragment: null, errors }
  }
  const lines = text.replace(/^\u{FEFF}/u, '').replace(/\r\n/g, '\n').replace(/\n+$/, '').split('\n')
  const cut = lines.indexOf('---')
  if (cut < 0) {
    err('`---` 줄이 없다 — 머리(langs · section) 와 본문을 가르는 줄이다')
    return { fragment: null, errors }
  }
  const head = {}
  for (const line of lines.slice(0, cut)) {
    const m = /^([A-Za-z]+): ?(.*)$/.exec(line)
    if (!m) { err(line === '' ? '머리에 빈 줄이 있다' : `머리 줄이 \`<키>: <값>\` 꼴이 아니다 — ${line}`); continue }
    if (m[1] !== 'langs' && m[1] !== 'section') { err(`모르는 키 \`${m[1]}\` (langs · section 만 둔다)`); continue }
    if (m[1] in head) { err(`키 \`${m[1]}\` 가 겹친다`); continue }
    head[m[1]] = m[2]
  }
  let langs = []
  if (!('langs' in head)) err('`langs:` 가 없다')
  else {
    langs = head.langs.split(' ').filter(Boolean)
    if (head.langs !== langs.join(' ') && head.langs.trim() !== '') err('`langs` 는 공백 하나로 구분한다')
    if (!langs.length) err('`langs` 가 비었다')
    const bad = langs.filter((l) => !order.includes(l))
    if (bad.length) err(`\`langs\` 에 DEPLOY_LANGS 밖의 토큰 — ${bad.join(' ')}`)
    if (new Set(langs).size !== langs.length) err('`langs` 에 같은 토큰이 겹친다')
  }
  if (!('section' in head)) err('`section:` 이 없다')
  else if (!SECTIONS.includes(head.section)) err(`\`section\` 은 ${SECTIONS.join(' · ')} 중 하나다 — ${head.section}`)
  const bodyLines = lines.slice(cut + 1)
  const body = bodyLines[0] ?? ''
  if (bodyLines.length !== 1) err(bodyLines.length === 0 ? '본문이 없다' : `본문은 정확히 한 줄이다 — ${bodyLines.length}줄`)
  else if (body.trim() === '') err('본문이 비었다')
  else if (body !== body.trim()) err('본문의 앞뒤에 공백이 있다')
  if (errors.length) return { fragment: null, errors }
  const n = bytes(compileItem(langs, body, order) + '\n')
  if (n > BULLET_MAX_BYTES) {
    err(`langs 전부로 컴파일한 줄이 ${n}B > ${BULLET_MAX_BYTES}B 다 — 본문을 줄이거나 조각을 나눠라`)
    return { fragment: null, errors }
  }
  return { fragment: { name, langs, section: head.section, body }, errors }
}

// 디렉터리가 없으면 둘 다 빈다. 이름순. 하위 디렉터리 · 규칙 밖 이름은 오류다.
export function readFragmentDir(repoRoot, order) {
  const dir = join(repoRoot, FRAGMENT_DIR)
  if (!existsSync(dir)) return { fragments: [], errors: [] }
  const fragments = []
  const errors = []
  const entries = readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
  for (const e of entries) {
    if (!e.isFile()) {
      errors.push(`${FRAGMENT_DIR}/${e.name}: 조각은 파일이다 — 하위 디렉터리 · 링크는 두지 않는다`)
      continue
    }
    const r = parseFragment(e.name, readFileSync(join(dir, e.name), 'utf8'), order)
    errors.push(...r.errors)
    if (r.fragment) fragments.push(r.fragment)
  }
  return { fragments, errors }
}
