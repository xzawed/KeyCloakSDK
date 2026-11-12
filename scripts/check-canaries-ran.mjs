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
//    조용히 비켜 가지 않게. 가드 **밖**의 레인 카나리아 표(`scripts/test/test-lane-canaries.sh` — 덤프 걷기 · bearer
//    정본 표)도 같은 방식이고, 그 파일은 `lc_…_canary() {` 정의 수가 그 축 수와 같아야 한다.
//  · 카나리아 줄 → 그 줄이 선언한 테스트(RESOLVE) → 보고서 항목. 선언 이름(node·ruby 는 제목 리터럴)이 **카나리아 문자열의
//    자리와 겹쳐야** 한다 — 아니면 같은 줄의 다른 테스트를 카나리아로 읽는다. go 만 본문 줄(표 행 · 단언 호출)을 받고 그
//    줄을 감싼 최상위 `func Test…` 로 간다. 항목은 정확히 맞춘다: 클래스(JVM·.NET·python) · describe 경로(node) · 모듈 경로
//    (rust) · 정의 줄(ruby `line_number`) · 파일(php).
//  · 항목이 없으면 FAIL(이 실행에서 돌지 않았다 — 필터·제외·이름 바뀜), 건너뛰었거나 실패한 항목이 하나라도 있으면 FAIL.
//    매개변수 테스트(항목 여럿)는 전부 통과해야 한다. go 는 최상위 항목이 있어야 하고, `t.Run(` 을 여는 테스트는 서브테스트도
//    하나 이상 보고돼야 한다. 뒤집힌 테스트(`it.fails` · vitest 옵션 `{ fails: true }` · `#[should_panic]`)는 통과가 곧 단언
//    실패라 FAIL 이다.
//  · 보고서 형식은 언어가 정한다(FORMAT) — JUnit XML · TRX · `go test -v` · libtest 출력 · RSpec JSON.
//  · ⚠️ **이름을 정할 수 없는 모양은 추측하지 않고 판정 불가(2)다** — 추측은 건강한 실행을 FAIL 로 냈다(독립 레그 2 실측).
//    리터럴이 아닌 describe(`.each` · 식별자 · `${}`) · 함수 안의 python def · 패키지 수준 go 표 · `#[path]` rust 모듈 ·
//    표시 이름을 바꾸는 kotlin 어노테이션(`@ParameterizedTest` 등) · 가릴 수 없는 vitest 옵션(변수 · 펼침 · 리터럴 아닌
//    `fails`). 오늘의 카나리아는 전부 받는 모양이다 — 그 밖의 모양을
//    들이는 PR 이 그 레인에서 이유와 함께 운다.
// ⚠️ 못 보는 것(독립 레그 실측 · 기대 개수나 내용의 원천이 보고서 밖이다): 매개변수 행·서브테스트 **일부만** 빼는 필터
//    (pytest `--deselect 'x[None]'` · go `-skip 'TestX/one'`) · 다른 파일(또는 두 단계 넘어)의 헬퍼가 여는 go 서브테스트를 전부
//    빼는 필터 · 카나리아를
//    필터로 빼고 **다른 패키지(go)·같은 파일의 다른 클래스(php)** 에 같은 이름을 둔 경우(그냥 skip 이면 두 항목이 다 잡혀
//    FAIL 이다) · 본문 바꿔치기(이름 재바인딩 · 단언 삭제 — 실행 증명이 아니라 행위 테스트·변이의 몫이다). go `(cached)` 재생과
//    RSpec `--dry-run` 은 받는다 — 앞은 같은 입력의 같은 결과이고(레인은 `-count=1`), 뒤는 레인 전체를 비워 attest 가 운다.
//    소스로 뒤집힘을 숨기는 꼴(#1018 레그 실측 — 리터럴 밖이라 추측해야 하는 것): 별칭(`const t = it.fails; t(…)`) · 실행
//    중 task 변경(`Object.assign(task, { fails: true })`) · vitest 태그 옵션(`tags` 가 fails 를 싣는다) · 옵션 변수에 함수
//    참조 테스트(`it(제목, opts, fnRef)` 는 `it(제목, fn, SLOW_MS)` 와 못 가른다) · go 표준 출력에 찍은 가짜 `--- PASS:` 줄 ·
//    ruby 같은 줄의 미끼 예제. W1 행렬이 덮는 카나리아는 앞의 둘 중 일부를 레인에서 따로 잡는다(앵커 블록이 사라진다).
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
// 가드 **밖**의 레인 카나리아 표(덤프 걷기 · bearer 정본 표) — 가드에 두면 아홉 행렬의 W1 이 그 행을 손 목록에 요구한다.
// 그 파일 머리 주석이 까닭을 적는다. 축 수 대조는 호출 자리가 아니라 `lc_…_canary() {` 정의 수로 한다.
export const LANE = 'scripts/test/test-lane-canaries.sh'

// 카나리아 표 — 축마다 표 함수와 그 행의 모양. `file` 이 있으면 행은 카나리아 문자열뿐이고 파일은 그 함수가 준다.
// `src` 가 없으면 가드의 표다.
export const AXES = [
  { axis: 'nonce', rows: 'sd_nonce_canary', shape: 'file|canary' },
  { axis: 'backoff', rows: 'sd_backoff_canary', shape: 'file|canary' },
  // java·kotlin 의 백오프 면제 근거(Nimbus 가 콜드 적재도 rate-limit 한다는 것을 고정하는 시험) — 나머지 일곱은 행이 없다.
  { axis: 'backoff-exempt', rows: 'sd_backoff_exempt', shape: 'file|canary' },
  { axis: 'mask', file: 'sd_mask_test', rows: 'sd_mask_canary', shape: 'canary' },
  { axis: 'mask2', file: 'sd_mask2_test', rows: 'sd_mask2_canary', shape: 'canary' },
  { axis: 'token-type', rows: 'sd_token_type_anchor', shape: 'kind|file|canary' },
  { axis: 'empty', rows: 'sd_empty_canary', shape: 'file|canary' },
  { axis: 'dump', src: LANE, rows: 'lc_dump_canary', shape: 'file|canary' },
  { axis: 'bearer', src: LANE, rows: 'lc_bearer_canary', shape: 'file|canary' },
]
const CALL_SITE = /^[^#]*\bsd_canary_ok\s+"\$ROOT\//
// 정의 수는 꼴을 너그럽게 센다(`이름 () {` · `function 이름 {`) — 정식 꼴만 세면 공백 하나로 새 표가 축 수 대조를 비켜 갔다
// (#1033 레그 C2). 그런 꼴의 표는 fnDef 가 못 읽으니 AXES 에 더하는 순간 판정 불가로 드러난다.
const LANE_DEF = /^\s*(?:function\s+)?lc_[a-z0-9_]+_canary\s*(?:\(\s*\))?\s*\{/

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
// 가드에서 표 함수 정의를 떼어 낸다 — `sed -n '/^이름() {/,/^}/p'` 와 같은 범위(줄 머리 정의 ~ 그 뒤 첫 줄 머리 `}`).
export function fnDef(text, fn) {
  const lines = text.split(/\r?\n/)
  const start = lines.findIndex((l) => l.startsWith(`${fn}() {`))
  if (start < 0) return null
  const end = lines.findIndex((l, i) => i > start && l.startsWith('}'))
  return end < 0 ? null : lines.slice(start, end + 1).join('\n')
}
// 실행할 스크립트 — 표 함수 정의 + 행을 찍는 줄. 경로는 셸에 넘기지 않는다(정의는 여기서 떼어 stdin 으로 준다).
function extractScript(defs, axes) {
  const lines = ['set -eu', 'L="$1"', ...defs]
  // 표 함수마다 출력을 먼저 변수로 받고 종료코드를 본다 — `"$(f)"` 를 printf 의 인자로 쓰면 그 안의 실패가 set -e 에
  // 걸리지 않아 행이 조용히 줄었다(독립 레그 실측: 표 함수가 정의 밖 헬퍼를 부르면 2 행 → 1 행 · rc 0).
  const call = (fn, v) => `${v}="$(${fn} "$L")" || { printf 'FNFAIL %s\\n' ${sq(fn)} >&2; exit 4; }`
  for (const a of axes) {
    const ax = sq(a.axis)
    if (a.shape === 'file|canary')
      lines.push(call(a.rows, 'o'), `printf '%s\\n' "$o" | while IFS= read -r r; do if [ -n "$r" ]; then printf '%s\\t%s\\n' ${ax} "$r"; fi; done`)
    else if (a.shape === 'canary')
      lines.push(
        call(a.file, 'f'),
        call(a.rows, 'o'),
        `printf '%s\\n' "$o" | while IFS= read -r c; do if [ -n "$c" ]; then printf '%s\\t%s|%s\\n' ${ax} "$f" "$c"; fi; done`,
      )
    else if (a.shape === 'kind|file|canary')
      lines.push(
        call(a.rows, 'o'),
        `printf '%s\\n' "$o" | while IFS='|' read -r k f c; do if [ "$k" = canary ]; then printf '%s\\t%s|%s\\n' ${ax} "$f" "$c"; fi; done`,
      )
    else throw new Error(`모르는 행 모양 ${a.shape}`)
  }
  lines.push('exit 0')
  return lines.join('\n')
}

export function canaries(root, lang, axes = AXES) {
  const out = []
  // 표 파일마다(가드 · 레인 표) — 축의 순서는 AXES 그대로다(가드의 축이 앞).
  for (const src of [...new Set(axes.map((a) => a.src ?? GUARD))]) out.push(...canariesOf(root, lang, src, axes.filter((a) => (a.src ?? GUARD) === src)))
  return out
}

function canariesOf(root, lang, src, axes) {
  const what = src === GUARD ? '가드' : '레인 카나리아 표'
  let text
  try {
    text = readFileSync(join(root, src), 'utf8')
  } catch (e) {
    throw new Unreadable(`${what}를 못 읽었다: ${src} (${e.code ?? e.message})`)
  }
  const lines = text.split(/\r?\n/)
  if (src === GUARD) {
    const sites = lines.filter((l) => CALL_SITE.test(l)).length
    if (sites !== axes.length)
      throw new Unreadable(
        `가드에서 \`sd_canary_ok "$ROOT/…\` 를 부르는 자리가 ${sites} 인데 이 검사가 아는 축은 ${axes.length} 다 — ` +
          '새 카나리아 축이면 AXES 에 그 표 함수를 더하라(안 그러면 그 축은 실행 여부를 아무도 안 본다)',
      )
  } else {
    const defs = lines.filter((l) => LANE_DEF.test(l)).length
    if (defs !== axes.length)
      throw new Unreadable(
        `${src} 에 \`lc_…_canary() {\` 표 함수가 ${defs} 인데 이 검사가 아는 레인 축은 ${axes.length} 다 — ` +
          '새 표 함수면 AXES 에 더하라(안 그러면 그 표는 실행 여부를 아무도 안 본다)',
      )
  }
  const defs = []
  for (const fn of new Set(axes.flatMap((a) => (a.file ? [a.file, a.rows] : [a.rows])))) {
    const d = fnDef(text, fn)
    if (d === null) throw new Unreadable(`${what}에 표 함수 \`${fn}() {\` 가 없다 — 이름이나 모양(줄 머리 정의 · 줄 머리 \`}\`)이 바뀌었나?`)
    defs.push(d)
  }
  // LC_ALL=C — 러너의 로캘이 없으면 sh 가 setlocale 경고를 stderr 에 찍어 아래 거절에 걸렸다(독립 레그 2 실측). 표의 행은
  // 바이트 그대로 지나간다(C 로캘은 바이트를 바꾸지 않는다).
  const r = spawnSync('sh', ['-s', '--', lang], { input: extractScript(defs, axes), encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' } })
  if (r.error) throw new Unreadable(`sh 를 못 띄웠다: ${r.error.message}`)
  // stderr 에 무엇이든 찍히면 믿지 않는다 — 함수 중간의 실패(정의 밖 헬퍼 · 없는 변수)는 마지막 명령이 성공하면 종료코드에 안 남는다.
  if (r.status !== 0 || r.stderr.trim() !== '')
    throw new Unreadable(`표 함수를 실행하다 실패했다(rc ${r.status}) — 정의 밖의 무엇(헬퍼 · 변수)에 기대나?: ${r.stderr.trim().slice(0, 400)}`)
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
  // 선언 꼴 카나리아는 그 선언 자체여야 한다 — 문자열 안의 같은 글자를 받으면 그 문자열을 담은 **다른** 테스트가 카나리아
  // 대신 돌아 통과로 읽혔다(#1017 레그 실측: go 는 감싼 함수로 · node 는 제목이 `it('…'` 인 가짜 시험으로, 진짜 선언은
  // 공백 · `.skip` 으로 비켜 두고). node 는 파일 단위로 비운 글(maskJs — 여러 줄 템플릿 · 줄 중간 주석까지)에서 보고
  // (#1018 레그: 템플릿 속 가짜 줄), go · ruby 는 줄 단위다. go 의 선언은 줄 머리다(gofmt) — 따옴표 없는 줄의 들여쓴
  // 글자를 막는다. 0 열의 raw 문자열 줄은 못 막지만 go 는 이름으로 항목을 찾아 진짜 시험의 항목에 닿는다. 이름으로 보고서
  // 항목을 찾는 언어(JVM · .NET · php · python · rust)는 같은 이름의 진짜 항목에 닿아 해당 없다.
  const decl = DECL_SHAPED[lang]
  if (decl && decl.test(canary)) {
    const { at: i, span } = at[0]
    const code = lang === 'node' ? maskJs(lines.join('\n')).split('\n')[i] : blankStrings(lines[i])
    if (code[span[0]] !== lines[i][span[0]] || (lang === 'go' && span[0] !== 0))
      throw new Unreadable(`${file}:${i + 1}: 선언 꼴 카나리아 ${JSON.stringify(canary)} 가 선언 자리가 아니다(문자열 · 주석 안 · 줄 머리 밖) — 그 자리를 담은 다른 테스트를 카나리아로 읽게 된다`)
  }
  return at[0]
}

const REGEX_KEYWORDS = new Set(['return', 'typeof', 'case', 'do', 'else', 'in', 'instanceof', 'new', 'delete', 'void', 'throw', 'yield', 'await', 'of'])
// JS/TS 를 **파일 단위로** 훑어 문자열 · 템플릿(`${}` 안까지) · 주석 · 정규식 리터럴의 안을 공백으로 비운다 — 줄바꿈은
// 그대로라 줄 · 열이 원문과 맞는다. 줄 단위 blankStrings 는 여러 줄 템플릿과 주석을 못 봤다(#1018 레그 실측: 템플릿 속
// 가짜 선언 줄 · `{ /* } */ fails: true }` · 인자 사이 주석의 오탐 · 감싼 함수 속 템플릿의 괄호). `keepStrings` 면 주석 ·
// 정규식만 비운다(옵션 객체에서 `fails` 가 문자열에도 나오는지 셀 때). 정규식은 앞 글자로 가른다(`(,=:[!&|?{};` 뒤) —
// 나눗셈과 헷갈리면 덜 비울 뿐 더 비우지 않는다.
export function maskJs(text, keepStrings = false) {
  const out = text.split('')
  const n = text.length
  const blank = (a, b) => {
    for (let k = a; k < b; k++) if (out[k] !== '\n' && out[k] !== '\r') out[k] = ' '
  }
  const quoted = (i) => {
    const q = text[i]
    let k = i + 1
    while (k < n && text[k] !== q && text[k] !== '\n') k += text[k] === '\\' ? 2 : 1
    return Math.min(k + 1, n)
  }
  const template = (i) => {
    let k = i + 1
    while (k < n && text[k] !== '`') {
      if (text[k] === '\\') k += 2
      else if (text[k] === '$' && text[k + 1] === '{') k = expr(k + 2)
      else k++
    }
    return Math.min(k + 1, n)
  }
  // `${` 뒤의 식 — 짝 `}` 다음 자리. 식 안의 문자열 · 템플릿 · 주석은 건너뛴다.
  const expr = (i) => {
    let depth = 1
    let k = i
    while (k < n) {
      const c = text[k]
      if (c === "'" || c === '"') k = quoted(k)
      else if (c === '`') k = template(k)
      else if (c === '/' && text[k + 1] === '*') k = blockEnd(k)
      else if (c === '/' && text[k + 1] === '/') k = lineEnd(k)
      else {
        if (c === '{') depth++
        else if (c === '}' && --depth === 0) return k + 1
        k++
      }
    }
    return n
  }
  const blockEnd = (i) => {
    const e = text.indexOf('*/', i + 2)
    return e < 0 ? n : e + 2
  }
  const lineEnd = (i) => {
    const e = text.indexOf('\n', i)
    return e < 0 ? n : e
  }
  const regex = (i) => {
    let k = i + 1
    let cls = false
    while (k < n && text[k] !== '\n') {
      if (text[k] === '\\') k += 2
      else if (cls) {
        if (text[k] === ']') cls = false
        k++
      } else if (text[k] === '[') {
        cls = true
        k++
      } else if (text[k] === '/') break
      else k++
    }
    k = Math.min(k + 1, n)
    while (k < n && /[a-z]/i.test(text[k])) k++
    return k
  }
  // 정규식이 올 수 있는 자리 — 연산자 · 여는 괄호 뒤, 또는 식을 여는 키워드 뒤(`return /}/` 를 나눗셈으로 읽으면 그 `}` 가
  // 옵션 객체를 일찍 닫아 `fails: true` 를 숨겼다 — Grok 레그 Q1). `)` · 다른 식별자 뒤는 나눗셈으로 본다.
  const regexStart = (i) => {
    if (prev === '' || '(,=:[!&|?{};'.includes(prev)) return true
    const w = /([A-Za-z_$][\w$]*)\s*$/.exec(text.slice(Math.max(0, i - 24), i))
    return !!w && REGEX_KEYWORDS.has(w[1])
  }
  let prev = ''
  for (let i = 0; i < n; ) {
    const c = text[i]
    let end = -1
    let isString = false
    if (c === '/' && text[i + 1] === '*') end = blockEnd(i)
    else if (c === '/' && text[i + 1] === '/') end = lineEnd(i)
    else if (c === "'" || c === '"') {
      end = quoted(i)
      isString = true
    } else if (c === '`') {
      end = template(i)
      isString = true
    } else if (c === '/' && regexStart(i)) end = regex(i)
    if (end < 0) {
      if (!/\s/.test(c)) prev = c
      i++
      continue
    }
    const isComment = c === '/' && (text[i + 1] === '*' || text[i + 1] === '/')
    // 주석은 구분자까지 통째로 비운다(공백과 같다). 문자열 · 템플릿 · 정규식은 여는 글자를 남긴다(토큰이 있었다는 표시).
    if (isComment) blank(i, end)
    else if (!(isString && keepStrings)) blank(i + 1, end - 1 > i ? end - 1 : end)
    if (!isComment) prev = isString ? c : '/'
    i = end
  }
  return out.join('')
}
const DECL_SHAPED = { go: /^func\s/, node: /^(?:it|test)\s*\(/, ruby: /^it\s*[("']/ }

// 줄 위로 올라가며 들여쓰기가 더 얕은 선언(클래스 · describe · mod)을 모은다(바깥 → 안쪽 순서). `stop` 이 더 얕은 들여쓰기에서
// 먼저 나오면 판정 불가다 — 함수 안에 놓인 테스트는 러너가 모으지 않거나 다른 이름으로 모은다(python: 독립 레그 실측 —
// `make_cases()` 안의 def 를 바깥 클래스의 테스트로 읽었다).
function classChain(lines, from, re, stop) {
  const chain = []
  let limit = indentOf(lines[from])
  for (let i = from - 1; i >= 0 && limit > 0; i--) {
    if (lines[i].trim() === '' || indentOf(lines[i]) >= limit) continue
    const m = re.exec(lines[i])
    if (m) {
      chain.unshift(m.slice(1).find((x) => x !== undefined))
      limit = indentOf(lines[i])
    } else if (stop && stop.test(lines[i])) throw new Unreadable(`${i + 1}행의 함수 안에 있다 — 러너가 그 테스트를 이 이름으로 모으지 않는다`)
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

// 줄의 문자열 리터럴(따옴표 셋) 중 카나리아 자리와 겹치는 첫 것 — node·ruby 의 테스트 제목(`end` = 닫는 따옴표 뒤 자리).
function titleAt(ctx, quotes, what) {
  const line = ctx.lines[ctx.at]
  const re = new RegExp(`([${quotes}])((?:\\\\.|(?!\\1)[^\\\\])*)\\1`, 'g')
  for (const m of line.matchAll(re)) {
    if (overlaps([m.index, m.index + m[0].length], ctx.span))
      return { q: m[1], body: m[2].replace(/\\(['"`\\])/g, '$1'), start: m.index, end: m.index + m[0].length }
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
// 이름 그대로(surefire) · `()`(Gradle) · 매개변수 테스트 `(인자 타입)[n]` 만 받는다 — `startsWith(n + '(')` 였을 때
// 괄호를 담은 kotlin 백틱 이름(`rejects x(legacy)`)이 카나리아 `rejects x` 로 읽혔다(독립 레그 실측).
// ⚠️ 선언의 매개변수가 비면 괄호도 비어야 한다 — 같은 이름의 미끼 오버로드(`void  이름(TestInfo i)` · kotlin 수신자
// 확장 `fun TestInfo.\`이름\`()`)에 `@Test` 를 옮기면 진짜 시험은 안 돌고 미끼가 `이름(TestInfo)` 로 보고돼 통과로
// 읽혔다(#1031 레그 실측 java·kotlin — 가드의 리터럴 계수는 그 미끼를 둘째 선언으로 못 센다).
const jvmMatch = (cls, n, noArgs) => (e) =>
  e.classname === cls && e.name.startsWith(n) && (noArgs ? /^(?:|\(\)(?:\[\d+\])?)$/ : /^(?:|\([^()]*\)(?:\[\d+\])?)$/).test(e.name.slice(n.length))
// 카나리아 선언의 매개변수 목록이 비었는가 — 선언 정규식(끝이 `\s*\(`)의 여는 괄호에서 짝 괄호까지 읽는다(줄을 넘는다).
function jvmNoArgs(ctx, re) {
  const g = new RegExp(re.source, `${re.flags.replace(/[gd]/g, '')}gd`)
  for (const m of ctx.lines[ctx.at].matchAll(g)) {
    const gi = m.indices.findIndex((x, i) => i > 0 && x)
    if (!(gi > 0 && overlaps(m.indices[gi], ctx.span))) continue
    let depth = 0
    let inner = ''
    for (let i = ctx.at, c = m.index + m[0].length - 1; i < ctx.lines.length; i++, c = 0) {
      const l = blankStrings(ctx.lines[i])
      for (; c < l.length; c++) {
        if (l[c] === '(' && depth++ === 0) continue
        if (l[c] === ')' && --depth === 0) return inner.trim() === ''
        inner += l[c]
      }
      inner += '\n'
    }
    throw new Unreadable(`${ctx.file}:${ctx.at + 1}: 선언의 매개변수 괄호가 닫히지 않았다`)
  }
  throw new Unreadable(`${ctx.file}:${ctx.at + 1}: 선언의 매개변수 목록을 읽지 못했다`)
}
// 문자열 리터럴의 안을 공백으로 비운 줄(길이는 그대로) — 호출·describe·주석을 찾을 때 제목 속 글자(`it (` · `//`)를 코드로
// 읽지 않게.
const blankStrings = (l) => l.replace(/(['"`])(?:\\.|(?!\1)[^\\])*\1/g, (m) => m[0] + ' '.repeat(m.length - 2) + m[0])
// node — vitest junit 의 이름은 `바깥 describe > 안 describe > 제목` 이다. 받는 describe 는 리터럴 제목뿐이다(뒤에 `,`).
// `.each` · `.skipIf(…)(…)` · 식별자 제목(`describe(Cls, …)`) · `${}` 템플릿은 이름을 정할 수 없어 판정 불가다 — 추측하면
// 건강한 실행을 FAIL 로 낸다(독립 레그 2 실측).
const DESCRIBE_LIT = /^\s*(?:describe|suite)(?:\.(?:only|skip|todo|concurrent|sequential|shuffle))*\(\s*(?:'((?:\\.|[^'\\])*)'|"((?:\\.|[^"\\])*)"|`((?:\\.|[^`$\\]|\$(?!\{))*)`)\s*,/
const NODE_INTERP = /%%|%\$|%[sdifjoOc#]|\$[A-Za-z_][\w.]*/
const NODE_TEMPLATE_INTERP = new RegExp(`\\$\\{[^}]*\\}|${NODE_INTERP.source}`)
// vitest 의 옵션 인자도 뒤집는다 — `it(제목, { fails: true }, fn)` · `describe(제목, { fails: true }, fn)` 은 본문이 실패해야
// 통과하고 JUnit 은 그 「expected fail」을 그냥 통과로 적는다(vitest 5.1 실측: 한 줄 · 여러 줄 · describe · 변수 옵션 넷 다 —
// #1017 레그가 카나리아 하나를 그렇게 바꾸고 회귀를 넣어 초록을 냈다). 셋째 인자 꼴 `it(제목, fn, 옵션)` 은 vitest 4 가
// 없앴다(TypeError). 제목 뒤 인자가 리터럴 객체면 그 안의 `fails: true|false` 만 읽고, 가릴 수 없는 꼴(변수 옵션 · 펼침 ·
// 리터럴 아닌 값 · 문자열 키)은 추측하지 않고 판정 불가다. 둘째 인자가 식별자 · 호출(`retried(fn)`)이면 마지막 인자일 때
// 테스트 함수이고, 뒤에 셋째 인자가 오면 그것이 함수 꼴일 때만 옵션 변수다(아니면 `it(제목, fn, SLOW_MS)` 의 타임아웃 —
// Grok 레그 Q2 · #1018 레그). 읽기는 파일 단위로 비운 줄(src.M — 문자열 · 템플릿 · 주석 · 정규식이 빈칸)에서 한다.
// `start` = 제목 리터럴의 닫는 따옴표 뒤(`,` 앞).
function optionsFail(src, at, start, file, what) {
  const { M, K } = src
  let i = at
  let c = start
  const unread = (why) => {
    throw new Unreadable(`${file}:${i + 1}: ${what} 의 vitest 옵션 — ${why}`)
  }
  // 공백 · 줄바꿈을 건너뛴 다음 글자(주석은 M 에서 이미 빈칸이다).
  const next = () => {
    for (; i < M.length; i++, c = 0) {
      while (c < M[i].length && /\s/.test(M[i][c])) c++
      if (c < M[i].length) return M[i][c]
    }
    return null
  }
  // 여는 괄호 자리에서 짝 괄호 다음 자리로(줄을 넘는다). `take` 면 지나온 글을 [M, K] 로 모은다.
  const skip = (take) => {
    let depth = 0
    const got = ['', '']
    for (; i < M.length; i++, c = 0) {
      for (; c < M[i].length; c++) {
        const x = M[i][c]
        if ('{[('.includes(x)) depth++
        else if ('}])'.includes(x)) depth--
        if (take) {
          got[0] += x
          got[1] += K[i][c]
        }
        if (depth === 0) {
          c++
          return got
        }
      }
      got[0] += '\n'
      got[1] += '\n'
    }
    return unread('괄호가 닫히지 않았다')
  }
  const fnStart = (s) => /^(?:async\b|function\b|\(|[A-Za-z_$][\w$]*\s*=>)/.test(s)
  const sep = next()
  if (sep === ')') return false
  if (sep !== ',') unread('제목 뒤가 `,` 도 `)` 도 아니다')
  c++
  const head = next()
  if (head === null) unread('인자 목록이 끝나지 않았다')
  if (head === '{') {
    // 리터럴 객체. 코드(M)에서 키를 읽고, 문자열을 살린 글(K)에서 `fails` 를 한 번 더 센다 — 문자열 키(`'fails'`) ·
    // 계산된 키(`['fails']`)는 코드에 안 보여서 둘이 어긋나면 판정 불가다. 주석 속 글자는 둘 다 빈칸이다.
    const [code, kept] = skip(true)
    if (code.includes('...')) unread('옵션 객체에 펼침(...)이 있다 — fails 를 가릴 수 없다')
    const said = kept.match(/\bfails\b/g) ?? []
    if (said.length === 0) return false
    const keys = code.match(/\bfails\b/g) ?? []
    const kv = /\bfails\s*:\s*(true|false)\b/.exec(code)
    if (said.length !== 1 || keys.length !== 1 || !kv) unread('fails 값이 true/false 리터럴이 아니다(또는 문자열 · 계산된 키 · 둘 이상)')
    return kv[1] === 'true'
  }
  if (fnStart(M[i].slice(c))) return false
  const id = /^[A-Za-z_$][\w$]*/.exec(M[i].slice(c))
  if (!id) unread('둘째 인자를 읽지 못했다')
  c += id[0].length
  // 식별자 뒤의 멤버 · 호출 사슬(`a.b`, `retried(…)`, `x[0]`)을 건너뛴다.
  for (let t = next(); t === '.' || t === '(' || t === '['; t = next()) {
    if (t === '.') {
      c++
      next()
      const m = /^[A-Za-z_$][\w$]*/.exec(M[i].slice(c))
      if (!m) unread(`\`${id[0]}\` 뒤 사슬을 읽지 못했다`)
      c += m[0].length
    } else skip(false)
  }
  const after = next()
  if (after === ')') return false
  if (after === ',') {
    c++
    if (next() === null) unread('인자 목록이 끝나지 않았다')
    if (fnStart(M[i].slice(c))) unread(`옵션이 리터럴 객체가 아니다(\`${id[0]}\`) — fails 를 가릴 수 없다`)
    return false
  }
  return unread(`\`${id[0]}\` 뒤를 읽지 못했다`)
}
// 위로 올라가며 처음 만나는 더 얕은 줄이 감싸는 블록이다(prettier 들여쓰기) — 그 줄마다 한계를 낮춘다. 클래스 사슬처럼
// describe 에서만 낮추면 닫힌 형제 블록(`for` 위의 describe)을 감싼 것으로 읽었다. `inverted` = 감싼 describe 중 하나가
// vitest 옵션 `fails: true` 다(그 안의 테스트가 전부 뒤집힌다). 빈 줄 · 주석 줄 · 여러 줄 템플릿 · 주석의 안은 src.M 에서
// 빈칸이라 건너뛰고, describe 의 제목은 주석만 비운 줄(src.K)에서 읽는다 — `/**/ describe(…, { fails: true }` 줄을 주석
// 줄로 건너뛰던 것(#1018 레그)이 이것으로 닫힌다.
function describeChain(src, from, file) {
  const { lines, M, K } = src
  const chain = []
  let inverted = false
  let limit = indentOf(lines[from])
  for (let i = from - 1; i >= 0 && limit > 0; i--) {
    if (M[i].trim() === '' || indentOf(lines[i]) >= limit) continue
    limit = indentOf(lines[i])
    if (!/^\s*(?:describe|suite)\b/.test(M[i])) continue
    const m = DESCRIBE_LIT.exec(K[i])
    if (!m) throw new Unreadable(`${file}:${i + 1}: describe 제목이 리터럴이 아니다(\`.each\` · \`.skipIf\` · 식별자 · \${} 템플릿) — 보고서 이름을 정할 수 없다`)
    // DESCRIBE_LIT 은 제목 뒤 `,` 까지 먹는다 — 옵션 판독은 그 `,` 자리에서 시작한다.
    if (optionsFail(src, i, m.index + m[0].length - 1, file, 'describe')) inverted = true
    chain.unshift(titlePattern((m[1] ?? m[2] ?? m[3]).replace(/\\(['"`\\])/g, '$1'), NODE_INTERP))
  }
  return { chain, inverted }
}

// RESOLVE[lang](ctx) → { label, match(entry), top? } · ctx = { file, rel, lines, text, at, span }
export const RESOLVE = {
  java(ctx) {
    const re = /\bvoid\s+(\w+)\s*\(/
    const n = declAt(ctx, re, 'void 메서드')
    const cls = qualified(packageOf(ctx.text, /^\s*package\s+([\w.]+)\s*;/m), classChain(ctx.lines, ctx.at, JAVA_CLASS), '$')
    return { label: `${cls}#${n}`, match: jvmMatch(cls, n, jvmNoArgs(ctx, re)) }
  },
  kotlin(ctx) {
    const re = /\bfun\s+(?:`([^`]+)`|(\w+))\s*\(/
    const n = declAt(ctx, re, 'fun')
    // Gradle 은 표시 이름을 쓴다 — `@ParameterizedTest`(`[1] "a"`) · `@RepeatedTest`(`repetition 1 of 2`) · `@DisplayName` 이
    // 붙은 카나리아는 이름으로 보고서 항목을 정할 수 없다(독립 레그 2 실측: 8 중 6 FAIL). 받지 않는다.
    for (let i = ctx.at; i >= 0; i--) {
      const t = ctx.lines[i].trim()
      if (i < ctx.at && t !== '' && !t.startsWith('@')) break
      if (/@(?:ParameterizedTest|RepeatedTest|DisplayName|TestFactory|TestTemplate)\b/.test(t))
        throw new Unreadable(`${ctx.file}:${i + 1}: 표시 이름을 바꾸는 어노테이션이 붙은 카나리아다 — Gradle 보고서 이름을 정할 수 없다`)
    }
    const cls = qualified(packageOf(ctx.text, /^\s*package\s+([\w.]+)/m), classChain(ctx.lines, ctx.at, KOTLIN_CLASS), '$')
    return { label: `${cls}#${n}`, match: jvmMatch(cls, n, jvmNoArgs(ctx, re)) }
  },
  python(ctx) {
    const n = declAt(ctx, /^\s*(?:async\s+)?def\s+(\w+)\s*\(/, 'def')
    const chain = classChain(ctx.lines, ctx.at, /^\s*class\s+(\w+)/, /^\s*(?:async\s+)?def\s/)
    const cls = [ctx.rel.replace(/\.py$/, '').split('/').join('.'), ...chain].join('.')
    return { label: `${ctx.rel}::${[...chain, n].join('::')}`, match: (e) => e.classname === cls && (e.name === n || e.name.startsWith(`${n}[`)) }
  },
  node(ctx) {
    const lit = titleAt(ctx, `'"\``, 'it/test 제목')
    // 파일 단위로 비운 글 — M: 문자열 · 템플릿 · 주석 · 정규식이 빈칸 · K: 주석 · 정규식만 빈칸(줄 · 열은 원문과 같다).
    const text = ctx.lines.join('\n')
    const src = { lines: ctx.lines, M: maskJs(text).split('\n'), K: maskJs(text, true).split('\n') }
    // 제목을 가진 호출 — 카나리아 줄부터 위로, 비운 줄의 첫 `it`/`test` 호출(창을 두지 않는다 — `it.fails.each([` 뒤 행이
    // 스물둘이면 20 줄 창 밖이었고, 제목 속 `it (` 를 호출로 읽었다 — 독립 레그 2 실측). 그보다 먼저 describe 를 만나거나
    // 못 찾으면 판정 불가.
    let callAt = -1
    let callCol = -1
    for (let i = ctx.at; i >= 0; i--) {
      const call = /\b(?:it|test)(?:\.\w+)*\s*\(/.exec(src.M[i])
      if (call) {
        callAt = i
        callCol = call.index
        break
      }
      if (i < ctx.at && /\b(?:describe|suite)\b/.test(src.M[i])) break
    }
    if (callAt < 0) throw new Unreadable(`${ctx.file}:${ctx.at + 1}: 제목을 가진 it/test 호출을 찾지 못했다`)
    // `it.fails` · `test.fails` · 옵션 `{ fails: true }`(제목 뒤 인자 · 감싼 describe) 는 본문이 실패해야 통과한다 — 보고서의
    // 통과가 곧 카나리아 단언의 실패다. 사슬은 `it` 부터 제목 앞까지 전부 본다 — 첫 `(` 에서 멈추면
    // `it.skipIf(false).fails(` 의 `.fails` 를 못 봤다(#1018 레그).
    const head =
      callAt === ctx.at
        ? src.M[callAt].slice(callCol, lit.start)
        : [src.M[callAt].slice(callCol), ...src.M.slice(callAt + 1, ctx.at), src.M[ctx.at].slice(0, lit.start)].join('\n')
    // describe 경로까지 맞춘다(호출 줄에서 시작) — 제목 끝만 보면 다른 describe 의 같은 제목이 빠진 카나리아 대신 통과로
    // 읽혔다(독립 레그 실측). 제목만 있는 줄에서 시작하면 더 깊은 들여쓰기 탓에 닫힌 형제 describe 를 감싼 것으로 읽었다(레그 2).
    const { chain, inverted: underFails } = describeChain(src, callAt, ctx.file)
    const inverted = /\.fails\b/.test(head) || optionsFail(src, ctx.at, lit.end, ctx.file, 'it/test') || underFails
    // 템플릿 제목의 `${…}` 는 정의 때 값이 박힌다(`for (const [route] of …) it.each(…)(\`%s — ${route} …\`)`) — `%s` 처럼
    // 「아무 글자」다. 리터럴로 읽으면 건강한 실행이 늘 「보고서에 없다」였다(#1031 뒤 레인 표 bearer 행 실측). 따옴표 제목의
    // `${` 는 그냥 글자다. 중첩 중괄호(`${a ? '}' : b}`)는 앞에서 끊겨 맞지 않는다(FAIL 쪽) — 오늘의 카나리아에는 없다.
    // ⚠️ 잔여(`%s` 와 같은 꼴 — Grok 레그): 같은 파일 · 같은 describe 경로에서 그 꼴에 맞는 다른 시험(`a ${x} b` 에 대한
    // `'a z b'`)이 빠진 카나리아 대신 통과로 읽힐 수 있다. 오늘의 행은 끝말이 서로 달라 겹치지 않는다.
    const titleRe = titlePattern(lit.body, lit.q === '`' ? NODE_TEMPLATE_INTERP : NODE_INTERP)
    // 자리표시(`%s` · `${…}`)가 있는 제목은, 그 꼴에 맞는 **다른 문자열**이 같은 파일에 있으면 판정 불가다 — 표를 비우고
    // 그 꼴의 제목을 가진 시험 하나(`it('d — e 가 뗀 값을 보낸다', …)`)를 두면 그것이 빠진 카나리아 대신 통과로 읽혔다
    // (#1033 레그 N2 · N3 — `%s` 도 같았다). 주석 · 정규식만 비운 글(K)의 따옴표 · 백틱 문자열을 본다(`${` 를 담은 템플릿은
    // 값을 모르니 뺀다).
    if (titleRe.includes('.*?')) {
      const only = new RegExp(`^${titleRe}$`)
      src.K.forEach((l, i) => {
        for (const m of l.matchAll(/(['"`])((?:\\.|(?!\1)[^\\])*)\1/g)) {
          if (i === ctx.at && m.index === lit.start) continue
          const body = m[2].replace(/\\(['"`\\])/g, '$1')
          if (!(m[1] === '`' && body.includes('${')) && only.test(body))
            throw new Unreadable(`${ctx.file}:${i + 1}: 다른 문자열 ${JSON.stringify(body)} 이 카나리아 제목의 꼴에 맞는다 — 그 시험이 빠진 카나리아 대신 통과로 읽힐 수 있다`)
        }
      })
    }
    const re = new RegExp(`^${[...chain, titleRe].join(' > ')}$`)
    return { label: `${ctx.rel} › ${lit.body}`, inverted, match: (e) => e.classname === ctx.rel && re.test(e.name) }
  },
  go(ctx) {
    const { file, lines, at } = ctx
    let n
    let i = at
    if (/^func\s/.test(lines[at])) n = declAt(ctx, /^func\s+(Test\w*)\s*\(/, 'func Test…')
    else {
      // 본문 줄(표 행 · 단언 호출) — 감싼 최상위 함수는 줄 머리 `func ` 다(gofmt). 그것이 Test 함수가 아니면 못 읽는다.
      while (i >= 0 && !/^func\s/.test(lines[i])) i--
      const m = i >= 0 ? /^func\s+(Test\w*)\s*\(/.exec(lines[i]) : null
      if (!m) throw new Unreadable(`${file}:${at + 1}: 카나리아 줄을 감싼 최상위 함수가 Test 함수가 아니다(${i >= 0 ? lines[i].trim() : '없음'})`)
      n = m[1]
    }
    // 본문의 끝(줄 머리 `}`) — 본문 줄 카나리아는 그 안에 있어야 한다. 패키지 수준 표가 위 Test 함수의 것으로 읽혔다
    // (독립 레그 2 실측: 그 표를 쓰는 다른 테스트가 SKIP 인데 rc 0).
    // 빈 본문(`func TestX(t *testing.T) {}`)은 그 줄에서 끝난다 — 아니면 뒤 패키지 수준 표의 줄 머리 `}` 를 끝으로 읽는다.
    let j = /\{\s*\}\s*$/.test(lines[i]) ? i : i + 1
    while (j > i && j < lines.length && !/^}/.test(lines[j])) j++
    if (at > j) throw new Unreadable(`${file}:${at + 1}: 카나리아 줄이 ${n} 의 본문(${i + 1}–${j + 1}행) 밖이다 — 패키지 수준 표면 그것을 쓰는 Test 를 정할 수 없다`)
    // 서브테스트를 여는 테스트는 서브테스트가 하나라도 보고돼야 한다 — `-skip 'TestX/.'` 같은 필터는 부모의 PASS 만 남긴다
    // (독립 레그 실측). 여는 자리는 `func(… *testing.T)` 를 넘기는 `.Run(` 이다(받는 이름 무관 — `tt.Run` · 문자열·주석 속
    // 글자는 빼고 — 레그 2). 본문이 부르는 **같은 파일의 최상위 도우미**가 여는 것도 센다(한 단계) — bearer 표의 둘이
    // `grammarInjected(t, …)` 로 연다(#1033 레그 G2: `-skip 'TestX/.'` 이 그 둘을 부모 PASS 만 남기고 비웠다).
    // ⚠️ 다른 파일의 도우미 · 두 단계 넘는 도우미 · 일부만 빼는 필터는 못 본다(기대 개수가 보고서 밖이다).
    const code = (l) => blankStrings(l).replace(/\/\/.*$/, '')
    const opens = (from, to) => lines.slice(from, to).some((l) => /\.Run\([^)]*?,\s*func\s*\(\s*\w+\s+\*testing\.T\s*\)/.test(code(l)))
    const endOf = (h) => {
      let e = /\{\s*\}\s*$/.test(lines[h]) ? h : h + 1
      while (e > h && e < lines.length && !/^}/.test(lines[e])) e++
      return e
    }
    let sub = opens(i, j)
    if (!sub) {
      const called = new Set(lines.slice(i + 1, j).flatMap((l) => [...code(l).matchAll(/(?<![\w.])([A-Za-z_]\w*)\s*\(/g)].map((m) => m[1])))
      for (let h = 0; h < lines.length && !sub; h++) {
        const d = /^func\s+(\w+)\s*\(/.exec(lines[h])
        if (d && d[1] !== n && called.has(d[1])) sub = opens(h, endOf(h))
      }
    }
    return { label: `${file}:${at + 1} → ${n}`, top: n, sub, match: (e) => e.name === n || e.name.startsWith(`${n}/`) }
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
    // 경로는 정확히 — 파일의 모듈 + 그 파일 안에서 감싼 `mod` 들 + 이름. `(?:\w+::)*` 였을 때 더 깊은 모듈의 같은 이름
    // (`auth::tests::legacy::x`)이 카나리아로 읽혔다(독립 레그 실측).
    const inner = classChain(ctx.lines, ctx.at, /^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*\{/)
    // `#[path = "…"] mod x;` 로 들인 파일은 모듈 경로가 파일 경로와 다르다(독립 레그 2 실측: `pathy::tests::…` 를
    // `pathy_tests::…` 로 기대했다). 그 파일을 가리키는 `#[path]` 가 크레이트에 있으면 받지 않는다.
    const base = rel.split('/').pop()
    const src = join(ctx.root, 'rust', 'src')
    for (const f of existsSync(src) ? walk(src, /\.rs$/, []) : [])
      for (const m of readFileSync(f, 'utf8').matchAll(/#\s*\[\s*path\s*=\s*"([^"]+)"\s*\]/g))
        if (m[1].replace(/\\/g, '/').split('/').pop() === base)
          throw new Unreadable(`${file}: \`#[path = "${m[1]}"]\` 로 들인 모듈이다 — 모듈 경로를 파일 경로로 정할 수 없다`)
    let parts
    let bin
    if (rel.startsWith('src/')) {
      parts = rel.slice(4).replace(/\.rs$/, '').split('/')
      if (parts.at(-1) === 'mod') parts.pop()
      if (parts.length === 1 && (parts[0] === 'lib' || parts[0] === 'main')) parts.pop()
      bin = (b) => /^(?:unittests )?src\/(?:lib|main)\.rs$/.test(b)
    } else if (/^tests\/[^/]+\.rs$/.test(rel)) {
      parts = []
      bin = (b) => b === rel
    } else throw new Unreadable(`${file}: rust 카나리아는 src/ 또는 tests/*.rs 에 있어야 한다`)
    const path = [...parts, ...inner, n].join('::')
    return { label: `${rel} → ${path}`, match: (e) => bin(e.binary ?? '') && e.name === path }
  },
  ruby(ctx) {
    const lit = titleAt(ctx, `'"`, 'it 제목')
    // 파일 + 정의 줄로 맞춘다 — 제목만 보면 `#{…}` 가 「아무 글자」라 같은 파일의 비슷한 제목(`… (legacy path)`)이 카나리아로
    // 읽혔다(독립 레그 실측). RSpec JSON 의 line_number 는 그 예제 블록의 줄이다 — 보통 `it` 줄이고(루프로 만든 예제들도 같은
    // 줄), `it "x",` 다음 줄에 `:aggregate_failures do` 가 오면 그 `do` 줄이다(레그 2 실측). 그래서 `it` 줄부터 블록을 여는
    // 줄(다섯 줄 안)까지를 받는다.
    let open = ctx.at
    const opens = (l) => /(?:\bdo\b|\{)\s*(?:\|[^|]*\|)?\s*$/.test(blankStrings(l).replace(/#.*$/, ''))
    while (open < ctx.at + 5 && open < ctx.lines.length - 1 && !opens(ctx.lines[open])) open++
    const lo = ctx.at + 1
    const hi = open + 1
    const norm = (f) => f.replace(/\\/g, '/').replace(/^\.\//, '')
    return {
      label: `${ctx.rel}:${lo} › ${lit.body}`,
      match: (e) => typeof e.file === 'string' && norm(e.file) === ctx.rel && e.line >= lo && e.line <= hi,
    }
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
    return RESOLVE[lang]({ root, file: c.file, rel: c.file.slice(prefix.length), lines, text, at, span })
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
// CDATA·주석 안의 글자는 마크업이 아니다 — 시험 출력(system-out)에 `<skipped/>` 같은 글자가 실리면 통과한 항목을 건너뛴
// 것으로 읽는다. 앞에서부터 한 번 훑으며 그 구간을 통째로 건너뛴다(치환을 되풀이하지 않는다 — 지운 뒤에 새 `<!--` 가 생기지
// 않는다). 닫히지 않은 구간은 끝까지 버린다.
export function stripXmlNoise(x) {
  const OPEN = [['<![CDATA[', ']]>'], ['<!--', '-->']]
  let out = ''
  let i = 0
  for (;;) {
    let k = -1
    let open = ''
    let close = ''
    for (const [o, c] of OPEN) {
      const j = x.indexOf(o, i)
      if (j >= 0 && (k < 0 || j < k)) {
        k = j
        open = o
        close = c
      }
    }
    if (k < 0) return out + x.slice(i)
    out += x.slice(i, k)
    const end = x.indexOf(close, k + open.length)
    if (end < 0) return out
    i = end + close.length
  }
}

// 텍스트 출력의 ANSI 색 — CI 의 rust 레인은 `dtolnay/rust-toolchain` 이 `CARGO_TERM_COLOR=always` 를 걸어 cargo 의
// `Running …` 줄이 `ESC[1mESC[32m     RunningESC[0m unittests src/lib.rs` 로 온다(실측 #996 첫 CI — 바이너리를 못 읽어
// src 카나리아 아홉이 전부 「보고서에 없다」였다). 로컬 콘솔 출력엔 색이 없어 보이지 않던 차이다.
const stripAnsi = (s) => s.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '')

// 여는 태그 — 따옴표 안의 `>` 는 태그 끝이 아니다(XML 은 속성값의 `>` 를 이스케이프하라고 요구하지 않는다). `[^>]*` 였을 때
// `note="a/>b"` 를 단힌 태그로 읽어 건너뛴 카나리아를 통과로 냈다(독립 레그 실측). → [속성, 단힘 여부, 태그 끝 위치]
function* openTags(x, name) {
  const re = new RegExp(`<${name}\\b((?:[^>"']|"[^"]*"|'[^']*')*)>`, 'g')
  for (const m of x.matchAll(re)) {
    const selfClosing = m[1].endsWith('/')
    yield { attrs: attrs(selfClosing ? m[1].slice(0, -1) : m[1]), selfClosing, end: m.index + m[0].length }
  }
}

export const PARSE = {
  junit(text) {
    const x = stripXmlNoise(text)
    if (!/<testsuites?\b/.test(x)) throw new Unreadable('JUnit XML 이 아니다(<testsuite> 없음)')
    const out = []
    for (const t of openTags(x, 'testcase')) {
      let body = ''
      if (!t.selfClosing) {
        const close = x.indexOf('</testcase>', t.end)
        body = close < 0 ? x.slice(t.end) : x.slice(t.end, close)
      }
      const status = /<(failure|error)\b/.test(body) ? 'failed' : /<skipped\b/.test(body) ? 'skipped' : 'passed'
      out.push({ classname: t.attrs.classname ?? '', name: t.attrs.name ?? '', file: t.attrs.file, status })
    }
    return out
  },
  trx(text) {
    const x = stripXmlNoise(text)
    if (!/<TestRun\b/.test(x)) throw new Unreadable('TRX 가 아니다(<TestRun> 없음)')
    const out = []
    for (const t of openTags(x, 'UnitTestResult')) {
      const o = t.attrs.outcome ?? ''
      out.push({ name: t.attrs.testName ?? '', status: o === 'Passed' ? 'passed' : o === 'NotExecuted' ? 'skipped' : 'failed' })
    }
    return out
  },
  gotest(text) {
    const out = []
    for (const m of stripAnsi(text).matchAll(/^\s*--- (PASS|FAIL|SKIP): (\S+) \(/gm))
      out.push({ name: m[2], status: m[1] === 'PASS' ? 'passed' : m[1] === 'SKIP' ? 'skipped' : 'failed' })
    return out
  },
  libtest(text) {
    const out = []
    let binary = ''
    for (const line of stripAnsi(text).split(/\r?\n/)) {
      const run = /^\s*Running (unittests )?(\S+)/.exec(line)
      if (run) {
        binary = (run[1] ?? '') + run[2].replace(/\\/g, '/')
        continue
      }
      // `#[should_panic]` 은 본문이 패닉해야 통과한다 — 카나리아에 붙으면 통과가 곧 단언 실패다(`test x - should panic ... ok`).
      const t = /^test (\S+)( - should panic)? \.\.\. (ok|ignored|FAILED)\b/.exec(line)
      if (t) out.push({ binary, name: t[1], status: t[3] === 'ignored' ? 'skipped' : t[3] === 'FAILED' ? 'failed' : t[2] ? 'inverted' : 'passed' })
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
    return j.examples.map((x) => ({
      file: x.file_path,
      line: x.line_number,
      name: x.description ?? '',
      status: x.status === 'passed' ? 'passed' : x.status === 'pending' ? 'skipped' : 'failed',
    }))
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
  const INVERTED = '뒤집혔다(it.fails · { fails: true } · should_panic) — 통과가 곧 카나리아 단언의 실패다'
  if (t.inverted) return { ok: false, why: INVERTED }
  const hit = entries.filter(t.match)
  if (hit.length === 0) return { ok: false, why: '보고서에 없다 — 이 실행에서 돌지 않았다(필터 · 제외 · 이름 바뀜)' }
  if (t.top && !hit.some((e) => e.name === t.top)) return { ok: false, why: `최상위 ${t.top} 가 보고서에 없다(서브테스트만 있다)` }
  if (t.sub && !hit.some((e) => e.name.startsWith(`${t.top}/`)))
    return { ok: false, why: `서브테스트를 여는 테스트인데 서브테스트가 하나도 보고되지 않았다(필터 -run/-skip?)` }
  const skipped = hit.filter((e) => e.status === 'skipped').length
  const failed = hit.filter((e) => e.status === 'failed').length
  if (hit.some((e) => e.status === 'inverted')) return { ok: false, why: INVERTED }
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
    // 한 시험이 두 행의 증거를 대신하지 않는다 — 면제 근거 행을 다른 축의 카나리아로 돌려 대고 진짜 근거 시험을 건너뛰면
    // 그 시험이 두 번 통과로 세어지고 근거는 아무도 안 봤다(#1031 레그 실측 java·kotlin).
    const owner = new Map()
    for (const { c, t } of targets) {
      if (owner.has(t.label)) unread(`두 행이 같은 시험을 가리킨다(${owner.get(t.label)} · ${c.axis}): ${t.label} — 한 시험은 한 행의 증거다`)
      owner.set(t.label, c.axis)
    }
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
