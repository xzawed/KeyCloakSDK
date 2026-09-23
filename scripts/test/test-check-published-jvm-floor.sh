#!/usr/bin/env sh
# **게시된 바이트** 오라클의 자가테스트.
#
# 이 가드가 채우는 칸: 문서↔태그(`kind=runtime`)와 태그↔소스핀(`check-jvm-api-surface-pins`)은
# 저장소 안만 본다. 릴리스가 다른 JDK 로 빌드했거나 업로드가 깨졌으면 **소비자가 받는 것만
# 다르고 저장소는 전부 초록**이다. 그 칸은 레지스트리에서 바이트를 받아야만 닫힌다.
#
# ⚠️ **네트워크를 쓰지 않는다.** 가드의 `--base` 가 디렉터리를 받으므로 repo1 의 경로 구조를
# 흉내 낸 픽스처 트리로 전부 검증한다. 네트워크 자체는 스케줄 워크플로가 지나간다.
#
# ⚠️ 테스트의 무게는 「통과한다」가 아니라 **(1) 하한을 넘은 바이트를 잡는가 (2) 0 개를 훑고
# 통과하지 않는가 (3) 하한 숫자를 박아두지 않았는가**에 있다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-published-jvm-floor.mjs"
MKJAR="$DIR/mkjar.mjs"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

G="io/github/xzawed"

# ── 픽스처: 저장소 쪽(태그가 하한을 소유한다) ──────────────────────────────
# `--root` 가 받는 것은 `scripts/lib/deploy-facts.sh`(좌표)와 git 태그(하한) 둘뿐이다.
mkrepo() { # mkrepo <디렉터리> <java-release> <kotlin-줄> [모듈…]
  d="$1"; jrel="$2"; kline="$3"; shift 3
  mkdir -p "$d/scripts/lib" "$d/java" "$d/kotlin"
  { printf '%s\n' 'df_check_url() { case "$1" in' \
      "  java) echo \"https://repo1.maven.org/maven2/$G/keycloak-sdk/maven-metadata.xml\" ;;" \
      "  kotlin) echo \"https://repo1.maven.org/maven2/$G/keycloak-sdk-kotlin/maven-metadata.xml\" ;;" \
      'esac; }'
  } > "$d/scripts/lib/deploy-facts.sh"
  { printf '%s\n' '<project><properties>'
    [ -n "$jrel" ] && printf '  <maven.compiler.release>%s</maven.compiler.release>\n' "$jrel"
    printf '%s\n' '</properties>' '<modules>'
    for m in "$@"; do printf '  <module>%s</module>\n' "$m"; done
    printf '%s\n' '</modules></project>'
  } > "$d/java/pom.xml"
  printf '%s\n' 'kotlin { compilerOptions {' "  $kline" '} }' > "$d/kotlin/build.gradle.kts"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm f
}
tagit() { git -C "$1" tag -f "$2" >/dev/null 2>&1; }

# ── 픽스처: 레지스트리 쪽(repo1 경로 구조를 흉내 낸다) ──────────────────────
reg_meta() { # reg_meta <base> <artifact> <version…>
  b="$1"; a="$2"; shift 2
  mkdir -p "$b/$G/$a"
  { printf '%s\n' '<metadata><versioning><versions>'
    for v in "$@"; do printf '  <version>%s</version>\n' "$v"; done
    printf '%s\n' '</versions></versioning></metadata>'
  } > "$b/$G/$a/maven-metadata.xml"
}
reg_pom() { # reg_pom <base> <artifact> <version> <packaging>
  mkdir -p "$1/$G/$2/$3"
  printf '<project><packaging>%s</packaging></project>\n' "$4" > "$1/$G/$2/$3/$2-$3.pom"
}
reg_jar() { # reg_jar <base> <artifact> <version> <mkjar 인자…>
  b="$1"; a="$2"; v="$3"; shift 3
  mkdir -p "$b/$G/$a/$v"
  node "$MKJAR" "$b/$G/$a/$v/$a-$v.jar" "$@"
}

K17='jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)'

# 정상 트리 하나를 만들어 여러 케이스가 공유한다.
R="$FIX/repo"; B="$FIX/base"
mkrepo "$R" 17 "$K17" keycloak-sdk keycloak-sdk-core
tagit "$R" v9.9.0; tagit "$R" kotlin-v9.9.0
for a in keycloak-sdk keycloak-sdk-core; do
  reg_meta "$B" "$a" 9.9.0; reg_pom "$B" "$a" 9.9.0 jar; reg_jar "$B" "$a" 9.9.0 61:2
done
reg_meta "$B" keycloak-sdk-kotlin 9.9.0; reg_pom "$B" keycloak-sdk-kotlin 9.9.0 jar
reg_jar "$B" keycloak-sdk-kotlin 9.9.0 61:2

assert_ok node "$GUARD" "--root=$R" "--base=$B"
out=$(node "$GUARD" "--root=$R" "--base=$B" 2>&1 || true)
assert_contains "$out" "keycloak-sdk-core" "집합 모듈만 보지 않고 형제 모듈도 읽는다"
assert_contains "$out" "클래스" "읽은 클래스 수를 출력한다"

# ── ⚠️ 핵심 대조군: 게시된 바이트가 태그 선언을 넘으면 잡아야 한다 ──────────
# 이것이 없으면 가드를 항등함수로 바꿔도 위 assert_ok 가 통과해 테스트가 공허해진다.
cp -r "$B" "$FIX/b-over"
reg_jar "$FIX/b-over" keycloak-sdk-core 9.9.0 65:2   # 태그는 17 인데 바이트는 21
assert_fails node "$GUARD" "--root=$R" "--base=$FIX/b-over"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-over" 2>&1 || true)
assert_contains "$out" "published-above-floor" "하한 초과는 published-above-floor 로 보고"
assert_contains "$out" "keycloak-sdk-core" "어느 아티팩트인지 지목한다"
assert_contains "$out" "major 65" "실제로 읽은 major 를 출력한다"

# ── ⚠️ **경계값** — feature→major 환산이 한 칸 어긋나도 잡아야 한다 ────────
# 변이 증명이 낸 진짜 구멍이다(P1: `feature + 44` → `+ 45` 가 **SILENT** 이었다). 65 대 61 처럼
# 멀리 떨어진 케이스만 있으면 상한이 한 칸 느슨해져도 전부 통과한다 — 그 한 칸이 곧 「JDK 18
# 로 빌드된 것을 17 이라고 통과시킨다」이다. 하한 17 의 상한은 **정확히 major 61** 이므로,
# 62 는 실패하고 61 은 통과해야 한다. 이 두 줄이 환산식을 고정한다.
cp -r "$B" "$FIX/b-edge"
reg_jar "$FIX/b-edge" keycloak-sdk-core 9.9.0 62:1   # 하한 바로 한 칸 위
assert_fails node "$GUARD" "--root=$R" "--base=$FIX/b-edge"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-edge" 2>&1 || true)
assert_contains "$out" "major 62" "하한보다 한 칸 높은 것도 잡는다"
assert_contains "$out" "major 61" "환산한 상한을 출력한다(17 → 61)"

cp -r "$B" "$FIX/b-exact"
reg_jar "$FIX/b-exact" keycloak-sdk-core 9.9.0 61:1  # 하한과 정확히 같은 칸
assert_ok node "$GUARD" "--root=$R" "--base=$FIX/b-exact"

# ── ⚠️ 하한 숫자를 박아두지 않았는가 ────────────────────────────────────────
# 17→21 로 **함께** 올리는 것은 정당한 결정이다. 가드가 17 을 상수로 들고 있으면 그때 막고,
# 막히면 가드가 꺼진다. 같은 바이트(65)가 태그 선언 21 아래에서는 통과해야 한다.
R21="$FIX/repo21"
mkrepo "$R21" 21 'jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)' keycloak-sdk keycloak-sdk-core
tagit "$R21" v9.9.0; tagit "$R21" kotlin-v9.9.0
assert_ok node "$GUARD" "--root=$R21" "--base=$FIX/b-over"

# ── ⚠️ kotlin 하한 파생 — **라벨이 아니라 값**을 단언한다 ───────────────────
# 독립 리뷰가 낸 구멍이다: 예전 케이스는 `assert_contains "$out" "jvmToolchain"` 하나였는데
# `floor.how` 는 **통과 메시지와 실패 메시지 양쪽에** 들어간다. 게다가 `|| true` 로 종료코드를
# 버려서, 파생값을 `-8` 해도(21→13, cap 57) 이 테스트는 그대로 통과했다 — **값이 한 번도
# 시험되지 않았다.** 그래서 종료코드와 **환산된 상한 숫자**를 함께 고정한다.
kt_repo() { # kt_repo <디렉터리> <kotlin/build.gradle.kts 내용 한 줄…>
  d="$1"; shift
  mkrepo "$d" 21 'freeCompilerArgs.add("-Xnothing")' keycloak-sdk keycloak-sdk-core
  printf '%s\n' "$@" > "$d/kotlin/build.gradle.kts"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm kt
  tagit "$d" v9.9.0; tagit "$d" kotlin-v9.9.0
}

RTC="$FIX/repo-tc"; kt_repo "$RTC" 'kotlin { jvmToolchain(21) }'
assert_ok node "$GUARD" "--root=$RTC" "--base=$B" "--lang=kotlin"
out=$(node "$GUARD" "--root=$RTC" "--base=$B" "--lang=kotlin" 2>&1 || true)
assert_contains "$out" "jvmToolchain" "jvmTarget 부재 시 툴체인을 실효 하한으로 읽는다"
assert_contains "$out" "major ≤ 65" "**파생한 값**을 단언한다(툴체인 21 → 상한 65)"

# 같은 픽스처(major 61)가 툴체인 17 선언 아래에서도 통과하고, 66 짜리는 걸린다 — 값이 실제로
# 쓰인다는 양방향 대조.
RTC17="$FIX/repo-tc17"; kt_repo "$RTC17" 'kotlin { jvmToolchain(17) }'
out=$(node "$GUARD" "--root=$RTC17" "--base=$B" "--lang=kotlin" 2>&1 || true)
assert_contains "$out" "major ≤ 61" "툴체인 17 → 상한 61 로 환산한다"

# `jvmToolchain(JavaLanguageVersion.of(21))` 은 **같은 선언**이다 — 표기 하나 때문에 레인이
# 통째로 꺼지면 안 된다(그것이 F1 의 실제 방아쇠였다).
RTCJ="$FIX/repo-tc-jlv"; kt_repo "$RTCJ" 'kotlin { jvmToolchain(JavaLanguageVersion.of(21)) }'
assert_ok node "$GUARD" "--root=$RTCJ" "--base=$B" "--lang=kotlin"

# ⚠️ **`JVM_1_8` 은 feature 8 이다.** `JVM_(\d+)` 로 읽으면 **1**(상한 45)이 되어 정당한 Java 8
# 릴리스를 전부 위반으로 찍는다. 8 → 상한 52 이므로 major 52 는 통과해야 한다.
RJ8="$FIX/repo-jvm18"; kt_repo "$RJ8" 'kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_1_8) } }'
cp -r "$B" "$FIX/b-j8"; reg_jar "$FIX/b-j8" keycloak-sdk-kotlin 9.9.0 52:2
assert_ok node "$GUARD" "--root=$RJ8" "--base=$FIX/b-j8" "--lang=kotlin"
out=$(node "$GUARD" "--root=$RJ8" "--base=$FIX/b-j8" "--lang=kotlin" 2>&1 || true)
assert_contains "$out" "major ≤ 52" "JVM_1_8 → feature 8 → 상한 52"

# ⚠️ **주석 안의 표기를 선언으로 읽지 않는다.** 비-전역 exec 는 첫 텍스트 일치를 취하므로,
# 위쪽 주석이 JVM_21 을 언급하면 그것이 하한이 된다(올리면 나쁜 바이트가 통과한다).
RCM="$FIX/repo-kt-cmt"
kt_repo "$RCM" '// 예전엔 JvmTarget.JVM_21 이었다' 'kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }'
out=$(node "$GUARD" "--root=$RCM" "--base=$B" "--lang=kotlin" 2>&1 || true)
assert_contains "$out" "major ≤ 61" "주석의 JVM_21 이 아니라 살아 있는 JVM_17 을 읽는다"

# ── ⚠️ 레인 단위 공허 — 한쪽이 살아 있으면 다른 쪽의 죽음이 가려진다 ───────
# 독립 리뷰가 낸 구멍이고 **실측으로 확인됐다**: 전역 카운터 하나뿐이라 kotlin 하한 선언을
# 못 읽게 만들자 kotlin `ok` 줄이 0 개인데 **exit 0** 이었다. 방아쇠는 평범하다 —
# `jvmToolchain(JavaLanguageVersion.of(21))` 표기 하나면 된다.
RDEAD="$FIX/repo-lane-dead"; kt_repo "$RDEAD" 'kotlin { someUnknownSpelling(21) }'
assert_fails node "$GUARD" "--root=$RDEAD" "--base=$B"
out=$(node "$GUARD" "--root=$RDEAD" "--base=$B" 2>&1 || true)
assert_contains "$out" "vacuous-lane" "한 레인이 통째로 죽으면 vacuous-lane 으로 실패"
assert_contains "$out" "keycloak-sdk-core" "다른 레인은 그대로 검사된다(전부 멈추지 않는다)"

# ── ⚠️ java 하한을 플러그인 설정으로 옮겨도 읽는다 ──────────────────────────
# 프로퍼티만 읽으면 평범한 pom 리팩터 하나로 java 레인이 통째로 조용히 꺼진다.
RPC="$FIX/repo-plugincfg"
mkrepo "$RPC" '' "$K17" keycloak-sdk keycloak-sdk-core
{ printf '%s\n' '<project><properties></properties><modules>' \
    '  <module>keycloak-sdk</module>' '  <module>keycloak-sdk-core</module>' '</modules>' \
    '<build><plugins><plugin><artifactId>maven-compiler-plugin</artifactId>' \
    '<configuration><release>17</release></configuration></plugin></plugins></build></project>'
} > "$RPC/java/pom.xml"
git -C "$RPC" add -A && git -C "$RPC" -c user.email=t@t -c user.name=t commit -qm pc
tagit "$RPC" v9.9.0; tagit "$RPC" kotlin-v9.9.0
assert_ok node "$GUARD" "--root=$RPC" "--base=$B" "--lang=java"
out=$(node "$GUARD" "--root=$RPC" "--base=$B" "--lang=java" 2>&1 || true)
assert_contains "$out" "maven-compiler-plugin <release>" "플러그인 설정의 release 도 하한 선언이다"

# ── pom 패키징은 jar 가 **없는 것이 정상**이다 ──────────────────────────────
# ⚠️ 404 를 「jar 없음」의 증거로 쓰면 정당한 BOM 을 위반으로 읽는다 — 2026-09-06 손측정에서
# 독립 레그가 지목한 지점이다. <packaging> 을 먼저 읽는다.
cp -r "$B" "$FIX/b-bom"
reg_meta "$FIX/b-bom" keycloak-sdk-bom 9.9.0; reg_pom "$FIX/b-bom" keycloak-sdk-bom 9.9.0 pom
RB="$FIX/repo-bom"
mkrepo "$RB" 17 "$K17" keycloak-sdk keycloak-sdk-core keycloak-sdk-bom
tagit "$RB" v9.9.0; tagit "$RB" kotlin-v9.9.0
assert_ok node "$GUARD" "--root=$RB" "--base=$FIX/b-bom"
out=$(node "$GUARD" "--root=$RB" "--base=$FIX/b-bom" 2>&1 || true)
assert_contains "$out" "packaging>pom" "pom 패키징은 건너뛰고 그 사실을 밝힌다"

# 그런데 **jar 패키징인데 jar 가 없으면** 그것은 부분 업로드 실패다.
cp -r "$B" "$FIX/b-nojar"
rm -f "$FIX/b-nojar/$G/keycloak-sdk-core/9.9.0/keycloak-sdk-core-9.9.0.jar"
assert_fails node "$GUARD" "--root=$R" "--base=$FIX/b-nojar"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-nojar" 2>&1 || true)
assert_contains "$out" "missing-jar" "jar 패키징인데 바이트가 없으면 missing-jar"

# metadata 가 싣는데 pom 이 없으면 레지스트리 자기모순이다.
cp -r "$B" "$FIX/b-nopom"
rm -f "$FIX/b-nopom/$G/keycloak-sdk-core/9.9.0/keycloak-sdk-core-9.9.0.pom"
assert_fails node "$GUARD" "--root=$R" "--base=$FIX/b-nopom"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-nopom" 2>&1 || true)
assert_contains "$out" "missing-pom" "metadata 가 싣는데 pom 이 없으면 missing-pom"

# 아티팩트 자신의 metadata 에 그 버전이 없으면 건너뛴다(`-examples` 가 실제로 그 경우다).
cp -r "$B" "$FIX/b-skip"
reg_meta "$FIX/b-skip" keycloak-sdk-examples 0.1.0
RE="$FIX/repo-ex"
mkrepo "$RE" 17 "$K17" keycloak-sdk keycloak-sdk-core keycloak-sdk-examples
tagit "$RE" v9.9.0; tagit "$RE" kotlin-v9.9.0
assert_ok node "$GUARD" "--root=$RE" "--base=$FIX/b-skip"
out=$(node "$GUARD" "--root=$RE" "--base=$FIX/b-skip" 2>&1 || true)
assert_contains "$out" "metadata 에 그 버전이 없다" "버전이 없는 아티팩트는 건너뛰고 밝힌다"

# ── 공허성 ──────────────────────────────────────────────────────────────────
# ⚠️ 독립 레그가 「이 오라클이 영원히 초록이 되는 가장 그럴듯한 길」로 지목한 것이 이 부류다 —
# 404·건너뜀 경로가 조용히 0 을 내고 exit 0 으로 끝난다.
cp -r "$B" "$FIX/b-notag"
RNT="$FIX/repo-notag"
mkrepo "$RNT" 17 "$K17" keycloak-sdk keycloak-sdk-core   # 태그를 달지 않는다
assert_fails node "$GUARD" "--root=$RNT" "--base=$FIX/b-notag"
out=$(node "$GUARD" "--root=$RNT" "--base=$FIX/b-notag" 2>&1 || true)
# ⚠️ 여기서 나오는 것은 `vacuous-run` 이 **아니라** 레인별 `vacuous-lane` 이다 — 두 레인이 각각
# 울기 때문이다. 레인 단위가 더 구체적이라 그쪽이 먼저 잡는 것이 맞고, `vacuous-run` 은 그것이
# 선점하지 못하는 미래의 경로를 위한 백스톱으로 남는다(**오늘은 도달하지 않는다** — 테스트가
# 그것을 덮는다고 주장하지 않는다).
assert_contains "$out" "vacuous-lane" "하나도 대조하지 못한 레인은 vacuous-lane 으로 실패"

# jar 안에 클래스가 0 개면 「위반 없음」이 아니다.
cp -r "$B" "$FIX/b-empty"
reg_jar "$FIX/b-empty" keycloak-sdk-core 9.9.0 --empty
assert_fails node "$GUARD" "--root=$R" "--base=$FIX/b-empty"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-empty" 2>&1 || true)
assert_contains "$out" "vacuous-jar" "클래스 0 개 jar 는 vacuous-jar 로 실패"

# java 인데 <modules> 를 못 뽑으면 집합 모듈 하나만 남아 공허하다.
RNM="$FIX/repo-nomod"
mkrepo "$RNM" 17 "$K17"    # 모듈 없음
tagit "$RNM" v9.9.0; tagit "$RNM" kotlin-v9.9.0
assert_fails node "$GUARD" "--root=$RNM" "--base=$B" "--lang=java"
out=$(node "$GUARD" "--root=$RNM" "--base=$B" "--lang=java" 2>&1 || true)
assert_contains "$out" "no-siblings" "모듈 파생이 깨지면 no-siblings 로 실패"

# 좌표의 출처가 사라지면 검사가 성립하지 않는다.
RNC="$FIX/repo-nocoord"
mkrepo "$RNC" 17 "$K17" keycloak-sdk
printf '%s\n' 'df_check_url() { :; }' > "$RNC/scripts/lib/deploy-facts.sh"
assert_fails node "$GUARD" "--root=$RNC" "--base=$B"
out=$(node "$GUARD" "--root=$RNC" "--base=$B" 2>&1 || true)
assert_contains "$out" "vacuous-scan" "repo1 좌표를 못 읽으면 vacuous-scan"

# SSOT 파일 자체가 없으면 통과로 읽지 않는다.
mkdir -p "$FIX/bare"
assert_fails node "$GUARD" "--root=$FIX/bare" "--base=$B"

# ── ⚠️ 형제가 **조용히 증발**하면 안 된다 ──────────────────────────────────
# 독립 리뷰가 낸 구멍: `no-siblings` 는 목록이 비었는지만 봤고, 목록에 있는 형제가 **해결되지
# 않는 것**은 전부 메모였다. 최악의 경우 형제 전부가 건너뛰어지고 집합 모듈의 **1 클래스**만
# 읽혀 `ok … 클래스 1개` 가 나온다 — 이 파일 머리말이 막겠다고 적은 바로 그 상태다.
mkmod() { # mkmod <repo> <디렉터리> <artifactId> <packaging>
  mkdir -p "$1/java/$2"
  printf '%s\n' '<project>' '  <parent><artifactId>keycloak-sdk-parent</artifactId></parent>' \
    "  <artifactId>$3</artifactId>" "  <packaging>$4</packaging>" '</project>' > "$1/java/$2/pom.xml"
}

# (a) 태그가 모듈이라 말하는데 레지스트리에 그 좌표가 아예 없다 → 실패다(메모가 아니다).
RGONE="$FIX/repo-gone"
mkrepo "$RGONE" 17 "$K17" keycloak-sdk keycloak-sdk-core keycloak-sdk-ghost
mkmod "$RGONE" keycloak-sdk-ghost keycloak-sdk-ghost jar
git -C "$RGONE" add -A && git -C "$RGONE" -c user.email=t@t -c user.name=t commit -qm ghost
tagit "$RGONE" v9.9.0; tagit "$RGONE" kotlin-v9.9.0
assert_fails node "$GUARD" "--root=$RGONE" "--base=$B" "--lang=java"
out=$(node "$GUARD" "--root=$RGONE" "--base=$B" "--lang=java" 2>&1 || true)
assert_contains "$out" "unknown-module-artifact" "레지스트리에 없는 모듈 좌표는 실패다"

# (b) 단, 루트 pom 의 `<excludeArtifacts>` 가 뺀 모듈이면 없는 것이 정상이다 — **태그가 말한다.**
REX="$FIX/repo-excl"
mkrepo "$REX" 17 "$K17" keycloak-sdk keycloak-sdk-core keycloak-sdk-ghost
mkmod "$REX" keycloak-sdk-ghost keycloak-sdk-ghost jar
{ printf '%s\n' '<project><properties>' '  <maven.compiler.release>17</maven.compiler.release>' \
    '</properties><modules>' '  <module>keycloak-sdk</module>' '  <module>keycloak-sdk-core</module>' \
    '  <module>keycloak-sdk-ghost</module>' '</modules>' \
    '<excludeArtifacts><excludeArtifact>keycloak-sdk-ghost</excludeArtifact></excludeArtifacts>' '</project>'
} > "$REX/java/pom.xml"
git -C "$REX" add -A && git -C "$REX" -c user.email=t@t -c user.name=t commit -qm excl
tagit "$REX" v9.9.0; tagit "$REX" kotlin-v9.9.0
assert_ok node "$GUARD" "--root=$REX" "--base=$B" "--lang=java"
out=$(node "$GUARD" "--root=$REX" "--base=$B" "--lang=java" 2>&1 || true)
assert_contains "$out" "excludeArtifacts" "게시 제외는 태그에서 파생해 정당한 건너뜀으로 읽는다"

# (c) ⚠️ **`<module>` 은 디렉터리이지 artifactId 가 아니다.** 지금은 같지만 강제하는 것이 없다 —
# 디렉터리만 바꾸면 그 모듈이 영영 조용히 빠진다. 모듈 pom 의 artifactId 를 읽어야 한다.
# ⚠️ 그 pom 의 **첫 `<artifactId>` 는 `<parent>` 의 것**이므로 parent 를 먼저 지워야 한다
# (실측: `keycloak-sdk-core/pom.xml` 의 첫 값은 `keycloak-sdk-parent` 다). mkmod 가 그 모양이다.
RDIR="$FIX/repo-dirname"
mkrepo "$RDIR" 17 "$K17" keycloak-sdk core
mkmod "$RDIR" core keycloak-sdk-core jar
git -C "$RDIR" add -A && git -C "$RDIR" -c user.email=t@t -c user.name=t commit -qm dir
tagit "$RDIR" v9.9.0; tagit "$RDIR" kotlin-v9.9.0
assert_ok node "$GUARD" "--root=$RDIR" "--base=$B" "--lang=java"
out=$(node "$GUARD" "--root=$RDIR" "--base=$B" "--lang=java" 2>&1 || true)
assert_contains "$out" "keycloak-sdk-core" "디렉터리명이 달라도 pom 의 artifactId 로 찾는다"

# (d) pom 패키징 모듈은 jar 를 요청하지 않는다 — 태그의 pom 에서 읽는다.
RPOM="$FIX/repo-pompkg"
mkrepo "$RPOM" 17 "$K17" keycloak-sdk keycloak-sdk-core keycloak-sdk-bom
mkmod "$RPOM" keycloak-sdk-bom keycloak-sdk-bom pom
git -C "$RPOM" add -A && git -C "$RPOM" -c user.email=t@t -c user.name=t commit -qm bom
tagit "$RPOM" v9.9.0; tagit "$RPOM" kotlin-v9.9.0
assert_ok node "$GUARD" "--root=$RPOM" "--base=$B" "--lang=java"

# (e) ⚠️ **버전 하나만 조용히 빠지는 경우** — 레인 단위 검사로는 못 본다(다른 버전이 읽히므로
# 레인은 공허하지 않다). 변이 증명이 낸 구멍이다(P12: `readThisVersion === 0` 무력화가 **SILENT**
# 이었다). 여기서는 9.9.1 의 집합 모듈이 pom 패키징이고 형제 metadata 에 9.9.1 이 없어,
# **그 버전에서 읽히는 것이 0 개**가 된다.
RV2="$FIX/repo-ver2"
mkrepo "$RV2" 17 "$K17" keycloak-sdk keycloak-sdk-core
tagit "$RV2" v9.9.0; tagit "$RV2" v9.9.1; tagit "$RV2" kotlin-v9.9.0
BV="$FIX/b-ver2"; cp -r "$B" "$BV"
reg_meta "$BV" keycloak-sdk 9.9.0 9.9.1
reg_pom  "$BV" keycloak-sdk 9.9.1 pom          # 집합 모듈이 그 버전에선 pom 패키징
# keycloak-sdk-core 의 metadata 는 9.9.0 만 싣는다(위 $B 복사본 그대로) → 9.9.1 은 건너뛴다
assert_fails node "$GUARD" "--root=$RV2" "--base=$BV" "--lang=java"
out=$(node "$GUARD" "--root=$RV2" "--base=$BV" "--lang=java" 2>&1 || true)
assert_contains "$out" "vacuous-version" "한 버전에서 아무것도 못 읽으면 vacuous-version"
assert_contains "$out" "9.9.1" "어느 버전이 비었는지 지목한다"
assert_contains "$out" "9.9.0" "다른 버전은 그대로 검사된다"

# ── ⚠️ preview 바이트 — major 는 하한 안인데 소비자가 못 읽는다 ────────────
# 독립 리뷰가 낸 구멍. `--enable-preview` 로 컴파일된 클래스는 major 가 정직하게 61 이면서
# minor 가 0xFFFF 이고, JDK 18+ 과 `--enable-preview` 없는 JDK 17 양쪽에서 로드되지 않는다.
# 태그는 preview 를 선언한 적이 없으므로 **선언과 다른 바이트**의 교과서적 사례다.
cp -r "$B" "$FIX/b-preview"
reg_jar "$FIX/b-preview" keycloak-sdk-core 9.9.0 61:2 --preview
assert_fails node "$GUARD" "--root=$R" "--base=$FIX/b-preview"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-preview" 2>&1 || true)
assert_contains "$out" "published-preview-class" "preview 클래스는 major 가 하한 안이어도 실패"

# ── ⚠️ `.class` 인데 CAFEBABE 가 아니면 major 를 **지어내지** 않는다 ───────
# zip 오프셋 해석이 어긋나면 임의 바이트의 6~7 을 major 로 읽는다. 매직을 보면 그 부류가
# 조용한 오답이 아니라 예외가 된다.
cp -r "$B" "$FIX/b-magic"
reg_jar "$FIX/b-magic" keycloak-sdk-core 9.9.0 61:2 --bad-magic
assert_fails node "$GUARD" "--root=$R" "--base=$FIX/b-magic"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-magic" 2>&1 || true)
assert_contains "$out" "매직 불일치" "클래스파일이 아니면 매직 불일치로 실패"

# ── ⚠️ 아카이브 주석 안의 가짜 EOCD 서명 ───────────────────────────────────
# zip 의 아카이브 주석은 임의 바이트다. 그 안에 EOCD 4바이트가 들어 있으면 **뒤에서부터 서명만
# 찾는 리더가 가짜를 먼저 만난다**(실측: 중앙 디렉터리 오프셋이 1094795585 로 읽혀 예외가 났다).
# 조용한 통과는 아니지만 **정상 jar 가 우연히 그 바이트를 품으면 화요일 새벽 거짓 경보**다.
# 진짜 EOCD 는 「주석 길이 == 남은 바이트」를 만족하므로 그것으로 가린다 — 이 케이스가 그 필터를
# 고정한다(필터를 지우면 아래 assert_ok 가 예외로 깨진다).
cp -r "$B" "$FIX/b-trap"
reg_jar "$FIX/b-trap" keycloak-sdk-core 9.9.0 61:2 --trap-comment
assert_ok node "$GUARD" "--root=$R" "--base=$FIX/b-trap"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-trap" 2>&1 || true)
assert_contains "$out" "keycloak-sdk-core" "주석 함정이 있어도 진짜 EOCD 를 찾아 읽는다"

# 함정이 있으면서 **실제로 하한을 넘는** 경우 — 함정 때문에 검사가 건너뛰어지면 안 된다.
cp -r "$B" "$FIX/b-trap-over"
reg_jar "$FIX/b-trap-over" keycloak-sdk-core 9.9.0 65:2 --trap-comment
assert_fails node "$GUARD" "--root=$R" "--base=$FIX/b-trap-over"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-trap-over" 2>&1 || true)
assert_contains "$out" "published-above-floor" "주석 함정이 위반을 가리지 않는다"

# ── Multi-Release jar 는 **의도적으로** 높다 ────────────────────────────────
# 제외하지 않으면 정당한 MR-jar 를 막게 되고, 그러면 이 가드는 꺼지게 된다.
cp -r "$B" "$FIX/b-mr"
reg_jar "$FIX/b-mr" keycloak-sdk-core 9.9.0 61:2 --mr=65
assert_ok node "$GUARD" "--root=$R" "--base=$FIX/b-mr"
out=$(node "$GUARD" "--root=$R" "--base=$FIX/b-mr" 2>&1 || true)
assert_contains "$out" "MR 제외" "Multi-Release 제외를 출력에 밝힌다"

assert_report
