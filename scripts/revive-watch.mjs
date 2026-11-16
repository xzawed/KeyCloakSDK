#!/usr/bin/env node
// revive-watch.mjs — 기각 레지스트리(docs/governance/rejected.md)의 되살릴 조건을 실제로 돌린다(등록부 revive-conditions-unmeasured).
//
// 그 문서는 되살릴 조건을 「돌아가는 명령」으로 적는다 — 다음 세션이 판정을 재현할 수 있게. 그런데 그 명령을 아무도 돌리지
// 않았고, 행 25 개가 전부 손 감시였다(실측 2026-11-16: mypy 행의 「현재 0건」이 낡아 있었다 — 아래 mypy 탐침).
// 그래서 표의 **행마다** 둘 중 하나를 둔다 — 기계가 재는 탐침(PROBES) 또는 기계로 못 재는 이유(MANUAL). 둘 다 없거나 둘 다
// 있거나 표에 없는 이름이면 실패한다(분할 — 새 기각 행은 여기서 분류해야 지나간다).
//
// 쓰임: node scripts/revive-watch.mjs [--partition | --tree] [--require-all] [--mypy-output <파일>] [root]
//   --partition    분류만(PR 마다 · 네트워크 없음)         --tree   트리 탐침까지(네트워크 없음)
//   (기본)         트리 · gh · mypy 탐침 — 쓸 수 없는 탐침은 「못 잼」으로 적고 넘어간다
//   --require-all  못 잰 탐침이 있으면 exit 2(주간 잡 — 조용히 건너뛰지 않는다)
//   --mypy-output  mypy 를 돌리지 않고 저장해 둔 출력으로 판정한다(재판정 · 자가테스트)
//   mypy 탐침은 REVIVE_PY(의존성이 깔린 python)가 있어야 돈다. gh 탐침은 GITHUB_REPOSITORY 가 있으면 그 저장소를 묻는다.
//   exit 0 아무 조건도 안 왔다 · 1 되살릴 조건이 왔다(그 행을 재판정하라) · 2 못 읽음 · 분류 어긋남 · (--require-all) 못 잰 탐침
import { spawnSync } from 'node:child_process'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { deriveLangs } from './check-known-gaps.mjs'

export const REGISTRY = 'docs/governance/rejected.md'
const MSRV_LEG = /\(Rust \d+\.\d+\)/

/** 표의 행 이름(첫 칸) — `\|` 는 칸 안의 글자다. */
export function rowNames(text) {
  const names = []
  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith('| ') || /^\|\s*-/.test(line) || line.startsWith('| 기각 |')) continue
    const m = /^\|\s((?:\\\||[^|])*?)\s\|/.exec(line)
    if (m) names.push(m[1].replace(/\\\|/g, '|'))
  }
  return names
}

const read = (root, p) => readFileSync(join(root, p), 'utf8')
// `gh run …` 는 -R 로 저장소를 받고, `gh api` 는 받지 않는다(실측: unknown shorthand flag 'R') — api 는 경로에 저장소를 쓴다.
const repoOf = () => process.env.GITHUB_REPOSITORY || '{owner}/{repo}'
function gh(args) {
  const repo = process.env.GITHUB_REPOSITORY
  const r = spawnSync('gh', repo && args[0] !== 'api' ? [...args, '-R', repo] : args, { encoding: 'utf8', maxBuffer: 16 << 20 })
  if (r.error || r.status !== 0) throw new Unavailable(`gh ${args.slice(0, 2).join(' ')} 실패: ${(r.stderr || String(r.error)).trim().split('\n')[0]}`)
  return args.includes('--log-failed') ? r.stdout : JSON.parse(r.stdout || '[]')
}
export class Unavailable extends Error {}
const since = (iso) => (r) => (r.createdAt ?? '') >= iso

// 탐침 — { kind, why, run(root) → { revive, detail } }. kind: tree(트리만) · gh(API) · mypy(툴체인).
export const PROBES = {
  '`repo-config`를 required 체크로': {
    kind: 'tree',
    run(root) {
      const b = JSON.parse(read(root, '.github/rulesets/main.json')).bypass_actors
      // 배열이 아니면 못 잰다 — `undefined > 0` 처럼 조용히 「안 옴」이 되지 않게(Grok 레그).
      if (!Array.isArray(b)) throw new Unavailable('main.json 의 bypass_actors 가 배열이 아니다')
      return { revive: b.length > 0, detail: `main.json bypass_actors ${b.length} 개` }
    },
  },
  'java 린트·정적분석 게이트': {
    kind: 'tree',
    run(root) {
      const n = read(root, 'sonar-project.properties').split(/\r?\n/).filter((l) => /^\s*sonar\.java\.binaries\s*[=:]/.test(l)).length
      return { revive: n === 0, detail: `sonar.java.binaries= 줄 ${n} 개` }
    },
  },
  'examples 모듈에 `<skipPublishing>`': {
    kind: 'tree', // publish mojo 의 aggregator 는 플러그인 jar 의 사실이라 여기서 못 본다 — 판 올림 PR 에서 본다
    run(root) {
      const mods = [...read(root, 'java/pom.xml').matchAll(/<module>([^<]+)<\/module>/g)].map((m) => m[1].trim())
      if (mods.length === 0) throw new Unavailable('java/pom.xml 에 <module> 이 없다')
      const last = mods.at(-1)
      return { revive: !/examples$/.test(last), detail: `마지막 모듈 ${last}` }
    },
  },
  'capability matrix **L열** 가드': { kind: 'tree', run: (root) => tenthLanguage(root) },
  '`DEPLOY.md` 3분할': { kind: 'tree', run: (root) => tenthLanguage(root) }, // 자격증명 분실은 사건이다 — 사람이 본다
  '`global.json`으로 .NET SDK 밴드 고정': {
    kind: 'tree', // 판정 당시의 대상 집합 — 바뀌면 그 라인이 서비싱 안인지 다시 본다(SDK 밴드 실패는 dotnet-ci 가 빨갛다)
    run(root) {
      const v = /<TargetFrameworks>([^<]*)<\/TargetFrameworks>/.exec(read(root, 'dotnet/Directory.Build.props'))?.[1]?.trim()
      if (v === undefined) throw new Unavailable('dotnet/Directory.Build.props 에 <TargetFrameworks> 가 없다')
      const set = v.split(';').map((s) => s.trim()).filter(Boolean).sort().join(';') // 공백 · 순서는 대상 집합이 아니다
      return { revive: set !== 'net10.0;net8.0', detail: `TargetFrameworks ${v}` }
    },
  },
  '`SONAR_TOKEN` 을 Dependabot 시크릿에 복제': {
    // 판정 2026-10-29 — 그 부류는 「Dependabot 커밋의 main 스캔이 **토큰 없이** 돈다」다. 토큰이 비면 스캐너가
    // `Not authorized or project not found` 로 실패한다(sonarcloud.yml scan 잡 주석). 다른 실패는 세지 않는다 — 2026-11-16
    // 재측: 판정 뒤 main 실패 넷 중 Dependabot 커밋 둘은 SonarCloud 서버의 「CE Task finished abnormally」와 스캐너의
    // Protobuf UTF-8 오류였다(같은 서버 오류가 사람 커밋에도 났다).
    kind: 'gh',
    run() {
      const runs = gh(['run', 'list', '--workflow', 'sonarcloud.yml', '--branch', 'main', '--status', 'failure', '--limit', '50', '--json', 'databaseId,headSha,createdAt']).filter(since('2026-10-29'))
      const bot = runs.filter((r) => gh(['api', `repos/${repoOf()}/commits/${r.headSha}`, '--jq', '{login: .author.login}']).login === 'dependabot[bot]')
      const noToken = bot.filter((r) => /Not authorized or project not found/.test(gh(['run', 'view', String(r.databaseId), '--log-failed'])))
      return { revive: noToken.length > 0, detail: `판정 뒤 main 실패 스캔 ${runs.length} · Dependabot 커밋 ${bot.length} · 그중 토큰 없음 ${noToken.length}` }
    },
  },
  'Rust `stable` 레그의 clippy 고정': {
    // 판정 2026-08-28 — 조건은 「stable 레그만 실패(MSRV 레그는 통과)」 **그리고 그것이 무관한 PR 을 막을 때」다. 그 PR 자신의
    // 새 코드에 새 lint 가 걸린 것은 레그의 목적대로라(2026-10-29 jwks-max-age 의 두 실행 — manual_is_multiple_of, 2026-11-16
    // 재판정) 한 브랜치 안의 실패는 세지 않는다 — **서로 다른 브랜치 둘 이상**이 같은 꼴로 깨질 때가 그 신호다.
    kind: 'gh',
    run() {
      const runs = gh(['run', 'list', '--workflow', 'rust-ci.yml', '--status', 'failure', '--limit', '30', '--json', 'databaseId,createdAt,headBranch']).filter(since('2026-08-28'))
      const only = runs.filter((r) => {
        const jobs = gh(['run', 'view', String(r.databaseId), '--json', 'jobs']).jobs ?? []
        const stable = jobs.find((j) => /\(Rust stable\)/.test(j.name))
        const msrv = jobs.find((j) => MSRV_LEG.test(j.name))
        return stable?.conclusion === 'failure' && msrv?.conclusion === 'success'
      })
      const branches = [...new Set(only.map((r) => r.headBranch))]
      return { revive: branches.length >= 2, detail: `판정 뒤 실패 ${runs.length} · stable 레그만 ${only.length}(브랜치 ${branches.length}${branches.length ? `: ${branches.join(' · ')}` : ''})` }
    },
  },
  '릴리스 순차머지 가드': {
    // 판정 2026-08-23 — dispatch-release 는 한 그룹이라, 나중 push 가 **대기 중인** 실행을 취소하면 스텝을 하나도 돌리지 않은
    // cancelled 로 남는다(기각 행의 말 그대로). 사람이 누른 Cancel 은 도는 중이라 스텝이 있다 — 그것은 세지 않는다(Grok 레그).
    kind: 'gh',
    run() {
      const runs = gh(['run', 'list', '--workflow', 'dispatch-release.yml', '--status', 'cancelled', '--limit', '20', '--json', 'databaseId,createdAt']).filter(since('2026-08-23'))
      const pending = runs.filter((r) => (gh(['run', 'view', String(r.databaseId), '--json', 'jobs']).jobs ?? []).every((j) => (j.steps ?? []).length === 0))
      return { revive: pending.length > 0, detail: `판정 뒤 취소된 dispatch-release ${runs.length} · 그중 스텝 없이(대기 중) ${pending.length}` }
    },
  },
  'mypy를 `python/tests`로 확장': {
    kind: 'mypy', // 그 부류는 「시험이 SDK API 를 잘못 부른다」다 — SDK 클래스 이름을 가리키는 call-arg · attr-defined 만 센다
    run(root, opts) {
      const out = opts.mypyOutput ?? runMypy(root)
      const hits = mypySdkErrors(out, sdkClasses(root))
      const total = out.split(/\r?\n/).filter((l) => /: error: /.test(l)).length
      return { revive: hits.length > 0, detail: `오류 ${total} 중 SDK 이름의 call-arg · attr-defined ${hits.length}${hits.length ? ` — ${hits.slice(0, 3).join(' · ')}` : ''}` }
    },
  },
}

// 기계로 못 재는 행 — 이유 한 줄. 이유가 「사건 · 실험 · 사람의 판정」이면 그것이 올 때 사람이 이 표를 본다.
export const MANUAL = {
  '금칙 문구 린트': '문맥으로 갈리는 판정이다 — 정규식이 수렴하지 않는다는 것이 기각 이유다',
  '문서 내부 수치 자기일치': '「드리프트가 실측될 때」는 사건이다 — 문서 감사 · check-docs 가 마주칠 때 판정한다',
  '퀵스타트 「중복」 삭제': '두 예제의 뜻이 갈렸는지는 뜻의 비교다 — 기계로 재지 않는다',
  'pre-1.0 문단 통합': '되살아난 문단을 찾을 글이 정해져 있지 않다(전제는 이미 소멸)',
  '게차 그룹화': '스펙 개정이라는 사람의 행위가 조건이다',
  'CLAUDE.md 생성물화': 'doc-guard 원천을 옮기는 설계 변경이 조건이다',
  '정식/RC 축 `claim_at` 신설': '런북이 무엇을 서술해야 하는가는 사람의 판정이다',
  'SonarCloud `sonar.tests` 설정': '실험(sonar.tests 를 넣은 스캔)이 있어야 판정 명령(check-sonar-index.mjs)에 뜻이 생긴다',
  'GitHub Release를 아홉 언어로 대칭화': '저장소 밖 소비자 도구의 행동이 조건이다',
  'KGP 2.4.20': '판 올림 실험(KGP 를 올려 CodeQL 잡 로그를 본다)이 조건이다',
  '전 워크플로 `persist-credentials: false` 강제': '사람의 정책 결정이 조건이다 — 쓰기 토큰 + 체크아웃은 check-ci-permissions 규칙 1b 가 이미 집행한다',
  '`release-readiness.sh` 의 원격 태그 대조': '도구가 틀린 답을 한 사건의 관측이 조건이다',
  '「천장 핀에는 `ignore` 도」 가드': '제약 선언의 설계 변경, 또는 머지 전 관측이 조건이다',
  'php-semver V154 면제': '리포트가 php 레인의 API 호환 실행 안에서만 생긴다 — 그것이 MAJOR 면 그 레인이 빨갛다',
  '`with:` 시크릿에 빈값 검사': 'with: 입력과 잡 env 를 짝짓는 파서가 없다 — 새 자리는 그것을 더하는 PR 의 일이다',
}

function tenthLanguage(root) {
  const langs = deriveLangs(root)
  return { revive: langs.length > 9, detail: `트리 언어 ${langs.length} 개(판정 당시 9)` }
}

/** SDK 가 정의한 클래스 이름 — python/src/keycloak_sdk/**.py 의 `class X`. */
export function sdkClasses(root) {
  const names = new Set()
  const walk = (d) => {
    for (const e of readdirSync(d)) {
      const p = join(d, e)
      if (statSync(p).isDirectory()) walk(p)
      else if (e.endsWith('.py')) for (const m of readFileSync(p, 'utf8').matchAll(/^class (\w+)/gm)) names.add(m[1])
    }
  }
  walk(join(root, 'python/src/keycloak_sdk'))
  return names
}

/** mypy 출력에서 SDK 이름을 가리키는 call-arg · attr-defined 오류 줄. */
export function mypySdkErrors(output, classes) {
  return output
    .split(/\r?\n/)
    .filter((l) => /: error: .*\[(?:call-arg|attr-defined)\]\s*$/.test(l))
    .filter((l) => /Module "keycloak_sdk/.test(l) || [...l.matchAll(/"([A-Za-z_]\w*)"/g)].some((m) => classes.has(m[1])))
    .map((l) => l.replace(/^.*?([^\\/]+:\d+): error: /, '$1: ').trim())
}

function runMypy(root) {
  const py = process.env.REVIVE_PY
  if (!py) throw new Unavailable('REVIVE_PY 가 없다(의존성이 깔린 python)')
  const r = spawnSync(py, ['-m', 'mypy', 'tests', '--disable-error-code=no-untyped-def'], { cwd: join(root, 'python'), encoding: 'utf8', maxBuffer: 16 << 20 })
  // mypy: 0 오류 없음 · 1 오류 있음 · 2 이상 · 실행 실패는 못 잼이다.
  if (r.error || (r.status !== 0 && r.status !== 1)) throw new Unavailable(`mypy 실행 실패: ${(r.stderr || String(r.error)).trim().split('\n')[0]}`)
  return r.stdout
}

/** 분류 어긋남 — 표에 있는데 분류 없음 · 둘 다 · 표에 없는 분류(유령). */
export function partitionProblems(names) {
  const out = []
  const known = new Set(names)
  for (const n of names) {
    const p = n in PROBES, m = n in MANUAL
    if (!p && !m) out.push(`분류 없는 행: ${n} — PROBES 에 탐침을 두거나 MANUAL 에 이유를 적는다`)
    if (p && m) out.push(`탐침과 수동이 둘 다인 행: ${n}`)
  }
  for (const n of [...Object.keys(PROBES), ...Object.keys(MANUAL)]) if (!known.has(n)) out.push(`표에 없는 분류(유령): ${n}`)
  if (new Set(names).size !== names.length) out.push('표에 같은 이름의 행이 둘 이상이다')
  return out
}

function main() {
  const args = process.argv.slice(2)
  const flag = (f) => {
    const i = args.indexOf(f)
    if (i >= 0) args.splice(i, 1)
    return i >= 0
  }
  const partitionOnly = flag('--partition'), treeOnly = flag('--tree'), requireAll = flag('--require-all')
  let mypyOutput
  const mi = args.indexOf('--mypy-output')
  if (mi >= 0) {
    mypyOutput = readFileSync(args[mi + 1], 'utf8')
    args.splice(mi, 2)
  }
  if (args.some((a) => a.startsWith('--'))) {
    console.error(`::error::모르는 옵션: ${args.find((a) => a.startsWith('--'))}`)
    process.exit(2)
  }
  // ⚠️ 기본 루트는 `fileURLToPath` 로 푼다 — `.pathname` 은 `%20` 을 풀지 않는다(check-workflow-paths.mjs 와 같다).
  const root = args[0] ?? fileURLToPath(new URL('..', import.meta.url))
  let names
  try {
    names = rowNames(read(root, REGISTRY))
  } catch (e) {
    console.error(`::error::${REGISTRY} 를 읽지 못했다 — ${e.message}`)
    process.exit(2)
  }
  if (names.length === 0) {
    console.error(`::error::${REGISTRY} 에서 기각 행을 0 개 읽었다 — 0 개를 훑고 통과하지 않는다`)
    process.exit(2)
  }
  const problems = partitionProblems(names)
  for (const p of problems) console.error(`::error::${p}`)
  const nProbe = names.filter((n) => n in PROBES).length
  console.log(`기각 행 ${names.length} · 탐침 ${nProbe} · 수동 ${names.length - nProbe}`)
  if (problems.length > 0) process.exit(2)
  if (partitionOnly) return
  let revived = 0, unmeasured = 0
  for (const n of names.filter((x) => x in PROBES)) {
    const p = PROBES[n]
    if (treeOnly && p.kind !== 'tree') continue
    try {
      const r = p.run(root, { mypyOutput })
      if (r.revive) revived++
      console.log(`${r.revive ? '!! 되살릴 조건이 왔다' : 'ok'}  [${p.kind}] ${n} — ${r.detail}`)
      if (r.revive) console.error(`::error::되살릴 조건이 왔다 — ${n}: ${r.detail} (${REGISTRY} 의 그 행을 재판정하라)`)
    } catch (e) {
      if (!(e instanceof Unavailable)) throw e
      unmeasured++
      console.log(`못 잼  [${p.kind}] ${n} — ${e.message}`)
    }
  }
  console.log(`되살릴 조건 ${revived} · 못 잰 탐침 ${unmeasured}`)
  if (revived > 0) process.exit(1)
  if (requireAll && unmeasured > 0) {
    console.error(`::error::못 잰 탐침 ${unmeasured} 개 — --require-all 이다(조용히 건너뛰지 않는다)`)
    process.exit(2)
  }
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop())) {
  try {
    main()
  } catch (e) {
    console.error(`::error::판정 불가 — 예상하지 못한 오류: ${e.stack ?? e}`)
    process.exit(2)
  }
}
