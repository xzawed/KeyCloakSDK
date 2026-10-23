#!/usr/bin/env node
// Central Portal 이 **업로드 뒤에야** 말해 주는 번들 배치 규칙을 업로드 전에 잰다.
//
// 왜 있는가: v1.2.0·v1.2.1 이 Portal 검증에서 FAILED 였다 — 「Bundle has content that does NOT have a
// .pom file: io/github/xzawed/keycloak-sdk-auth, …」. 러너의 Maven 이 3.10.0 이 되자 스테이징 저장소에
// 로컬 저장소 장부(`maven-metadata-local.xml` · `_remote.repositories` · `.locks`)가 생겼고
// central-publishing 0.11.x 는 그것을 지우지 않았다(플러그인 dacf615). 저장소의 어떤 가드도 번들을
// 만들지 않으므로 태그를 자른 뒤에야 드러났고, 번호 둘이 탔다.
//
// 입력: 번들의 항목 목록 한 줄에 하나(`unzip -Z1 central-bundle.zip`) — 파일 인자 또는 `-`(stdin).
// 디렉터리 항목(`/` 로 끝남)은 무시하고, 윈도에서 만든 zip 의 `\` 는 `/` 로 읽는다.
//
// 규칙 — 파일마다 `<그룹 경로>/<artifactId>/<version>/<artifactId>-<version>…` 에 있어야 하고(구성요소
// 디렉터리), 구성요소 디렉터리마다 `<artifactId>-<version>.pom` 이 있어야 한다. 로컬 저장소 장부는
// 어디에 있든 위반이다. 기대 구성요소 집합은 `--root` 의 `java/pom.xml` 이 소유한다(모듈 pom 의
// artifactId + 부모 − `<excludeArtifacts>`) — 손으로 적으면 모듈이 하나 늘 때 조용히 조준 밖이 된다.
//
// 사용: node scripts/check-central-bundle.mjs <목록|-> [--root=<저장소>] [--group=io/github/xzawed]
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const args = process.argv.slice(2)
const flag = (name, dflt) => {
  const a = args.find((x) => x.startsWith(`--${name}=`))
  return a ? a.slice(name.length + 3) : dflt
}
const input = args.find((x) => !x.startsWith('--'))
if (!input) {
  console.error('사용: check-central-bundle.mjs <unzip -Z1 목록 | -> [--root=<저장소>] [--group=io/github/xzawed]')
  process.exit(2)
}
const ROOT = resolve(flag('root', '.'))
const GROUP = flag('group', 'io/github/xzawed').replace(/\/+$/, '')

const stripXml = (t) => t.replace(/<!--[\s\S]*?-->/g, ' ')
const readPom = (rel) => {
  try {
    return stripXml(readFileSync(join(ROOT, rel), 'utf8'))
  } catch (e) {
    // ⚠️ 못 읽은 pom 을 빈 문자열로 넘기면 기대 집합이 조용히 줄어든다 — 이름을 대고 멈춘다.
    console.error(`::error::${join(ROOT, rel)} 을 읽지 못했다 (${e.code ?? e.message}) — 기대 구성요소를 정할 수 없다`)
    process.exit(2)
  }
}

// 기대 구성요소 — 부모(루트 pom 의 artifactId) + 각 모듈 pom 의 artifactId − excludeArtifacts.
const expected = (() => {
  const root = readPom('java/pom.xml')
  const rootId = /<artifactId>\s*([^<\s]+)\s*<\/artifactId>/.exec(root.replace(/<parent>[\s\S]*?<\/parent>/, ' '))?.[1]
  const block = /<modules>([\s\S]*?)<\/modules>/.exec(root)
  const ex = /<excludeArtifacts>([\s\S]*?)<\/excludeArtifacts>/.exec(root)
  const excluded = new Set(ex ? [...ex[1].matchAll(/<[^>]+>\s*([^<\s]+)\s*<\//g)].map((m) => m[1]) : [])
  const ids = rootId ? [rootId] : []
  for (const m of block ? block[1].matchAll(/<module>\s*([^<\s]+)\s*<\/module>/g) : []) {
    // ⚠️ `<parent>` 를 먼저 지운다 — 자식 pom 의 첫 artifactId 는 부모의 것이다.
    const body = readPom(`java/${m[1]}/pom.xml`).replace(/<parent>[\s\S]*?<\/parent>/, ' ')
    const id = /<artifactId>\s*([^<\s]+)\s*<\/artifactId>/.exec(body)?.[1]
    if (id) ids.push(id)
  }
  return ids.filter((id) => !excluded.has(id))
})()

const raw = readFileSync(input === '-' ? 0 : input, 'utf8')
const files = raw.split(/\r?\n/).map((l) => l.trim().replace(/\\/g, '/')).filter((l) => l && !l.endsWith('/'))

// 로컬 저장소가 자기 내용에 대해 남기는 장부 — Central 은 이것이 든 번들을 거부한다.
const BOOKKEEPING = /(^|\/)(maven-metadata-local\.xml|_remote\.repositories|resolver-status\.properties|[^/]+\.lastUpdated)(\.(md5|sha1|sha256|sha512|asc))?$|(^|\/)\.locks\//

const errors = []
const components = new Map() // `<artifactId>/<version>` → { files, hasPom }
for (const f of files) {
  if (BOOKKEEPING.test(f)) {
    errors.push(`로컬 저장소 장부가 번들에 있다: ${f}`)
    continue
  }
  if (!f.startsWith(`${GROUP}/`)) {
    errors.push(`그룹 경로 밖의 파일: ${f}`)
    continue
  }
  const rest = f.slice(GROUP.length + 1).split('/')
  // rest = [artifactId, version, file] 이어야 구성요소 디렉터리다 — 더 얕으면 Central 이 말하는
  // 「.pom 이 없는 내용」이고(1.2.0·1.2.1 의 장부가 바로 그 자리에 있었다), 더 깊으면 배치가 틀렸다.
  if (rest.length !== 3) {
    errors.push(`구성요소 디렉터리(<artifactId>/<version>/) 밖의 파일: ${f}`)
    continue
  }
  const [artifactId, version, name] = rest
  if (!name.startsWith(`${artifactId}-${version}`)) {
    errors.push(`이름이 좌표와 맞지 않는 파일: ${f}`)
    continue
  }
  const key = `${artifactId}/${version}`
  const c = components.get(key) ?? { files: 0, hasPom: false }
  c.files += 1
  if (name === `${artifactId}-${version}.pom`) c.hasPom = true
  components.set(key, c)
}
for (const [key, c] of components) {
  if (!c.hasPom) errors.push(`.pom 이 없는 구성요소: ${GROUP}/${key} (파일 ${c.files} 개)`)
}
const seen = new Set([...components.keys()].map((k) => k.split('/')[0]))
for (const id of expected) {
  if (!seen.has(id)) errors.push(`번들에 없는 게시 모듈: ${id} (java/pom.xml 이 게시한다고 말한다)`)
}
for (const id of seen) {
  if (!expected.includes(id)) errors.push(`게시 집합 밖의 구성요소: ${id} (excludeArtifacts 거나 모듈이 아니다)`)
}
// ⚠️ 공허 통과 금지 — 기대 집합이 비면(pom 을 못 읽음) 위의 대조가 전부 빈 채로 초록이 된다.
if (expected.length === 0) errors.push(`기대 구성요소가 0 개다 — ${join(ROOT, 'java/pom.xml')} 의 모듈을 못 읽었다`)

const versions = new Set([...components.keys()].map((k) => k.split('/')[1]))
if (errors.length) {
  for (const e of errors) console.error(`::error::${e}`)
  console.error(`번들 배치 위반 ${errors.length}건 (파일 ${files.length} · 구성요소 ${components.size} · 기대 ${expected.length})`)
  process.exit(1)
}
console.log(`ok — 파일 ${files.length} · 구성요소 ${components.size}/${expected.length} (${expected.join(' · ')}) · 판 ${[...versions].join(',')}`)
