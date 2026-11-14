#!/usr/bin/env node
// Dependabot 업데이트가 대상마다 마지막에 성공했는가 — 아니면 exit 1.
//
// 왜 필요한가: Dependabot 업데이트 잡은 GitHub 의 동적 워크플로(`Dependabot Updates`, 이벤트 `dynamic`)라 그
// 결과가 이 저장소의 어떤 CI 에도 닿지 않는다 — `nightly-alert.yml` 은 예약 실행과 main push 만 본다. 실측
// 2026-11-14: ruby bundler 업데이트가 2026-09-17 부터 **매주 실패**했는데(simplecov ≥ 1.3 이 Ruby ≥ 3.3 을
// 요구해 dependency_file_not_resolvable) 아무 신호도 없었다(등록부 dependabot-updater-failure-blind).
// 예약 워크플로 `dependabot-health.yml` 이 이 스크립트를 돌리고, 그 빨강을 nightly-alert 가 이슈로 연다.
//
// 판정:
//   - 대상 = 실행 제목의 「<생태계> in <디렉터리>」. 뒤의 ` for <의존성>` · ` - Update #N` 은 뗀다 — 한 의존성만
//     겨눈 실행(보안 업데이트 등)도 그 디렉터리로 접혀, 다음 정기 실행이 성공하면 풀린다(접지 않으면 그 제목은
//     다시 오지 않아 영구 빨강이 되고, 영구 빨강은 곧 무시당한다).
//   - 대상마다 **마지막으로 끝난 실행**만 본다. failure · startup_failure · timed_out 이면 빨강.
//   - 창은 14 일 — 그보다 오래된 대상(디렉터리를 옮겨 은퇴한 표기 등)은 보지 않는다.
//   - 8 일 동안 실행이 하나도 없으면 빨강 — Dependabot 이 꺼진 것은 「실패 없음」이 아니다(주간 + 여유).
//   - 조회 실패 · 배열이 아닌 응답은 exit 2 — 「모른다」를 「건강하다」로 반올림하지 않는다.
import { spawnSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

const WORKFLOW = 'Dependabot Updates'
const WINDOW_DAYS = 14
const SILENT_DAYS = 8
const DAY = 86_400_000
const FAILED = new Set(['failure', 'startup_failure', 'timed_out'])

export function targetOf(title) {
  return String(title ?? '')
    .replace(/ - Update #\d+\s*$/, '')
    .replace(/ for .*$/, '')
    .trim()
}

// 순수 함수 — 자가테스트가 네트워크 없이 먹인다.
export function updatesVerdict(runs, now = Date.now()) {
  // ⚠️ 배열이 아니면 던진다. `null` · 객체 · 문자열을 빈 목록처럼 넘기면 「읽었는데 실패가 없었다」와
  // 「읽은 것이 실행 목록이 아니었다」가 같은 초록이 된다(check-dependabot-alerts.mjs 와 같은 함정).
  if (!Array.isArray(runs)) {
    throw new TypeError(`Dependabot 실행 목록이 배열이 아니다(${runs === null ? 'null' : typeof runs}) — 건강으로 넘기지 않는다`)
  }
  const since = now - WINDOW_DAYS * DAY
  const latest = new Map()
  let newest = -Infinity
  for (const r of runs) {
    const t = Date.parse(r?.createdAt)
    if (!Number.isFinite(t)) continue // 시각을 못 읽는 실행은 「돌았다」로도 세지 않는다
    newest = Math.max(newest, t)
    if (r?.status !== 'completed' || t < since) continue
    const key = targetOf(r?.displayTitle)
    const prev = latest.get(key)
    if (!prev || t > prev.t) latest.set(key, { t, run: r })
  }
  const failing = []
  if (!(newest >= now - SILENT_DAYS * DAY)) {
    const last = Number.isFinite(newest) ? new Date(newest).toISOString() : '없음'
    failing.push(`Dependabot 실행이 ${SILENT_DAYS} 일 동안 하나도 없다 — 꺼졌거나 막혔다(마지막: ${last})`)
  }
  for (const [key, { run }] of [...latest.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
    if (FAILED.has(run.conclusion)) {
      failing.push(`${key} — 마지막 실행이 ${run.conclusion} (${run.createdAt} · run ${run.databaseId})`)
    }
  }
  return { failing, targets: latest.size }
}

function gh(args) {
  const r = spawnSync('gh', args, { encoding: 'utf8', windowsHide: true, timeout: 60_000 })
  if (r.error) return { ok: false, out: `gh 실행 실패: ${r.error.message} (gh CLI 가 설치돼 있고 인증돼 있어야 한다)` }
  // 조회 실패는 언제나 「확인하지 못했다」(2)다. stdout 만 JSON 으로 읽는다 — stderr 의 경고가 섞이면 파싱이 깨진다.
  if (r.status !== 0) return { ok: false, out: `${r.stdout || ''}${r.stderr || ''}`.trim() }
  return { ok: true, out: r.stdout || '' }
}

function repoSlug(argv) {
  const i = argv.indexOf('--repo')
  if (i >= 0 && argv[i + 1]) return argv[i + 1]
  if (process.env.GITHUB_REPOSITORY) return process.env.GITHUB_REPOSITORY
  const r = gh(['repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'])
  if (!r.ok || !r.out.trim()) {
    console.error(`::error::저장소를 정하지 못했다 — --repo <owner/name> 을 준다\n${r.out}`)
    process.exit(2)
  }
  return r.out.trim()
}

// gh 조회 결과 → 종료 코드와 출력 줄. 순수 함수라 자가테스트가 프로세스 없이 먹인다 — Windows 에서는 PATH 의
// 스텁 `gh` 를 node 의 spawnSync 가 찾지 못하고 진짜 gh 를 불러, 진입점을 프로세스로 재면 엉뚱한 것을 잰다(실측).
export function decide(res, now = Date.now()) {
  if (!res?.ok) {
    return { code: 2, lines: [`::error::Dependabot 실행 목록을 읽지 못했다 — 확인하지 못했다(건강하다는 뜻이 아니다)`, String(res?.out ?? '')] }
  }
  let v
  try {
    v = updatesVerdict(JSON.parse(res.out), now)
  } catch (e) {
    return { code: 2, lines: [`::error::Dependabot 실행 목록을 판정하지 못했다 — ${e.message}`] }
  }
  if (v.failing.length === 0) {
    return { code: 0, lines: [`ok   Dependabot 대상 ${v.targets}개 — 마지막 실행이 전부 성공(창 ${WINDOW_DAYS} 일)`] }
  }
  return {
    code: 1,
    lines: [
      ...v.failing.map((f) => `::error::${f}`),
      '원인은 그 실행 로그 끝의 「Dependencies failed to update」 표에 있다 — `gh run view <run> --log`.',
    ],
  }
}

function main() {
  const repo = repoSlug(process.argv.slice(2))
  const res = gh(['run', 'list', '-R', repo, '--workflow', WORKFLOW, '--limit', '200',
    '--json', 'databaseId,status,conclusion,createdAt,displayTitle'])
  const d = decide(res)
  for (const line of d.lines) console.log(line)
  process.exit(d.code)
}

// process.argv[1] 은 `node -e '...'` 로 import 할 때 undefined 다 — 가드 없이 부르면 자가테스트가 네트워크를 때린다.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
