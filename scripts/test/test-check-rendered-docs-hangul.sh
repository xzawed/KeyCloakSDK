#!/usr/bin/env sh
# 그려지는 문서 한글 계수기(`check-rendered-docs-hangul.mjs`)의 자가테스트.
#
# 왜: 이 계수기는 레인 CI 가 만든 산출물을 본다 — 실제 트리로는 「0」이 「셌고 깨끗하다」인지 「볼 것을 못
# 찾았다」인지 구분되지 않는다. 그래서 양성(한글을 잡는다) · 음성(영문만이면 0) · 공허(파일이 없으면 2)와
# 필터 둘을 고정한다. 픽스처는 TMP 에 만든다 — 커밋한 산출물 픽스처는 `.gitignore` 의 `dist/` 류에 삼켜져
# 로컬은 초록, CI 는 빨강이 될 수 있다(`test-check-node-public-surface.sh` 머리 주석).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-rendered-docs-hangul.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 계수기의 종료코드를 찍는다. 출력은 $TMP/out 에 남긴다.
run() { node "$GUARD" "$@" > "$TMP/out" 2>&1 && echo 0 || echo $?; }

# ── 음성 — 영문만이면 0 ──
mkdir -p "$TMP/en" && printf '<p>Validates a token.</p>\n' > "$TMP/en/a.html"
assert_eq "0" "$(run "$TMP/en")" "[음성] 영문만인 산출물은 통과해야 한다"

# ── 양성 — 한글 줄을 잡고 자리를 찍는다 ──
mkdir -p "$TMP/ko" && printf '<p>Validates.</p>\n<p>토큰을 검증한다</p>\n' > "$TMP/ko/a.html"
assert_eq "1" "$(run "$TMP/ko")" "[양성] 한글 줄이 있으면 1 이어야 한다"
assert_contains "$(cat "$TMP/out")" "a.html:2:" "[양성] 파일과 줄 번호를 찍어야 한다"

# ── 공허 — 디렉터리가 없거나 파일이 모자라면 2 ──
assert_eq "2" "$(run "$TMP/none")" "[공허] 디렉터리가 없으면 2 여야 한다"
mkdir -p "$TMP/empty"
assert_eq "2" "$(run "$TMP/empty")" "[공허] 파일이 없으면 2 여야 한다"
assert_eq "2" "$(run "$TMP/en" --min-files=2)" "[공허] --min-files 보다 적으면 2 여야 한다"

# ── 필터 — 빼지 않으면 잡혀야 대조가 된다 ──
mkdir -p "$TMP/mix/src"
printf 'ok\n' > "$TMP/mix/a.html"
printf '한글\n' > "$TMP/mix/b.js"
printf '한글\n' > "$TMP/mix/src/c.html"
assert_eq "1" "$(run "$TMP/mix")" "[필터 대조] 필터 없이는 b.js · src/c.html 이 잡혀야 한다"
assert_eq "1" "$(run "$TMP/mix" --ext=.html)" "[필터] --skip 없이는 src/c.html 이 잡혀야 한다"
assert_eq "0" "$(run "$TMP/mix" --ext=.html --skip=src/)" "[필터] --ext=.html --skip=src/ 이면 a.html 만 읽는다"

# ── 바이너리 — NUL 이 있는 파일은 건너뛴다(폰트를 UTF-8 로 읽으면 한글 범위 글자가 나온다) ──
mkdir -p "$TMP/bin"
printf 'ok\n' > "$TMP/bin/a.html"
printf '\000\352\260\200\n' > "$TMP/bin/font.woff"
assert_eq "0" "$(run "$TMP/bin")" "[바이너리] NUL 이 있는 파일의 한글 범위 바이트는 세지 않는다"
assert_contains "$(cat "$TMP/out")" "건너뛴 바이너리 1" "[바이너리] 건너뛴 수를 찍어야 한다"
printf '\352\260\200\n' > "$TMP/bin/text.txt"
assert_eq "1" "$(run "$TMP/bin")" "[바이너리 대조] NUL 없는 같은 바이트는 텍스트로 잡혀야 한다"

# ── 오타 — 모르는 옵션은 필터를 조용히 끄는 대신 2 ──
assert_eq "2" "$(run "$TMP/en" --exts=.html)" "[오타] 모르는 옵션은 2 여야 한다"

assert_report
