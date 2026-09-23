#!/usr/bin/env node
// 게시되는 JVM 아티팩트가 **API 표면**까지 선언한 소비자 하한에 묶여 있는지 본다.
//
// 형제 가드와의 분업: `check-jvm-bytecode-floor.mjs` 는 방출된 `.class` 의 major 를 읽는다.
// 그것만으로는 부족하다 — `jvmTarget`(kotlin) 과 `-target`(javac) 은 **클래스파일 버전만**
// 내리고 컴파일은 빌드 JDK 의 부트클래스패스에 링크된 채로 남는다. 그러면 하한에 없는 API 를
// 불러도 컴파일이 통과하고, major 는 정직하게 61 로 나오며, 형제 가드도 초록인데,
// **실제 JDK 17 소비자만** 런타임에 NoSuchMethodError / NoClassDefFoundError 로 죽는다.
// 상수풀을 읽지 않는 한 바이트코드 검사는 이 사고를 구조적으로 볼 수 없다.
//
// API 표면을 함께 묶는 지시어는 셋뿐이고, 이 가드는 **그 셋이 있는가와 값이 하나인가**만 본다:
//   java   : <maven.compiler.release>      — javac `--release`
//   kotlin : -Xjdk-release                 — kotlinc 에서 `--release` 와 같은 역할
//   kotlin : options.release (JavaCompile) — 그 모듈에 섞일 java 소스용
// `jvmTarget` 도 함께 읽는다 — 값이 위 셋과 갈리면 「클래스는 17, API 는 21」이 되기 때문이다.
//
// ⚠️ 하한 숫자를 **박아두지 않는다.** 17→21 로 올리는 것은 정당한 결정이고, 그때 가드가 막으면
// 가드가 꺼진다. 이 가드가 집행하는 것은 「값이 무엇인가」가 아니라 **「네 자리가 한 값인가」**다.
//
// 사용: node scripts/check-jvm-api-surface-pins.mjs [--root=DIR | DIR]

import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs'
import { join, relative } from 'node:path'

const argv = process.argv.slice(2)
const rootArg = argv.find((a) => a.startsWith('--root='))
const ROOT = rootArg ? rootArg.slice('--root='.length) : (argv.find((a) => !a.startsWith('--')) ?? '.')

const errors = []
const fail = (code, ...lines) => {
  errors.push(code)
  console.error(`::error::${code}`)
  for (const l of lines) console.error(`  ${l}`)
}

if (!existsSync(ROOT) || !statSync(ROOT).isDirectory()) {
  fail('missing-root', `루트가 디렉터리가 아니다: ${ROOT}`)
  process.exit(1)
}

const rel = (p) => relative(ROOT, p).replace(/\\/g, '/')
const readIf = (p) => (existsSync(p) && statSync(p).isFile() ? readFileSync(p, 'utf8') : null)

// ── 읽는 자리 ───────────────────────────────────────────────────────────────
// ⚠️ 두 레인의 **루트 빌드 파일**만 본다. 하네스(`harness/apps/kotlin`)는 게시되지 않으므로
// 소비자 하한과 무관하고, 여기 끌어들이면 정당한 하네스 변경이 이 가드를 깨운다.
const JAVA_POM = join(ROOT, 'java', 'pom.xml')
const KOTLIN_BUILD = join(ROOT, 'kotlin', 'build.gradle.kts')

const javaPom = readIf(JAVA_POM)
const kotlinBuild = readIf(KOTLIN_BUILD)

if (javaPom === null) fail('missing-build-file', `없다: ${rel(JAVA_POM)}`, '파일이 옮겨졌다면 이 가드의 경로를 함께 옮겨라 — 없는 것을 통과로 읽지 않는다.')
if (kotlinBuild === null) fail('missing-build-file', `없다: ${rel(KOTLIN_BUILD)}`)
if (errors.length) process.exit(1)

// ── 네 지시어 ───────────────────────────────────────────────────────────────
// 각 항목: 어디서 · 무엇을 · 어떤 정규식으로. 「없으면 missing-pin」이 규칙이다.
const PINS = [
  { file: rel(JAVA_POM), text: javaPom, label: 'maven.compiler.release', re: /<maven\.compiler\.release>\s*(\d+)\s*<\/maven\.compiler\.release>/g },
  { file: rel(KOTLIN_BUILD), text: kotlinBuild, label: 'jvmTarget', re: /jvmTarget[^\n]*?JVM_(\d+)/g },
  { file: rel(KOTLIN_BUILD), text: kotlinBuild, label: '-Xjdk-release', re: /-Xjdk-release=(\d+)/g },
  { file: rel(KOTLIN_BUILD), text: kotlinBuild, label: 'options.release', re: /options\.release[^\n]*?\(\s*(\d+)\s*\)/g },
]

const seen = new Map() // 값 → 그 값을 말한 자리들
for (const pin of PINS) {
  const hits = [...pin.text.matchAll(pin.re)].map((m) => m[1])
  if (hits.length === 0) {
    fail(
      'missing-pin',
      `${pin.file} 에 \`${pin.label}\` 이 없다.`,
      '이 지시어가 빠지면 클래스파일 버전은 그대로 내려가도 **API 표면이 빌드 JDK 에 묶인 채로**',
      '남는다 — 빌드도 CI 도 바이트코드 가드도 초록인데 소비자만 런타임에 죽는다.',
    )
    continue
  }
  for (const h of hits) {
    if (!seen.has(h)) seen.set(h, [])
    seen.get(h).push(`${pin.file}:${pin.label}`)
  }
}

// ── 약한 형태로의 교체 ──────────────────────────────────────────────────────
// `--release` 를 `source`/`target` 으로 바꾸면 값은 그대로인데 API 표면이 풀린다.
// 「지시어가 있는가」만 보면 이 교체를 통과시키므로 **따로** 본다.
const poms = []
const walkPoms = (d) => {
  let entries
  try {
    entries = readdirSync(d, { withFileTypes: true })
  } catch {
    return
  }
  for (const e of entries) {
    if (e.name === 'target' || e.name === 'node_modules' || e.name === '.git') continue
    const p = join(d, e.name)
    if (e.isDirectory()) walkPoms(p)
    else if (e.name === 'pom.xml') poms.push(p)
  }
}
walkPoms(join(ROOT, 'java'))

if (poms.length === 0) {
  // 공허 하한은 **규칙**이다 — 「java 레인이 있으면 pom 이 최소 하나」. 개수를 박지 않는다.
  fail('vacuous-scan', `${rel(join(ROOT, 'java'))} 아래에서 pom.xml 을 하나도 못 찾았다 — 약한 핀 검사가 공허하다.`)
}

for (const p of poms) {
  const t = readFileSync(p, 'utf8')
  // ⚠️ 정규식을 **문자열로 짓지 않는다** — `.` 하나만 이스케이프하는 `replace` 는 백슬래시를
  // 놓쳐서 CodeQL `js/incomplete-sanitization` 이 high 로 잡는다(실제로 잡혔다). 여기서는
  // 찾는 것이 리터럴 태그이므로 정규식 자체가 필요 없다.
  for (const weak of ['maven.compiler.source', 'maven.compiler.target']) {
    if (t.includes(`<${weak}>`)) {
      fail('weaker-pin', `${rel(p)} 가 \`${weak}\` 를 쓴다 — \`maven.compiler.release\` 로만 핀해야 API 표면이 함께 묶인다.`)
    }
  }
  // 플러그인 **설정** 안의 <source>/<target> 도 같은 교체다(프로퍼티만 보면 놓친다).
  // 전체 XML 을 파싱하지 않고 해당 <plugin> 블록만 잘라서 본다 — 대상이 좁아 오탐이 없다.
  let i = t.indexOf('maven-compiler-plugin')
  while (i !== -1) {
    const end = t.indexOf('</plugin>', i)
    const block = end === -1 ? t.slice(i) : t.slice(i, end)
    // 같은 이유로 리터럴 정규식이다 — 이름을 끼워 넣어 만들지 않는다.
    for (const [weak, re] of [
      ['source', /<source>\s*\d/],
      ['target', /<target>\s*\d/],
    ]) {
      if (re.test(block)) {
        fail('weaker-pin', `${rel(p)} 의 maven-compiler-plugin 설정이 \`<${weak}>\` 를 쓴다 — \`<release>\` 여야 API 표면이 묶인다.`)
      }
    }
    i = t.indexOf('maven-compiler-plugin', i + 1)
  }
}

// ── 네 자리가 한 값인가 ─────────────────────────────────────────────────────
// CLAUDE.md 의 「JVM 짝은 **함께** 움직인다」가 여기서 집행된다. 한쪽만 내리면 JDK 17 소비자가
// 두 아티팩트 중 하나에서 UnsupportedClassVersionError 를 맞는다.
if (seen.size > 1) {
  fail(
    'floor-disagreement',
    `JVM 하한이 갈렸다 — 한 값이어야 한다.`,
    ...[...seen.entries()].sort((a, b) => Number(a[0]) - Number(b[0])).map(([v, where]) => `${v}: ${where.join(' · ')}`),
  )
}

if (errors.length) {
  console.error('')
  console.error('  다시 재는 법: 게시본이 실제로 무엇에 묶였는지는 태그가 소유한다 —')
  console.error('    git show <태그>:java/pom.xml | grep maven.compiler.release')
  console.error('    git show <태그>:kotlin/build.gradle.kts | grep -E "jvmTarget|Xjdk-release|options.release"')
  process.exit(1)
}

const floor = [...seen.keys()][0]
console.log(`ok   JVM API 표면 핀 ${PINS.length}자리가 모두 ${floor} 로 일치 — pom ${poms.length}개에 약한 핀 없음`)
