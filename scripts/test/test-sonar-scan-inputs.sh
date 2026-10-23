#!/usr/bin/env sh
# sonarcloud.yml 의 scan 잡이 산출물을 **데이터로만** 받는지 — 그 배치 블록을 워크플로에서 그대로 꺼내 돌린다.
#
# 산출물은 시크릿 없는 coverage 잡의 코드(미검토 의존성 포함)가 쓴다. scan 은 SONAR_TOKEN 을 쥐므로 산출물의 어떤
# 모양도 scan 안에서 코드 실행·환경 주입이 되면 안 된다. 실측(2026-10-23, 첫 판): jar 이름 검사를
# `printf '%s\n' "$b" | grep -qxE …` 로 했더니 **개행 든 이름**이 한 줄만 맞아 통과했고, 그 이름이 `$GITHUB_ENV` 로
# 들어가 이후 스텝(스캔 액션)에 임의의 환경변수를 심을 수 있었다. 정적 가드(check-ci-permissions 규칙 12)는 이런
# **값**의 문제를 못 본다 — 그래서 블록을 실제로 돌린다.
# ⚠️ 개행 든 파일 이름과 심볼릭 링크는 Windows 파일시스템·Git Bash 가 못 만들 수 있다 — 그때는 그 사례만 건너뛰고
# 알린다(CI 는 리눅스다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
WF="$DIR/../../.github/workflows/sonarcloud.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 마커 사이만 뽑고 앞 공백과 CRLF 를 벗긴다(test-release-prerelease.sh 와 같은 관용 — 워크플로는 Windows
# 체크아웃에서 CRLF 로 내려온다). 셸 블록의 들여쓰기는 꾸밈이라 통째로 벗겨도 뜻이 같다.
between() { # $1 = 마커 이름
  awk -v m="$1" '
    index($0, "# <<< " m) { inb = 0 }
    inb { sub(/\r$/, ""); sub(/^[ \t]+/, ""); print }
    index($0, "# >>> " m) { inb = 1 }
  ' "$WF"
}
between sonar-place > "$TMP/place.sh"
assert_ok test -s "$TMP/place.sh"
assert_contains "$(cat "$TMP/place.sh")" 'GITHUB_ENV' "배치 블록을 실제로 뽑았다(마커가 사라지면 이 시험이 공허해진다)"

# 넘기는 쪽(coverage 의 upload path 목록)과 받는 쪽(scan 의 배치 목록)이 **같은 집합**이어야 한다 — 한쪽에만 더하면
# 리포트가 조용히 빠지거나(scan 이 그 자리를 안 본다) scan 이 늘 실패한다.
between sonar-inputs | sed -n 's/^\([A-Za-z0-9_./-]\{1,\}\)$/\1/p' | sort > "$TMP/upload.txt"
grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+' "$TMP/place.sh" \
  | grep -E '(\.(xml|info|out|json)|/target/classes)$' | sort -u > "$TMP/placed.txt"
printf 'sonar-inputs/java-libs\n' >> "$TMP/placed.txt"
sort -o "$TMP/placed.txt" "$TMP/placed.txt"
assert_ok test -s "$TMP/upload.txt"
assert_eq "$(cat "$TMP/upload.txt")" "$(cat "$TMP/placed.txt")" "coverage 가 올리는 목록과 scan 이 받는 목록이 같다"
assert_eq "16" "$(wc -l < "$TMP/upload.txt" | tr -d ' ')" "넘기는 자리는 열여섯이다(리포트 11 · 클래스 디렉터리 4 · jar 디렉터리 1)"

# 정상 산출물 하나를 짓는다 — 리포트·클래스 디렉터리·jar 둘.
mk_in() { # $1 = 산출물 디렉터리
  while IFS= read -r p; do
    case "$p" in
      sonar-inputs/java-libs) mkdir -p "$1/$p"; : > "$1/$p/001-a-1.0.jar"; : > "$1/$p/002-b_c+d-2.0.jar" ;;
      */target/classes) mkdir -p "$1/$p/io/x"; : > "$1/$p/io/x/A.class" ;;
      *) mkdir -p "$(dirname "$1/$p")"; printf 'report\n' > "$1/$p" ;;
    esac
  done < "$TMP/upload.txt"
}
# place <산출물> — 새 작업 디렉터리에서 블록을 돌린다. RC 와 ENVF(= $GITHUB_ENV) 를 남긴다.
place() {
  WORK="$(mktemp -d "$TMP/work.XXXXXX")"
  ENVF="$WORK/.github_env"
  : > "$ENVF"
  RC=0
  (cd "$WORK" && IN="$1" GITHUB_ENV="$ENVF" bash "$TMP/place.sh") > "$WORK/.out" 2>&1 || RC=$?
}

# (1) 정상 — 통과하고, GITHUB_ENV 에는 정확히 한 줄, 리포트와 클래스는 정해진 자리에 있다.
IN1="$TMP/in1"; mk_in "$IN1"; place "$IN1"
assert_eq 0 "$RC" "정상 산출물은 통과한다: $(cat "$WORK/.out")"
assert_eq 1 "$(wc -l < "$ENVF" | tr -d ' ')" "GITHUB_ENV 에는 한 줄만 쓴다"
assert_contains "$(cat "$ENVF")" "SONAR_JAVA_LIBS=$IN1/sonar-inputs/java-libs/001-a-1.0.jar,$IN1/sonar-inputs/java-libs/002-b_c+d-2.0.jar" "jar 경로를 받은 자리로 짓는다"
assert_ok test -f "$WORK/go/cover.out"
assert_ok test -f "$WORK/java/keycloak-sdk-core/target/classes/io/x/A.class"

# (2) 산출물 루트의 덤 파일은 옮기지 않는다 — 설정을 덮는 통로가 없다.
IN2="$TMP/in2"; mk_in "$IN2"; printf 'sonar.host.url=https://evil.example\n' > "$IN2/sonar-project.properties"; place "$IN2"
assert_eq 0 "$RC" "덤 파일이 있어도 정해진 것만 옮기고 통과한다"
assert_fails test -e "$WORK/sonar-project.properties"

# (3) 리포트 하나가 빠지면 스캔하지 않는다(생성 실패가 「덜 본 초록」이 되지 않게).
IN3="$TMP/in3"; mk_in "$IN3"; rm "$IN3/python/coverage.xml"; place "$IN3"
assert_eq 1 "$RC" "리포트가 빠지면 실패한다"
assert_contains "$(cat "$WORK/.out")" "python/coverage.xml 가 산출물에 없다" "빠진 자리를 댄다"

# (4) jar 가 없으면 실패한다.
IN4="$TMP/in4"; mk_in "$IN4"; rm "$IN4"/sonar-inputs/java-libs/*.jar; place "$IN4"
assert_eq 1 "$RC" "jar 가 없으면 실패한다"
assert_contains "$(cat "$WORK/.out")" "sonar.java.libraries 가 비었다" "빈 클래스패스를 댄다"

# (5) 공백 든 jar 이름 — 스캔 args 로 들어가면 공백 하나가 스캐너 속성 주입이 된다.
IN5="$TMP/in5"; mk_in "$IN5"; : > "$IN5/sonar-inputs/java-libs/003-x -Dsonar.scanner.javaExePath=y.jar"; place "$IN5"
assert_eq 1 "$RC" "공백 든 jar 이름은 받지 않는다"
assert_eq 0 "$(wc -l < "$ENVF" | tr -d ' ')" "거부하면 GITHUB_ENV 에 아무것도 쓰지 않는다"

# (6) jar 자리가 디렉터리면 실패한다.
IN6="$TMP/in6"; mk_in "$IN6"; mkdir "$IN6/sonar-inputs/java-libs/003-dir.jar"; place "$IN6"
assert_eq 1 "$RC" "jar 자리가 파일이 아니면 실패한다"

# (7) 개행 든 jar 이름 — 첫 판의 구멍. 한 줄만 맞는 이름이 통과하면 둘째 줄이 GITHUB_ENV 의 새 변수가 된다.
IN7="$TMP/in7"; mk_in "$IN7"
NL_NAME="$(printf '003-x.jar\nNODE_OPTIONS=--require=evil.jar')"
if : > "$IN7/sonar-inputs/java-libs/$NL_NAME" 2>/dev/null && [ -f "$IN7/sonar-inputs/java-libs/$NL_NAME" ]; then
  place "$IN7"
  assert_eq 1 "$RC" "개행 든 jar 이름은 받지 않는다"
  assert_not_contains "$(cat "$ENVF")" "NODE_OPTIONS" "GITHUB_ENV 로 새 변수가 새지 않는다"
else
  printf 'SKIP 이 파일시스템은 개행 든 파일 이름을 못 만든다 — 사례 (7) 은 CI(리눅스)에서 돈다\n' >&2
fi

# (8) 심볼릭 링크는 받지 않는다.
IN8="$TMP/in8"; mk_in "$IN8"
if ln -s /etc/hostname "$IN8/go/link" 2>/dev/null && [ -L "$IN8/go/link" ]; then
  place "$IN8"
  assert_eq 1 "$RC" "심볼릭 링크가 든 산출물은 받지 않는다"
  assert_contains "$(cat "$WORK/.out")" "심볼릭 링크" "그 이유를 댄다"
else
  printf 'SKIP 이 환경은 심볼릭 링크를 못 만든다 — 사례 (8) 은 CI(리눅스)에서 돈다\n' >&2
fi

assert_report
