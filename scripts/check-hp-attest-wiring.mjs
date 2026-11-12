#!/usr/bin/env node
// check-hp-attest-wiring.mjs — 레인이 **반드시 돌아야 하는 증명 단계 둘**의 배선을 정적으로 대조한다: 적대 경로 행렬
// attest(`check-hp-attest.mjs`)와 보안 카나리아 실행 대조(`check-canaries-ran.mjs`, #996). 레인이 두 단계를 조건 없이
// 돌고, 그 둘과 가드가 읽는 공용 파일만 바꾼 PR 에서도 그 레인이 생기는가.
//
// 왜: 두 검사는 레인 단계가 **돌 때만** 증명한다 — 그 단계를 지우거나 `if:`·`continue-on-error` 로 무르면 아무것도
// 울지 않았다(등록부 `guard-detection-surface-hand-narrowed` 의 남은 칸 — attest 는 #934, 카나리아는 이 판). 그리고 아홉
// 행렬의 W1 과 카나리아 검사가 런타임에 읽는 `scripts/test/test-security-defaults.sh` 가 레인 `paths:` 밖이라, 그 스크립트만
// 바꾼 PR 은 언어 CI 를 만들지 않았다 — 2026-09-01 이후 그 파일을 고친 `main` 커밋 36 중 18 이 언어 디렉터리를 안
// 건드렸다(`w1-shared-script-drift-weekly-only`). 런타임에 읽는 루트 파일은 그것과 카나리아 검사가 함께 읽는 레인 카나리아
// 표(`scripts/test/test-lane-canaries.sh` — 덤프 걷기 · bearer 정본 표) 둘이다(다른 루트 경로는 주석 속 인용).
//
// 모델 — 언어 집합은 트리에서 파생한다(`check-known-gaps.mjs` 의 `deriveLangs` = `df_tree_langs`). 단계 종류(STEPS)마다,
// 언어마다:
//  (1) `.github/workflows/*.yml|yaml` 의 주석 아닌 줄에서 `node … <그 스크립트> … --lang <언어>` 를 도는 단계가 하나
//      이상 있다(카나리아 단계는 `--report` 도 있어야 한다 — 없으면 그 검사가 실행마다 판정 불가다).
//  (2) 그 단계와 그 잡에 `if:` · `continue-on-error:` 키가 없다 — 조건부 증명은 증명이 아니다. 그리고 단계의 종료코드가
//      곧 그 검사의 것이다: 줄 머리에서 시작하고(앞 명령 · `!` 없음) 그 줄에 셸 연산자가 없고 그 run 의 마지막 명령이다.
//  (3) 그 워크플로의 `push` · `pull_request` 트리거가 `<언어>/**` 와 `SHARED` 를 받는다(`paths:` 가 없으면 전부 받는다).
//      `branches` 가 있으면 main 을, `pull_request.types` 가 있으면 opened · synchronize · reopened 를 담고, push 가 태그에만
//      걸리지 않는다 — 경로만 보면 PR 에서 아예 안 도는 트리거가 「받는다」로 읽힌다(Grok 레그).
//  그리고 단계가 부르는 언어가 파생 집합 밖이면(철자 · 지운 언어) FAIL 이다.
// ⚠️ 못 보는 것(독립 레그 실측 · 두 단계 다): 단계·잡·워크플로의 `shell:` 덮어쓰기(`shell: "echo {0}"` 면 스크립트가 안
//    돈다 — 줄 단위 판독기 밖이고 실수가 아니라 의도된 무력화다). 다른 잡으로 옮긴 카나리아 단계와 빈 `--report` 는 여기서
//    통과하지만 실행 때 보고서 없음(1) · 인자 오류(2)로 운다.
// ⚠️ 등록부는 SHARED 가 아니다. attest 는 known gap id 가 있을 때만 등록부를 읽고(오늘 아홉 다 빈 목록 —
//    `check-known-gaps.mjs` 실측), 리터럴 id 는 모든 PR 의 `known-gaps-join` 이 열림/닫힘을 대조하며, 리터럴 없는 비지
//    않은 목록은 같은 정적 대조가 판정 불가로 막는다. 등록부를 걸면 등록부 PR 마다 아홉 레인이 돈다.
//    되살릴 조건: 리터럴 없이 계산되는 known gap id 를 정적 대조가 통과시키는 모양이 생긴다.
// 판정: 통과 0 · FAIL 1 · 판정 불가 2 — 읽지 못한 모양(플로우 매핑 `on:` · 한 줄에서 닫히지 않는 플로우 시퀀스 ·
//  `paths-ignore` · 부정 패턴 · 변수 `--lang`)과 언어 0. 이해 못 한 모양을 통과로 넘기면 그게 곧 우회로다.
//
// 사용: node scripts/check-hp-attest-wiring.mjs [<저장소 루트>]
import { readFileSync, readdirSync } from 'node:fs'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { deriveLangs } from './check-known-gaps.mjs'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export const SHARED = [
  'scripts/check-hp-attest.mjs',
  'scripts/check-canaries-ran.mjs',
  'scripts/test/test-security-defaults.sh',
  'scripts/test/test-lane-canaries.sh',
]
// 레인이 반드시 돌아야 하는 증명 단계 — 종류 이름은 메시지에 그대로 나간다(attest 쪽 문구는 #934 그대로다).
const stepRe = (script) => new RegExp(`(^|[\\s;&|(])node\\s+(?:\\S+\\s+)*?(?:\\.{1,2}\\/)*${script.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?=[\\s"']|$)`)
export const STEPS = [
  { kind: 'attest', script: 'scripts/check-hp-attest.mjs', re: stepRe('scripts/check-hp-attest.mjs'), need: [] },
  // `--report` 없이 부르면 그 검사는 실행마다 판정 불가(2)다 — 배선이 증명을 낳지 못한다.
  { kind: '카나리아', script: 'scripts/check-canaries-ran.mjs', re: stepRe('scripts/check-canaries-ran.mjs'), need: [['--report', /--report(?:=|\s)/]] },
]
const TRIGGERS = ['push', 'pull_request']
const GUARD_KEYS = ['if', 'continue-on-error']
// `pull_request` 의 기본 활동 — `types:` 를 적으면 이 셋을 다 담아야 PR 을 열고 밀 때 레인이 돈다.
const PR_TYPES = ['opened', 'synchronize', 'reopened']

export class Unreadable extends Error {}

// YAML 주석 — 따옴표 밖이고 앞이 공백(또는 줄 머리)인 `#` 부터(check-ci-permissions.mjs 의 splitComment 와 같은 규칙).
// `run:` 블록 스칼라 안의 셸 주석도 같이 걷힌다 — 주석 처리한 attest 호출은 호출이 아니다.
export function stripComment(line) {
  let inS = false
  let inD = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (c === "'" && !inD) inS = !inS
    else if (c === '"' && !inS) inD = !inD
    else if (c === '#' && !inS && !inD && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i).trimEnd()
  }
  return line.trimEnd()
}
const indentOf = (l) => l.length - l.trimStart().length
const unq = (s) => s.trim().replace(/^(['"])(.*)\1$/, '$2')
const KEY = /^([A-Za-z_][\w-]*|'[^']*'|"[^"]*")\s*:(?:\s(.*))?$/

// GitHub `paths` 글롭 — `**` 는 `/` 를 넘고 `*`·`?` 는 넘지 않는다.
const globRe = (p) =>
  new RegExp(
    '^' +
      p
        .replace(/[.+^${}()|[\]\\]/g, '\\$&')
        .replace(/\*\*\/?|\*|\?/g, (m) => (m.startsWith('**') ? '.*' : m === '*' ? '[^/]*' : '[^/]')) +
      '$',
  )
export const covers = (pats, file) => pats.some((p) => globRe(p).test(file))

// `on:` 의 한 트리거 — {paths, types, branches, tags}. null = 그 트리거가 없다. `paths` 가 없으면 ['**'](경로로 거르지
// 않는다), 다른 셋은 없으면 null. ⚠️ 경로만 보면 `types: [labeled]` · `branches: [develop]` 처럼 PR 에서 아예 안 도는
// 트리거가 「받는다」로 읽힌다(Grok 레그). 같은 키가 두 번이거나 `*-ignore` 면 어느 것이 쓰이는지 대조하지 않는다(판정 불가).
const UNFILTERED = { paths: ['**'], types: null, branches: null, tags: null }
export function triggerSpec(lines, trig) {
  const body = lines.map(stripComment)
  const onIdx = body.findIndex((l) => /^['"]?on['"]?\s*:/.test(l))
  if (onIdx < 0) throw new Unreadable('최상위 `on:` 이 없다')
  const v = body[onIdx].replace(/^['"]?on['"]?\s*:/, '').trim()
  if (v.startsWith('{')) throw new Unreadable('`on:` 이 플로우 매핑이다 — 블록 표기로 적을 것')
  if (v.startsWith('[')) {
    if (!v.endsWith(']')) throw new Unreadable('`on:` 이 한 줄에서 닫히지 않는 플로우 시퀀스다')
    return v.slice(1, -1).split(',').map(unq).includes(trig) ? UNFILTERED : null
  }
  if (v !== '') return unq(v) === trig ? UNFILTERED : null
  let kid = null
  let at = -1
  const seq = []
  for (let k = onIdx + 1; k < body.length; k++) {
    const l = body[k]
    if (l.trim() === '') continue
    const ind = indentOf(l)
    if (ind === 0) break
    if (kid === null) kid = ind
    if (ind !== kid) continue
    const item = /^-\s+(.+)$/.exec(l.trim())
    if (item) {
      seq.push(unq(item[1]))
      continue
    }
    const m = KEY.exec(l.trim())
    if (m && unq(m[1]) === trig) {
      at = k
      break
    }
  }
  if (seq.length) return seq.includes(trig) ? UNFILTERED : null
  if (at < 0) return null
  const head = (KEY.exec(body[at].trim())?.[2] ?? '').trim()
  const tail = []
  for (let k = at + 1; k < body.length; k++) {
    if (body[k].trim() === '') continue
    if (indentOf(body[k]) <= kid) break
    tail.push(body[k])
  }
  const text = [head, ...tail].join('\n')
  for (const bad of ['paths-ignore', 'branches-ignore', 'tags-ignore'])
    if (new RegExp(`(^|[\\s{,])${bad}\\s*:`).test(text)) throw new Unreadable(`\`${trig}\` 의 ${bad} 는 대조하지 않는다`)
  const list = (key) => {
    const n = text.match(new RegExp(`(^|[\\s{,])${key}\\s*:`, 'g'))?.length ?? 0
    if (n === 0) return null
    if (n > 1) throw new Unreadable(`\`${trig}.${key}\` 가 두 번 적혔다 — 어느 쪽이 쓰이는지 대조하지 않는다`)
    const flow = new RegExp(`(^|[\\s{,])${key}\\s*:\\s*\\[([^\\]\\n]*)\\]`).exec(text)
    if (flow) return flow[2].split(',').map(unq).filter(Boolean)
    if (new RegExp(`(^|[\\s{,])${key}\\s*:\\s*\\[`).test(text)) throw new Unreadable(`\`${trig}.${key}\` 플로우 시퀀스가 한 줄에서 닫히지 않는다`)
    const pi = tail.findIndex((l) => new RegExp(`^\\s*${key}\\s*:\\s*$`).test(l))
    if (pi < 0) throw new Unreadable(`\`${trig}.${key}\` 를 읽지 못했다`)
    const out = []
    for (let k = pi + 1; k < tail.length; k++) {
      const item = /^\s*-\s+(.+)$/.exec(tail[k])
      if (!item || indentOf(tail[k]) < indentOf(tail[pi])) break
      out.push(unq(item[1]))
    }
    if (out.length === 0) throw new Unreadable(`\`${trig}.${key}\` 에서 항목을 하나도 읽지 못했다`)
    return out
  }
  const paths = list('paths') ?? ['**']
  if (paths.some((p) => p.startsWith('!'))) throw new Unreadable(`\`${trig}.paths\` 의 부정 패턴은 순서 의미를 대조하지 않는다`)
  return { paths, types: list('types'), branches: list('branches'), tags: list('tags') }
}

// 그 종류의 증명 단계들 — {line, langs, stepKeys, job, jobKeys, problems}.
export function laneSteps(lines, step) {
  const K = step.kind
  const body = lines.map(stripComment)
  const jobsAt = body.findIndex((l) => /^jobs\s*:\s*$/.test(l))
  const out = []
  for (let k = 0; k < body.length; k++) {
    if (!step.re.test(body[k])) continue
    const lang = /--lang(?:=|\s+)(["']?)([^\s"']+)\1/.exec(body[k])
    if (!lang) throw new Unreadable(`${k + 1}행: ${K} 호출의 \`--lang\` 을 읽지 못했다`)
    if (lang[2].includes('$')) throw new Unreadable(`${k + 1}행: \`--lang\` 이 변수다 — 정적으로 대조할 수 없다`)
    if (jobsAt < 0 || jobsAt > k) throw new Unreadable(`${k + 1}행: ${K} 호출이 \`jobs:\` 밖에 있다`)
    // 단계 머리 — 이 줄이 `- ` 이면 이 줄, 아니면 더 얕은 들여쓰기의 가장 가까운 `- ` 줄.
    let s = -1
    for (let j = k; j > jobsAt; j--) {
      if (/^\s*-\s/.test(body[j]) && (j === k || indentOf(body[j]) < indentOf(body[k]))) {
        s = j
        break
      }
    }
    if (s < 0) throw new Unreadable(`${k + 1}행: ${K} 호출을 담은 단계(\`- \`)를 찾지 못했다`)
    const si = indentOf(body[s])
    const stepKeys = []
    const first = /^\s*-\s+([A-Za-z_][\w-]*)\s*:/.exec(body[s])
    if (first) stepKeys.push(first[1])
    for (let j = s + 1; j < body.length; j++) {
      if (body[j].trim() === '') continue
      if (indentOf(body[j]) <= si) break
      const m = indentOf(body[j]) === si + 2 && KEY.exec(body[j].trim())
      if (m) stepKeys.push(unq(m[1]))
    }
    // 잡 — `jobs:` 아래 첫 키의 들여쓰기가 잡 들여쓰기다. 단계 위로 가장 가까운 그 들여쓰기의 키.
    const ji = indentOf(body.slice(jobsAt + 1).find((l) => l.trim() !== '') ?? '')
    let jl = -1
    for (let j = s; j > jobsAt; j--) {
      if (body[j].trim() !== '' && indentOf(body[j]) === ji && KEY.test(body[j].trim())) {
        jl = j
        break
      }
    }
    if (jl < 0) throw new Unreadable(`${k + 1}행: ${K} 단계를 담은 잡을 찾지 못했다`)
    const jobKeys = []
    for (let j = jl + 1; j < body.length; j++) {
      if (body[j].trim() === '') continue
      if (indentOf(body[j]) <= ji) break
      const m = indentOf(body[j]) === ji + 2 && KEY.exec(body[j].trim())
      if (m) jobKeys.push(unq(m[1]))
    }
    // 종료코드 — 단계의 종료코드가 곧 그 검사의 것이어야 한다(`|| true` 가 실패를 삼킨다 — Grok 레그). 그래서 그 호출은
    // 줄 머리에서 시작하고(앞 명령 · `!` 없음), 그 줄에 셸 연산자가 없고, 블록 스칼라라면 그 run 의 마지막 명령이다.
    const problems = []
    const cmd = body[k].trim().replace(/^-\s+/, '').replace(/^run\s*:\s*/, '')
    if (!/^node\s/.test(cmd)) problems.push(`${K} 명령이 줄 머리에서 시작하지 않는다(앞 명령 · \`!\`)`)
    if (/[;&|]/.test(cmd.replace(/"[^"]*"|'[^']*'/g, ''))) problems.push(`${K} 줄에 셸 연산자(; & |)가 있다 — 단계의 종료코드가 바뀐다`)
    for (const [flag, re] of step.need)
      if (!re.test(body[k])) problems.push(`${K} 호출에 \`${flag}\` 가 없다 — 그 검사가 실행마다 판정 불가다`)
    if (!/^(-\s+)?run\s*:/.test(body[k].trim())) {
      let r = -1
      for (let j = k - 1; j >= s; j--) {
        if (/^\s*(-\s+)?run\s*:\s*[|>]/.test(body[j])) {
          r = j
          break
        }
      }
      if (r < 0) throw new Unreadable(`${k + 1}행: ${K} 호출이 어느 \`run:\` 블록에 있는지 읽지 못했다`)
      for (let j = k + 1; j < body.length; j++) {
        if (body[j].trim() === '') continue
        if (indentOf(body[j]) > indentOf(body[r])) problems.push(`${K} 가 그 run 의 마지막 명령이 아니다 — 단계의 종료코드가 뒤 명령의 것이 된다`)
        break
      }
    }
    out.push({ line: k + 1, langs: lang[2].split(','), stepKeys, job: unq(KEY.exec(body[jl].trim())[1]), jobKeys, problems })
  }
  return out
}
// #934 의 이름 — attest 단계만.
export const attestSteps = (lines) => laneSteps(lines, STEPS[0])

function main() {
  const root = resolve(process.argv[2] ?? REPO)
  const fails = new Set()
  const unusable = []
  let langs = []
  try {
    langs = deriveLangs(root)
  } catch (e) {
    unusable.push(`언어 집합 파생이 실패했다: ${e.message}`)
  }
  if (langs.length === 0 && unusable.length === 0) unusable.push('파생된 언어가 0 개다 — 0 개를 훑고 통과하지 않는다')
  const dir = join(root, '.github', 'workflows')
  let files = []
  try {
    files = readdirSync(dir).filter((f) => /\.ya?ml$/.test(f)).sort()
  } catch (e) {
    unusable.push(`${dir} 를 읽지 못했다: ${e.message}`)
  }
  const byKind = new Map(STEPS.map((s) => [s.kind, new Map(langs.map((l) => [l, []]))]))
  const nSteps = new Map(STEPS.map((s) => [s.kind, 0]))
  for (const f of files) {
    const lines = readFileSync(join(dir, f), 'utf8').split(/\r?\n/)
    const found = []
    const trig = {}
    try {
      for (const step of STEPS) for (const st of laneSteps(lines, step)) found.push({ K: step.kind, st })
      if (found.length) for (const t of TRIGGERS) trig[t] = triggerSpec(lines, t)
    } catch (e) {
      if (!(e instanceof Unreadable)) throw e
      unusable.push(`${f}: ${e.message}`)
      continue
    }
    for (const { K, st } of found) {
      nSteps.set(K, nSteps.get(K) + 1)
      const byLang = byKind.get(K)
      for (const lang of st.langs) {
        if (!byLang.has(lang)) {
          fails.add(`${f}:${st.line} ${K} 가 파생 언어 밖의 「${lang}」를 부른다(철자 · 지운 언어)`)
          continue
        }
        byLang.get(lang).push(`${f}:${st.line} (${st.job})`)
        for (const k of GUARD_KEYS) {
          if (st.stepKeys.includes(k)) fails.add(`${f}:${st.line} ${lang} ${K} 단계에 \`${k}:\` — 조건부 ${K} 는 증명이 아니다`)
          if (st.jobKeys.includes(k)) fails.add(`${f}:${st.line} ${lang} ${K} 를 담은 잡 \`${st.job}\` 에 \`${k}:\` — 조건부 ${K} 는 증명이 아니다`)
        }
        for (const p of st.problems) fails.add(`${f}:${st.line} ${lang} ${p}`)
        for (const t of TRIGGERS) {
          const spec = trig[t]
          if (spec === null) {
            fails.add(`${f}: \`${t}\` 트리거가 없다 — ${lang} 레인이 그 사건에서 ${K} 를 돌지 않는다`)
            continue
          }
          if (!covers(spec.paths, `${lang}/x`)) fails.add(`${f}: \`${t}.paths\` 가 \`${lang}/**\` 를 받지 않는다`)
          for (const s of SHARED)
            if (!covers(spec.paths, s)) fails.add(`${f}: \`${t}.paths\` 가 ${s} 를 받지 않는다 — 그 파일만 바꾼 PR 에서 ${lang} 레인이 생기지 않는다`)
          if (spec.branches && !covers(spec.branches, 'main'))
            fails.add(`${f}: \`${t}.branches\` 가 main 을 받지 않는다 — main 으로 가는 변경에서 ${lang} 레인이 돌지 않는다`)
          if (t === 'push' && spec.tags && !spec.branches) fails.add(`${f}: \`push\` 가 태그에만 걸린다 — 브랜치 push 에서 ${lang} 레인이 돌지 않는다`)
          if (t === 'pull_request' && spec.types)
            for (const need of PR_TYPES)
              if (!spec.types.includes(need)) fails.add(`${f}: \`pull_request.types\` 에 ${need} 가 없다 — 그 사건에서 ${lang} 레인이 돌지 않는다`)
        }
      }
    }
  }
  for (const s of STEPS)
    for (const [lang, where] of byKind.get(s.kind))
      if (where.length === 0) fails.add(`${lang}: ${s.kind}(\`node ${s.script} … --lang ${lang}\`)를 도는 워크플로 단계가 없다`)
  for (const lang of langs)
    if (STEPS.every((s) => byKind.get(s.kind).get(lang).length))
      console.log(`ok    ${lang.padEnd(7)} ${STEPS.map((s) => `${s.kind} ${byKind.get(s.kind).get(lang).join(' · ')}`).join(' | ')}`)
  for (const u of unusable) console.error(`::error::판정 불가 — ${u}`)
  for (const x of fails) console.error(`::error::FAIL ${x}`)
  const counts = STEPS.map((s) => `${s.kind} 단계 ${nSteps.get(s.kind)}`).join(' · ')
  console.log(`레인 배선: 언어 ${langs.length} · ${counts} · FAIL ${fails.size} · 판정 불가 ${unusable.length}`)
  process.exit(unusable.length ? 2 : fails.size ? 1 : 0)
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
