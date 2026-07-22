#!/usr/bin/env node
// 문서-소스 드리프트 가드. 산문을 읽지 않는다 — HTML 주석 앵커가 선언한 좌표만
// 읽고 값은 빌드 파일에서 추출해 대조한다. 기대값을 이 스크립트에 적지 않으므로
// 가드 자신은 드리프트할 수 없다.
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve, relative, dirname } from 'node:path'

const ROOT = resolve(process.argv[2] ?? '.')
// .superpowers는 gitignore된 작업 스크래치(실제 문서가 아님).
const SKIP = new Set(['.git', 'node_modules', 'vendor', 'target', 'build', 'dist', '.gradle', '.superpowers'])
// scripts/test/fixtures/**는 가드 자신의 테스트 입력이다 — 그 안의 source= 경로는
// 격리된 임시 디렉터리(테스트가 mktemp로 만드는) 기준 상대경로라 저장소 루트를
// 걸을 때 해석 대상이 아니다. 이름이 아니라 정확한 상대경로로 제외해야
// ruby/spec/fixtures 같은 무관한 "fixtures" 디렉터리까지 함께 가리지 않는다.
const SKIP_PATHS = new Set(['scripts/test/fixtures'])
const MAX_PROP_HOPS = 10 // 순환/장기 속성 체인이 무한루프하지 않도록 하는 반복 상한.

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

function extract(sourceRel) {
  const abs = join(ROOT, sourceRel)
  if (sourceRel.endsWith('pom.xml')) return fromPomReactor(abs)
  const text = readFileSync(abs, 'utf8')
  if (sourceRel.endsWith('.gradle.kts')) return fromGradle(text)
  if (sourceRel.endsWith('package-lock.json')) return fromPackageLock(text)
  if (sourceRel.endsWith('package.json')) return fromPackageJson(text)
  if (sourceRel.endsWith('.csproj')) return fromCsproj(text)
  throw new Error(`no extractor for ${sourceRel}`)
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

// kind=runtime 비교 전 문서 주장과 추출값 양쪽을 "맨숫자" 형태로 정규화한다.
// 추출기는 원문 선언 문자열을 그대로 돌려주는데(node ">=22"·ruby ">= 3.2"
// [연산자 뒤 공백 포함]·php "^8.3"·go "1.25.0"·dotnet "net8.0") 이 프로젝트의
// 문서 관용은 "Node 22+"·"Go 1.25+"처럼 다른 표기다 — 실제 값은 항상 빌드
// 파일에서 그대로 오므로 이는 포맷 정규화이지 값 하드코딩이 아니다. 규칙:
//   1) 앞의 범위 연산자(>=, >, ^, ~)와 그 뒤 공백(있다면)을 제거한다.
//   2) 언어 접두(dotnet TargetFramework의 "net")를 숫자 앞에서 제거한다.
//   3) 끝의 "+"(문서 관용 "22+"/"1.25+")를 제거한다.
//   4) 점으로 구분된 구성요소가 3개 이상이고 마지막이 "0"이면 그 구성요소를
//      버린다("1.25.0" -> "1.25", go의 3부 버전과 문서의 2부 관용을 맞춘다).
//      단 구성요소가 정확히 2개뿐이면 건드리지 않는다 — dotnet "8.0"이
//      "8"로 더 깎이면 문서가 "8.0"이라고 정확히 쓴 값과 어긋나 버린다.
function normalizeVersion(s) {
  let v = s.trim()
  v = v.replace(/^(>=|>|\^|~)\s*/, '')
  v = v.replace(/^net(?=\d)/, '')
  v = v.replace(/\+$/, '')
  const parts = v.split('.')
  if (parts.length >= 3 && parts[parts.length - 1] === '0') parts.pop()
  return parts.join('.')
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

for (const file of walk(ROOT)) {
  const rel = relative(ROOT, file).replace(/\\/g, '/')
  const lines = readFileSync(file, 'utf8').split(/\r?\n/)
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
      if (!seen.has(coord)) seen.set(coord, [])
      seen.get(coord).push({ rel, ver })

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
      if (actual !== ver) {
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
for (const [coord, hits] of seen) {
  const vers = [...new Set(hits.map((h) => h.ver))]
  if (vers.length > 1) {
    errors.push(`좌표 '${coord}' 가 문서마다 다름: ${hits.map((h) => `${h.rel}=${h.ver}`).join(' vs ')}`)
  }
}

if (errors.length) {
  for (const e of errors) console.error(`::error::${e}`)
  console.error(`문서 드리프트 ${errors.length}건`)
  process.exit(1)
}
console.log(`checked ${facts} facts across ${anchors} anchors`)
