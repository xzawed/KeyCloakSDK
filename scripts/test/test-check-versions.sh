#!/usr/bin/env sh
# 버전 SSOT 가드 자가테스트 — 가드가 **실제로 어긋남을 잡는지**, 그리고 **잡으면 안 되는 것을
# 잡지는 않는지**(오탐)를 둘 다 확인한다. 통과만 확인하는 자가테스트는 공허하다: 가드가 아무것도
# 검사하지 않아도 통과하기 때문이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/version-ssot"
GUARD="$DIR/../check-versions.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 정상 픽스처는 통과해야 한다.
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# 변이 1: Java POM 하나만 범프 — 범프가 반쯤 적용된 상태. 버전이 7개 파일에 있어 실제로 잘 일어난다.
cp -r "$FIX/." "$TMP/"
sed -i 's|<parent><version>0.1.0-SNAPSHOT</version></parent>|<parent><version>0.2.0-SNAPSHOT</version></parent>|' "$TMP/java/mod-a/pom.xml"
assert_fails node "$GUARD" "$TMP"

# 한 언어만 범프 — 언어 간 갈림은 **경고이지 실패가 아니다**.
# SECURITY.md가 소비자에게 명시적으로 약속한다: "각 언어는 독립적으로 버저닝하며, 보안 수정은
# 그 언어에서 준비되는 즉시 릴리스하고 나머지 여덟을 기다리지 않는다." 이 가드가 릴리스 경로
# (install-smoke.yml)에서 실패로 동작하면 그 약속을 지킬 수 없다 — python만 고친 보안 패치가
# 아홉 언어를 전부 올릴 때까지 나갈 수 없게 된다.
# 그리고 이 검사는 애초에 무엇도 지키지 못한다: `py-v0.2.0`을 밀면 python 자신의 태그↔매니페스트
# 가드가 이미 확인하므로 node의 상태는 무관하고, `node-v0.2.0`을 package.json이 0.1.0인 채로 밀면
# node 자신의 가드가 첫 스텝에서 잡는다. 반쯤 적용된 범프는 **해를 끼칠 수 있는 각 지점에서**
# 이미 잡힌다. 남는 역할은 "하나 빠뜨린 것 아닌가" 하는 조율용 알림뿐이다.
cp -r "$FIX/." "$TMP/"
sed -i 's/"version": "0.1.0"/"version": "0.2.0"/' "$TMP/node/package.json"
assert_ok node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "::warning::" "언어 간 갈림은 경고로 알린다"
assert_not_contains "$out" "::error::" "언어 간 갈림을 오류로 올리지 않는다"

# 변이 3: 매니페스트에서 버전 줄을 없애면 실패해야 한다 — 추출 실패를 통과로 처리하면 가드가
# 조용히 무력화된다(공허한 통과 방지).
cp -r "$FIX/." "$TMP/"
: > "$TMP/rust/Cargo.toml"
assert_fails node "$GUARD" "$TMP"

# 오탐 방지: 레지스트리마다 프리릴리스 표기가 다른 것은 **정상**이다(PEP 440 rc1 · SemVer -rc.1 ·
# RubyGems .rc1 · Maven -RC1). 표기 통일을 요구하면 각 레지스트리가 그 버전을 거부한다.
# 기저 버전(X.Y.Z)이 같으면 통과해야 한다.
cp -r "$FIX/." "$TMP/"
sed -i 's/version = "0.1.0"/version = "0.1.0rc1"/' "$TMP/python/pyproject.toml"
sed -i 's/"version": "0.1.0"/"version": "0.1.0-rc.1"/' "$TMP/node/package.json"
sed -i 's/VERSION = "0.1.0"/VERSION = "0.1.0.rc1"/' "$TMP/ruby/lib/keycloak_sdk/version.rb"
sed -i 's/version = "0.1.0"/version = "0.1.0-RC1"/' "$TMP/kotlin/build.gradle.kts"
# ⚠️ kotlin SDK를 범프했으면 하네스 앱의 핀도 **같은 커밋에서** 따라가야 한다(아래 하네스 절).
# 이 줄이 없으면 이 픽스처는 2026-08-11 사고 그 자체가 된다.
sed -i 's/keycloak-sdk-kotlin:0.1.0"/keycloak-sdk-kotlin:0.1.0-RC1"/' "$TMP/harness/apps/kotlin/build.gradle.kts"
assert_ok node "$GUARD" "$TMP"

# --list: 기계가독 모드 — harness/install/install-verify.sh가 무명시 실행에서 언어별 검증 버전을
# 파생할 때 소비한다. 계약은 `lang<TAB>version` 두 컬럼뿐이고 경고·요약이 섞이면 안 된다
# (소비자가 행 단위로 파싱한다). 위와 같은 프리릴리스 표기 픽스처를 그대로 재사용해 레지스트리
# 원표기(0.1.0rc1)가 가공 없이 그대로 나오는 것을 고정한다.
out=$(node "$GUARD" "$TMP" --list)
assert_contains "$out" "$(printf 'python\t0.1.0rc1')" "--list: python 원표기 그대로"
assert_contains "$out" "$(printf 'node\t0.1.0-rc.1')" "--list: node 원표기 그대로"
assert_not_contains "$out" "::warning::" "--list: 경고 미출력(기계가독 계약)"
assert_not_contains "$out" "버전 SSOT" "--list: 사람용 요약 미출력(기계가독 계약)"
# 추출 실패는 --list에서도 하드 실패다 — 소비자가 빈 목록을 "버전 없음"으로 오독하면 안 된다.
: > "$TMP/rust/Cargo.toml"
assert_fails node "$GUARD" "$TMP" --list

# ---- node/package-lock.json 이 매니페스트와 어긋나면 실패해야 한다 ----
# lockfile은 루트 패키지 자신의 버전을 두 곳에 적는다. `package.json`만 올리면 둘 다 옛 값으로
# 남고 **`npm ci`는 실패하지 않는다**(실측) — DEPLOY.md가 재생성을 산문으로 요구했지만 잊어도
# 아무것도 잡지 않았다.
rm -rf "$TMP" && mkdir -p "$TMP"
cp -r "$FIX/." "$TMP/"
nv="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$TMP/node/package.json")"

# 두 자리 모두 일치 → 통과(대조군: 없으면 "lock이 있으면 무조건 실패"인 가드와 구분 못 한다)
printf '{"version":"%s","packages":{"":{"version":"%s"}}}\n' "$nv" "$nv" > "$TMP/node/package-lock.json"
assert_ok node "$GUARD" "$TMP"

# 최상위만 낡음 → 실패
printf '{"version":"0.0.9","packages":{"":{"version":"%s"}}}\n' "$nv" > "$TMP/node/package-lock.json"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" 'package-lock.json 의 version="0.0.9"' "최상위 version 드리프트를 지목해야 한다"

# packages[""] 만 낡음 → 실패(둘 중 하나만 검사하면 이 쪽이 새 나간다)
printf '{"version":"%s","packages":{"":{"version":"0.0.9"}}}\n' "$nv" > "$TMP/node/package-lock.json"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" 'packages[""].version="0.0.9"' 'packages[""] 드리프트를 지목해야 한다'

# 형식이 바뀌어 자리 자체가 사라지면 조용히 통과하면 안 된다
printf '%s\n' '{"version":"0.1.0-rc.1","packages":{}}' > "$TMP/node/package-lock.json"
assert_fails node "$GUARD" "$TMP"

# 파일이 있는데 파싱 불가 → 실패(부재와 구분한다)
printf '%s\n' 'not json' > "$TMP/node/package-lock.json"
assert_fails node "$GUARD" "$TMP"

# ⚠️ 대조군 — lockfile이 **아예 없는** 트리는 검사 대상이 아니다(이 가드의 다른 픽스처가 그렇다).
# 없으면 "node/package.json이 있으면 lock도 반드시 있어야 한다"는 전혀 다른 가드가 된 것을 모른다.
rm -f "$TMP/node/package-lock.json"
assert_ok node "$GUARD" "$TMP"

# ---- 하네스 샘플 앱이 SDK를 **리터럴 버전으로** 핀한 자리 ----
#
# 왜 필요한가: 2026-08-11 야간 `score-all`이 빨개졌다 —
#   > Could not find io.github.xzawed:keycloak-sdk-kotlin:0.1.0.
# kotlin SDK를 `0.1.0` → `0.1.0-RC1`로 범프한 PR #170이 `harness/apps/kotlin`의 핀을 두고 갔고,
# Dockerfile은 SDK 소스를 `publishToMavenLocal`로 설치하므로 로컬 .m2에는 RC1만 남아 앱이 요구하는
# `0.1.0`이 어디에도 없었다. **리포를 겨누는 가드는 그때 전부 초록이었다** — 하네스 앱은 PR/푸시
# CI(`mvp-go`)에서 빌드되지 않고 야간에만 빌드되기 때문이다(repo-hygiene.yml 97행 주석의 레지스트리
# 설정 가드와 같은 부류의 사각지대다).
#
# ⚠️ **기저 버전 비교로는 못 잡는다.** `0.1.0`과 `0.1.0-RC1`은 기저(X.Y.Z)가 같지만 Maven·Gradle의
# 좌표 해석은 **문자열 정확비교**다. 그래서 이 검사만 문자열 동일을 요구한다(언어 간 기저 비교가
# 경고인 것과 반대 — 여기서는 정책 충돌이 없고 드리프트가 곧 빌드 실패다).
#
# 대상은 **리터럴 버전을 쓰는 두 앱뿐**이다. 나머지 일곱은 경로/파일 참조라 드리프트할 값이 없다
# (node `file:./…tgz` · php path repo `*` · ruby `path:` · rust `path` · dotnet `ProjectReference` ·
# go `replace` + `v0.0.0` · python은 Dockerfile이 소스에서 설치).
rm -rf "$TMP" && mkdir -p "$TMP"
cp -r "$FIX/." "$TMP/"
KPIN="$TMP/harness/apps/kotlin/build.gradle.kts"
JPIN="$TMP/harness/apps/java/pom.xml"

# 대조군: 핀 = SSOT → 통과. 없으면 "하네스 파일이 있으면 무조건 실패"인 가드와 구분하지 못한다.
assert_ok node "$GUARD" "$TMP"

# 변이 A — **실제 사고 재현**: SDK만 범프하고 하네스 핀을 두고 간다.
cp -r "$FIX/." "$TMP/"
sed -i 's/version = "0.1.0"/version = "0.1.0-RC1"/' "$TMP/kotlin/build.gradle.kts"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "harness/apps/kotlin/build.gradle.kts" "드리프트한 하네스 파일을 지목해야 한다"
# ⚠️ 기대값만 확인하면 공허하다 — `0.1.0-RC1`은 요약줄(kotlin SSOT)에도 있어 가드가 없어도 통과한다.
# 낡은 **핀 쪽** 값이 좌표와 함께 나오는지를 본다.
assert_contains "$OUT" 'keycloak-sdk-kotlin 핀이 "0.1.0" 인데' "핀에 박힌 낡은 값을 좌표와 함께 보여줘야 한다"

# ⚠️ **같은 드리프트가 `--list`를 죽이면 안 된다.** `--list`의 계약은 "언어별 매니페스트 버전"이고
# 하네스 앱의 핀은 그 값에 아무 영향도 주지 않는다. 그런데 한때 같은 `errors` 배열을 공유해서,
# 낡은 핀 하나가 `harness/install/install-verify.sh`의 파생을 fail-closed로 죽였다 — 야간 하네스가
# **아홉 언어 중 하나도 측정하지 못하고** INSTALL-MATRIX.md도 없이 끝났다(실측). 이 가드가 막으려던
# 사고(kotlin 앱 하나가 빌드 실패)보다 넓은 정지다. 그래서 `--list`에서는 경고로만 남긴다.
assert_ok node "$GUARD" "$TMP" --list
# ⚠️ `|| true` 필수 — 이 파일은 `set -e`라 대입문의 명령치환이 실패하면 그 자리에서 죽고
# `assert_report`에 도달하지 못해 남은 어서션이 아예 돌지 않는다(회귀 시가 정확히 그 경우다).
LOUT="$(node "$GUARD" "$TMP" --list 2>/dev/null)" || true
assert_contains "$LOUT" "$(printf 'kotlin\t0.1.0-RC1')" "--list: 하네스 핀이 낡아도 kotlin 행이 나와야 한다"
assert_contains "$LOUT" "$(printf 'python\t0.1.0')" "--list: 하네스 핀이 낡아도 나머지 언어 행이 나와야 한다"
assert_not_contains "$LOUT" "::" "--list: stdout은 두 컬럼뿐이다(경고·오류는 stderr)"
LERR="$(node "$GUARD" "$TMP" --list 2>&1 1>/dev/null)" || true
assert_contains "$LERR" '::warning::' "--list: 하네스 드리프트를 경고로는 남겨야 한다(조용한 통과 금지)"
assert_contains "$LERR" 'keycloak-sdk-kotlin 핀이 "0.1.0" 인데' "--list: 경고가 낡은 핀 값을 지목해야 한다"

# 변이 B — java 쪽만 낡음. 둘 중 하나만 검사하면 이쪽이 새 나간다.
cp -r "$FIX/." "$TMP/"
sed -i 's|<version>0.1.0-SNAPSHOT</version>|<version>0.0.9</version>|' "$JPIN"
assert_fails node "$GUARD" "$TMP"

# 오탐 방지 — SDK와 하네스 핀을 **함께** 옮기면 통과해야 한다(정상적인 범프 커밋의 모양).
cp -r "$FIX/." "$TMP/"
sed -i 's/version = "0.1.0"/version = "0.1.0-RC1"/' "$TMP/kotlin/build.gradle.kts"
sed -i 's/keycloak-sdk-kotlin:0.1.0"/keycloak-sdk-kotlin:0.1.0-RC1"/' "$KPIN"
assert_ok node "$GUARD" "$TMP"

# 추출 실패도 실패다 — 파일은 있는데 좌표 선언이 사라지면 조용히 통과하면 안 된다(가드 무력화 방지).
cp -r "$FIX/." "$TMP/"
: > "$KPIN"
assert_fails node "$GUARD" "$TMP"

# ⚠️ 대조군 — 하네스 트리가 **아예 없는** 체크아웃은 검사 대상이 아니다(이 가드의 다른 픽스처가
# 그렇다). 없으면 "harness/가 반드시 존재해야 한다"는 전혀 다른 가드가 된 것을 모른다.
cp -r "$FIX/." "$TMP/"
rm -rf "$TMP/harness"
assert_ok node "$GUARD" "$TMP"

# ---- Kotlin: Gradle 래퍼가 KGP의 완전지원 밴드 안에 있는가 ----
#
# 왜 필요한가: 이 저장소의 Kotlin 모듈은 **첫 커밋부터 밴드 안에 있던 적이 없다**(실측).
#   bf38670(스캐폴딩)  KGP 2.2.20(상한 8.14)  + 래퍼 9.5.0  → 메이저 하나만큼 밖
#   723d0a4(dependabot) KGP 2.4.10(상한 9.5.0) + 래퍼 9.6.1 → 0.1.1 만큼 밖
# 그동안 리포를 겨누는 가드는 전부 초록이었다 — 어떤 가드도 `gradle-wrapper.properties`를 읽지
# 않았기 때문이다. 723d0a4는 KGP와 래퍼를 **한 커밋에** 올려 밴드 확인 계기 자체를 지웠다.
rm -rf "$TMP" && mkdir -p "$TMP"
cp -r "$FIX/." "$TMP/"
WPROPS="$TMP/kotlin/gradle/wrapper/gradle-wrapper.properties"
BGK="$TMP/kotlin/build.gradle.kts"

# 대조군: 래퍼 9.5.0 == 밴드 상한 → 통과(경계는 포함이다). 이 대조군이 없으면
# "kotlin 래퍼 파일이 있으면 무조건 실패"인 가드와 구별하지 못한다.
assert_ok node "$GUARD" "$TMP"

# 변이 1 — **723d0a4 재현**: 래퍼만 밴드 위로 나간다.
# ⚠️ 미러 주석도 **함께** 옮긴다. 그러지 않으면 미러 검사가 대신 실패시켜서, 밴드 검사가
# 아무것도 안 해도 이 어서션이 통과한다(공허성). 밴드 위반만 남긴 뒤 메시지로 확인한다.
cp -r "$FIX/." "$TMP/"
sed -i 's/gradle-9\.5\.0-bin\.zip/gradle-9.6.1-bin.zip/' "$WPROPS"
sed -i 's|^// gradle/wrapper: 9\.5\.0$|// gradle/wrapper: 9.6.1|' "$BGK"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "밴드 7.6.3–9.5.0 를 벗어났다" "밴드 위반을 실제 밴드 값과 함께 지목해야 한다"
assert_contains "$OUT" "Gradle 래퍼 9.6.1" "밴드 밖 래퍼 버전을 지목해야 한다"
assert_not_contains "$OUT" "미러 주석" "미러 검사가 아니라 밴드 검사가 잡은 것이어야 한다(공허성 방지)"

# 변이 2 — 밴드 **하한** 밖. 상한만 검사하면 이쪽이 새 나간다(KGP를 올리면 하한도 같이 올라간다).
cp -r "$FIX/." "$TMP/"
sed -i 's/gradle-9\.5\.0-bin\.zip/gradle-7.0-bin.zip/' "$WPROPS"
sed -i 's|^// gradle/wrapper: 9\.5\.0$|// gradle/wrapper: 7.0|' "$BGK"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "Gradle 래퍼 7.0" "하한 미만도 밴드 위반이다"

# 변이 3 — **KGP만 올리고 밴드 기록을 두고 간다.** 이것이 이 검사가 수렴하는 이유다:
# 밴드 값은 외부(kotlinlang.org) 데이터라 CI가 가져올 수 없으므로 하드코딩하되 `kgp=`로 KGP에
# 묶어 둔다. KGP가 움직이면 기록이 무효가 되어 사람이 밴드를 다시 확인할 수밖에 없다.
# 이 어서션이 없으면 하드코딩한 상수가 조용히 낡는다.
cp -r "$FIX/." "$TMP/"
sed -i 's/kotlin("jvm") version "2\.4\.10"/kotlin("jvm") version "2.5.0"/' "$BGK"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "실제 KGP 선언은 \"2.5.0\" 다" "낡은 밴드 기록을 새 KGP와 함께 지목해야 한다"
assert_contains "$OUT" "새 밴드를 다시 확인" "무엇을 하라는 것인지 말해야 한다"

# 변이 4 — build.gradle.kts 1행 미러 주석이 래퍼와 갈린다. 이 줄은 오래 **아무도 검사하지 않는
# 2차 정의 자리**였다(723d0a4가 같이 옮긴 것은 우연이지 강제가 아니었다).
cp -r "$FIX/." "$TMP/"
sed -i 's|^// gradle/wrapper: 9\.5\.0$|// gradle/wrapper: 9.4.0|' "$BGK"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" '1행의 미러 주석이 "9.4.0" 인데' "미러 주석의 낡은 값을 지목해야 한다"

# 변이 5 — 밴드 선언줄을 지우면 조용히 통과하면 안 된다(가드 무력화 방지).
# 주석처럼 생겼기 때문에 정리 커밋에서 지워지기 가장 쉬운 줄이다.
cp -r "$FIX/." "$TMP/"
sed -i '/^\/\/ kgp-gradle-band:/d' "$BGK"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "주석이 아니라 검사되는 선언이다" "선언이 사라진 것을 지목해야 한다"

# ---- `.claude/rules/kotlin.md` — 3차 정의 자리 ----
# 왜 필요한가: 위 변이 1~5 를 전부 통과시켜도 **그 규칙 문서가 낡은 채로 남고 필수 체크 둘 다
# 초록이었다**(2026-08-28 변이로 증명: 래퍼+미러를 9.4.0 으로 내려도 check-versions·check-docs 가
# 통과했고 kotlin.md 만 9.5.0 을 계속 주장했다). check-docs 는 앵커 기반이라 산문을 읽지 않는다.
# 그 파일은 정책 근거로 인용되는 자리라, 틀리면 다음 사람이 틀린 밴드로 판단한다.
KMD="$TMP/.claude/rules/kotlin.md"

# 대조군: 셋이 일치하면 통과해야 한다(이게 없으면 아래 실패가 이 검사 몫인지 알 수 없다).
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# 변이 7 — 규칙 문서의 래퍼 값만 낡는다(래퍼·미러·밴드는 전부 정상).
cp -r "$FIX/." "$TMP/"
sed -i 's/the build needs (`9\.5\.0`)/the build needs (`9.4.0`)/' "$KMD"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" 'kotlin.md 가 래퍼를 "9.4.0" 로 적는데' "규칙 문서의 낡은 래퍼 값을 지목해야 한다"
assert_not_contains "$OUT" "밴드 7.6.3–9.5.0 를 벗어났다" "밴드 검사가 대신 잡은 게 아니어야 한다(공허성 방지)"

# 변이 8 — 규칙 문서의 밴드 값만 낡는다. ⚠️ 이것이 가장 비싼 자리다: 이 문장이 #314 류의
# 판단 근거로 인용되므로, 여기 상한이 조용히 넓어지면 밴드 밖 래퍼가 정당해 보인다.
cp -r "$FIX/." "$TMP/"
sed -i 's/(KGP 2\.4\.10 → 7\.6\.3–9\.5\.0)/(KGP 2.4.10 → 7.6.3–9.9.0)/' "$KMD"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "7.6.3–9.9.0" "규칙 문서의 낡은 밴드 값을 지목해야 한다"

# 변이 9 — 문구를 갈아엎어 값이 안 읽히게 만든다. 조용히 통과하면 이 검사는 공허해진다
# (값을 지우고 소스를 가리키는 것은 정답이지만, 값을 남긴 채 모양만 바꾸는 것은 아니다).
cp -r "$FIX/." "$TMP/"
sed -i 's/the build needs (`9\.5\.0`)/the build needs 9.5.0/' "$KMD"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "3차 정의 자리다" "읽지 못한 것을 통과로 넘기지 않아야 한다"

# ---- 소비자 하한 정합 — languageVersion·apiVersion·전이 kotlin-stdlib ----
# 이 셋이 게시 jar를 쓸 수 있는 최소 Kotlin을 함께 정한다. 갈라지면 **증상이 소비자 쪽에서만**
# 난다(우리 CI는 그 조합을 빌드하지 않아 초록이다) — 그래서 자가테스트가 유일한 방어다.

# 변이 6 — stdlib만 올린다. 클래스 메타데이터는 2.2인데 전이 stdlib는 2.4가 되어
# 소비자가 `Class 'kotlin.Unit' was compiled with an incompatible version of Kotlin`으로 죽는다.
cp -r "$FIX/." "$TMP/"
sed -i 's|kotlin-stdlib:2\.2\.21|kotlin-stdlib:2.4.10|' "$BGK"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "소비자 하한이 갈라졌다" "메타데이터와 stdlib 의 하한 불일치를 지목해야 한다"

# 변이 7 — apiVersion만 올린다. 둘은 같은 하한을 가리켜야 한다.
cp -r "$FIX/." "$TMP/"
sed -i 's|apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2)|apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_4)|' "$BGK"
assert_fails node "$GUARD" "$TMP"

# 변이 8 — 명시 stdlib 선언을 지운다. 자동주입에 맡기면 KGP 버전의 stdlib가 전이되어
# 하한이 조용히 KGP 버전까지 올라간다. 선언줄은 "정리"에서 지워지기 쉬운 모양이다.
cp -r "$FIX/." "$TMP/"
sed -i '/kotlin-stdlib:/d' "$BGK"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "자동주입" "명시 선언이 사라진 것을 지목해야 한다"

# 오탐 방지 — 셋을 **함께** 올리면 통과해야 한다(정상적인 하한 상향의 모양).
# 이 대조군이 없으면 이 가드는 "하한을 영원히 올리지 마라"가 된다.
cp -r "$FIX/." "$TMP/"
sed -i 's|KotlinVersion.KOTLIN_2_2|KotlinVersion.KOTLIN_2_4|g' "$BGK"
sed -i 's|kotlin-stdlib:2\.2\.21|kotlin-stdlib:2.4.10|' "$BGK"
assert_ok node "$GUARD" "$TMP"

# 오탐 방지 — 정상적인 KGP 범프의 모양이면 통과해야 한다. 이 대조군이 없으면 이 가드는
# "KGP를 영원히 올리지 마라"가 된다.
# ⚠️ 2026-08-28: 「함께」의 정의가 **넷에서 여섯으로** 늘었다 — `.claude/rules/kotlin.md` 의 두
# 문장이 3차 정의 자리로 추가됐기 때문이다. 이 대조군이 낡은 넷만 옮기던 판이라 새 검사에서
# 실패했고, 그 실패가 정확히 검사가 의도한 것이었다(불완전한 범프는 통과하면 안 된다).
cp -r "$FIX/." "$TMP/"
sed -i 's/kotlin("jvm") version "2\.4\.10"/kotlin("jvm") version "2.6.0"/' "$BGK"
sed -i 's|^// kgp-gradle-band: .*$|// kgp-gradle-band: kgp=2.6.0 gradle=8.0-9.9.0|' "$BGK"
sed -i 's|^// gradle/wrapper: 9\.5\.0$|// gradle/wrapper: 9.9.0|' "$BGK"
sed -i 's/gradle-9\.5\.0-bin\.zip/gradle-9.9.0-bin.zip/' "$WPROPS"
sed -i 's/the build needs (`9\.5\.0`)/the build needs (`9.9.0`)/' "$KMD"
sed -i 's/(KGP 2\.4\.10 → 7\.6\.3–9\.5\.0)/(KGP 2.6.0 → 8.0–9.9.0)/' "$KMD"
assert_ok node "$GUARD" "$TMP"

# ⚠️ **밴드 위반이 `--list`를 죽이면 안 된다.** `--list`의 계약은 "언어별 매니페스트 버전"이고
# Kotlin 툴체인 정책은 그 값에 아무 영향도 주지 않는다. 하네스 핀과 같은 근거다 — 한때 그 부류가
# `errors`를 공유해서 낡은 핀 하나가 아홉 언어의 install-verify 파생을 통째로 죽였다(실측).
cp -r "$FIX/." "$TMP/"
sed -i 's/gradle-9\.5\.0-bin\.zip/gradle-9.6.1-bin.zip/' "$WPROPS"
sed -i 's|^// gradle/wrapper: 9\.5\.0$|// gradle/wrapper: 9.6.1|' "$BGK"
assert_ok node "$GUARD" "$TMP" --list
LOUT="$(node "$GUARD" "$TMP" --list 2>/dev/null)" || true
assert_contains "$LOUT" "$(printf 'kotlin\t0.1.0')" "--list: 밴드가 어긋나도 kotlin 행이 나와야 한다"
assert_not_contains "$LOUT" "::" "--list: stdout은 두 컬럼뿐이다(경고·오류는 stderr)"
LERR="$(node "$GUARD" "$TMP" --list 2>&1 1>/dev/null)" || true
assert_contains "$LERR" '::warning::' "--list: 밴드 위반을 경고로는 남겨야 한다(조용한 통과 금지)"

# ⚠️ 대조군 — 래퍼 파일이 **아예 없는** 체크아웃은 검사 대상이 아니다(부분 체크아웃). 없으면
# "kotlin/gradle/wrapper/ 가 반드시 존재해야 한다"는 전혀 다른 가드가 된 것을 모른다.
cp -r "$FIX/." "$TMP/"
rm -rf "$TMP/kotlin/gradle"
assert_ok node "$GUARD" "$TMP"

assert_report
