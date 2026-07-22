#!/usr/bin/env node
// 문서-소스 드리프트 가드. 산문을 읽지 않는다 — HTML 주석 앵커가 선언한 좌표만
// 읽고 값은 빌드 파일에서 추출해 대조한다. 기대값을 이 스크립트에 적지 않으므로
// 가드 자신은 드리프트할 수 없다.
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve, relative, dirname } from 'node:path'

const ROOT = resolve(process.argv[2] ?? '.')
const SKIP = new Set(['.git', 'node_modules', 'vendor', 'target', 'build', 'dist', '.gradle'])
const MAX_PROP_HOPS = 10 // 순환/장기 속성 체인이 무한루프하지 않도록 하는 반복 상한.

function walkFiles(dir, matches, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name)) continue
    const p = join(dir, name)
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
function fromPomReactor(pomAbsPath) {
  const root = findReactorRoot(pomAbsPath)
  const files = new Set([pomAbsPath, ...walkFiles(root, (name) => name === 'pom.xml')])
  const texts = [...files].map((f) => readFileSync(f, 'utf8'))
  const props = new Map()
  for (const t of texts) for (const [k, v] of parsePomProps(t)) props.set(k, v)
  const m = new Map()
  for (const t of texts) {
    for (const dep of parsePomDependencies(t)) {
      const ver = resolveProp(dep.version, props)
      m.set(`${dep.groupId}:${dep.artifactId}`, ver)
    }
  }
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
    const a = /<!--\s*doc-guard:\s*(.*?)\s*-->/.exec(lines[i])
    if (!a) continue
    anchors++
    const attrs = parseAttrs(a[1])

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

if (errors.length) {
  for (const e of errors) console.error(`::error::${e}`)
  console.error(`문서 드리프트 ${errors.length}건`)
  process.exit(1)
}
console.log(`checked ${facts} facts across ${anchors} anchors`)
