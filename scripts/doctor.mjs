#!/usr/bin/env node
// 툴체인 진단기 — "이 PC에서 어느 언어를 빌드할 수 있는가"를 한 번에 답한다.
//
// 요구 버전을 이 스크립트에 적지 않는다. 각 언어의 빌드 파일이 이미 최소 런타임을
// 선언하고 있고(engines·rust-version·required_ruby_version·requires-python·
// TargetFramework·go 지시자·maven.compiler.release·jvmToolchain), 그것이 유일한
// 원천이다. 여기에 숫자를 복사하면 빌드 파일이 올라간 날 진단기가 조용히 거짓말을
// 시작한다 — 그래서 추출에 실패하면 통과가 아니라 에러다(좌표가 바뀐 것 자체가 신호).
//
// 사용:
//   node scripts/doctor.mjs                 # 9개 언어 전부 진단
//   node scripts/doctor.mjs java kotlin     # 지정한 언어만
//   node scripts/doctor.mjs --json          # 기계 판독용
// 종료코드: 선택된 언어에 필요한 도구가 없거나 최소 버전 미달이면 1, 아니면 0.
// (docker는 통합테스트 전용이라 없어도 실패로 치지 않는다 — 경고만.)
import { readFileSync, existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { resolve, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

// ── 빌드 파일에서 최소 런타임 선언 추출 ──────────────────────────────────────
// 좌표(파일·정규식·무엇을 읽었는지)를 값과 함께 들고 다닌다. 진단 실패 리포트가
// "어느 파일의 어느 선언 때문에 이 숫자를 요구하는가"까지 말해야 쓸모가 있다.
function req(file, re, what) {
  const path = join(ROOT, file)
  if (!existsSync(path)) throw new Error(`빌드 파일 없음: ${file} (좌표가 바뀌었다면 doctor.mjs도 함께 고쳐야 한다)`)
  const m = re.exec(readFileSync(path, 'utf8'))
  if (!m) throw new Error(`${file}에서 ${what}을(를) 찾지 못함 (선언 형태가 바뀌었다면 doctor.mjs도 함께 고쳐야 한다)`)
  return { version: m[1], source: `${file} · ${what}` }
}

// ── 버전 비교(숫자 세그먼트 사전식) ──────────────────────────────────────────
const seg = (v) => v.split(/[^\d]+/).filter(Boolean).map(Number)
function gte(found, required) {
  const a = seg(found)
  const b = seg(required)
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0
    const y = b[i] ?? 0
    if (x !== y) return x > y
  }
  return true
}

// ── 도구 실행 ────────────────────────────────────────────────────────────────
// 버전을 stdout이 아니라 stderr로 뱉는 도구가 있다(java -version). 둘을 합쳐서 본다.
//
// 호출 경로를 3단으로 시도하는 이유(전부 Windows에서 실측한 실패다):
//  1. shell 없이 — 진짜 실행파일(java.exe·go.exe…)에 가장 정확하다.
//  2. shell:true — Node는 Windows에서 cmd.exe를 띄운다. `mvn.cmd`·`gradlew.bat` 같은
//     배치 shim은 이 경로로만 잡힌다.
//  3. `sh -c` — cmd.exe가 실행할 수 없는 **확장자 없는 POSIX 셸 shim**(이 저장소의
//     `composer`가 정확히 그렇다: Git Bash용 shim + composer.phar)을 잡는다. 2단까지만
//     두면 설치돼 있는 composer를 MISSING으로 오진한다.
const ATTEMPTS = [
  (cmd, args) => [cmd, args, { shell: false }],
  (cmd, args) => [cmd, args, { shell: true }],
  (cmd, args) => ['sh', ['-c', [cmd, ...args].join(' ')], { shell: false }],
]
function run(cmd, args) {
  let lastOut = ''
  for (const build of ATTEMPTS) {
    const [c, a, opt] = build(cmd, args)
    const r = spawnSync(c, a, { encoding: 'utf8', windowsHide: true, timeout: 30_000, ...opt })
    if (r.error || r.status === null) continue
    const out = `${r.stdout || ''}${r.stderr || ''}`.trim()
    // 없는 명령은 셸이 비영점 종료 + 버전 없는 출력으로 답한다. 버전 꼴이 보이면
    // 종료코드와 무관하게 성공으로 친다(일부 도구는 --version에도 비영점을 낸다).
    if (/\d+\.\d+/.test(out)) return { ok: true, out }
    lastOut = out || lastOut
  }
  return { ok: false, out: lastOut }
}
const firstVersion = (out) => (/(\d+)\.(\d+)(?:\.(\d+))?/.exec(out) || [])[0] ?? null

// ── 진단 대상 ────────────────────────────────────────────────────────────────
// probe: 먼저 성공하는 명령을 쓴다(python↔python3, cargo 등 호출명이 PC마다 다름).
const check = (name, probes, required, note) => ({ name, probes, required, note })

// Maven·Gradle은 PATH의 `java`가 아니라 **JAVA_HOME이 가리키는 JDK**로 빌드한다.
// 그래서 JAVA_HOME이 설정돼 있으면 그쪽을 먼저 본다 — PATH 앞에 낡은 JDK가 있어도
// 빌드가 도는 것이 실제 동작이고(이 저장소가 정확히 그 구성이다), PATH만 보면
// "JDK 17이라 빌드 불가"라는 거짓 경보를 낸다.
function jdkProbes() {
  const home = process.env.JAVA_HOME
  if (!home) return [['java', ['-version']]]
  // Git Bash에서 export하면 `/c/Program Files/...` 꼴로 들어온다. Windows 네이티브
  // 프로세스인 node는 이 형태를 실행경로로 쓸 수 없으므로 드라이브 표기로 되돌린다.
  const win = process.platform === 'win32' && /^\/[a-z]\//i.test(home) ? `${home[1].toUpperCase()}:${home.slice(2)}` : home
  return [
    [join(win, 'bin', 'java'), ['-version']],
    ['java', ['-version']],
  ]
}

function langs() {
  return {
    java: {
      label: 'Java',
      checks: [
        check('java (JDK)', jdkProbes(), req('java/pom.xml', /<maven\.compiler\.release>\s*(\d+)\s*</, 'maven.compiler.release')),
        check('mvn', [['mvn', ['-v']]], req('java/pom.xml', /<requireMavenVersion>\s*<version>\s*\[([\d.]+)\s*,/, 'enforcer requireMavenVersion')),
      ],
    },
    python: {
      label: 'Python',
      checks: [
        check(
          'python',
          [
            ['python', ['--version']],
            ['python3', ['--version']],
          ],
          req('python/pyproject.toml', /requires-python\s*=\s*"[^"\d]*([\d.]+)"/, 'requires-python'),
        ),
      ],
    },
    node: {
      label: 'Node',
      checks: [check('node', [['node', ['--version']]], req('node/package.json', /"node"\s*:\s*"[^"\d]*([\d.]+)"/, 'engines.node'))],
    },
    go: {
      label: 'Go',
      checks: [check('go', [['go', ['version']]], req('go/go.mod', /^go\s+([\d.]+)/m, 'go 지시자'))],
    },
    dotnet: {
      label: 'C#/.NET',
      checks: [
        check('dotnet (SDK)', [['dotnet', ['--version']]], req('dotnet/Directory.Build.props', /<TargetFramework>\s*net([\d.]+)\s*</, 'TargetFramework')),
      ],
    },
    php: {
      label: 'PHP',
      checks: [
        check('php', [['php', ['--version']]], req('php/composer.json', /"php"\s*:\s*"[^"\d]*([\d.]+)"/, 'require.php')),
        check('composer', [['composer', ['--version']]], null, '버전 하한 선언 없음 — 존재만 확인'),
      ],
    },
    rust: {
      label: 'Rust',
      checks: [
        check('cargo', [['cargo', ['--version']]], req('rust/Cargo.toml', /rust-version\s*=\s*"([\d.]+)"/, 'rust-version(MSRV)')),
        check('rustc', [['rustc', ['--version']]], req('rust/Cargo.toml', /rust-version\s*=\s*"([\d.]+)"/, 'rust-version(MSRV)')),
      ],
    },
    ruby: {
      label: 'Ruby',
      checks: [
        check('ruby', [['ruby', ['--version']]], req('ruby/keycloak-sdk.gemspec', /required_ruby_version\s*=\s*"[^"\d]*([\d.]+)"/, 'required_ruby_version')),
        check('bundler', [['bundle', ['--version']]], null, '버전 하한 선언 없음 — 존재만 확인'),
      ],
    },
    kotlin: {
      label: 'Kotlin',
      checks: [
        check('java (JDK)', jdkProbes(), req('kotlin/build.gradle.kts', /jvmToolchain\((\d+)\)/, 'jvmToolchain')),
        // Gradle 자체는 설치할 필요가 없다 — 래퍼(kotlin/gradlew)가 build.gradle.kts가
        // 요구하는 배포판을 내려받는다. 그래서 확인 대상은 "래퍼가 있는가"뿐이다.
        check('kotlin/gradlew (래퍼)', null, null, 'Gradle 설치 불필요 — 래퍼가 배포판을 가져온다'),
      ],
    },
  }
}

// ── 공통(언어 무관) ──────────────────────────────────────────────────────────
const COMMON = [
  check('git', [['git', ['--version']]], null, null),
  check('docker', [['docker', ['--version']]], null, '통합테스트 전용 — 없어도 단위테스트는 돈다'),
]
const OPTIONAL = new Set(['docker'])

function evaluate(c) {
  if (c.name.startsWith('kotlin/gradlew')) {
    const ok = existsSync(join(ROOT, 'kotlin', 'gradlew'))
    return { ...c, status: ok ? 'ok' : 'MISSING', found: ok ? '있음' : null }
  }
  let out = null
  for (const [cmd, args] of c.probes) {
    const r = run(cmd, args)
    if (r.ok) {
      out = r.out
      break
    }
  }
  if (out === null) return { ...c, status: 'MISSING', found: null }
  const found = firstVersion(out)
  if (!found) return { ...c, status: 'UNKNOWN', found: out.split('\n')[0].slice(0, 60) }
  if (c.required && !gte(found, c.required.version)) return { ...c, status: 'TOO OLD', found }
  return { ...c, status: 'ok', found }
}

// ── main ─────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2)
const JSON_OUT = argv.includes('--json')
const wanted = argv.filter((a) => !a.startsWith('--'))

let ALL
try {
  ALL = langs()
} catch (e) {
  console.error(`::error::${e.message}`)
  process.exit(2)
}

const unknown = wanted.filter((w) => !(w in ALL))
if (unknown.length) {
  console.error(`알 수 없는 언어: ${unknown.join(', ')}`)
  console.error(`가능한 값: ${Object.keys(ALL).join(' ')}`)
  process.exit(2)
}
const selected = wanted.length ? wanted : Object.keys(ALL)

const results = []
for (const key of selected) {
  for (const c of ALL[key].checks) results.push({ group: ALL[key].label, ...evaluate(c) })
}
for (const c of COMMON) results.push({ group: '공통', ...evaluate(c) })

const failed = results.filter((r) => r.status !== 'ok' && !OPTIONAL.has(r.name))

if (JSON_OUT) {
  console.log(
    JSON.stringify(
      {
        ok: failed.length === 0,
        results: results.map((r) => ({
          group: r.group,
          tool: r.name,
          required: r.required?.version ?? null,
          requiredFrom: r.required?.source ?? null,
          found: r.found,
          status: r.status,
        })),
      },
      null,
      2,
    ),
  )
  process.exit(failed.length ? 1 : 0)
}

const w = (s, n) => String(s ?? '—').padEnd(n)
console.log(`${w('도구', 22)}${w('필요', 10)}${w('설치됨', 14)}상태`)
console.log('-'.repeat(58))
let group = null
for (const r of results) {
  if (r.group !== group) {
    group = r.group
    console.log(`[${group}]`)
  }
  const mark = r.status === 'ok' ? 'ok' : OPTIONAL.has(r.name) ? `${r.status} (선택)` : r.status
  console.log(`  ${w(r.name, 20)}${w(r.required?.version, 10)}${w(r.found, 14)}${mark}`)
}

if (failed.length) {
  console.log('')
  for (const r of failed) {
    const why = r.required ? ` — ${r.required.source}가 ${r.required.version} 이상을 요구` : ''
    console.log(`::error::[${r.group}] ${r.name}: ${r.status}${why}`)
  }
  console.log('\n설치 방법: docs/guides/development-setup.md')
  process.exit(1)
}
console.log(`\n선택된 ${selected.length}개 언어의 툴체인이 모두 준비됨.`)
