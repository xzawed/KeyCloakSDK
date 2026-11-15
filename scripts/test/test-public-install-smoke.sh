#!/usr/bin/env sh
# public-install-smoke.sh 의 **정적 계약** — 네트워크 · Docker 없이 PR 마다 도는 몫이다. 실제 설치 · 실행은
# .github/workflows/public-install.yml(예약 · 수동 · 그 두 파일을 고치는 PR)이 공개 레지스트리에 대고 한다.
#
# 본다:
#  1. 스크립트의 언어 분기와 워크플로 행렬이 DEPLOY_LANGS 와 **같은 집합**이다 — 열 번째 언어가 한쪽에만 들어가면
#     그 언어의 게시판은 아무도 공개 레지스트리에서 설치해 보지 않는다(손 목록이 조용히 좁아지는 부류).
#  2. 인자가 없거나 모르는 언어면 **설치 전에** 실패한다 — 아무것도 안 하고 초록이 되지 않는다.
#  3. 판정 함수가 빠진 · 남는 언어를 실제로 지목한다(음성 대조 — 살아 있는 트리만 단언하면 판정을 지워도 초록이다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
ROOT="$DIR/../.."
SMOKE="$ROOT/scripts/public-install-smoke.sh"
WF="$ROOT/.github/workflows/public-install.yml"

# 스크립트의 언어 분기 — `case "$lang" in` 블록 안의 `  <lang>)` 줄(keycloak-up 은 case 밖의 if 다).
pis_case_langs() { awk '/^case "\$lang" in$/{p=1;next} p&&/^esac$/{exit} p&&/^  [a-z]+\)$/{sub(/^  /,"");sub(/\)$/,"");print}' "$1"; }
# 워크플로 행렬 — `lang: [a, b, …]` 한 줄.
pis_matrix_langs() { sed -n 's/^ *lang: *\[\(.*\)\] *$/\1/p' "$1" | tr ',' '\n' | tr -d ' ' | grep . || true; }
# $1 = 기대 집합, $2 = 실제 집합(줄마다 하나) → 「missing:… extra:…」(같으면 빈 출력)
pis_gap() {
  _pt="$(mktemp -d)"
  printf '%s\n' "$1" | grep . | sort -u > "$_pt/want" || true
  printf '%s\n' "$2" | grep . | sort -u > "$_pt/got" || true
  _miss="$(comm -23 "$_pt/want" "$_pt/got" | tr '\n' ' ')"
  _extra="$(comm -13 "$_pt/want" "$_pt/got" | tr '\n' ' ')"
  rm -rf "$_pt"
  [ -z "$_miss$_extra" ] || printf 'missing:%s extra:%s' "$_miss" "$_extra"
}

WANT="$(printf '%s\n' $DEPLOY_LANGS)"
assert_eq "" "$(pis_gap "$WANT" "$(pis_case_langs "$SMOKE")")" "[공개 스모크] 스크립트의 언어 분기가 DEPLOY_LANGS 와 다르다"
assert_eq "" "$(pis_gap "$WANT" "$(pis_matrix_langs "$WF")")" "[공개 스모크] 워크플로 행렬이 DEPLOY_LANGS 와 다르다"

# 판정의 음성 대조 — 같은 함수에 합성 입력을 먹인다.
assert_contains "$(pis_gap "$WANT" "$(printf '%s\n' $DEPLOY_LANGS | grep -vx ruby)")" "missing:ruby" "[공개 스모크 판정] 빠진 언어를 지목한다"
assert_contains "$(pis_gap "$WANT" "$(printf '%s\nelixir\n' $DEPLOY_LANGS)")" "extra:elixir" "[공개 스모크 판정] 남는 언어를 지목한다"
_pis_tmp="$(mktemp -d)"
printf '%s\n' 'case "$lang" in' '  node)' '    :' '    ;;' '  *)' '    die' '    ;;' 'esac' > "$_pis_tmp/s.sh"
printf '%s\n' '        lang: [node, go]' > "$_pis_tmp/w.yml"
assert_eq "node" "$(pis_case_langs "$_pis_tmp/s.sh")" "[공개 스모크 판정] case 분기만 언어로 읽는다(*) 는 아니다)"
assert_eq "$(printf 'node\ngo')" "$(pis_matrix_langs "$_pis_tmp/w.yml")" "[공개 스모크 판정] 행렬 한 줄을 언어 목록으로 읽는다"
rm -rf "$_pis_tmp"

# 인자 없음 · 모르는 언어 — 설치 전에 실패한다.
_o="$(bash "$SMOKE" 2>&1)" && _c=0 || _c=$?
assert_eq "1" "$_c" "[공개 스모크] 인자가 없으면 실패한다"
assert_contains "$_o" "usage" "[공개 스모크] 인자가 없으면 쓰는 법을 말한다"
_o="$(bash "$SMOKE" elixir 2>&1)" && _c=0 || _c=$?
assert_eq "1" "$_c" "[공개 스모크] 모르는 언어면 실패한다"
assert_contains "$_o" "모르는 언어: elixir" "[공개 스모크] 모르는 언어를 이름으로 지목한다"

assert_report
