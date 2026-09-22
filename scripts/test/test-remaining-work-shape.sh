#!/usr/bin/env sh
# 잔여작업 등록부가 **다시 이력 저장소가 되지 않게** 한다.
#
# ⚠️ 왜: 이 파일은 예산 없이 256,624 B 까지 자랐고 그중 **닫힌 70 건의 하위 서사가 65,347 B**
# 였다. 2026-09-22 에 그 서사를 `archive/docs-history-2026-09` 태그로 이관했다. 다시 붙는 것을
# 막는 장치가 없으면 같은 자리로 돌아간다(옵트인 예산이 한 번도 이 파일을 안 덮은 것이 원인이다).
#
# ⚠️ **단언할 수 있는 규칙은 하나뿐이다 — 「닫힌 항목이 소유한 줄 수 == 닫힌 항목 수」.**
# 정상적인 닫기는 표제 한 줄만 소유하므로 항목이 하나 닫힐 때 **양변이 함께 1 씩** 움직인다.
# 하위 서사가 돌아오면 **좌변만** 움직여 빨개진다. 기대 상수를 영원히 고칠 일이 없다 —
# `닫힘 == 70` 도 `닫힘 <= N` 도 바이트 상한도 전부 변경 때마다 다시 맞추는 수라 공허하다.
# (독립 레그 판정. `닫힘 == 0` 은 이 저장소의 계수 앵커 프레임워크가 추출값 0 을 「추출 실패」로
#  읽어 쓸 수 없고, 애초에 표제를 남기는 이 설계에서는 성립하지도 않는다.)
#
# ⚠️ `> 0` 절이 **이중 추출 실패**(`0 == 0`)를 막는다 — 정규식이 깨지면 양변이 함께 0 이 되어
# 조용히 통과한다. 그 부류가 이 저장소에서 이미 여러 번 나왔다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${RW_ROOT:-$DIR/../..}"
F="$ROOT/docs/superpowers/plans/remaining-work.md"

assert_eq "yes" "$([ -f "$F" ] && echo yes || echo no)" "[등록부] 파일이 없다: $F"

# 항목이 "소유"하는 줄 = 표제줄 + 뒤따르는 **들여쓴** 줄(다음 항목/헤딩/비들여쓰기 전까지).
# 끝의 빈 줄은 항목 사이 간격이므로 소유에서 뺀다.
_shape="$(awk '
  function flush(){ if (cur=="x") { owned += (n - trail) } ; cur=""; n=0; trail=0 }
  /^- \[[ x]\] / { flush(); cur = (substr($0,4,1)=="x") ? "x" : "o"; if (cur=="x") closed++; n=1; trail=0; next }
  /^#{1,6} / { flush(); next }
  {
    if (cur != "") {
      if ($0 ~ /^[[:space:]]*$/) { n++; trail++; next }
      if ($0 ~ /^[[:space:]]/)   { n++; trail=0; next }
      flush(); next
    }
  }
  END { flush(); printf "%d %d", owned, closed }
' "$F")"
_owned="${_shape%% *}"
_closed="${_shape##* }"

# 공허 방지 — 추출이 깨지면 둘 다 0 이 되어 `0 == 0` 으로 통과한다.
_pos=1; [ "$_closed" -gt 0 ] && _pos=0
assert_eq "ok" "$(ok_if "$_pos" "$_closed")" \
  "[등록부] 닫힌 항목을 하나도 못 찾았다($_closed) — 추출이 깨졌나? (0 == 0 으로 통과시키지 않는다)"

assert_eq "$_closed" "$_owned" \
  "[등록부] 닫힌 항목이 소유한 줄 수($_owned)가 닫힌 항목 수($_closed)와 다르다 — 닫은 항목에 하위 서사가 다시 붙었다. 사후 서사는 아카이브 태그로 보낼 것(문서 상단 안내 참조)"

# 아카이브 안내가 살아 있는가 — 이관한 곳을 가리키는 줄이 지워지면 다음 세션이 서사를 못 찾는다.
_ptr="$(grep -c 'archive/docs-history-2026-09' "$F" || true)"
assert_eq "ok" "$(ok_if "$([ "$_ptr" -ge 1 ] && printf 0 || printf 1)" MISSING)" \
  "[등록부] 이관 대상 태그(archive/docs-history-2026-09)를 가리키는 줄이 사라졌다"

assert_report
