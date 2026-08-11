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
import { readFileSync, existsSync } from 'node:fs'
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

// ── node: package-lock.json 이 매니페스트와 같은 버전을 기록하는가 ──
//
// lockfile은 루트 패키지 **자신의 버전**을 두 곳(`version`, `packages[""].version`)에 적는다.
// `package.json`만 올리면 그 둘은 옛 값으로 남고 — 실측 — **`npm ci`는 실패하지 않는다.**
// DEPLOY.md §4 step 1이 "같은 커밋에서 `npm install --package-lock-only`로 재생성하라"고
// 적어 두었지만 그건 산문이었고, 잊어도 아무것도 잡지 않았다. Java가 7개 POM에 쓰는
// "같은 값이 여러 곳에 있으면 전부 같아야 한다"를 node lockfile에 그대로 적용한다.
{
  const nodeV = found.find(([l]) => l === 'node')?.[1]
  const lockPath = 'node/package-lock.json'
  let lock = null
  // ⚠️ **부재와 파싱 실패를 구분한다.** lockfile이 아예 없는 트리(이 가드 자신의 테스트
  // 픽스처)에서는 검사할 것이 없어 조용히 넘어간다 — 그러나 파일이 있는데 읽히지 않으면
  // 그건 실패다(가드가 조용히 무력화되면 안 된다). 실제 저장소에서 lock을 지워 이 검사를
  // 피하는 경로는 열려 있지만, 그러면 node 워크플로의 `npm ci`가 전부 죽어 훨씬 시끄럽다.
  if (existsSync(join(root, lockPath))) {
    try {
      lock = JSON.parse(read(lockPath))
    } catch (e) {
      errors.push(`${lockPath} 를 읽지 못했다: ${e.message}`)
    }
  }
  if (nodeV && lock) {
    const spots = [
      ['version', lock.version],
      ['packages[""].version', lock.packages?.['']?.version],
    ]
    for (const [where, v] of spots) {
      if (v === undefined) {
        errors.push(`${lockPath} 에 ${where} 가 없다 — lockfile 형식이 바뀌었다면 이 가드도 함께 고칠 것`)
      } else if (v !== nodeV) {
        errors.push(
          `${lockPath} 의 ${where}="${v}" 가 node/package.json 의 "${nodeV}" 와 다르다 — ` +
            `같은 커밋에서 \`npm install --package-lock-only\` 로 재생성하라(\`npm ci\`는 이 드리프트에 실패하지 않는다)`,
        )
      }
    }
  }
}

// ── 하네스 샘플 앱이 SDK를 **리터럴 버전으로** 핀한 자리 ──
//
// 왜 필요한가: 2026-08-11 야간 `score-all`이 이것 때문에 죽었다 —
//   > Could not find io.github.xzawed:keycloak-sdk-kotlin:0.1.0.
// kotlin SDK를 `0.1.0` → `0.1.0-RC1`로 범프한 PR #170이 `harness/apps/kotlin`의 핀을 두고 갔다.
// 하네스 Dockerfile은 SDK 소스를 `publishToMavenLocal`로 설치하므로 로컬 .m2에는 RC1만 남고 앱이
// 요구하는 `0.1.0`은 어디에도 없다. 이 드리프트는 **야간에만** 드러난다 — 하네스 앱은 PR/푸시
// CI(`mvp-go`)에서 빌드되지 않기 때문에, 리포를 겨누는 가드가 전부 초록인 채로 며칠이 지난다.
//
// ⚠️ **아래 기저 버전(X.Y.Z) 비교로는 못 잡는다.** `0.1.0`과 `0.1.0-RC1`은 기저가 같지만 Maven·
// Gradle의 좌표 해석은 문자열 정확비교다. 그래서 이 검사만 **문자열 동일**을 요구한다. 언어 간
// 갈림이 경고인 것과 반대로 여기서는 오류다 — 독립 버저닝 정책과 충돌하지 않고(같은 언어 안의
// 기계적 참조다) 드리프트가 곧 빌드 실패이기 때문이다.
//
// 대상은 리터럴 버전을 쓰는 **두 앱뿐**이다. 나머지 일곱은 경로/파일 참조라 드리프트할 값이 없다
// (node `file:./…tgz` · php path repo `*` · ruby `path:` · rust `path` · dotnet `ProjectReference` ·
// go `replace` + `v0.0.0` · python은 Dockerfile이 소스에서 설치). 새 하네스 앱이 리터럴 핀을
// 쓰게 되면 여기에 추가할 것.
{
  const harnessPins = [
    ['java', 'harness/apps/java/pom.xml', /<artifactId>keycloak-sdk<\/artifactId>\s*<version>([^<]+)<\/version>/, 'io.github.xzawed:keycloak-sdk'],
    // ⚠️ **선언에 앵커한다** — 좌표만 찾으면 같은 파일의 *주석*이 먼저 잡힌다(실제 파일의 10행이
    // 그 좌표를 산문으로 언급한다). 그 상태로는 `[^"]+`가 다음 따옴표까지 여러 줄을 삼켜 엉뚱한
    // 값을 SSOT와 대조했다 — 픽스처가 실제 파일보다 깨끗해서 자가테스트를 통과했고, 진짜 저장소에
    // 돌려보고서야 드러났다. 픽스처에 그 주석을 미끼로 넣어 고정했다.
    ['kotlin', 'harness/apps/kotlin/build.gradle.kts', /implementation\("io\.github\.xzawed:keycloak-sdk-kotlin:([^"]+)"\)/, 'io.github.xzawed:keycloak-sdk-kotlin'],
  ]
  for (const [lang, p, re, coord] of harnessPins) {
    // ⚠️ **부재와 추출 실패를 구분한다**(node lockfile 검사와 같은 관용). 하네스가 없는 트리
    // (이 가드 자신의 픽스처·부분 체크아웃)에서는 검사할 것이 없다. 그러나 파일이 있는데 좌표
    // 선언이 안 읽히면 그건 실패다 — 조용히 통과하면 가드가 무력화된 것을 아무도 모른다.
    if (!existsSync(join(root, p))) continue
    const pinned = pick(p, re, `${lang} 하네스 앱의 SDK 핀`)
    if (pinned === null) continue // pick()이 이미 errors에 적었다
    const ssot = found.find(([l]) => l === lang)?.[1]
    if (ssot === undefined) continue // 해당 언어 SSOT 추출이 이미 실패했다 — 중복 보고하지 않는다
    if (pinned !== ssot) {
      errors.push(
        `${p} 의 ${coord} 핀이 "${pinned}" 인데 ${lang} SSOT 는 "${ssot}" 다 — ` +
          `SDK 버전을 범프하면 **같은 커밋에서** 하네스 앱의 핀도 옮길 것(이 드리프트는 야간 score-all에서만 드러난다)`,
      )
    }
  }
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
