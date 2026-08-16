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
// ⚠️ **하네스 샘플 앱 핀 오류는 별도 계급이다** — plain 모드에서는 `errors`와 똑같이 치명적이지만
// `--list`에서는 치명적이지 않다.
//
// 왜 나눴나: `--list`의 계약은 "언어별 매니페스트 버전"이고 하네스 앱의 핀은 그 값에 아무 영향도
// 주지 않는다. 그런데 한 배열을 공유하면 **낡은 핀 하나가 파생 자체를 죽인다** —
// `harness/install/install-verify.sh`는 무명시 실행에서 이 목록을 fail-closed로 소비하므로
// (`--list` 실패 → exit 2) 언어 루프에 **진입조차 못 하고** 신호도 INSTALL-MATRIX.md도 나오지 않는다.
// 즉 kotlin 앱 하나의 드리프트가 아홉 언어를 전부 측정 불가로 만든다 — 이 가드가 막으려던 사고
// (kotlin 앱 하나가 빌드에 실패하는 것)보다 **더 넓은 정지**다. 실측으로 확인했다.
// 진짜 추출 실패(매니페스트에서 버전을 못 읽음)는 그대로 `errors`라 두 모드 모두 하드 실패다 —
// 그건 파생 값 자체를 신뢰할 수 없는 경우이기 때문이다.
//
// ⚠️ 이 배열은 이름과 달리 "하네스 전용"이 아니라 **파생을 막지 않는 치명적 오류** 계급이다 —
// Kotlin의 Gradle 래퍼↔KGP 밴드 검사도 여기 들어간다. 같은 근거다: 래퍼 버전은 `--list`의 계약
// (언어별 매니페스트 버전)에 아무 영향도 주지 않으므로, Kotlin 툴체인 정책 하나가 아홉 언어의
// install-verify 파생을 통째로 죽여서는 안 된다. 차단은 plain 모드(repo-hygiene 머지 게이트)가 한다.
const harnessErrors = []
const found = []

const read = (p) => readFileSync(join(root, p), 'utf8')
// sink: 이 오류가 어느 계급인지 — 기본은 파생을 막는 `errors`, 하네스 검사는 `harnessErrors`.
const pick = (p, re, label, sink = errors) => {
  const m = re.exec(read(p))
  if (!m) {
    sink.push(`${p} 에서 ${label} 버전을 추출하지 못했다 — 추출 실패도 실패로 취급한다(가드가 조용히 무력화되면 안 된다)`)
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
    const pinned = pick(p, re, `${lang} 하네스 앱의 SDK 핀`, harnessErrors)
    if (pinned === null) continue // pick()이 이미 harnessErrors에 적었다
    const ssot = found.find(([l]) => l === lang)?.[1]
    if (ssot === undefined) continue // 해당 언어 SSOT 추출이 이미 실패했다 — 중복 보고하지 않는다
    if (pinned !== ssot) {
      harnessErrors.push(
        `${p} 의 ${coord} 핀이 "${pinned}" 인데 ${lang} SSOT 는 "${ssot}" 다 — ` +
          `SDK 버전을 범프하면 **같은 커밋에서** 하네스 앱의 핀도 옮길 것(이 드리프트는 야간 score-all에서만 드러난다)`,
      )
    }
  }

  // ── 하네스와 SDK가 **공유해야 하는 제3자 좌표** ──
  //
  // ⚠️ 위 검사는 SDK **자신의** 버전만 본다. 그런데 rust 하네스 앱과 quickstart는 `keycloak`
  // crate를 직접 의존한다 — `keycloak::types::UserRepresentation`을 값으로 만들어 `AdminClient`
  // 메서드에 넘기려면 **같은 crate·같은 버전·같은 피처**여야 같은 타입이기 때문이다(두 파일의
  // 주석이 그렇게 적고 있다). 그런데 그 "동일"을 아무도 검사하지 않았고, 실제로 SDK는
  // `~26.6.2`인데 하네스 둘은 `=26.6.2`로 갈라져 있었다(2026-08-12 문서 감사 C2).
  //
  // ⚠️ **연산자까지 포함해 문자로 대조한다.** `=`(정확)와 `~`(패치 범위)는 서로 다른 계약이라
  // SDK가 상한을 올리는 순간 교집합이 비어 cargo가 통일에 실패한다 — 조용한 드리프트는 아니지만
  // 그때 깨지는 것은 야간 하네스이고 원인이 보이지 않는다. `check-docs.mjs`가 의존성 표에서
  // 연산자를 값으로 취급하는 것과 같은 이유다.
  const sharedThirdParty = [
    ['keycloak', /^\s*keycloak\s*=\s*\{\s*version\s*=\s*"([^"]+)"/m, [
      'rust/Cargo.toml',
      'harness/apps/rust/Cargo.toml',
      'harness/install/quickstart/rust/Cargo.toml',
    ]],
  ]
  for (const [crate, re, paths] of sharedThirdParty) {
    const present = paths.filter((p) => existsSync(join(root, p)))
    if (present.length < 2) continue // 부분 체크아웃 — 대조할 짝이 없다
    const seen = []
    for (const p of present) {
      const v = pick(p, re, `${p} 의 ${crate} 요구`, harnessErrors)
      if (v !== null) seen.push([p, v])
    }
    // 대조군 — 추출이 실제로 짝을 이뤘는가. 정규식이 낡으면 0~1건만 잡히고 조용히 통과한다.
    if (seen.length !== present.length) continue // pick()이 이미 적었다
    const [, want] = seen[0]
    for (const [p, v] of seen.slice(1)) {
      if (v !== want) {
        harnessErrors.push(
          `${p} 의 ${crate} 요구가 "${v}" 인데 ${seen[0][0]} 는 "${want}" 다 — ` +
            `두 파일의 주석이 "SDK와 동일한 crate/버전/피처"를 요구한다(같은 타입이어야 값으로 전달 가능). ` +
            `연산자도 값의 일부다(\`=\` ≠ \`~\`)`,
        )
      }
    }
  }
}

// ── Kotlin: Gradle 래퍼가 KGP의 **완전지원 밴드** 안에 있는가 ──
//
// 왜 필요한가: 이 저장소의 Kotlin 모듈은 **첫 커밋부터 한 번도 밴드 안에 있던 적이 없다**(실측).
//   bf38670(스캐폴딩): KGP 2.2.20(밴드 상한 8.14) + 래퍼 9.5.0  → 메이저 하나만큼 밖
//   723d0a4(dependabot): KGP 2.4.10(밴드 상한 9.5.0) + 래퍼 9.6.1 → 0.1.1 만큼 밖
// 즉 723d0a4는 "밴드 밖으로 나간 사고"가 아니라 간격을 **좁힌** 커밋이었고, 진짜 사고는
// **아무도 이 짝을 확인한 적이 없다는 것**이다. 리포를 겨누는 가드는 그동안 전부 초록이었다 —
// 어떤 가드도 `gradle-wrapper.properties`를 읽지 않았기 때문이다(실측: 이 블록을 넣기 전
// `grep -rn 'gradle-wrapper' scripts/ .github/workflows/` → 0건).
//
// ⚠️ **밴드 데이터는 외부(kotlinlang.org)라 CI가 가져올 수 없다.** 그래서 밴드를 하드코딩하되
// **KGP 버전과 묶어서** 기록한다(`kotlin/build.gradle.kts`의 `// kgp-gradle-band:` 줄). 상수만
// 박아두면 그 상수 자체가 조용히 낡지만, `kgp=`를 실제 KGP 선언과 대조하면 **KGP가 움직이는
// 순간 기록이 무효가 되어** 사람이 밴드를 다시 확인할 수밖에 없다. 이것이 이 검사가 수렴하는
// 이유다 — 비교 대상 셋이 전부 로컬 파일이고 문맥 의존이 없다.
//
// ⚠️ 밴드 밖이 곧 고장은 아니다(kotlinlang: "you might encounter deprecation warnings or some new
// features might not work"). 그래서 이 검사가 지키는 것은 "빌드가 깨진다"가 아니라 **선언된 정책**
// 이다 — 정책은 사람이 정하고(사용자 승인), 가드는 그것이 조용히 어긋나는 것만 막는다.
{
  const bgk = 'kotlin/build.gradle.kts'
  const wrapProps = 'kotlin/gradle/wrapper/gradle-wrapper.properties'
  // ⚠️ **부재와 추출 실패를 구분한다**(위 두 검사와 같은 관용). 래퍼가 없는 트리(부분 체크아웃·
  // 이 가드의 픽스처 일부)는 검사 대상이 아니다. 그러나 파일이 있는데 값이 안 읽히면 실패다.
  if (existsSync(join(root, bgk)) && existsSync(join(root, wrapProps))) {
    const cmpVer = (a, b) => {
      const pa = a.split('.').map(Number)
      const pb = b.split('.').map(Number)
      for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const d = (pa[i] ?? 0) - (pb[i] ?? 0)
        if (d !== 0) return d < 0 ? -1 : 1
      }
      return 0
    }
    // 래퍼의 실제 버전 SSOT는 배포 URL이다(`-bin`/`-all` 둘 다 허용).
    const wrapper = pick(wrapProps, /gradle-(\d+(?:\.\d+)*)-(?:bin|all)\.zip/, 'Gradle 래퍼 배포', harnessErrors)
    // build.gradle.kts 1행의 미러 주석. 이것은 오래 **아무도 검사하지 않는 2차 정의 자리**였다 —
    // 723d0a4는 래퍼를 9.6.1로 올리면서 이 줄도 같이 옮겼지만, 그건 우연이지 강제가 아니었다.
    const mirror = pick(bgk, /^\/\/ gradle\/wrapper:\s*(\S+)\s*$/m, '래퍼 미러 주석(build.gradle.kts 1행)', harnessErrors)
    const kgpActual = pick(bgk, /kotlin\("jvm"\)\s+version\s+"([^"]+)"/, 'KGP 선언', harnessErrors)
    const bandRe = /^\/\/ kgp-gradle-band:\s*kgp=(\S+)\s+gradle=(\d+(?:\.\d+)*)-(\d+(?:\.\d+)*)\s*$/m
    const band = bandRe.exec(read(bgk))
    if (!band) {
      harnessErrors.push(
        `${bgk} 에서 \`// kgp-gradle-band: kgp=<KGP> gradle=<min>-<max>\` 선언을 읽지 못했다 — ` +
          `이 줄은 주석이 아니라 검사되는 선언이다(지우면 래퍼↔KGP 정합을 아무도 안 본다)`,
      )
    }
    if (wrapper && mirror && wrapper !== mirror) {
      harnessErrors.push(
        `${bgk} 1행의 미러 주석이 "${mirror}" 인데 ${wrapProps} 는 "${wrapper}" 다 — ` +
          `래퍼를 옮기면 같은 커밋에서 이 주석도 옮길 것(2차 정의 자리다)`,
      )
    }
    if (band && kgpActual && band[1] !== kgpActual) {
      harnessErrors.push(
        `${bgk} 의 kgp-gradle-band 는 kgp=${band[1]} 기준으로 기록됐는데 실제 KGP 선언은 "${kgpActual}" 다 — ` +
          `KGP를 올렸으면 kotlinlang.org의 KGP↔Gradle 호환표에서 **새 밴드를 다시 확인**하고 이 줄을 함께 고칠 것. ` +
          `밴드는 KGP 버전마다 다르다(실측: 2.2.20–2.2.21 는 7.6.3–8.14, 2.4.0–2.4.10 는 7.6.3–9.5.0)`,
      )
    }
    if (band && wrapper) {
      const [, , lo, hi] = band
      if (cmpVer(wrapper, lo) < 0 || cmpVer(wrapper, hi) > 0) {
        harnessErrors.push(
          `Gradle 래퍼 ${wrapper} 가 KGP ${band[1]} 의 완전지원 밴드 ${lo}–${hi} 를 벗어났다 — ` +
            `래퍼만 올리지 말고 KGP와 **함께** 올릴 것(밴드 밖이 곧 고장은 아니지만, 이 저장소의 선언된 정책이다). ` +
            `근거·되살릴 조건: .claude/rules/kotlin.md`,
        )
      }
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
  // ⚠️ 하네스 핀 드리프트는 여기서 **차단하지 않는다**(위 harnessErrors 선언부의 근거). 그러나
  // 조용히 넘기지도 않는다 — stderr로 경고를 낸다. stdout의 두 컬럼 계약은 그대로다(소비자는
  // stdout만 읽는다). 차단은 plain 모드(repo-hygiene 머지 게이트)가 한다.
  for (const e of harnessErrors) console.error(`::warning::${e}`)
  for (const [lang, v] of found) console.log(`${lang}\t${v}`)
  process.exit(0)
}

for (const [lang, v, where] of found) console.log(`  ${lang.padEnd(8)} ${v.padEnd(18)} ${where}`)
for (const w of warnings) console.log(`::warning::${w}`)
// plain 모드에서는 하네스 핀 드리프트도 치명적이다 — 이 모드가 도는 자리(repo-hygiene 머지 게이트 ·
// install-smoke)는 "리포가 정합한가"를 묻는 자리이고, 거기서는 사람이 고쳐야 한다.
const fatal = [...errors, ...harnessErrors]
if (fatal.length) {
  for (const e of fatal) console.log(`::error::${e}`)
  console.log(`\n버전 SSOT 검사 실패 — ${fatal.length}건`)
  process.exit(1)
}
console.log(
  `\n버전 SSOT 검사 통과 — ${found.length}개 언어(go·php는 태그가 SSOT라 대상 아님)` +
    (warnings.length ? ` · 경고 ${warnings.length}건(기저 버전 갈림 — 차단하지 않는다)` : ''),
)
