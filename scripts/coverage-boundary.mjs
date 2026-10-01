#!/usr/bin/env node
// coverage-boundary.mjs — 커버리지 omit(「네트워크 경계」) 목록의 SSOT ↔ 사본 조인 가드.
//
// 왜: 아홉 언어가 단위 커버리지 게이트에서 경계 파일을 빼고, 그 목록이 SonarCloud · 하네스 ·
// 규칙 문서로 **손으로 복사**돼 있었다. 대조하는 가드가 0 건이라 사본이 이미 갈라져 있었다
// (등록부 `coverage-omit-no-ssot`). 이 파일이 그 조인이다.
//
// 모델 — 무엇을 무엇과 비교하는가:
//  · SSOT 는 언어당 하나, **그 자리를 고치면 게이트가 재는 것이 바뀌는** 설정이다(아래 `SSOT`).
//  · 비교 단위는 문자열이 아니라 **펼친 파일 집합**이다. `git ls-files` 의 제품 소스(테스트 제외)
//    위에서 각 도구의 매칭 의미론으로 펼친다 — 글롭·클래스 패턴·정규식은 문자열로 비교가 안 된다.
//    게이트가 **통째로** 안 재는 파일(jacoco.skip 모듈 · vitest/phpunit `include` 밖)도 omit 에 든다.
//    모델하지 않는 손잡이(coverage.py `include` · coverlet `ExcludeByAttribute` · 둘째 `<source>` …)는 FAIL.
//  · 클래스 단위 SSOT(java JaCoCo · kotlin Kover · dotnet coverlet)는 소스를 훑어 파일 → 클래스를
//    잇는다. 한 파일의 클래스가 **일부만** 빠지면 그 파일은 파일 글롭으로 표현할 수 없다 → FAIL.
//  · 같은 문법의 정규식 사본(go `grep -vE` · rust `--ignore-filename-regex`)은 셸·마크다운 인용을
//    벗긴 뒤 **문자 그대로** 비교한다(같은 집합이어도 패턴이 다르면 다음 파일에서 갈린다).
//  · dotnet 은 Sonar 가 C# 커버리지를 먹지 않는다. 면제를 손으로 적지 않고 **규칙을 파생**한다 —
//    `sonar-project.properties` 에 그 언어의 리포트 경로가 없으면, Sonar 사본은 그 언어의 **전부**여야
//    한다(리포트 없는 파일은 0% 로 분모에 든다). 리포트 경로가 생기면 기대값이 SSOT 로 바뀐다.
//
// ⚠️ 실패는 스킵이 아니다. SSOT 가 0 파일로 펼쳐지거나, 자리 파일이 없거나, 이 가드가 모르는 설정
// 형태를 만나면 FAIL(exit 2). 사본이 갈렸으면 DRIFT(exit 1). 둘 다 없을 때만 exit 0.
// ⚠️ 주석은 사본이 아니다 — XML·properties·TOML·셸·YAML 모두 주석을 걷어낸 뒤 찾는다. YAML 은
// `run:` 스크립트 안만 본다(그 밖의 문자열은 실행되지 않는다).
//
// 사용: node scripts/coverage-boundary.mjs list  [ROOT] [--lang <id>]
//       node scripts/coverage-boundary.mjs check [ROOT]
import { readFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, dirname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'

class Fatal extends Error {
  constructor(site, lang, msg) {
    super(msg)
    this.site = site
    this.lang = lang
  }
}

// ── CLI ──────────────────────────────────────────────────────────────────────────────────
function usage(msg) {
  if (msg) console.error(msg)
  console.error('usage: node scripts/coverage-boundary.mjs list [ROOT] [--lang <id>]')
  console.error('       node scripts/coverage-boundary.mjs check [ROOT]')
  process.exit(2)
}
const argv = process.argv.slice(2)
const cmd = argv[0]
if (cmd !== 'list' && cmd !== 'check') usage(cmd ? `알 수 없는 명령: ${cmd}` : '')
let root = null
let onlyLang = null
for (let i = 1; i < argv.length; i++) {
  const a = argv[i]
  if (a === '--lang') onlyLang = argv[++i]
  else if (a.startsWith('--lang=')) onlyLang = a.slice(7)
  else if (a.startsWith('--')) usage(`알 수 없는 옵션: ${a}`)
  else if (root === null) root = a
  else usage(`인자가 너무 많다: ${a}`)
}
root ??= join(dirname(fileURLToPath(import.meta.url)), '..')

// ── 추적 파일 ──────────────────────────────────────────────────────────────────────────────
// 가드는 **추적된 파일만** 센다 — 빌드 산출물·로컬 잔여물이 집합에 섞이면 안 된다.
let FILES
try {
  FILES = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 })
    .split('\0')
    .filter(Boolean)
    .map((p) => p.replace(/\\/g, '/'))
} catch (e) {
  console.error(`FAIL git ls-files 가 실패했다(${root}) — 추적 파일 없이는 아무것도 잴 수 없다: ${e.message}`)
  process.exit(2)
}
const TRACKED = new Set(FILES)
const textCache = new Map()
function read(rel, lang) {
  if (textCache.has(rel)) return textCache.get(rel)
  const p = join(root, rel)
  if (!TRACKED.has(rel) || !existsSync(p))
    throw new Fatal(rel, lang, '자리 파일이 없다(추적되지 않거나 지워졌다) — 스킵이 아니라 실패다')
  const t = readFileSync(p, 'utf8').replace(/\r\n/g, '\n')
  textCache.set(rel, t)
  return t
}
const lineAt = (text, idx) => text.slice(0, idx).split('\n').length
const sortU = (xs) => [...new Set(xs)].sort()

// ── 매칭 의미론 ────────────────────────────────────────────────────────────────────────────
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')
// Ant 계열 글롭(Sonar · JaCoCo · vitest/picomatch 공통 부분집합): `**/` · `**` · `*` · `?`.
// 중괄호 대안(`{a,b}`)은 picomatch 만 안다 — Sonar 에서는 글자 그대로다.
function antRegex(glob, { braces = false } = {}) {
  let re = ''
  let i = 0
  while (i < glob.length) {
    let piece
    let step = 1
    if (glob.startsWith('**/', i)) [piece, step] = ['(?:.*/)?', 3]
    else if (glob.startsWith('**', i)) [piece, step] = ['.*', 2]
    else if (glob[i] === '*') piece = '[^/]*'
    else if (glob[i] === '?') piece = '[^/]'
    else if (braces && glob[i] === '{') {
      const j = glob.indexOf('}', i)
      if (j < 0) throw new Error(`닫히지 않은 중괄호: ${glob}`)
      piece = '(?:' + glob.slice(i + 1, j).split(',').map(esc).join('|') + ')'
      step = j + 1 - i
    } else piece = esc(glob[i])
    re += piece
    i += step
  }
  return new RegExp('^' + re + '$')
}
// Kover 클래스 필터: `*` 는 「아무 글자 0 개 이상」(점·`$` 포함), `?` 는 한 글자(Kover 문서).
const koverRegex = (p) => new RegExp('^' + p.split('').map((c) => (c === '*' ? '.*' : c === '?' ? '.' : esc(c))).join('') + '$')
// coverage.py(7.x) `files.py` 의 글롭 → 정규식 규칙을 옮긴 것. 선두 `*/` 는 「아무 접두 + 슬래시, 또는 없음」.
function coveragePyRegex(pat, cwdAbs) {
  let p = pat.replace(/\\/g, '/')
  if (!p.startsWith('*') && !p.startsWith('/')) p = cwdAbs + '/' + p
  let re = ''
  let i = 0
  if (/^\*+\//.test(p)) {
    re += '(?:.*/)?'
    i = p.indexOf('/') + 1
  }
  while (i < p.length) {
    if (/^\/\*+$/.test(p.slice(i))) {
      re += '/.*'
      break
    }
    if (p.startsWith('**/', i)) {
      re += '(?:.*/)?'
      i += 3
    } else if (p[i] === '*') {
      while (p[i] === '*') i++
      re += '[^/]*'
    } else {
      re += p[i] === '?' ? '[^/]' : esc(p[i])
      i++
    }
  }
  return new RegExp('^' + re + '$')
}
// Ruby 정규식 리터럴을 JS 로(쓰이는 부분집합만). 모르는 구문이면 FAIL 이 낫다.
function rubyRegex(body, flags, site) {
  if (/\(\?<[=!]|\\[GhHRX]|\(\?[imx-]+[):]/.test(body)) throw new Fatal(site, 'ruby', `이 가드가 옮기지 못하는 Ruby 정규식: ${body}`)
  const js = body.replace(/\\A/g, '^').replace(/\\[zZ]/g, '$')
  return new RegExp(js, (flags.includes('i') ? 'i' : '') + (flags.includes('m') ? 's' : ''))
}
// SimpleCov 1.2 `StringFilter#compute_segment_pattern` 을 옮긴 것(`filter.rb`). project_filename 은
// 루트 기준 상대 경로이고 선두 `/` 가 없다(1.x `source_file.rb`).
function simplecovStringRegex(arg) {
  const n = arg.replace(/^\//, '')
  const e = esc(n)
  if (n.endsWith('/')) return new RegExp(`(?:^|/)${e}`)
  if (n.includes('.') && !n.includes('/')) return new RegExp(`[^/]*${e}(?=[/.]|$)`)
  return new RegExp(`(?:^|/)${e}(?=[/.]|$)`)
}

// ── 셸 한 층 인용 벗기기 ────────────────────────────────────────────────────────────────────
// POSIX 셸이 한 줄을 단어로 나누는 방식(따옴표·백슬래시·주석). `$VAR`·`$(…)`·백틱은 전개하지 않고
// 단어에 `exp` 표시만 한다 — 비교할 값에 전개가 끼면 문자 그대로 비교가 성립하지 않으므로 FAIL 이다.
const EXPANDS = /^[A-Za-z_{(0-9@*#?$!-]/
function lexWords(text) {
  const out = []
  let cur = null
  let exp = false
  const flush = () => {
    if (cur !== null) out.push({ w: cur, exp })
    cur = null
    exp = false
  }
  for (let i = 0; i < text.length; ) {
    const c = text[i]
    if (/\s/.test(c)) {
      flush()
      i++
    } else if (cur === null && c === '#') break
    else if ('|&;<>()'.includes(c)) {
      flush()
      out.push({ op: c })
      i++
    } else if (c === "'") {
      const j = text.indexOf("'", i + 1)
      cur = (cur ?? '') + (j < 0 ? text.slice(i + 1) : text.slice(i + 1, j))
      i = j < 0 ? text.length : j + 1
    } else if (c === '"') {
      cur ??= ''
      i++
      while (i < text.length && text[i] !== '"') {
        if (text[i] === '\\' && '$`"\\'.includes(text[i + 1] ?? '')) {
          cur += text[i + 1]
          i += 2
        } else {
          if (text[i] === '`' || (text[i] === '$' && EXPANDS.test(text[i + 1] ?? ''))) exp = true
          cur += text[i++]
        }
      }
      i++
    } else if (c === '\\') {
      cur = (cur ?? '') + (text[i + 1] ?? '')
      i += 2
    } else {
      if (c === '`' || (c === '$' && EXPANDS.test(text[i + 1] ?? ''))) exp = true
      cur = (cur ?? '') + c
      i++
    }
  }
  flush()
  return out
}
// 여러 줄 스크립트에서 각 줄이 **시작할 때의** 인용 상태. 바깥 작은따옴표 안의 줄은 안쪽 셸
// (`sh -c '…'`)이 글자 그대로 받으므로 한 층으로 읽으면 된다. 바깥 큰따옴표는 두 층이 겹쳐 이
// 가드가 옳게 못 벗긴다 → 그 자리의 사본은 FAIL.
function quoteStates(lines) {
  let st = 'none'
  return lines.map((l) => {
    const at = st
    for (let i = 0; i < l.text.length; i++) {
      const c = l.text[i]
      if (st === 'single') {
        if (c === "'") st = 'none'
      } else if (st === 'double') {
        if (c === '\\') i++
        else if (c === '"') st = 'none'
      } else if (c === '\\') i++
      else if (c === "'") st = 'single'
      else if (c === '"') st = 'double'
      else if (c === '#' && (i === 0 || /[\s;&|()]/.test(l.text[i - 1]))) break
    }
    return { ...l, state: at }
  })
}
function wordsOfLine(l, site, lang) {
  if (l.state === 'double') throw new Fatal(`${site}:${l.line}`, lang, '바깥 큰따옴표 안의 명령이다 — 인용이 두 층이라 문자 그대로 비교할 수 없다')
  if (l.state === 'single') {
    // 바깥 작은따옴표 문자열 = 안쪽 셸 스크립트. 이 줄에서 바깥 따옴표가 닫히면 그 뒤는 바깥 셸이다.
    const j = l.text.indexOf("'")
    if (j < 0) return lexWords(l.text)
    return [...lexWords(l.text.slice(0, j)), { op: ';' }, ...lexWords(l.text.slice(j + 1))]
  }
  return lexWords(l.text)
}

// ── 명령 속 정규식 추출 ──────────────────────────────────────────────────────────────────
const KIND = {
  // `cargo llvm-cov --ignore-filename-regex <re>` (또는 `=<re>`)
  llvmcov: {
    label: 'cargo llvm-cov --ignore-filename-regex',
    cmdWord: 'llvm-cov',
    trigger: /--ignore-filename-regex/,
    extract(ws) {
      const out = []
      ws.forEach((x, i) => {
        if (x.op) return
        if (x.w === '--ignore-filename-regex') {
          const nx = ws[i + 1]
          out.push(nx && !nx.op ? nx : null)
        } else if (x.w.startsWith('--ignore-filename-regex=')) out.push({ ...x, w: x.w.slice('--ignore-filename-regex='.length) })
      })
      return out
    },
  },
  // `grep -vE <re> <…cover…>` — 커버 프로필에서 경계 줄을 걷어내는 go 게이트의 모양.
  // 마크다운 스팬(`loose`)은 피연산자 없이 명령만 전사하므로 커버 프로필 조건을 풀어 준다.
  // 긴 옵션(`--invert-match`·`--extended-regexp`·`--regexp=`)과 `-e` 도 읽는다 — 짧은 묶음만 읽으면
  // `grep --extended-regexp -v '…' cover.out` 같은 둘째 필터가 통째로 안 보였다(Grok 레그 실측).
  grepcover: {
    label: 'grep -vE … <cover profile>',
    cmdWord: 'grep',
    trigger: /\be?grep\b/,
    extract(ws, loose) {
      const out = []
      ws.forEach((x, i) => {
        if (x.op || !/(^|\/)e?grep$/.test(x.w)) return
        const g = grepArgs(ws, i + 1, x.w.endsWith('egrep'))
        let onCover = loose
        for (let k = g.next; ws[k] && !ws[k].op; k++) if (/cover/.test(ws[k].w)) onCover = true
        // 반전 매칭(-v)만 「경계 줄 걷어내기」다. 모양을 못 읽으면(-E 없음 · -f · 패턴 둘) FAIL(null).
        if (!onCover || !g.invert) return
        out.push(g.ok ? g.pat : null)
      })
      return out
    },
  },
}
// grep 인자 → { invert, ok, pat(단어), next(피연산자 시작) }. ok=false 는 「이 가드가 모르는 모양」이다.
function grepArgs(ws, j, egrep) {
  let invert = false
  let ere = egrep
  let bad = false
  const pats = []
  for (; ws[j] && !ws[j].op && ws[j].w.startsWith('-') && ws[j].w !== '-'; j++) {
    const o = ws[j].w
    if (o === '--') {
      j++
      break
    }
    if (o === '--invert-match') invert = true
    else if (o === '--extended-regexp') ere = true
    else if (o === '--regexp' || o === '--file') {
      if (o === '--file') bad = true
      pats.push(ws[++j])
    } else if (o.startsWith('--regexp=')) pats.push({ ...ws[j], w: o.slice(9) })
    else if (o.startsWith('--file=')) bad = true
    else if (/^--(basic-regexp|fixed-strings|perl-regexp)$/.test(o)) bad = true
    else if (/^-[A-Za-z0-9]+$/.test(o)) {
      const cl = o.slice(1)
      if (cl.includes('v')) invert = true
      if (cl.includes('E')) ere = true
      if (/[FGP]/.test(cl)) bad = true
      const argAt = cl.search(/[ef]/)
      if (argAt >= 0) {
        if (cl[argAt] === 'f') bad = true
        const rest = cl.slice(argAt + 1)
        pats.push(rest ? { ...ws[j], w: rest } : ws[++j])
      }
    }
  }
  if (!pats.length && ws[j] && !ws[j].op) pats.push(ws[j++])
  const ok = ere && !bad && pats.length === 1 && !!pats[0] && !pats[0].op
  return { invert, ok, pat: ok ? pats[0] : null, next: j }
}
// 파일 종류별로 「실행되는 명령 줄」만 모은다.
function commandLines(rel, lang) {
  const text = read(rel, lang)
  const L = text.split('\n')
  if (/\.ya?ml$/.test(rel)) {
    const out = []
    for (let i = 0; i < L.length; i++) {
      const m = L[i].match(/^(\s*)(?:-\s+)?run\s*:\s*(.*)$/)
      if (!m) continue
      const keyCol = L[i].indexOf('run')
      const v = m[2]
      if (/^[|>][-+0-9]*\s*(#.*)?$/.test(v)) {
        const block = []
        let j = i + 1
        for (; j < L.length; j++) {
          if (L[j].trim() === '') continue
          if (L[j].match(/^\s*/)[0].length <= keyCol) break
          block.push({ line: j + 1, text: L[j] })
        }
        out.push(...quoteStates(block))
        i = j - 1
      } else if (/^["']/.test(v)) out.push({ line: i + 1, text: v, quotedYaml: true, state: 'none' })
      else out.push({ line: i + 1, text: v, state: 'none' })
    }
    return out
  }
  if (/\.md$/.test(rel)) {
    // 인라인 코드 스팬만 — 마크다운은 스팬 안의 백슬래시를 건드리지 않는다(CommonMark).
    const out = []
    L.forEach((t, i) => {
      for (const m of t.matchAll(/(`+)(?!`)([\s\S]*?[^`])\1(?!`)/g)) {
        let body = m[2]
        if (/^ .* $/.test(body) && body.trim()) body = body.slice(1, -1)
        out.push({ line: i + 1, text: body, state: 'none', span: true })
      }
    })
    return out
  }
  return quoteStates(L.map((text, i) => ({ line: i + 1, text })))
}
function findRegexes(rel, lang, kind) {
  const K = KIND[kind]
  const hits = []
  for (const l of commandLines(rel, lang)) {
    if (!K.trigger.test(l.text)) continue
    const ws = wordsOfLine(l, rel, lang)
    // 마크다운 스팬은 명령을 담고 있을 때만 전사로 친다(`--flag="…"` 같은 모양 안내는 사본이 아니다).
    if (l.span && !ws.some((x) => x.w === K.cmdWord || x.w?.endsWith('/' + K.cmdWord))) continue
    for (const v of K.extract(ws, !!l.span)) {
      if (l.quotedYaml) throw new Fatal(`${rel}:${l.line}`, lang, 'YAML 따옴표 스칼라 안의 명령이다 — YAML 이스케이프까지 벗겨야 해 이 가드가 비교하지 않는다')
      if (v === null) throw new Fatal(`${rel}:${l.line}`, lang, `\`${K.label}\` 의 모양을 읽지 못했다(인자 없음 · -E 없음 · -f · 패턴 여럿)`)
      if (v.exp) throw new Fatal(`${rel}:${l.line}`, lang, `\`${K.label}\` 의 값에 셸 전개가 있다(${v.w}) — 전개된 값은 문자 그대로 비교할 수 없다`)
      hits.push({ line: l.line, value: v.w })
    }
  }
  return hits
}

// ── 소스 훑기(클래스 단위 SSOT 의 파일 매핑) ───────────────────────────────────────────────
// 주석·문자열·문자 리터럴을 걷어낸다 — 그 안의 `class`·`{` 가 구조로 읽히면 안 된다.
function stripCode(src, lang) {
  const n = src.length
  const nestedComments = lang === 'kotlin'
  const blockComment = (k) => {
    let d = 1
    k += 2
    while (k < n && d > 0) {
      if (nestedComments && src.startsWith('/*', k)) {
        d++
        k += 2
      } else if (src.startsWith('*/', k)) {
        d--
        k += 2
      } else k++
    }
    return k
  }
  const lineComment = (k) => {
    while (k < n && src[k] !== '\n') k++
    return k
  }
  const charLit = (k) => {
    k++
    k += src[k] === '\\' ? 2 : 1
    while (k < n && src[k] !== "'" && src[k] !== '\n') k++
    return k + 1
  }
  const isStringStart = (k) => {
    if (src[k] === '"') return true
    if (lang === 'csharp' && (src[k] === '@' || src[k] === '$')) {
      let j = k
      while (src[j] === '@' || src[j] === '$') j++
      return j > k && src[j] === '"'
    }
    return false
  }
  const codeUntilClose = (k) => {
    let d = 1
    while (k < n) {
      if (src.startsWith('//', k)) k = lineComment(k)
      else if (src.startsWith('/*', k)) k = blockComment(k)
      else if (isStringStart(k)) k = stringLit(k)
      else if (src[k] === "'") k = charLit(k)
      else {
        if (src[k] === '{') d++
        else if (src[k] === '}' && --d === 0) return k + 1
        k++
      }
    }
    return n
  }
  const stringLit = (k) => {
    let verbatim = false
    let interp = false
    if (lang === 'csharp')
      while (src[k] === '@' || src[k] === '$') {
        if (src[k] === '@') verbatim = true
        else interp = true
        k++
      }
    let q = 0
    while (src[k + q] === '"') q++
    if (q >= 3) {
      const close = lang === 'csharp' ? '"'.repeat(q) : '"""'
      k += q
      while (k < n) {
        if (lang === 'java' && src[k] === '\\') k += 2
        else if (lang === 'kotlin' && src.startsWith('${', k)) k = codeUntilClose(k + 2)
        else if (src.startsWith(close, k)) {
          k += close.length
          while (src[k] === '"') k++
          return k
        } else k++
      }
      return n
    }
    if (q === 2) return k + 2
    k++
    while (k < n) {
      const c = src[k]
      if (verbatim) {
        if (c === '"') {
          if (src[k + 1] === '"') {
            k += 2
            continue
          }
          return k + 1
        }
      } else {
        if (c === '\\') {
          k += 2
          continue
        }
        if (c === '"') return k + 1
        if (c === '\n') return k
      }
      if (lang === 'kotlin' && src.startsWith('${', k)) k = codeUntilClose(k + 2)
      else if (lang === 'csharp' && interp && c === '{') k = src[k + 1] === '{' ? k + 2 : codeUntilClose(k + 1)
      else k++
    }
    return n
  }
  let out = ''
  for (let i = 0; i < n; ) {
    if (src.startsWith('//', i)) i = lineComment(i)
    else if (src.startsWith('/*', i)) {
      const j = blockComment(i)
      out += src.slice(i, j).replace(/[^\n]/g, ' ')
      i = j
    } else if (isStringStart(i)) {
      i = stringLit(i)
      out += '""'
    } else if (src[i] === "'") {
      i = charLit(i)
      out += '0'
    } else out += src[i++]
  }
  return out
}
const tokens = (code) => code.match(/[A-Za-z_$][\w$]*|::|\S/g) ?? []
const IDENT = /^[A-Za-z_$][\w$]*$/

// java: 파일 → 클래스 파일 경로. 최상위 타입 T 는 `T.class`, 중첩·익명·enum 상수 본문이 있으면
// `T$1.class` 대표를 더한다(`**/T.class` 는 그것을 빼지 않는다 → 부분 제외 = FAIL).
function javaClassFiles(src) {
  const t = tokens(stripCode(src, 'java'))
  let pkg = ''
  const tops = []
  const stack = []
  let pending = null
  let top = null
  let enumAt = 0
  for (let i = 0; i < t.length; i++) {
    const w = t[i]
    if (w === 'package' && stack.length === 0 && !pkg) {
      let j = i + 1
      while (j < t.length && t[j] !== ';') pkg += t[j++]
      i = j
      continue
    }
    const isDecl =
      (w === 'class' || w === 'interface' || w === 'enum' || (w === 'record' && (t[i + 2] === '(' || t[i + 2] === '<'))) &&
      t[i - 1] !== '.' &&
      IDENT.test(t[i + 1] ?? '')
    if (isDecl) {
      if (stack.length === 0) tops.push((top = { name: t[i + 1], companions: false }))
      else if (top) top.companions = true
      pending = w === 'enum' && stack.length === 0 ? 'enum' : 'type'
      i++
      continue
    }
    if (w === 'new' && top) {
      let j = i + 1
      while (j < t.length && (IDENT.test(t[j]) || t[j] === '.')) j++
      if (t[j] === '<')
        for (let d = 0; j < t.length; j++) {
          if (t[j] === '<') d++
          else if (t[j] === '>' && --d === 0) {
            j++
            break
          }
        }
      if (t[j] === '(') {
        for (let d = 0; j < t.length; j++) {
          if (t[j] === '(') d++
          else if (t[j] === ')' && --d === 0) {
            j++
            break
          }
        }
        if (t[j] === '{') top.companions = true
      }
    }
    if (w === '{') {
      if (enumAt && stack.length === enumAt && top) top.companions = true // enum 상수 본문 → T$1
      stack.push(pending ? 'type' : 'other')
      if (pending === 'enum') enumAt = stack.length
      pending = null
    } else if (w === '}') {
      stack.pop()
      if (stack.length < enumAt) enumAt = 0
      if (stack.length === 0) top = null
    } else if (w === ';' && enumAt && stack.length === enumAt) enumAt = 0
  }
  const dir = pkg ? pkg.replace(/\./g, '/') + '/' : ''
  return tops.flatMap((x) => [`${dir}${x.name}.class`, ...(x.companions ? [`${dir}${x.name}$1.class`] : [])])
}
// kotlin: 파일 → JVM 클래스 이름. 최상위 class/interface/object T 는 `T` 와 `T$…`(코루틴·람다·중첩 —
// Kotlin 은 거의 늘 만든다), 최상위 fun/val/var 가 있으면 파일 파사드 `<Stem>Kt` 와 `<Stem>Kt$…`.
// ⚠️ 파사드 이름은 **파일 이름**에서 온다 — `auth.kt` 의 최상위 함수는 `AuthKt` 로 가지 `AuthClient…` 로
// 가지 않는다. 그래서 `AuthClient*` 로는 그 파일이 부분만 빠진다(→ FAIL 로 드러난다).
function kotlinClasses(src, file) {
  const jvmName = src.match(/@file\s*:\s*JvmName\s*\(\s*"([^"]+)"\s*\)/)?.[1]
  const code = stripCode(src, 'kotlin')
  const pkg = code.match(/^\s*package\s+([\w.]+)/m)?.[1] ?? ''
  const t = tokens(code)
  const tops = []
  let depth = 0
  let paren = 0
  let facade = false
  for (let i = 0; i < t.length; i++) {
    const w = t[i]
    if (w === '{') depth++
    else if (w === '}') depth--
    else if (w === '(') paren++
    else if (w === ')') paren--
    if (depth !== 0 || paren !== 0) continue
    if ((w === 'class' || w === 'interface' || w === 'object') && t[i - 1] !== '::') {
      if (IDENT.test(t[i + 1] ?? '')) tops.push(t[++i])
    } else if (w === 'fun' && t[i + 1] !== 'interface') facade = true
    else if (w === 'val' || w === 'var') facade = true
  }
  const P = pkg ? pkg + '.' : ''
  const names = tops.flatMap((n) => [P + n, `${P}${n}$<synthetic>`])
  if (facade) {
    const stem = jvmName ?? basename(file, '.kt').replace(/^./, (c) => c.toUpperCase()) + 'Kt'
    names.push(P + stem, `${P}${stem}$<synthetic>`)
  }
  return names
}
// C#: 파일 → 최상위 타입의 CLR 전체 이름. coverlet 은 제외된 타입의 **중첩 타입까지** 뺀다
// (`Instrumenter.IsTypeExcluded` 가 `DeclaringType` 사슬을 걷는다) — 그래서 최상위만 보면 된다.
function csharpTypes(src) {
  const t = tokens(stripCode(src, 'csharp').replace(/^[ \t]*#.*$/gm, ''))
  const stack = []
  let fileNs = null
  let pendingNs = null
  let pending = false
  const tops = []
  const nsName = () => {
    const parts = [fileNs, ...stack.filter((s) => s.kind === 'ns').map((s) => s.name)].filter(Boolean)
    return parts.length ? parts.join('.') + '.' : ''
  }
  for (let i = 0; i < t.length; i++) {
    const w = t[i]
    if (w === 'namespace') {
      let j = i + 1
      let s = ''
      while (j < t.length && (IDENT.test(t[j]) || t[j] === '.')) s += t[j++]
      if (t[j] === ';') fileNs = s
      else pendingNs = s
      i = j - 1
      continue
    }
    if (['class', 'struct', 'interface', 'enum', 'record', 'delegate'].includes(w)) {
      if ((w === 'class' || w === 'struct') && t[i - 1] === 'record') continue
      let j = i + 1
      if (w === 'record' && (t[j] === 'class' || t[j] === 'struct')) j++
      if (w === 'delegate') {
        let p = j
        while (p < t.length && t[p] !== '(' && t[p] !== ';') p++
        j = p - 1
        if (t[j] === '>') for (let d = 0; j > i; j--) if (t[j] === '>') d++; else if (t[j] === '<' && --d === 0) { j--; break }
      }
      const name = t[j]
      if (!IDENT.test(name ?? '')) continue // `where T : class` 같은 제약
      let arity = 0
      if (t[j + 1] === '<' && w !== 'delegate') {
        arity = 1
        for (let k = j + 1, d = 0; k < t.length; k++) {
          if (t[k] === '<') d++
          else if (t[k] === '>' && --d === 0) break
          else if (t[k] === ',' && d === 1) arity++
        }
      }
      if (stack.every((s) => s.kind === 'ns')) tops.push(nsName() + name + (arity ? '`' + arity : ''))
      pending = w !== 'delegate'
      i = j
      continue
    }
    if (w === '{') {
      if (pendingNs !== null) {
        stack.push({ kind: 'ns', name: pendingNs })
        pendingNs = null
      } else stack.push({ kind: pending ? 'type' : 'other' })
      pending = false
    } else if (w === '}') stack.pop()
    else if (w === ';') pending = false
  }
  return tops
}

// ── 설정 파일 파서(쓰이는 부분만) ────────────────────────────────────────────────────────────
// XML 주석을 같은 길이의 공백으로 바꾼다 — 줄 번호를 보존하기 위해.
const blankXmlComments = (x) => x.replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '))
// 스크립트(TS·Kotlin DSL) 토크나이저 — 문자열 **값**을 보존한다. 템플릿 보간이 낀 문자열은 dyn.
function scriptTokens(src, { kotlin = false } = {}) {
  const toks = []
  const n = src.length
  const idRe = /[A-Za-z_$][\w$]*/y
  for (let i = 0; i < n; ) {
    const c = src[i]
    if (src.startsWith('//', i)) {
      while (i < n && src[i] !== '\n') i++
    } else if (src.startsWith('/*', i)) {
      const j = src.indexOf('*/', i + 2)
      i = j < 0 ? n : j + 2
    } else if (kotlin && src.startsWith('"""', i)) {
      const j = src.indexOf('"""', i + 3)
      const v = src.slice(i + 3, j < 0 ? n : j)
      toks.push({ t: 'str', v, dyn: v.includes('$'), pos: i })
      i = j < 0 ? n : j + 3
    } else if (c === '"' || c === "'" || c === '`') {
      let j = i + 1
      let v = ''
      let dyn = false
      while (j < n && src[j] !== c) {
        if (src[j] === '\\') {
          v += src[j + 1] ?? ''
          j += 2
          continue
        }
        if (src[j] === '$' && (c === '`' ? src[j + 1] === '{' : kotlin && c === '"' && /[{A-Za-z_]/.test(src[j + 1] ?? ''))) dyn = true
        v += src[j++]
      }
      toks.push({ t: 'str', v, dyn, pos: i })
      i = j + 1
    } else if (/\s/.test(c)) i++
    else {
      idRe.lastIndex = i
      const m = idRe.exec(src)
      if (m) {
        toks.push({ t: 'id', v: m[0], pos: i })
        i += m[0].length
      } else toks.push({ t: 'p', v: c, pos: i++ })
    }
  }
  return toks
}
function matchClose(toks, i) {
  const open = toks[i].v
  const close = { '{': '}', '[': ']', '(': ')' }[open]
  for (let d = 0, k = i; k < toks.length; k++) {
    if (toks[k].t !== 'p') continue
    if (toks[k].v === open) d++
    else if (toks[k].v === close && --d === 0) return k
  }
  return -1
}
// Java .properties — `#`/`!` 주석, 역슬래시 줄 이음, `key=value`/`key: value`/`key value`.
function parseProperties(text, site) {
  const props = new Map()
  const L = text.split('\n')
  for (let i = 0; i < L.length; i++) {
    if (/^\s*[#!]/.test(L[i]) || !L[i].trim()) continue
    const start = i + 1
    let s = L[i].replace(/^\s+/, '')
    while (/(?:^|[^\\])(?:\\\\)*\\$/.test(s) && i + 1 < L.length) s = s.slice(0, -1) + L[++i].replace(/^\s+/, '')
    const m = s.match(/^((?:\\.|[^=:\s\\])+)\s*[=:\s]?\s*(.*)$/)
    if (!m) continue
    const key = m[1].replace(/\\(.)/g, '$1')
    if (props.has(key)) throw new Fatal(`${site}:${start}`, null, `\`${key}\` 가 두 번 정의됐다(나중 것이 이긴다) — 어느 쪽이 진짜인지 모호하다`)
    props.set(key, { value: m[2].replace(/\\(.)/g, '$1'), line: start })
  }
  return props
}

// ── 언어별 SSOT ─────────────────────────────────────────────────────────────────────────────
// 각 항목: dir · universe(제품 소스, 테스트 제외 — 그 게이트가 재는 범위) · ssot() → { site, label,
// entries[{pattern,line}], set, partial[{file,detail}], dead[pattern] }.
const SSOT = {
  java: {
    dir: 'java',
    universe: () => FILES.filter((f) => /^java\/([^/]+)\/src\/main\/java\/.+\.java$/.test(f)),
    ssot(U) {
      // `<jacoco.skip>true</jacoco.skip>` 인 모듈은 게이트가 **통째로** 안 잰다(예: examples) — 그 모듈의
      // 파일 전부가 omit 이다. 모집단에서 빼 버리면 모듈 하나를 skip 해도 Sonar 사본을 아무도 안 본다
      // (Grok 레그 실측: 그 변이가 SILENT 였다).
      const skipped = new Set(
        FILES.filter((f) => /^java\/[^/]+\/pom\.xml$/.test(f))
          .filter((f) => /<jacoco\.skip>\s*true\s*<\/jacoco\.skip>/.test(blankXmlComments(read(f, 'java'))))
          .map((f) => f.split('/')[1]),
      )
      const forced = new Map(U.filter((f) => skipped.has(f.split('/')[1])).map((f) => [f, 'jacoco.skip']))
      const site = 'java/pom.xml'
      const poms = FILES.filter((f) => /^java\/(?:[^/]+\/)?pom\.xml$/.test(f))
      const blocks = []
      for (const p of poms) {
        const x = blankXmlComments(read(p, 'java'))
        for (const m of x.matchAll(/<plugin>([\s\S]*?)<\/plugin>/g))
          if (/<artifactId>\s*jacoco-maven-plugin\s*<\/artifactId>/.test(m[1])) blocks.push({ p, x, body: m[1], at: m.index + 8 })
      }
      if (blocks.length !== 1 || blocks[0].p !== site)
        throw new Fatal(site, 'java', `jacoco-maven-plugin 설정이 ${site} 한 곳에 있어야 한다(찾은 곳: ${blocks.map((b) => b.p).join(', ') || '없음'})`)
      const { x, body, at } = blocks[0]
      const execIdx = body.search(/<executions>/)
      const pluginLevel = execIdx < 0 ? body : body.slice(0, execIdx) + body.slice(body.indexOf('</executions>') + 13)
      const execPart = execIdx < 0 ? '' : body.slice(execIdx, body.indexOf('</executions>'))
      if (/<exclude>/.test(execPart) || /<includes>/.test(body))
        throw new Fatal(site, 'java', 'execution 단위 <exclude> 또는 <includes> 가 있다 — 이 가드는 플러그인 단위 <excludes> 만 읽는다')
      const entries = []
      for (const m of pluginLevel.matchAll(/<exclude>\s*([^<]+?)\s*<\/exclude>/g)) {
        const idx = body.indexOf(m[0])
        entries.push({ pattern: m[1], line: lineAt(x, at + idx) })
      }
      const res = entries.map((e) => ({ ...e, re: antRegex(e.pattern) }))
      return classify({
        lang: 'java',
        site,
        label: 'jacoco <excludes>',
        entries,
        U,
        classesOf: (f) => javaClassFiles(read(f, 'java')),
        isExcluded: (c) => res.some((r) => r.re.test(c)),
        res,
        forced,
      })
    },
  },
  kotlin: {
    dir: 'kotlin',
    universe: () => FILES.filter((f) => /^kotlin\/src\/main\/kotlin\/.+\.kt$/.test(f)),
    ssot(U) {
      const site = 'kotlin/build.gradle.kts'
      const src = read(site, 'kotlin')
      const toks = scriptTokens(src, { kotlin: true })
      const kov = toks.map((t, i) => i).filter((i) => toks[i].t === 'id' && toks[i].v === 'kover' && toks[i + 1]?.v === '{')
      if (kov.length !== 1) throw new Fatal(site, 'kotlin', `최상위 \`kover { }\` 블록이 하나여야 한다(찾음 ${kov.length})`)
      const end = matchClose(toks, kov[0] + 1)
      const inner = toks.slice(kov[0] + 2, end)
      const blockOf = (name) => inner.map((t, i) => i).filter((i) => inner[i].t === 'id' && inner[i].v === name && inner[i + 1]?.v === '{')
      if (blockOf('includes').length || inner.some((t) => t.t === 'id' && t.v === 'excludedClasses'))
        throw new Fatal(site, 'kotlin', 'kover `includes { }` 또는 `excludedClasses` 가 있다 — 이 가드는 `excludes { classes(...) }` 만 읽는다')
      const ex = blockOf('excludes')
      if (ex.length !== 1) throw new Fatal(site, 'kotlin', `kover \`excludes { }\` 블록이 하나여야 한다(찾음 ${ex.length}) — 변형별 필터는 이 가드가 모른다`)
      const exEnd = matchClose(inner, ex[0] + 1)
      const entries = []
      for (let i = ex[0] + 2; i < exEnd; i++) {
        const t = inner[i]
        if (t.t !== 'id') continue
        if (inner[i + 1]?.v === '(') {
          if (t.v !== 'classes') throw new Fatal(`${site}:${lineAt(src, t.pos)}`, 'kotlin', `kover 필터 \`${t.v}(...)\` 는 이 가드가 파일로 펼치지 못한다`)
          const close = matchClose(inner, i + 1)
          for (const a of inner.slice(i + 2, close)) {
            if (a.t === 'p' && a.v === ',') continue
            if (a.t !== 'str' || a.dyn) throw new Fatal(`${site}:${lineAt(src, a.pos)}`, 'kotlin', 'classes(...) 인자가 문자열 리터럴이 아니다')
            entries.push({ pattern: a.v, line: lineAt(src, a.pos) })
          }
          i = close
        } else if (inner[i + 1]?.v === '.') throw new Fatal(`${site}:${lineAt(src, t.pos)}`, 'kotlin', `\`${t.v}.…\` 속성 표기는 이 가드가 읽지 않는다`)
      }
      const res = entries.map((e) => ({ ...e, re: koverRegex(e.pattern) }))
      return classify({
        lang: 'kotlin',
        site,
        label: 'kover excludes.classes',
        entries,
        U,
        classesOf: (f) => kotlinClasses(read(f, 'kotlin'), f),
        isExcluded: (c) => res.some((r) => r.re.test(c)),
        res,
      })
    },
  },
  go: {
    dir: 'go',
    universe: () => FILES.filter((f) => /^go\/.+\.go$/.test(f) && !/_test\.go$/.test(f) && !/(^|\/)testdata\//.test(f)),
    ssot(U) {
      const site = '.github/workflows/go-ci.yml'
      const hits = findRegexes(site, 'go', 'grepcover')
      if (hits.length !== 1) throw new Fatal(site, 'go', `커버 프로필을 거르는 \`grep -vE\` 가 정확히 하나여야 한다(찾음 ${hits.length})`)
      const mod = read('go/go.mod', 'go').match(/^module\s+(\S+)/m)?.[1]
      if (!mod) throw new Fatal('go/go.mod', 'go', 'module 경로를 읽지 못했다 — 커버 프로필 줄을 만들 수 없다')
      const re = new RegExp(hits[0].value)
      const entries = [{ pattern: hits[0].value, line: hits[0].line }]
      return fileSsot({
        lang: 'go',
        site: `${site}:${hits[0].line}`,
        label: 'grep -vE on cover.out',
        entries,
        U,
        isOmitted: (f) => re.test(`${mod}/${f.slice(3)}:1.1,1.2 1 1`),
        literal: hits[0].value,
      })
    },
  },
  python: {
    dir: 'python',
    universe: () => FILES.filter((f) => /^python\/src\/keycloak_sdk\/.+\.py$/.test(f)),
    ssot(U) {
      const site = 'python/pyproject.toml'
      for (const f of ['python/.coveragerc', 'python/setup.cfg', 'python/tox.ini'])
        if (TRACKED.has(f) && /\[(coverage:)?(run|report)\]|omit/.test(read(f, 'python')))
          throw new Fatal(f, 'python', 'coverage 설정이 pyproject.toml 밖에도 있다 — 이 가드는 pyproject 만 읽는다')
      const text = read(site, 'python')
      // 모집단(python/src/keycloak_sdk)은 `source = ["keycloak_sdk"]` 가 정한다 — 그 값이 바뀌거나 `include` 가
      // 생기면 게이트가 재는 범위가 이 가드의 가정과 갈린다(coverage.py 는 source 가 있으면 run.include 를
      // 무시하지만 report.include 는 보고를 좁힌다). 모델하지 않는 형태이므로 FAIL.
      const source = tomlStrings(text, 'tool.coverage.run', 'source').map((e) => e.pattern)
      if (source.join(',') !== 'keycloak_sdk') throw new Fatal(site, 'python', `[tool.coverage.run] source 가 ["keycloak_sdk"] 가 아니다(${JSON.stringify(source)}) — 모집단 가정이 깨졌다`)
      for (const sec of ['tool.coverage.run', 'tool.coverage.report'])
        if (tomlKeyLine(text, sec, 'include')) throw new Fatal(`${site}:${tomlKeyLine(text, sec, 'include')}`, 'python', `[${sec}] include 가 있다 — 이 가드는 omit 만 펼친다`)
      const entries = [...tomlStrings(text, 'tool.coverage.run', 'omit'), ...tomlStrings(text, 'tool.coverage.report', 'omit')]
      const cwd = '/__root__/python'
      const res = entries.map((e) => ({ ...e, re: coveragePyRegex(e.pattern, cwd) }))
      return fileSsot({
        lang: 'python',
        site,
        label: '[tool.coverage] omit',
        entries,
        U,
        isOmitted: (f) => res.some((r) => r.re.test('/__root__/' + f)),
        res,
        subject: (f) => '/__root__/' + f,
      })
    },
  },
  node: {
    dir: 'node',
    universe: () => FILES.filter((f) => /^node\/src\/.+\.ts$/.test(f) && !/\.d\.ts$/.test(f)),
    ssot(U) {
      const site = 'node/vitest.config.ts'
      const src = read(site, 'node')
      const toks = scriptTokens(src)
      const cov = toks.map((t, i) => i).filter((i) => toks[i].t === 'id' && toks[i].v === 'coverage' && toks[i + 1]?.v === ':' && toks[i + 2]?.v === '{')
      if (cov.length !== 1) throw new Fatal(site, 'node', `\`coverage: { }\` 객체가 하나여야 한다(찾음 ${cov.length})`)
      const end = matchClose(toks, cov[0] + 2)
      // coverage 객체 바로 아래의 `include`·`exclude` 배열(중첩 객체 속 같은 이름은 아니다).
      const arrays = {}
      for (let i = cov[0] + 3, depth = 0; i < end; i++) {
        const t = toks[i]
        if (t.t === 'p' && '{[('.includes(t.v)) depth++
        else if (t.t === 'p' && '}])'.includes(t.v)) depth--
        else if (depth === 0 && t.t === 'id' && (t.v === 'exclude' || t.v === 'include') && toks[i + 1]?.v === ':') {
          if (toks[i + 2]?.v !== '[') throw new Fatal(`${site}:${lineAt(src, t.pos)}`, 'node', `coverage.${t.v} 가 배열 리터럴이 아니다`)
          arrays[t.v] = i + 2
        }
      }
      const strings = (key) => {
        if (arrays[key] === undefined) throw new Fatal(site, 'node', `coverage.${key} 가 없다 — 없으면 vitest 는 「불러온 파일만」 재서 모집단을 정할 수 없다`)
        const out = []
        for (const t of toks.slice(arrays[key] + 1, matchClose(toks, arrays[key]))) {
          if (t.t === 'p' && t.v === ',') continue
          if (t.t !== 'str' || t.dyn) throw new Fatal(`${site}:${lineAt(src, t.pos)}`, 'node', `coverage.${key} 에 문자열 리터럴이 아닌 항목이 있다(스프레드·변수는 이 가드가 못 펼친다)`)
          out.push({ pattern: t.v, line: lineAt(src, t.pos) })
        }
        return out
      }
      const glob = (e) => ({ ...e, re: antRegex(e.pattern.replace(/^\.\//, ''), { braces: true }) })
      const entries = strings('exclude')
      const res = entries.map(glob)
      // `include` 밖의 파일은 게이트가 안 잰다 — 그것도 omit 이다(Grok 레그 실측: include 를 좁혀도 SILENT 였다).
      const inc = strings('include').map(glob)
      const forced = new Map(U.filter((f) => !inc.some((r) => r.re.test(f.slice(5)))).map((f) => [f, 'coverage.include 밖']))
      return fileSsot({
        lang: 'node',
        site,
        label: 'vitest coverage.exclude',
        entries,
        U,
        isOmitted: (f) => res.some((r) => r.re.test(f.slice(5))),
        res,
        subject: (f) => f.slice(5),
        forced,
      })
    },
  },
  dotnet: {
    dir: 'dotnet',
    universe: () => FILES.filter((f) => /^dotnet\/src\/.+\.cs$/.test(f)),
    ssot(U) {
      const site = 'dotnet/coverlet.runsettings'
      const x = blankXmlComments(read(site, 'dotnet'))
      if (/<(Include|ExcludeByFile|IncludeDirectory|ExcludeByAttribute)>/.test(x))
        throw new Fatal(site, 'dotnet', '<Include>/<ExcludeByFile>/<IncludeDirectory>/<ExcludeByAttribute> 가 있다 — 이 가드는 <Exclude> 타입 필터만 읽는다')
      const ms = [...x.matchAll(/<Exclude>([\s\S]*?)<\/Exclude>/g)]
      if (ms.length !== 1) throw new Fatal(site, 'dotnet', `<Exclude> 가 하나여야 한다(찾음 ${ms.length})`)
      const line = lineAt(x, ms[0].index)
      const entries = ms[0][1].split(',').map((s) => s.trim()).filter(Boolean).map((pattern) => ({ pattern, line }))
      const res = entries.map((e) => {
        const m = e.pattern.match(/^\[([^\]]+)\](.+)$/)
        if (!m || /\?/.test(e.pattern)) throw new Fatal(`${site}:${line}`, 'dotnet', `coverlet 필터 형식을 모른다: ${e.pattern}`)
        const w = (s) => new RegExp('^' + esc(s).replace(/\\\*/g, '.*') + '$')
        return { ...e, mod: w(m[1]), type: w(m[2]), re: w(m[2]) }
      })
      const asm = (f) => {
        // 가장 가까운 상위 디렉터리의 .csproj — AssemblyName 이 없으면 파일 이름이 어셈블리 이름이다.
        for (let d = dirname(f); d.startsWith('dotnet'); d = dirname(d)) {
          const pj = FILES.find((p) => dirname(p) === d && p.endsWith('.csproj'))
          if (pj) return read(pj, 'dotnet').match(/<AssemblyName>\s*([^<]+?)\s*<\/AssemblyName>/)?.[1] ?? basename(pj, '.csproj')
        }
        throw new Fatal(f, 'dotnet', '이 파일을 담는 .csproj 를 찾지 못했다 — 어셈블리 이름을 모른다')
      }
      const cls = (f) => csharpTypes(read(f, 'dotnet')).map((ty) => `[${asm(f)}]${ty}`)
      const one = (r, c) => {
        const [, a, ty] = c.match(/^\[([^\]]+)\](.+)$/)
        return r.mod.test(a) && r.type.test(ty)
      }
      const hit = (c) => res.some((r) => one(r, c))
      return classify({
        lang: 'dotnet',
        site: `${site}:${line}`,
        label: 'coverlet <Exclude>',
        entries,
        U,
        classesOf: cls,
        isExcluded: hit,
        res: res.map((r) => ({ ...r, test: (c) => one(r, c) })),
      })
    },
  },
  php: {
    dir: 'php',
    universe: () => FILES.filter((f) => /^php\/src\/.+\.php$/.test(f)),
    ssot(U) {
      const site = 'php/phpunit.xml'
      const x = blankXmlComments(read(site, 'php'))
      if (/<coverage[\s>][\s\S]*?<(include|exclude)>/.test(x)) throw new Fatal(site, 'php', '레거시 <coverage> include/exclude 가 있다 — 이 가드는 <source> 만 읽는다')
      // `<source>` 는 하나여야 한다 — 둘째 블록은 이 가드가 읽지 않으므로 모호함을 통과시키지 않는다.
      const srcs = [...x.matchAll(/<source[\s>][\s\S]*?<\/source>/g)]
      if (srcs.length !== 1) throw new Fatal(site, 'php', `<source> 가 하나여야 한다(찾음 ${srcs.length})`)
      const srcM = srcs[0]
      const block = (tag) => {
        const out = []
        for (const ex of srcM[0].matchAll(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`, 'g')))
          for (const m of ex[1].matchAll(/<(file|directory)((?:\s+[\w-]+="[^"]*")*)\s*>\s*([^<]+?)\s*<\/\1>/g)) {
            const suffix = m[2].match(/suffix="([^"]*)"/)?.[1] ?? '.php'
            const prefix = m[2].match(/prefix="([^"]*)"/)?.[1] ?? ''
            out.push({
              pattern: m[1] === 'file' ? m[3] : `${m[3]}/ (prefix=${prefix} suffix=${suffix})`,
              kind: m[1],
              path: m[3].replace(/^\.\//, '').replace(/\/$/, ''),
              suffix,
              prefix,
              line: lineAt(x, srcM.index + ex.index + ex[0].indexOf(ex[1]) + m.index),
            })
          }
        return out
      }
      const rel = (f) => f.slice(4)
      const test = (e, f) =>
        e.kind === 'file' ? rel(f) === e.path : rel(f).startsWith(e.path + '/') && basename(f).endsWith(e.suffix) && basename(f).startsWith(e.prefix)
      const entries = block('exclude')
      const res = entries.map((e) => ({ ...e, test: (f) => test(e, f) }))
      // `<include>` 밖의 파일도 게이트가 안 잰다 — 그것도 omit 이다(node `coverage.include` 와 같은 판정).
      const inc = block('include')
      if (!inc.length) throw new Fatal(site, 'php', '<source><include> 가 없다 — 모집단을 정할 수 없다')
      const forced = new Map(U.filter((f) => !inc.some((e) => test(e, f))).map((f) => [f, '<include> 밖']))
      return fileSsot({
        lang: 'php',
        site,
        label: 'phpunit <source><exclude>',
        entries,
        U,
        isOmitted: (f) => res.some((r) => r.test(f)),
        res,
        subject: (f) => f,
        forced,
      })
    },
  },
  ruby: {
    dir: 'ruby',
    universe: () => FILES.filter((f) => /^ruby\/lib\/.+\.rb$/.test(f)),
    ssot(U) {
      const site = 'ruby/spec/spec_helper.rb'
      if (TRACKED.has('ruby/.simplecov')) throw new Fatal('ruby/.simplecov', 'ruby', '.simplecov 가 있다 — 이 가드는 spec_helper.rb 만 읽는다')
      const text = read(site, 'ruby')
      const entries = []
      text.split('\n').forEach((raw, i) => {
        const l = raw.replace(/^\s*#.*$/, '')
        // `SimpleCov.add_filter "…"` 처럼 블록 밖에서 모듈 메서드로 불러도 같은 필터다(Grok 레그 실측:
        // 첫 판은 줄머리 `skip`/`add_filter` 만 읽어 그것이 SILENT 였다).
        const call = l.replace(/^\s*SimpleCov\s*\.\s*/, ' ')
        if (/^\s*SimpleCov\.start\s*\(?\s*["':]/.test(l) || /^\s*(cover|track_files|load_profile|profile)\b/.test(call))
          throw new Fatal(`${site}:${i + 1}`, 'ruby', '프로파일·cover·track_files 는 이 가드가 파일로 펼치지 못한다')
        const m = call.match(/^\s*(skip|add_filter)\b\s*(.*)$/)
        if (!m) return
        const a = m[2].trim().replace(/^\((.*)\)(\s*#.*)?$/, '$1')
        let re
        let s
        if ((s = a.match(/^"((?:[^"\\]|\\.)*)"\s*(#.*)?$/) || a.match(/^'([^']*)'\s*(#.*)?$/))) re = simplecovStringRegex(s[1])
        else if ((s = a.match(/^%r\{(.*)\}([imx]*)\s*(#.*)?$/) || a.match(/^\/((?:[^/\\]|\\.)*)\/([imx]*)\s*(#.*)?$/))) re = rubyRegex(s[1], s[2], `${site}:${i + 1}`)
        else throw new Fatal(`${site}:${i + 1}`, 'ruby', `${m[1]} 인자 형식을 모른다(블록·배열·변수는 파일로 펼치지 못한다): ${a}`)
        entries.push({ pattern: a.replace(/\s*#.*$/, ''), line: i + 1, re })
      })
      return fileSsot({
        lang: 'ruby',
        site,
        label: 'SimpleCov skip',
        entries,
        U,
        isOmitted: (f) => entries.some((e) => e.re.test(f.slice(5))),
        res: entries,
        subject: (f) => f.slice(5),
      })
    },
  },
  rust: {
    dir: 'rust',
    universe: () => FILES.filter((f) => /^rust\/src\/.+\.rs$/.test(f)),
    ssot(U) {
      const site = '.github/workflows/rust-ci.yml'
      const hits = findRegexes(site, 'rust', 'llvmcov')
      if (hits.length !== 1) throw new Fatal(site, 'rust', `\`--ignore-filename-regex\` 가 정확히 하나여야 한다(찾음 ${hits.length})`)
      const re = new RegExp(hits[0].value)
      const entries = [{ pattern: hits[0].value, line: hits[0].line }]
      return fileSsot({
        lang: 'rust',
        site: `${site}:${hits[0].line}`,
        label: 'cargo llvm-cov --ignore-filename-regex',
        entries,
        U,
        isOmitted: (f) => re.test('/__root__/' + f),
        literal: hits[0].value,
      })
    },
  },
}
const LANG_IDS = Object.keys(SSOT)

// 그 절에 `key =` 줄이 있으면 줄 번호(1부터), 없으면 0.
function tomlKeyLine(text, section, key) {
  let inSec = false
  const L = text.split('\n')
  for (let i = 0; i < L.length; i++) {
    const l = L[i].replace(/^\s*#.*$/, '')
    if (/^\s*\[[^\]]+\]\s*$/.test(l)) inSec = l.trim() === `[${section}]`
    else if (inSec && new RegExp(`^\\s*${esc(key)}\\s*=`).test(l)) return i + 1
  }
  return 0
}
function tomlStrings(text, section, key) {
  const out = []
  let inSec = false
  let open = false
  text.split('\n').forEach((raw, i) => {
    // 문자열 밖의 `#` 부터 줄 끝까지가 주석이다.
    let l = ''
    for (let k = 0, q = null; k < raw.length; k++) {
      const c = raw[k]
      if (q) {
        if (c === '\\' && q === '"') {
          l += c + (raw[k + 1] ?? '')
          k++
        } else {
          if (c === q) q = null
          l += c
        }
      } else if (c === '#') break
      else {
        if (c === '"' || c === "'") q = c
        l += c
      }
    }
    if (!open && /^\s*\[/.test(l)) {
      inSec = l.trim() === `[${section}]`
      return
    }
    if (!inSec) return
    let rest = null
    if (open) rest = l
    else {
      const m = l.match(new RegExp(`^\\s*${esc(key)}\\s*=\\s*(.*)$`))
      if (m) {
        if (!m[1].startsWith('[')) throw new Fatal(`python/pyproject.toml:${i + 1}`, 'python', `${key} 가 배열이 아니다`)
        rest = m[1].slice(1)
        open = true
      }
    }
    if (rest === null) return
    for (const s of rest.matchAll(/"((?:[^"\\]|\\.)*)"|'([^']*)'/g)) out.push({ pattern: s[1] ?? s[2], line: i + 1 })
    if (/\]\s*$/.test(rest.replace(/"(?:[^"\\]|\\.)*"|'[^']*'/g, ''))) open = false
  })
  return out
}

// SSOT 결과 조립 — 파일 단위(패턴이 파일을 직접 가리킨다).
// `forced` 는 패턴과 무관하게 게이트가 통째로 안 재는 파일(파일 → 이유)이다 — jacoco.skip 모듈 ·
// vitest/phpunit `include` 밖. 그것도 omit 이므로 Sonar 사본이 따라와야 한다.
const siteOf = (site, entries) => (site.includes(':') || !entries.length ? site : `${site}:${entries[0].line}`)
function fileSsot({ lang, site, label, entries, U, isOmitted, literal = null, res = null, subject = null, forced = new Map() }) {
  site = siteOf(site, entries)
  if (!entries.length) throw new Fatal(site, lang, 'omit 항목을 하나도 찾지 못했다 — 표기가 바뀌었으면 가드가 공허해진다')
  const set = new Set(U.filter((f) => forced.has(f) || isOmitted(f)))
  if (set.size === 0) throw new Fatal(site, lang, 'SSOT 가 제품 소스 0 개로 펼쳐진다 — 스킵이 아니라 실패다')
  const dead = res ? res.filter((r) => !U.some((f) => (r.test ? r.test(f) : r.re.test(subject(f))))).map((r) => r.pattern) : []
  return { site, label, entries, set, partial: [], dead, literal, forced }
}
// SSOT 결과 조립 — 클래스 단위. 파일의 클래스가 전부 빠지면 그 파일이 omit, 일부면 partial(FAIL).
function classify({ lang, site, label, entries, U, classesOf, isExcluded, res, forced = new Map() }) {
  site = siteOf(site, entries)
  if (!entries.length) throw new Fatal(site, lang, 'omit 항목을 하나도 찾지 못했다 — 표기가 바뀌었으면 가드가 공허해진다')
  const set = new Set()
  const partial = []
  const all = []
  for (const f of U) {
    if (forced.has(f)) {
      set.add(f)
      continue
    }
    const cs = classesOf(f)
    all.push(...cs)
    const hit = cs.filter(isExcluded)
    if (cs.length && hit.length === cs.length) set.add(f)
    else if (hit.length) partial.push({ file: f, detail: `빠짐 ${hit.join(', ')} · 남음 ${cs.filter((c) => !isExcluded(c)).join(', ')}` })
  }
  if (set.size === 0 && !partial.length) throw new Fatal(site, lang, 'SSOT 가 제품 소스 0 개로 펼쳐진다 — 스킵이 아니라 실패다')
  const dead = res.filter((r) => !all.some((c) => (r.test ? r.test(c) : r.re.test(c)))).map((r) => r.pattern)
  return { site, label, entries, set, partial, dead, forced }
}

// ── 사본 표 ────────────────────────────────────────────────────────────────────────────────
// 같은 문법의 정규식 사본. 여기에 없는 실행 자리에서 같은 명령이 나오면 「등록 안 된 사본」이다.
const REGEX_COPIES = {
  go: { kind: 'grepcover', files: ['harness/suites/go.sh', '.claude/rules/go.md'] },
  rust: { kind: 'llvmcov', files: ['.github/workflows/sonarcloud.yml', 'harness/suites/rust.sh', '.claude/rules/rust.md'] },
}
const SONAR = 'sonar-project.properties'
// kotlin.md 는 목록을 전사하지 않고 패턴 하나를 **예로** 든다 — 그 예가 SSOT 에 실제로 있는지만 본다.
const MENTIONS = { kotlin: ['.claude/rules/kotlin.md'] }

// ── 실행 ────────────────────────────────────────────────────────────────────────────────────
const findings = []
const fail = (e) => void findings.push({ kind: 'FAIL', site: e.site, lang: e.lang, msg: e.message })
const guard = (fn) => {
  try {
    return fn()
  } catch (e) {
    if (e instanceof Fatal) return fail(e)
    throw e
  }
}
const U = {}
const S = {}
for (const id of LANG_IDS) {
  guard(() => {
    U[id] = SSOT[id].universe()
    if (!U[id].length) throw new Fatal(`${SSOT[id].dir}/`, id, '제품 소스가 0 개다 — 언어 디렉터리 규칙이 깨졌다')
  })
  if (U[id]) guard(() => (S[id] = SSOT[id].ssot(U[id])))
  if (S[id]) for (const p of S[id].partial) fail(new Fatal(S[id].site, id, `${p.file} 이(가) 부분만 빠진다(${p.detail}) — 파일 글롭 사본으로 표현할 수 없다`))
}

if (cmd === 'list') {
  if (onlyLang && !SSOT[onlyLang]) usage(`모르는 언어: ${onlyLang} (${LANG_IDS.join(' · ')})`)
  for (const id of LANG_IDS) {
    if (onlyLang && id !== onlyLang) continue
    const s = S[id]
    if (!s) continue
    console.log(`[${id}] SSOT ${s.site} (${s.label}) → ${s.set.size} / ${U[id].length} files`)
    for (const f of sortU(s.set)) console.log(`  ${f}${s.forced.has(f) ? `  (${s.forced.get(f)})` : ''}`)
    for (const p of s.partial) console.log(`  (partial) ${p.file} — ${p.detail}`)
    if (s.dead.length) console.log(`  · 제품 소스에 걸리지 않는 항목: ${s.dead.join(' · ')}`)
  }
  for (const f of findings) if (!onlyLang || f.lang === onlyLang) console.error(`FAIL ${f.site} [${f.lang ?? '-'}] ${f.msg}`)
  process.exit(findings.length ? 2 : 0)
}

const drift = (site, lang, msg) => findings.push({ kind: 'DRIFT', site, lang, msg })
const setDiff = (actual, expected) => ({
  extra: sortU([...actual].filter((f) => !expected.has(f))),
  missing: sortU([...expected].filter((f) => !actual.has(f))),
})
const fmtDiff = ({ extra, missing }) =>
  [extra.length ? `extra: ${extra.join(', ')}` : '', missing.length ? `missing: ${missing.join(', ')}` : ''].filter(Boolean).join(' | ')

// (1) Sonar — sonar.coverage.exclusions 의 효과를 언어별 제품 소스 위에서 펼쳐 SSOT 와 비교.
guard(() => {
  const text = read(SONAR, null)
  const props = parseProperties(text, SONAR)
  for (const k of ['sonar.inclusions', 'sonar.coverage.inclusions', 'sonar.sources'])
    if (props.has(k)) throw new Fatal(`${SONAR}:${props.get(k).line}`, null, `\`${k}\` 가 있다 — 이 가드는 기본 소스 집합 위에서만 펼친다`)
  const cov = props.get('sonar.coverage.exclusions')
  if (!cov) throw new Fatal(SONAR, null, 'sonar.coverage.exclusions 가 없다')
  const globs = (v) => v.split(',').map((s) => s.trim()).filter(Boolean).map((g) => antRegex(g))
  const covRe = globs(cov.value)
  const idxRe = globs(props.get('sonar.exclusions')?.value ?? '')
  // 리포트 경로는 baseDir 상대다 — `./dotnet/…` 도 dotnet 이다(Grok 레그 실측: 선두 `./` 가 파생을 비껴갔다).
  const withReport = new Set()
  for (const [k, { value }] of props)
    if (/reportsPaths?$|reportPaths?$/i.test(k))
      for (const p of value.split(',').map((s) => s.trim().replace(/^(\.\/)+/, '')))
        for (const id of LANG_IDS) if (p.startsWith(SSOT[id].dir + '/')) withReport.add(id)
  const site = `${SONAR}:${cov.line}`
  for (const id of LANG_IDS) {
    if (!U[id]) continue
    const indexed = U[id].filter((f) => !idxRe.some((r) => r.test(f)))
    const actual = new Set(indexed.filter((f) => covRe.some((r) => r.test(f))))
    let expected
    let against
    if (withReport.has(id)) {
      if (!S[id]) continue // SSOT 가 FAIL — 이미 보고됐다
      expected = new Set(indexed.filter((f) => S[id].set.has(f)))
      against = `SSOT ${S[id].site}`
    } else {
      // 파생 규칙: 리포트를 안 먹이는 언어는 Sonar 가 전부 빼야 0% 희석이 없다.
      expected = new Set(indexed)
      against = `derived rule (no ${id} coverage report in ${SONAR} → all ${indexed.length} files)`
    }
    const d = setDiff(actual, expected)
    if (d.extra.length || d.missing.length) drift(site, id, `vs ${against} — ${fmtDiff(d)}`)
  }
})

// (2) 같은 문법의 정규식 사본 — 인용을 벗긴 값을 문자 그대로.
for (const [id, { kind, files }] of Object.entries(REGEX_COPIES)) {
  const s = S[id]
  if (!s) continue
  for (const f of files)
    guard(() => {
      const hits = findRegexes(f, id, kind)
      if (!hits.length) throw new Fatal(f, id, `사본 자리에서 \`${KIND[kind].label}\` 를 찾지 못했다(주석은 세지 않는다) — 표기가 바뀌었으면 이 대조가 공허해진다`)
      for (const h of hits) {
        if (h.value === s.literal) continue
        let files = ''
        try {
          const re = new RegExp(h.value)
          const mod = id === 'go' ? read('go/go.mod', 'go').match(/^module\s+(\S+)/m)?.[1] : null
          const got = new Set(U[id].filter((u) => (id === 'go' ? re.test(`${mod}/${u.slice(3)}:1.1,1.2 1 1`) : re.test('/__root__/' + u))))
          const dd = setDiff(got, s.set)
          files = dd.extra.length || dd.missing.length ? ` — files ${fmtDiff(dd)}` : ' — same file set today'
        } catch {
          files = ' — (copy is not a valid JS regex)'
        }
        drift(`${f}:${h.line}`, id, `regex differs from SSOT ${s.site} — copy: ${h.value} · ssot: ${s.literal}${files}`)
      }
    })
}

// (3) 언급 — kotlin.md 가 예로 드는 Kover 패턴이 SSOT 에 실제로 있는가.
for (const [id, files] of Object.entries(MENTIONS)) {
  const s = S[id]
  if (!s) continue
  for (const f of files)
    guard(() => {
      read(f, id)
      for (const l of commandLines(f, id)) {
        if (!/^[A-Za-z_][\w.$]*\*$/.test(l.text) || !/[A-Z]/.test(l.text)) continue
        const known = s.entries.some((e) => e.pattern === l.text || e.pattern.endsWith('.' + l.text))
        if (!known) drift(`${f}:${l.line}`, id, `mentions Kover pattern \`${l.text}\` that SSOT ${s.site} does not contain (${s.entries.map((e) => e.pattern).join(', ')})`)
      }
    })
}

// (4) 등록 안 된 사본 — 워크플로 run 스크립트와 하네스 셸에서 같은 명령이 새로 나타났는가.
//     그리고 Sonar 제외를 properties 밖(`-Dsonar.coverage.exclusions=…`)에서 덮어쓰는가.
//     등록은 **종류별**이다 — 한 종류의 사본 자리라고 다른 종류의 새 사본까지 면제하면 안 된다
//     (Grok 레그 실측: sonarcloud.yml 에 넣은 `grep -vE … cover.out` 이 SILENT 였다).
guard(() => {
  const registered = {
    grepcover: new Set(['.github/workflows/go-ci.yml', ...REGEX_COPIES.go.files]),
    llvmcov: new Set(['.github/workflows/rust-ci.yml', ...REGEX_COPIES.rust.files]),
  }
  const sweep = FILES.filter((f) => /^\.github\/workflows\/[^/]+\.ya?ml$/.test(f) || /^harness\/.+\.sh$/.test(f))
  if (sweep.length < 5) throw new Fatal('.github/workflows/', null, `훑을 실행 자리를 ${sweep.length} 개만 찾았다 — 스윕이 깨졌다`)
  for (const f of sweep) {
    if (/\.ya?ml$/.test(f)) {
      read(f, null)
        .split('\n')
        .forEach((l, i) => {
          const code = l.replace(/(^|\s)#.*$/, '')
          if (/sonar\.(coverage\.)?(exclusions|inclusions)/.test(code))
            findings.push({ kind: 'FAIL', site: `${f}:${i + 1}`, lang: null, msg: 'Sonar 제외를 sonar-project.properties 밖에서 정의한다 — 이 가드는 properties 만 읽는다' })
        })
    }
    for (const kind of Object.keys(KIND)) {
      if (registered[kind].has(f)) continue
      for (const h of guard(() => findRegexes(f, null, kind)) ?? [])
        drift(`${f}:${h.line}`, kind === 'llvmcov' ? 'rust' : 'go', `unregistered copy of \`${KIND[kind].label}\` (value: ${h.value}) — register it in REGEX_COPIES of scripts/coverage-boundary.mjs`)
    }
  }
})

const order = { FAIL: 0, DRIFT: 1 }
findings.sort((a, b) => order[a.kind] - order[b.kind] || String(a.lang).localeCompare(String(b.lang)) || a.site.localeCompare(b.site))
for (const f of findings) console.log(`${f.kind} ${f.site} [${f.lang ?? '-'}] ${f.msg}`)
const nFail = findings.filter((f) => f.kind === 'FAIL').length
const nDrift = findings.length - nFail
const counts = LANG_IDS.map((id) => `${id} ${S[id] ? S[id].set.size : '?'}`).join(' · ')
if (!findings.length) console.log(`coverage-boundary: OK — 9 SSOT ↔ copies agree (omitted files: ${counts})`)
else console.log(`coverage-boundary: ${nDrift} drift · ${nFail} fail (omitted files: ${counts})`)
process.exit(nFail ? 2 : nDrift ? 1 : 0)
