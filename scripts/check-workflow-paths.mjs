#!/usr/bin/env node
// check-workflow-paths.mjs — `paths:` 로 거르는 워크플로가 PR 에서 **실행하는** 저장소 파일은 그 `paths:` 가 받아야 한다
// (등록부 guards-outside-their-own-pr-signal).
//
// 왜: `paths:` 필터는 잡을 건너뛰는 것이 아니라 그 PR 에 체크를 **만들지 않는다**(#368). 레인이 실행하는 스크립트가 레인의
// `paths:` 밖이면, 그 스크립트만 고친 PR 에서 그것을 **실제 호출 형태로** 돌리는 체크가 하나도 생기지 않는다 — 자가테스트
// (repo-hygiene)는 픽스처로 판정을 볼 뿐 레인의 호출(실제 산출물 · 실제 인자)을 타지 않는다. 실측(2026-11-16, main fea92d4e):
// 레인 넷이 자기가 실행하는 가드 넷을 안 받았고(ci · kotlin 의 check-jvm-bytecode-floor · ci 의 check-central-bundle · dotnet 의
// check-coverage · php 의 check-php-api-compat), 아홉 레인이 통합 장부가 실행하는 coverage-boundary.mjs 를, 공개 설치 스모크가
// 자기 스크립트가 쓰는 하네스 파일 다섯과 scripts/gradle/osv-audit-init.gradle 을 안 받았다. 마지막은 어느 PR 체크도 실행하지
// 않았다(security-audit 은 일정 · 수동뿐이다).
//
// 모델:
//  · 대상 — `pull_request` 트리거가 `paths:` 로 거르는 워크플로. `paths:` 가 없으면 모든 PR 에서 돈다(대상 아님).
//  · 실행되는 파일 — PR 에서 도는 잡의 `run:` 이 이름을 대는 저장소 파일(1단 — 스텝 · 잡 · 워크플로의 working-directory 와 `cd` 를
//    푼다), 그리고 그 파일이 스크립트면 그 안에서 저장소 경로로 대는 파일 · .mjs 의 상대 가져오기(2단 — 주석은 걷는다).
//    `scripts/` · `harness/` 아래만 본다 — 언어 디렉터리는 레인의 `<언어>/**` 가 받는다.
//  · PR 에서 건너뛰는 잡 — 잡의 `if:` 가 `github.event_name == '<이벤트>'` 들의 `||` 이고 pull_request 가 없으면 그 잡은 대조에서
//    뺀다(PR 에서 돌지 않는다). 그 잡 수를 인벤토리에 찍는다.
//  · 판정 — 실행되는 파일마다 그 워크플로의 `pull_request.paths` 가 받아야 한다. 트리거를 이해 못 하면 판정 불가(exit 2 —
//    `check-hp-attest-wiring.mjs` 의 triggerSpec 을 쓴다, 사본을 두지 않는다).
// ⚠️ 못 보는 것: 셸 스크립트 안의 상대 경로(`suites/$L.sh` · `./apps/…`)와 변수로 조립한 경로 · 변수 `cd` · 식으로 쓴
// working-directory, 3단 이상, 재사용 워크플로(`uses: ./.github/workflows/…` — 지금은 태그 트리거 릴리스만 부른다). 그리고 잡
// `if:` 가 위 꼴이 아닌 조건이면 PR 에서 돈다고 본다(보수적 — 받지 않으면 실패다).
//
// 사용: node scripts/check-workflow-paths.mjs [ROOT] [--min-workflows=<n>] [--min-files=<n>]
import { execFileSync } from 'node:child_process'
import { readFileSync, readdirSync } from 'node:fs'
import { join, posix } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Unreadable, covers, stripComment, triggerSpec } from './check-hp-attest-wiring.mjs'

const SHARED = /^(scripts|harness)\//
const indentOf = (l) => l.length - l.trimStart().length
// 대조 대상 트리 — 추적된 파일과 그 읽기(루트마다 하나 — 자가테스트가 픽스처 트리를 준다).
export function context(root) {
  const tracked = new Set(
    execFileSync('git', ['-C', root, 'ls-files'], { encoding: 'utf8', maxBuffer: 64 << 20 })
      .split('\n')
      .filter(Boolean),
  )
  return { root, tracked, read: (rel) => readFileSync(join(root, rel), 'utf8').replace(/\r/g, '') }
}

// 저장소 경로처럼 보이는 낱말 — `$GITHUB_WORKSPACE/` · `${{ github.workspace }}/` 는 저장소 루트다.
const PATHISH = /(?:\$\{\{\s*github\.workspace\s*\}\}\/|\$\{?GITHUB_WORKSPACE\}?\/)?(?:\.{1,2}\/)*[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+|\.\/[A-Za-z0-9_.-]+/g
// 작업 디렉터리 기준으로 먼저, 안 되면 저장소 루트 기준으로 푼다(namedInRun 이 둘 다 묻는다).
function resolveToken(ctx, tok, wd) {
  const rel = tok.replace(/^(\$\{\{\s*github\.workspace\s*\}\}|\$\{?GITHUB_WORKSPACE\}?)\//, '')
  const p = posix.normalize(wd === null ? rel : posix.join(wd, rel))
  return ctx.tracked.has(p) && SHARED.test(p) ? p : null
}
// 한 `run:` 본문이 이름을 대는 파일 — `cd <글자 그대로의 디렉터리>` 를 따라간다(변수면 상대 경로를 풀지 않는다).
export function namedInRun(ctx, text, wd0) {
  const out = new Set()
  let wd = wd0
  for (const raw of text.split('\n')) {
    const line = stripComment(raw)
    for (const seg of line.split(/&&|\|\||;/)) {
      const cd = /^\s*cd\s+(\S+)\s*$/.exec(seg)
      if (cd) {
        wd = /[$`]/.test(cd[1]) ? null : posix.normalize(posix.join(wd ?? '.', cd[1].replace(/^['"]|['"]$/g, '')))
        continue
      }
      for (const m of seg.matchAll(PATHISH)) {
        const f = resolveToken(ctx, m[0], wd) ?? resolveToken(ctx, m[0], null)
        if (f) out.add(f)
      }
    }
  }
  return out
}
// 2단 — 스크립트 안의 저장소 경로(루트 기준 글자 그대로), 그리고 .mjs · .js 면 그 파일 기준 상대 가져오기(`from './lib/x.mjs'` ·
// `import('./x.mjs')` · `new URL('./x.mjs', import.meta.url)` — Grok 적대 레그: 레인 paths 에서 lib 를 빼도 초록이었다). 주석 줄은 걷는다.
export function namedInScript(ctx, f) {
  if (!/\.(sh|mjs|js)$/.test(f)) return new Set()
  const text = ctx
    .read(f)
    .split('\n')
    .filter((l) => !/^\s*(#|\/\/|\*)/.test(l))
    .join('\n')
  const out = new Set()
  const add = (p) => {
    if (p !== f && ctx.tracked.has(p) && SHARED.test(p)) out.add(p)
  }
  for (const m of text.matchAll(/(?:^|[^A-Za-z0-9_.-])((?:scripts|harness)\/[A-Za-z0-9_.\/-]+)/g)) add(posix.normalize(m[1]))
  if (/\.(mjs|js)$/.test(f))
    for (const m of text.matchAll(/(?:\bfrom\s*|\bimport\s*\(?\s*|\bnew URL\(\s*)['"](\.{1,2}\/[^'"]+)['"]/g))
      add(posix.normalize(posix.join(posix.dirname(f), m[1])))
  return out
}

// 잡 — { name, line(1-based), if, runs: [{ line, text, wd }] }
export function jobsOf(lines) {
  const body = lines.map(stripComment)
  const j0 = body.findIndex((l) => /^jobs\s*:\s*$/.test(l))
  if (j0 < 0) throw new Unreadable('최상위 `jobs:` 가 없다')
  const wfWd = workingDir(body, 0, j0, 0)
  const keys = []
  let kid = null
  for (let k = j0 + 1; k < body.length; k++) {
    const l = body[k]
    if (l.trim() === '') continue
    const ind = indentOf(l)
    if (ind === 0) break
    if (kid === null) kid = ind
    if (ind === kid) {
      const m = /^([A-Za-z_][\w-]*)\s*:\s*$/.exec(l.trim())
      if (!m) throw new Unreadable(`${k + 1}행 잡 키를 읽지 못했다(플로우 표기?)`)
      keys.push({ name: m[1], at: k })
    }
  }
  const jobs = []
  for (let i = 0; i < keys.length; i++) {
    const from = keys[i].at
    let to = i + 1 < keys.length ? keys[i + 1].at : body.length
    for (let k = from + 1; k < to; k++) if (body[k].trim() !== '' && indentOf(body[k]) === 0) to = k
    const child = kid + 2
    const ifLine = body.slice(from + 1, to).find((l) => indentOf(l) === child && /^if\s*:/.test(l.trim()))
    const jobWd = workingDir(body, from + 1, to, child) ?? wfWd
    const runs = []
    for (let k = from + 1; k < to; k++) {
      const m = /^(\s*)(?:-\s+)?run\s*:\s?(.*)$/.exec(body[k])
      if (!m) continue
      const key = body[k].indexOf('run')
      const v = m[2].trim()
      const text = []
      if (v === '' || /^[|>][-+]?$/.test(v)) {
        for (let n = k + 1; n < to; n++) {
          if (lines[n].trim() !== '' && indentOf(lines[n]) <= key) break
          text.push(lines[n])
        }
      } else text.push(v)
      runs.push({ line: k + 1, text: text.join('\n'), wd: stepWd(body, k, from, key) ?? jobWd })
    }
    jobs.push({ name: keys[i].name, line: from + 1, if: ifLine ? ifLine.trim().replace(/^if\s*:\s*/, '') : null, runs })
  }
  return jobs
}
// `defaults: run: working-directory:` — [from, to) 안에서 indent 단 아래.
function workingDir(body, from, to, indent) {
  for (let k = from; k < to; k++) {
    if (indentOf(body[k]) !== indent || !/^defaults\s*:\s*$/.test(body[k].trim())) continue
    for (let n = k + 1; n < to && (body[n].trim() === '' || indentOf(body[n]) > indent); n++) {
      const m = /^working-directory\s*:\s*(.+)$/.exec(body[n].trim())
      if (m) return wdValue(m[1])
    }
  }
  return null
}
// 스텝의 `working-directory:` — 그 `run:` 이 든 스텝(앞의 `- ` 부터 다음 `- ` 전까지).
function stepWd(body, k, jobFrom, runKeyCol) {
  let s = k
  while (s > jobFrom && !/^\s*-\s/.test(body[s])) s--
  const dash = indentOf(body[s])
  for (let n = s; n < body.length; n++) {
    if (n > s && body[n].trim() !== '' && indentOf(body[n]) <= dash) break
    const m = /^(?:-\s+)?working-directory\s*:\s*(.+)$/.exec(body[n].trim())
    if (m) return wdValue(m[1])
  }
  return null
}
function wdValue(v) {
  const s = v.trim().replace(/^['"]|['"]$/g, '')
  if (/^\$\{\{\s*github\.workspace\s*\}\}$/.test(s) || s === '.') return '.'
  return /[$`]/.test(s) ? null : posix.normalize(s)
}
// 잡의 `if:` 가 이벤트 이름 등식의 `||` 뿐이고 pull_request 가 없으면 PR 에서 돌지 않는다.
export function skipsPullRequest(cond) {
  if (!cond) return false
  const c = cond.replace(/^\$\{\{\s*|\s*\}\}$/g, '').trim()
  const terms = c.split('||').map((t) => t.trim())
  const ev = terms.map((t) => /^github\.event_name\s*==\s*'([a-z_]+)'$/.exec(t)?.[1] ?? null)
  return ev.every((e) => e !== null) && !ev.includes('pull_request')
}

function main() {
  let rootArg = null
  let MIN_WORKFLOWS = 0
  let MIN_FILES = 0
  for (const a of process.argv.slice(2)) {
    if (/^--min-workflows=\d+$/.test(a)) MIN_WORKFLOWS = Number(a.slice('--min-workflows='.length))
    else if (/^--min-files=\d+$/.test(a)) MIN_FILES = Number(a.slice('--min-files='.length))
    else if (a.startsWith('--')) {
      console.error(`::error::모르는 옵션: ${a}`)
      process.exit(2)
    } else if (rootArg === null) rootArg = a
  }
  // ⚠️ 기본 루트는 `fileURLToPath` 로 푼다 — `.pathname` 은 `%20` 을 풀지 않는다(check-versions.mjs 와 같다).
  const ctx = context(rootArg ?? fileURLToPath(new URL('..', import.meta.url)))
  const dir = join(ctx.root, '.github', 'workflows')
  const files = readdirSync(dir).filter((f) => /\.ya?ml$/.test(f)).sort()
  const fails = []
  const unusable = []
  let nWf = 0
  let nFiles = 0
  let nSkippedJobs = 0
  for (const f of files) {
    const lines = readFileSync(join(dir, f), 'utf8').replace(/\r/g, '').split('\n')
    let spec
    let jobs
    try {
      spec = triggerSpec(lines, 'pull_request')
      if (!spec || (spec.paths.length === 1 && spec.paths[0] === '**')) continue
      jobs = jobsOf(lines)
    } catch (e) {
      if (e instanceof Unreadable) {
        unusable.push(`${f}: ${e.message}`)
        continue
      }
      throw e
    }
    nWf++
    const seen = new Map() // 파일 → 처음 대는 자리
    for (const job of jobs) {
      if (skipsPullRequest(job.if)) {
        nSkippedJobs++
        continue
      }
      for (const r of job.runs) {
        for (const h1 of namedInRun(ctx, r.text, r.wd)) {
          if (!seen.has(h1)) seen.set(h1, `${f}:${r.line} 잡 \`${job.name}\``)
          for (const h2 of namedInScript(ctx, h1)) if (!seen.has(h2)) seen.set(h2, `${f}:${r.line} 잡 \`${job.name}\` → ${h1}`)
        }
      }
    }
    nFiles += seen.size
    let bad = 0
    for (const [file, where] of seen)
      if (!covers(spec.paths, file)) {
        bad++
        fails.push(`${where} 가 ${file} 를 쓰는데 \`pull_request.paths\` 가 그것을 받지 않는다 — 그 파일만 고친 PR 에서 이 워크플로가 돌지 않는다`)
      }
    console.log(`${bad ? 'FAIL' : 'ok  '}  ${f.padEnd(24)} paths ${String(spec.paths.length).padStart(2)} · 쓰는 공유 파일 ${seen.size}${bad ? ` · 받지 않는 것 ${bad}` : ''}`)
  }
  if (nWf < MIN_WORKFLOWS) fails.push(`paths 로 거르는 PR 워크플로가 ${nWf}개뿐이다(기대 ${MIN_WORKFLOWS}개 이상) — 트리거 표기가 바뀌어 대조가 조용히 비었을 수 있다`)
  if (nFiles < MIN_FILES) fails.push(`쓰는 공유 파일이 ${nFiles}개뿐이다(기대 ${MIN_FILES}개 이상) — run 본문 해석이 깨졌을 수 있다`)
  for (const u of unusable) console.error(`::error::판정 불가 — ${u}`)
  for (const x of fails) console.error(`::error::FAIL ${x}`)
  console.log(`워크플로 paths: 대상 ${nWf} · 쓰는 공유 파일 ${nFiles} · PR 에서 건너뛰는 잡 ${nSkippedJobs} · FAIL ${fails.length} · 판정 불가 ${unusable.length}`)
  process.exit(unusable.length ? 2 : fails.length ? 1 : 0)
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop())) {
  try {
    main()
  } catch (e) {
    console.error(`::error::판정 불가 — 예상하지 못한 오류: ${e.stack ?? e}`)
    process.exit(2)
  }
}
