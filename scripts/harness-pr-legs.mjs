#!/usr/bin/env node
// harness-pr-legs.mjs — PR 이 하네스의 무거운 레그(score-all · install-all)를 돌려야 하는가.
//
// 두 레그는 하네스 전체(스위트 · 앱 · 설치 파이프라인)를 컨테이너로 돌린다(야간 실측: score-all ≈ 51 분 · install-all ≈ 15 분).
// 야간에만 돌면 하네스를 고친 PR 의 신호는 mvp-go 와 자가테스트뿐이고, 그 PR 이 레그를 깨도 머지 뒤 야간에야 안다.
// 그래서 PR 이 **레그가 읽는 것**을 바꿨을 때만 PR 에서도 돈다. 판정은 이 워크플로 자신의 `pull_request.paths` 에서 파생한다 —
// 패턴을 여기 다시 적지 않는다(check-workflow-paths.mjs 가 레그가 쓰는 파일을 그 paths 가 받는지 따로 본다).
//   · 뺀다: `go/**` — paths 에 있는 것은 mvp-go(Go 스모크) 때문이다. SDK 소스는 레인 CI 와 야간 레그가 본다(다른 여덟 언어와 같다).
//   · 뺀다: `*.md` — 레그가 실행하지 않는다.
//
// 쓰임: git diff --name-only <base>...HEAD | node scripts/harness-pr-legs.mjs [root]
//   stdout: `heavy=true|false` 한 줄($GITHUB_OUTPUT 에 그대로 붙인다) · stderr: 레그를 깨운 파일
//   exit 0 판정함 · 2 워크플로를 못 읽음(그 PR 의 changes 잡이 빨갛다 — 조용히 건너뛰지 않는다)
//       node scripts/harness-pr-legs.mjs --wiring [root]   — 그 워크플로의 배선을 본다. exit 0 · 1 어긋남 · 2 못 읽음
//   ⚠️ 두 레그의 `if:` 는 **글자 그대로** 고정한다. 가장 위험한 회귀는 `!cancelled()` 가 빠지는 것이다 — 야간 · 수동에는
//   changes 가 건너뛰어지고, 건너뛴 잡을 needs 하는 잡은 상태 함수가 없으면 함께 건너뛰어져 워크플로가 초록으로 끝난다.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Unreadable, covers, stripComment, triggerSpec } from './check-hp-attest-wiring.mjs'
import { jobsOf } from './check-workflow-paths.mjs'

export const WORKFLOW = '.github/workflows/harness.yml'
export const LEGS = ['score-all', 'install-all']
export const LEG_IF =
  "${{ !cancelled() && (github.event_name == 'workflow_dispatch' || github.event_name == 'schedule' || needs.changes.outputs.heavy == 'true') }}"
const DIFF_TO_FILE = 'git diff --name-only "origin/$BASE_REF...HEAD" > "$RUNNER_TEMP/changed.txt"'
const DECIDE = 'node scripts/harness-pr-legs.mjs < "$RUNNER_TEMP/changed.txt" >> "$GITHUB_OUTPUT"'

/** 워크플로 글의 배선 어긋남 목록(빈 목록 = 맞다). */
export function wiringProblems(text) {
  const lines = text.split(/\r?\n/)
  const jobs = jobsOf(lines)
  const block = (name) => {
    const i = jobs.findIndex((j) => j.name === name)
    if (i < 0) return null
    return { job: jobs[i], body: lines.slice(jobs[i].line, i + 1 < jobs.length ? jobs[i + 1].line - 1 : lines.length).map(stripComment) }
  }
  const out = []
  const ch = block('changes')
  if (!ch) out.push('changes 잡이 없다')
  else {
    if (ch.job.if !== "github.event_name == 'pull_request'") out.push(`changes 잡의 if 가 PR 전용이 아니다: ${ch.job.if}`)
    if (!ch.body.some((l) => /^\s+heavy\s*:\s*\$\{\{\s*steps\.legs\.outputs\.heavy\s*\}\}\s*$/.test(l))) out.push('changes 잡이 outputs.heavy 를 steps.legs 에서 내지 않는다')
    const run = ch.job.runs.map((r) => r.text.split('\n').map((s) => s.trim())).flat()
    if (!run.includes(DIFF_TO_FILE) || !run.includes(DECIDE)) out.push('changes 잡이 diff 를 파일로 받아 판정하지 않는다(파이프면 git 실패가 「깨울 것 없음」이 된다)')
  }
  for (const leg of LEGS) {
    const b = block(leg)
    if (!b) {
      out.push(`${leg} 잡이 없다`)
      continue
    }
    if (!b.body.some((l) => /^\s+needs\s*:\s*\[?\s*changes\s*\]?\s*$/.test(l))) out.push(`${leg} 잡에 needs: changes 가 없다`)
    if (b.job.if !== LEG_IF) out.push(`${leg} 잡의 if 가 고정한 글자와 다르다: ${b.job.if}`)
  }
  return out
}

/** 레그를 깨우는 파일 — 워크플로의 PR paths 가 받고, go/** 도 문서도 아닌 것. */
export function heavyFiles(paths, changed) {
  return changed.filter((f) => covers(paths, f) && !f.startsWith('go/') && !/\.md$/i.test(f))
}

export function prPaths(root) {
  const lines = readFileSync(join(root, WORKFLOW), 'utf8').split(/\r?\n/)
  const spec = triggerSpec(lines, 'pull_request')
  if (spec === null) throw new Unreadable(`${WORKFLOW} 에 pull_request 트리거가 없다`)
  return spec.paths
}

function main() {
  const args = process.argv.slice(2)
  const wiring = args[0] === '--wiring'
  if (wiring) args.shift()
  // ⚠️ 기본 루트는 `fileURLToPath` 로 푼다 — `.pathname` 은 `%20` 을 풀지 않는다(check-workflow-paths.mjs 와 같다).
  const root = args[0] ?? fileURLToPath(new URL('..', import.meta.url))
  if (wiring) {
    let problems
    try {
      problems = wiringProblems(readFileSync(join(root, WORKFLOW), 'utf8'))
    } catch (e) {
      console.error(`::error::${WORKFLOW} 를 읽지 못했다 — ${e.message}`)
      process.exit(2)
    }
    for (const p of problems) console.error(`::error::${WORKFLOW}: ${p}`)
    if (problems.length > 0) process.exit(1)
    console.log(`${WORKFLOW}: changes 잡 · 무거운 레그 ${LEGS.length} 개의 배선이 맞다`)
    return
  }
  let paths
  try {
    paths = prPaths(root)
  } catch (e) {
    console.error(`::error::${WORKFLOW} 의 pull_request.paths 를 읽지 못했다 — ${e.message}`)
    process.exit(2)
  }
  const changed = readFileSync(0, 'utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)
  const heavy = heavyFiles(paths, changed)
  for (const f of heavy) console.error(`레그를 깨운 파일: ${f}`)
  if (heavy.length === 0) console.error(`레그를 깨운 파일 없음 — 바뀐 파일 ${changed.length} 개`)
  console.log(`heavy=${heavy.length > 0}`)
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop())) {
  try {
    main()
  } catch (e) {
    console.error(`::error::판정 불가 — 예상하지 못한 오류: ${e.stack ?? e}`)
    process.exit(2)
  }
}
