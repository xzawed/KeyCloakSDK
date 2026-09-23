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

# ── ⚠️ kotlin 에 jvmTarget 이 없으면 툴체인이 실효 하한이다 ─────────────────
# `kotlin-v1.0.0` 이 실제로 그 상태였고 게시본이 major 65 였다. 21 로 **가정**하지 않고
# `jvmToolchain(n)` 을 읽는다는 것을 픽스처가 시험한다.
RTC="$FIX/repo-tc"
mkrepo "$RTC" 21 'freeCompilerArgs.add("-Xnothing")' keycloak-sdk keycloak-sdk-core
printf '%s\n' 'kotlin { jvmToolchain(21) }' > "$RTC/kotlin/build.gradle.kts"
git -C "$RTC" add -A && git -C "$RTC" -c user.email=t@t -c user.name=t commit -qm tc
tagit "$RTC" v9.9.0; tagit "$RTC" kotlin-v9.9.0
out=$(node "$GUARD" "--root=$RTC" "--base=$B" "--lang=kotlin" 2>&1 || true)
assert_contains "$out" "jvmToolchain" "jvmTarget 부재 시 툴체인을 실효 하한으로 읽는다"

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
assert_contains "$out" "vacuous-run" "하나도 대조하지 못한 실행은 vacuous-run 으로 실패"

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
