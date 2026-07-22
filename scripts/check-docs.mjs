#!/usr/bin/env node
// 문서-소스 드리프트 가드. 산문을 읽지 않는다 — HTML 주석 앵커가 선언한 좌표만
// 읽고 값은 빌드 파일에서 추출해 대조한다. 기대값을 이 스크립트에 적지 않으므로
// 가드 자신은 드리프트할 수 없다.
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve, relative } from 'node:path'

const ROOT = resolve(process.argv[2] ?? '.')
const SKIP = new Set(['.git', 'node_modules', 'vendor', 'target', 'build', 'dist', '.gradle'])

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name)) continue
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (name.endsWith('.md')) out.push(p)
  }
  return out
}

// "org.example:alpha" -> "1.2.3"
function fromGradle(t) {
  const m = new Map()
  for (const x of t.matchAll(/["']([\w.\-]+:[\w.\-]+):([\w.\-]+)["']/g)) m.set(x[1], x[2])
  return m
}
function fromPom(t) {
  const props = new Map()
  for (const x of t.matchAll(/<([\w.\-]+)>([^<>\s]+)<\/\1>/g)) props.set(x[1], x[2])
  const m = new Map()
  for (const d of t.matchAll(/<dependency>([\s\S]*?)<\/dependency>/g)) {
    const g = /<groupId>([^<]+)<\/groupId>/.exec(d[1])
    const a = /<artifactId>([^<]+)<\/artifactId>/.exec(d[1])
    const v = /<version>([^<]+)<\/version>/.exec(d[1])
    if (!g || !a || !v) continue
    let ver = v[1].trim()
    const pm = /^\$\{(.+)\}$/.exec(ver)
    if (pm) ver = props.get(pm[1]) ?? ver
    m.set(`${g[1].trim()}:${a[1].trim()}`, ver)
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
function fromCsproj(t) {
  const m = new Map()
  for (const x of t.matchAll(/<PackageReference\s+Include="([^"]+)"\s+Version="([^"]+)"/g)) m.set(x[1], x[2])
  return m
}

function extract(sourceRel) {
  const text = readFileSync(join(ROOT, sourceRel), 'utf8')
  if (sourceRel.endsWith('.gradle.kts')) return fromGradle(text)
  if (sourceRel.endsWith('pom.xml')) return fromPom(text)
  if (sourceRel.endsWith('package.json')) return fromPackageJson(text)
  if (sourceRel.endsWith('.csproj')) return fromCsproj(text)
  throw new Error(`no extractor for ${sourceRel}`)
}

function parseAttrs(s) {
  const o = {}
  for (const m of s.matchAll(/([\w-]+)=(\S+)/g)) o[m[1]] = m[2]
  return o
}

// 앵커 바로 뒤의 표에서 (좌표, 버전) 쌍을 뽑는다. 좌표는 행의 첫 백틱 토큰,
// 버전은 마지막 셀이다.
function rowsAfter(lines, startIdx) {
  const rows = []
  for (let i = startIdx; i < lines.length; i++) {
    const l = lines[i]
    if (!l.trim()) { if (rows.length) break; else continue }
    if (!l.trimStart().startsWith('|')) { if (rows.length) break; else continue }
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
  for (let i = 0; i < lines.length; i++) {
    const a = /<!--\s*doc-guard:\s*(.*?)\s*-->/.exec(lines[i])
    if (!a) continue
    anchors++
    const attrs = parseAttrs(a[1])
    const min = Number(attrs.min ?? 1)
    let source
    try {
      source = extract(attrs.source)
    } catch (e) {
      errors.push(`${rel}:${i + 1} 소스 추출 실패 (${attrs.source}): ${e.message}`)
      continue
    }
    const rows = rowsAfter(lines, i + 1)
    let checked = 0
    for (const { coord, ver } of rows) {
      const actual = source.get(coord)
      if (actual === undefined) {
        errors.push(`${rel}:${i + 1} 좌표 '${coord}' 를 ${attrs.source} 에서 찾지 못함`)
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
