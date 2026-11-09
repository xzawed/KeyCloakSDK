#!/usr/bin/env node
// check-canaries-ran.mjs — 보안 기본값 가드의 **행위 카나리아**가 이 레인 실행에서 **실제로 돌아 통과했는가**를 그 레인의
// 시험 보고서(러너 자신의 출력)로 대조한다.
//
// 왜: `scripts/test/test-security-defaults.sh` 는 카나리아 테스트의 선언이 주석 밖에 정확히 한 번 있는지만 본다. 그래서
// 그 테스트에 skip 표지(`@Disabled` · `@pytest.mark.skip` · `t.Skip` · `#[ignore]` …)를 달거나 레인 명령의 필터로 빼도
// 가드도 레인도 초록이었다(probe.sh SILENT 2026-11-09 — 등록부 `guard-detection-surface-hand-narrowed`). 줄 단위로 skip
// 표지를 막으면 required 체크(`doc-facts`)의 오탐이 되므로, 판정은 레인의 비-required 단계가 보고서로 한다.
//
// 모델:
//  · 카나리아 목록은 가드의 표 함수(AXES)를 **그대로 실행**해 얻는다 — 함수 정의만 떼어 sh 로 부른다(사본을 두지 않는다).
//    가드에서 `sd_canary_ok "$ROOT/…` 를 부르는 자리 수가 AXES 수와 다르면 판정 불가다 — 새 카나리아 축이 이 검사를
//    조용히 비켜 가지 않게.
//  · 카나리아 줄 → 그 줄이 선언한 테스트(RESOLVE) → 보고서 항목. 선언 이름(node·ruby 는 제목 리터럴)이 **카나리아 문자열의
//    자리와 겹쳐야** 한다 — 아니면 같은 줄의 다른 테스트를 카나리아로 읽는다. go 만 본문 줄(표 행 · 단언 호출)을 받고 그
//    줄을 감싼 최상위 `func Test…` 로 간다.
//  · 항목이 없으면 FAIL(이 실행에서 돌지 않았다 — 필터·제외·이름 바뀜), 건너뛰었거나 실패한 항목이 하나라도 있으면 FAIL.
//    매개변수 테스트(항목 여럿)는 전부 통과해야 한다. go 는 최상위 항목이 있어야 하고 서브테스트도 본다.
//  · 보고서 형식은 언어가 정한다(FORMAT) — JUnit XML · TRX · `go test -v` · libtest 출력 · RSpec JSON.
// 판정: 통과 0 · FAIL 1 · 판정 불가 2.
//  ⚠️ 보고서가 **없는** 것은 2 가 아니라 1 이다 — 시험 단계가 보고서를 쓰지 않았다는 바로 그 사건이다(attest 와 같은 이유).
//  판정 불가: 인자 · 가드의 표 함수를 못 찾음 · 호출 자리 수가 AXES 와 다름 · 카나리아 0 개 · 카나리아 줄이 0 개이거나 둘
//  이상 · 그 줄에서 선언을 못 읽음(또는 선언이 카나리아 자리와 안 겹침) · 보고서를 못 읽음(형식) · 보고서에 항목이 0 개.
//
// 사용: node scripts/check-canaries-ran.mjs --lang <언어> --report <파일|디렉터리> [--report …] [--root <저장소>]
//       node scripts/check-canaries-ran.mjs --lang <언어> --list [--root <저장소>]   (해석만 — 보고서 없이)
//       디렉터리는 JUnit(`TEST-*.xml`)·TRX(`*.trx`) 언어에서만 받는다(아래로 훑는다).
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export const GUARD = 'scripts/test/test-security-defaults.sh'

// 가드의 카나리아 표 — 축마다 표 함수와 그 행의 모양. `file` 이 있으면 행은 카나리아 문자열뿐이고 파일은 그 함수가 준다.
export const AXES = [
  { axis: 'nonce', rows: 'sd_nonce_canary', shape: 'file|canary' },
  { axis: 'backoff', rows: 'sd_backoff_canary', shape: 'file|canary' },
  { axis: 'mask', file: 'sd_mask_test', rows: 'sd_mask_canary', shape: 'canary' },
  { axis: 'mask2', file: 'sd_mask2_test', rows: 'sd_mask2_canary', shape: 'canary' },
  { axis: 'token-type', rows: 'sd_token_type_anchor', shape: 'kind|file|canary' },
]
const CALL_SITE = /^[^#]*\bsd_canary_ok\s+"\$ROOT\//

const LANG_RE = /^[a-z][a-z0-9]*$/
export class Usage extends Error {}
export class Unreadable extends Error {}

export function parseArgs(argv) {
  const opt = { lang: null, reports: [], root: REPO, list: false }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const eq = a.startsWith('--') ? a.indexOf('=') : -1
    const name = eq > 0 ? a.slice(0, eq) : a
    if (name === '--list' && eq < 0) opt.list = true
    else if (name === '--lang' || name === '--report' || name === '--root') {
      let v
      if (eq > 0) v = a.slice(eq + 1)
      else {
        v = argv[i + 1]
        if (v === undefined || v.startsWith('--')) throw new Usage(`${name} 에 값이 없다`)
        i++
      }
      if (v === '') throw new Usage(`${name} 이 비었다`)
      if (name === '--lang') opt.lang = v
      else if (name === '--report') opt.reports.push(v)
      else opt.root = resolve(v)
    } else if (a.startsWith('-')) throw new Usage(`모르는 플래그 ${a}`)
    else throw new Usage(`인자가 남는다: ${a}`)
  }
  if (opt.lang === null) throw new Usage('--lang 이 없다')
  if (!LANG_RE.test(opt.lang)) throw new Usage(`언어 이름이 문법 ${LANG_RE} 밖이다: ${opt.lang}`)
  if (!Object.hasOwn(RESOLVE, opt.lang)) throw new Usage(`이 검사가 모르는 언어다: ${opt.lang} — RESOLVE · FORMAT 에 그 언어를 더하라`)
  if (opt.list && opt.reports.length) throw new Usage('--list 는 --report 와 함께 쓰지 않는다')
  if (!opt.list && opt.reports.length === 0) throw new Usage('--report 가 없다')
  return opt
}

// ─── 1. 카나리아 목록 — 가드의 표 함수를 실행한다 ─────────────────────────────────────────────────────
const sq = (s) => `'${s.replace(/'/g, `'\\''`)}'`
function extractScript(axes) {
  const fns = [...new Set(axes.flatMap((a) => (a.file ? [a.file, a.rows] : [a.rows])))]
  const lines = [
    'set -eu',
    'G="$1"; L="$2"',
    `for fn in ${fns.join(' ')}; do`,
    '  def="$(sed -n "/^$fn() {/,/^}/p" "$G")"',
    '  if [ -z "$def" ]; then printf "NOFN\\t%s\\n" "$fn"; exit 3; fi',
    '  eval "$def"',
    'done',
  ]
  for (const a of axes) {
    const ax = sq(a.axis)
    if (a.shape === 'file|canary')
      lines.push(`printf '%s\\n' "$(${a.rows} "$L")" | while IFS= read -r r; do if [ -n "$r" ]; then printf '%s\\t%s\\n' ${ax} "$r"; fi; done`)
    else if (a.shape === 'canary')
      lines.push(
        `f="$(${a.file} "$L")"`,
        `printf '%s\\n' "$(${a.rows} "$L")" | while IFS= read -r c; do if [ -n "$c" ]; then printf '%s\\t%s|%s\\n' ${ax} "$f" "$c"; fi; done`,
      )
    else if (a.shape === 'kind|file|canary')
      lines.push(
        `printf '%s\\n' "$(${a.rows} "$L")" | while IFS='|' read -r k f c; do if [ "$k" = canary ]; then printf '%s\\t%s|%s\\n' ${ax} "$f" "$c"; fi; done`,
      )
    else throw new Error(`모르는 행 모양 ${a.shape}`)
  }
  lines.push('exit 0')
  return lines.join('\n')
}

export function canaries(root, lang, axes = AXES) {
  const guard = join(root, GUARD)
  let text
  try {
    text = readFileSync(guard, 'utf8')
  } catch (e) {
    throw new Unreadable(`가드를 못 읽었다: ${GUARD} (${e.code ?? e.message})`)
  }
  const sites = text.split(/\r?\n/).filter((l) => CALL_SITE.test(l)).length
  if (sites !== axes.length)
    throw new Unreadable(
      `가드에서 \`sd_canary_ok "$ROOT/…\` 를 부르는 자리가 ${sites} 인데 이 검사가 아는 축은 ${axes.length} 다 — ` +
        '새 카나리아 축이면 AXES 에 그 표 함수를 더하라(안 그러면 그 축은 실행 여부를 아무도 안 본다)',
    )
  const r = spawnSync('sh', ['-c', extractScript(axes), 'sh', guard, lang], { encoding: 'utf8' })
  if (r.error) throw new Unreadable(`sh 를 못 띄웠다: ${r.error.message}`)
  const nofn = /^NOFN\t(.+)$/m.exec(r.stdout)
  if (nofn) throw new Unreadable(`가드에 표 함수 \`${nofn[1]}() {\` 가 없다 — 이름이나 모양(줄 머리 정의 · 줄 머리 \`}\`)이 바뀌었나?`)
  if (r.status !== 0) throw new Unreadable(`표 함수를 실행하다 실패했다(rc ${r.status}): ${r.stderr.trim()}`)
  const out = []
  for (const line of r.stdout.split('\n')) {
    if (!line) continue
    const t = line.indexOf('\t')
    const rest = line.slice(t + 1)
    const p = rest.indexOf('|')
    if (t < 0 || p < 0) throw new Unreadable(`표 함수의 행을 못 읽었다: ${JSON.stringify(line)}`)
    out.push({ axis: line.slice(0, t), file: rest.slice(0, p), canary: rest.slice(p + 1) })
  }
  return out
}

// ─── 2. 카나리아 줄 → 테스트 ─────────────────────────────────────────────────────────────────────────
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const indentOf = (l) => l.length - l.trimStart().length
const COMMENT = { python: /^\s*#/, ruby: /^\s*#/, default: /^\s*(\/\/|\/\*|\*)/ }
const overlaps = (a, b) => a[0] < b[1] && b[0] < a[1]

// 카나리아 문자열이 놓인 줄과 그 자리 — 주석 줄은 빼고 정확히 하나여야 한다(가드가 같은 것을 단언한다 — 여기서 어긋나면
// 해석을 믿지 않는다). 경계는 가드와 같다: 앞 글자가 식별자·`.` 이면 다른 이름의 일부다(`xit(` 가 `it(` 를 담는 것).
export function canaryLine(lang, lines, canary, file) {
  const comment = COMMENT[lang] ?? COMMENT.default
  const at = []
  lines.forEach((l, i) => {
    if (comment.test(l)) return
    for (let k = l.indexOf(canary); k >= 0; k = l.indexOf(canary, k + 1)) {
      if (k === 0 || !/[\w.]/.test(l[k - 1])) {
        at.push({ at: i, span: [k, k + canary.length] })
        break
      }
    }
  })
  if (at.length !== 1)
    throw new Unreadable(`${file}: 카나리아 ${JSON.stringify(canary)} 가 주석 밖 ${at.length} 줄에 있다 — 정확히 하나여야 한다`)
  return at[0]
}

// 줄 위로 올라가며 들여쓰기가 더 얕은 클래스 선언을 모은다(바깥 → 안쪽 순서).
function classChain(lines, from, re) {
  const chain = []
  let limit = indentOf(lines[from])
  for (let i = from - 1; i >= 0 && limit > 0; i--) {
    const m = re.exec(lines[i])
    if (m && indentOf(lines[i]) < limit) {
      chain.unshift(m[m.length - 1])
      limit = indentOf(lines[i])
    }
  }
  return chain
}
function packageOf(text, re) {
  const m = re.exec(text)
  return m ? m[1] : null
}
const qualified = (pkg, chain, sep) => {
  if (chain.length === 0) throw new Unreadable('테스트를 담은 클래스를 찾지 못했다')
  return (pkg ? `${pkg}.` : '') + chain.join(sep)
}

// 카나리아 줄의 선언 — 이름 그룹(들 중 처음 잡힌 것)이 카나리아 자리와 겹치는 매치. 없으면 판정 불가.
function declAt(ctx, re, what) {
  const line = ctx.lines[ctx.at]
  const g = new RegExp(re.source, `${re.flags.replace(/[gd]/g, '')}gd`)
  let seen = false
  for (const m of line.matchAll(g)) {
    seen = true
    const gi = m.indices.findIndex((x, i) => i > 0 && x)
    if (gi > 0 && overlaps(m.indices[gi], ctx.span)) return m[gi]
  }
  throw new Unreadable(
    `${ctx.file}:${ctx.at + 1}: ${seen ? `${what} 선언의 이름이 카나리아 자리와 겹치지 않는다 — 같은 줄의 다른 테스트를 카나리아로 읽게 된다` : `카나리아 줄에서 ${what} 선언을 읽지 못했다 — 이 언어는 선언 줄만 읽는다`}`,
  )
}

// 줄의 문자열 리터럴(따옴표 셋) 중 카나리아 자리와 겹치는 첫 것 — node·ruby 의 테스트 제목.
function titleAt(ctx, quotes, what) {
  const line = ctx.lines[ctx.at]
  const re = new RegExp(`([${quotes}])((?:\\\\.|(?!\\1)[^\\\\])*)\\1`, 'g')
  for (const m of line.matchAll(re)) {
    if (overlaps([m.index, m.index + m[0].length], ctx.span)) return { q: m[1], body: m[2].replace(/\\(['"`\\])/g, '$1') }
  }
  throw new Unreadable(`${ctx.file}:${ctx.at + 1}: 카나리아 자리와 겹치는 ${what} 문자열이 없다`)
}

// 제목 → 정규식. `it.each` 의 자리표시(%s · %d · $name …)와 ruby 의 `#{…}` 는 「아무 글자」다.
function titlePattern(title, interp) {
  let s = ''
  for (let i = 0; i < title.length; ) {
    const m = interp.exec(title.slice(i))
    if (m && m.index === 0) {
      s += m[0] === '%%' ? '%' : '.*?'
      i += m[0].length
    } else {
      s += esc(title[i])
      i += 1
    }
  }
  return s
}

const JAVA_CLASS = /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|protected|private|static|final|abstract|sealed|non-sealed)\s+)*(?:class|interface|enum|record)\s+(\w+)/
const KOTLIN_CLASS = /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|protected|open|abstract|sealed|data|inner|enum|annotation)\s+)*(?:class|object|interface)\s+(\w+)/
const DOTNET_CLASS = /^\s*(?:\[[^\]]*\]\s*)*(?:(?:public|internal|private|protected|static|sealed|abstract|partial)\s+)*(?:class|record|struct)\s+(\w+)/
const jvmMatch = (cls, n) => (e) => e.classname === cls && (e.name === n || e.name.startsWith(`${n}(`) || e.name.startsWith(`${n}[`))

// RESOLVE[lang](ctx) → { label, match(entry), top? } · ctx = { file, rel, lines, text, at, span }
export const RESOLVE = {
  java(ctx) {
    const n = declAt(ctx, /\bvoid\s+(\w+)\s*\(/, 'void 메서드')
    const cls = qualified(packageOf(ctx.text, /^\s*package\s+([\w.]+)\s*;/m), classChain(ctx.lines, ctx.at, JAVA_CLASS), '$')
    return { label: `${cls}#${n}`, match: jvmMatch(cls, n) }
  },
  kotlin(ctx) {
    const n = declAt(ctx, /\bfun\s+(?:`([^`]+)`|(\w+))\s*\(/, 'fun')
    const cls = qualified(packageOf(ctx.text, /^\s*package\s+([\w.]+)/m), classChain(ctx.lines, ctx.at, KOTLIN_CLASS), '$')
    return { label: `${cls}#${n}`, match: jvmMatch(cls, n) }
  },
  python(ctx) {
    const n = declAt(ctx, /^\s*(?:async\s+)?def\s+(\w+)\s*\(/, 'def')
    const chain = classChain(ctx.lines, ctx.at, /^\s*class\s+(\w+)/)
    const cls = [ctx.rel.replace(/\.py$/, '').split('/').join('.'), ...chain].join('.')
    return { label: `${ctx.rel}::${[...chain, n].join('::')}`, match: (e) => e.classname === cls && (e.name === n || e.name.startsWith(`${n}[`)) }
  },
  node(ctx) {
    const lit = titleAt(ctx, `'"\``, 'it/test 제목')
    const re = new RegExp(`(?:^| > )${titlePattern(lit.body, /%%|%[sdifjoOc#]|\$[A-Za-z_][\w.]*/)}$`)
    return { label: `${ctx.rel} › ${lit.body}`, match: (e) => e.classname === ctx.rel && re.test(e.name) }
  },
  go(ctx) {
    const { file, lines, at } = ctx
    let n
    if (/^func\s/.test(lines[at])) n = declAt(ctx, /^func\s+(Test\w*)\s*\(/, 'func Test…')
    else {
      // 본문 줄(표 행 · 단언 호출) — 감싼 최상위 함수는 줄 머리 `func ` 다(gofmt). 그것이 Test 함수가 아니면 못 읽는다.
      let i = at
      while (i >= 0 && !/^func\s/.test(lines[i])) i--
      const m = i >= 0 ? /^func\s+(Test\w*)\s*\(/.exec(lines[i]) : null
      if (!m) throw new Unreadable(`${file}:${at + 1}: 카나리아 줄을 감싼 최상위 함수가 Test 함수가 아니다(${i >= 0 ? lines[i].trim() : '없음'})`)
      n = m[1]
    }
    return { label: `${file}:${at + 1} → ${n}`, top: n, match: (e) => e.name === n || e.name.startsWith(`${n}/`) }
  },
  dotnet(ctx) {
    const n = declAt(ctx, /\b(?:void|Task(?:<[^>]*>)?)\s+(\w+)\s*\(/, '메서드(void|Task)')
    const cls = qualified(packageOf(ctx.text, /^\s*namespace\s+([\w.]+)/m), classChain(ctx.lines, ctx.at, DOTNET_CLASS), '+')
    const fq = `${cls}.${n}`
    return { label: fq, match: (e) => e.name === fq || e.name.startsWith(`${fq}(`) }
  },
  php(ctx) {
    const n = declAt(ctx, /\bfunction\s+(\w+)\s*\(/, 'function')
    const tail = `/${ctx.file}`
    const norm = (f) => `/${f.replace(/\\/g, '/').replace(/^\/+/, '')}`
    return {
      label: `${ctx.file}::${n}`,
      match: (e) => typeof e.file === 'string' && norm(e.file).endsWith(tail) && (e.name === n || e.name.startsWith(`${n} with data set `)),
    }
  },
  rust(ctx) {
    const n = declAt(ctx, /\bfn\s+(\w+)\s*[(<]/, 'fn')
    const { rel, file } = ctx
    let re
    let bin
    if (rel.startsWith('src/')) {
      const parts = rel.slice(4).replace(/\.rs$/, '').split('/')
      if (parts.at(-1) === 'mod') parts.pop()
      if (parts.length === 1 && (parts[0] === 'lib' || parts[0] === 'main')) parts.pop()
      re = new RegExp(`^${parts.map((p) => `${esc(p)}::`).join('')}(?:\\w+::)*${esc(n)}$`)
      bin = (b) => /^(?:unittests )?src\/(?:lib|main)\.rs$/.test(b)
    } else if (/^tests\/[^/]+\.rs$/.test(rel)) {
      re = new RegExp(`^(?:\\w+::)*${esc(n)}$`)
      bin = (b) => b === rel
    } else throw new Unreadable(`${file}: rust 카나리아는 src/ 또는 tests/*.rs 에 있어야 한다`)
    return { label: `${rel} → ${n}`, match: (e) => bin(e.binary ?? '') && re.test(e.name) }
  },
  ruby(ctx) {
    const lit = titleAt(ctx, `'"`, 'it 제목')
    const re = new RegExp(`^${titlePattern(lit.body, lit.q === '"' ? /#\{[^}]*\}/ : /(?!)/)}$`)
    const norm = (f) => f.replace(/\\/g, '/').replace(/^\.\//, '')
    return { label: `${ctx.rel} › ${lit.body}`, match: (e) => typeof e.file === 'string' && norm(e.file) === ctx.rel && re.test(e.name) }
  },
}

export function resolveCanary(root, lang, c) {
  const prefix = `${lang}/`
  if (!c.file || !c.file.startsWith(prefix)) throw new Unreadable(`${c.axis}: 카나리아 파일 ${JSON.stringify(c.file)} 이 ${prefix} 밖이다`)
  let text
  try {
    text = readFileSync(join(root, c.file), 'utf8')
  } catch (e) {
    throw new Unreadable(`${c.file}: 못 읽었다(${e.code ?? e.message})`)
  }
  const lines = text.split(/\r?\n/)
  const { at, span } = canaryLine(lang, lines, c.canary, c.file)
  try {
    return RESOLVE[lang]({ file: c.file, rel: c.file.slice(prefix.length), lines, text, at, span })
  } catch (e) {
    if (e instanceof Unreadable && !e.message.startsWith(c.file)) throw new Unreadable(`${c.file}:${at + 1}: ${e.message}`)
    throw e
  }
}

// ─── 3. 보고서 ───────────────────────────────────────────────────────────────────────────────────────
export const FORMAT = { java: 'junit', kotlin: 'junit', python: 'junit', node: 'junit', php: 'junit', dotnet: 'trx', go: 'gotest', rust: 'libtest', ruby: 'rspec' }
const DIR_FILES = { junit: /^TEST-.*\.xml$/, trx: /\.trx$/ }

const decodeXml = (s) =>
  s.replace(/&(#x[0-9a-fA-F]+|#\d+|lt|gt|amp|quot|apos);/g, (_, e) =>
    e === 'lt' ? '<' : e === 'gt' ? '>' : e === 'amp' ? '&' : e === 'quot' ? '"' : e === 'apos' ? "'" : String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)),
  )
function attrs(s) {
  const o = {}
  for (const m of s.matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) o[m[1]] = decodeXml(m[2] ?? m[3])
  return o
}
// CDATA·주석 안의 글자는 마크업이 아니다 — 시험 출력(system-out)에 `<skipped/>` 같은 글자가 실리면 통과한 항목을 건너뛴 것으로 읽는다.
const stripXmlNoise = (x) => x.replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, '').replace(/<!--[\s\S]*?-->/g, '')

export const PARSE = {
  junit(text) {
    const x = stripXmlNoise(text)
    if (!/<testsuites?\b/.test(x)) throw new Unreadable('JUnit XML 이 아니다(<testsuite> 없음)')
    const out = []
    for (const m of x.matchAll(/<testcase\b([^>]*?)(?:\/>|>([\s\S]*?)<\/testcase>)/g)) {
      const a = attrs(m[1])
      const body = m[2] ?? ''
      const status = /<(failure|error)\b/.test(body) ? 'failed' : /<skipped\b/.test(body) ? 'skipped' : 'passed'
      out.push({ classname: a.classname ?? '', name: a.name ?? '', file: a.file, status })
    }
    return out
  },
  trx(text) {
    if (!/<TestRun\b/.test(text)) throw new Unreadable('TRX 가 아니다(<TestRun> 없음)')
    const out = []
    for (const m of text.matchAll(/<UnitTestResult\b([^>]*?)\/?>/g)) {
      const a = attrs(m[1])
      const o = a.outcome ?? ''
      out.push({ name: a.testName ?? '', status: o === 'Passed' ? 'passed' : o === 'NotExecuted' ? 'skipped' : 'failed' })
    }
    return out
  },
  gotest(text) {
    const out = []
    for (const m of text.matchAll(/^\s*--- (PASS|FAIL|SKIP): (\S+) \(/gm))
      out.push({ name: m[2], status: m[1] === 'PASS' ? 'passed' : m[1] === 'SKIP' ? 'skipped' : 'failed' })
    return out
  },
  libtest(text) {
    const out = []
    let binary = ''
    for (const line of text.split(/\r?\n/)) {
      const run = /^\s*Running (unittests )?(\S+)/.exec(line)
      if (run) {
        binary = (run[1] ?? '') + run[2].replace(/\\/g, '/')
        continue
      }
      const t = /^test (\S+) \.\.\. (ok|ignored|FAILED)\b/.exec(line)
      if (t) out.push({ binary, name: t[1], status: t[2] === 'ok' ? 'passed' : t[2] === 'ignored' ? 'skipped' : 'failed' })
    }
    return out
  },
  rspec(text) {
    let j
    try {
      j = JSON.parse(text)
    } catch (e) {
      throw new Unreadable(`RSpec JSON 이 아니다(${e.message})`)
    }
    if (!j || !Array.isArray(j.examples)) throw new Unreadable('RSpec JSON 에 examples 배열이 없다')
    return j.examples.map((x) => ({ file: x.file_path, name: x.description ?? '', status: x.status === 'passed' ? 'passed' : x.status === 'pending' ? 'skipped' : 'failed' }))
  },
}

function walk(dir, re, acc) {
  for (const d of readdirSync(dir, { withFileTypes: true })) {
    if (d.name === '.git' || d.name === 'node_modules') continue
    const p = join(dir, d.name)
    if (d.isDirectory()) walk(p, re, acc)
    else if (re.test(d.name)) acc.push(p)
  }
  return acc
}

// → { entries, missing:[path] } · 읽지 못하면 Unreadable
export function loadReports(lang, paths) {
  const fmt = FORMAT[lang]
  const files = []
  const missing = []
  for (const p of paths) {
    if (!existsSync(p)) {
      missing.push(p)
      continue
    }
    if (statSync(p).isDirectory()) {
      const re = DIR_FILES[fmt]
      if (!re) throw new Unreadable(`${lang} 의 보고서(${fmt})는 파일로 준다 — 디렉터리를 받지 않는다: ${p}`)
      const found = walk(p, re, [])
      if (found.length === 0) missing.push(`${p} 아래 ${re}`)
      files.push(...found)
    } else files.push(p)
  }
  const entries = []
  for (const f of files) {
    let text
    try {
      text = readFileSync(f, 'utf8')
    } catch (e) {
      throw new Unreadable(`${f}: 못 읽었다(${e.code ?? e.message})`)
    }
    try {
      entries.push(...PARSE[fmt](text))
    } catch (e) {
      if (e instanceof Unreadable) throw new Unreadable(`${f}: ${e.message}`)
      throw e
    }
  }
  return { entries, missing }
}

// ─── 4. 판정 ─────────────────────────────────────────────────────────────────────────────────────────
// → { ok, why }
export function judge(t, entries) {
  const hit = entries.filter(t.match)
  if (hit.length === 0) return { ok: false, why: '보고서에 없다 — 이 실행에서 돌지 않았다(필터 · 제외 · 이름 바뀜)' }
  if (t.top && !hit.some((e) => e.name === t.top)) return { ok: false, why: `최상위 ${t.top} 가 보고서에 없다(서브테스트만 있다)` }
  const skipped = hit.filter((e) => e.status === 'skipped').length
  const failed = hit.filter((e) => e.status === 'failed').length
  if (skipped) return { ok: false, why: `건너뛰었다 — ${skipped}/${hit.length} 항목이 skip` }
  if (failed) return { ok: false, why: `실패했다 — ${failed}/${hit.length} 항목` }
  return { ok: true, why: `${hit.length} 통과` }
}

function main() {
  let opt
  try {
    opt = parseArgs(process.argv.slice(2))
  } catch (e) {
    if (e instanceof Usage) {
      console.error(`::error::check-canaries-ran: ${e.message}`)
      process.exit(2)
    }
    throw e
  }
  const unread = (msg) => {
    console.error(`::error::check-canaries-ran(${opt.lang}) 판정 불가: ${msg}`)
    process.exit(2)
  }
  let targets
  try {
    const list = canaries(opt.root, opt.lang)
    if (list.length === 0) unread(`가드의 표에서 ${opt.lang} 카나리아를 하나도 얻지 못했다 — 공허하다`)
    targets = list.map((c) => ({ c, t: resolveCanary(opt.root, opt.lang, c) }))
  } catch (e) {
    if (e instanceof Unreadable) unread(e.message)
    throw e
  }
  if (opt.list) {
    for (const { c, t } of targets) console.log(`${c.axis.padEnd(10)} ${t.label}`)
    console.log(`canaries ${opt.lang}: ${targets.length}`)
    return
  }
  let rep
  try {
    rep = loadReports(opt.lang, opt.reports.map((p) => resolve(p)))
  } catch (e) {
    if (e instanceof Unreadable) unread(e.message)
    throw e
  }
  if (rep.missing.length) {
    for (const m of rep.missing) console.error(`::error::check-canaries-ran(${opt.lang}): 보고서가 없다 — ${m} (시험 단계가 보고서를 쓰지 않았다)`)
    console.log(`canaries-ran ${opt.lang}: 카나리아 ${targets.length} · 보고서 없음 → FAIL`)
    process.exit(1)
  }
  if (rep.entries.length === 0) unread('보고서에서 테스트 항목을 하나도 읽지 못했다 — 형식이 바뀌었나?')
  let fails = 0
  for (const { c, t } of targets) {
    const v = judge(t, rep.entries)
    if (v.ok) console.log(`ok    ${c.axis.padEnd(10)} ${t.label} — ${v.why}`)
    else {
      fails++
      console.log(`FAIL  ${c.axis.padEnd(10)} ${t.label} — ${v.why}`)
      console.error(`::error file=${c.file}::보안 카나리아(${c.axis})가 이 실행에서 통과하지 않았다: ${t.label} — ${v.why}`)
    }
  }
  console.log(`canaries-ran ${opt.lang}: 카나리아 ${targets.length} · 통과 ${targets.length - fails} · FAIL ${fails} (보고서 항목 ${rep.entries.length})`)
  process.exit(fails ? 1 : 0)
}

// 진입 가드 — 형제 가드와 같은 꼴(경로를 그대로 비교하면 Windows 의 argv 경로 표기에서 어긋난다).
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop())) {
  try {
    main()
  } catch (e) {
    console.error(`::error::판정 불가 — 예상하지 못한 오류: ${e.stack ?? e}`)
    process.exit(2)
  }
}
