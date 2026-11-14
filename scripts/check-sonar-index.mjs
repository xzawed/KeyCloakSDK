#!/usr/bin/env node
// SonarCloud 색인 수 계측기 — 이 실행의 `SonarCloud` 잡이 색인한 파일 수를 남기고, main 의 직전 성공 스캔과 견준다.
//
// 왜 필요한가: `sonar.tests` 만 넣은 PR #304 의 스캔은 색인 487 → 159 로 소스 집합이 무너지고도 품질 게이트가
// PASSED 였다 — 볼 게 없어서 통과한 초록(docs/governance/rejected.md 「SonarCloud `sonar.tests` 설정」). 그 행의
// 되살릴 조건은 「넣은 실행과 넣지 않은 직전 실행의 색인 수가 같은가」인데, 그 수는 잡 로그에만 있었고 아무도
// 기록하지 않았다(등록부 sonar-tests-revive-instrument).
//
// 판정:
//   - 현재 = 이 실행의 `SonarCloud` 잡 로그의 「N files indexed」. 없거나 서로 다른 값이 둘 이상이면 exit 2.
//   - 기준 = 같은 워크플로의 main push 실행 중 이 실행을 뺀 가장 최근 성공 실행의 같은 수(로그를 못 읽으면 그 앞
//     실행으로, 다섯 개까지).
//   - 기준보다 MAX_DROP 넘게 줄면 exit 1 — 소스 집합 붕괴(#304). MAX_RISE 넘게 늘어도 exit 1 — 생성물·바이너리가
//     소스로 색인되는 부류(sonar-project.properties 머리의 `coverage.xml` · `gradle-wrapper.jar`).
//   - 두 수와 두 실행을 $GITHUB_STEP_SUMMARY 에 남긴다 — 되살릴 실험의 계측값이다.
//   - 조회 실패는 exit 2 — 「모른다」를 「같다」로 반올림하지 않는다.
//   ⚠️ 문턱 안의 단계로 나눠 줄면 못 본다 — 성공한 실행이 다음 기준이 된다(Grok 레그). 겨누는 것은 설정 한 줄에
//   한 번에 무너지는 것(#304)이고, 실패한 실행은 기준이 되지 않으므로 그 빨강은 고칠 때까지 남는다.
import { spawnSync } from 'node:child_process'
import { appendFileSync, readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

export const MAX_DROP = 0.1
export const MAX_RISE = 0.25
const JOB = 'SonarCloud'
const WORKFLOW = 'sonarcloud.yml'
const BASE_TRIES = 5

// 로그의 「N files indexed」 — 값이 정확히 하나일 때만 그 수. 없거나 서로 다르면 null.
export function indexedCount(logText) {
  const seen = new Set()
  for (const m of String(logText ?? '').matchAll(/(?<![\d,.])(\d+) files indexed\b/g)) seen.add(Number(m[1]))
  return seen.size === 1 ? [...seen][0] : null
}

export function indexVerdict(current, baseline) {
  const change = (current - baseline) / baseline
  const pct = `${change >= 0 ? '+' : ''}${(change * 100).toFixed(1)}%`
  if (change < -MAX_DROP)
    return { ok: false, pct, reason: `색인이 ${pct} 줄었다 — 소스 집합이 무너졌는가(#304: 487 → 159 인데 게이트 PASSED)` }
  if (change > MAX_RISE)
    return { ok: false, pct, reason: `색인이 ${pct} 늘었다 — 생성물·바이너리가 소스로 색인됐는가` }
  return { ok: true, pct, reason: '' }
}

// res = { current, baseline, currentRun, baselineRun } — 수는 null 이면 「못 읽었다」.
export function decide(res) {
  const { current, baseline, currentRun, baselineRun } = res
  if (current == null) return { code: 2, lines: [`::error::이 실행(${currentRun})의 ${JOB} 잡 로그에서 「N files indexed」 를 하나로 읽지 못했다`] }
  if (baseline == null) return { code: 2, lines: [`::error::main 의 직전 성공 스캔에서 색인 수를 읽지 못했다 — 견줄 기준이 없다`] }
  const v = indexVerdict(current, baseline)
  const rec = `색인 ${baseline} (main 실행 ${baselineRun}) → ${current} (이 실행 ${currentRun}) · ${v.pct}`
  if (!v.ok) return { code: 1, lines: [`::error::${v.reason} · ${rec} · 문턱 -${MAX_DROP * 100}% / +${MAX_RISE * 100}%`] }
  return { code: 0, lines: [`${rec} — 문턱 안`] }
}

function gh(args) {
  const r = spawnSync('gh', args, { encoding: 'utf8', windowsHide: true, timeout: 120_000, maxBuffer: 64 * 1024 * 1024 })
  return r.status === 0 ? r.stdout : null
}

function jobLogCount(repo, runId) {
  const jobs = gh(['api', `repos/${repo}/actions/runs/${runId}/jobs`, '--jq', `.jobs[] | select(.name == "${JOB}") | .id`])
  const id = jobs?.trim().split('\n')[0]
  if (!id) return null
  return indexedCount(gh(['api', `repos/${repo}/actions/jobs/${id}/logs`]))
}

const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)

const USAGE = 'usage: GITHUB_REPOSITORY=<owner/repo> check-sonar-index.mjs --run <run id>\n' +
  '       check-sonar-index.mjs --log <저장한 잡 로그> --base-log <기준 잡 로그>   (조회 없이 같은 판정)'

function main() {
  const argv = process.argv.slice(2)
  const opt = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined }
  const runId = opt('--run')
  const repo = process.env.GITHUB_REPOSITORY
  let current = null
  let baseline = null
  let currentRun = runId
  let baselineRun = null
  if (opt('--log') !== undefined || opt('--base-log') !== undefined) {
    // 저장한 로그로 같은 판정 — 되살릴 실험의 두 실행을 다시 재는 길이자, 진입점을 조회 없이 시험하는 길이다.
    const read = (p) => { try { return readFileSync(p, 'utf8') } catch { return null } }
    const log = read(opt('--log') ?? '')
    const base = read(opt('--base-log') ?? '')
    if (log == null || base == null) { console.error(USAGE); process.exit(2) }
    current = indexedCount(log)
    baseline = indexedCount(base)
    currentRun = opt('--log')
    baselineRun = opt('--base-log')
  } else {
    if (!/^\d+$/.test(runId ?? '') || !/^[\w.-]+\/[\w.-]+$/.test(repo ?? '')) { console.error(USAGE); process.exit(2) }
    // 잡이 끝난 직후엔 로그가 아직 안 붙어 있을 수 있다 — 몇 번 다시 본다.
    for (let i = 0; i < 6 && current == null; i++) {
      if (i) pause(10_000)
      current = jobLogCount(repo, runId)
    }
    const runs = gh(['api', `repos/${repo}/actions/workflows/${WORKFLOW}/runs?branch=main&event=push&status=success&per_page=20`,
      '--jq', '.workflow_runs[].id'])
    for (const id of (runs ?? '').split('\n').map((s) => s.trim()).filter((s) => s && s !== runId).slice(0, BASE_TRIES)) {
      baseline = jobLogCount(repo, id)
      if (baseline != null) { baselineRun = id; break }
    }
  }
  const d = decide({ current, baseline, currentRun, baselineRun })
  for (const l of d.lines) console.log(l)
  if (process.env.GITHUB_STEP_SUMMARY) {
    const row = (n, r) => (n == null ? '못 읽음' : `${n} (실행 ${r})`)
    appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `### SonarCloud 색인 수\n\n| | 색인 |\n|---|---|\n| 이 실행 | ${row(current, currentRun)} |\n| main 직전 성공 | ${row(baseline, baselineRun)} |\n\n${d.lines.join('\n')}\n`)
  }
  process.exit(d.code)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
