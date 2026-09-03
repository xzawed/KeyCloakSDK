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
let MIN_USES = 1
// ⚠️ 그리고 규칙 5(권한 상승에 근거 주석)에도 같은 하한이 필요하다. 이 규칙은 **상승을 발견해서**
// 검사하므로, 상승이 스캐너에 안 보이게 되는 순간 0건을 검사하고 초록을 낸다. 실측: 플로우 매핑
// 표기 하나로 인벤토리의 상승 수가 6 → 5 로 줄어드는데도 통과했다. 인쇄만 하고 하한이 없으면
// 그 수가 줄어드는 것을 아무도 못 본다.
let MIN_ESCALATIONS = 0
for (const arg of process.argv.slice(2)) {
  if (/^--min-release=\d+$/.test(arg)) MIN_RELEASE = Number(arg.slice('--min-release='.length))
  else if (/^--min-publish=\d+$/.test(arg)) MIN_PUBLISH = Number(arg.slice('--min-publish='.length))
  else if (/^--min-uses=\d+$/.test(arg)) MIN_USES = Number(arg.slice('--min-uses='.length))
  else if (/^--min-escalations=\d+$/.test(arg))
    MIN_ESCALATIONS = Number(arg.slice('--min-escalations='.length))
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
  }
}

// 잡 목록과 각 잡의 `permissions:` 선언 위치를 뽑는다.
const parseWorkflow = (file, text) => {
  const { lines, nodes } = scan(text)
  const wf = { file, lines, workflowPerms: null, jobs: [], fatal: [] }

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

  wf.workflowPerms = nodes.find((x) => x.indent === 0 && x.key === 'permissions') ?? null
  const jobsIdx = nodes.findIndex((x) => x.indent === 0 && x.key === 'jobs')
  if (jobsIdx < 0) {
    wf.fatal.push(`${file}: 최상위 \`jobs:\`를 찾지 못했다 — 워크플로로 해석할 수 없다(fail-closed)`)
    return wf
  }
  // jobs 하위 = 다음 최상위 키 전까지.
  const after = nodes.slice(jobsIdx + 1)
  const stop = after.findIndex((x) => x.indent === 0)
  const body = stop < 0 ? after : after.slice(0, stop)
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
// ⚠️ **이 규칙이 못 보는 것**: 빈값 검사가 있다는 것만 보고 그것이 `exit 1` 로 이어지는지는
// 보지 않는다. 그 배선까지 텍스트로 쫓으면 두 모양에서 수렴하지 않는다.
const ENV_SECRET_BINDING = /^\s*([A-Za-z_][A-Za-z0-9_]*):\s*\$\{\{\s*secrets\.([A-Z_][A-Z0-9_]*)\s*\}\}/
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
      if (!body.some((l) => test.test(l)))
        out.push(
          `${wf.file}: 잡 \`${job.name}\`이 배포 시크릿 \`${secret}\`을(를) \`$${env}\`로 받는데 미설정 빈값 검사가 없다 — 아무것도 게시하지 않은 실행이 green 으로 끝난다`,
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
for (const wf of workflows) {
  jobCount += wf.jobs.length
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
if (usesRefs < MIN_USES)
  errors.push(
    `비로컬 \`uses:\` 가 ${usesRefs}개뿐이다(기대 ${MIN_USES}개 이상) — 규칙 10 이 조용히 비었을 수 있다`,
  )

console.log(
  `  워크플로 ${workflows.length}개 · 릴리스 ${releases.length}개 · 잡 ${jobCount}개 · 게시 잡 ${publishJobs}개 · 비로컬 uses ${usesRefs}개 · 릴리스 잡의 write 상승 ${writeGrants}건`,
)
if (errors.length) {
  for (const e of errors) console.log(`::error::${e}`)
  console.log(`\nCI 권한 가드 실패 — ${errors.length}건`)
  process.exit(1)
}
console.log(
  `\nCI 권한 가드 통과 — 릴리스 워크플로의 모든 잡이 권한을 직접 선언하고(워크플로 레벨 기본값 없음), 어떤 워크플로도 저장소 기본 권한에 기대지 않는다`,
)
