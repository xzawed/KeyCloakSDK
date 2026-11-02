#!/usr/bin/env node
// check-hp-attest-wiring.mjs — 적대 경로 행렬 attest 의 **배선**을 정적으로 대조한다: 레인이 attest 단계를 조건 없이
// 돌고, 행렬·attest 가 읽는 공용 파일만 바꾼 PR 에서도 그 레인이 생기는가.
//
// 왜: `check-hp-attest.mjs` 는 레인 단계가 **돌 때만** 증명한다 — 그 단계를 지우거나 `if:`·`continue-on-error` 로
// 무르면 아무것도 울지 않았다(등록부 `guard-detection-surface-hand-narrowed` 의 남은 칸). 그리고 아홉 행렬의 W1 이
// 런타임에 읽는 `scripts/test/test-security-defaults.sh` 가 레인 `paths:` 밖이라, 그 스크립트만 바꾼 PR 은 언어 CI 를
// 만들지 않았다 — 2026-09-01 이후 그 파일을 고친 `main` 커밋 36 중 18 이 언어 디렉터리를 안 건드렸다
// (`w1-shared-script-drift-weekly-only`). 행렬이 런타임에 읽는 루트 파일은 그 하나다(다른 루트 경로는 주석 속 인용).
//
// 모델 — 언어 집합은 트리에서 파생한다(`check-known-gaps.mjs` 의 `deriveLangs` = `df_tree_langs`). 언어마다:
//  (1) `.github/workflows/*.yml|yaml` 의 주석 아닌 줄에서 `node … scripts/check-hp-attest.mjs … --lang <언어>` 를 도는
//      단계가 하나 이상 있다.
//  (2) 그 단계와 그 잡에 `if:` · `continue-on-error:` 키가 없다 — 조건부 attest 는 증명이 아니다.
//  (3) 그 워크플로의 `push` · `pull_request` 트리거가 `<언어>/**` 와 `SHARED` 를 받는다(`paths:` 가 없으면 전부 받는다).
//  그리고 attest 가 부르는 언어가 파생 집합 밖이면(철자 · 지운 언어) FAIL 이다.
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
export const SHARED = ['scripts/check-hp-attest.mjs', 'scripts/test/test-security-defaults.sh']
const TRIGGERS = ['push', 'pull_request']
const GUARD_KEYS = ['if', 'continue-on-error']

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

// `on:` 의 한 트리거가 받는 경로 패턴. null = 그 트리거가 없다 · ['**'] = 경로로 거르지 않는다.
export function triggerPaths(lines, trig) {
  const body = lines.map(stripComment)
  const onIdx = body.findIndex((l) => /^['"]?on['"]?\s*:/.test(l))
  if (onIdx < 0) throw new Unreadable('최상위 `on:` 이 없다')
  const v = body[onIdx].replace(/^['"]?on['"]?\s*:/, '').trim()
  if (v.startsWith('{')) throw new Unreadable('`on:` 이 플로우 매핑이다 — 블록 표기로 적을 것')
  if (v.startsWith('[')) {
    if (!v.endsWith(']')) throw new Unreadable('`on:` 이 한 줄에서 닫히지 않는 플로우 시퀀스다')
    return v.slice(1, -1).split(',').map(unq).includes(trig) ? ['**'] : null
  }
  if (v !== '') return unq(v) === trig ? ['**'] : null
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
  if (seq.length) return seq.includes(trig) ? ['**'] : null
  if (at < 0) return null
  const head = (KEY.exec(body[at].trim())?.[2] ?? '').trim()
  const tail = []
  for (let k = at + 1; k < body.length; k++) {
    if (body[k].trim() === '') continue
    if (indentOf(body[k]) <= kid) break
    tail.push(body[k])
  }
  const text = [head, ...tail].join('\n')
  if (/(^|[\s{,])paths-ignore\s*:/.test(text)) throw new Unreadable(`\`${trig}\` 의 paths-ignore 는 대조하지 않는다`)
  let pats
  const flow = /(^|[\s{,])paths\s*:\s*\[([^\]\n]*)\]/.exec(text)
  if (flow) pats = flow[2].split(',').map(unq).filter(Boolean)
  else if (/(^|[\s{,])paths\s*:\s*\[/.test(text)) throw new Unreadable(`\`${trig}.paths\` 플로우 시퀀스가 한 줄에서 닫히지 않는다`)
  else {
    const pi = tail.findIndex((l) => /^\s*paths\s*:\s*$/.test(l))
    if (pi < 0) {
      if (/(^|[\s{,])paths\s*:/.test(text)) throw new Unreadable(`\`${trig}.paths\` 를 읽지 못했다`)
      return ['**']
    }
    pats = []
    for (let k = pi + 1; k < tail.length; k++) {
      const item = /^\s*-\s+(.+)$/.exec(tail[k])
      if (!item || indentOf(tail[k]) < indentOf(tail[pi])) break
      pats.push(unq(item[1]))
    }
    if (pats.length === 0) throw new Unreadable(`\`${trig}.paths\` 에서 항목을 하나도 읽지 못했다`)
  }
  if (pats.some((p) => p.startsWith('!'))) throw new Unreadable(`\`${trig}.paths\` 의 부정 패턴은 순서 의미를 대조하지 않는다`)
  return pats
}

// attest 를 부르는 단계들 — {line, langs, stepKeys, job, jobKeys}.
const ATTEST = /(^|[\s;&|(])node\s+(?:\S+\s+)*?(?:\.{1,2}\/)*scripts\/check-hp-attest\.mjs(?=[\s"']|$)/
export function attestSteps(lines) {
  const body = lines.map(stripComment)
  const jobsAt = body.findIndex((l) => /^jobs\s*:\s*$/.test(l))
  const out = []
  for (let k = 0; k < body.length; k++) {
    if (!ATTEST.test(body[k])) continue
    const lang = /--lang(?:=|\s+)(["']?)([^\s"']+)\1/.exec(body[k])
    if (!lang) throw new Unreadable(`${k + 1}행: attest 호출의 \`--lang\` 을 읽지 못했다`)
    if (lang[2].includes('$')) throw new Unreadable(`${k + 1}행: \`--lang\` 이 변수다 — 정적으로 대조할 수 없다`)
    if (jobsAt < 0 || jobsAt > k) throw new Unreadable(`${k + 1}행: attest 호출이 \`jobs:\` 밖에 있다`)
    // 단계 머리 — 이 줄이 `- ` 이면 이 줄, 아니면 더 얕은 들여쓰기의 가장 가까운 `- ` 줄.
    let s = -1
    for (let j = k; j > jobsAt; j--) {
      if (/^\s*-\s/.test(body[j]) && (j === k || indentOf(body[j]) < indentOf(body[k]))) {
        s = j
        break
      }
    }
    if (s < 0) throw new Unreadable(`${k + 1}행: attest 호출을 담은 단계(\`- \`)를 찾지 못했다`)
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
    if (jl < 0) throw new Unreadable(`${k + 1}행: attest 단계를 담은 잡을 찾지 못했다`)
    const jobKeys = []
    for (let j = jl + 1; j < body.length; j++) {
      if (body[j].trim() === '') continue
      if (indentOf(body[j]) <= ji) break
      const m = indentOf(body[j]) === ji + 2 && KEY.exec(body[j].trim())
      if (m) jobKeys.push(unq(m[1]))
    }
    out.push({ line: k + 1, langs: lang[2].split(','), stepKeys, job: unq(KEY.exec(body[jl].trim())[1]), jobKeys })
  }
  return out
}

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
  const byLang = new Map(langs.map((l) => [l, []]))
  let nSteps = 0
  for (const f of files) {
    const lines = readFileSync(join(dir, f), 'utf8').split(/\r?\n/)
    let steps
    const trig = {}
    try {
      steps = attestSteps(lines)
      if (steps.length) for (const t of TRIGGERS) trig[t] = triggerPaths(lines, t)
    } catch (e) {
      if (!(e instanceof Unreadable)) throw e
      unusable.push(`${f}: ${e.message}`)
      continue
    }
    for (const st of steps) {
      nSteps++
      for (const lang of st.langs) {
        if (!byLang.has(lang)) {
          fails.add(`${f}:${st.line} attest 가 파생 언어 밖의 「${lang}」를 부른다(철자 · 지운 언어)`)
          continue
        }
        byLang.get(lang).push(`${f}:${st.line} (${st.job})`)
        for (const k of GUARD_KEYS) {
          if (st.stepKeys.includes(k)) fails.add(`${f}:${st.line} ${lang} attest 단계에 \`${k}:\` — 조건부 attest 는 증명이 아니다`)
          if (st.jobKeys.includes(k)) fails.add(`${f}:${st.line} ${lang} attest 를 담은 잡 \`${st.job}\` 에 \`${k}:\` — 조건부 attest 는 증명이 아니다`)
        }
        for (const t of TRIGGERS) {
          const pats = trig[t]
          if (pats === null) {
            fails.add(`${f}: \`${t}\` 트리거가 없다 — ${lang} 레인이 그 사건에서 attest 를 돌지 않는다`)
            continue
          }
          if (!covers(pats, `${lang}/x`)) fails.add(`${f}: \`${t}.paths\` 가 \`${lang}/**\` 를 받지 않는다`)
          for (const s of SHARED)
            if (!covers(pats, s)) fails.add(`${f}: \`${t}.paths\` 가 ${s} 를 받지 않는다 — 그 파일만 바꾼 PR 에서 ${lang} 레인이 생기지 않는다`)
        }
      }
    }
  }
  for (const [lang, where] of byLang) {
    if (where.length === 0) fails.add(`${lang}: attest(\`node scripts/check-hp-attest.mjs … --lang ${lang}\`)를 도는 워크플로 단계가 없다`)
    else console.log(`ok    ${lang.padEnd(7)} ${where.join(' · ')}`)
  }
  for (const u of unusable) console.error(`::error::판정 불가 — ${u}`)
  for (const x of fails) console.error(`::error::FAIL ${x}`)
  console.log(`hp-attest 배선: 언어 ${langs.length} · attest 단계 ${nSteps} · FAIL ${fails.size} · 판정 불가 ${unusable.length}`)
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
