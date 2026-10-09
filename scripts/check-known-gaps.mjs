#!/usr/bin/env node
// check-known-gaps.mjs — HostilePathMatrix 의 알려진 틈(KNOWN_GAPS) ↔ 잔여작업 등록부의 열린 항목.
//
// 왜: 아홉 언어의 적대 경로 행렬은 「지금 main 에서 실패하는 칸」을 KNOWN_GAPS 에 `등록부 id: 이유` 로
// 적고, 그 칸이 더는 관측되지 않으면 스스로 실패한다(낡은 틈). 그런데 **그 id 가 등록부에 있는가, 아직
// 열려 있는가**는 아무도 대조하지 않았다 — 오타 id · 등록 누락 · 틈이 남은 채 닫힌 항목이 조용히
// 통과한다(등록부 `guard-detection-surface-hand-narrowed` 의 「다음 걸음」).
//
// 모델:
//  · 언어 집합은 **트리에서 파생**한다(`df_tree_langs` — 자기 루트에 빌드 매니페스트를 가진 최상위
//    디렉터리). 파생 언어마다 basename 이 hostile-path-matrix 인 추적 파일이 정확히 하나여야 한다 —
//    없거나 둘이면 FAIL(열 번째 언어가 행렬 없이 조용히 빠지지 않게).
//  · 행렬 파일은 확장자로 고른 렉서가 주석·문자열을 가른다. ⚠️ **`LEXERS` 는 언어 목록이 아니라 렉서의
//    능력표다** — 파생된 언어의 확장자가 표에 없으면 건너뛰지 않고 FAIL 이다. 렉서는 닫히지 않은
//    문자열·주석·보간 구멍을 오류로 낸다: 문법을 잘못 읽어 어긋나면 대개 거기서 터진다(조용히 어긋난
//    채 끝나지 않게).
//  · 선언: 이름에 `known gap` 이 든 식별자에 대한 대입이 코드(주석·문자열 밖)에 **정확히 하나**. 우변이
//    빈 모양(`{}` · `Map.of()` · `&[]` …)이고 문장이 거기서 끝나면 빈 목록이다. 우변이 다르거나 다른
//    자리에서 그 이름에 쓰면(`[k] =` · `.Add(` · `.update(` …) 비지 않은 목록이다.
//  · 참조: 문자열 리터럴 중 내용이 `<id>: ` 로 시작하는 것 — 아홉 행렬이 선언한 값 계약 `등록부 id: 이유`
//    의 정적 발자국이다. 역사적 계산형 셋도 id 는 이 모양의 상수였다(java @986a96e 도우미 지역변수 ·
//    kotlin @73d48a1 상수 · python @0eae924 상수). 그리고 `'<id>' =>`(php 의 id 키 묶음 @569300a).
//    **파일 전체**에서 찾는다 — 계산형은 id 가 선언 앞(kotlin·python)에도 뒤(java)에도 있다.
//    주석 안의 것은 참조가 아니다 — 주석이 「id 가 있다」를 채우면 계산된 id 가 조용히 빠진다.
//  · id 문법 `ID` 는 등록부 id 전수를 덮고(대문자 첫 마디 `H1-…` · 점 `…-0.44-…`) `"W1: …"`·`"panic: …"`
//    를 거른다(실측: 그 둘이 오늘 행렬 일곱·하나에 있다). 등록부의 모든 id 가 이 문법 안인지도 매번
//    본다 — 문법 밖 id 를 가리키는 틈은 찾을 수 없기 때문이다.
//
// 판정: OPEN → 0 · CLOSED(닫힌 항목을 가리키는 낡은 틈) / UNREGISTERED → 1(DRIFT) · 판정 불가 → 2(FAIL).
// 판정 불가: 언어 0 · 행렬 없음/둘 · 렉서 없는 확장자 · 렉서 오류 · 선언 0/둘 · **비지 않은 목록인데
// id 0** · 등록부 없음/열림 0/닫힘 0/문법 밖 id · 참조된 id 의 중복·모르는 상태 표기.
// ⚠️ 아무것도 못 찾은 파서는 통과가 아니라 실패다 — 「빈 목록」은 빈 모양을 **알아봤을 때만** 빈 것이다.
//
// ⚠️ 한계(실측 — Grok 레그 두 축 포함, 정적 대조의 몫이 아니다):
//  (1) id 를 리터럴 접두로 쓰지 않는 항목은 안 보인다 — 서식(`"%s: %s"`) · 연결 · 앞말(`"wip <id>: …"`) · 문법 밖
//      토큰 · 맵 키 자리(`"<id>": …`). 같은 파일에 다른 참조가 있으면 그 항목만 조용히 빠지고, 없으면 「id 0」 으로
//      실패한다. ⚠️ 키 자리를 받지 않는 것은 판정이다 — 받으면 오늘 node 행렬의 `'content-type':` 가 거짓 참조가 된다.
//  (2) 빈 선언을 **인자로 받은 함수**가 채우면(`fill(NAME)`) 쓰기로 못 본다 — 그 값의 id 가 리터럴이면 파일 전체
//      훑기가 여전히 잡고, 계산된 id 면 조용하다.
//  둘 다 런타임 값 전수(행렬 실행)만 닫는다.
//
// 사용: node scripts/check-known-gaps.mjs [ROOT]   (ROOT 기본 = 이 저장소)
import { readFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, dirname, resolve, extname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export const REGISTRY = 'docs/superpowers/plans/remaining-work.md'

const ID = '[A-Za-z0-9]+(?:-[a-z0-9.]+)+'
export const ID_RE = new RegExp(`^${ID}$`)
// 콜론 뒤 공백은 요구하지 않는다(`id:이유` 오타도 참조다) — `::`(이름공간)만 뺀다. 행렬 파일 이력 25 판에서
// 공백 없는 `<id>:` 로 시작하는 문자열 0 건(실측) — 이 완화가 거짓 참조를 들이지 않는다.
const F1 = new RegExp(`^(${ID}):(?!:)`)

class Fatal extends Error {}
class LexError extends Error {}

// ── 렉서 ────────────────────────────────────────────────────────────────────────────────
export const LEXERS = { go: 'go', java: 'java', kt: 'kotlin', ts: 'ts', php: 'php', py: 'python', rb: 'ruby', rs: 'rust', cs: 'csharp' }

const TS_KW = new Set(['return', 'typeof', 'case', 'in', 'of', 'delete', 'void', 'throw', 'new', 'else', 'do', 'instanceof', 'yield', 'await'])
const RUBY_KW = new Set(['if', 'unless', 'when', 'and', 'or', 'not', 'return', 'then', 'else', 'elsif', 'while', 'until', 'puts', 'p', 'print', 'raise', 'yield', 'in', 'case', 'do', 'begin'])
// 정규식·% 리터럴이 올 수 있는 자리(피연산자 자리) — 직전 의미 있는 코드 문자. `)`·`]`·`}`·식별자 뒤는 나눗셈이다.
const OPERAND = new Set(['', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', ';', '+', '-', '*', '%', '<', '>', '~', '^'])

// → { masked, strings, lineOf }. masked 는 src 와 길이가 같고 주석은 공백, 문자열·리터럴은 \u0001
// (줄바꿈은 그대로)이다 — 식별자가 문자열 조각과 붙어 한 단어가 되지 않게 단어 문자가 아닌 것을 쓴다.
// strings 는 문자열 리터럴(정규식·문자·%w 류 제외)의 { start, end, cStart, cEnd }.
export function lex(src, fam) {
  const n = src.length
  const mask = new Uint8Array(n) // 0 코드 · 1 주석 · 2 문자열·리터럴
  const strings = []
  const starts = [0]
  for (let k = 0; k < n; k++) if (src[k] === '\n') starts.push(k + 1)
  const lineOf = (k) => {
    let lo = 0
    let hi = starts.length - 1
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if (starts[mid] <= k) lo = mid
      else hi = mid - 1
    }
    return lo + 1
  }
  const fail = (msg, k) => {
    throw new LexError(`${msg} (줄 ${lineOf(k)})`)
  }
  const fill = (a, b, v) => {
    for (let k = a; k < b; k++) mask[k] = v
  }
  const isW = (ch) => ch !== undefined && /[\w$]/.test(ch)
  const nested = fam === 'kotlin' || fam === 'rust'
  const slashComments = fam !== 'python' && fam !== 'ruby'
  const hashComments = fam === 'python' || fam === 'ruby' || fam === 'php'
  const heredocs = [] // ruby: 머리 줄이 끝나면 본문을 읽을 히어독들

  const eol = (k) => {
    while (k < n && src[k] !== '\n') k++
    return k
  }
  const block = (k) => {
    let d = 1
    let e = k + 2
    while (e < n && d > 0) {
      if (nested && src.startsWith('/*', e)) {
        d++
        e += 2
      } else if (src.startsWith('*/', e)) {
        d--
        e += 2
      } else e++
    }
    if (d > 0) fail('블록 주석이 닫히지 않았다', k)
    return e
  }

  // 문자열 본체. o: close · esc(역슬래시) · dquote(C# verbatim 의 "") · multi(줄바꿈 허용) · hole(보간 구멍
  // 여는 표지) · holeEsc(구멍이 아닌 겹침 `{{`) · extend(kotlin 원시 문자열의 닫는 따옴표 뒤 여분) ·
  // nestOpen(ruby % 리터럴의 괄호 중첩) · kind('str' 만 참조 후보).
  const lit = (start, cStart, o) => {
    let e = cStart
    let depth = 0
    let seg = start
    for (;;) {
      if (e >= n) fail('문자열이 닫히지 않았다', start)
      const ch = src[e]
      if (o.dquote && ch === '"' && src[e + 1] === '"') {
        e += 2
        continue
      }
      if (o.esc && ch === '\\') {
        e += 2
        continue
      }
      if (o.holeEsc && src.startsWith(o.holeEsc, e)) {
        e += o.holeEsc.length
        continue
      }
      if (o.hole && src.startsWith(o.hole, e)) {
        const inner = e + o.hole.length - (o.hole === '{$' ? 1 : 0) // php `{$x}` 는 `$` 부터 코드다
        fill(seg, inner, 2)
        e = code(inner, '}')
        mask[e - 1] = 2
        seg = e
        continue
      }
      if (o.nestOpen && ch === o.nestOpen) {
        depth++
        e++
        continue
      }
      if (depth === 0 && src.startsWith(o.close, e)) break
      if (o.nestOpen && ch === o.close) {
        depth--
        e++
        continue
      }
      if (ch === '\n' && !o.multi) fail('문자열이 줄 안에서 닫히지 않았다', start)
      e++
    }
    let cEnd = e
    let end = e + o.close.length
    if (o.extend)
      while (src[end] === '"') {
        end++
        cEnd++
      }
    fill(seg, end, 2)
    if ((o.kind ?? 'str') === 'str') strings.push({ start, end, cStart, cEnd })
    return end
  }
  const charLit = (k) => {
    let e = k + 1
    e += src[e] === '\\' ? 2 : 1
    while (e < n && src[e] !== "'" && src[e] !== '\n') e++
    if (src[e] !== "'") fail('문자 리터럴이 닫히지 않았다', k)
    fill(k, e + 1, 2)
    return e + 1
  }
  // rust 의 `'` 는 문자 리터럴이거나 수명·라벨(`'a`)이다 — 리터럴 모양이 아니면 코드로 둔다.
  const rustChar = (k) => {
    const m = /^'(?:[^\\'\n]|\\(?:[nrt0\\'"]|x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]{1,6}\}))'/u.exec(src.slice(k, k + 16))
    if (!m) return -1
    fill(k, k + m[0].length, 2)
    return k + m[0].length
  }
  const jsRegex = (k) => {
    let e = k + 1
    let cls = false
    for (;;) {
      if (e >= n || src[e] === '\n') fail('정규식 리터럴이 줄 안에서 닫히지 않았다', k)
      const ch = src[e]
      if (ch === '\\') {
        e += 2
        continue
      }
      if (cls) {
        if (ch === ']') cls = false
      } else if (ch === '[') cls = true
      else if (ch === '/') break
      e++
    }
    e++
    while (e < n && /[a-z]/i.test(src[e])) e++
    fill(k, e, 2)
    return e
  }
  const rubyFlags = (e) => {
    let f = e
    while (f < n && /[imxounse]/.test(src[f])) f++
    fill(e, f, 2)
    return f
  }
  const operand = (k, prev, prevWord, kw) => {
    if (prevWord) {
      if (kw.has(prevWord)) return true
      // `foo /re/` · `foo %w[a]` — 식별자 뒤 공백 + 구분자 뒤 비공백(루비 자신의 어림과 같다)
      return fam === 'ruby' && /\s/.test(src[k - 1]) && !/[\s=]/.test(src[k + 1] ?? ' ')
    }
    return OPERAND.has(prev)
  }
  const rubyBegin = (k) => {
    let e = k
    for (;;) {
      const le = eol(e)
      if (e !== k && /^=end(\s|$)/.test(src.slice(e, le))) return le
      if (le >= n) fail('=begin 이 =end 없이 끝났다', k)
      e = le + 1
    }
  }
  // ruby 히어독 본문 — 머리 줄의 \n(k) 다음 줄부터 종결 줄까지. 종결 줄의 \n 위치를 돌려준다.
  const rubyHeredocBodies = (k) => {
    let e = k + 1
    while (heredocs.length) {
      const h = heredocs.shift()
      const bodyStart = e
      for (;;) {
        if (e >= n) fail(`히어독 ${h.id} 이 끝나지 않았다`, h.start)
        const le = eol(e)
        const line = src.slice(e, le).replace(/\r$/, '')
        if ((h.indent ? line.trim() : line) === h.id) {
          strings.push({ start: h.start, end: le, cStart: bodyStart, cEnd: e })
          fill(bodyStart, le, 2)
          e = le
          break
        }
        e = le + 1
      }
      if (heredocs.length) e++
    }
    return e
  }

  // 그 자리에서 시작하는 문자열·리터럴의 끝, 아니면 -1.
  const literal = (k, prev, prevWord) => {
    const c = src[k]
    const bnd = k === 0 || !isW(src[k - 1])
    switch (fam) {
      case 'go':
        if (c === '"') return lit(k, k + 1, { close: '"', esc: true })
        if (c === '`') return lit(k, k + 1, { close: '`', multi: true })
        if (c === "'") return charLit(k)
        return -1
      case 'java':
        if (src.startsWith('"""', k)) return lit(k, k + 3, { close: '"""', esc: true, multi: true })
        if (c === '"') return lit(k, k + 1, { close: '"', esc: true })
        if (c === "'") return charLit(k)
        return -1
      case 'kotlin':
        if (src.startsWith('"""', k)) return lit(k, k + 3, { close: '"""', multi: true, hole: '${', extend: true })
        if (c === '"') return lit(k, k + 1, { close: '"', esc: true, hole: '${' })
        if (c === "'") return charLit(k)
        if (c === '`') return lit(k, k + 1, { close: '`', kind: 'other' }) // 역따옴표 식별자
        return -1
      case 'ts':
        if (c === '"' || c === "'") return lit(k, k + 1, { close: c, esc: true })
        if (c === '`') return lit(k, k + 1, { close: '`', esc: true, multi: true, hole: '${' })
        if (c === '/' && src[k + 1] !== '/' && src[k + 1] !== '*' && operand(k, prev, prevWord, TS_KW)) return jsRegex(k)
        return -1
      case 'csharp': {
        if (c === "'") return charLit(k)
        if (c !== '"' && !((c === '$' || c === '@') && bnd)) return -1
        const m = /^(\$*)(@?)(\$*)("{3,}|")/.exec(src.slice(k, k + 16))
        if (!m) return -1
        const dollars = m[1].length + m[3].length
        const q = m[4]
        const hole = dollars ? '{'.repeat(dollars) : null
        const holeEsc = dollars === 1 ? '{{' : null
        const cStart = k + m[0].length
        if (q.length >= 3) return lit(k, cStart, { close: q, multi: true, hole, holeEsc })
        if (m[2] === '@') return lit(k, cStart, { close: '"', dquote: true, multi: true, hole, holeEsc })
        return lit(k, cStart, { close: '"', esc: true, hole, holeEsc })
      }
      case 'rust': {
        if (bnd) {
          const m = /^[bc]?r(#*)"/.exec(src.slice(k, k + 40))
          if (m) return lit(k, k + m[0].length, { close: '"' + m[1], multi: true })
          if ((c === 'b' || c === 'c') && src[k + 1] === '"') return lit(k, k + 2, { close: '"', esc: true, multi: true })
          if (c === 'b' && src[k + 1] === "'") return rustChar(k + 1)
        }
        if (c === '"') return lit(k, k + 1, { close: '"', esc: true, multi: true })
        if (c === "'") return rustChar(k)
        return -1
      }
      case 'python': {
        const m = /^([rRbBuUfF]{0,2})('''|"""|'|")/.exec(src.slice(k, k + 5))
        if (!m || (m[1] && !bnd)) return -1
        const f = /f/i.test(m[1])
        return lit(k, k + m[0].length, { close: m[2], esc: true, multi: m[2].length === 3, hole: f ? '{' : null, holeEsc: f ? '{{' : null })
      }
      case 'ruby': {
        if (c === "'") return lit(k, k + 1, { close: "'", esc: true, multi: true })
        if (c === '"') return lit(k, k + 1, { close: '"', esc: true, multi: true, hole: '#{' })
        if (c === '`') return lit(k, k + 1, { close: '`', esc: true, multi: true, hole: '#{', kind: 'other' })
        if (c === '%' && operand(k, prev, prevWord, RUBY_KW)) {
          const m = /^%([qQwWiIrsx]?)([^\w\s])/.exec(src.slice(k, k + 3))
          if (m) {
            const pairs = { '(': ')', '[': ']', '{': '}', '<': '>' }
            const t = m[1]
            const interp = t === '' || 'QWIrx'.includes(t)
            const e = lit(k, k + m[0].length, {
              close: pairs[m[2]] ?? m[2],
              esc: true,
              multi: true,
              hole: interp ? '#{' : null,
              nestOpen: pairs[m[2]] ? m[2] : null,
              kind: t === '' || t === 'q' || t === 'Q' ? 'str' : 'other',
            })
            return t === 'r' ? rubyFlags(e) : e
          }
        }
        if (c === '/' && operand(k, prev, prevWord, RUBY_KW))
          return rubyFlags(lit(k, k + 1, { close: '/', esc: true, multi: true, hole: '#{', kind: 'other' }))
        if (c === '<' && src[k + 1] === '<') {
          const m = /^<<([~-]?)(["'`]?)([A-Za-z_]\w*)\2/.exec(src.slice(k, k + 64))
          if (m && (m[1] || m[2] || /^[A-Z_][A-Z0-9_]*$/.test(m[3])) && operand(k, prev, prevWord, RUBY_KW)) {
            heredocs.push({ id: m[3], indent: m[1] !== '', start: k })
            fill(k, k + m[0].length, 2)
            return k + m[0].length
          }
        }
        return -1
      }
      case 'php': {
        if (c === "'") return lit(k, k + 1, { close: "'", esc: true, multi: true })
        if (c === '"') return lit(k, k + 1, { close: '"', esc: true, multi: true, hole: '{$' })
        if (c === '`') return lit(k, k + 1, { close: '`', esc: true, multi: true, hole: '{$', kind: 'other' })
        if (src.startsWith('<<<', k)) {
          const m = /^<<<[ \t]*(["']?)([A-Za-z_]\w*)\1\r?\n/.exec(src.slice(k, k + 80))
          if (!m) fail('히어독 머리를 읽지 못했다', k)
          const bodyStart = k + m[0].length
          const term = new RegExp(`^[ \\t]*${m[2]}(?![\\w])`)
          for (let e = bodyStart; ; ) {
            if (e >= n) fail(`히어독 ${m[2]} 이 끝나지 않았다`, k)
            const le = eol(e)
            const t = term.exec(src.slice(e, le))
            if (t) {
              strings.push({ start: k, end: e + t[0].length, cStart: bodyStart, cEnd: e })
              fill(k, e + t[0].length, 2)
              return e + t[0].length
            }
            e = le + 1
          }
        }
        return -1
      }
      default:
        throw new LexError(`렉서 계열 ${fam} 을 모른다`)
    }
  }

  // 코드. closer 가 '}' 면 보간 구멍 — 짝 맞는 `}` 다음 위치를 돌려준다.
  function code(k, closer) {
    let depth = 0
    let prev = ''
    let prevWord = ''
    while (k < n) {
      const c = src[k]
      if (c === '\n') {
        if (heredocs.length) {
          k = rubyHeredocBodies(k)
          prev = ''
          prevWord = ''
          continue
        }
        if (fam === 'ruby') {
          prev = ''
          prevWord = ''
        }
        k++
        if (fam === 'ruby') {
          if (/^=begin(\s|$)/.test(src.slice(k, k + 7))) {
            const e = rubyBegin(k)
            fill(k, e, 1)
            k = e
          } else if (/^__END__\r?(\n|$)/.test(src.slice(k, k + 9))) {
            fill(k, n, 1)
            return n
          }
        }
        continue
      }
      if (slashComments && src.startsWith('//', k)) {
        const e = eol(k)
        fill(k, e, 1)
        k = e
        continue
      }
      if (hashComments && c === '#' && !(fam === 'php' && src[k + 1] === '[')) {
        const e = eol(k)
        fill(k, e, 1)
        k = e
        continue
      }
      if (slashComments && src.startsWith('/*', k)) {
        const e = block(k)
        fill(k, e, 1)
        k = e
        continue
      }
      const e = literal(k, prev, prevWord)
      if (e >= 0) {
        k = e
        prev = '"'
        prevWord = ''
        continue
      }
      if (closer !== null) {
        if (c === '{') depth++
        else if (c === '}') {
          if (depth === 0) return k + 1
          depth--
        }
      }
      if (/[A-Za-z_$]/.test(c)) {
        let w = k + 1
        while (w < n && /[\w$]/.test(src[w])) w++
        if (fam === 'ruby' && (src[w] === '?' || src[w] === '!') && src[w + 1] !== '=') w++
        prevWord = src.slice(k, w)
        prev = src[w - 1]
        k = w
        continue
      }
      if (!/\s/.test(c)) {
        prev = c
        prevWord = ''
      }
      k++
    }
    if (closer !== null) fail('보간 구멍이 닫히지 않았다', n - 1)
    if (heredocs.length) fail(`히어독 ${heredocs[0].id} 의 본문이 없다`, heredocs[0].start)
    return k
  }

  let k0 = 0
  if (fam === 'ts' && src.startsWith('#!')) {
    k0 = eol(0)
    fill(0, k0, 1)
  }
  code(k0, null)
  const out = new Array(n)
  for (let k = 0; k < n; k++) {
    const ch = src[k]
    out[k] = ch === '\n' || ch === '\r' ? ch : mask[k] === 1 ? ' ' : mask[k] === 2 ? '\u0001' : ch
  }
  return { masked: out.join(''), strings, lineOf }
}

// ── 선언 · 참조 추출 ─────────────────────────────────────────────────────────────────────
// 대입 꼬리: 이름 뒤 선택적 타입 표기(`: T`) 후 `=`(`==`·`=>`·`=~` 아님). go 는 `var x T = …` 도.
const DECL_TAIL = /^[ \t]*(?::[^=\n;]*?)?=(?![=>~])/
const GO_TYPED = /^[ \t]+[\w.[\]*]+[ \t]*=(?![=>~])/
// 빈 모양 — 우변 전체가 이것이어야 한다(`;` 하나는 허용). 모르는 빈 철자는 비지 않은 것으로 읽혀 id 를
// 요구하고, 없으면 FAIL 이다(조용히 빈 것으로 치지 않는다).
const EMPTY = new RegExp(
  '^(?:' +
    [
      String.raw`\{\s*\}(?:\.freeze)?`,
      String.raw`&?\[\s*\]`,
      String.raw`map\[string\]string\{\s*\}`,
      String.raw`(?:Map\.of|emptyMap|mapOf|dict)\(\s*\)`,
      String.raw`new(?:\s+[A-Za-z_][\w.]*\s*<[^>]*>)?\(\s*(?:StringComparer\.\w+)?\s*\)`,
    ].join('|') +
    ')$',
)
// 문장이 `;` 로 끝나야 하는 계열 — `;` 없는 빈 모양은 다음 줄로 이어진다(초기화 블록 등).
const SEMI = new Set(['java', 'csharp', 'rust', 'php'])
// 줄바꿈이 문장을 끝내지 않는 경우 — 다음 코드 줄이 이것으로 시작하면 이어진다. go·python 은 끝낸다.
const CONT = {
  ts: /^(?:[.([`+\-*/%,?:|&=<>]|in\b|instanceof\b)/,
  kotlin: /^(?:\.|\?\.|\?:|&&|\|\||as\b)/,
  ruby: /^(?:\.|&\.)/,
}
const WRITE_VERB = String.raw`Add|TryAdd|add|put\w*|set\w*|update!?|merge!?|store|insert|extend|push|append|assign|compute\w*`

export function extract(src, fam) {
  const { masked, strings, lineOf } = lex(src, fam)
  const decls = []
  for (const m of masked.matchAll(/[A-Za-z_][A-Za-z0-9_]*/g)) {
    if (!m[0].toLowerCase().replace(/_/g, '').includes('knowngap')) continue
    const rest = masked.slice(m.index + m[0].length, m.index + m[0].length + 400)
    const t = DECL_TAIL.exec(rest) ?? (fam === 'go' ? GO_TYPED.exec(rest) : null)
    if (t) decls.push({ name: m[0], at: m.index, eq: m.index + m[0].length + t[0].length })
  }
  if (decls.length === 0)
    throw new Fatal('KNOWN_GAPS 선언을 못 찾았다(주석·문자열 밖에서, 이름에 known gap 이 든 식별자에 대한 대입이 0)')
  if (decls.length > 1)
    throw new Fatal(`KNOWN_GAPS 선언이 ${decls.length}개다(줄 ${decls.map((d) => lineOf(d.at)).join(', ')}) — 어느 것이 목록인지 가를 수 없다`)
  const d = decls[0]

  const lineEnd = (p) => {
    const e = masked.indexOf('\n', p)
    return e < 0 ? masked.length : e
  }
  const nextCodeLine = (p) => {
    for (let s = p; s < masked.length; ) {
      const e = lineEnd(s + 1)
      const text = masked.slice(s + 1, e)
      if (text.trim() !== '') return { text, end: e }
      s = e
    }
    return null
  }
  let end = lineEnd(d.eq)
  let rhsAt = d.eq
  let rhs = masked.slice(d.eq, end).trim()
  if (rhs === '') {
    const nl = nextCodeLine(end)
    if (nl) {
      rhsAt = nl.end - nl.text.length
      rhs = nl.text.trim()
      end = nl.end
    }
  }
  const clip = (s) => (s.length > 60 ? `${s.slice(0, 60)}…` : s)
  let notEmpty = '' // 비지 않다고 읽은 이유 — 빈 문자열이면 빈 목록
  if (!EMPTY.test(rhs.replace(/;\s*$/, '').trim()))
    notEmpty = `비지 않은 목록이다(우변 \`${clip(src.slice(rhsAt, lineEnd(rhsAt)).trim())}\`)`
  else if (SEMI.has(fam) && !/;\s*$/.test(rhs)) notEmpty = '빈 모양이지만 `;` 로 끝나지 않아 문장이 다음 줄로 이어진다'
  else if (CONT[fam]) {
    const nl = nextCodeLine(end)
    if (nl && CONT[fam].test(nl.text.trimStart())) notEmpty = `빈 모양이지만 다음 줄(\`${clip(nl.text.trim())}\`)로 문장이 이어진다`
  }

  // 다른 자리에서 그 이름에 쓰는 모양 — 하나라도 있으면 비지 않은 목록으로 읽고 id 를 요구한다.
  // php 의 `$` 는 변수 표지라(`self::$knownGaps[…] = …`) 이름 앞에 와도 같은 이름이다 — 다른 언어에서는 식별자 글자다.
  const NAME = `(?<![\\w${fam === 'php' ? '' : '$'}])${d.name}(?![\\w$])`
  const ASSIGN = String.raw`(?:[-+*/%|&^]?=(?![=>~])|\|\|=|&&=|\?\?=)`
  const WRITES = [
    // 첨자·복합 대입: NAME[k] = v · NAME |= …
    new RegExp(String.raw`${NAME}\s*(?:\[[^\]\n]*\]\s*${ASSIGN}|(?:[-+|&^]=|\|\|=|\?\?=))`, 'g'),
    // 쓰는 메서드: NAME.Add( · .put( · .update( · .merge!( …
    new RegExp(String.raw`${NAME}\s*\.\s*(?:${WRITE_VERB})\s*\(`, 'g'),
    // 필드 쓰기: NAME.x = v — Grok 레그가 지목했고 이 줄 전에는 빈 목록으로 속았다(실측)
    new RegExp(String.raw`${NAME}\s*\.\s*[A-Za-z_$][\w$]*\s*${ASSIGN}`, 'g'),
    // 쓰라고 넘김: Object.assign(NAME · maps.Copy(NAME
    new RegExp(String.raw`(?:Object\.assign|maps\.Copy)\s*\(\s*${NAME}`, 'g'),
    // 별칭: x := NAME · x = NAME 가 그 줄의 끝 — 별칭에 쓰면 이름만 보는 위 넷이 못 본다(Grok 레그 실측)
    new RegExp(String.raw`(?<![=!<>:])(?::=|=)(?![=>~])[ \t]*${NAME}[ \t]*;?[ \t]*\r?$`, 'gm'),
  ]
  // 주소로 넘김 — go 만이다(python 의 `x & NAME.keys()` 는 읽기다).
  if (fam === 'go') WRITES.push(new RegExp(String.raw`(?<![\w$&])&\s*${NAME}`, 'g')) // json.Unmarshal(b, &NAME)
  const writes = WRITES.flatMap((re) => [...masked.matchAll(re)].map((w) => lineOf(w.index)))

  const refs = []
  for (const s of strings) {
    const content = src.slice(s.cStart, s.cEnd)
    const v = F1.exec(content.trimStart())
    if (v) refs.push({ id: v[1], line: lineOf(s.start) })
    else if (ID_RE.test(content) && /^[ \t]*=>/.test(src.slice(s.end, s.end + 16))) refs.push({ id: content, line: lineOf(s.start) })
  }

  if (!notEmpty && writes.length) notEmpty = `빈 모양으로 선언하고 다른 자리에서 쓴다(줄 ${writes.join(', ')})`
  if (notEmpty && refs.length === 0)
    throw new Fatal(`${notEmpty} — 그런데 등록부 id 리터럴(\`"<id>: …"\` · \`'<id>' =>\`)이 0 이라 대조할 수 없다`)
  return { name: d.name, line: lineOf(d.at), empty: !notEmpty, refs }
}

// ── 등록부 ─────────────────────────────────────────────────────────────────────────────
// 항목 = 최상위 `- [ ] \`id\``(열림) · `- [x] \`id\``(닫힘). 하위 불릿의 언급·들여쓴 체크박스는 항목이 아니다.
export function parseRegistry(text) {
  const byId = new Map()
  let open = 0
  let closed = 0
  const outside = []
  text.split(/\r?\n/).forEach((l, i) => {
    const m = /^- \[(.)\] `([^`]+)`/.exec(l)
    if (!m) return
    const state = m[1] === ' ' ? 'open' : m[1] === 'x' ? 'closed' : 'unknown'
    if (state === 'open') open++
    else if (state === 'closed') closed++
    if (!ID_RE.test(m[2])) outside.push(m[2])
    if (!byId.has(m[2])) byId.set(m[2], [])
    byId.get(m[2]).push({ state, line: i + 1 })
  })
  if (open === 0 || closed === 0)
    throw new Fatal(`등록부에서 열린 항목 ${open} · 닫힌 항목 ${closed} 을 읽었다 — 추출이 깨졌다(0 을 대조의 한쪽으로 쓰지 않는다)`)
  if (outside.length)
    throw new Fatal(`등록부 id ${outside.map((x) => `\`${x}\``).join(', ')} 가 참조 추출 문법 \`${ID}\` 밖이다 — 그 id 를 가리키는 틈을 찾을 수 없다`)
  return { byId, open, closed }
}

// ── 트리 ───────────────────────────────────────────────────────────────────────────────
// 언어 집합은 손으로 적지 않는다 — 이 저장소의 파생 규칙(`df_tree_langs`)을 대상 트리에 적용한다.
function deriveLangs(root) {
  const out = execFileSync('sh', ['-c', '. scripts/lib/deploy-facts.sh && df_tree_langs "$1"', 'sh', root.replace(/\\/g, '/')], {
    cwd: REPO,
    encoding: 'utf8',
  })
  return out.split(/\s+/).filter(Boolean)
}
function trackedUnder(root, lang) {
  return execFileSync('git', ['-C', root, 'ls-files', '-z', '--', `${lang}/`], { encoding: 'utf8', maxBuffer: 64 << 20 })
    .split('\0')
    .filter(Boolean)
}
const isMatrix = (p) => basename(p).toLowerCase().replace(/[^a-z]/g, '').includes('hostilepathmatrix')

function main() {
  const root = resolve(process.argv[2] ?? REPO)
  const fails = [] // [언어, 자리, 이유] → exit 2
  const drifts = [] // → exit 1
  let langs = []
  try {
    langs = deriveLangs(root)
  } catch (e) {
    fails.push(['-', root, `언어 집합 파생이 실패했다: ${e.message}`])
  }
  if (langs.length === 0 && fails.length === 0) fails.push(['-', root, '파생된 언어가 0 개다 — 0 개를 훑고 통과하지 않는다'])

  let reg = null
  try {
    const p = join(root, REGISTRY)
    if (!existsSync(p)) throw new Fatal('등록부 파일이 없다')
    reg = parseRegistry(readFileSync(p, 'utf8'))
  } catch (e) {
    if (!(e instanceof Fatal)) throw e
    fails.push(['-', REGISTRY, e.message])
  }

  let nRefs = 0
  for (const lang of langs) {
    let rel = `${lang}/`
    try {
      const files = trackedUnder(root, lang).filter(isMatrix)
      if (files.length !== 1)
        throw new Fatal(files.length ? `행렬 파일이 ${files.length}개다(${files.join(', ')})` : '행렬 파일이 없다(basename 에 hostile-path-matrix)')
      rel = files[0]
      const ext = extname(rel).slice(1)
      const fam = LEXERS[ext]
      if (!fam) throw new Fatal(`렉서가 없는 확장자 .${ext} — 새 문법이면 LEXERS 에 렉서를 더한다(건너뛰지 않는다)`)
      const g = extract(readFileSync(join(root, rel), 'utf8'), fam)
      console.log(`ok    ${lang.padEnd(8)} ${rel}:${g.line}  ${g.name} — ${g.empty ? '빈 목록' : `참조 ${g.refs.length}`}`)
      for (const r of g.refs) {
        nRefs++
        if (!reg) continue
        const hits = reg.byId.get(r.id)
        const where = `${rel}:${r.line}`
        if (!hits) drifts.push(`UNREGISTERED ${lang} ${where} ${r.id} — 등록부에 그런 항목이 없다`)
        else if (hits.length > 1)
          fails.push([lang, where, `id ${r.id} 가 등록부에 ${hits.length}번 있다(줄 ${hits.map((h) => h.line).join(', ')}) — 열림/닫힘을 가를 수 없다`])
        else if (hits[0].state === 'unknown') fails.push([lang, where, `id ${r.id} 의 등록부 상태 표기를 모른다(줄 ${hits[0].line})`])
        else if (hits[0].state === 'closed') drifts.push(`CLOSED ${lang} ${where} ${r.id} — 등록부 ${hits[0].line}행에서 닫혔는데 틈으로 남아 있다`)
        else console.log(`OPEN ${lang} ${where} ${r.id} — 등록부 ${hits[0].line}행`)
      }
    } catch (e) {
      if (!(e instanceof Fatal) && !(e instanceof LexError) && !e.status) throw e
      fails.push([lang, rel, e.message])
    }
  }

  for (const d of drifts) console.error(`::error::${d}`)
  for (const [lang, where, msg] of fails) console.error(`::error::FAIL ${lang} ${where} — ${msg}`)
  console.log(
    `known-gaps ↔ 등록부: 언어 ${langs.length} · 참조 ${nRefs} · 등록부 열림 ${reg?.open ?? '?'} / 닫힘 ${reg?.closed ?? '?'} · drift ${drifts.length} · 판정 불가 ${fails.length}`,
  )
  process.exit(fails.length ? 2 : drifts.length ? 1 : 0)
}

// 자가테스트가 import 로 순수 함수만 쓸 수 있게 — 직접 실행일 때만 main.
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop())) {
  try {
    main()
  } catch (e) {
    console.error(`::error::FAIL - - — 예상하지 못한 오류(판정 불가): ${e.stack ?? e}`)
    process.exit(2)
  }
}
