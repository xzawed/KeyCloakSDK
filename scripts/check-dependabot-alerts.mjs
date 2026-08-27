#!/usr/bin/env node
// 열린 Dependabot 경보가 하나라도 있으면 실패한다.
//
// 왜 필요한가: `security-audit.yml`의 언어별 감사 잡 9종은 전부 `working-directory:`가 SDK
// 디렉터리라 **하네스의 의존성을 아무도 보지 않는다**. GitHub 의존성 그래프는 하네스
// 매니페스트를 파싱하지만(실측: 54개 중 harness/* 포함), 그 결과가 닿는 곳은 Security 탭뿐이라
// 사람이 열어보지 않으면 침묵한다 — high 2건이 51일간 열려 있었고 아무것도 빨개지지 않았다.
//
// 이 게이트는 언어 툴체인을 쓰지 않는다. 하네스 앱 매니페스트 13개 중 5개가 **이미지 안에만
// 있는 경로**를 참조해서(`path: "/src/ruby"`·`replace => /sdk`·`url: "/src/php"`·`.tgz`·
// `http://mvn-repo-kotlin/`) 스톡 러너에서 bundler·go·composer·npm 을 돌릴 수 없다. 대신
// GitHub이 이미 만들어 둔 그래프를 읽는다.
//
// ⚠️ 이 게이트는 하네스 감사를 **대체하지 않는다** — 컨테이너 없이 실제로 도는 둘(rust·python)은
// `security-audit.yml`의 `harness-rust`·`harness-python`이 직접 감사한다. 여기는 나머지다.
// ⚠️ 그리고 이 게이트도 "전부"가 아니다: 의존성 그래프는 `replace`를 무시하고 Gradle 을 파싱하지
// 않는다. 하네스 Go 의 SDK 엣지와 하네스 Kotlin 은 어느 게이트도 보지 않는다(security-audit.yml 주석).
//
// 사용:
//   node scripts/check-dependabot-alerts.mjs            # 현재 저장소
//   node scripts/check-dependabot-alerts.mjs --repo o/n
//
// 종료코드: 열린 경보가 있으면 1. 조회 실패(권한·인증·네트워크)는 2 — 구분하지 않으면
// 토큰이 없어서 못 읽은 것이 "경보 없음"으로 둔갑한다.
//
// ⚠️ 이 잡의 `permissions:`에는 `vulnerability-alerts: read`가 있어야 한다. **실측**(run
// 33079374320, 같은 요청을 보내는 두 잡): 선언한 잡은 `200`, 선언하지 않은 대조군은 `403
// Resource not accessible by integration`이었다. `security-events: read`는 code scanning용이라
// 이 API에 듣지 않는다 — 바꿔 달면 403이 오고, 아래 fail-closed가 없으면 그게 초록이 된다.
//
// ⚠️ 빠져나갈 길은 침묵이 아니라 기록이다: 판정이 끝난 경보는 GitHub UI에서 **사유와 함께
// dismiss**한다. dismissed는 `state=open`이 아니므로 이 게이트가 더 이상 세지 않는다(code
// scanning 쪽에서 이미 5건을 그렇게 닫았다).
import { spawnSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

function gh(args) {
  const r = spawnSync('gh', args, { encoding: 'utf8', windowsHide: true, timeout: 60_000 })
  if (r.error) return { ok: false, code: 2, out: `gh 실행 실패: ${r.error.message} (gh CLI가 설치돼 있고 인증돼 있어야 한다)` }
  const out = `${r.stdout || ''}${r.stderr || ''}`.trim()
  // 조회 실패는 **언제나** "확인하지 못했다"(2)이지 "경보가 없다"가 아니다. 원인 문구를
  // 열거해 분류하려는 시도는 반드시 샌다(repo-config.mjs가 같은 이유로 분류를 버렸다).
  if (r.status !== 0) return { ok: false, code: 2, out }
  return { ok: true, out }
}

// 순수 함수. 네트워크 없이 자가테스트가 이걸 직접 먹인다 — 그게 없으면 이 함수가 늘 빈
// 배열을 돌려주게 바뀌어도 아무도 모른다.
//
// ⚠️ `state`를 여기서 **다시** 거른다. 호출부가 `?state=open`을 붙이지만, 그 질의문자열이
// 빠지거나 오타가 나면 fixed·dismissed까지 세어 게이트가 영구 빨강이 되고 곧 무시당한다.
export function alertsVerdict(alerts) {
  // ⚠️ 배열이 아니면 **던진다**. 이게 이 게이트의 유일한 거짓-초록 형태였다: 200 응답이
  // `null`이나 JSON 문자열로 파싱되면 `alerts ?? []`는 null만 걷어내고, 문자열은 `for...of`가
  // 글자 단위로 훑어 `.state`가 전부 undefined → 빈 배열 → exit 0. 즉 "읽었는데 아무것도
  // 없었다"와 "읽은 것이 경보 목록이 아니었다"가 같은 초록이 된다. 던지면 main이 2로 받는다.
  if (!Array.isArray(alerts)) {
    throw new TypeError(`Dependabot 경보 응답이 배열이 아니다(${alerts === null ? 'null' : typeof alerts}) — 경보 없음으로 넘기지 않는다`)
  }
  const out = []
  for (const a of alerts) {
    if (a?.state !== 'open') continue
    const sev = a.security_advisory?.severity ?? '?'
    const pkg = a.dependency?.package
    const where = a.dependency?.manifest_path ?? '?'
    const ghsa = a.security_advisory?.ghsa_id ?? '?'
    const cve = a.security_advisory?.cve_id ?? '-'
    // ⚠️ 한 경보 = **배열 한 항목**이다(여러 줄이어도). 호출부가 `length` 를 경보 **건수**로
    // 쓰므로 구간을 별도 항목으로 밀어 넣으면 "경보 5건" 같은 거짓 수치가 나간다.
    const lines = [`#${a.number} [${sev}] ${pkg?.ecosystem ?? '?'}/${pkg?.name ?? '?'} @ ${where} — ${ghsa} / ${cve}`]
    // ⚠️ **`security_vulnerability.first_patched_version` 을 고쳐야 할 버전으로 쓰지 말 것.**
    // 그 객체는 advisory 의 여러 취약 구간 중 **지금 선언된 버전에 걸리는 하나**만 담는다.
    // 실측(alert #13): `security_vulnerability` 는 `>= 5.5.0, < 7.2.1` / patched `7.2.1` 하나인데
    // `security_advisory.vulnerabilities` 는 **둘**이다 — 위 구간과 `>= 8.0.0, < 8.0.2` / `8.0.2`.
    // 그 좁은 값을 그대로 믿고 `>= 7.2.1` 로 올리면 8.0.0·8.0.1(둘 다 취약, 둘 다 7.2.1 보다 높다)이
    // 그대로 허용된다 — 이 저장소에서 실제로 그렇게 했고 적대적 리뷰가 P0 으로 잡았다(7df7529).
    // 그래서 좁은 값을 아예 출력하지 않고 **모든 구간**을 찍는다. 여기서 구간 산술은 하지 않는다
    // (9개 생태계의 범위 문법을 파싱하는 것은 새 거짓-초록 표면이다) — 사람이 합집합을 보고 고른다.
    for (const line of advisoryRanges(a)) lines.push(`    ${line}`)
    out.push(lines.join('\n'))
  }
  return out
}

// advisory 가 이 패키지에 대해 선언한 **모든** 취약 구간. advisory 하나가 여러 패키지를 덮을 수
// 있으므로 경보의 패키지로 거른다(거르지 않으면 남의 생태계 구간이 섞여 사람이 잘못 고른다).
// ⚠️ 구간이 둘 이상이면 그것을 말로 적는다 — 이 사건의 함정이 정확히 "패치 라인이 둘"이었고,
// 목록만 나열하면 읽는 사람이 다시 낮은 쪽 하나만 집는다.
export function advisoryRanges(alert) {
  const pkg = alert?.dependency?.package
  const all = alert?.security_advisory?.vulnerabilities
  if (!Array.isArray(all) || all.length === 0) return ['취약 구간: (advisory 에 없음 — GitHub UI 에서 직접 확인할 것)']
  const mine = all.filter(
    (v) => !pkg?.name || (v?.package?.name === pkg.name && v?.package?.ecosystem === pkg.ecosystem),
  )
  const use = mine.length ? mine : all
  const lines = use.map(
    (v) => `취약 ${v?.vulnerable_version_range ?? '?'} → 패치 ${v?.first_patched_version?.identifier ?? '없음'}`,
  )
  if (use.length > 1) {
    lines.push(`⚠️ 취약 구간이 ${use.length}개다 — 하한 하나로 전부를 벗어나는지 확인할 것(낮은 패치 라인만 집으면 위쪽 구간이 열린다)`)
  }
  return lines
}

function repoSlug(argv) {
  const i = argv.indexOf('--repo')
  if (i >= 0 && argv[i + 1]) return argv[i + 1]
  const r = gh(['repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'])
  if (!r.ok) {
    console.error(`현재 저장소를 알 수 없다 — --repo <owner/name>을 주거나 gh 인증을 확인하라.\n${r.out}`)
    process.exit(2)
  }
  return r.out
}

function main() {
  const argv = process.argv.slice(2)
  const repo = repoSlug(argv)
  const res = gh(['api', '-H', 'X-GitHub-Api-Version: 2022-11-28', `repos/${repo}/dependabot/alerts?state=open&per_page=100`])
  if (!res.ok) {
    console.log(`::error::Dependabot 경보를 조회하지 못했다 — 경보 없음으로 넘기지 않는다.`)
    console.log(`  잡의 permissions에 \`vulnerability-alerts: read\`가 있는지 확인하라(없으면 403).`)
    console.log(res.out)
    process.exit(2)
  }
  // ⚠️ 파싱과 판정을 **같은 try 안에** 둔다. alertsVerdict는 배열이 아닌 입력에 던지는데,
  // 그 throw가 밖으로 새면 node가 스택트레이스와 함께 1로 죽는다 — 그러면 "열린 경보 있음"과
  // "응답이 경보 목록이 아님"이 같은 종료코드가 되어, 이 스크립트가 애써 나눈 1/2 구분이 무너진다.
  let open
  try {
    open = alertsVerdict(JSON.parse(res.out))
  } catch (e) {
    console.log(`::error::Dependabot 경보 응답을 읽지 못했다 — ${e.message}`)
    process.exit(2)
  }
  if (open.length === 0) {
    console.log(`ok   ${repo}: 열린 Dependabot 경보 없음`)
    process.exit(0)
  }
  console.log(`::error::${repo}: 열린 Dependabot 경보 ${open.length}건`)
  for (const line of open) console.log(`  - ${line}`)
  console.log(``)
  console.log(`고치거나(의존성 상향), 판정을 마쳤다면 Security 탭에서 **사유와 함께 dismiss** 하라.`)
  process.exit(1)
}

// process.argv[1]은 `node -e '...'`로 import할 때 undefined다 — 가드 없이 호출하면
// pathToFileURL이 throw해서, 정작 import만 하려던 자가테스트가 죽는다.
// ⚠️ 이 파일 경로를 `node -e` 뒤 인자로 넘기면 argv[1]이 되어 가드가 "직접 실행"으로 오인한다.
// import하는 쪽은 scripts/로 cd한 뒤 cwd 상대 지정자로 import하라(test-dependabot-alerts.sh).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
