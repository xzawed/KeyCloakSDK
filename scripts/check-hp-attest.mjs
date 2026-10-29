#!/usr/bin/env node
// check-hp-attest.mjs — 적대 경로 행렬이 **이 실행에서 실제로 돌았다**는 증명(attest 파일)을 레인 단계에서 대조한다.
//
// 왜: 아홉 언어의 HostilePathMatrix 는 단위 스위트 안의 테스트 하나라, 레인이 초록이라는 것은 「행렬이 돌았다」의 증거가
// 아니다. 실측(#773): 최신 main 로그에서 행렬이 돈 것이 **보이는** 레인은 java·node·rust 셋뿐이었고 나머지는 요약 줄만
// 찍었으며, go 는 `(cached)` 재생으로 통과했다. 필터(`-k`·`-t`·`--filter`)·러너 캐시·건너뛴 W1 어느 것이든 행렬을
// 비운 레인은 그대로 초록이다. 정적 대조(`check-known-gaps.mjs`)는 소스만 읽으므로 이 칸을 구조적으로 못 본다.
//
// 모델:
//  · 행렬은 **모든 단언이 통과한 뒤에만**, `HP_ATTEST_DIR` 이 있을 때 `<dir>/<lang>.json` 을 쓴다 —
//    {lang, nonce, rows, classes, w3, w1, knownGaps}. 실패한 행렬은 파일을 남기지 않는다(쓰기가 마지막 줄이다).
//  · nonce 는 `HP_ATTEST_NONCE` — CI 가 `run_id.run_attempt.job.job-index` 로 준다. 이 가드는 단위 테스트 단계 **바로 뒤**
//    단계에서 같은 값으로 읽으므로, 다른 실행·다른 잡·다른 매트릭스 레그·캐시가 남긴 파일은 통과하지 못한다.
//  · `knownGaps` 는 행렬이 **런타임에** 가진 KNOWN_GAPS 값의 id(`등록부 id: 이유` 의 앞마디)다. 정적 대조가 못 보는 계산된
//    id(#773 의 「남은 틈」 둘 — 리터럴 접두가 아닌 id · 넘겨받은 함수가 채운 목록)까지 여기서 닫힌다. 그 id 는 등록부의
//    **열린** 항목이어야 한다. 등록부 판독기는 `check-known-gaps.mjs` 의 것 하나다(사본을 두지 않는다).
//
// 판정: 통과 → 0 · FAIL → 1 · 판정 불가 → 2.
//  FAIL(행렬이 이 실행에서 증명하지 못했다): 파일 없음 · nonce 불일치 · lang 불일치 · rows 가 양의 정수가 아님(0 포함) ·
//    classes 가 여섯 계급 정확히가 아님 · 계급 수가 음이 아닌 정수가 아님 · 계급 합 ≠ rows · w3 가 양의 정수가 아님 ·
//    w1 ≠ true · knownGaps 가 문자열 배열이 아님 · 열린 항목이 아닌 id(닫힘 · 미등록).
//  판정 불가(가드가 읽지 못했다): 인자(모르는 플래그 · 빈 --lang/--nonce · 언어 이름 문법 밖) · <dir> 가 디렉터리가 아님 ·
//    파일 읽기 오류 · JSON 이 아님 · JSON 이 객체가 아님 · 대조할 id 가 있는데 등록부를 못 읽음 · id 가 등록부에 둘 이상 ·
//    체크박스 표기를 모름.
// ⚠️ <dir> 가 **없는** 것은 판정 불가가 아니라 FAIL 이다 — 행렬이 디렉터리를 만드니, 없다는 것은 아무 행렬도 쓰지 않았다는
//    바로 그 사건이다(이 가드가 잡으려는 것). 2 로 두면 「가드가 못 읽었다」로 읽혀 사람이 엉뚱한 곳을 본다.
// ⚠️ 등록부는 대조할 id 가 있을 때만 읽는다 — 아홉 목록이 다 비어 있는 오늘, 등록부 표기 사고가 아홉 레인을 함께 빨갛게
//    하지 않게(등록부 자체는 `doc-facts` 의 형태 검사와 `known-gaps-join` 이 본다).
//
// 사용: node scripts/check-hp-attest.mjs <dir> --nonce <nonce> --lang <lang>[,<lang>…] [--root <저장소>]
//       (--root 기본 = 이 저장소 — 자가테스트가 픽스처 등록부를 쓰려고 받는다)
import { readFileSync, statSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readRegistry, registryState, REGISTRY } from './check-known-gaps.mjs'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
// 행렬 아홉이 같은 이름으로 세는 계급 — 이 밖의 키는 철자가 갈린 것이다(합이 맞아도 그 칸이 무엇인지 모른다).
export const CLASSES = ['CODE_EXCHANGE', 'TOKEN_GRANT', 'JWKS_FETCH', 'OTHER', 'NONE', 'UNDETERMINED']
// 언어 이름은 파일 이름이 된다 — `../x` 가 디렉터리 밖을 읽지 않게 문법으로 막는다(목록은 두지 않는다: 열 번째 언어가
// 이 파일을 고치지 않고 들어올 수 있어야 하고, 철자가 틀린 언어는 「파일 없음」 FAIL 로 드러난다).
const LANG_RE = /^[a-z][a-z0-9]*$/

class Usage extends Error {}

// 값을 받는 플래그 셋 — `--x v` 와 `--x=v` 둘 다. 값 자리에 다음 플래그가 오면 값이 없는 것이다(조용히 삼키지 않는다).
const VALUE_FLAGS = { '--nonce': 'nonce', '--lang': 'langs', '--root': 'root' }

export function parseArgs(argv) {
  const opt = { dir: null, nonce: null, langs: null, root: REPO }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const eq = a.indexOf('=')
    const name = a.startsWith('--') && eq > 0 ? a.slice(0, eq) : a
    const key = VALUE_FLAGS[name]
    if (key !== undefined) {
      let v
      if (name !== a) v = a.slice(eq + 1)
      else {
        v = argv[i + 1]
        if (v === undefined || v.startsWith('--')) throw new Usage(`${name} 에 값이 없다`)
        i++
      }
      opt[key] = key === 'root' ? resolve(v) : v
    } else if (a.startsWith('-')) throw new Usage(`모르는 플래그 ${a}`)
    else if (opt.dir === null) opt.dir = a
    else throw new Usage(`인자가 남는다: ${a}`)
  }
  if (opt.dir === null || opt.dir === '') throw new Usage('<dir> 가 없다')
  // ⚠️ 빈 nonce 는 아무 실행에도 묶이지 않는다 — 비어 있는 attest 와 맞아 버리면 nonce 대조가 통째로 공허해진다.
  if (opt.nonce === null || opt.nonce === '') throw new Usage('--nonce 가 없거나 비었다')
  if (opt.langs === null) throw new Usage('--lang 이 없다')
  const langs = opt.langs.split(',')
  // ⚠️ 빈 목록은 0 개를 훑고 통과한다 — 그래서 실패가 아니라 판정 불가다(`--lang ""` · `--lang go,,rust`).
  if (langs.some((l) => l === '')) throw new Usage(`--lang 에 빈 언어가 있다(${JSON.stringify(opt.langs)})`)
  const bad = langs.filter((l) => !LANG_RE.test(l))
  if (bad.length) throw new Usage(`언어 이름이 문법 ${LANG_RE} 밖이다: ${bad.join(', ')}`)
  opt.langs = [...new Set(langs)]
  return opt
}

const isPosInt = (x) => Number.isInteger(x) && x > 0
const isNonNegInt = (x) => Number.isInteger(x) && x >= 0
const show = (x) => (x === undefined ? '없음' : JSON.stringify(x))

// 한 언어의 attest → { verdict: 'ok'|'fail'|'unusable', why: [...], line }. reg() 는 필요할 때만 등록부를 읽는다.
export function judge(dir, lang, nonce, reg) {
  const file = join(dir, `${lang}.json`)
  let text
  try {
    text = readFileSync(file, 'utf8')
  } catch (e) {
    if (e.code === 'ENOENT') return { verdict: 'fail', why: [`${file} 이 없다 — 이 실행에서 행렬이 돌지 않았거나(필터·캐시 재생·skip) 단언이 실패했다`] }
    return { verdict: 'unusable', why: [`${file} 을 못 읽었다: ${e.message}`] }
  }
  let a
  try {
    a = JSON.parse(text)
  } catch (e) {
    return { verdict: 'unusable', why: [`${file} 이 JSON 이 아니다: ${e.message}`] }
  }
  if (a === null || typeof a !== 'object' || Array.isArray(a)) return { verdict: 'unusable', why: [`${file} 이 JSON 객체가 아니다(${show(a)})`] }

  const why = []
  const unusable = []
  if (a.lang !== lang) why.push(`lang 이 ${show(a.lang)} 다(기대 ${JSON.stringify(lang)}) — 다른 언어의 행렬이 이 파일을 썼다`)
  if (a.nonce !== nonce) why.push(`nonce 가 ${show(a.nonce)} 다(기대 ${JSON.stringify(nonce)}) — 이 실행·이 잡이 쓴 파일이 아니다`)
  if (!isPosInt(a.rows)) why.push(`rows 가 ${show(a.rows)} 다 — 양의 정수여야 한다(0 이면 분류표가 비었다)`)
  const c = a.classes
  if (c === null || typeof c !== 'object' || Array.isArray(c)) why.push(`classes 가 객체가 아니다(${show(c)})`)
  else {
    const extra = Object.keys(c).filter((k) => !CLASSES.includes(k))
    if (extra.length) why.push(`classes 에 모르는 계급 ${extra.join(', ')} — 계급 이름이 갈렸다`)
    const bad = CLASSES.filter((k) => !isNonNegInt(c[k]))
    if (bad.length) why.push(`classes 의 ${bad.map((k) => `${k}=${show(c[k])}`).join(', ')} — 음이 아닌 정수여야 한다`)
    else if (isPosInt(a.rows)) {
      const sum = CLASSES.reduce((s, k) => s + c[k], 0)
      if (sum !== a.rows) why.push(`계급 합 ${sum} ≠ rows ${a.rows} — 두 수가 같은 분류표를 세지 않았다`)
    }
  }
  if (!isPosInt(a.w3)) why.push(`w3 가 ${show(a.w3)} 다 — 양의 정수여야 한다(0 이면 적대 변형이 하나도 돌지 않았다)`)
  if (a.w1 !== true) why.push(`w1 이 ${show(a.w1)} 다 — 손 목록 대조(W1)가 이 실행에서 돌지 않았다(보안 기본값 가드를 못 읽고 건너뛰었다)`)
  const gaps = a.knownGaps
  if (!Array.isArray(gaps) || gaps.some((g) => typeof g !== 'string')) why.push(`knownGaps 가 문자열 배열이 아니다(${show(gaps)})`)
  else if (gaps.length) {
    let r = null
    try {
      r = reg()
    } catch (e) {
      unusable.push(`known gap id ${gaps.length} 개를 대조할 등록부(${REGISTRY})를 못 읽었다: ${e.message}`)
    }
    for (const id of r ? gaps : []) {
      const s = registryState(r, id)
      if (s.state === 'open') continue
      if (s.state === 'closed') why.push(`known gap ${JSON.stringify(id)} 는 등록부 ${s.line}행에서 닫혔다 — 틈이 남았는데 항목이 닫혔다`)
      else if (s.state === 'unregistered') why.push(`known gap ${JSON.stringify(id)} 는 등록부에 없다 — 오타 id 이거나 등록이 빠졌다`)
      else if (s.state === 'duplicate') unusable.push(`known gap ${JSON.stringify(id)} 가 등록부에 ${s.lines.length}번 있다(줄 ${s.lines.join(', ')}) — 열림/닫힘을 가를 수 없다`)
      else unusable.push(`known gap ${JSON.stringify(id)} 의 등록부 상태 표기를 모른다(줄 ${s.line})`)
    }
  }
  if (unusable.length) return { verdict: 'unusable', why: [...unusable, ...why] }
  if (why.length) return { verdict: 'fail', why }
  const counts = CLASSES.map((k) => `${k} ${c[k]}`).join(' · ')
  return { verdict: 'ok', why: [], line: `rows ${a.rows} (${counts}) · w3 ${a.w3} · w1 · knownGaps ${gaps.length ? gaps.join(', ') : '0'}` }
}

function main() {
  let opt
  try {
    opt = parseArgs(process.argv.slice(2))
  } catch (e) {
    if (!(e instanceof Usage)) throw e
    console.error(`::error::판정 불가 — ${e.message}`)
    console.error('사용: node scripts/check-hp-attest.mjs <dir> --nonce <nonce> --lang <lang>[,<lang>…] [--root <저장소>]')
    process.exit(2)
  }
  // <dir> 가 없으면 언어마다 「파일 없음」 FAIL 로 간다(머리 주석). 있는데 디렉터리가 아니면 읽을 수 없다.
  let st = null
  try {
    st = statSync(opt.dir)
  } catch (e) {
    if (e.code !== 'ENOENT') {
      console.error(`::error::판정 불가 — ${opt.dir} 을 읽지 못했다: ${e.message}`)
      process.exit(2)
    }
  }
  if (st && !st.isDirectory()) {
    console.error(`::error::판정 불가 — ${opt.dir} 이 디렉터리가 아니다`)
    process.exit(2)
  }
  // 등록부는 한 번만 읽는다 — 실패도 기억해 언어마다 같은 이유로 판정 불가를 낸다.
  let registry = null
  const reg = () => {
    if (registry === null) {
      try {
        registry = { ok: readRegistry(opt.root) }
      } catch (e) {
        registry = { err: e }
      }
    }
    if (registry.err) throw registry.err
    return registry.ok
  }
  const n = { ok: 0, fail: 0, unusable: 0 }
  for (const lang of opt.langs) {
    const v = judge(opt.dir, lang, opt.nonce, reg)
    n[v.verdict]++
    if (v.verdict === 'ok') console.log(`ok    ${lang.padEnd(7)} ${v.line}`)
    else for (const w of v.why) console.error(`::error::${v.verdict === 'fail' ? 'FAIL' : '판정 불가'} ${lang} — ${w}`)
  }
  console.log(`hp-attest: 언어 ${opt.langs.length} · 통과 ${n.ok} · FAIL ${n.fail} · 판정 불가 ${n.unusable} (nonce ${opt.nonce})`)
  process.exit(n.unusable ? 2 : n.fail ? 1 : 0)
}

// 자가테스트가 import 로 순수 함수만 쓸 수 있게 — 직접 실행일 때만 main(check-known-gaps.mjs 와 같은 꼴).
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop())) {
  try {
    main()
  } catch (e) {
    console.error(`::error::판정 불가 — 예상하지 못한 오류: ${e.stack ?? e}`)
    process.exit(2)
  }
}
