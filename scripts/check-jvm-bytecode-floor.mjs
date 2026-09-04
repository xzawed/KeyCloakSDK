#!/usr/bin/env node
// 게시되는 JVM 아티팩트의 **클래스파일 버전**이 선언한 소비자 하한을 넘지 않는지 본다.
//
// 왜 필요한가: 두 JVM 레인 모두 **JDK 21 로 빌드하고 17 을 방출**한다(java 는
// `maven.compiler.release=17`, kotlin 은 `jvmTarget=17` + `-Xjdk-release=17`). 그 설정 중 하나만
// 빠져도 빌드는 성공하고 CI 도 초록인데 **major 65 짜리 jar 가 나간다** — 그러면 JDK 17 소비자만
// `UnsupportedClassVersionError` 로 죽는다. CI 가 21 에서 도는 한 그 사고는 CI 에 보이지 않는다.
//
// 특히 kotlin 은 `jvmToolchain(21)` 이 바이트코드 타깃까지 21 로 끌고 가므로, `jvmTarget` 한 줄을
// 지우면 조용히 21 로 되돌아간다. 그 한 줄을 지키는 것이 이 가드다.
//
// 사용: node scripts/check-jvm-bytecode-floor.mjs <디렉터리…> [--max-major=61] [--min-classes=N]

import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const argv = process.argv.slice(2)
const num = (name, dflt) => {
  const hit = argv.find((a) => a.startsWith(`${name}=`))
  if (hit === undefined) return dflt
  const n = Number(hit.slice(name.length + 1))
  if (!Number.isFinite(n)) {
    console.error(`::error::bad-arg`)
    console.error(`  ${name} 의 값이 수치가 아니다: ${hit}`)
    process.exit(1)
  }
  return n
}
const MAX_MAJOR = num('--max-major', 61) // 61 = Java 17
const MIN_CLASSES = num('--min-classes', 1)
const dirs = argv.filter((a) => !a.startsWith('--'))

if (dirs.length === 0) {
  console.error('::error::usage')
  console.error('  node scripts/check-jvm-bytecode-floor.mjs <디렉터리…> [--max-major=61] [--min-classes=N]')
  process.exit(1)
}

// ⚠️ Multi-Release jar 의 `META-INF/versions/<n>/` 아래는 **의도적으로** 높은 버전이다.
// 그것까지 잡으면 정당한 MR-jar 를 막게 되므로 제외하고, 제외했다는 사실을 출력한다.
const isMultiRelease = (p) => /META-INF[\\/]versions[\\/]/.test(p)

const found = []
let skippedMR = 0
const walk = (d) => {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    const p = join(d, e.name)
    if (e.isDirectory()) walk(p)
    else if (e.name.endsWith('.class')) {
      if (isMultiRelease(p)) { skippedMR++; continue }
      const b = readFileSync(p)
      if (b.length < 8) continue
      found.push({ p, major: b.readUInt16BE(6) })
    }
  }
}

for (const d of dirs) {
  if (!existsSync(d) || !statSync(d).isDirectory()) {
    console.error('::error::missing-dir')
    console.error(`  디렉터리가 없다: ${d}`)
    console.error('  빌드보다 먼저 돌았거나 산출 경로가 바뀌었다 — 0개를 훑고 통과시키지 않는다.')
    process.exit(1)
  }
  walk(d)
}

// 공허성 하한 — 산출 경로가 바뀌면 0개를 훑고 「위반 없음」이 된다. 이 부류가 이 저장소의 단골이다.
if (found.length < MIN_CLASSES) {
  console.error('::error::vacuous-scan')
  console.error(`  클래스를 ${found.length}개만 찾았다(기대 ${MIN_CLASSES}개 이상): ${dirs.join(' ')}`)
  console.error('  0개를 훑고 통과하면 이 가드는 있으나 마나다.')
  process.exit(1)
}

const over = found.filter((f) => f.major > MAX_MAJOR)
const hist = {}
for (const f of found) hist[f.major] = (hist[f.major] || 0) + 1
const label = (m) => (m === 61 ? 'Java 17' : m === 65 ? 'Java 21' : m === 69 ? 'Java 25' : `major ${m}`)

console.log(
  `JVM 바이트코드 하한: ${found.length}개 클래스 · 상한 major ${MAX_MAJOR}(${label(MAX_MAJOR)})` +
    (skippedMR > 0 ? ` · Multi-Release 제외 ${skippedMR}개` : ''),
)
for (const [m, n] of Object.entries(hist).sort((a, b) => a[0] - b[0])) {
  console.log(`  major ${m} (${label(Number(m))}): ${n}개`)
}

if (over.length > 0) {
  console.error(`::error::bytecode-above-floor`)
  console.error(`  선언한 소비자 하한보다 높은 클래스가 ${over.length}개다 — JDK ${MAX_MAJOR === 61 ? 17 : '하한'} 소비자가 UnsupportedClassVersionError 로 죽는다.`)
  for (const f of over.slice(0, 10)) console.error(`    ${f.p} → major ${f.major} (${label(f.major)})`)
  if (over.length > 10) console.error(`    … 외 ${over.length - 10}개`)
  console.error('  java: maven.compiler.release · kotlin: jvmTarget + -Xjdk-release 를 확인하라.')
  process.exit(1)
}
console.log('하한 위반 없음')
