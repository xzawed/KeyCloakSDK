#!/usr/bin/env node
// check-versions.mjs — 아홉 언어 매니페스트의 버전이 서로 어긋나지 않는지 검사한다.
//
// 왜 필요한가: 버전 범프가 **반쯤 적용되는 것**이 첫 공개 배포의 실제 위험이다. Java는 버전이
// 7개 POM에 존재하고(수동 편집 시 하나를 빠뜨리기 쉽다), 나머지 언어는 각자 다른 파일에 있으며,
// 릴리스 워크플로의 태그↔매니페스트 가드는 **자기 언어만** 본다 — 즉 python만 0.2.0으로 올리고
// node를 0.1.0으로 남겨두면 어떤 게이트도 그것을 잡지 못한다. 태그가 밀리는 순간 그 좌표는
// 태워버린 것이 되고 되돌릴 수 없다.
//
// ⚠️ 이 가드는 **문자열 동일**이 아니라 **X.Y.Z 기저 버전 동일**을 요구한다. 프리릴리스 표기는
// 레지스트리마다 다르기 때문이다(PEP 440 `0.1.0rc1` · RubyGems `0.1.0.rc1` · Maven `0.1.0-RC1` ·
// SemVer `0.1.0-rc.1`). 표기를 통일하라고 요구하면 각 레지스트리가 거부한다.
// ⚠️ go·php는 태그가 버전 SSOT라 매니페스트에 버전이 없다 — 검사 대상이 아니다(scripts/lib/deploy-facts.sh).
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// 루트는 인자로 받는다(check-docs.mjs와 같은 관용) — 그래야 자가테스트가 픽스처 트리에 대해
// 이 가드를 실제로 돌려볼 수 있다. 인자가 없으면 저장소 루트.
// --list: `lang<TAB>version` 만 출력하는 기계가독 모드. harness/install/install-verify.sh가
// 무명시 실행에서 언어별 검증 버전을 파생할 때 소비한다 — 추출 테이블을 bash에 복제하면
// 여기와 어긋나므로(드리프트) 이 파일이 유일한 추출 SSOT로 남는다. 추출 실패는 이 모드에서도
// exit 1이다(가드가 조용히 무력화되면 안 된다).
const cliArgs = process.argv.slice(2)
const listMode = cliArgs.includes('--list')
const root =
  cliArgs.find((a) => !a.startsWith('--')) ??
  new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const errors = []
const found = []

const read = (p) => readFileSync(join(root, p), 'utf8')
const pick = (p, re, label) => {
  const m = re.exec(read(p))
  if (!m) {
    errors.push(`${p} 에서 ${label} 버전을 추출하지 못했다 — 추출 실패도 실패로 취급한다(가드가 조용히 무력화되면 안 된다)`)
    return null
  }
  return m[1]
}

// ── Java: 루트 + 자식 POM. 전부 **문자열까지** 같아야 한다(같은 reactor의 한 버전이므로). ──
// ⚠️ 모듈 목록은 디렉터리 나열이 아니라 **루트 POM의 `<module>` 선언**에서 얻는다.
// 예전에는 `java/` 아래 디렉터리를 전부 모듈로 간주했는데, 그러면 pom.xml이 없는 디렉터리가
// 하나라도 있으면 readFileSync가 ENOENT 스택트레이스로 죽었다 — Maven을 한 번이라도 빌드한
// 워킹트리에는 `java/target/`이 생기므로 **로컬에서는 늘 깨지고 CI(새 체크아웃)에서만 통과**했다.
// 가드가 개발자 머신에서만 죽으면 사람들은 가드를 신뢰하지 않게 된다. 게다가 reactor의 진짜
// 모듈 목록은 루트 POM이 선언하는 것이지 디렉터리 존재가 아니다(선언되지 않은 디렉터리는
// 애초에 빌드에 참여하지 않는다).
const rootPom = read('java/pom.xml')
const javaPoms = [
  'pom.xml',
  ...[...rootPom.matchAll(/<module>([^<]+)<\/module>/g)].map((m) => `${m[1].trim()}/pom.xml`),
]
const javaVersions = new Map()
for (const rel of javaPoms) {
  const p = `java/${rel}`
  // `${project.version}` 같은 참조가 아니라 리터럴인 첫 <version>을 취한다.
  const v = pick(p, /<version>((?!\$\{)[^<]+)<\/version>/, 'Java')
  if (v) javaVersions.set(p, v)
}
const distinctJava = new Set(javaVersions.values())
if (distinctJava.size > 1) {
  errors.push(
    `Java POM 버전이 갈렸다(${distinctJava.size}종) — 범프가 반쯤 적용된 상태다:\n` +
      [...javaVersions].map(([p, v]) => `      ${v}  ${p}`).join('\n'),
  )
}
const javaVersion = [...distinctJava][0]
if (javaVersion) found.push(['java', javaVersion, `${javaVersions.size}개 POM`])

// ── 매니페스트에 버전이 있는 나머지 언어 ──
const manifests = [
  ['python', 'python/pyproject.toml', /^version = "([^"]+)"/m],
  ['node', 'node/package.json', /"version":\s*"([^"]+)"/],
  ['rust', 'rust/Cargo.toml', /^version = "([^"]+)"/m],
  ['ruby', 'ruby/lib/keycloak_sdk/version.rb', /VERSION = "([^"]+)"/],
  ['kotlin', 'kotlin/build.gradle.kts', /^version = "([^"]+)"/m],
  // ⚠️ dotnet의 csproj 버전은 **로컬 기본값**이다 — 릴리스는 태그에서 `-p:Version`으로 주입한다
  // (dotnet-release.yml). 그래도 다른 언어와 갈리면 로컬 `dotnet pack` 산출물이 엉뚱한 버전을
  // 달게 되므로 함께 검사한다.
  ['dotnet', 'dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj', /<Version>([^<]+)<\/Version>/],
]
for (const [lang, p, re] of manifests) {
  const v = pick(p, re, lang)
  if (v) found.push([lang, v, p])
}

// ── 기저 버전(X.Y.Z) 일치 검사 ──
const base = (v) => {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(v)
  return m ? `${m[1]}.${m[2]}.${m[3]}` : null
}
const bases = new Map()
for (const [lang, v] of found) {
  const b = base(v)
  if (!b) {
    errors.push(`${lang} 버전 "${v}" 에서 X.Y.Z를 읽지 못했다`)
    continue
  }
  if (!bases.has(b)) bases.set(b, [])
  bases.get(b).push(`${lang}=${v}`)
}
// ⚠️ 언어 간 갈림은 **경고이지 오류가 아니다.** 한때 오류였고, 그 상태로 릴리스 경로
// (install-smoke.yml — 아홉 워크플로가 전부 `needs:`로 부른다)에 배선되면서 SECURITY.md가
// 소비자에게 한 약속을 지킬 수 없게 만들었다: "각 언어는 독립적으로 버저닝하며, 보안 수정은 그
// 언어에서 준비되는 즉시 릴리스하고 나머지 여덟을 기다리지 않는다." 오류로 두면 python 하나만
// 고친 보안 패치가 아홉을 전부 올릴 때까지 나갈 수 없고, 우회하려고 아홉을 다 올리면 나머지
// 여덟은 그 기저 버전을 영영 쓸 수 없게 된다(각 언어의 태그↔매니페스트 가드가 문자열 동일 비교라).
//
// 게다가 이 검사는 애초에 무엇도 지키지 못했다. `py-v0.2.0`을 밀면 python 자신의 가드가 이미
// pyproject를 확인하므로 node의 상태는 무관하고, `node-v0.2.0`을 package.json이 0.1.0인 채로
// 밀면 node 자신의 가드가 첫 스텝에서 잡는다 — 반쯤 적용된 범프는 **해를 끼칠 수 있는 각
// 지점에서 이미** 잡힌다. 남는 역할은 조율 실수 알림뿐이고, 그건 경고가 할 일이다.
//
// 아래 두 가지는 버저닝 정책과 무관한 불변식이라 **오류로 유지**한다:
//   (1) Java reactor 내부 7개 POM의 문자열 동일(같은 reactor의 한 버전이므로)
//   (2) 추출 실패(가드가 조용히 무력화되는 것을 막는다)
const warnings = []
if (bases.size > 1) {
  warnings.push(
    `언어 간 기저 버전이 갈렸다(${bases.size}종) — 의도한 것이면 무시해도 된다(언어별 독립 버저닝은 SECURITY.md가 명시한 정책이다). 조율 릴리스를 하려던 것이라면 하나를 빠뜨린 것이다:\n` +
      [...bases].map(([b, who]) => `      ${b}: ${who.join(' · ')}`).join('\n'),
  )
}

if (listMode) {
  // 기계가독 출력 — 소비자(install-verify.sh)는 탭 구분 두 컬럼만 기대한다. 경고(기저 버전
  // 갈림)는 사람용 신호라 여기서는 내지 않는다 — 언어별 독립 버저닝이 정책이므로 갈림 자체가
  // 파생을 막을 이유가 아니다. 추출 실패는 동일하게 하드 실패.
  if (errors.length) {
    for (const e of errors) console.error(`::error::${e}`)
    process.exit(1)
  }
  for (const [lang, v] of found) console.log(`${lang}\t${v}`)
  process.exit(0)
}

for (const [lang, v, where] of found) console.log(`  ${lang.padEnd(8)} ${v.padEnd(18)} ${where}`)
for (const w of warnings) console.log(`::warning::${w}`)
if (errors.length) {
  for (const e of errors) console.log(`::error::${e}`)
  console.log(`\n버전 SSOT 검사 실패 — ${errors.length}건`)
  process.exit(1)
}
console.log(
  `\n버전 SSOT 검사 통과 — ${found.length}개 언어(go·php는 태그가 SSOT라 대상 아님)` +
    (warnings.length ? ` · 경고 ${warnings.length}건(기저 버전 갈림 — 차단하지 않는다)` : ''),
)
