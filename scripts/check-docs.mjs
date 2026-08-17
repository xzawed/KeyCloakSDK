#!/usr/bin/env node
// 문서-소스 드리프트 가드. 산문을 읽지 않는다 — HTML 주석 앵커가 선언한 좌표만
// 읽고 값은 빌드 파일에서 추출해 대조한다. 기대값을 이 스크립트에 적지 않으므로
// 가드 자신은 드리프트할 수 없다.
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve, relative, dirname } from 'node:path'

// .superpowers는 gitignore된 작업 스크래치(실제 문서가 아님). .venv/venv/site-packages는
// 파이썬 가상환경(+ 그 안의 vendored 서드파티 패키지)이라 실제 문서가 아니다 — 이게 없으면
// python/.venv/Lib/site-packages/**의 README/NOTICE가 검사 5(링크)에 걸려 거짓 경고를 낸다.
const SKIP = new Set([
  '.git',
  'node_modules',
  'vendor',
  'target',
  'build',
  'dist',
  '.gradle',
  '.superpowers',
  '.venv',
  'venv',
  'site-packages',
])
// scripts/test/fixtures/**는 가드 자신의 테스트 입력이다 — 그 안의 source= 경로는
// 격리된 임시 디렉터리(테스트가 mktemp로 만드는) 기준 상대경로라 저장소 루트를
// 걸을 때 해석 대상이 아니다. 이름이 아니라 정확한 상대경로로 제외해야
// ruby/spec/fixtures 같은 무관한 "fixtures" 디렉터리까지 함께 가리지 않는다.
const SKIP_PATHS = new Set(['scripts/test/fixtures'])
const MAX_PROP_HOPS = 10 // 순환/장기 속성 체인이 무한루프하지 않도록 하는 반복 상한.
// docs/ 문서 지도. 검사 6(제외 대상)과 검사 9(대조 주체) 둘 다 참조하므로 여기 둔다.
const DOCS_MAP = 'docs/README.md'
// 지도 마지막 칸의 최소 길이(공백·구분자 제외). 품질은 못 보지만 공백/한 단어는 잡는다.
const MIN_INSIGHT_CHARS = 20

// argv 파싱: 위치 인자(루트 경로)와 플래그(--strict·--min-facts=N·--min-anchors=M)를
// 서로 완전히 독립적으로 파싱한다. `process.argv[2]`를 무조건 루트로 가정하면
// `--strict`가 위치 인자 자리에 오는 가장 자연스러운 호출(`check-docs.mjs --strict`,
// 명시적 `.` 없이)에서 그 문자열 자체가 존재하지 않는 디렉터리 경로로 오인되어
// ENOENT로 크래시한다 — 검사 4~6을 --strict로 승격하는 다음 단계의 진입점이 바로 이
// 호출형이라 반드시 고쳐야 하는 부비트랩이다. 루트는 "--로 시작하지 않는 첫 인자"
// (기본 '.')이고, 플래그는 등장 위치와 무관하게 인식된다 — 아래 다섯 호출형이 전부
// 동일하게 동작해야 한다: `check-docs.mjs` · `check-docs.mjs .` · `check-docs.mjs --strict` ·
// `check-docs.mjs . --strict` · `check-docs.mjs --strict .`
let rootArg = null
let STRICT = false
let MIN_FACTS = 0
let MIN_ANCHORS = 0
for (const arg of process.argv.slice(2)) {
  if (arg === '--strict') {
    STRICT = true
  } else if (/^--min-facts=\d+$/.test(arg)) {
    MIN_FACTS = Number(arg.slice('--min-facts='.length))
  } else if (/^--min-anchors=\d+$/.test(arg)) {
    MIN_ANCHORS = Number(arg.slice('--min-anchors='.length))
  } else if (!arg.startsWith('--') && rootArg === null) {
    rootArg = arg
  }
}
// --strict 없으면 검사 4~6(예방적 — 아직 실제 드리프트가 관측된 적 없음)은 경고만 남기고
// 종료코드는 살린다. repo-hygiene.yml은 브랜치 필터 없는 on:push라 즉시 fail-closed로 켜면
// 모든 Dependabot 브랜치가 동시에 빨개진다 — 한 사이클 관찰 후 CI가 --strict를 붙여 승격한다.
// --min-facts/--min-anchors는 기본 0(=미적용, 픽스처 영향 없음)이라 opt-in이다 — CI(doc-facts
// 잡)만 저장소 루트의 실측 하한(현재 14/4)을 명시로 전달해, 앵커나 그 표를 통째로 지워도
// (=검사 자체가 조용히 사라져도) exit 0으로 새지 않게 한다.
const ROOT = resolve(rootArg ?? '.')
const warnings = []

function walkFiles(dir, matches, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name)) continue
    const p = join(dir, name)
    const rel = relative(ROOT, p).replace(/\\/g, '/')
    if (SKIP_PATHS.has(rel)) continue
    if (statSync(p).isDirectory()) walkFiles(p, matches, out)
    else if (matches(name)) out.push(p)
  }
  return out
}
function hasFile(dir, name) {
  try {
    return statSync(join(dir, name)).isFile()
  } catch {
    return false
  }
}
function walk(dir) {
  return walkFiles(dir, (name) => name.endsWith('.md'))
}

// "org.example:alpha" -> "1.2.3"
function fromGradle(t) {
  const m = new Map()
  for (const x of t.matchAll(/["']([\w.\-]+:[\w.\-]+):([\w.\-]+)["']/g)) m.set(x[1], x[2])
  return m
}

// 단일 pom 텍스트에서 <tag>value</tag> 형태의 leaf 프로퍼티를 전부 뽑는다(구조 태그도
// 섞여 들어오지만 해가 없다 — 실제 조회는 ${...} 참조가 명시한 키만 사용한다).
function parsePomProps(t) {
  const props = new Map()
  for (const x of t.matchAll(/<([\w.\-]+)>([^<>]+)<\/\1>/g)) props.set(x[1], x[2].trim())
  return props
}
function parsePomDependencies(t) {
  const deps = []
  for (const d of t.matchAll(/<dependency>([\s\S]*?)<\/dependency>/g)) {
    const g = /<groupId>([^<]+)<\/groupId>/.exec(d[1])
    const a = /<artifactId>([^<]+)<\/artifactId>/.exec(d[1])
    const v = /<version>([^<]+)<\/version>/.exec(d[1])
    if (!g || !a || !v) continue
    deps.push({ groupId: g[1].trim(), artifactId: a[1].trim(), version: v[1].trim() })
  }
  return deps
}
// 값 전체가 정확히 "${name}"이면 속성으로 치환한다. 그 결과가 다시 "${other}"이면
// 재귀적으로 더 따라간다(전이적 속성 참조) — 순환 정의가 있어도 MAX_PROP_HOPS에서
// 멈추므로 무한루프하지 않는다. 끝내 못 찾으면(선언되지 않은 속성) 원래의
// "${name}" 문자열을 그대로 반환한다 — 호출부가 이를 "미해결"로 감지해 에러 처리한다.
function resolveProp(raw, props) {
  let v = raw
  for (let hop = 0; hop < MAX_PROP_HOPS; hop++) {
    const m = /^\$\{([\w.\-]+)\}$/.exec(v)
    if (!m) break
    const next = props.get(m[1])
    if (next === undefined || next === v) break
    v = next
  }
  return v
}
// 앵커가 가리키는 pom.xml에서 위로(부모 방향) 올라가며 리액터의 꼭대기를 찾는다 —
// 조상 디렉터리에도 pom.xml이 있는 동안은 계속 올라간다(ROOT 밖으로는 나가지 않는다).
// 이렇게 해야 앵커가 부모 pom(java/pom.xml)을 가리키든 자식 모듈 pom
// (java/keycloak-sdk-admin/pom.xml)을 가리키든 같은 전체 리액터를 찾는다.
function findReactorRoot(pomAbsPath) {
  let dir = dirname(pomAbsPath)
  while (dir !== ROOT) {
    const parent = dirname(dir)
    if (parent === dir) break // 파일시스템 루트
    if (!hasFile(parent, 'pom.xml')) break // 더 위엔 pom.xml이 없다 — 리액터 경계
    dir = parent
  }
  return dir
}
// pom.xml 소스는 단일 파일이 아니라 "리액터"로 취급한다 — 리액터 꼭대기부터
// 그 아래 모든 pom.xml(부모+자식 모듈)에서 프로퍼티와 dependency를 함께 모은다.
// 부모가 <properties>만 선언하고 자식이 <dependency>만 선언하는 실제 Maven
// 멀티모듈 레이아웃에서도, 앵커가 어느 모듈의 pom.xml을 가리키든 해석되게 하기 위함이다.
//
// 단, 이 reactor-wide 병합은 "같은 좌표를 서로 다른 pom이 서로 다른 값으로
// 선언"하는 경우까지 조용히 하나를 골라선 안 된다 — 그러면 어느 pom이 이겼는지가
// 파일시스템 순회 순서에 좌우되는 조용한 오답(거짓 PASS 또는 거짓 FAIL)이 된다.
// 그래서 병합 도중 같은 좌표에 대해 이미 확정한 버전과 다른 버전을 만나면 그
// 자리에서 즉시 던진다 — 좌표·양쪽 버전·양쪽 pom 경로를 모두 명시해 호출부
// (extract()의 try/catch)가 "소스 추출 실패" 에러로 fail-closed 처리하게 한다.
// 동일한 값을 여러 pom이 반복 선언하는 것은 정상이며 에러가 아니다.
function fromPomReactor(pomAbsPath) {
  const root = findReactorRoot(pomAbsPath)
  const files = new Set([pomAbsPath, ...walkFiles(root, (name) => name === 'pom.xml')])
  const entries = [...files].map((f) => ({ path: f, text: readFileSync(f, 'utf8') }))
  const props = new Map()
  for (const { text } of entries) for (const [k, v] of parsePomProps(text)) props.set(k, v)
  const resolved = new Map() // "groupId:artifactId" -> { version, pomPath } — 충돌 보고용으로 출처 pom도 함께 기억한다.
  for (const { path, text } of entries) {
    for (const dep of parsePomDependencies(text)) {
      const coord = `${dep.groupId}:${dep.artifactId}`
      const ver = resolveProp(dep.version, props)
      const prev = resolved.get(coord)
      if (prev && prev.version !== ver) {
        const prevRel = relative(ROOT, prev.pomPath).replace(/\\/g, '/')
        const curRel = relative(ROOT, path).replace(/\\/g, '/')
        throw new Error(
          `좌표 '${coord}' 가 리액터 안에서 서로 다른 pom에 의해 다른 버전으로 선언됨: ${prev.version} (${prevRel}) vs ${ver} (${curRel}) — 어느 쪽이 진실인지 가드가 임의로 고를 수 없다`,
        )
      }
      resolved.set(coord, { version: ver, pomPath: path })
    }
  }
  const m = new Map()
  for (const [coord, { version }] of resolved) m.set(coord, version)
  return m
}
function fromPackageJson(t) {
  const j = JSON.parse(t)
  const m = new Map()
  for (const sec of ['dependencies', 'devDependencies']) {
    for (const [k, v] of Object.entries(j[sec] ?? {})) m.set(k, v)
  }
  return m
}
// package-lock.json은 선언된 범위(^6 등)가 아니라 실제로 설치되는 해석된 버전을
// 돌려준다(npm v7+ lockfileVersion 2/3의 평탄화된 packages 맵).
function fromPackageLock(t) {
  const j = JSON.parse(t)
  const m = new Map()
  for (const [key, info] of Object.entries(j.packages ?? {})) {
    if (!key.startsWith('node_modules/')) continue
    const name = key.slice('node_modules/'.length)
    if (name.includes('node_modules/')) continue // 중첩 전이 의존성 경로는 스킵(최상위만)
    if (info && typeof info.version === 'string') m.set(name, info.version)
  }
  return m
}
function fromCsproj(t) {
  const m = new Map()
  for (const x of t.matchAll(/<PackageReference\s+Include="([^"]+)"\s+Version="([^"]+)"/g)) m.set(x[1], x[2])
  return m
}

// composer.json의 "vendor/package" -> 버전 범위 문자열(예: "^7.1"·"~2.7"·"0.42.0"). `require`와
// `require-dev`를 병합한다 — 표의 행이 개발전용 좌표(phpunit 등)를 가리키는 경우도 같은 맵에서
// 해석되게 하려는 것뿐, 이 맵 자체가 두 절을 구분하지는 않는다(동일 좌표가 양쪽에 동시에
// 선언되는 경우는 실전에서 없음 — 있다면 뒤 절의 값이 앞을 덮어써 조용히 하나만 남는다).
// JSON이라 파싱은 안전하고, 파일에 비ASCII 설명 문자열이 섞여 있어 항상 UTF-8로 읽는다.
function fromComposer(t) {
  const j = JSON.parse(t)
  const m = new Map()
  for (const sec of ['require', 'require-dev']) {
    for (const [k, v] of Object.entries(j[sec] ?? {})) m.set(k, v)
  }
  return m
}

// Cargo.toml의 [dependencies]/[dev-dependencies](및 그 파생 — 예: target별 조건부 절)
// 섹션에서만 "name" -> 버전 문자열을 뽑는다. [package] 섹션의 `name`/`version`/`edition` 등은
// 크레이트 자신의 메타데이터라 의존성이 아니므로 섹션 헤더를 추적해 배제한다. 두 선언 형태를
// 모두 지원해야 한다 — bare(`name = "=1.2.3"`)와 inline-table
// (`name = { version = "=1.2.3", features = [...] }`, 버전은 `version = "..."` 키가
// 어디 있든 한 줄 안에서 찾는다). TOML 라이브러리 없이 한 줄 단위 정규식으로 충분한 것은
// 이 리포의 Cargo.toml이 각 의존성을 한 줄에 선언하기 때문이다(멀티라인 inline-table은 미지원).
function fromCargo(t) {
  const m = new Map()
  let inDeps = false
  for (const rawLine of t.split(/\r?\n/)) {
    const line = rawLine.trim()
    const section = /^\[([^\]]+)\]$/.exec(line)
    if (section) {
      inDeps = /dependencies/i.test(section[1])
      continue
    }
    if (!inDeps) continue
    const bare = /^([\w-]+)\s*=\s*"([^"]+)"$/.exec(line)
    if (bare) {
      m.set(bare[1], bare[2])
      continue
    }
    const table = /^([\w-]+)\s*=\s*\{.*\bversion\s*=\s*"([^"]+)".*\}$/.exec(line)
    if (table) m.set(table[1], table[2])
  }
  return m
}

// .gemspec의 `spec.add_dependency "name", "range"` / `spec.add_runtime_dependency ...` 행에서
// "name" -> 버전 범위 문자열(예: "~> 2.0")을 뽑는다. `add_development_dependency`는 의도적으로
// 제외한다 — gemspec의 런타임 의존성만 게시된 gem의 설치 그래프(따라서 배포 산출물)에 실리고,
// 개발전용 의존성은 Gemfile 쪽 관심사이기 때문이다.
function fromGemspec(t) {
  const m = new Map()
  for (const x of t.matchAll(/\.add_(?:runtime_)?dependency\s+["']([^"']+)["']\s*,\s*["']([^"']+)["']/g)) {
    m.set(x[1], x[2])
  }
  return m
}

// go.mod의 require 절에서 "module/path" -> "version"을 뽑는다. require 는 두 형태가 모두
// 유효하다 — 단일 줄 `require module/path v1.2.3` 과 괄호 블록 `require (\n\tmodule/path v1.2.3\n)`.
// go mod tidy 가 직접 의존과 // indirect 의존을 서로 다른 require 블록으로 나누는 것이 관례이므로
// **모든** require 블록을 순회해야 한다(한 블록만 보면 간접 의존 좌표가 표에 있어도 "찾지 못함").
// module/go/toolchain/replace/exclude/retract 는 의존성 좌표가 아니므로 무시한다 — 특히
// `go 1.25` 한 줄을 좌표 "go" 로 오인하면 런타임 앵커(RUNTIME.go)와 의존성 맵이 섞이는
// 디코이 버그가 된다(naive 줄 분할 파서가 흔히 빠지는 함정).
// 버전 문자열은 go.mod 원문 그대로 반환한다(선행 `v` 포함, 의사버전
// `v0.0.0-20240101120000-abcdef123456` 도 그대로). 다른 추출기와 같이 정규화는
// normalizeRequirement 에 맡긴다. `// indirect` 주석만 버전 값에서 떼어낸다(맵 키는 남긴다 —
// 문서가 그 좌표를 참조할 수 있으므로; 간접 의존도 핀된 실제 버전이다).
function fromGoMod(t) {
  const m = new Map()
  let inRequire = false
  for (const rawLine of t.split(/\r?\n/)) {
    // 줄 끝 `// ...` 주석을 먼저 떼고 파싱한다 — `// indirect` 가 버전 뒤에 붙는 관례.
    // 모듈 경로는 `//` 를 포함하지 않으므로 첫 `//` 기준 절단이 안전하다.
    const code = rawLine.replace(/\s*\/\/.*$/, '').trim()
    if (!code) continue
    if (inRequire) {
      if (code === ')') {
        inRequire = false
        continue
      }
      const ent = /^(\S+)\s+(\S+)$/.exec(code)
      if (ent) m.set(ent[1], ent[2])
      continue
    }
    // 괄호 블록 시작 — `require (` / `require(` 둘 다 허용(공백 유무).
    if (/^require\s*\($/.test(code)) {
      inRequire = true
      continue
    }
    // 단일 줄 require — 괄호 없는 `require module/path v1.2.3`.
    const single = /^require\s+(\S+)\s+(\S+)$/.exec(code)
    if (single) {
      m.set(single[1], single[2])
      continue
    }
    // module · go · toolchain · replace · exclude · retract · 그 외 지시어는 무시.
  }
  return m
}

// pyproject.toml 의 `[project].dependencies` 와 `[project.optional-dependencies]` 의
// **모든** 그룹을 병합해 "package-name" -> "버전 지정자 원문" 맵을 만든다.
// fromComposer 가 require + require-dev 를 합치는 것과 같은 이유다 — 표 행이 runtime
// 좌표든 dev 좌표든 같은 앵커/맵에서 해석돼야 한다(이 맵 자체가 두 절을 구분하지는
// 않는다).
//
// ⚠️ TOML 라이브러리 없이 섹션·배열 경계를 줄 단위로 추적한다. 이유: 이 파일의 다른
// 추출기도 전부 regex/JSON 이고, 일반 TOML 파서를 들이면 의존성이 늘어난다. 이 리포의
// pyproject 는 의존성을 한 줄에 한 항목으로 쓰므로 그 범위면 충분하다.
//
// ⚠️ 반드시 의존성 배열 **안** 만 본다. 같은 파일의 `classifiers = ["Programming
// Language :: Python :: 3.10"]` 나 `[build-system] requires = ["hatchling"]` 를 스캔하면
// 쓰레기 키가 맵에 들어가 표 행이 조용히 "찾은 것처럼" 통과한다(naive "모든 따옴표
// 문자열" 스캔이 빠지는 함정 — 회귀 테스트에 디코이로 고정).
//
// 항목은 따옴표 문자열 뒤에 `#` 주석이 붙을 수 있다(`"joserfc>=1.7,<2",   # 보안 핵심…`).
// 주석은 따옴표 **밖** 에만 있으므로 먼저 따옴표 내용을 뽑고 그 뒤는 버린다.
// PEP 508 엑스트라(`uvicorn[standard]`)는 배포 이름에 속하지 않으므로 키에서 떼고,
// 환경 마커(`; python_version < '3.11'`)도 값에서 버린다. 지정자 자체는 정규화하지
// 않는다 — `>=7.1,<8` 처럼 쓰인 그대로 돌려주고 대조는 normalizeRequirement 가 한다.
function fromPyproject(t) {
  const m = new Map()
  // 'project' | 'optional' | 'other' — 섹션 밖/미관여 테이블은 other 로 무시.
  let section = 'other'
  let inDepArray = false

  // 따옴표 한 항목을 PEP 508 로 분해해 맵에 넣는다. 지정자 없으면 빈 문자열 값을 남긴다
  // (키는 유지 — "좌표를 찾지 못함" 과 "지정자 없음" 을 구분).
  const addReq = (raw) => {
    // 환경 마커는 `;` 이후 전부 — 마커 안 따옴표는 이미 raw 가 항목 본문이라 첫 `;` 절단이 안전.
    const body = raw.split(';')[0].trim()
    if (!body) return
    // name [extras] version_spec — extras 는 키에서 제외, 지정자는 원문 그대로.
    const ent = /^([\w.-]+)(?:\[[^\]]*\])?\s*(.*)$/.exec(body)
    if (!ent) return
    m.set(ent[1], (ent[2] || '').trim())
  }

  // 한 줄(또는 배열 시작 줄의 `[` 이후 잔여)에서 따옴표 항목만 주워 담는다.
  // ⚠️ 배열 닫는 `]` 는 **따옴표 밖** 에서만 본다 — 항목 안의 PEP 508 extras
  // (`uvicorn[standard]`·`testcontainers[keycloak]`) 가 가진 `]` 를 배열 종료로
  // 오인하면 그 항목 이후가 통째로 잘리고 inDepArray 가 조기 false 가 된다.
  // 또한 환경 마커 안의 작은따옴표(`python_version < '3.11'`) 때문에
  // `["']…["']` 교차 매칭 정규식은 쓸 수 없다 — 연 따옴표와 같은 종류로만 닫는다.
  const absorbQuoted = (fragment) => {
    let i = 0
    while (i < fragment.length) {
      const c = fragment[i]
      if (c === '"' || c === "'") {
        const q = c
        i++
        let content = ''
        while (i < fragment.length && fragment[i] !== q) {
          content += fragment[i]
          i++
        }
        if (i < fragment.length && fragment[i] === q) {
          addReq(content)
          i++ // 닫는 따옴표
        }
        continue
      }
      if (c === ']') return true // 배열 종료(따옴표 밖)
      i++
    }
    return false
  }

  for (const rawLine of t.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) continue

    const sec = /^\[([^\]]+)\]$/.exec(line)
    if (sec) {
      // 새 테이블이면 열려 있던 배열은 끝(비정상 TOML 이어도 다음 섹션으로 누수 금지).
      inDepArray = false
      if (sec[1] === 'project') section = 'project'
      else if (sec[1] === 'project.optional-dependencies') section = 'optional'
      else section = 'other'
      continue
    }

    if (section === 'other') continue

    if (!inDepArray) {
      // [project] 에서는 dependencies 배열만. classifiers/keywords/authors 등은 무시.
      // [project.optional-dependencies] 에서는 그룹 이름 = [ ... ] 전부(dev/test/… 무관).
      let open = null
      if (section === 'project') open = /^dependencies\s*=\s*\[(.*)$/.exec(line)
      else if (section === 'optional') open = /^[\w.-]+\s*=\s*\[(.*)$/.exec(line)
      if (!open) continue
      inDepArray = true
      if (absorbQuoted(open[1])) inDepArray = false
      continue
    }

    // 배열 본문 — 닫는 ] 단독 줄이거나 항목+].
    if (absorbQuoted(line)) inDepArray = false
  }
  return m
}

function extract(sourceRel) {
  const abs = join(ROOT, sourceRel)
  if (sourceRel.endsWith('pom.xml')) return fromPomReactor(abs)
  const text = readFileSync(abs, 'utf8')
  if (sourceRel.endsWith('.gradle.kts')) return fromGradle(text)
  if (sourceRel.endsWith('package-lock.json')) return fromPackageLock(text)
  if (sourceRel.endsWith('composer.json')) return fromComposer(text)
  if (sourceRel.endsWith('package.json')) return fromPackageJson(text)
  if (sourceRel.endsWith('.csproj')) return fromCsproj(text)
  if (sourceRel.endsWith('.gemspec')) return fromGemspec(text)
  if (sourceRel.endsWith('Cargo.toml')) return fromCargo(text)
  if (sourceRel.endsWith('go.mod')) return fromGoMod(text)
  if (sourceRel.endsWith('pyproject.toml')) return fromPyproject(text)
  throw new Error(`no extractor for ${sourceRel}`)
}

// 좌표의 **생태계**. 검사 2는 "같은 좌표를 여러 문서가 다르게 주장하는가"를 보는데, 좌표를
// 맨 문자열로만 키하면 이름이 겹치는 **서로 다른 생태계의 패키지**가 충돌한다 — 실측으로
// 걸린 것: npm `testcontainers`(^12)와 cargo `testcontainers`(0.28.0)는 이름만 같고 아무
// 관계도 없는데 "문서마다 다름"으로 오탐이 났다. 생태계를 키에 넣어 그 부류를 분리한다.
// ⚠️ 같은 생태계 안의 충돌은 그대로 잡힌다(그게 이 검사의 존재 이유다).
function ecosystemOf(sourceRel) {
  if (sourceRel.endsWith('pom.xml') || sourceRel.endsWith('.gradle.kts')) return 'maven'
  if (sourceRel.endsWith('package.json') || sourceRel.endsWith('package-lock.json')) return 'npm'
  if (sourceRel.endsWith('composer.json')) return 'composer'
  if (sourceRel.endsWith('.csproj')) return 'nuget'
  if (sourceRel.endsWith('.gemspec')) return 'rubygems'
  if (sourceRel.endsWith('Cargo.toml')) return 'cargo'
  if (sourceRel.endsWith('go.mod')) return 'gomod'
  if (sourceRel.endsWith('pyproject.toml')) return 'pypi'
  return 'unknown'
}

function parseAttrs(s) {
  const o = {}
  for (const m of s.matchAll(/([\w-]+)=(\S+)/g)) o[m[1]] = m[2]
  return o
}

// 앵커는 자신 바로 뒤의 표만 소유한다 — 앵커와 표의 첫 행 사이에는 빈 줄만
// 허용하고, 비어있지 않은 비-표 줄(산문·헤딩·다른 표 등)을 만나면 즉시 탐색을
// 멈춘다. 그 자리에 표가 없으면 null을 돌려줘 호출부가 에러 처리하게 한다
// (프로즈나 디코이 표를 건너뛰어 엉뚱한 표를 "그 앵커의 표"로 오인하지 않는다).
function tableAt(lines, startIdx) {
  let i = startIdx
  while (i < lines.length && !lines[i].trim()) i++
  if (i >= lines.length || !lines[i].trimStart().startsWith('|')) return null
  const rows = []
  for (; i < lines.length; i++) {
    const l = lines[i]
    if (!l.trim()) break
    if (!l.trimStart().startsWith('|')) break
    const cells = l.split('|').slice(1, -1).map((c) => c.trim())
    if (cells.every((c) => /^:?-+:?$/.test(c))) continue
    const coord = /`([^`]+)`/.exec(l)
    if (!coord) continue
    const ver = cells[cells.length - 1].replace(/[`*]/g, '').trim()
    rows.push({ coord: coord[1], ver })
  }
  return rows
}

// kind=runtime 비교, 그리고(아래 kind=dep 확장 이후) kind=dep 표 행의 문서 주장 ↔ 추출값
// 비교 양쪽 모두, 대조 전에 "맨숫자" 형태로 정규화한다. 추출기는 원문 선언 문자열을 그대로
// 돌려주는데(node ">=22"·ruby ">= 3.2"[연산자 뒤 공백 포함]·php "^8.3"·go "1.25.0"·dotnet
// "net8.0"·rust "=26.6.2"[정확 핀]·ruby gemspec "~> 2.0"[비관적 연산자]) 이 프로젝트의 문서는
// 때로 같은 값을 다른 표기로 쓴다("Node 22+"·"Go 1.25+"처럼 접두 없이, 또는 표에서처럼
// 연산자를 그대로 베껴 쓰기도 함) — 실제 값은 항상 빌드 파일에서 그대로 오므로 이는 포맷
// 정규화이지 값 하드코딩이 아니다. 규칙:
//   1) 앞의 범위 연산자(>=, ~>, =, >, ^, ~)와 그 뒤 공백(있다면)을 제거한다. 순서가 중요하다 —
//      2글자 연산자(">="·"~>")를 그 부분집합인 1글자 연산자(">"·"~")보다 먼저 시도해야
//      "~> 2.0"에서 "~"만 잘려 "> 2.0"이 남는 오정규화를 피한다.
//   2) 언어 접두(dotnet TargetFramework의 "net")를 숫자 앞에서 제거한다.
//   3) 끝의 "+"(문서 관용 "22+"/"1.25+")를 제거한다.
//   4) 점으로 구분된 구성요소가 3개 이상이고 마지막이 "0"이면 그 구성요소를
//      버린다("1.25.0" -> "1.25", go의 3부 버전과 문서의 2부 관용을 맞춘다).
//      단 구성요소가 정확히 2개뿐이면 건드리지 않는다 — dotnet "8.0"이
//      "8"로 더 깎이면 문서가 "8.0"이라고 정확히 쓴 값과 어긋나 버린다.
// 이 정규화는 표기 차이만 흡수한다 — "26.6.2"와 "26.6.3"처럼 실제 값이 다르면 정규화 후에도
// 여전히 다르다(규칙 1~4 어느 것도 마지막 숫자 구성요소 자체를 바꾸지 않는다).
function normalizeVersion(s) {
  let v = s.trim()
  v = v.replace(/^(>=|~>|=|>|\^|~)\s*/, '')
  v = v.replace(/^net(?=\d)/, '')
  v = v.replace(/\+$/, '')
  const parts = v.split('.')
  if (parts.length >= 3 && parts[parts.length - 1] === '0') parts.pop()
  return parts.join('.')
}

// kind=dep 전용 — 위 정규화를 하되 **범위 연산자는 보존**한다. kind=runtime과 갈리는 데는
// 이유가 있다: 런타임 선언에서 `>=22`와 문서 관용 `22+`는 같은 말이라 연산자가 포맷이지만,
// 의존성 선언에서 연산자는 **값 자체**다 — `=26.6.2`(정확 핀)·`~26.6.2`(틸드)·`^26.6.2`(캐럿)는
// 소비자에게 서로 다른 계약이고, 특히 라이브러리에서 정확 핀은 소비자의 의존성 해소를 하드
// 실패시킨다(CLAUDE.md Rust 절).
// ⚠️ 이 함수가 생긴 계기: Rust 3개 크레이트를 정확 핀에서 캐럿/틸드로 바꿨을 때 문서는 여전히
// `=`를 주장하고 있었는데 **이 가드가 통과시켰다** — normalizeVersion이 대조 전에 연산자를
// 떼어내고 있었기 때문이다. 즉 핀 방식 변경은 구조적으로 보이지 않는 드리프트였다.
// ⚠️ 따라서 규칙은 "표 셀을 매니페스트가 쓴 그대로 적는다"이다. cargo에서 맨 `"4.0.1"`과
// `"^4.0.1"`은 의미가 같지만 이 가드는 문자로 대조하므로, 매니페스트를 `^`로 명시하면 표도
// 함께 고쳐야 한다(npm은 맨 `22`와 `^22`가 실제로 다른 의미라 이 엄격함이 오히려 옳다).
function normalizeRequirement(s) {
  const m = /^(>=|~>|=|>|\^|~)\s*/.exec(s.trim())
  return (m ? m[1] : '') + normalizeVersion(s)
}

// 최소 런타임 — 언어별 고정 추출기(좌표가 없는 단일 값)
const RUNTIME = {
  java: ['java/pom.xml', (t) => /<maven\.compiler\.release>([^<]+)</.exec(t)?.[1]],
  kotlin: ['kotlin/build.gradle.kts', (t) => /jvmToolchain\((\d+)\)/.exec(t)?.[1]],
  node: ['node/package.json', (t) => JSON.parse(t).engines?.node],
  go: ['go/go.mod', (t) => /^go\s+([\d.]+)/m.exec(t)?.[1]],
  dotnet: ['dotnet/Directory.Build.props', (t) => /<TargetFramework>([^<]+)</.exec(t)?.[1]],
  php: ['php/composer.json', (t) => JSON.parse(t).require?.php],
  rust: ['rust/Cargo.toml', (t) => /^rust-version\s*=\s*"([^"]+)"/m.exec(t)?.[1]],
  ruby: ['ruby/keycloak-sdk.gemspec', (t) => /required_ruby_version\s*=\s*["']([^"']+)["']/.exec(t)?.[1]],
  python: ['python/pyproject.toml', (t) => /^requires-python\s*=\s*"([^"]+)"/m.exec(t)?.[1]],
}
// 좌표 -> 그 좌표를 선언한 (문서, 버전) 목록. kind=dep 표에서 파싱된 모든 행을
// 앵커·파일과 무관하게 모아, 전체 순회가 끝난 뒤 같은 좌표가 문서마다 다른
// 값을 말하는지 대조한다(검사 2) — 실제 소스와의 대조(검사 1)와 독립적이라,
// 문서에 버전이 하나도 실제와 다르지 않아도(즉 각자 자기 소스와는 일치해도)
// 서로 모순되는 주장이면 잡아낸다.
const seen = new Map()

const errors = []
let facts = 0
let anchors = 0

// 검사 4 — 커버리지 게이트 임계값(문서가 주장한 값 ↔ 빌드 설정). 예방적 검사라 기본은 경고.
// kind=dep 좌표표 방식이 아니라, 각 언어의 정본 툴체인 문서(.claude/rules/<lang>.md)에 있는
// "게이트/gate NN ... NN" 표기 하나를 실제 빌드 설정과 대조하는 좁은 스코프다 — 해당 문서나
// 소스가 없는 트리(가드 자신의 격리된 테스트 픽스처 등)에서는 조용히 건너뛴다(에러 아님).
const COVERAGE = {
  java: [
    'java/pom.xml',
    (t) => [...t.matchAll(/<minimum>([\d.]+)<\/minimum>/g)].map((m) => String(Math.round(Number(m[1]) * 100))),
  ],
  kotlin: ['kotlin/build.gradle.kts', (t) => [...t.matchAll(/minValue\s*=\s*(\d+)/g)].map((m) => m[1])],
  node: ['node/vitest.config.ts', (t) => [...t.matchAll(/(?:lines|branches):\s*(\d+)/g)].map((m) => m[1])],
}
// 문서 텍스트에서 "게이트"/"gate" 낱말이 등장하는 첫 줄을 찾아, 그 낱말 뒤에 나오는 첫 두
// 숫자를 [라인%, 브랜치%] 주장으로 삼는다 — 세 소스 모두 라인 임계값을 브랜치보다 먼저
// 선언하므로(java pom의 LINE limit, kotlin의 LINE rule, node의 `lines:`) 순서가 맞는다.
function firstGateClaim(text) {
  for (const line of text.split(/\r?\n/)) {
    const idx = line.search(/게이트|gate/i)
    if (idx < 0) continue
    const nums = [...line.slice(idx).matchAll(/\d{1,3}/g)].map((m) => m[0])
    if (nums.length >= 2) return [nums[0], nums[1]]
  }
  return null
}
function checkCoverageGates() {
  for (const [lang, [srcRel, pick]] of Object.entries(COVERAGE)) {
    const docRel = `.claude/rules/${lang}.md`
    let docText
    try {
      docText = readFileSync(join(ROOT, docRel), 'utf8')
    } catch {
      continue // 이 언어의 정본 문서가 없는 트리 — 검사 대상 아님.
    }
    const claim = firstGateClaim(docText)
    if (!claim) continue // 이 문서는 게이트를 주장하지 않는다 — 대조할 것이 없다.
    let actual
    try {
      actual = pick(readFileSync(join(ROOT, srcRel), 'utf8'))
    } catch (e) {
      ;(STRICT ? errors : warnings).push(
        `${docRel} ${lang} 커버리지 게이트 주장을 대조하려 했으나 ${srcRel} 읽기 실패: ${e.message}`,
      )
      continue
    }
    if (actual.length < 2) {
      ;(STRICT ? errors : warnings).push(
        `${docRel} ${lang} 커버리지 게이트 검증 실패 — ${srcRel} 에서 라인/브랜치 임계값을 2건 추출하지 못함(추출 ${actual.length}건)`,
      )
      continue
    }
    if (claim[0] !== actual[0] || claim[1] !== actual[1]) {
      ;(STRICT ? errors : warnings).push(
        `${docRel} ${lang} 커버리지 게이트 문서=라인${claim[0]}/브랜치${claim[1]} 실제=라인${actual[0]}/브랜치${actual[1]} (${srcRel})`,
      )
    }
  }
}

// 검사 5 — 상대 링크 대상이 실제로 디스크에 존재하는가. 예방적 검사라 기본은 경고.
// `./`·`../`·선두 `/`뿐 아니라 맨상대경로(CHANGELOG.md, docs/…)도 본다 — 점·슬래시
// 접두가 없으면 구버전은 죽어도 초록이었다(#193). 해석은 그 문서의 부모 디렉터리
// 기준(루트 문서에서는 ROOT 와 같다). ROOT 단독으로 보면 하위 문서의 형제 링크가
// 오탐이다(실측 32건: docs/README.md → guides/… 등).
// 오탐 억제: 스킴(http(s):, mailto: 등)·프로토콜상대(//) ·경로로 볼 근거가 없는
// 식별자는 건너뛴다. 경로 근거 = `/`를 포함하거나 `.md`로 끝남. 순수 앵커(`#…`)는
// 정규식이 `(` 뒤를 `#`에서 끊으므로 애초에 안 잡힌다.
// 펜스(```) 안의 링크 문법은 예시일 뿐 실제 링크가 아니다 — 앵커 스캐너(메인 루프)가
// 펜스를 건너뛰는 것과 동일한 규칙을 여기서도 독립적으로 추적한다(둘은 별개 순회라
// 상태를 공유하지 않는다).
function looksLikeRepoPath(dest) {
  if (!dest) return false
  if (/^[a-z][a-z0-9+.-]*:/i.test(dest)) return false
  if (dest.startsWith('//')) return false
  if (dest.includes('/')) return true
  return /\.md$/i.test(dest)
}

function checkLinks(file, rel, lines) {
  let inFence = false
  for (const line of lines) {
    if (/^\s*```/.test(line)) {
      inFence = !inFence
      continue
    }
    if (inFence) continue
    for (const m of line.matchAll(/\[[^\]]*\]\(([^)#\s]+)/g)) {
      const dest = m[1]
      if (!looksLikeRepoPath(dest)) continue
      const target = resolve(file, '..', dest)
      try {
        statSync(target)
      } catch {
        ;(STRICT ? errors : warnings).push(`${rel} 링크 대상 없음: ${dest}`)
      }
    }
  }
}

// "다른 8개 언어"·"선행 7개 언어"류는 전체 언어 수에 대한 주장이 아니라 "이 언어를 제외한
// 나머지"·"이 언어보다 먼저 추가된 언어들"을 가리키는 상대 기수다 — 언어가 하나 늘 때마다
// 이 문구도 전부 갱신해야 하는 건 아니므로(무의미한 수정 부담) 구조적으로 대조 대상이 아니다.
// 숫자 바로 앞(공백 제외)이 이 마커 중 하나로 끝나면 검사 6에서 건너뛴다.
const RELATIVE_COUNT_MARKERS = ['다른', '그 외', '나머지', '선행', '외']

// 검사 6 — "N개 언어" 기수가 scripts/lib/deploy-facts.sh 의 DEPLOY_LANGS 와 맞는가. 예방적
// 검사라 기본은 경고. docs/superpowers/** 와 (자가테스트 픽스처가 합성하는)
// docs/governance/history.md·docs/governance/verification-log*.md ·CHANGELOG.md 는
// 그 시절 언어 수를 정당하게 말하는 이력 문서라 제외한다. 운영 트리에는 history.md·
// verification-log* 가 더 이상 없지만, 픽스처가 같은 경로를 만들어 제외가 공허하지
// 않음을 증명하므로 분기를 지우지 않는다. ⚠️ CHANGELOG.md 를 뒤늦게 넣은 이유:
// 항목마다 날짜가 붙은 append-only 이력이라 "8개 언어 하네스 (2026-07-07)"는
// **당시 사실로 옳다**. 제외 전에는 언어가 하나 늘 때마다 과거 항목이 자동으로
// 경고가 됐고(9번째 Kotlin 추가 시 실제로 2건 발생), 그걸 없애는 유일한 방법이
// **이력을 거짓으로 고쳐 쓰는 것**이라 가드가 잘못된 수정을 유도하고 있었다.
// 상대 기수(위 RELATIVE_COUNT_MARKERS)도 구조적으로
// 총 언어 수와 무관하므로 제외한다 — "9개 언어" · "8개 언어 폴리글랏"처럼 전체 언어 수를
// 절대값으로 주장하는 문구만 대조 대상이다.
// ⚠️ 지역 변수를 `facts`로 짓지 말 것 — 모듈 스코프의 카운터 `let facts`를 섀도잉한다.
function checkCardinality() {
  let deployFacts
  try {
    deployFacts = readFileSync(join(ROOT, 'scripts/lib/deploy-facts.sh'), 'utf8')
  } catch {
    return // 이 트리엔 배포사실 SSOT가 없다(가드 자신의 격리된 테스트 픽스처 등) — 스킵.
  }
  const m = /DEPLOY_LANGS="([^"]+)"/.exec(deployFacts)
  if (!m) {
    ;(STRICT ? errors : warnings).push('scripts/lib/deploy-facts.sh 에서 DEPLOY_LANGS 를 찾지 못함')
    return
  }
  const n = m[1].trim().split(/\s+/).length
  for (const f of walk(ROOT)) {
    const rel = relative(ROOT, f).replace(/\\/g, '/')
    if (rel.startsWith('docs/superpowers/')) continue // 진행 계획·이력 문서는 당시 기준이 맞다
    if (rel === 'docs/governance/history.md') continue // 픽스처용 — 운영 트리엔 없음
    if (/^docs\/governance\/verification-log.*\.md$/.test(rel)) continue // 픽스처용 — 운영 트리엔 없음
    if (rel === 'CHANGELOG.md') continue // 위와 동일 — 항목마다 날짜가 붙은 append-only 이력
    // 위와 동일 — docs/README.md 는 **이력 문서들의 색인**이라, 각 줄이 대상 문서의 제목을
    // 인용한다. 제목 자체가 "하네스 5개 언어 확장 설계"처럼 당시 기수를 담고 있고(그게 그 문서의
    // 실제 H1이다) 지도가 그것을 다르게 적으면 오히려 거짓이 된다.
    // ⚠️ 이 면제는 **지도가 현재 상태를 주장하지 않는다는 전제** 위에서만 정당하다. 한때
    // 지도에 "9개 언어 각각의 설치…" 같은 현재값 여섯 줄이 있었고, 그것들은 9가 마침 현재값이라
    // 통과했을 뿐 10번째 언어가 들어오는 순간 조용히 썩었을 것이다 — 그리고 이 면제가 그걸
    // 가렸을 것이다. 지금은 전부 "언어마다"·"각 언어"로 고쳐 두었다. **지도에 현재 언어 수를
    // 다시 적지 말 것** — 그런 사실은 CLAUDE.md 소관이고, 지도의 마지막 칸은 "그 문서에만
    // 있는 것"만 말한다.
    if (rel === DOCS_MAP) continue
    const text = readFileSync(f, 'utf8')
    for (const x of text.matchAll(/(\d+)개 언어/g)) {
      if (Number(x[1]) === n) continue
      // 매치 직전(공백은 무시) 텍스트가 상대 기수 마커로 끝나면 "전체 언어 수" 주장이
      // 아니므로 건너뛴다("다른 8개 언어"·"선행 7개 언어" 등).
      const before = text.slice(Math.max(0, x.index - 8), x.index).trimEnd()
      if (RELATIVE_COUNT_MARKERS.some((mk) => before.endsWith(mk))) continue
      ;(STRICT ? errors : warnings).push(`${rel} "${x[1]}개 언어" ≠ DEPLOY_LANGS ${n}개`)
    }
  }
}

for (const file of walk(ROOT)) {
  const rel = relative(ROOT, file).replace(/\\/g, '/')
  const lines = readFileSync(file, 'utf8').split(/\r?\n/)
  checkLinks(file, rel, lines)
  let inFence = false
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*```/.test(lines[i])) { inFence = !inFence; continue }
    if (inFence) continue // 펜스 안의 앵커 문법은 예시일 뿐 실제 앵커가 아니다.
    // 앵커는 trim한 줄 전체와 정확히 일치해야 한다 — 앵커 문법을 설명하는 산문이
    // 인라인 백틱으로 같은 줄에 앞뒤 텍스트와 함께 등장하면(예: "- Produces: 앵커
    // 문법 `<!-- doc-guard: ... -->` + 뒤따르는 표.") 그건 선언이 아니라 설명이므로
    // 무시해야 한다. 실제 앵커는 언제나 자신만으로 한 줄을 이룬다.
    const trimmed = lines[i].trim()
    const exact = /^<!--\s*doc-guard:\s*(.*?)\s*-->$/.exec(trimmed)
    if (!exact) {
      // 줄 전체 일치는 아니다. 그래도 앵커 문법이 이 줄 어딘가에 나타난다면 두
      // 갈래뿐이다 — (a) 그 앵커 텍스트가 인라인 백틱 한 쌍으로 통째로 감싸여
      // 있으면 문법을 설명하는 산문(무시, 위 사례와 동일 취급), (b) 그 외의
      // 모든 형태(리스트 불릿 아래 들여쓰기, 후행 텍스트 등 — 백틱 없이 등장)는
      // 선언처럼 보이지만 이 가드에게는 절대 인식되지 않는다. 후자를 조용히
      // 넘기면 "선언인데 무효화됨"이 침묵 통과하는 것과 같은 부류의 결함이므로,
      // 명시 에러로 fail-closed 한다.
      const loose = /<!--\s*doc-guard:\s*(.*?)\s*-->/.exec(trimmed)
      if (loose) {
        const before = trimmed[loose.index - 1]
        const after = trimmed[loose.index + loose[0].length]
        const backtickWrapped = before === '`' && after === '`'
        if (!backtickWrapped) {
          errors.push(
            `${rel}:${i + 1} 앵커처럼 보이지만 줄 전체와 정확히 일치하지 않아 인식되지 않는다 — 선언이라면 그 줄 하나만으로 앵커여야 하고(들여쓰기·후행 텍스트 불가), 문법을 설명하는 산문이라면 인라인 백틱으로 전체를 감싸야 한다`,
          )
        }
      }
      continue
    }
    anchors++
    const attrs = parseAttrs(exact[1])

    // kind=runtime은 표가 아니라 앵커 뒤 인라인 코드 한 개(백틱)로 표기된 단일
    // 최소 런타임 값을 검사한다 — kind=dep의 min/표 처리와 무관하므로 여기서
    // 갈라져 별도로 완결 처리하고 continue한다.
    if (attrs.kind === 'runtime') {
      const spec = RUNTIME[attrs.lang]
      if (!spec) {
        errors.push(`${rel}:${i + 1} 알 수 없는 lang=${attrs.lang}`)
        continue
      }
      const [srcRel, pick] = spec
      let actual
      try {
        actual = pick(readFileSync(join(ROOT, srcRel), 'utf8'))
      } catch (e) {
        errors.push(`${rel}:${i + 1} ${srcRel} 읽기 실패: ${e.message}`)
        continue
      }
      if (!actual) {
        errors.push(`${rel}:${i + 1} ${srcRel} 에서 최소 런타임을 추출하지 못함`)
        continue
      }
      // 앵커 뒤 3줄 안의 첫 백틱 스팬이 아니라, 숫자를 포함해 "버전 모양"인
      // 첫 백틱 스팬을 주장으로 삼는다 — 그래야 버전보다 먼저 등장하는
      // 디코이 백틱 용어(코드명 등)를 건너뛴다.
      const claimText = lines.slice(i + 1, i + 4).join('\n')
      const claim = [...claimText.matchAll(/`([^`]+)`/g)].find((m) => /\d/.test(m[1]))
      if (!claim) {
        errors.push(`${rel}:${i + 1} 런타임 앵커 뒤 3줄 안에 숫자를 포함한 백틱 버전 표기가 없음`)
        continue
      }
      facts++
      if (normalizeVersion(claim[1]) !== normalizeVersion(actual)) {
        errors.push(`${rel}:${i + 1} ${attrs.lang} 최소 런타임 문서=${claim[1]} 실제=${actual} (${srcRel})`)
      }
      continue
    }

    let min
    if (attrs.min === undefined) {
      min = 1
    } else {
      const n = Number(attrs.min)
      if (!Number.isInteger(n) || n < 1) {
        errors.push(`${rel}:${i + 1} min='${attrs.min}' 은 1 이상의 정수가 아님 — fail-closed 탐지기가 무력화됨`)
        continue
      }
      min = n
    }

    let source
    try {
      source = extract(attrs.source)
    } catch (e) {
      errors.push(`${rel}:${i + 1} 소스 추출 실패 (${attrs.source}): ${e.message}`)
      continue
    }

    const rows = tableAt(lines, i + 1)
    if (rows === null) {
      errors.push(`${rel}:${i + 1} 앵커 뒤에 표가 없다`)
      continue
    }

    let checked = 0
    for (const { coord, ver } of rows) {
      // 검사 2용 수집 — 실제 소스 대조와 무관하게, 이 좌표를 이 문서가 무엇이라
      // 주장하는지 전부 기록해 둔다(전체 순회 종료 후 문서 간 대조에 사용).
      // ⚠️ 키는 **생태계 + 좌표**다. 맨 좌표로 키하면 이름이 겹치는 다른 생태계 패키지가
      // 충돌한다(`ecosystemOf` 주석의 npm/cargo `testcontainers` 실측).
      const key = `${ecosystemOf(attrs.source)} ${coord}`
      if (!seen.has(key)) seen.set(key, [])
      seen.get(key).push({ rel, ver, coord })

      const actual = source.get(coord)
      if (actual === undefined) {
        errors.push(`${rel}:${i + 1} 좌표 '${coord}' 를 ${attrs.source} 에서 찾지 못함`)
        continue
      }
      const unresolved = /^\$\{([\w.\-]+)\}$/.exec(actual)
      if (unresolved) {
        errors.push(`${rel}:${i + 1} '${coord}' 버전 속성 \${${unresolved[1]}} 을 ${attrs.source} 리액터에서 해석하지 못함`)
        continue
      }
      checked++
      // 의존성 표는 **연산자까지 포함해** 대조한다(normalizeRequirement — 그 주석에 이유가 있다).
      // 표기 차이(`net` 접두·끝의 `+`·go의 3부 버전 등)는 여전히 흡수하되, 핀 방식(`=` ↔ `^` ↔ `~`)은
      // 값의 일부로 취급한다. 즉 문서 표 셀은 빌드 파일이 쓴 대로 적어야 한다.
      if (normalizeRequirement(actual) !== normalizeRequirement(ver)) {
        errors.push(`${rel}:${i + 1} '${coord}' 문서=${ver} 실제=${actual} (${attrs.source})`)
      }
    }
    if (checked < min) {
      errors.push(`${rel}:${i + 1} 추출 ${checked}건 < min=${min} — 형식이 바뀌어 가드가 무력화됐을 수 있음`)
    }
    facts += checked
  }
}

// 검사 2 — 같은 좌표를 여러 문서가 서로 다른 값으로 주장하면 실패한다. 각자
// 자기 소스와는 일치해도(검사 1 GREEN) 문서끼리 모순되면 그 자체가 결함이다
// (실제로 Java 표 11.37.2 ↔ Kotlin 표 11.38.1 불일치가 사람 손으로 발견됐다).
for (const [key, hits] of seen) {
  const vers = [...new Set(hits.map((h) => h.ver))]
  if (vers.length > 1) {
    // 메시지에는 생태계 접두 없이 좌표만 — 사람이 찾을 문자열은 그것이다.
    errors.push(`좌표 '${hits[0].coord}' (${key.split(' ')[0]}) 가 문서마다 다름: ${hits.map((h) => `${h.rel}=${h.ver}`).join(' vs ')}`)
  }
}

// 검사 8 — 크기 래칫. `<!-- doc-budget: max-bytes=N [max-lines=M] -->`를 담은 문서가 상한을
// 넘으면 실패한다. **목표치가 아니라 래칫이다** — 지금 크기를 상한으로 박아 재성장만 막고,
// 줄일 때마다 사람이 숫자를 함께 내린다(올리는 PR은 그 자체가 리뷰 신호가 된다).
//
// 왜 산문 규칙으로 부족한가: 문서 재편 설계가 CLAUDE.md 목표를 33 KB로 승인했는데,
// 이관 커밋 직후 44 KB였던 파일이 13일 만에 66 KB가 됐다(+50%). 규칙은 있었고 아무도
// 어기려 하지 않았는데도 그렇게 됐다 — 한 줄씩 늘어나는 것을 사람이 알아챌 수 없기
// 때문이다. 기계만 셀 수 있다.
//
// ⚠️ **재는 것은 raw가 아니라 `loadedText()`, 즉 실제로 컨텍스트에 주입되는 부분이다**(2026-08-17).
// 블록 레벨 HTML 주석은 주입 전에 제거되므로 토큰을 1바이트도 쓰지 않는데, raw를 재던 시절에는
// CLAUDE.md의 그 4,116 B(41줄·주석 13개)가 예산을 잠식했다. 이 저장소는 가드·이관의 **설계 근거를
// 블록 주석으로 남기는** 관용을 쓰므로, 여유가 440 B까지 좁아진 상태에서 기준이 틀리면 "근거를
// 지우는 것"이 예산을 맞추는 최소저항 경로가 된다 — 가장 값진 것을 가장 먼저 깎게 만드는 계측이다.
// (선례: Claude Code 자신이 v2.1.211에서 같은 버그를 고쳤다.) 기준을 바꾸면서 상한도 함께 내려
// **여유(440 B)를 그대로 옮겼다** — 안 그러면 이 변경 자체가 조용한 4,116 B 예산 인상이 된다.
//
// `max-lines`는 선택 축이다(공식 권고가 줄 기준이라 바이트만으로는 그 축이 안 보인다). 없으면
// 줄 수를 보지 않아 기존 앵커를 깨지 않는다.
function checkDocBudget() {
  for (const f of walk(ROOT)) {
    const rel = relative(ROOT, f).replace(/\\/g, '/')
    const text = readFileSync(f, 'utf8')
    const m = /<!--\s*doc-budget:([^>]*?)-->/.exec(text)
    if (!m) continue
    const spec = m[1]
    const mb = /max-bytes=(\d+)/.exec(spec)
    const ml = /max-lines=(\d+)/.exec(spec)
    // ⚠️ 앵커는 있는데 max-bytes가 없으면 실패다. 오타 하나(`maxbytes=`)로 래칫이 조용히
    // 사라지는 것이 가드 무력화의 최소저항 경로가 되어서는 안 된다 — 검사 9가 "지도를 지우는
    // 것으로 검사를 없앨 수 없다"를 고정한 것과 같은 이유다.
    if (!mb) {
      errors.push(`${rel}: doc-budget 앵커에 max-bytes=N 이 없다 — 오타 하나로 래칫이 사라져서는 안 된다`)
      continue
    }
    const loaded = loadedText(text)
    const raw = Buffer.byteLength(text, 'utf8')
    const max = Number(mb[1])
    const actual = Buffer.byteLength(loaded, 'utf8')
    if (actual > max) {
      errors.push(
        `${rel}: 적재 ${actual}B > doc-budget ${max}B (초과 ${actual - max}B · raw ${raw}B) — 줄이거나, 늘려야 할 이유가 있다면 앵커의 max-bytes를 함께 올려라(그 변경 자체가 리뷰 대상이다)`,
      )
    }
    if (ml) {
      const maxLines = Number(ml[1])
      const lines = countLines(loaded)
      if (lines > maxLines) {
        errors.push(
          `${rel}: 적재 ${lines}줄 > doc-budget max-lines=${maxLines} (초과 ${lines - maxLines}줄 · raw ${countLines(text)}줄) — 공식 권고는 200줄이다`,
        )
      }
    }
  }
}

// 이 문서에서 **실제로 컨텍스트에 주입되는** 부분. 블록 레벨 HTML 주석은 주입 전에 제거되므로
// 토큰을 1바이트도 쓰지 않는다(code.claude.com/docs/en/memory#how-claude-md-files-load).
// ⚠️ **코드블록 안의 주석은 보존된다**(같은 문서) — 펜스를 무시하고 지우면 예산이 조용히
// 헐거워지고, 하필 주석 규약을 *설명하는* 문서일수록 더 헐거워진다.
// ⚠️ **인라인 주석은 블록이 아니다** — 앞에 본문이 있는 줄은 통째로 적재된다.
// 애매한 경계에서는 전부 **과대계상 쪽**으로 붙였다(그 방향이 예산을 조이는 쪽이다).
function loadedText(text) {
  const lines = text.split('\n')
  const out = []
  let inFence = false
  let inComment = false
  for (const line of lines) {
    const bare = line.replace(/\r$/, '')
    if (inComment) {
      const end = bare.indexOf('-->')
      if (end >= 0) {
        inComment = false
        const rest = bare.slice(end + 3)
        if (rest.trim() !== '') out.push(rest) // 주석이 줄 중간에 끝나면 나머지는 본문이다
      }
      continue
    }
    if (/^[ \t]*(```|~~~)/.test(bare)) {
      inFence = !inFence
      out.push(line)
      continue
    }
    if (!inFence && /^[ \t]*<!--/.test(bare)) {
      if (/-->[ \t]*$/.test(bare)) continue // 한 줄짜리 블록 주석
      if (bare.includes('-->')) {
        out.push(line) // 주석 뒤에 본문이 이어진다 → 블록이 아니다
        continue
      }
      inComment = true
      continue
    }
    out.push(line)
  }
  return out.join('\n')
}

// 내용 줄 수. 끝개행이 만드는 빈 마지막 원소는 줄이 아니다.
function countLines(text) {
  const parts = text.split('\n')
  if (parts.length > 0 && parts[parts.length - 1] === '') parts.pop()
  return parts.length
}

// 검사 9 — docs/ 지도(`docs/README.md`)와 디스크가 **양방향**으로 맞는가.
//
// 한 방향만 검사하면 반대쪽 드리프트가 그대로 통과한다: "지도에 적힌 파일이 존재하는가"만
// 보면 새 문서를 지도에 안 넣는 것을 못 잡고, "모든 파일이 지도에 있는가"만 보면 문서를
// 지우거나 옮긴 뒤 지도를 안 고치는 것을 못 잡는다. 둘 다 실제로 일어나는 방향이라 둘 다 본다.
//
// ⚠️ 조건부 실행이 **공허해지지 않도록** 주의해서 걸었다. `docs/README.md`가 없으면 그냥
// 건너뛰게 하면 지도를 지우는 순간 검사가 사라진다 — 가드를 무력화하는 가장 쉬운 방법이
// 가드가 지키는 파일을 지우는 것이 되어서는 안 된다. 그래서 발동 조건은 지도의 존재가 아니라
// **`docs/` 안에 .md가 하나라도 있는가**다. 지도가 없으면 그 자체가 실패다. `docs/`가 아예
// 없는 트리(가드 자신의 픽스처)에서만 no-op이 된다.
function checkDocsMap() {
  const docsDir = join(ROOT, 'docs')
  let present
  try {
    if (!statSync(docsDir).isDirectory()) return
    present = walk(docsDir)
      .map((f) => relative(ROOT, f).replace(/\\/g, '/'))
      .filter((r) => r !== DOCS_MAP)
  } catch {
    return // docs/ 없음 — 이 저장소의 문서 규약이 적용되지 않는 트리다.
  }
  if (present.length === 0) return
  // ⚠️ 이 스냅샷은 **이 함수가 내는 첫 errors.push보다 앞**이어야 한다. 한때 양방향 연결 검사
  // 뒤에 두었더니, 지도가 없는 파일을 가리키는데도 "62 files linked" 초록 요약이 자기 실패와
  // 나란히 찍혔다(전역 errors.length를 쓰던 이전 판은 그 경우를 옳게 억제했었다).
  const before = errors.length

  const mapPath = join(ROOT, DOCS_MAP)
  let text
  try {
    text = readFileSync(mapPath, 'utf8')
  } catch {
    errors.push(`${DOCS_MAP} 이 없다 — docs/ 아래 ${present.length}개 문서를 가리키는 지도가 있어야 한다`)
    return
  }

  // 지도가 링크한 docs/ 내부 .md 경로. 바깥(../CLAUDE.md 등)과 외부 URL은 대상이 아니다.
  const linked = new Set()
  for (const m of text.matchAll(/\]\(([^)\s]+?\.md)(?:#[^)]*)?\)/g)) {
    const href = m[1]
    if (/^[a-z]+:/i.test(href)) continue
    const rel = relative(ROOT, resolve(dirname(mapPath), href)).replace(/\\/g, '/')
    if (rel.startsWith('docs/')) linked.add(rel)
  }

  for (const r of present) {
    if (!linked.has(r)) {
      errors.push(`${r} 이 ${DOCS_MAP} 에 없다 — 문서를 추가했으면 지도에도 한 줄 넣어라(마지막 칸까지)`)
    }
  }
  for (const r of linked) {
    if (!present.includes(r)) {
      errors.push(`${DOCS_MAP} 가 존재하지 않는 ${r} 을 가리킨다 — 문서를 지우거나 옮겼으면 지도도 고쳐라`)
    }
  }

  // 지도의 **상태 칸**은 손으로 적는 값이라 그대로 두면 또 하나의 복제본이 된다(게시 현황이
  // 그래서 6곳에서 동시에 낡았다). 그래서 상태의 진실 원천을 **각 문서 자신**에 두고 대조한다:
  // 문서 상단의 `<!-- doc-status: X -->` 마커가 있으면 지도의 칸이 그것과 같아야 하고,
  // 마커가 없는 문서(살아있는 운영 문서)는 지도에서 '운영'이어야 한다. 어느 쪽이든 손으로 적은
  // 값 하나가 다른 값 하나와 반드시 마주 보게 되어, 한쪽만 고치면 잡힌다.
  const STATUS_OF = { complete: '완료', active: '진행', living: '운영' }
  const VALID = new Set(Object.values(STATUS_OF))
  let statusChecked = 0
  for (const r of present) {
    // ⚠️ 링크가 등장하는 **아무 행**이나 잡으면 안 된다. 지도 상단의 상태 범례표에도
    // `[CLAUDE.md](../CLAUDE.md)` 같은 링크가 있고 그 행의 첫 칸은 '완료'라서,
    // 단순 `includes` + `find`는 범례를 그 문서의 행으로 오인해 거짓 실패를 냈다(실제로 냈다).
    // 색인 행은 **첫 칸이 그 문서 링크**인 행뿐이다.
    const link = `](${relFromMap(r)})`
    const row = text
      .split('\n')
      .map((l) => l.split('|').map((c) => c.trim()))
      .find((cells) => cells.length > 2 && cells[1].includes(link))
    // ⚠️ 여기서 `continue` 하면 안 된다. 행 매칭이 조용히 깨지면(표 서식을 바꾸거나 정규식이
    // 어긋나면) 대조 대상이 0건이 되고 검사 전체가 공허하게 통과한다 — 이 가드가 막으려는
    // 바로 그 실패다. 모든 문서는 상태 칸을 가진 표 행으로 색인돼야 하고, 아니면 실패다.
    if (!row) {
      errors.push(`${r} 이 ${DOCS_MAP} 의 표 행으로 색인돼 있지 않다 — 첫 칸이 그 문서 링크인 행이 있어야 한다`)
      continue
    }
    const cells = row
    const cell = cells.find((c) => VALID.has(c))
    if (!cell) {
      errors.push(`${DOCS_MAP} 의 ${r} 줄에 상태 칸(${[...VALID].join('/')})이 없다`)
      continue
    }
    // 지도의 존재 이유는 마지막 칸("여기서만 알 수 있는 것")이다. 그런데 검사 9가 새 문서마다
    // 줄을 요구하므로, 최소저항 경로가 **빈 칸으로 한 줄 추가**가 된다 — 가드가 자기가 못 잡는
    // 열화를 적극적으로 유도하는 셈이다. 내용의 고유성은 기계로 못 보지만 공백은 볼 수 있다.
    // (산문으로 "반드시 채워라"라고 적는 것으로는 안 된다 — 이 저장소의 doc-budget 래칫이
    //  존재하는 이유가 정확히 "산문 규칙은 막지 못한다"였다.)
    // ⚠️ 공백·구두점·기호를 **전부** 벗기고 센다. 처음에는 `/[\s—·]/`만 벗겼는데, 마침표·밑줄·
    // 쉼표·하이픈·틸드·별표·불릿을 20개 늘어놓으면 그대로 통과했다(실측 7종). 유니코드 클래스로
    // 벗기면 그런 채움문자는 전부 0자가 된다.
    const last = cells[cells.length - 2] ?? ''
    if (last.replace(/[\s\p{P}\p{S}]/gu, '').length < MIN_INSIGHT_CHARS) {
      errors.push(
        `${DOCS_MAP} 의 ${r} 줄에서 마지막 칸("여기서만 알 수 있는 것")이 비었거나 너무 짧다 — 채울 말이 없다면 그 문서는 다른 문서에 합쳐야 한다는 뜻이다`,
      )
    }
    // ⚠️ `.exec()`로 **첫 매치**를 취하면 안 된다. 본문에 이 규약의 *예시*로 완전한 마커를
    // 적어둔 문서가 생기면 그 예시가 자기 배너보다 앞서 잡혀, 배너 순서 검사와 상태 대조를
    // 둘 다 예시 기준으로 하게 된다(실측: 그 상태로 배너를 지시 뒤로 옮겨도 통과). 마커가 둘
    // 이상이면 어느 것이 진실인지 가드가 임의로 고를 수 없으니 그 자리에서 실패한다.
    const body = readFileSync(join(ROOT, r), 'utf8')
    const all = [...body.matchAll(/<!--\s*doc-status:\s*(\w+)\s*-->/g)]
    if (all.length > 1) {
      errors.push(`${r}: doc-status 마커가 ${all.length}개다 — 어느 것이 문서의 상태인지 가드가 고를 수 없다`)
      continue
    }
    const m = all[0] ?? null
    const declared = m ? STATUS_OF[m[1]] : '운영'
    if (m && !declared) {
      errors.push(`${r} 의 doc-status='${m[1]}' 는 알 수 없는 값이다 (${Object.keys(STATUS_OF).join('/')})`)
      continue
    }
    statusChecked++
    // ⚠️ 완료 배너는 **실행 지시보다 앞에** 있어야 한다. 계획서들은 "REQUIRED SUB-SKILL: …
    // implement this plan task-by-task"로 시작하고 체크박스가 전부 미체크로 남아 있어서,
    // 위에서부터 읽는 에이전트는 배너를 만나기 전에 이미 실행 지시를 받는다. 순서가 뒤집히면
    // 배너는 있으나 마나다 — 존재만 검사하면 그 사실을 못 본다.
    if (m && m[1] === 'complete') {
      const instr = body.indexOf('For agentic workers')
      // ⚠️ `indexOf('doc-status:')`(첫 등장)를 쓰면 안 된다 — 이 규약을 **설명하는** 문서가
      // 본문에서 그 문자열을 언급하는 순간 배너보다 앞선 히트가 생겨 검사가 공허하게 통과한다.
      // 마커 정규식이 실제로 매치한 위치(`m.index`)만이 배너의 자리다.
      if (instr >= 0 && m.index > instr) {
        errors.push(`${r}: 완료 배너가 "For agentic workers" 실행 지시보다 뒤에 있다 — 위에서부터 읽으면 지시를 먼저 받는다`)
      }
    }
    // ⚠️ 위의 마커↔지도 대조는 **둘이 함께 틀리면 침묵한다.** 실제로 그랬다 — 하네스 계획서가
    // 미체크 0 / 체크 69인 채 마커도 '진행' 지도도 '진행'이라 서로 정합이었고, 45 KB짜리 끝난
    // 문서가 「진행」을 주장하는데 가드는 초록이었다. 두 손으로 적은 값을 마주 보게 해도, 둘 다
    // 같은 방향으로 낡으면 아무것도 잡히지 않는다.
    //
    // "이 계획이 끝났는가"에는 외부 SSOT가 없다. 그러나 불변식은 **이미 선언돼 있다** —
    // `docs/README.md` 범례의 「진행 | 아직 열려 있는 작업. **체크박스가 실제 할 일이다**」.
    // 그 문서 자신의 체크박스가 사실상 진실 원천이므로 그것을 집행한다.
    //
    // ⚠️ **한 방향만 건다.** 역("미체크 > 0 ⇒ 반드시 active")은 거짓이다 — 기각한 항목은 미체크로
    // 남는 것이 정상이고(B1·B2·B3·D2가 그렇게 남았다), 그걸 실패시키면 이 가드가 "기각 금지"라는
    // 정책을 새로 만드는 셈이 된다. 가드는 선언된 불변식만 집행하고 정책을 만들지 않는다.
    if (declared === STATUS_OF.active && countOpenTasks(body) === 0) {
      errors.push(
        `${r}: 미체크 항목이 0건인데 doc-status=active('진행')다 — '진행'은 "체크박스가 실제 할 일"이라는 뜻이다. 일이 끝났으면 complete로 내려라`,
      )
    }
    if (cell !== declared) {
      errors.push(
        `${r}: 문서가 선언한 상태='${declared}'${m ? '' : '(마커 없음 → 운영으로 간주)'} ≠ ${DOCS_MAP} 의 '${cell}'`,
      )
    }
  }
  // ⚠️ 전역 `errors.length`를 보면 **다른 검사**가 실패했을 때 이 요약이 안 찍혀 검사 9가
  // 돌기는 했는지 알 수 없다. 이 검사가 낸 실패만 센다.
  if (errors.length === before) {
    console.log(`docs map: ${present.length} files linked, ${statusChecked} statuses cross-checked`)
  }
}
// 지도 안에서 쓰이는 상대경로(docs/ 기준)로 되돌린다.
function relFromMap(rel) {
  return rel.slice('docs/'.length)
}

// 미체크 체크박스(`- [ ]`)의 개수. **펜스 코드블록은 걷어낸다** — 이 규약을 *설명하는* 문서가
// ``` 안에 예시로 `- [ ]` 를 적는 순간 끝난 계획서가 영원히 열린 것처럼 보이기 때문이다.
// doc-status 마커에서 이미 같은 부류에 당했다(본문의 예시가 배너보다 먼저 잡혀 검사가 공허하게
// 통과했다) — 정규식 하나로 세기 전에 그 전례를 먼저 갚는다.
// ⚠️ 여닫이가 안 맞는 펜스는 그 뒤 전부를 코드로 보게 되어 개수가 0으로 떨어진다. 그 방향은
// **가드가 발동하는 쪽**(fail-closed)이라 그대로 둔다 — 조용히 통과하는 것보다 낫다.
function countOpenTasks(body) {
  let inFence = false
  let n = 0
  for (const line of body.split(/\r?\n/)) {
    if (/^[ \t]*(```|~~~)/.test(line)) {
      inFence = !inFence
      continue
    }
    if (!inFence && /^[ \t]*[-*+] \[ \]/.test(line)) n++
  }
  return n
}

// 검사 4·6·8·9 — 파일별 순회와 무관한 전역 대조라 메인 루프 밖에서 한 번만 실행한다.
checkCoverageGates()
checkCardinality()
checkDocBudget()
checkDocsMap()

// 검사 7 — fact/anchor 최저치(floor, --min-facts/--min-anchors로 opt-in). 앵커 주석 하나를
// 지우면서 그 앵커가 소유했던 표까지 함께 남겨두면(=검사 대상 자체가 사라지면) 위의 검사
// 1~6 어느 것도 이를 잡지 못하고 그냥 exit 0 — 유일한 신호는 사람이 보고 눈치채야 하는
// "checked N facts across M anchors" 문구뿐이다. 이 검사는 그 자리를 최후 방어선으로
// 메운다: STRICT 여부와 무관하게 항상 강제한다(경고로 낮추면 이 검사 자체가 무력화된
// "예방적 검사" 신세가 되어 버그를 반복하므로). 기본값 0은 항상 참(facts/anchors는
// 음수일 수 없음)이라 플래그를 안 주면 완전 no-op — 픽스처는 영향받지 않는다.
if (facts < MIN_FACTS) {
  errors.push(`facts ${facts} < --min-facts=${MIN_FACTS} — 앵커나 그 표가 삭제되어 검사 커버리지가 줄었을 수 있음`)
}
if (anchors < MIN_ANCHORS) {
  errors.push(`anchors ${anchors} < --min-anchors=${MIN_ANCHORS} — 앵커 자체가 삭제되었을 수 있음`)
}

for (const w of warnings) console.warn(`::warning::${w}`)

if (errors.length) {
  for (const e of errors) console.error(`::error::${e}`)
  console.error(`문서 드리프트 ${errors.length}건`)
  process.exit(1)
}
console.log(`checked ${facts} facts across ${anchors} anchors`)
