#!/usr/bin/env node
// check-ci-permissions.mjs — GITHUB_TOKEN 스코프가 **이 저장소 안에서** 결정되도록 못박는다.
//
// 왜 필요한가: 잡에 `permissions:`가 없으면 그 잡의 토큰은 워크플로 레벨 기본값을, 그것마저
// 없으면 **저장소 기본 권한**(Settings → Actions → Workflow permissions)을 물려받는다. 저장소
// 기본값은 이 저장소의 어떤 파일에도 없고, PR 리뷰를 거치지 않으며, UI 토글 한 번이나 조직
// 정책으로 바뀐다 — 즉 릴리스 잡이 쥐는 토큰의 힘이 코드 리뷰 바깥에서 정해진다. 릴리스
// 워크플로는 레지스트리에 게시하고 GitHub Release를 만드는 경로라 그 상태를 용납할 수 없다.
//
// 이 가드는 사람이 손으로 확인하던 것을 기계화한 것이다. 릴리스 워크플로 아홉 개의 권한을
// 잡 레벨로 내린 뒤(S7637) 남은 안전망은 각 파일 헤더의 "⚠️ 새 잡에는 반드시 `permissions:`를
// 함께 적을 것"이라는 **주석**뿐이었다. 주석은 잡을 추가하는 사람이 읽어야만 동작한다.
//
// 검사 범위가 규칙마다 다른 것은 의도다(각 규칙 주석 참조). 특히 "워크플로 레벨 블록 금지"를
// 저장소 전체로 넓히면 안 된다: `*-ci.yml`·`install-smoke.yml`은 모든 잡이 체크아웃하는 동질
// 워크플로라 워크플로 레벨 `contents: read` 한 줄이 정답이고, 잡 레벨로 흩으면 중복만 늘어난다.
// 넓힌 뒤 예외 목록으로 되돌리는 순간 그 목록이 썩기 시작한다.
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

// 루트는 인자로 받는다(check-versions.mjs·check-docs.mjs와 같은 관용) — 그래야 자가테스트가
// 픽스처 트리에 대해 이 가드를 실제로 돌려볼 수 있다. 플래그는 등장 위치와 무관하게 인식한다.
const DEFAULT_ROOT = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
let rootArg = null
// --min-release: 릴리스 워크플로가 이만큼은 있어야 한다. glob으로 범위를 좁히는 가드는
// **대상이 0건이어도 통과한다** — 누가 릴리스 워크플로를 `*-publish.yml`로 개명하면 이 가드는
// 아무것도 검사하지 않으면서 초록불을 낸다. CI는 실측치를 명시로 넘겨 그 침묵을 막는다.
let MIN_RELEASE = 1
// 같은 이유의 하한 둘 더 — 규칙 9(게시 잡)·규칙 10(비로컬 uses)도 발견 기반이라 조준점이
// 사라지면 0건을 검사하고 초록을 낸다.
let MIN_PUBLISH = 1
// ⚠️ 규칙 1b 의 하한은 **0 이 기본**이다(규칙 5 와 같은 이유) — 자가테스트 픽스처 트리에는
// `contents: write` + 체크아웃 잡이 없을 수 있고, 기본값 1 이면 그 정당한 경우가 빨개진다.
// 실측치는 CI 가 명시로 넘긴다.
let MIN_WRITE_CHECKOUT = 0
let MIN_USES = 1
// ⚠️ 그리고 규칙 5(권한 상승에 근거 주석)에도 같은 하한이 필요하다. 이 규칙은 **상승을 발견해서**
// 검사하므로, 상승이 스캐너에 안 보이게 되는 순간 0건을 검사하고 초록을 낸다. 실측: 플로우 매핑
// 표기 하나로 인벤토리의 상승 수가 6 → 5 로 줄어드는데도 통과했다. 인쇄만 하고 하한이 없으면
// 그 수가 줄어드는 것을 아무도 못 본다.
let MIN_ESCALATIONS = 0
// 규칙 11(PR 에서 시크릿을 쥐는 잡)도 발견 기반이다 — 시크릿 참조 표기나 트리거가 바뀌면 0건을
// 검사하고 초록을 낸다. 기본값 0 은 규칙 1b 와 같은 이유이고, 실측치는 CI 가 넘긴다.
let MIN_PR_SECRET_JOBS = 0
for (const arg of process.argv.slice(2)) {
  if (/^--min-release=\d+$/.test(arg)) MIN_RELEASE = Number(arg.slice('--min-release='.length))
  else if (/^--min-publish=\d+$/.test(arg)) MIN_PUBLISH = Number(arg.slice('--min-publish='.length))
  else if (/^--min-write-checkout=\d+$/.test(arg))
    MIN_WRITE_CHECKOUT = Number(arg.slice('--min-write-checkout='.length))
  else if (/^--min-uses=\d+$/.test(arg)) MIN_USES = Number(arg.slice('--min-uses='.length))
  else if (/^--min-escalations=\d+$/.test(arg))
    MIN_ESCALATIONS = Number(arg.slice('--min-escalations='.length))
  else if (/^--min-pr-secret-jobs=\d+$/.test(arg))
    MIN_PR_SECRET_JOBS = Number(arg.slice('--min-pr-secret-jobs='.length))
  else if (!arg.startsWith('--') && rootArg === null) rootArg = arg
}
const root = rootArg ?? DEFAULT_ROOT
const errors = []

// ── 최소 YAML 구조 스캐너 ────────────────────────────────────────────────────
// 왜 파서를 쓰지 않는가: 이 저장소의 scripts/*.mjs는 의존성이 없다(CI가 `npm ci` 없이 그냥
// `node`로 돌린다). 대신 **구조적 라인만** 본다 — 값의 의미는 해석하지 않고 들여쓰기와 키만
// 읽으므로, 해석하지 못하는 모양(플로우 스타일 잡 본문·머지 키)은 통과가 아니라 **오류**로
// 떨어뜨린다. 가드가 이해 못 한 것을 조용히 넘기면 그게 곧 우회로가 된다.

const KEY_LINE = /^ *([A-Za-z_][\w.-]*|'[^']*'|"[^"]*"):(\s.*)?$/
const BLOCK_SCALAR = /^[|>][-+]?\d*$/
const MERGE_KEY = /^ *<< *:/m
const unquote = (s) => s.replace(/^['"]|['"]$/g, '')

// 주석 제거. 따옴표 안의 `#`는 주석이 아니고, `foo#bar`의 `#`도 아니다(앞에 공백 필요).
// ⚠️ 이게 없으면 산문 주석이 규칙을 오염시킨다 — ruby-release.yml 헤더에는 "`contents: write`
// 권한이 불필요하다"는 **설명문**이 있어서, 주석을 안 걷어내면 존재하지도 않는 권한 상승을
// 검출한다. 반대로 `id-token: write # 이유` 같은 꼬리 주석을 안 걷어내면 값이 "write # 이유"가
// 되어 **진짜 권한 상승이 보이지 않는다**(자가테스트가 인벤토리 문구로 이 방향을 고정한다).
const splitComment = (line) => {
  let inS = false
  let inD = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (c === "'" && !inD) inS = !inS
    else if (c === '"' && !inS) inD = !inD
    else if (c === '#' && !inS && !inD && (i === 0 || /\s/.test(line[i - 1])))
      return { body: line.slice(0, i), comment: line.slice(i + 1).trim() }
  }
  return { body: line, comment: null }
}

// 한 줄에서 구조적 키 노드를 뽑는다. 시퀀스 항목(`- uses: ...`)은 KEY_LINE이 매치하지 않으므로
// 자동으로 제외된다 — 잡 매핑의 키가 될 수 없는데 포함하면 스텝 내부 키가 잡 레벨 키로 오인될
// 여지만 생긴다.
const keyNode = (raw, indent, n) => {
  const { body, comment } = splitComment(raw)
  const m = KEY_LINE.exec(body.trimEnd())
  if (!m) return null
  return { n, indent, key: unquote(m[1]), value: unquote((m[2] ?? '').trim()), comment }
}

// 블록 스칼라(`run: |`) 본문은 통째로 건너뛴다: 셸 스크립트 안의 아무 문자열이나 YAML 키로
// 읽히면 안 된다(php-ci.yml의 `fwrite(...)` 같은 줄이 실제로 있다).
// ⚠️ 정직하게 적어둔다 — blockIndent를 세우는 한 줄은 **자가테스트의 변이 검증에 걸리지 않는다.**
// GitHub 스키마상 스텝 본문은 항상 잡 레벨 키보다 두 단계 이상 깊게 들여쓰기되므로, 오늘의
// 규칙 다섯 개는 블록 스칼라 본문과 애초에 인덱스가 겹치지 않는다(지워도 자가테스트가 초록이다).
// 그래도 남기는 이유는 이 스캐너가 "구조만 읽는다"는 계약을 지켜야 하기 때문이다 — 셸 텍스트를
// 키로 들고 있는 노드 목록 위에 다음 규칙을 얹으면 그 규칙이 조용히 틀린다.
const scan = (text) => {
  const lines = text.split(/\r?\n/)
  const nodes = []
  let blockIndent = null
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i]
    if (raw.trim() === '') continue
    const indent = raw.length - raw.replace(/^ */, '').length
    if (blockIndent !== null && indent > blockIndent) continue
    blockIndent = null
    const node = keyNode(raw, indent, i + 1)
    if (!node) continue
    if (BLOCK_SCALAR.test(node.value)) blockIndent = indent
    nodes.push(node)
  }
  return { lines, nodes }
}

// `permissions:` 아래 한 단계 깊은 키들(`contents: read` 등)이 권한 스코프다.
const scopesOf = (inner, perms, childIndent) => {
  const rest = inner.slice(inner.indexOf(perms) + 1)
  const end = rest.findIndex((x) => x.indent <= childIndent)
  return (end < 0 ? rest : rest.slice(0, end)).filter((x) => x.indent > childIndent)
}

const readJob = (jobNode, inner) => {
  const childIndent = Math.min(...inner.map((x) => x.indent))
  const perms = inner.find((x) => x.indent === childIndent && x.key === 'permissions') ?? null
  return {
    name: jobNode.key,
    node: jobNode,
    perms,
    scopes: perms ? scopesOf(inner, perms, childIndent) : [],
    ifNode: inner.find((x) => x.indent === childIndent && x.key === 'if') ?? null,
    // 잡 레벨 키(`uses`·`container`·`services` …) — 규칙 12 가 쓴다.
    keys: inner.filter((x) => x.indent === childIndent),
  }
}

// `on:` 의 트리거 이름들(규칙 11 의 범위). 블록 매핑(이 저장소의 표기)·스칼라·플로우 시퀀스·
// 블록 시퀀스를 읽는다. 플로우 매핑(`on: {push: …}`)은 키를 확실히 못 뽑으므로 fail-closed 다 —
// 트리거를 잘못 읽으면 PR 에서 도는 잡이 범위 밖으로 빠진다.
const triggersOf = (file, lines, nodes, fatal) => {
  const i = nodes.findIndex((x) => x.indent === 0 && x.key === 'on')
  if (i < 0) {
    fatal.push(`${file}: 최상위 \`on:\` 을 찾지 못했다 — 트리거를 모르면 규칙 11 의 범위를 정할 수 없다(fail-closed)`)
    return []
  }
  const on = nodes[i]
  const v = on.value.trim()
  if (v.startsWith('{')) {
    fatal.push(`${file}:${on.n} \`on:\` 이 플로우 매핑이라 트리거를 읽을 수 없다(fail-closed) — 블록 표기로 적을 것`)
    return []
  }
  // ⚠️ 여러 줄로 이어진 플로우 시퀀스(`on: [push,` …)와 앵커·별칭(`on: &t`)은 이 줄만으로 트리거를 알 수 없다 —
  // 빈 목록이나 `&t` 하나로 읽으면 PR 트리거가 조용히 빠진다(Grok 적대 레그).
  if ((v.startsWith('[') && !v.endsWith(']')) || /^[&*]/.test(v)) {
    fatal.push(`${file}:${on.n} \`on:\` 의 트리거를 읽을 수 없다(여러 줄 플로우 시퀀스·앵커 — fail-closed) — 블록 표기로 적을 것`)
    return []
  }
  if (v.startsWith('['))
    return v
      .replace(/^\[|\]$/g, '')
      .split(',')
      .map((s) => unquote(s.trim()))
      .filter(Boolean)
  if (v !== '') return [v]
  const after = nodes.slice(i + 1)
  const stop = after.findIndex((x) => x.indent === 0)
  const kids = stop < 0 ? after : after.slice(0, stop)
  if (kids.length > 0) {
    const ind = Math.min(...kids.map((x) => x.indent))
    return kids.filter((x) => x.indent === ind).map((x) => x.key)
  }
  // 블록 시퀀스(`on:` 아래 `- push`)는 키 노드를 만들지 않으므로 원문 줄에서 읽는다.
  const seq = []
  for (let k = on.n; k < lines.length; k++) {
    const body = splitComment(lines[k]).body
    if (body.trim() === '') continue
    const m = /^\s+-\s+([A-Za-z_]+)\s*$/.exec(body)
    if (!m) break
    seq.push(m[1])
  }
  if (seq.length === 0) fatal.push(`${file}:${on.n} \`on:\` 아래에서 트리거를 하나도 읽지 못했다(fail-closed)`)
  return seq
}

// 잡 목록과 각 잡의 `permissions:` 선언 위치를 뽑는다.
const parseWorkflow = (file, text) => {
  const { lines, nodes } = scan(text)
  const wf = { file, lines, workflowPerms: null, jobs: [], fatal: [], triggers: [], jobsLine: null, jobsEndLine: null }

  // 머지 키(`<<: *anchor`)가 있으면 잡의 실제 키 집합을 이 스캐너로 알 수 없다.
  // 판단 불가는 통과가 아니라 실패다.
  if (MERGE_KEY.test(text))
    wf.fatal.push(`${file}: YAML 머지 키(<<:)가 있어 잡의 권한 선언 여부를 판단할 수 없다(fail-closed)`)

  // ⚠️ 이 스캐너는 들여쓰기와 키만 읽는다 — 플로우 매핑 `permissions: {contents: write}` 는
  // 자식 노드를 만들지 않으므로 **스코프가 통째로 보이지 않는다.** 실측(A/B, 실 워크플로 복사본):
  // 근거 주석 없는 `{contents: write, id-token: write}` 를 넣었더니 인벤토리의
  // 「릴리스 잡의 write 상승」이 6 → 5 로 **줄어들고** 가드는 그대로 통과했다. 즉 규칙 5 가
  // 보지 못하는 표기가 하나 있었고, 이 파일의 헤더는 이미 「해석하지 못하는 모양은 통과가
  // 아니라 오류」라고 적고 있었는데 코드가 그 약속을 지키지 않았다.
  //
  // `{}` 는 예외다 — 빈 매핑은 「권한 없음」이라 해석할 스코프가 없고, 실제로 네 릴리스
  // 워크플로가 그 표기를 쓴다(dotnet/go/php-release · release). 여기서 막으면 즉시 전면 RED 다.
  for (const n of nodes) {
    if (n.key !== 'permissions') continue
    const v = (n.value ?? '').trim()
    if (v.startsWith('{') && v.replace(/\s/g, '') !== '{}')
      wf.fatal.push(
        `${file}:${n.n} \`permissions:\` 가 플로우 매핑으로 적혀 있어 스코프를 읽을 수 없다(fail-closed) — 블록 표기로 적을 것`,
      )
  }

  wf.triggers = triggersOf(file, lines, nodes, wf.fatal)
  wf.workflowPerms = nodes.find((x) => x.indent === 0 && x.key === 'permissions') ?? null
  const jobsIdx = nodes.findIndex((x) => x.indent === 0 && x.key === 'jobs')
  if (jobsIdx < 0) {
    wf.fatal.push(`${file}: 최상위 \`jobs:\`를 찾지 못했다 — 워크플로로 해석할 수 없다(fail-closed)`)
    return wf
  }
  wf.jobsLine = nodes[jobsIdx].n
  // jobs 하위 = 다음 최상위 키 전까지.
  const after = nodes.slice(jobsIdx + 1)
  const stop = after.findIndex((x) => x.indent === 0)
  const body = stop < 0 ? after : after.slice(0, stop)
  // `jobs:` 뒤에도 최상위 키(`env:` 등)가 올 수 있다 — 그 시작 줄(없으면 파일 끝 다음 줄). 규칙 11 이 쓴다.
  wf.jobsEndLine = stop < 0 ? lines.length + 1 : after[stop].n
  if (body.length === 0) {
    wf.fatal.push(`${file}: \`jobs:\` 하위에서 잡을 하나도 읽지 못했다(플로우 스타일이거나 비어 있다 — fail-closed)`)
    return wf
  }
  const jobIndent = Math.min(...body.map((x) => x.indent))
  for (const [i, jobNode] of body.entries()) {
    if (jobNode.indent !== jobIndent) continue
    const next = body.findIndex((x, k) => k > i && x.indent === jobIndent)
    const inner = body.slice(i + 1, next < 0 ? body.length : next)
    if (inner.length === 0) {
      wf.fatal.push(`${file}: 잡 \`${jobNode.key}\`의 본문을 읽지 못했다(플로우 스타일 — fail-closed)`)
      continue
    }
    wf.jobs.push(readJob(jobNode, inner))
  }
  return wf
}

// ── 규칙 ────────────────────────────────────────────────────────────────────

// 규칙 1(릴리스 전용): 모든 잡이 `permissions:`를 직접 선언한다.
// 릴리스 워크플로에는 워크플로 레벨 기본값이 없으므로(규칙 2), 빠뜨린 잡은 워크플로가 아니라
// **저장소 기본 권한**을 물려받는다 — 이 파일 바깥에서 바뀌는 값이다.
const ruleJobLevelDeclared = (wf, out) => {
  for (const job of wf.jobs)
    if (!job.perms)
      out.push(
        `${wf.file}:${job.node.n} 잡 \`${job.name}\`에 \`permissions:\`가 없다 — 릴리스 워크플로에는 워크플로 레벨 기본값이 없어서 이 잡은 **저장소 기본 권한**(Settings → Actions, 이 저장소 바깥에서 바뀜)을 물려받는다`,
      )
}

// 규칙 1b(저장소 전체): `contents: write` 를 가진 잡의 checkout 은 자격증명을 워크스페이스에
// 남기지 않는다(`persist-credentials: false`).
//
// ⚠️ **이것은 「전 워크플로에 강제한다」가 아니다.** 그 제안은 기각돼 있다(기각 레지스트리 —
// 24개 중 10개에만 있고 그 비대칭의 근거가 저장소 어디에도 없어서, 가드가 정책을 새로 만드는
// 셈이 되기 때문). 그 기각이 적어 둔 **되살릴 신호**는 「`persist-credentials` 를 가진 목록과
// `contents: write` 를 가진 잡 목록이 갈릴 때」이고, 2026-09-11 실측에서 그것이 참이 됐다:
// `contents: write` 를 가진 릴리스 잡 넷 중 `go-release.yml` 의 `release` 하나만 빠져 있었다.
//
// 그래서 규칙의 범위를 **기각이 지목한 그 조인**으로 좁힌다 — 쓰기 토큰을 쥔 잡만. 읽기 전용
// 잡은 이 규칙의 대상이 아니다(그것까지 걸면 기각된 제안을 되살리는 것이다).
//
// ⚠️ 발견 기반이라 조준점이 사라지면 조용히 0건을 검사한다 — 아래 호출부가 검사한 잡 수를
// 세어 `--min-write-checkout` 하한과 대조한다.
// ⚠️ **2026-09-23: 범위를 `contents: write` → 「GITHUB_TOKEN 으로 행사되는 쓰기 스코프」로 넓혔다.**
// 기각이 막은 것은 「전 워크플로에 강제」(읽기 전용 잡까지)였지 **쓰기 토큰의 정의**가 아니었다.
// 새 신호가 왔다 — `release.yml` 의 `release` 잡이 `contents: read` 인 채로 `attestations: write`
// 를 얻었고(출처 증명), 그 잡은 **두 파일의 체크아웃 다섯 중 유일하게** `persist-credentials: false`
// 가 없었다. 좁은 규칙은 그것을 **구조적으로 못 본다**(실측: 그 줄을 지워도 이 가드는 초록이었다).
// 근거는 스코프 **이름**이 아니라 「남은 토큰이 그 권한을 행사할 수 있는가」다 — 워크스페이스에
// 남은 GITHUB_TOKEN 은 그 잡의 모든 API 스코프를 이후 스텝(서드파티 Maven 플러그인 포함)에
// 넘긴다. `attestations: write` 면 증명을 발행할 수 있다.
//
// ⚠️ **`id-token` 은 제외한다 — 실측으로 갈렸다.** 처음엔 「쓰기면 전부」로 넓혔더니
// `node-release.yml`·`python-release.yml` 의 `release` 잡 둘이 걸렸는데, 그 둘은
// `contents: read` + `id-token: write`(npm·PyPI Trusted Publishing)다. OIDC 토큰은 git 자격증명이
// 아니라 `ACTIONS_ID_TOKEN_REQUEST_*` 환경변수로 받는다 — 남은 git 토큰은 그 능력을 주지 않는다.
// 그 둘을 걸면 **거짓 양성**이고, 거짓 양성은 규칙을 꺼지게 만든다.
const NON_TOKEN_SCOPES = new Set(['id-token'])
const ruleWriteJobDropsCheckoutCreds = (wf, out) => {
  let seen = 0
  for (const [i, job] of wf.jobs.entries()) {
    const writes = job.scopes.filter(
      (s) => !NON_TOKEN_SCOPES.has(s.key) && (s.value ?? '').trim().replace(/#.*$/, '').trim() === 'write',
    )
    if (writes.length === 0) continue
    const start = job.node.n
    const end = wf.jobs[i + 1]?.node.n ?? wf.lines.length + 1
    // ⚠️ **주석을 걷고 본다 — 안 걷으면 주석이 설정 행세를 한다.** 실측으로 걸렸다(2026-09-23):
    // 이 규칙을 넓히면서 `release.yml` 에 「`persist-credentials: false` 가 이 잡에만 빠져 있었다」는
    // 경위 주석을 달았는데, 그 **글자 때문에** 실제 설정 줄을 지워도 규칙이 침묵했다.
    // 즉 이 가드를 무력화하는 데 필요한 것이 설정 변경이 아니라 **주석 한 줄**이었다.
    const body = wf.lines
      .slice(start, end - 1)
      .map((l) => l.replace(/#.*$/, ''))
      .join('\n')
    if (!/uses: *actions\/checkout@/.test(body)) continue // 체크아웃이 없으면 남길 자격증명도 없다
    seen += 1
    if (!/persist-credentials: *false/.test(body))
      out.push(
        `${wf.file}:${start} 잡 \`${job.name}\` 은 \`${writes.map((s) => `${s.key}: write`).join('`·`')}\` 를 쥐고 체크아웃하면서 \`persist-credentials: false\` 가 없다 — 그 토큰이 워크스페이스의 git 설정에 남아 이후 스텝(빌드·테스트·서드파티 액션)이 그 권한을 그대로 쓸 수 있다. 형제 릴리스 워크플로들은 이미 이 줄을 갖고 있다`,
      )
  }
  return seen
}

// 규칙 2(릴리스 전용): 워크플로 레벨 `permissions:` 블록 금지.
// 워크플로 레벨 기본값은 그 스코프를 **쓰지 않는 잡까지** 토큰에 쥐여준다(SonarQube
// githubactions:S7637). 릴리스 워크플로는 잡마다 필요 권한이 다르다 — 체크아웃조차 없는
// `version` 잡(`permissions: {}`)과 `contents: write`가 필요한 발행 잡이 한 파일에 있다.
const ruleNoWorkflowLevelBlock = (wf, out) => {
  if (!wf.workflowPerms) return
  out.push(
    `${wf.file}:${wf.workflowPerms.n} 워크플로 레벨 \`permissions:\` 블록이 있다 — 릴리스 워크플로는 잡마다 필요 권한이 달라서(체크아웃 없는 version 잡 vs 발행 잡) 기본값을 두면 쓰지도 않는 스코프가 잡에 새어 들어간다(S7637). 잡 레벨로 내릴 것`,
  )
}

// 규칙 3(저장소 전체): 어떤 잡도 저장소 기본 권한을 물려받지 않는다.
// 규칙 1의 일반형이자 이 가드에서 유일하게 저장소 전체에 걸리는 규칙이다. "잡 레벨로 적어라"
// 대신 "토큰 스코프가 저장소 안에 적혀 있어라"로 말하기 때문에 예외가 필요 없다 —
// `*-ci.yml`·`install-smoke.yml`처럼 워크플로 레벨 한 줄로 끝내는 동질 워크플로도 만족한다.
// 새 워크플로를 권한 선언 없이 추가하는 것이 이 규칙이 잡는 실제 사고다.
const ruleNoRepoDefaultInheritance = (wf, out) => {
  if (wf.workflowPerms) return
  const bare = wf.jobs.filter((j) => !j.perms).map((j) => j.name)
  if (bare.length === 0) return
  out.push(
    `${wf.file}: 워크플로 레벨 \`permissions:\`도 없고 잡 \`${bare.join('`·`')}\`도 선언이 없다 — 이 잡들의 토큰은 저장소 기본 권한(이 저장소 바깥에서 바뀌는 값)을 물려받는다`,
  )
}

// 규칙 4(저장소 전체): 일괄 부여(`write-all`/`read-all`) 금지.
// 스코프별로 적으라는 것 외에 판단이 필요 없는 규칙이다. 오탐 여지가 없다.
const ruleNoBlanketGrant = (wf, out) => {
  const blanket = [wf.workflowPerms, ...wf.jobs.map((j) => j.perms)].filter(
    (p) => p && /^(write-all|read-all)$/.test(p.value),
  )
  for (const p of blanket)
    out.push(`${wf.file}:${p.n} \`permissions: ${p.value}\` — 일괄 부여는 쓰지 않는다. 필요한 스코프만 개별로 적을 것`)
}

// 규칙 5(릴리스 전용): 권한 상승에는 근거 주석이 붙어 있어야 한다.
//
// ⚠️ 이 규칙이 증명하는 것은 **"이유가 적혀 있다"**이지 "그 이유가 참이다"가 아니다. 후자
// ("`contents: write`는 실제로 그 스코프를 쓰는 잡에만 있다")는 기계화하지 않기로 했다 —
// 쓰기를 정당화하는 수단의 집합이 열려 있기 때문이다(`gh release create`·`git push`·
// `gh api -X POST`·서드파티 릴리스 액션·컴포지트 액션·잡이 호출하는 셸 스크립트 내부). 허용
// 목록으로 그걸 흉내내면 새 발행 수단이 등장할 때마다 오탐이 나고, 오탐을 없애려고 패턴을
// 넓히면 결국 무엇이든 매치하는 고무도장이 된다. 그런 가드는 있는 것이 없는 것보다 나쁘다.
//
// 대신 기계화 가능한 잔여물만 취한다: 상승은 **선언 지점에 이유를 남겨야 한다**. `read` →
// `write` 한 단어짜리 조용한 diff가 불가능해지고, 다음 사람이 대조할 근거가 코드에 남는다.
// 근거는 스코프 줄의 꼬리 주석·바로 윗줄 주석·`permissions:` 줄의 꼬리 주석·그 윗줄 주석
// 어디에 있어도 인정한다 — 표기 스타일로 사람과 싸우는 가드는 반드시 우회당한다.
const commentAbove = (lines, n) => {
  for (let k = n - 2; k >= 0; k--) {
    const t = lines[k].trim()
    if (t === '') continue
    return t.startsWith('#') ? t.slice(1).trim() : null
  }
  return null
}
const ruleEscalationDocumented = (wf, out) => {
  let count = 0
  for (const job of wf.jobs)
    for (const s of job.scopes) {
      if (s.value !== 'write') continue
      count++
      const documented = [
        s.comment,
        commentAbove(wf.lines, s.n),
        job.perms.comment,
        commentAbove(wf.lines, job.perms.n),
      ].some((c) => c && c.length > 0)
      if (!documented)
        out.push(
          `${wf.file}:${s.n} \`${s.key}: write\` (잡 \`${job.name}\`)에 근거 주석이 없다 — 권한 상승은 선언 지점에 이유를 남길 것(예: \`contents: write # \\\`gh release create\\\`\`)`,
        )
    }
  return count
}

// 잡이 차지하는 원본 줄 범위. 노드는 1-based `n`을 들고 있으므로 다음 잡의 시작 전까지가 이 잡이다.
// 마지막 잡은 파일 끝까지. `run:` 본문을 **텍스트로** 훑어야 하는 규칙(아래 6·7)이 쓴다 —
// 이 스캐너의 계약은 "구조만 키로 읽는다"이고, 여기서는 키로 읽는 게 아니라 범위 안의 원문을
// 찾는 것이라 계약을 깨지 않는다.
const jobLines = (wf, job) => {
  const starts = wf.jobs.map((j) => j.node.n).sort((a, b) => a - b)
  const next = starts.find((n) => n > job.node.n)
  return wf.lines.slice(job.node.n - 1, next ? next - 1 : wf.lines.length)
}

// 규칙 6: `govulncheck`를 도는 잡의 `setup-go`에는 `check-latest: true`가 있어야 한다.
//
// 없으면 setup-go가 러너 툴캐시의 **낡은 패치**를 그대로 쓴다. 표준 라이브러리 취약점은 패치
// 릴리스로 고쳐지므로 감사 잡이 낡은 툴체인을 감사하게 되고, 고쳐진 것을 "못 고쳐졌다"고 보고한다
// (2026-08-17 실측: security-audit가 go1.26.5로 stdlib 5건, 같은 커밋을 1.26.6으로 재검사하면
// `No vulnerabilities found.`). 이 불변식은 go-ci.yml 주석이 이미 선언했는데 **주석은 두 파일 중
// 한쪽에만 지켜졌다** — 그래서 기계로 옮긴다.
//
// ⚠️ **빌드/테스트 잡에는 요구하지 않는다.** 그쪽은 소비자 하한을 재현하는 것이 목적이라 캐시를
// 그대로 쓰는 것이 옳다. 조준점을 "govulncheck를 도는 잡"으로 좁게 유지할 것.
// ⚠️ 탐지는 원문 범위 검색(fail-closed)이고 요구는 `check-latest: true` 문자열이다 — 블록 스칼라
// 안에 govulncheck를 숨겨도 탐지되지만, 플래그를 다른 방식으로 준 경우는 잡지 못한다.
const ruleGovulncheckChecksLatest = (wf, out) => {
  for (const job of wf.jobs) {
    // ⚠️ **주석은 걷어내고 본다.** go-ci.yml은 `vulncheck` 잡 바로 앞(= `build` 잡의 줄 범위 안)에
    // govulncheck를 설명하는 주석을 두고 있어, 원문 그대로 찾으면 `build`가 오탐으로 걸린다(실측).
    const body = jobLines(wf, job).map((l) => splitComment(l).body)
    if (!body.some((l) => l.includes('govulncheck'))) continue
    if (!body.some((l) => /^\s*check-latest:\s*true\s*(#.*)?$/.test(l)))
      out.push(
        `${wf.file}: 잡 \`${job.name}\`이 govulncheck를 도는데 setup-go에 \`check-latest: true\`가 없다 — 러너 툴캐시의 낡은 툴체인을 감사하게 된다`,
      )
  }
}

// 규칙 7: `govulncheck@<버전>` 핀은 워크플로 사이에서 같아야 한다.
//
// 같은 두 파일이 지고 있는 **두 번째** 주석뿐인 동기화 약속이다(security-audit.yml의
// "⚠️ go-ci.yml의 버전과 함께 올린다"). 첫 번째(규칙 6)가 이미 한쪽만 고쳐진 채 굳었으므로
// 이쪽도 주석에 맡기지 않는다.
const GOVULN_PIN = /govulncheck@(v[\w.\-+]+)/g
const ruleGovulncheckPinAligned = (wfs, out) => {
  const seen = new Map()
  for (const wf of wfs)
    for (const raw of wf.lines)
      // 주석에 적힌 버전은 핀이 아니다(규칙 6과 같은 이유로 주석을 걷어낸다).
      for (const m of splitComment(raw).body.matchAll(GOVULN_PIN)) {
        if (!seen.has(m[1])) seen.set(m[1], new Set())
        seen.get(m[1]).add(wf.file)
      }
  if (seen.size > 1)
    out.push(
      `govulncheck 버전 핀이 워크플로마다 다르다: ${[...seen].map(([v, fs]) => `${v}(${[...fs].join(',')})`).join(' vs ')} — 한쪽만 올리지 말 것`,
    )
}

// 규칙 8: 배포 시크릿을 env로 받는 잡은 그 env마다 **실행되는** 빈값 검사를 가져야 한다.
//
// 「미설정은 스킵이 아니라 실패다」는 이 저장소가 이미 규칙으로 갖고 있는 문장인데(`ci.md`),
// 아홉 레인 중 rust 하나가 빠져 있었다(2026-08-31 실측: java·kotlin·dotnet·php·dispatch 는
// 있고 rust 만 없음). 아무것도 게시하지 않은 실행이 green 으로 끝나면 성공한 실행과 구분되지 않는다.
//
// ⚠️ **주석을 가드로 세지 않는다.** rust-release.yml:5 는 「CARGO_REGISTRY_TOKEN 시크릿 미설정
// 시 …」라는 주석을 **갖고 있으면서** 가드가 없었다. `미설정` 문자열을 찾는 규칙이었다면 그
// 구멍을 그대로 통과시켰을 것이다.
// ⚠️ **시크릿 이름이 아니라 env 이름으로 건다.** 셋이 이름을 바꿔 받는다 — dispatch 는
// `APP_ID: ${{ secrets.RELEASE_APP_ID }}`, kotlin 은 `ORG_GRADLE_PROJECT_signingInMemoryKey`.
// 검사되는 것은 셸이 실제로 보는 변수이므로 조준점도 그쪽이어야 한다.
// ⚠️ 모양은 둘 다 허용한다 — 단일은 `[ -z "$X" ]`, 복수는 `[ -n "$X" ] || missing=…` 누적형이다.
// ⚠️ `GITHUB_TOKEN` 은 러너가 항상 주입하므로 제외한다(dotnet·php 의 `GH_TOKEN`).
// ⚠️ **검사가 있다는 것과 그것이 배포를 멈춘다는 것은 다르다.** 예전 이 규칙은 빈값 검사의
// **존재**만 봤고, 그 배선을 쫓으면 두 모양에서 수렴하지 않는다고 적혀 있었다. 실측(2026-09-10)
// 결과 **수렴한다** — 빈값 검사를 담은 `run:` 블록 **28개 전부**가 같은 블록 안에 `exit 1` 을
// 갖는다(오탐 0). 그래서 판정을 그 블록으로 좁힌다.
//
// 그 전에는 `exit 1` 한 줄만 지우면 시크릿 미설정이 **경고로 끝나고 잡이 초록**이었다
// (변이 프로브 `SILENT`) — 태그는 남고 레지스트리는 비는, `ci.md` 가 이미 이름 붙인 그 실패다.
//
// ⚠️ `exit 1` 은 **같은 줄 인라인 형태**도 세야 한다(`[ -n "$X" ] || { echo …; exit 1; }`).
// 줄 단독으로만 세면 정당한 두 자리를 거짓 양성으로 잡는다(실측으로 겪었다).
const ENV_SECRET_BINDING = /^\s*([A-Za-z_][A-Za-z0-9_]*):\s*\$\{\{\s*secrets\.([A-Z_][A-Z0-9_]*)\s*\}\}/
const EXITS_NONZERO = /(^|\s|;|&&|\|\|)exit\s+1(\s|;|\}|$)/
// 그 줄을 품은 `run: |` 블록(들여쓰기가 더 깊은 연속 줄)을 돌려준다.
const runBlockAround = (lines, idx) => {
  for (let i = idx; i >= 0; i--) {
    const m = /^(\s*)(?:- )?run:\s*\|/.exec(lines[i])
    if (!m) continue
    const indent = m[1].length
    let j = i + 1
    while (j < lines.length && (lines[j].trim() === '' || lines[j].search(/\S/) > indent)) j++
    return j > idx ? lines.slice(i + 1, j) : null
  }
  return null
}
const ruleSecretPreflight = (wf, out) => {
  for (const job of wf.jobs) {
    const body = jobLines(wf, job).map((l) => splitComment(l).body)
    const bound = new Map()
    for (const l of body) {
      const m = ENV_SECRET_BINDING.exec(l)
      if (m && m[2] !== 'GITHUB_TOKEN') bound.set(m[1], m[2])
    }
    for (const [env, secret] of bound) {
      const test = new RegExp(`\\[\\s+-[zn]\\s+"\\$${env}"\\s+\\]`)
      const at = body.findIndex((l) => test.test(l))
      if (at < 0) {
        out.push(
          `${wf.file}: 잡 \`${job.name}\`이 배포 시크릿 \`${secret}\`을(를) \`$${env}\`로 받는데 미설정 빈값 검사가 없다 — 아무것도 게시하지 않은 실행이 green 으로 끝난다`,
        )
        continue
      }
      const block = runBlockAround(body, at)
      if (!block || !block.some((l) => EXITS_NONZERO.test(l)))
        out.push(
          `${wf.file}: 잡 \`${job.name}\`의 \`${secret}\` 빈값 검사가 **배포를 멈추지 않는다** — 그 \`run:\` 블록에 \`exit 1\` 이 없다. 검사만 있고 판정이 없으면 미설정이 경고로 끝나고 잡은 초록이다`,
        )
    }
  }
}

// 규칙 9: 게시 잡은 통합 E2E 와 install-smoke 를 통과한 뒤에만 돈다.
//
// `CLAUDE.md` 가 릴리스 불변식으로 선언하는데 **`needs:` 를 읽는 자리가 없었다**(실측 2026-09-02:
// rust-release 의 publish 를 `needs: [version]` 으로 강등해도 check-ci-permissions·
// test-release-prerelease·test-dispatch-release 가 전부 초록이었다).
//
// ⚠️ **게시 「명령」으로 잡을 찾지 않는다** — 초안이 그랬고 두 자리를 놓쳤다: python 은 CLI 가
// 아니라 `uses: pypa/gh-action-pypi-publish` 로 게시하고, go 는 `gh release create` 가 곧 게시다
// (태그가 레지스트리다). 게다가 `dispatch-release.yml` 의 `cut-tag` 가 `git push … refs/tags` 를
// 하므로 **오탐**한다 — 그 파일은 태그만 만들고 게시하지 않는다.
//
// 그래서 조준점은 **잡 키**다. 실측: 아홉이 `release`(6) · `publish`(2, kotlin·rust) ·
// `split`(1, php) 셋 중 하나이고 `cut-tag` 는 그 집합 밖이다.
// ⚠️ `verify` 는 요구하지 않는다 — java·dotnet·rust·ruby 넷이 그 잡을 갖지 않는다(실측).
const PUBLISH_JOB_KEYS = new Set(['release', 'publish', 'split'])
const NEEDS_REQUIRED = ['integration', 'install-smoke']
const rulePublishGated = (wf, out) => {
  if (/dispatch-release\.ya?ml$/.test(wf.file)) return 0
  let seen = 0
  for (const job of wf.jobs) {
    if (!PUBLISH_JOB_KEYS.has(job.node.key)) continue
    seen++
    const line = jobLines(wf, job)
      .map((l) => splitComment(l).body)
      .find((l) => /^\s*needs:/.test(l))
    if (!line) {
      out.push(`${wf.file}: 게시 잡 \`${job.node.key}\`에 \`needs:\`가 없다 — 발행 전 게이트를 건너뛴다`)
      continue
    }
    // 플로우 시퀀스(`needs: [a, b]`)와 스칼라(`needs: a`)만 읽는다. 블록 시퀀스는 fail-closed.
    const m = /^\s*needs:\s*\[([^\]]*)\]/.exec(line)
    const got = m ? m[1].split(',').map((s) => s.trim()) : [line.replace(/^\s*needs:\s*/, '').trim()]
    for (const req of NEEDS_REQUIRED)
      if (!got.includes(req))
        out.push(
          `${wf.file}: 게시 잡 \`${job.node.key}\`의 \`needs:\`에 \`${req}\`가 없다 — 발행 전 E2E 게이트가 끊겼다(현재: ${got.join(', ') || '(빈 값)'})`,
        )
  }
  return seen
}

// 규칙 10: 비로컬 액션은 40자 SHA 로 핀한다.
//
// 현재 트리는 완전한데 **그것을 지키는 것이 없었다**(실측: `actions/checkout@v7` 로 강등해도 통과).
// 이 저장소는 **ref 이름이 곧 의미**인 액션을 셋 쓴다 — `dtolnay/rust-toolchain`(stable/master 가
// 서로 다른 `action.yml` 계약) · `pypa/gh-action-pypi-publish`(기본 브랜치가 `unstable/v1` 이라
// 핀이 풀리면 **PyPI 게시가 조용히 unstable 채널로 간다**). `.claude/rules/ci.md` 가 dependabot 을
// 막는 이유도 그것이다.
const USES_REF = /^\s*-?\s*uses:\s*([^\s#]+)/
const ruleActionsPinnedToSha = (wf, out) => {
  let seen = 0
  for (const raw of wf.lines) {
    const m = USES_REF.exec(splitComment(raw).body)
    if (!m) continue
    const ref = m[1]
    if (ref.startsWith('./')) continue // 로컬 재사용 워크플로 — 핀 대상이 아니다
    seen++
    if (!/@[0-9a-f]{40}$/.test(ref))
      out.push(`${wf.file}: \`${ref}\` 가 40자 SHA 로 핀되지 않았다 — ref 이름이 곧 의미인 액션이 셋 있다`)
  }
  return seen
}

// 규칙 11(저장소 전체): PR 에서 Actions 시크릿을 쥐는 잡은 **Dependabot 이 연 PR** 에서 돌지 않는다 —
// 누가 그 실행을 트리거했든.
//
// Dependabot 이 트리거한 실행에는 Actions 시크릿이 없다(그래서 건너뛴다). 그런데 사람이 그 PR 에
// 커밋을 얹거나 Update branch 를 누르면 actor 가 사람이 되어 시크릿이 보이고, 방금 bump 된 **미검토**
// 패키지의 설치·빌드가 시크릿과 같은 잡에서 돈다 — 토큰을 Dependabot 시크릿 저장소에 복제하는 안을
// 기각한 바로 그 이유다(`sonarcloud.yml` 주석). 실측: actor 로만 거르던 sonarcloud 가 2026-10-08~21
// 일곱 번 그렇게 돌았다(actor·triggering_actor 모두 사람). 그래서 기준은 actor 가 아니라 **PR 작성자**
// 다 — 작성자는 커밋이 얹혀도, 다시 돌려도 바뀌지 않는다.
//
// ⚠️ 판정은 글자가 아니라 **값**이다 — 잡의 `if:` 를 아래 시나리오마다 평가한다. 「작성자 검사가
// 있는가」를 문자열로 보면 `&&` 를 `||` 로 쓴 식, 괄호를 빠뜨린 식이 통과한다(글자로는 검사가 있다).
// 같은 식이 push 실행을 건너뛰지 않는지도 본다 — main 스캔은 건너뛸 수 없다(PR0 fail-closed).
// ⚠️ 이 규칙이 못 보는 것: 사람이 연 PR 에 Dependabot 의 bump 커밋을 옮겨 담은 경우(작성자가
// 사람이다). 그 몫은 규칙 12 다 — 거르는 대신 시크릿 잡에 패키지 코드를 두지 않는다.
//
// 평가기는 GitHub Actions 식의 부분집합이다. 의미는 GitHub 의 것을 따른다 — 문자열 비교는 대소문자를
// 가리지 않고, 타입이 다르면 숫자로 바꿔 비교하며(null → 0 · 문자열 → Number), `&&`·`||` 는 피연산자
// 값을 돌려준다. ⚠️ **모르는 문법·함수·문맥은 통과가 아니라 오류다** — 모르는 것을 null 로 두고
// 계산하면 그 null 이 판정을 정한다. 같은 이유로 양변을 늘 다 평가한다(단락 평가가 가린 쪽의
// 모르는 것도 드러난다).
const exprStr = (v) => (v === null ? '' : String(v))
const EXPR_FUNCS = {
  startswith: (a, b) => exprStr(a).toLowerCase().startsWith(exprStr(b).toLowerCase()),
  endswith: (a, b) => exprStr(a).toLowerCase().endsWith(exprStr(b).toLowerCase()),
  contains: (a, b) => exprStr(a).toLowerCase().includes(exprStr(b).toLowerCase()),
  // 잡 레벨 상태 함수 — 시나리오는 「앞선 잡이 전부 성공했다」다.
  success: () => true,
  always: () => true,
  failure: () => false,
  cancelled: () => false,
}
const exprTruthy = (v) => !(v === false || v === null || v === '' || v === 0 || Number.isNaN(v))
const exprNum = (v) => {
  if (v === null) return 0
  if (typeof v === 'boolean') return Number(v)
  if (typeof v === 'number') return v
  return v.trim() === '' ? 0 : Number(v)
}
const exprEq = (a, b) => {
  if (typeof a === 'string' && typeof b === 'string') return a.toLowerCase() === b.toLowerCase()
  if (a !== null && b !== null && typeof a === typeof b) return a === b
  if (a === null && b === null) return true
  return exprNum(a) === exprNum(b)
}
const evalExpr = (src, ctx) => {
  const toks = []
  for (let i = 0; i < src.length; ) {
    const rest = src.slice(i)
    const m =
      /^\s+/.exec(rest) ??
      /^(?<op>\|\||&&|==|!=|<=|>=|[()!<>,])/.exec(rest) ??
      /^'(?<str>(?:[^']|'')*)'/.exec(rest) ??
      /^(?<num>\d+(?:\.\d+)?)/.exec(rest) ??
      /^(?<id>[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)*)/.exec(rest)
    if (!m) throw new Error(`읽지 못하는 글자 \`${rest[0]}\``)
    const g = m.groups ?? {}
    if (g.op !== undefined) toks.push({ op: g.op })
    else if (g.str !== undefined) toks.push({ lit: g.str.replace(/''/g, "'") })
    else if (g.num !== undefined) toks.push({ lit: Number(g.num) })
    else if (g.id !== undefined) toks.push({ id: g.id })
    i += m[0].length
  }
  let p = 0
  const isOp = (o) => toks[p]?.op === o
  const expect = (o) => {
    if (!isOp(o)) throw new Error(`\`${o}\` 가 있어야 할 자리다`)
    p++
  }
  const orE = () => {
    let v = andE()
    while (isOp('||')) {
      p++
      const r = andE()
      v = exprTruthy(v) ? v : r
    }
    return v
  }
  const andE = () => {
    let v = eqE()
    while (isOp('&&')) {
      p++
      const r = eqE()
      v = exprTruthy(v) ? r : v
    }
    return v
  }
  const eqE = () => {
    let v = unE()
    for (;;) {
      if (['<', '<=', '>', '>='].some(isOp)) throw new Error(`비교 연산 \`${toks[p].op}\` 은 이 평가기가 읽지 않는다`)
      if (!isOp('==') && !isOp('!=')) return v
      const o = toks[p++].op
      const r = unE()
      v = o === '==' ? exprEq(v, r) : !exprEq(v, r)
    }
  }
  const unE = () => {
    if (!isOp('!')) return prim()
    p++
    return !exprTruthy(unE())
  }
  const prim = () => {
    const t = toks[p++]
    if (!t) throw new Error('식이 중간에 끝났다')
    if (t.op === '(') {
      const v = orE()
      expect(')')
      return v
    }
    if ('lit' in t) return t.lit
    if (t.id === undefined) throw new Error(`\`${t.op}\` 가 올 자리가 아니다`)
    const name = t.id.toLowerCase()
    if (name === 'true') return true
    if (name === 'false') return false
    if (name === 'null') return null
    if (isOp('(')) {
      p++
      const args = []
      if (!isOp(')')) {
        args.push(orE())
        while (isOp(',')) {
          p++
          args.push(orE())
        }
      }
      expect(')')
      if (!Object.hasOwn(EXPR_FUNCS, name)) throw new Error(`모르는 함수 \`${t.id}()\``)
      return EXPR_FUNCS[name](...args)
    }
    if (!Object.hasOwn(ctx, name))
      throw new Error(`시나리오에 없는 문맥 \`${t.id}\` — 판정이 그 값에 달렸다면 이 규칙의 시나리오에 넣을 것`)
    return ctx[name]
  }
  const v = orE()
  if (p < toks.length) throw new Error('식 뒤에 읽지 못한 토큰이 남았다')
  return v
}

// YAML 스칼라를 값으로. ⚠️ 위 `unquote` 를 쓰면 안 된다 — 그것은 앞뒤 따옴표를 **따로** 벗겨
// `… != 'dependabot[bot]'` 의 마지막 따옴표를 먹는다.
const yamlScalar = (v) => {
  if (v.startsWith("'")) {
    if (!/^'(?:[^']|'')*'$/.test(v)) throw new Error('작은따옴표 스칼라가 바르게 닫히지 않았다')
    return v.slice(1, -1).replace(/''/g, "'")
  }
  if (v.startsWith('"')) return JSON.parse(v) // YAML 의 큰따옴표 이스케이프 중 JSON 밖의 것은 오류(fail-closed)
  return v
}
// 잡 레벨 `if:` 의 식. `${{ }}` 로 통째로 감쌌으면 벗기고, 이어지는 줄(키보다 깊이 들여쓴 줄)을 붙인다 —
// 블록 스칼라뿐 아니라 plain·따옴표 스칼라도 여러 줄로 이어질 수 있다(YAML 은 줄바꿈을 공백 하나로 접는다).
// 첫 줄만 읽으면 `… ||` 로 끝나 맞는 식이 거부된다(Grok 적대 레그의 오탐).
// ⚠️ `${{ a }} && b` 처럼 감싼 것과 맨 식이 섞이면 GitHub 은 그 값을 식이 아니라 문자열 템플릿으로
// 다룬다 — 평가기가 식으로 읽으면 그 차이가 가려지므로 오류로 떨어뜨린다.
const ifExpression = (wf, node) => {
  const raw = splitComment(wf.lines[node.n - 1]).body
  let v = raw.slice(raw.indexOf(':') + 1).trim()
  const more = []
  for (let k = node.n; k < wf.lines.length; k++) {
    const l = wf.lines[k]
    if (l.trim() !== '' && l.length - l.trimStart().length <= node.indent) break
    more.push(l)
  }
  if (BLOCK_SCALAR.test(v)) v = more.map((l) => l.trim()).join(' ').trim()
  else {
    const quoted = v.startsWith("'") || v.startsWith('"')
    const tail = more.map((l) => (quoted ? l : splitComment(l).body).trim()).filter(Boolean)
    v = yamlScalar([v, ...tail].join(' ').trim())
  }
  const m = /^\$\{\{([\s\S]*)\}\}$/.exec(v)
  if (m && !m[1].includes('${{')) return m[1]
  if (v.includes('${{'))
    throw new Error('`${{ }}` 로 감싼 부분과 맨 식이 섞여 있다 — GitHub 은 그런 값을 식이 아니라 문자열 템플릿으로 다룬다')
  return v
}

// 잡이 쥐는 Actions 시크릿 — 식(`${{ … }}`) 안의 `secrets.X`·`secrets[…]`, 그리고 `secrets: inherit`(재사용
// 워크플로 호출 — 이름 없이 넘긴다). `GITHUB_TOKEN` 은 모든 잡에 있으므로 세지 않는다(규칙 8 과 같다).
// ⚠️ 식 밖의 글자는 세지 않는다 — `run:` 의 `echo "secrets.X"` 는 시크릿을 쥐지 않는다(Grok 적대 레그의 오탐).
// ⚠️ 그리고 **주석을 걷지 않는다**: GitHub 은 셸을 모르고 `run:` 글 전체에서 식을 치환하므로 run 블록의
// `# echo ${{ secrets.X }}` 도 그 값을 스크립트에 싣는다. 걷으면 쥔 시크릿을 놓친다(걷던 첫 판이 그랬다).
// 대가는 YAML 주석 속 식까지 세는 쪽 — 엄격해지는 방향이다.
const EXPR_SPAN = /\$\{\{([\s\S]*?)\}\}/g
const SECRET_IN_EXPR = /\bsecrets\s*(?:\.\s*([A-Za-z_][A-Za-z0-9_]*)|\[)/g
const SECRETS_INHERIT = /^\s*secrets:\s*inherit\b/
const secretsIn = (lines) => {
  const names = new Set()
  for (const raw of lines) if (SECRETS_INHERIT.test(splitComment(raw).body)) names.add('secrets: inherit')
  for (const span of lines.join('\n').matchAll(EXPR_SPAN))
    for (const m of span[1].matchAll(SECRET_IN_EXPR)) if (m[1] !== 'GITHUB_TOKEN') names.add(m[1] ?? 'secrets[…]')
  return names
}

const DEPENDABOT = 'dependabot[bot]'
const PR_EVENTS = ['pull_request', 'pull_request_target']
// [이름, actor, triggering_actor] — 셋 다 Dependabot 이 **연** PR 이다. 재실행은 actor 가 처음 트리거한 쪽,
// triggering_actor 가 다시 돌린 쪽이다(GitHub 문서 — 재실행은 actor 의 권한으로 돈다).
const DEPENDABOT_CASES = [
  ['Dependabot 이 연 PR 을 Dependabot 이 갱신', 'bot', 'bot'],
  ['Dependabot 이 연 PR 에 사람이 커밋을 얹음(Update branch 포함)', 'human', 'human'],
  ['Dependabot 이 트리거한 실행을 사람이 다시 돌림', 'bot', 'human'],
]
// 자유값(사람 이름 · 기준/머리 브랜치 · PR 번호)은 **두 벌**로 평가한다 — 시나리오의 상수 하나에 맞춘 식
// (`base_ref != 'main'` 처럼 — Dependabot 의 target-branch 는 바꿀 수 있다)이 통과하지 못하게(Grok 적대 레그).
const FREE_VALUES = [
  { human: 'a-maintainer', base: 'main', head: 'dependabot/npm_and_yarn/node/demo-1.2.3', pr: 1 },
  { human: 'Another-Maintainer', base: 'release/1.x', head: 'dependabot/github_actions/demo-4.5.6', pr: 77 },
]
const prScenario = (event, actorKind, triggeringKind, f) => {
  const who = (kind) => (kind === 'bot' ? DEPENDABOT : f.human)
  return {
    'github.event_name': event,
    'github.actor': who(actorKind),
    'github.triggering_actor': who(triggeringKind),
    'github.event.pull_request.user.login': DEPENDABOT,
    'github.head_ref': f.head,
    'github.base_ref': f.base,
    // ⚠️ pull_request 는 PR 병합 ref 에서, pull_request_target 은 **기준 브랜치** ref 에서 돈다 — 둘을 같게 두면
    // `github.ref == 'refs/heads/main'` 이 pull_request_target 에서 거짓으로 보여 통과한다(Grok 적대 레그).
    'github.ref': event === 'pull_request_target' ? `refs/heads/${f.base}` : `refs/pull/${f.pr}/merge`,
  }
}
const pushScenario = (f) => ({
  'github.event_name': 'push',
  'github.actor': f.human,
  'github.triggering_actor': f.human,
  'github.event.pull_request.user.login': null,
  'github.head_ref': '',
  'github.base_ref': '',
  'github.ref': 'refs/heads/main',
})
// PR 에서 Actions 시크릿을 쥐는 잡들 — 규칙 11·12 가 **같은 발견**을 쓴다(한쪽만 새 표기를 배우면 다른 쪽이
// 조용히 빈다).
const prSecretJobsOf = (wf) => {
  const prEvents = wf.triggers.filter((t) => PR_EVENTS.includes(t))
  if (prEvents.length === 0 || wf.jobsLine === null) return { prEvents, jobs: [], outside: [] }
  // 최상위 `env:` 의 시크릿은 모든 잡이 쥔다 — `jobs:` **앞뒤** 어디에 있든(뒤를 안 보면 마지막 잡만 안다).
  const outside = [...wf.lines.slice(0, wf.jobsLine - 1), ...wf.lines.slice(wf.jobsEndLine - 1)]
  const wfSecrets = secretsIn(outside)
  const jobs = []
  for (const job of wf.jobs) {
    const body = jobLines(wf, job).slice(0, Math.max(0, wf.jobsEndLine - job.node.n))
    const secrets = new Set([...wfSecrets, ...secretsIn(body)])
    if (secrets.size > 0) jobs.push({ job, body, secrets })
  }
  return { prEvents, jobs, outside }
}
const ruleDependabotPrSecretSkip = (wf, out) => {
  const { prEvents, jobs } = prSecretJobsOf(wf)
  for (const { job, secrets } of jobs) {
    const at = `${wf.file}:${job.node.n} 잡 \`${job.name}\` 은 PR 에서 \`${[...secrets].join('`·`')}\` 를 쥐는데`
    if (!job.ifNode) {
      out.push(`${at} \`if:\` 가 없다 — Dependabot 이 연 PR 에서도 방금 bump 된 미검토 패키지가 그 시크릿과 같은 잡에서 돈다`)
      continue
    }
    try {
      const expr = ifExpression(wf, job.ifNode)
      for (const event of prEvents)
        for (const [label, actorKind, triggeringKind] of DEPENDABOT_CASES)
          if (FREE_VALUES.some((f) => exprTruthy(evalExpr(expr, prScenario(event, actorKind, triggeringKind, f)))))
            out.push(
              `${at} 「${label}」(${event})에서 돈다 — 미검토 패키지가 시크릿과 같은 잡에서 돈다. 기준은 actor 가 아니라 PR 작성자(\`github.event.pull_request.user.login\`)다`,
            )
      if (wf.triggers.includes('push') && FREE_VALUES.some((f) => !exprTruthy(evalExpr(expr, pushScenario(f)))))
        out.push(
          `${wf.file}:${job.ifNode.n} 잡 \`${job.name}\` 의 \`if:\` 가 push 실행까지 건너뛴다 — Dependabot 건너뛰기가 main 실행으로 새면 안 된다(PR0 fail-closed)`,
        )
    } catch (e) {
      out.push(`${wf.file}:${job.ifNode.n} 잡 \`${job.name}\` 의 \`if:\` 를 평가하지 못했다(fail-closed) — ${e.message}`)
    }
  }
  return jobs.length
}

// 규칙 12(저장소 전체): PR 에서 Actions 시크릿을 쥐는 잡은 저장소·패키지 코드를 돌리지 않는다 — 설치·빌드·테스트는
// 시크릿이 없는 잡이 하고, 시크릿 잡은 그 산출물을 **데이터로만** 받는다.
//
// 규칙 11 은 Dependabot 이 **연** PR 을 건너뛸 뿐이다. 사람이 연 PR 에 bump 커밋을 옮겨 담으면 작성자가 사람이라
// 못 거른다(등록부 `sonarcloud-human-pr-carries-unreviewed-bump`). 그래서 거르는 대신 **같은 잡에 두지 않는다** —
// 별개 잡은 별개 러너(VM)라 앞 잡의 코드가 뒤 잡의 프로세스·디스크에 닿지 못한다. 닿는 통로는 잡 자신의 실행과
// 산출물·캐시·출력이고, 아래가 그것을 막는다.
//   (a) 잡 레벨 `uses:`(재사용 워크플로)·`container:`·`services:` — 안에서 무엇이 도는지 이 가드가 못 본다(fail-closed).
//   (b) 스텝 `uses:` 는 허용 목록뿐이다(체크아웃 · 산출물 받기 · 스캔). 로컬 액션(`./`)·`docker://` 는 저장소 코드다.
//       체크아웃은 하나 · 이 저장소만이다. 스캔 액션의 서명 검증 · 스캐너 출처 · 분석 루트를 바꾸는 입력
//       (`skipSignatureVerification` · `scannerBinaries*` · `projectBaseDir`)과 같은 일을 하는 스캐너 속성
//       (`-Dsonar.projectBaseDir` · `-Dsonar.scanner.*` · `userHome` · `working.directory` · `java.jdkHome` · `host.url`)도
//       막는다 — 검증 안 된 바이너리나 산출물의 설정이 토큰과 돈다(둘째 회차: Grok 적대 레그가 짚었다).
//       ⚠️ 셋업 액션이 빠진 것은 의도다 — 툴체인이 있으면 다음 사람이 빌드 한 줄을 얹고, 캐시를 복원하는 액션은
//       시크릿 없는 잡이 같은 PR 범위에 심은 캐시를 읽는다. 스캔 액션(핀된 SHA)은 Actions 캐시 API 를 쓰지 않는다
//       (dist 에 restoreCache·saveCache·ACTIONS_CACHE_URL 0 건 — 러너 로컬 tool-cache 만, 2026-10-23 실측).
//   (c) `run:` 에 설치·빌드·인터프리터 실행(버전 꼬리 포함 — `python3.12`)과 명령 자리의 파일 실행(`./x` · `. x` ·
//       `"$VAR/x"` · `/x`)이 없다. `shell:`(잡·워크플로 `defaults:` 포함)은 bash·sh 뿐이고, 로더 훅 환경변수
//       (`BASH_ENV`·`NODE_OPTIONS`·`JAVA_TOOL_OPTIONS`·`JAVA_HOME`·`SONAR_USER_HOME`·`LD_PRELOAD` …)와 `$GITHUB_PATH`
//       쓰기가 없다 — 훅 하나면 저장소·산출물의 파일이 셸·스캔 액션(node)·스캐너(JVM) 안에서 돈다. ⚠️ 손 목록이라
//       수렴하지 않는다 — 구조적 막이는 (b)이고, 이것은 「한 줄만 얹은」 회귀를 잡는 그물이다. `run:` 글의 셸 주석은
//       걷지 않는다(엄격한 쪽 — `"#"` 안팎을 셸처럼 가리지 못하면 걷는 쪽이 뒤를 숨긴다).
//       ⚠️ 이 규칙은 **모양**만 본다. 산출물의 **값**(이름에 든 개행 → `$GITHUB_ENV` 주입 같은 것)은
//       `scripts/test/test-sonar-scan-inputs.sh` 가 sonarcloud.yml 의 배치 블록을 떼어내 실제로 돌려 본다.
//   (d) 잡 어디에도 앞 잡의 **출력**(`${{ needs.<잡>.outputs… }}` · `toJSON(needs)`)이 없다 — 그 잡의 코드가 정한
//       글자다(`run:` 이면 스크립트 주입, 스캔 `args:` 면 스캐너 속성 주입). `needs.<잡>.result` 는 상태라 허용한다.
//   (e) `actions/download-artifact` 의 `path:` 가 `${{ runner.temp }}` 아래다 — 워크스페이스에 풀리면 산출물이 설정
//       파일(sonar-project.properties · .git/config)을 덮는다. 받은 뒤 정해진 자리만 옮기는 것은 워크플로 몫이다.
const PR_SECRET_JOB_ACTIONS = new Set(['actions/checkout', 'actions/download-artifact', 'SonarSource/sonarqube-scan-action'])
// 버전 꼬리(`python3.12` · `php8.3` · `pip3`)는 같은 도구다 — 꼬리 없는 이름만 적으면 그 표기가 빠져나간다(Grok 레그).
const RUN_TOOLS =
  'npm|npx|yarn|pnpm|bun|node(?:js)?|deno|pip[0-9.]*|pipx|python[0-9.]*|pytest|poetry|uv|tox|mvn|mvnw|gradle|gradlew|' +
  'java|javac|jshell|groovy|kotlinc?|scala|go|cargo|rustc|rustup|composer|php[0-9.]*|phpunit|bundle|bundler|gem|' +
  'ruby[0-9.]*|rake|rspec|dotnet|msbuild|make|cmake|perl[0-9.]*|lua|tclsh|sh|bash|zsh|source|chmod|curl|wget'
// 앞: 줄머리·공백·셸 구분자·따옴표·`/`(절대경로 실행). 뒤: 끝·공백·구분자·따옴표 — `java/…`·`go/cover.out` 같은
// 경로 조각은 뒤에 `/` 가 와서 걸리지 않는다. 대소문자는 가린다(`Java libraries` 같은 산문이 걸리지 않게).
const RUN_TOOL = new RegExp(String.raw`(?:^|[\s;&|()\x60"'/])(${RUN_TOOLS})(?=$|[\s;&|()\x60"'])`, 'm')
// 명령 자리 — 줄머리 · 셸 구분자 · `$(` · 백틱 · 명령을 앞에 받는 낱말(then · do · exec · xargs …) 뒤.
const CMD_POS = String.raw`(?:^|[;&|(\x60]|\$\(|\b(?:then|do|else|exec|command|xargs|env|sudo|nohup|time)\s)\s*`
// 명령 자리의 **파일 실행** — 상대경로(`./gradlew` · `../x`) · 점 소싱(`. ./env`) · 변수 경로(`"$IN/x"`) · 절대경로
// (`/tmp/x`) · 홈(`~/x`). 산출물의 파일을 실행하는 통로라 도구 이름 목록과 따로 막는다(Grok 레그 — `/tmp/x` 가 샜다).
const RUN_FILE_EXEC = new RegExp(CMD_POS + String.raw`(?:\.{1,2}\/|\.\s+\S|"?\$[{A-Za-z_]|\/|~\/)`, 'm')
const LOADER_HOOKS =
  'BASH_ENV|ENV|PATH|NODE_OPTIONS|NODE_PATH|JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|_JAVA_OPTIONS|JAVA_HOME|SONAR_SCANNER_OPTS|' +
  'SONAR_SCANNER_JAVA_OPTS|SONAR_SCANNER_JSON_PARAMS|SONARQUBE_SCANNER_PARAMS|SONAR_USER_HOME|LD_PRELOAD|LD_LIBRARY_PATH|' +
  'PYTHONPATH|PYTHONSTARTUP|RUBYOPT|PERL5OPT'
// YAML `env:` 의 키(`NODE_OPTIONS: …`)와 `$GITHUB_ENV` 에 쓰는 글(`NODE_OPTIONS=…`) 둘 다 본다.
const LOADER_HOOK = new RegExp(String.raw`(?:^\s*|[\s"'])(${LOADER_HOOKS})\s*[:=]`)
// 스캔 액션의 입력 중 서명 검증 · 스캐너 출처 · **분석 루트**를 바꾸는 것. 분석 루트를 산출물로 돌리면 산출물의
// sonar-project.properties 가 `sonar.scanner.javaOpts=-javaagent:…` 를 실을 수 있다(Grok 레그).
const SCAN_UNSAFE_INPUT = /^\s*(skipSignatureVerification|scannerBinariesUrl|scannerBinariesAuthHeader|projectBaseDir)\s*:/
// 같은 것을 속성으로 — 분석 루트 · 스캐너 JVM(JRE 경로·옵션·프로비저닝) · 캐시 · 작업 디렉터리 · JDK 홈 · 서버.
const SCAN_UNSAFE_PROP = /-Dsonar\.(projectBaseDir|scanner\.[A-Za-z0-9.]+|userHome|working\.directory|java\.jdkHome|host\.url)\b/
const runBlocksOf = (body) => {
  const blocks = []
  for (let i = 0; i < body.length; i++) {
    const m = /^(\s*)(?:-\s+)?run:(?:\s(.*))?$/.exec(body[i])
    if (!m) continue
    const keyIndent = body[i].indexOf('run:')
    const v = (m[2] ?? '').trim()
    // 블록 스칼라, 그리고 값이 다음 줄로 넘어간 plain 스칼라(`run:` 뒤가 빈 줄) — 둘 다 더 깊은 줄이 본문이다.
    if (v === '' || BLOCK_SCALAR.test(splitComment(v).body.trim())) {
      const text = []
      for (let k = i + 1; k < body.length; k++) {
        const l = body[k]
        if (l.trim() !== '' && l.length - l.trimStart().length <= keyIndent) break
        text.push(l)
      }
      blocks.push({ at: i, text: text.join('\n') })
    } else blocks.push({ at: i, text: v })
  }
  return blocks
}
// 스텝 `uses:` 의 본문(그 스텝의 다음 줄부터 다음 스텝 전까지).
const stepTail = (body, i) => {
  const dash = body[i].indexOf('-')
  const tail = []
  for (let k = i + 1; k < body.length; k++) {
    const l = body[k]
    if (l.trim() === '') continue
    const ind = l.length - l.trimStart().length
    if (ind <= dash) break
    tail.push(l)
  }
  return tail
}
// 셸·로더 훅·`$GITHUB_PATH` — 잡 본문과 최상위 줄(`defaults:`·`env:` 는 모든 잡에 걸린다)에 같이 쓴다.
// 여기는 YAML 주석을 걷는다 — 설명 주석의 낱말이 설정 행세를 하지 않게(규칙 1b 의 교훈).
const hookFindings = (lines, lineOf, who) => {
  const found = []
  for (const [i, raw] of lines.entries()) {
    const body = splitComment(raw).body
    const sm = /^\s*(?:-\s+)?shell:\s*(.*)$/.exec(body)
    if (sm && !/^['"]?(bash|sh)\b/.test(sm[1].trim()))
      found.push(`${lineOf(i)} ${who} 의 \`shell: ${sm[1].trim()}\` — 시크릿 잡의 셸은 bash·sh 뿐이다(다른 셸은 run 글을 그 언어로 실행한다)`)
    const hm = LOADER_HOOK.exec(body)
    if (hm)
      found.push(`${lineOf(i)} ${who} 이 로더 훅 \`${hm[1]}\` 를 둔다 — 훅 하나면 저장소·산출물의 파일이 셸·스캔 액션·스캐너 안에서 돈다`)
    if (/\bGITHUB_PATH\b/.test(body))
      found.push(`${lineOf(i)} ${who} 이 \`$GITHUB_PATH\` 를 고친다 — 산출물 속 실행 파일이 이후 스텝의 명령을 가린다`)
  }
  return found
}
const rulePrSecretJobRunsNoCode = (wf, out) => {
  const { jobs, outside } = prSecretJobsOf(wf)
  if (jobs.length === 0) return
  // 최상위 줄의 번호 — `outside` 는 `jobs:` 앞 조각과 뒤 조각을 이은 것이다.
  const head = wf.jobsLine - 1
  out.push(...hookFindings(outside, (i) => `${wf.file}:${i < head ? i + 1 : wf.jobsEndLine + (i - head)}`, '워크플로 최상위'))
  for (const { job, body } of jobs) {
    const who = `잡 \`${job.name}\`(PR 에서 시크릿을 쥔다)`
    const lineOf = (i) => `${wf.file}:${job.node.n + i}`
    const jobLevelUses = new Set(job.keys.filter((k) => k.key === 'uses').map((k) => k.n))
    for (const k of job.keys)
      if (['uses', 'container', 'services'].includes(k.key))
        out.push(`${wf.file}:${k.n} ${who} 이 잡 레벨 \`${k.key}:\` 를 쓴다 — 그 안에서 무엇이 도는지 이 가드가 볼 수 없다(fail-closed). 빌드·설치는 시크릿 없는 잡으로`)
    out.push(...hookFindings(body, lineOf, who))
    let checkouts = 0
    for (const [i, raw] of body.entries()) {
      const plain = splitComment(raw).body
      const ui = SCAN_UNSAFE_INPUT.exec(plain)
      if (ui)
        out.push(`${lineOf(i)} ${who} 이 스캔 액션의 입력 \`${ui[1]}\` 를 쓴다 — 서명 검증·스캐너 출처·분석 루트를 바꾸는 입력은 시크릿 잡에서 금지(검증 안 된 바이너리나 산출물의 설정이 토큰과 돈다)`)
      const up = SCAN_UNSAFE_PROP.exec(plain)
      if (up)
        out.push(`${lineOf(i)} ${who} 이 스캐너 속성 \`sonar.${up[1]}\` 를 바꾼다 — 분석 루트·스캐너 JVM·캐시·서버를 바꾸는 속성은 시크릿 잡에서 금지`)
      const um = USES_REF.exec(plain)
      if (!um || jobLevelUses.has(job.node.n + i)) continue
      const ref = um[1]
      const name = ref.replace(/@.*$/, '')
      if (ref.startsWith('./') || ref.startsWith('docker://') || !PR_SECRET_JOB_ACTIONS.has(name))
        out.push(
          `${lineOf(i)} ${who} 이 \`${name}\` 를 쓴다 — 시크릿 잡의 액션은 \`${[...PR_SECRET_JOB_ACTIONS].join('`·`')}\` 뿐이다(셋업·캐시·로컬 액션은 패키지 코드를 이 잡에 들인다)`,
        )
      // 체크아웃은 하나 · 이 저장소만 — 둘째 체크아웃이나 다른 저장소는 작업 트리(설정 · 소스)를 덮는다(Grok 레그).
      if (name === 'actions/checkout') {
        checkouts++
        if (checkouts === 2)
          out.push(`${lineOf(i)} ${who} 의 체크아웃이 2 번 있다 — 둘째 체크아웃은 검토된 트리(sonar-project.properties · 소스)를 덮는다`)
        if (stepTail(body, i).some((l) => /^\s*repository:/.test(splitComment(l).body)))
          out.push(`${lineOf(i)} ${who} 의 체크아웃이 \`repository:\` 로 다른 저장소를 받는다 — 검토되지 않은 트리다`)
      }
      if (name === 'actions/download-artifact') {
        const path = stepTail(body, i)
          .map((l) => /^\s*path:\s*(.*)$/.exec(splitComment(l).body))
          .find(Boolean)
        if (!path || !/^['"]?\$\{\{\s*runner\.temp\s*\}\}/.test(path[1].trim()))
          out.push(
            `${lineOf(i)} ${who} 의 \`actions/download-artifact\` 가 \`path: \${{ runner.temp }}/…\` 가 아니다 — 워크스페이스에 풀리면 산출물이 설정 파일을 덮는다`,
          )
      }
    }
    // `needs.<잡>.result` 는 상태라 앞 잡의 코드가 못 정한다 — 그것만 걷어 내고 남은 `needs` 를 본다. `toJSON(needs)`
    // 처럼 점·괄호 없이 통째로 싣는 식도 출력을 싣는다(첫 판의 `needs[.[]` 가 놓쳤다 — Grok 레그 뒤 재현).
    for (const span of body.join('\n').matchAll(EXPR_SPAN))
      if (/\bneeds\b/.test(span[1].replace(/\bneeds\s*\.\s*[A-Za-z_][\w-]*\s*\.\s*result\b/g, '')))
        out.push(`${wf.file}:${job.node.n} ${who} 에 \`\${{${span[1]}}}\` 가 있다 — 앞 잡의 출력은 그 잡의 코드가 정한 글자다(run 이면 스크립트 주입, 스캔 args 면 속성 주입)`)
    for (const { at: i, text } of runBlocksOf(body)) {
      const tool = RUN_TOOL.exec(text)
      if (tool)
        out.push(`${lineOf(i)} ${who} 의 \`run:\` 이 \`${tool[1]}\` 를 부른다 — 설치·빌드·인터프리터는 시크릿 없는 잡에서 돌리고 산출물로 넘길 것`)
      if (RUN_FILE_EXEC.test(text))
        out.push(`${lineOf(i)} ${who} 의 \`run:\` 이 파일을 실행한다(명령 자리의 \`./…\`·\`. …\`·\`$VAR/…\`·\`/…\`) — 시크릿 없는 잡으로`)
    }
  }
}

// ── 실행 ────────────────────────────────────────────────────────────────────

const dir = join(root, '.github', 'workflows')
let files = []
try {
  files = readdirSync(dir)
    .filter((f) => /\.ya?ml$/.test(f))
    .sort()
} catch (e) {
  errors.push(`${dir} 를 읽지 못했다 (${e.code ?? e.message}) — 검사 대상 없음을 통과로 취급하지 않는다`)
}
if (files.length === 0 && errors.length === 0)
  errors.push(`${dir} 에 워크플로가 하나도 없다 — 검사 대상 없음을 통과로 취급하지 않는다`)

const isRelease = (f) => /release\.ya?ml$/.test(f)
const workflows = files.map((f) => parseWorkflow(f, readFileSync(join(dir, f), 'utf8')))
for (const wf of workflows) errors.push(...wf.fatal)

const releases = workflows.filter((wf) => isRelease(wf.file))
if (releases.length < MIN_RELEASE)
  errors.push(
    `릴리스 워크플로가 ${releases.length}개뿐이다(기대 ${MIN_RELEASE}개 이상) — 파일이 개명되어 이 가드의 검사 범위가 조용히 비었을 수 있다`,
  )

ruleGovulncheckPinAligned(workflows, errors)

let writeGrants = 0
let jobCount = 0
let publishJobs = 0
let usesRefs = 0
let writeCheckouts = 0
let prSecretJobs = 0
for (const wf of workflows) {
  jobCount += wf.jobs.length
  writeCheckouts += ruleWriteJobDropsCheckoutCreds(wf, errors)
  prSecretJobs += ruleDependabotPrSecretSkip(wf, errors)
  rulePrSecretJobRunsNoCode(wf, errors)
  ruleNoBlanketGrant(wf, errors)
  ruleGovulncheckChecksLatest(wf, errors)
  usesRefs += ruleActionsPinnedToSha(wf, errors)
  if (isRelease(wf.file)) {
    ruleJobLevelDeclared(wf, errors)
    ruleNoWorkflowLevelBlock(wf, errors)
    ruleSecretPreflight(wf, errors)
    publishJobs += rulePublishGated(wf, errors)
    writeGrants += ruleEscalationDocumented(wf, errors)
  } else {
    // 규칙 3은 규칙 1의 일반형이다 — 릴리스 워크플로에서는 규칙 1이 더 구체적인 메시지로
    // 같은 것을 잡으므로 여기서 또 보고하지 않는다(같은 사고를 두 줄로 알리면 둘 다 덜 읽힌다).
    ruleNoRepoDefaultInheritance(wf, errors)
  }
}

// ⚠️ 공허성 — 규칙 9·10 은 **발견 기반**이라 조준점이 사라지면 0건을 검사하고 초록을 낸다.
// 잡 키를 개명하거나(`release` → `deploy`) `uses:` 표기가 바뀌면 그렇게 된다. `--min-release`
// 와 같은 이유로 실측치를 명시로 넘겨 그 침묵을 막는다.
if (publishJobs < MIN_PUBLISH)
  errors.push(
    `게시 잡이 ${publishJobs}개뿐이다(기대 ${MIN_PUBLISH}개 이상) — 잡 키가 개명되어 규칙 9 가 조용히 비었을 수 있다`,
  )
// 규칙 5 도 같은 부류다 — 상승을 **발견해서** 검사하므로 상승이 스캐너에 안 보이면 0건을
// 검사하고 초록을 낸다. 이 수는 원래 인쇄만 되고 아무도 보지 않았다.
if (writeGrants < MIN_ESCALATIONS)
  errors.push(
    `릴리스 잡의 write 상승이 ${writeGrants}건뿐이다(기대 ${MIN_ESCALATIONS}건 이상) — 표기가 바뀌어 규칙 5 가 상승을 못 보고 있을 수 있다`,
  )
// 규칙 1b 도 발견 기반이다 — `contents: write` 표기가 바뀌거나 체크아웃 액션이 개명되면
// 0건을 검사하고 초록을 낸다. 실측치를 명시로 넘겨 그 침묵을 막는다.
if (writeCheckouts < MIN_WRITE_CHECKOUT)
  errors.push(
    `\`contents: write\` + 체크아웃 잡이 ${writeCheckouts}개뿐이다(기대 ${MIN_WRITE_CHECKOUT}개 이상) — 표기가 바뀌어 규칙 1b 가 조용히 비었을 수 있다`,
  )
if (usesRefs < MIN_USES)
  errors.push(
    `비로컬 \`uses:\` 가 ${usesRefs}개뿐이다(기대 ${MIN_USES}개 이상) — 규칙 10 이 조용히 비었을 수 있다`,
  )
if (prSecretJobs < MIN_PR_SECRET_JOBS)
  errors.push(
    `PR 에서 시크릿을 쥐는 잡이 ${prSecretJobs}개뿐이다(기대 ${MIN_PR_SECRET_JOBS}개 이상) — 시크릿 참조 표기나 트리거가 바뀌어 규칙 11 이 조용히 비었을 수 있다`,
  )

console.log(
  `  워크플로 ${workflows.length}개 · 릴리스 ${releases.length}개 · 잡 ${jobCount}개 · 게시 잡 ${publishJobs}개 · 비로컬 uses ${usesRefs}개 · 릴리스 잡의 write 상승 ${writeGrants}건 · write+체크아웃 잡 ${writeCheckouts}개 · PR 시크릿 잡 ${prSecretJobs}개`,
)
if (errors.length) {
  for (const e of errors) console.log(`::error::${e}`)
  console.log(`\nCI 권한 가드 실패 — ${errors.length}건`)
  process.exit(1)
}
console.log(
  `\nCI 권한 가드 통과 — 릴리스 워크플로의 모든 잡이 권한을 직접 선언하고(워크플로 레벨 기본값 없음), 어떤 워크플로도 저장소 기본 권한에 기대지 않는다`,
)
