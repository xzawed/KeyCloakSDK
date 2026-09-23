#!/usr/bin/env node
// **게시된 바이트**를 받아 클래스파일 버전을 읽는다 — 태그까지가 한계였던 사슬의 마지막 칸.
//
// 사슬(각 칸을 서로 다른 가드가 소유한다):
//   문서 ↔ 태그          `check-docs.mjs` 의 `kind=runtime` 앵커
//   태그 ↔ 소스 핀       `check-jvm-api-surface-pins.mjs`
//   태그 ↔ **게시 바이트**  이 파일
// 앞의 둘은 저장소 안만 본다. 릴리스 워크플로가 다른 JDK 로 빌드했거나, 업로드가 깨졌거나,
// 누가 Portal 에 다른 바이트를 올렸다면 **소비자가 받는 것만 다르고 저장소는 전부 초록**이다.
//
// ⚠️ **대조 대상은 SSOT 가 아니라 레지스트리다.** `df_published_version` 은 런북 §4 1단계에서
// **태그보다 먼저** 올라가므로 그것은 *의도*이지 현재 사실의 주장이 아니다 — 그것을 기준으로
// 「게시됐는데 404 다」를 판정하면 사람이 Portal 을 누르기 전 구간 내내 거짓 빨강이 난다.
// 그래서 검사 대상은 **`maven-metadata.xml` 이 실제로 싣고 있는 버전**이고, 각 버전의 하한은
// **그 버전의 태그**가 소유한다. 상수는 어디에도 없다.
//
// 사용:
//   node scripts/check-published-jvm-floor.mjs [--base=<URL|디렉터리>] [--lang=java,kotlin]
//   --base 가 디렉터리면 네트워크를 쓰지 않는다(자가테스트가 그 경로로 전부 검증한다).

import { readFileSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { inflateRawSync } from 'node:zlib'

const argv = process.argv.slice(2)
const opt = (name, dflt) => {
  const hit = argv.find((a) => a.startsWith(`${name}=`))
  return hit === undefined ? dflt : hit.slice(name.length + 1)
}
const BASE = opt('--base', 'https://repo1.maven.org/maven2')
const ONLY = opt('--lang', '')
const ROOT = opt('--root', '.')
const OFFLINE = !/^https?:\/\//.test(BASE)

const errors = []
const notes = []
const fail = (code, ...lines) => {
  errors.push(code)
  console.error(`::error::${code}`)
  for (const l of lines) console.error(`  ${l}`)
}

// ── 좌표는 SSOT 가 소유한다 ─────────────────────────────────────────────────
// `df_check_url` 의 maven-metadata.xml URL 에서 그룹/아티팩트 경로를 뽑는다. 좌표를 여기 손으로
// 적으면 SSOT 가 둘이 된다.
const factsPath = join(ROOT, 'scripts/lib/deploy-facts.sh')
if (!existsSync(factsPath)) {
  fail('missing-ssot', `없다: ${factsPath} — 좌표의 출처가 없으면 검사가 성립하지 않는다.`)
  process.exit(1)
}
const facts = readFileSync(factsPath, 'utf8')
const coords = []
for (const m of facts.matchAll(/^\s*(\w+)\)\s*echo\s*"https:\/\/repo1\.maven\.org\/maven2\/(\S+?)\/maven-metadata\.xml"/gm)) {
  coords.push({ lang: m[1], path: m[2] })
}
const wanted = ONLY ? ONLY.split(',').map((s) => s.trim()).filter(Boolean) : null
const targets = wanted ? coords.filter((c) => wanted.includes(c.lang)) : coords

// 공허 하한 — **규칙**이다: `df_check_url` 이 repo1 좌표를 말하는 언어가 하나도 없으면
// 이 검사는 통째로 안 돈 것이지 「위반 없음」이 아니다.
if (targets.length === 0) {
  fail('vacuous-scan', `deploy-facts.sh 에서 repo1 좌표를 하나도 못 읽었다(--lang=${ONLY || '(전체)'}) — df_check_url 의 모양이 바뀌었나?`)
  process.exit(1)
}

// ── 가져오기 ────────────────────────────────────────────────────────────────
const get = async (rel) => {
  if (OFFLINE) {
    const p = join(BASE, rel)
    if (!existsSync(p) || !statSync(p).isFile()) return null
    return readFileSync(p)
  }
  const r = await fetch(`${BASE}/${rel}`)
  if (r.status === 404) return null
  if (!r.ok) throw new Error(`HTTP ${r.status} — ${rel}`)
  return Buffer.from(await r.arrayBuffer())
}

// ── 태그가 선언한 하한 ──────────────────────────────────────────────────────
// ⚠️ kotlin 은 `jvmTarget` 이 **없으면 툴체인이 타깃까지 끌고 간다**(트리 주석이 그 인과를
// 적는다). `kotlin-v1.0.0` 이 실제로 그 상태였고 게시본이 major 65 였다. 그래서 없을 때
// 21 로 가정하지 않고 **`jvmToolchain(n)` 을 읽는다** — 그것이 그 시절의 실효 하한이다.
const showAtTag = (tag, path) => {
  try {
    return execFileSync('git', ['-C', ROOT, 'show', `${tag}:${path}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
  } catch {
    return null
  }
}
const floorAtTag = (lang, tag) => {
  if (lang === 'java') {
    const t = showAtTag(tag, 'java/pom.xml')
    if (t === null) return null
    const m = /<maven\.compiler\.release>\s*(\d+)\s*</.exec(t)
    return m ? { feature: Number(m[1]), how: 'maven.compiler.release' } : null
  }
  const t = showAtTag(tag, 'kotlin/build.gradle.kts')
  if (t === null) return null
  const jt = /JvmTarget\.JVM_(\d+)/.exec(t)
  if (jt) return { feature: Number(jt[1]), how: 'jvmTarget' }
  const tc = /jvmToolchain\((\d+)\)/.exec(t)
  return tc ? { feature: Number(tc[1]), how: 'jvmToolchain(=jvmTarget 부재 시 실효 하한)' } : null
}
const tagFor = (lang, version) => (lang === 'kotlin' ? `kotlin-v${version}` : `v${version}`)
const majorOf = (feature) => feature + 44 // Java 17 → 61 · Java 21 → 65

// ⚠️ **집합 모듈 하나만 보면 java 레인은 사실상 공허하다** — 실측: `keycloak-sdk` 의 jar 는
// 버전당 클래스가 **1개**다. 진짜 코드는 `-core`·`-auth`·`-admin` 에 있고, 2026-09-06 손측정이
// jar 를 다섯 개 받은 이유가 그것이다. 형제 목록은 **그 버전의 태그**가 소유한다(손으로 적으면
// 모듈이 하나 늘 때 조용히 조준 밖이 된다).
const siblingsAtTag = (lang, tag) => {
  if (lang !== 'java') return []
  const t = showAtTag(tag, 'java/pom.xml')
  if (t === null) return []
  const block = /<modules>([\s\S]*?)<\/modules>/.exec(t)
  if (!block) return []
  return [...block[1].matchAll(/<module>\s*([^<\s]+)\s*<\/module>/g)].map((m) => m[1])
}

// ── jar 안의 클래스파일 버전 ────────────────────────────────────────────────
// 의존성 없이 zip 을 읽는다(이 저장소의 가드는 전부 zero-dep 이다). 필요한 것은 각 항목의
// 앞 8바이트뿐이지만 deflate 항목은 펴야 하므로 항목 단위로 inflate 한다.
// ⚠️ **Multi-Release jar 의 `META-INF/versions/<n>/` 아래는 의도적으로 높다** — 제외하고,
// 제외했다는 사실을 출력한다(형제 가드와 같은 규칙).
const readJarMajors = (buf, label) => {
  const EOCD = 0x06054b50
  let eocd = -1
  for (let i = buf.length - 22; i >= 0 && i >= buf.length - 66000; i--) {
    if (buf.readUInt32LE(i) !== EOCD) continue
    // ⚠️ **서명만 보고 잡으면 안 된다.** zip 의 아카이브 주석은 임의 바이트이고, 그 안에
    // 이 4바이트가 들어 있으면 뒤에서부터 훑는 이 루프가 **가짜를 먼저 만난다**(실측: 그때
    // 중앙 디렉터리 오프셋이 1094795585 로 읽혀 예외가 났다 — 큰 소리로 죽으니 조용한 통과는
    // 아니지만, 정상 jar 가 우연히 그 바이트를 품으면 **거짓 경보**다).
    // 진짜 EOCD 는 「주석 길이 필드 == 실제 남은 바이트」를 만족한다. 그것으로 가린다.
    if (buf.readUInt16LE(i + 20) !== buf.length - (i + 22)) continue
    eocd = i
    break
  }
  if (eocd < 0) throw new Error(`${label}: zip 끝 레코드를 못 찾았다(jar 가 아니거나 잘렸다)`)
  const count = buf.readUInt16LE(eocd + 10)
  let off = buf.readUInt32LE(eocd + 16)
  if (count === 0xffff || off === 0xffffffff) throw new Error(`${label}: zip64 다 — 이 리더는 지원하지 않는다(조용히 오독하지 않는다)`)
  const out = []
  let skippedMR = 0
  for (let n = 0; n < count; n++) {
    if (buf.readUInt32LE(off) !== 0x02014b50) throw new Error(`${label}: 중앙 디렉터리 항목 ${n} 의 서명이 어긋난다`)
    const method = buf.readUInt16LE(off + 10)
    const csize = buf.readUInt32LE(off + 20)
    const nameLen = buf.readUInt16LE(off + 28)
    const extraLen = buf.readUInt16LE(off + 30)
    const cmtLen = buf.readUInt16LE(off + 32)
    const local = buf.readUInt32LE(off + 42)
    const name = buf.toString('utf8', off + 46, off + 46 + nameLen)
    off += 46 + nameLen + extraLen + cmtLen
    if (!name.endsWith('.class')) continue
    if (name.startsWith('META-INF/versions/')) { skippedMR++; continue }
    const lnLen = buf.readUInt16LE(local + 26)
    const leLen = buf.readUInt16LE(local + 28)
    const start = local + 30 + lnLen + leLen
    const raw = buf.subarray(start, start + csize)
    const data = method === 0 ? raw : inflateRawSync(raw)
    if (data.length < 8) continue
    out.push({ name, major: data.readUInt16BE(6) })
  }
  return { classes: out, skippedMR }
}

// ── 본체 ────────────────────────────────────────────────────────────────────
let versionsChecked = 0
let classesRead = 0
const pending = []

for (const { lang, path } of targets) {
  const meta = await get(`${path}/maven-metadata.xml`)
  if (meta === null) {
    fail('no-metadata', `${lang}: ${path}/maven-metadata.xml 이 404 다 — 좌표가 바뀌었거나 아직 아무것도 게시되지 않았다.`)
    continue
  }
  const versions = [...meta.toString('utf8').matchAll(/<version>([^<]+)<\/version>/g)].map((m) => m[1].trim())
  if (versions.length === 0) {
    fail('empty-metadata', `${lang}: maven-metadata.xml 에 <version> 이 없다 — 파싱이 깨졌거나 내용이 비었다.`)
    continue
  }

  const groupDir = path.slice(0, path.lastIndexOf('/'))
  const metaCache = new Map()
  const metaVersions = async (artifact) => {
    if (metaCache.has(artifact)) return metaCache.get(artifact)
    const b = await get(`${groupDir}/${artifact}/maven-metadata.xml`)
    const list = b === null ? null : [...b.toString('utf8').matchAll(/<version>([^<]+)<\/version>/g)].map((m) => m[1].trim())
    metaCache.set(artifact, list)
    return list
  }

  for (const v of versions) {
    const tag = tagFor(lang, v)
    const floor = floorAtTag(lang, tag)
    if (floor === null) {
      // 태그가 없는 게시본 — 대조할 선언이 없다. 건너뛰되 **세어서** 출력한다.
      notes.push(`skip ${lang} ${v} — 태그 ${tag} 에서 하한 선언을 못 읽었다(태그 없음/모양 다름)`)
      continue
    }
    const coordArtifact = path.split('/').pop()
    const siblings = siblingsAtTag(lang, tag)
    // 공허 방지 — java 인데 형제를 0 개 뽑았다면 파생이 깨진 것이다(집합 모듈 jar 는
    // 클래스가 1 개뿐이라 그대로 두면 「전부 통과」가 거짓 안심이 된다).
    if (lang === 'java' && siblings.length === 0) {
      fail('no-siblings', `${lang} ${v}: ${tag} 의 java/pom.xml 에서 <module> 을 하나도 못 뽑았다 — 집합 모듈 하나만 보면 이 레인은 공허하다.`)
      continue
    }
    const artifacts = [...new Set([coordArtifact, ...siblings])]

    for (const artifact of artifacts) {
      const av = await metaVersions(artifact)
      if (av === null) {
        notes.push(`skip ${lang} ${artifact} — maven-metadata 가 없다(게시된 적 없는 모듈)`)
        continue
      }
      if (!av.includes(v)) {
        // ⚠️ 등록부가 적는 `-examples` 가 이 경우다 — 그 좌표에 `1.0.0` 자체가 없다.
        notes.push(`skip ${lang} ${artifact} ${v} — 이 아티팩트의 metadata 에 그 버전이 없다`)
        continue
      }
      const pom = await get(`${groupDir}/${artifact}/${v}/${artifact}-${v}.pom`)
      if (pom === null) {
        fail('missing-pom', `${lang} ${artifact} ${v}: metadata 는 이 버전을 싣는데 pom 이 404 다 — 레지스트리가 자기모순이다.`)
        continue
      }
      // ⚠️ **404 를 「jar 없음」의 증거로 쓰지 않는다** — pom 패키징이면 애초에 jar 가 없다.
      // 2026-09-06 손측정에서 독립 레그가 지목한 바로 그 지점이다: 먼저 <packaging> 을 읽는다.
      const packaging = (/<packaging>\s*([\w-]+)\s*<\/packaging>/.exec(pom.toString('utf8')) ?? [, 'jar'])[1]
      if (packaging === 'pom') {
        notes.push(`skip ${lang} ${artifact} ${v} — <packaging>pom</packaging> 이라 jar 가 없다`)
        continue
      }
      const jar = await get(`${groupDir}/${artifact}/${v}/${artifact}-${v}.jar`)
      if (jar === null) {
        fail(
          'missing-jar',
          `${lang} ${artifact} ${v}: <packaging>${packaging}</packaging> 인데 jar 가 404 다.`,
          'metadata 가 싣고 pom 이 jar 를 약속하는데 바이트가 없다 — 업로드가 부분적으로 실패한 모양이다.',
        )
        continue
      }
      let read
      try {
        read = readJarMajors(jar, `${lang} ${artifact} ${v}`)
      } catch (e) {
        fail('unreadable-jar', `${lang} ${artifact} ${v}: ${e.message}`)
        continue
      }
      if (read.classes.length === 0) {
        fail('vacuous-jar', `${lang} ${artifact} ${v}: jar 안에 클래스가 0 개다 — 0 개를 훑고 「위반 없음」으로 읽지 않는다.`)
        continue
      }
      versionsChecked++
      classesRead += read.classes.length
      const cap = majorOf(floor.feature)
      const over = read.classes.filter((c) => c.major > cap)
      const mr = read.skippedMR > 0 ? ` · MR 제외 ${read.skippedMR}` : ''
      if (over.length > 0) {
        fail(
          'published-above-floor',
          `${lang} ${artifact} ${v}: 게시된 클래스 ${over.length}/${read.classes.length} 개가 태그가 선언한 하한을 넘는다.`,
          `선언: ${tag} 의 ${floor.how} = ${floor.feature} (major ${cap})`,
          ...over.slice(0, 5).map((c) => `  ${c.name} → major ${c.major}`),
          over.length > 5 ? `  … 외 ${over.length - 5}개` : '',
          '소비자가 받는 바이트가 우리가 선언한 것과 다르다 — 릴리스가 다른 JDK 로 빌드됐거나 업로드가 뒤바뀌었다.',
        )
      } else {
        notes.push(`ok   ${lang} ${artifact} ${v} — 클래스 ${read.classes.length}개 전부 major ≤ ${cap} (${floor.how}=${floor.feature})${mr}`)
      }
    }
  }

  // 이 좌표에서 검사한 버전이 0 이면, 그 사실을 **보이게** 남긴다(조용한 초록 금지).
  if (versions.length > 0 && versionsChecked === 0) pending.push(`${lang}: ${versions.length}개 버전 중 대조 가능한 것이 0개`)
}

for (const n of notes) console.log(n)

// ── 공허 방지 ───────────────────────────────────────────────────────────────
// ⚠️ **아무것도 읽지 않고 끝난 실행은 성공한 실행과 구분되지 않는다.** 독립 레그가 이 검사의
// 가장 그럴듯한 죽는 법으로 지목한 것이 정확히 이것이다(404·타임아웃 경로가 조용히 0 을 낸다).
// 규칙: 좌표가 하나라도 있으면 **버전 하나 이상을 실제로 읽어야** 한다. 개수를 박지 않는다.
if (errors.length === 0 && versionsChecked === 0) {
  fail(
    'vacuous-run',
    `좌표 ${targets.length}개를 훑고 **버전을 하나도 대조하지 못했다** — 「위반 없음」이 아니라 검사가 안 돈 것이다.`,
    ...pending.map((p) => `  ${p}`),
    '태그 이름 규칙이 바뀌었거나(git fetch --tags 가 안 돌았거나) 좌표가 옮겨졌다.',
  )
}

if (errors.length) {
  console.error('')
  console.error('  다시 재는 법:')
  console.error('    curl -s https://repo1.maven.org/maven2/io/github/xzawed/keycloak-sdk/maven-metadata.xml')
  console.error('    node scripts/check-published-jvm-floor.mjs --lang=java')
  process.exit(1)
}
console.log(`ok   게시본 ${versionsChecked}개 버전 · 클래스 ${classesRead}개를 태그 선언과 대조했다`)
