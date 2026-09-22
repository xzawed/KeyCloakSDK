#!/usr/bin/env sh
# 루트 README 영↔한이 **같은 구조**인가.
#
# ⚠️ 왜 따로 필요한가: `CLAUDE.md` 가 「README는 루트만 영한 미러(동일 구조)」라고 적는데,
# 그것을 기계로 집행하던 것은 `test-readme-badges.sh` 의 **배지 집합 비교 하나뿐**이었다.
# 즉 언어 행 하나를 한쪽에서 지우거나, 표 행을 늘리거나, 문서 링크를 한쪽에만 고쳐도
# 저장소의 모든 가드가 초록이었다(감사 실측 2026-09-22 — 열린 high 로 등록됐던 항목).
#
# ⚠️ **번역되는 것은 비교하지 않는다.** 제목 문자열·표 내용·본문은 언어마다 다른 것이 정상이다.
# 비교하는 것은 번역이 바꾸지 않는 **구조**다 — 헤딩 레벨 시퀀스, 표 행 수, 코드펜스 수,
# 그리고 **문서 바깥을 가리키는 링크 타깃 집합**.
#
# ⚠️ 링크에서 두 부류는 **의도적으로 뺀다**: (a) 문서 내 앵커(`#...`)는 헤딩이 번역되므로
# 함께 번역된다, (b) 서로를 가리키는 상호 링크(`README.md` ↔ `README.ko.md`)는 반대 방향이
# 정상이다. 이 둘을 빼지 않으면 가드가 정상 상태에서 빨개져 곧 지워진다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${RM_ROOT:-$DIR/../..}"
EN="$ROOT/README.md"
KO="$ROOT/README.ko.md"

assert_eq "yes" "$([ -f "$EN" ] && [ -f "$KO" ] && echo yes || echo no)" \
  "[미러] 루트 README 둘이 모두 있어야 한다"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. 헤딩 레벨 시퀀스 ────────────────────────────────────────────────────
# `## → ### → ##` 같은 **차례**까지 본다. 개수만 세면 순서를 바꾼 편집이 통과한다.
rm_headings() { grep -oE '^#{1,6} ' "$1" | tr -d ' ' | tr '\n' '-'; }
_en_h="$(rm_headings "$EN")"
_ko_h="$(rm_headings "$KO")"
# 공허 하한 — 추출이 깨지면 둘 다 빈 문자열이 되어 조용히 통과한다. 실측 11(2026-09-22).
RM_MIN_HEADINGS=10
_hn="$(grep -cE "^#{1,6} " "$EN" || true)"
_enough=1; [ "$_hn" -ge "$RM_MIN_HEADINGS" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_hn")" \
  "[미러] README.md 에서 헤딩을 ${RM_MIN_HEADINGS}개 미만 찾았다($_hn) — 추출이 깨졌나?"
assert_eq "$_en_h" "$_ko_h" \
  "[미러] 헤딩 레벨 시퀀스가 다르다 — 한쪽에만 절을 넣거나 순서를 바꿨다"

# ── 2. 표 행 수 · 코드펜스 수 ──────────────────────────────────────────────
# 표의 **내용**은 번역되지만 행 수는 같아야 한다 — 언어 행 하나가 빠지는 것이 가장 흔한 어긋남이다.
assert_eq "$(grep -c '^|' "$EN" || true)" "$(grep -c '^|' "$KO" || true)" \
  "[미러] 표 행 수가 다르다 — 한쪽 표에서 행이 빠졌거나 늘었다"
assert_eq "$(grep -c '^```' "$EN" || true)" "$(grep -c '^```' "$KO" || true)" \
  "[미러] 코드펜스 수가 다르다 — 한쪽에만 예제를 넣거나 뺐다"

# ── 3. 바깥을 가리키는 링크 타깃 집합 ──────────────────────────────────────
# 문서 내 앵커와 상호 링크는 뺀다(위 주석 참조). 나머지 타깃은 번역 대상이 아니므로 같아야 한다.
rm_targets() { # $1=파일 $2=상대편 파일명
  grep -oE '\]\([^)]+\)' "$1" \
    | sed 's/^](//; s/)$//' \
    | grep -v '^#' \
    | grep -vx "$2" \
    | sort -u
}
rm_targets "$EN" 'README.ko.md' > "$TMP/en"
rm_targets "$KO" 'README.md'    > "$TMP/ko"
# 공허 하한 — 링크가 한 건도 안 잡히면 diff 가 항상 빈다. 실측 30+ (2026-09-22).
RM_MIN_LINKS=20
_ln="$(grep -c . "$TMP/en" || true)"
_enough2=1; [ "$_ln" -ge "$RM_MIN_LINKS" ] && _enough2=0
assert_eq "ok" "$(ok_if "$_enough2" "$_ln")" \
  "[미러] README.md 에서 링크를 ${RM_MIN_LINKS}개 미만 찾았다($_ln) — 추출이 깨졌나?"
assert_eq "" "$(diff "$TMP/en" "$TMP/ko" || true)" \
  "[미러] 링크 타깃 집합이 다르다 (< 는 영문에만, > 는 한글에만) — 한쪽만 경로를 고쳤다"

assert_report
