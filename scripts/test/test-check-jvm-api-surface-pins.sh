#!/usr/bin/env sh
# JVM **API 표면** 핀 가드의 자가테스트.
#
# 형제 가드(`check-jvm-bytecode-floor.mjs`)와 무엇이 다른가: 그것은 방출된 `.class` 의 major 를
# 읽는다. 그런데 **major 가 61 이어도 소비자가 죽는 경로가 따로 있다** — `jvmTarget`/`-target` 은
# 클래스파일 버전만 내리고 컴파일은 **JDK 21 의 부트클래스패스에 링크된 채로** 남는다. 그러면
# 17 에 없는 API 를 불러도 컴파일이 통과하고, 실제 JDK 17 소비자가 런타임에 NoSuchMethodError /
# NoClassDefFoundError 로 죽는다. 바이트코드 가드는 그 사고를 **구조적으로 볼 수 없다**(상수풀을
# 읽지 않는다). API 표면을 묶는 것은 javac `--release` · kotlinc `-Xjdk-release` 뿐이고,
# **그 지시어들을 지키는 것이 이 가드다.**
#
# 실측(2026-09-23): `-Xjdk-release` 를 부르는 자리는 `scripts/`·`.github/` 에 다섯 군데 있는데
# **전부 주석**이고, `options.release` 는 가드 쪽에 0건이었다. 즉 그 줄을 지워도 빌드 성공 ·
# 바이트코드 floor 통과(major 는 여전히 61) · CI 초록이다.
#
# 그래서 테스트의 무게는 「통과한다」가 아니라 **「지시어가 사라진 것을 잡는가」**에 있다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-jvm-api-surface-pins.mjs"
ROOT="$(cd "$DIR/../.." && pwd)"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# 픽스처는 **텍스트**다 — 가드가 읽는 것이 정확히 이 지시어 행들이다. 해석기를 거치지 않고
# printf 로 쓴다(백슬래시·`$` 를 먹는 왕복을 만들지 않는다).
mk_java() { # mk_java <디렉터리> <release 행…>
  d="$1"; shift
  mkdir -p "$d/java"
  { printf '%s\n' '<project>' '  <properties>'
    for l in "$@"; do printf '    %s\n' "$l"; done
    printf '%s\n' '  </properties>' '  <build><plugins><plugin>' \
      '    <artifactId>maven-compiler-plugin</artifactId><version>3.16.0</version>' \
      '  </plugin></plugins></build>' '</project>'
  } > "$d/java/pom.xml"
}
mk_kotlin() { # mk_kotlin <디렉터리> <행…>
  d="$1"; shift
  mkdir -p "$d/kotlin"
  { printf '%s\n' 'kotlin {' '    compilerOptions {'
    for l in "$@"; do printf '        %s\n' "$l"; done
    printf '%s\n' '    }' '}'
  } > "$d/kotlin/build.gradle.kts"
}

K_TARGET='jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)'
K_JDKREL='freeCompilerArgs.add("-Xjdk-release=17")'
K_JAVAC='options.release.set(17)'

# ── 정상 ────────────────────────────────────────────────────────────────────
mk_java   "$FIX/ok" '<maven.compiler.release>17</maven.compiler.release>'
mk_kotlin "$FIX/ok" "$K_TARGET" "$K_JDKREL" "$K_JAVAC"
assert_ok node "$GUARD" "--root=$FIX/ok"
out=$(node "$GUARD" "--root=$FIX/ok" 2>&1 || true)
assert_contains "$out" "17" "판정에 쓴 하한을 출력한다"

# ── ⚠️ 핵심 대조군: 지시어가 하나씩 사라지면 잡아야 한다 ────────────────────
# 이 셋이 없으면 가드를 항등함수로 바꿔도 위 assert_ok 가 그대로 통과해 테스트가 공허해진다.

# (1) kotlin `-Xjdk-release` 만 사라진 경우 — **바이트코드는 여전히 61 이라 형제 가드는 초록이다.**
mk_java   "$FIX/no-jdkrel" '<maven.compiler.release>17</maven.compiler.release>'
mk_kotlin "$FIX/no-jdkrel" "$K_TARGET" "$K_JAVAC"
assert_fails node "$GUARD" "--root=$FIX/no-jdkrel"
out=$(node "$GUARD" "--root=$FIX/no-jdkrel" 2>&1 || true)
assert_contains "$out" "missing-pin" "사라진 지시어는 missing-pin 으로 보고"
assert_contains "$out" "-Xjdk-release" "어느 지시어가 빠졌는지 지목한다"

# (2) kotlin 모듈의 java 소스용 `options.release` 가 사라진 경우.
mk_java   "$FIX/no-javac" '<maven.compiler.release>17</maven.compiler.release>'
mk_kotlin "$FIX/no-javac" "$K_TARGET" "$K_JDKREL"
assert_fails node "$GUARD" "--root=$FIX/no-javac"
out=$(node "$GUARD" "--root=$FIX/no-javac" 2>&1 || true)
assert_contains "$out" "options.release" "어느 지시어가 빠졌는지 지목한다"

# (3) java 의 `maven.compiler.release` 가 사라진 경우.
mk_java   "$FIX/no-release" '<maven.compiler.encoding>UTF-8</maven.compiler.encoding>'
mk_kotlin "$FIX/no-release" "$K_TARGET" "$K_JDKREL" "$K_JAVAC"
assert_fails node "$GUARD" "--root=$FIX/no-release"
out=$(node "$GUARD" "--root=$FIX/no-release" 2>&1 || true)
assert_contains "$out" "maven.compiler.release" "어느 지시어가 빠졌는지 지목한다"

# ── ⚠️ 약한 형태로의 **교체**: `--release` 를 `source`/`target` 으로 바꾸면 값은 그대로 17 인데
# API 표면이 풀린다. 「지시어가 있는가」만 보면 이 교체를 통과시킨다.
mk_java   "$FIX/weaker" '<maven.compiler.source>17</maven.compiler.source>' \
                        '<maven.compiler.target>17</maven.compiler.target>'
mk_kotlin "$FIX/weaker" "$K_TARGET" "$K_JDKREL" "$K_JAVAC"
assert_fails node "$GUARD" "--root=$FIX/weaker"
out=$(node "$GUARD" "--root=$FIX/weaker" 2>&1 || true)
assert_contains "$out" "weaker-pin" "source/target 교체는 weaker-pin 으로 실패"

# 플러그인 설정 안의 `<source>`/`<target>` 도 같은 교체다(프로퍼티 형태만 보면 놓친다).
mkdir -p "$FIX/weaker2/java" "$FIX/weaker2/kotlin"
{ printf '%s\n' '<project><properties>' \
    '    <maven.compiler.release>17</maven.compiler.release>' \
    '</properties><build><plugins><plugin>' \
    '  <artifactId>maven-compiler-plugin</artifactId>' \
    '  <configuration><source>17</source><target>17</target></configuration>' \
    '</plugin></plugins></build></project>'
} > "$FIX/weaker2/java/pom.xml"
mk_kotlin "$FIX/weaker2" "$K_TARGET" "$K_JDKREL" "$K_JAVAC"
assert_fails node "$GUARD" "--root=$FIX/weaker2"
out=$(node "$GUARD" "--root=$FIX/weaker2" 2>&1 || true)
assert_contains "$out" "weaker-pin" "플러그인 설정 안의 source/target 도 잡는다"

# ── ⚠️ 두 레인이 **갈리는** 경우: CLAUDE.md 가 「JVM 짝은 함께 움직인다」고 쓰는 그 불변식이다.
# 한쪽만 내리면 JDK 17 소비자가 두 아티팩트 중 하나에서 UnsupportedClassVersionError 를 맞는다.
mk_java   "$FIX/split" '<maven.compiler.release>17</maven.compiler.release>'
mk_kotlin "$FIX/split" 'jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)' \
                       'freeCompilerArgs.add("-Xjdk-release=21")' 'options.release.set(21)'
assert_fails node "$GUARD" "--root=$FIX/split"
out=$(node "$GUARD" "--root=$FIX/split" 2>&1 || true)
assert_contains "$out" "floor-disagreement" "레인이 갈리면 floor-disagreement 로 실패"
assert_contains "$out" "21" "갈린 값을 둘 다 출력한다"

# 한 파일 **안에서** 갈리는 경우도 같다(`jvmTarget` 만 내리고 `-Xjdk-release` 를 두고 온 경우 —
# 이것이 실제로 가장 그럴듯한 사고다).
mk_java   "$FIX/half" '<maven.compiler.release>17</maven.compiler.release>'
mk_kotlin "$FIX/half" "$K_TARGET" 'freeCompilerArgs.add("-Xjdk-release=21")' "$K_JAVAC"
assert_fails node "$GUARD" "--root=$FIX/half"
out=$(node "$GUARD" "--root=$FIX/half" 2>&1 || true)
assert_contains "$out" "floor-disagreement" "한 파일 안의 불일치도 잡는다"

# ── ⚠️ 하한을 **함께** 올리는 것은 정당하다 — 가드가 상수 17 을 박아두면 안 된다.
mk_java   "$FIX/bump" '<maven.compiler.release>21</maven.compiler.release>'
mk_kotlin "$FIX/bump" 'jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)' \
                      'freeCompilerArgs.add("-Xjdk-release=21")' 'options.release.set(21)'
assert_ok node "$GUARD" "--root=$FIX/bump"

# ── 공허성 ──────────────────────────────────────────────────────────────────
# 빌드 파일이 옮겨지거나 이름이 바뀌면 「위반 없음」이 된다 — 이 저장소의 단골 실패다.
mkdir -p "$FIX/nofiles"
assert_fails node "$GUARD" "--root=$FIX/nofiles"
out=$(node "$GUARD" "--root=$FIX/nofiles" 2>&1 || true)
assert_contains "$out" "missing-build-file" "빌드 파일이 없으면 missing-build-file 로 실패"

# 없는 루트를 통과로 읽지 않는다.
assert_fails node "$GUARD" "--root=$FIX/does-not-exist"

# ── 실제 저장소 ─────────────────────────────────────────────────────────────
# ⚠️ 이 한 줄이 가드를 **현실에 묶는다** — 픽스처만 검사하면 지시어의 실제 표기가 바뀌었을 때
# (예: `jvmTarget = JvmTarget.JVM_17` 대입 형태로 리팩터링) 가드가 조용히 공허해진다.
assert_ok node "$GUARD" "--root=$ROOT"

assert_report
