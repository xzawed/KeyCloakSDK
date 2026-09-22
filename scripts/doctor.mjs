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
import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { resolve, dirname, join, isAbsolute, delimiter } from 'node:path'
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
  // ⚠️ **cmd 를 단따옴표로 감싼다.** 감싸지 않으면 `sh` 가 Windows 경로의 백슬래시를
  // 이스케이프로 먹어 `C:\Users\…\composer` 가 `C:Usersdirtc…composer` 가 되고, 그 명령은
  // 당연히 없어서 127 로 죽는다(실측). 종전에는 cmd 가 언제나 맨 이름이라 드러나지 않았다 —
  // 절대 경로 후보가 생기면서 비로소 보였다. 감싸면 status=0 으로 정상 실행된다.
  (cmd, args) => ['sh', ['-c', [`'${cmd}'`, ...args].join(' ')], { shell: false }],
]

// 출력에서 **경로처럼 생긴 토큰**을 지운다. 실패 메시지는 호출 경로를 되뇌고, 이 저장소의
// 경로에는 버전이 박혀 있다(`…/php-8.3/composer`). 지우지 않으면 아래 버전 정규식이
// 디렉터리 이름을 집어 **`composer 8.3 ok` 라는 거짓 성공**을 만든다 — MISSING 보다 나쁘다.
// (실측으로 걸렸다: sh 가 백슬래시를 먹어 남긴 `C:Usersdirtctoolsphp-8.3` 에서 `8.3` 이 나왔다.)
const stripPaths = (s) =>
  s
    .split(/\s+/)
    .filter((t) => !t.includes('/') && !t.includes('\\') && !/^[A-Za-z]:/.test(t))
    .join(' ')
// 규약 경로 후보를 부를 때는 **그 디렉터리를 PATH 맨 앞에 둔다.** 이식형 설치의 shim 은
// 형제 실행파일을 **맨 이름**으로 부르고(이 저장소의 `composer` 가 정확히 그렇다:
// `exec php "$(dirname "$0")/composer.phar"`), 그 이름은 문서가 시키는
// `export PATH="$KCSDK_PHP:$PATH"`(`.claude/rules/php.md`)를 했을 때만 풀린다.
// ⚠️ 그 export 없이 doctor 를 돌리면 shim 이 `php: Is a directory` 로 죽고 doctor 는
// **설치돼 있는 composer 를 MISSING 으로 보고했다**(실측 2026-09-22 — 그 상태로
// `::error::` 와 exit 1 까지 냈다). doctor 의 존재 이유가 「환경 export 없이도 이 PC 에
// 무엇이 있는지 말한다」이므로, 그 export 가 하는 일을 spawn 단위로 재현한다.
const withToolDirOnPath = (cmd) => {
  if (!isAbsolute(cmd)) return undefined
  return { ...process.env, PATH: `${dirname(cmd)}${delimiter}${process.env.PATH || ''}` }
}
function run(cmd, args) {
  let lastOut = ''
  const env = withToolDirOnPath(cmd)
  for (const build of ATTEMPTS) {
    const [c, a, opt] = build(cmd, args)
    const r = spawnSync(c, a, {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 30_000,
      ...(env ? { env } : {}),
      ...opt,
    })
    if (r.error || r.status === null) continue
    // 판정과 추출을 **둘 다** 경로 제거 후에 한다(위 stripPaths 주석 참조).
    const out = stripPaths(`${r.stdout || ''}${r.stderr || ''}`).trim()
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

// ── 규약 경로(KCSDK_*) ───────────────────────────────────────────────────────
// 이 저장소의 툴체인은 **PATH에 올리지 않는 이식형 설치**가 정상이다 — CLAUDE.md와 모든
// `.claude/rules/<lang>.md`가 `${KCSDK_TOOLS:-$HOME/tools}`·`KCSDK_PY`·`KCSDK_JDK21`·
// `KCSDK_PHP`로 그 자리를 지정한다. 그런데 doctor는 PATH와 JAVA_HOME만 봤다. 결과는
// **저장소 자신의 규약대로 설치한 도구를 MISSING으로 보고하고 "설치 방법"을 가리키는 것**
// 이었다(실측: 이 PC에서 mvn·python·php·composer 넷 다 그랬고, 넷 다 규약 위치에 실재했으며
// 그날 전부 실제로 빌드에 썼다). 진단기가 틀리면 사람은 이미 가진 것을 다시 설치한다.
//
// ⚠️ **버전이 박힌 디렉터리명을 하드코딩하지 않는다.** `apache-maven-3.9.9`·`php-8.3` 같은
// 값은 `.claude/rules/*.md`가 소유하는 핀이고, 여기 적으면 두 번째 정의 자리가 생겨 둘이
// 갈린다. 대신 `KCSDK_TOOLS`의 **직속 자식**을 훑어 후보를 만든다 — 실측상 배치가 둘로
// 갈리기 때문에(maven은 `bin/`에, php는 루트에 실행파일이 있다) 둘 다 본다.
const homeDir = process.env.HOME || process.env.USERPROFILE || ''

// Git Bash에서 export한 `/c/…` 표기는 Windows 네이티브 프로세스인 node가 실행경로로 쓸 수
// 없다 — 드라이브 표기로 되돌린다(jdkProbes가 JAVA_HOME에 하던 것과 같은 변환).
function winPath(p) {
  return process.platform === 'win32' && /^\/[a-z]\//i.test(p) ? `${p[1].toUpperCase()}:${p.slice(2)}` : p
}

// 실행파일 후보가 **실제로 있는지** 먼저 본다. 없는 경로까지 spawn하면 도구 하나당
// 시도가 3배로 늘어 진단이 눈에 띄게 느려진다.
const EXE_SUFFIXES = process.platform === 'win32' ? ['', '.exe', '.cmd', '.bat'] : ['']
const existsExe = (base) => EXE_SUFFIXES.some((s) => existsSync(base + s))

function toolsChildDirs() {
  const root = winPath(process.env.KCSDK_TOOLS || (homeDir ? join(homeDir, 'tools') : ''))
  if (!root || !existsSync(root)) return []
  let kids
  try {
    kids = readdirSync(root, { withFileTypes: true })
  } catch {
    return []
  }
  return kids.filter((d) => d.isDirectory()).flatMap((d) => [join(root, d.name, 'bin'), join(root, d.name)])
}

// probes(cmd, args, explicit) — 규약 우선, PATH 최후.
// explicit: 그 도구 전용 KCSDK_* 가 가리키는 **완전 경로** 후보(있으면 가장 먼저 본다).
function probes(cmd, args, explicit = []) {
  const out = []
  for (const p of explicit) {
    if (p && existsExe(winPath(p))) out.push([winPath(p), args])
  }
  for (const d of toolsChildDirs()) {
    const base = join(d, cmd)
    if (existsExe(base)) out.push([base, args])
  }
  out.push([cmd, args]) // PATH — 종전 동작을 마지막 후보로 보존한다
  return out
}

// `KCSDK_PY`의 문서화된 기본값은 `python/` 기준 상대경로다(`.venv/Scripts/python.exe`).
function pyCandidates() {
  const v = process.env.KCSDK_PY
  if (v) return [resolve(ROOT, 'python', winPath(v))]
  return [join(ROOT, 'python', '.venv', 'Scripts', 'python.exe'), join(ROOT, 'python', '.venv', 'bin', 'python')]
}

// `KCSDK_PHP`는 **디렉터리**를 가리킨다(php.md: `${KCSDK_PHP:-${KCSDK_TOOLS:-$HOME/tools}/php-8.3}`).
const phpDirCandidates = (cmd) => (process.env.KCSDK_PHP ? [join(winPath(process.env.KCSDK_PHP), cmd)] : [])

// Maven·Gradle은 PATH의 `java`가 아니라 **JAVA_HOME이 가리키는 JDK**로 빌드한다.
// 그래서 JAVA_HOME이 설정돼 있으면 그쪽을 먼저 본다 — PATH 앞에 낡은 JDK가 있어도
// 빌드가 도는 것이 실제 동작이고(이 저장소가 정확히 그 구성이다), PATH만 보면
// "JDK 17이라 빌드 불가"라는 거짓 경보를 낸다.
// ⚠️ `KCSDK_JDK21`이 JAVA_HOME보다 앞선다 — CLAUDE.md·rules가 이 저장소 전용 JDK 지정으로
// 그 변수를 문서화하고, 명령 예시도 `JAVA_HOME="${KCSDK_JDK21:-…}"` 꼴로 그것을 우선한다.
// OS 관용 JDK 설치 루트. ⚠️ **버전은 적지 않는다** — 디렉터리를 훑어 `bin/java` 가 있는
// 것만 후보로 낸다(`toolsChildDirs` 와 같은 원칙). 벤더 디렉터리명은 이 저장소의 사실이
// 아니라 OS·설치기의 규약이라 SSOT 규칙에 걸리지 않는다.
//
// ⚠️ 이것이 없으면 doctor 는 **이 PC 에 있는 JDK 21 을 못 보고** `TOO OLD` 라며 설치
// 가이드를 가리킨다 — 이미 가진 것을 또 설치하라는 오진이다(실측 2026-09-22:
// `C:\Program Files\Eclipse Adoptium\jdk-21.0.8.9-hotspot` 가 실재하는데 JAVA_HOME 이
// 17 을 가리켜 17 에서 멈췄다). `.claude/rules/java.md` 가 처방하는 유일한 해법이
// 「doctor 가 찾아준 JDK 21 을 KCSDK_JDK21 로 export 하라」인데, 찾지 못하면 그 처방은
// 순환이 된다.
function jdkRootProbes() {
  const roots =
    process.platform === 'win32'
      ? [process.env.ProgramFiles, process.env['ProgramFiles(x86)']]
          .filter(Boolean)
          .flatMap((pf) => ['Eclipse Adoptium', 'Java', 'Microsoft', 'Amazon Corretto', 'Zulu', 'BellSoft'].map((v) => join(pf, v)))
      : process.platform === 'darwin'
        ? ['/Library/Java/JavaVirtualMachines']
        : ['/usr/lib/jvm']
  const out = []
  for (const root of roots) {
    if (!existsSync(root)) continue
    let kids
    try {
      kids = readdirSync(root, { withFileTypes: true })
    } catch {
      continue
    }
    for (const d of kids) {
      if (!d.isDirectory()) continue
      // macOS 번들은 `<jdk>/Contents/Home/bin/java` 다.
      for (const mid of ['', 'Contents/Home']) {
        const base = join(root, d.name, mid, 'bin', 'java')
        if (existsExe(base)) out.push([base, ['-version']])
      }
    }
  }
  return out
}

function jdkProbes() {
  const home = process.env.KCSDK_JDK21 || process.env.JAVA_HOME
  const rest = [...probes('java', ['-version']), ...jdkRootProbes()]
  if (!home) return rest
  // Git Bash에서 export하면 `/c/Program Files/...` 꼴로 들어온다(winPath가 되돌린다).
  return [[join(winPath(home), 'bin', 'java'), ['-version']], ...rest]
}

function langs() {
  return {
    java: {
      label: 'Java',
      checks: [
        check('java (JDK)', jdkProbes(), req('java/pom.xml', /<maven\.compiler\.release>\s*(\d+)\s*</, 'maven.compiler.release')),
        check('mvn', probes('mvn', ['-v']), req('java/pom.xml', /<requireMavenVersion>\s*<version>\s*\[([\d.]+)\s*,/, 'enforcer requireMavenVersion')),
      ],
    },
    python: {
      label: 'Python',
      checks: [
        check(
          'python',
          // 규약(venv 또는 KCSDK_PY) → KCSDK_TOOLS → PATH의 python/python3 순.
          [...probes('python', ['--version'], pyCandidates()), ['python3', ['--version']]],
          req('python/pyproject.toml', /requires-python\s*=\s*"[^"\d]*([\d.]+)"/, 'requires-python'),
        ),
      ],
    },
    node: {
      label: 'Node',
      checks: [check('node', probes('node', ['--version']), req('node/package.json', /"node"\s*:\s*"[^"\d]*([\d.]+)"/, 'engines.node'))],
    },
    go: {
      label: 'Go',
      checks: [check('go', probes('go', ['version']), req('go/go.mod', /^go\s+([\d.]+)/m, 'go 지시자'))],
    },
    dotnet: {
      label: 'C#/.NET',
      checks: [
        check('dotnet (SDK)', probes('dotnet', ['--version']), req('dotnet/Directory.Build.props', /<TargetFramework>\s*net([\d.]+)\s*</, 'TargetFramework')),
      ],
    },
    php: {
      label: 'PHP',
      checks: [
        check('php', probes('php', ['--version'], phpDirCandidates('php')), req('php/composer.json', /"php"\s*:\s*"[^"\d]*([\d.]+)"/, 'require.php')),
        check('composer', probes('composer', ['--version'], phpDirCandidates('composer')), null, '버전 하한 선언 없음 — 존재만 확인'),
      ],
    },
    rust: {
      label: 'Rust',
      checks: [
        check('cargo', probes('cargo', ['--version']), req('rust/Cargo.toml', /rust-version\s*=\s*"([\d.]+)"/, 'rust-version(MSRV)')),
        check('rustc', probes('rustc', ['--version']), req('rust/Cargo.toml', /rust-version\s*=\s*"([\d.]+)"/, 'rust-version(MSRV)')),
      ],
    },
    ruby: {
      label: 'Ruby',
      checks: [
        check('ruby', probes('ruby', ['--version']), req('ruby/keycloak-sdk.gemspec', /required_ruby_version\s*=\s*"[^"\d]*([\d.]+)"/, 'required_ruby_version')),
        check('bundler', probes('bundle', ['--version']), null, '버전 하한 선언 없음 — 존재만 확인'),
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

// 요구를 만족시킨 실행파일이 **환경변수가 가리키는 것이 아닐 때** 그 자리를 못 박는 줄.
// 지금은 JDK 만 해당한다 — 나머지 도구는 버전 하한이 없거나(`composer`) PATH 로 충분하다.
function exportHint(c, win) {
  if (!c.name.startsWith('java') || !win || !isAbsolute(win)) return null
  const home = dirname(dirname(win)) // <jdk>/bin/java → <jdk>
  const declared = process.env.KCSDK_JDK21 || process.env.JAVA_HOME
  if (declared && winPath(declared).replace(/[\\/]+$/, '') === home.replace(/[\\/]+$/, '')) return null
  return `export KCSDK_JDK21="${home}"`
}

function evaluate(c) {
  if (c.name.startsWith('kotlin/gradlew')) {
    const ok = existsSync(join(ROOT, 'kotlin', 'gradlew'))
    return { ...c, status: ok ? 'ok' : 'MISSING', found: ok ? '있음' : null }
  }
  // ⚠️ **첫 성공에서 멈추지 않는다.** 종전에는 `break` 였고, 그래서 JAVA_HOME 이 17 을
  // 가리키면 이 PC 에 있는 JDK 21 을 **보지도 않고** `TOO OLD` 를 냈다(실측 2026-09-22).
  // 요구 버전이 있으면 그것을 **만족하는** 후보를 끝까지 찾고, 없을 때만 처음 찾은 것으로
  // 답한다 — 첫 후보가 이미 만족하면 종전과 같은 자리에서 멈추므로 비용도 그대로다.
  let out = null
  let win = null
  for (const [cmd, args] of c.probes) {
    const r = run(cmd, args)
    if (!r.ok) continue
    if (out === null) {
      out = r.out
      win = cmd
    }
    const v = firstVersion(r.out)
    if (!c.required || (v && gte(v, c.required.version))) {
      out = r.out
      win = cmd
      break
    }
  }
  if (out === null) return { ...c, status: 'MISSING', found: null }
  const found = firstVersion(out)
  if (!found) return { ...c, status: 'UNKNOWN', found: out.split('\n')[0].slice(0, 60) }
  if (c.required && !gte(found, c.required.version)) return { ...c, status: 'TOO OLD', found }
  // 요구를 만족시킨 것이 **환경변수가 가리키는 것이 아니라 doctor 가 찾아낸 경로**라면,
  // 그 자리를 못 박는 export 줄을 그대로 준다 — 「doctor 가 찾아준 것을 export 하라」는
  // 처방이 실제로 수행 가능해진다(`.claude/rules/java.md`·`kotlin.md`).
  const hint = exportHint(c, win)
  return { ...c, status: 'ok', found, ...(hint ? { hint } : {}) }
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
  // ⚠️ 찾아낸 자리를 **그대로 붙여 넣을 수 있는 줄**로 준다. 「doctor 가 찾아준 JDK 21 을
  // export 하라」는 처방이 수행 가능해지는 지점이 여기다.
  if (r.hint) console.log(`  ${' '.repeat(20)}↳ ${r.hint}`)
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
