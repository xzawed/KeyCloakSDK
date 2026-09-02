#!/usr/bin/env sh
# Node 공개 타입 표면 가드(`check-node-public-surface.mjs`)의 자가테스트.
#
# 왜 생겼나: 이것이 **자가테스트가 없는 유일한 `scripts/*.mjs`** 였다. 게다가 그 가드는
# `node/dist` 라는 **빌드 산출물**을 보므로, 실제 트리로는 "통과"가 「검사했고 깨끗하다」인지
# 「볼 것을 못 찾았다」인지 구분되지 않는다 — 가드 자신이 파일 0개를 에러로 만드는 것도
# 그래서인데, 그 안전장치 자체를 아무도 검사하지 않았다.
#
# ⚠️ **픽스처를 `<case>/node/dist/` 로 두지 않는다.** `.gitignore:44` 의 `dist/` 가 그 경로를
# 통째로 삼켜서 파일이 커밋되지 않는다 — 로컬은 초록, CI 는 파일이 없어 빨강이 되는 부류다
# (실측: `git check-ignore -v` 가 여섯 케이스 전부를 지목했다). 픽스처는 평평하게 두고,
# 케이스마다 TMP 에 `node/dist` 를 만들어 복사한 뒤 그 루트를 가드에 넘긴다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/node-surface"
GUARD="$DIR/../check-node-public-surface.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# <case> → $TMP/<case>/node/dist/*.d.ts 를 만들고 그 루트를 echo 한다.
stage() {
  _root="$TMP/$1"
  mkdir -p "$_root/node/dist"
  cp "$FIX/$1/"*.d.ts "$_root/node/dist/"
  printf '%s' "$_root"
}

# ⚠️ 스윕 공허성 — 픽스처가 사라지거나 이름이 바뀌면 아래 어서션이 전부 "파일 0개"로 떨어져
# **가드의 dist-부재 검사에 걸려 통과처럼 보이는 실패**가 된다. 개수를 먼저 못박는다.
assert_eq "6" "$(ls "$FIX" | grep -c . )" "픽스처 케이스가 여섯이어야 한다"
assert_eq "6" "$(find "$FIX" -name '*.d.ts' | grep -c . )" "케이스마다 .d.ts 가 하나씩 있어야 한다"

# ── 오탐 대조군 셋 — 통과해야 하는 것 ──
assert_ok node "$GUARD" "$(stage clean)"
assert_ok node "$GUARD" "$(stage allow-representation)"   # §4(b)(a) representation 타입
assert_ok node "$GUARD" "$(stage allow-raw)"              # §4(b)(b) raw() 탈출구

# ── 변이 — 잡아야 하는 것 ──
# ⚠️ 종료코드만 보면 "다른 이유로 실패"해도 통과하므로 문구까지 고정한다.
_r="$(stage leak-jose)"
assert_fails node "$GUARD" "$_r"
out="$(node "$GUARD" "$_r" 2>&1 || true)"
assert_contains "$out" "공개 선언이 하위 라이브러리 타입을 노출한다" "jose 누출을 그 이유로 지목한다"
assert_contains "$out" "jose" "누출된 줄을 함께 인쇄한다"

assert_fails node "$GUARD" "$(stage leak-openid)"

# ── 예외의 **범위** — 같은 파일이라는 이유로 넓어지지 않는다 ──
# `raw()` 예외가 파일 단위였을 때 이 픽스처는 통과했다(같은 파일에 raw() 가 있다는 이유로
# `underlying` 게터의 KcAdminClient 노출까지 함께 통과). §4(b) 는 예외를 탈출구 **하나**로 못박는다.
_r="$(stage leak-raw-scope)"
assert_fails node "$GUARD" "$_r"
out="$(node "$GUARD" "$_r" 2>&1 || true)"
assert_contains "$out" "raw() 밖의 공개 선언에 쓰였다" "raw() 예외의 범위를 벗어난 사용을 지목한다"

# ── 공허성: dist 가 없으면 **실패**해야 한다 ──
# 이 가드의 통과는 "검사했다"를 뜻해야 한다. 빌드 전에 돌려 0개로 초록이 되는 것이 이 부류의
# 전형적인 공허함이고, 그 안전장치가 실제로 사는지는 여기서만 확인된다.
mkdir -p "$TMP/nodist"
assert_fails node "$GUARD" "$TMP/nodist"
out="$(node "$GUARD" "$TMP/nodist" 2>&1 || true)"
assert_contains "$out" "파일 0개로 통과시키면 검사가 공허해진다" "dist 부재를 공허함으로 지목한다"

# ── 계수 대조군 — 픽스처를 실제로 훑었는가 ──
# 파일을 못 찾고도 "누출 0건"으로 끝나는 판을 막는다(위 공허성 검사의 반대 방향).
out="$(node "$GUARD" "$TMP/clean" 2>&1)"
assert_contains "$out" "1개 .d.ts 검사, 누출 0건" "clean 픽스처에서 파일 수와 누출 수를 함께 인쇄한다"

assert_report
