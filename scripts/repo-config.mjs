#!/usr/bin/env node
// 저장소 설정(브랜치 룰셋)을 코드로 고정한다.
//
// 왜 필요한가: 브랜치 보호는 저장소 파일이 아니라 GitHub 서버 상태다. 웹 UI에서
// 한 번 클릭해 만들면 **무엇이 왜 그렇게 설정됐는지가 저장소 어디에도 남지 않고**,
// 다른 PC·다른 사람이 확인하거나 재현할 방법이 없으며, 누가 조용히 바꿔도 아무도
// 모른다. 그래서 원하는 상태를 `.github/rulesets/*.json`에 두고 이 스크립트로
// 적용·대조한다 — check-docs·doctor와 같은 원칙(원천을 하나 두고 기계가 대조).
//
// 사용:
//   node scripts/repo-config.mjs check     # 라이브 설정이 커밋된 정의와 같은지 대조(기본)
//   node scripts/repo-config.mjs apply     # 커밋된 정의를 GitHub에 적용(관리자 권한 필요)
//   node scripts/repo-config.mjs pull      # 라이브 설정을 파일로 내려받음(최초 도입·수동변경 흡수)
//   ... --repo <owner/name>                # 기본값은 gh가 인식한 현재 저장소
//
// 종료코드: check에서 드리프트가 있으면 1. 인증/권한 문제는 2(드리프트와 구분한다 —
// 토큰이 없어서 못 읽은 것을 "설정이 어긋났다"로 보고하면 그게 거짓 신호다).
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { resolve, dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const DIR = join(ROOT, '.github', 'rulesets')

// GitHub이 생성·관리하는 필드. 원하는 상태의 일부가 아니므로 대조에서 제외한다
// (커밋된 파일에 id/updated_at을 넣으면 그 자체가 매번 드리프트로 잡힌다).
const SERVER_FIELDS = new Set([
  'id',
  'node_id',
  'created_at',
  'updated_at',
  'source',
  'source_type',
  '_links',
  'current_user_can_bypass',
])

// 순서 비의존 정규화. 룰셋의 배열(rules·allowed_merge_methods·required_status_checks·
// bypass_actors)은 전부 집합 의미라 서버가 돌려주는 순서가 우리 파일과 달라도 같은
// 설정이다. 순서를 그대로 비교하면 의미 없는 드리프트가 계속 뜬다.
export function canonical(v) {
  if (Array.isArray(v)) return v.map(canonical).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)))
  if (v && typeof v === 'object') {
    const out = {}
    for (const k of Object.keys(v).sort()) {
      if (SERVER_FIELDS.has(k)) continue
      out[k] = canonical(v[k])
    }
    return out
  }
  return v
}

function gh(args, { input } = {}) {
  const r = spawnSync('gh', args, { encoding: 'utf8', input, windowsHide: true, timeout: 60_000 })
  if (r.error) return { ok: false, code: 2, out: `gh 실행 실패: ${r.error.message} (gh CLI가 설치돼 있고 인증돼 있어야 한다)` }
  const out = `${r.stdout || ''}${r.stderr || ''}`.trim()
  if (r.status !== 0) {
    // gh 호출 실패는 **언제나** "설정을 확인하지 못했다"(2)이지 "설정이 어긋났다"(1)가
    // 아니다. 이 스크립트의 gh 호출은 전부 설정을 읽거나 쓰는 것이고, 비교는 읽어온
    // 뒤에 로컬에서 한다 — 그러니 실패는 비교에 도달조차 못 했다는 뜻이다.
    //
    // 처음엔 메시지를 정규식으로 훑어 401/404만 2로 분류했는데, CI 러너의 gh는
    // 미인증이라 "set the GH_TOKEN environment variable"라는 다른 문구를 뱉었고
    // 그게 정규식에 안 걸려 드리프트(1)로 둔갑했다. 원인 문구를 열거하는 방식은
    // 반드시 이렇게 샌다 — 분류를 없애는 것이 옳다.
    return { ok: false, code: 2, out }
  }
  return { ok: true, out }
}

function repoSlug(argv) {
  const i = argv.indexOf('--repo')
  if (i >= 0 && argv[i + 1]) return argv[i + 1]
  const r = gh(['repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'])
  if (!r.ok) die(r.code, `현재 저장소를 알 수 없다 — --repo <owner/name>을 주거나 gh 인증을 확인하라.\n${r.out}`)
  return r.out
}

const die = (code, msg) => {
  console.error(msg)
  process.exit(code)
}

function desiredFiles() {
  if (!existsSync(DIR)) die(2, `정의 디렉터리가 없다: ${DIR}`)
  const files = readdirSync(DIR).filter((f) => f.endsWith('.json'))
  if (!files.length) die(2, `정의 파일이 없다: ${DIR}/*.json`)
  return files.map((f) => ({ file: `.github/rulesets/${f}`, body: JSON.parse(readFileSync(join(DIR, f), 'utf8')) }))
}

function liveRulesets(repo) {
  const list = gh(['api', `repos/${repo}/rulesets`])
  if (!list.ok) die(list.code, `룰셋 목록을 읽지 못했다(관리자 권한 토큰이 필요하다).\n${list.out}`)
  const byName = new Map()
  for (const rs of JSON.parse(list.out)) {
    // 목록 응답은 rules를 포함하지 않는다 — 개별 조회로 전체를 가져와야 대조가 성립한다.
    const one = gh(['api', `repos/${repo}/rulesets/${rs.id}`])
    if (!one.ok) die(one.code, `룰셋 ${rs.id} 조회 실패\n${one.out}`)
    byName.set(rs.name, JSON.parse(one.out))
  }
  return byName
}

// ── 명령 ─────────────────────────────────────────────────────────────────────
// 이 파일을 import해도 실행되지 않아야 한다 — 자가테스트가 네트워크·gh 없이
// canonical()만 검증할 수 있어야 하기 때문이다.
function main() {
  const argv = process.argv.slice(2)
  const cmd = argv.find((a) => !a.startsWith('--')) ?? 'check'
  if (!['check', 'apply', 'pull'].includes(cmd)) die(2, `알 수 없는 명령: ${cmd} (check|apply|pull)`)
  const repo = repoSlug(argv)
  const live = liveRulesets(repo)

  if (cmd === 'pull') {
    for (const { file, body } of desiredFiles()) {
      const l = live.get(body.name)
      if (!l) {
        console.log(`skip ${file} — "${body.name}" 룰셋이 원격에 없다`)
        continue
      }
      writeFileSync(join(ROOT, file), `${JSON.stringify(canonical(l), null, 2)}\n`)
      console.log(`pulled ${file} ← ${repo} "${body.name}"`)
    }
    process.exit(0)
  }

  let drift = 0
  for (const { file, body } of desiredFiles()) {
    const want = canonical(body)
    const l = live.get(body.name)

    if (!l) {
      if (cmd === 'apply') {
        const r = gh(['api', '-X', 'POST', `repos/${repo}/rulesets`, '--input', '-'], { input: JSON.stringify(body) })
        if (!r.ok) die(r.code, `룰셋 "${body.name}" 생성 실패\n${r.out}`)
        console.log(`created ${repo} "${body.name}" (정의: ${file})`)
        continue
      }
      console.log(`::error::${file}: "${body.name}" 룰셋이 ${repo}에 없다`)
      drift++
      continue
    }

    const have = canonical(l)
    if (JSON.stringify(have) === JSON.stringify(want)) {
      console.log(`ok  ${file} — ${repo} "${body.name}" 일치`)
      continue
    }

    if (cmd === 'apply') {
      const r = gh(['api', '-X', 'PUT', `repos/${repo}/rulesets/${l.id}`, '--input', '-'], { input: JSON.stringify(body) })
      if (!r.ok) die(r.code, `룰셋 "${body.name}" 적용 실패\n${r.out}`)
      console.log(`applied ${file} → ${repo} "${body.name}"`)
      continue
    }

    drift++
    console.log(`::error::${file}: ${repo} "${body.name}" 설정이 정의와 다르다`)
    console.log('--- 커밋된 정의(want) ---')
    console.log(JSON.stringify(want, null, 2))
    console.log('--- 실제 GitHub 설정(have) ---')
    console.log(JSON.stringify(have, null, 2))
  }

  if (cmd === 'check' && drift) {
    console.log(`\n${drift}건 불일치. 정의를 적용하려면 \`node scripts/repo-config.mjs apply\`,`)
    console.log('실제 설정을 정답으로 받아들이려면 `node scripts/repo-config.mjs pull` 후 커밋하라.')
    process.exit(1)
  }
  console.log(cmd === 'apply' ? '\n적용 완료.' : '\n설정 일치.')
}

// process.argv[1]은 `node -e '...'`로 import할 때 undefined다 — 가드 없이 호출하면
// pathToFileURL이 throw해서, 정작 import만 하려던 자가테스트가 죽는다.
//
// ⚠️ 이 관용구의 한계: `node -e '<code>' scripts/repo-config.mjs`처럼 **이 파일 경로를
// 인자로 넘기면** 그 값이 argv[1]이 되어 가드가 "직접 실행"으로 오인하고 main()을
// 돌린다. import해 쓰는 쪽은 경로를 인자로 넘기지 말고 cwd 상대 지정자로 import하라
// (scripts/test/test-repo-config.sh가 그 방식이다).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
