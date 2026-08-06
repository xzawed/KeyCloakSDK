#!/usr/bin/env sh
# 각 `<lang>/README.md`의 프리릴리스 배너가 실제 게시 현황(DF_PUBLISHED)과 맞는가.
#
# 왜 이 가드가 필요한가: 이 README들은 **레지스트리 랜딩 페이지**가 된다. 패키지 안에 담겨
# 올라가고, 레지스트리는 README를 **버전마다 고정**한다 — 게시 후에 고치려면 새 버전을 태워야
# 한다(DEPLOY.md §4 step 1의 경고). 그래서 "게시했는데 배너가 아직 미게시라고 말하는" 실수는
# 되돌리는 데 좌표 하나가 든다. 9개 언어를 손으로 맞춰 왔고 지금은 전부 맞지만, 남은 5개를
# 게시하는 동안 다섯 번 더 틀릴 기회가 있다.
#
# ⚠️ 이 어서션은 **양방향이라야 의미가 있다**. "미게시면 '아직'이라고 적혀 있어야 한다"만
# 검사하면 게시 후 배너를 안 고쳐도 통과하고, 그 반대만 검사하면 새 언어가 추가될 때 빈
# 배너를 통과시킨다. `DF_PUBLISHED` 한 줄을 옮기는 순간 **양쪽이 동시에** 요구된다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
ROOT="$DIR/../.."

for L in $DEPLOY_LANGS; do
  f="$ROOT/$L/README.md"
  assert_ok test -f "$f"

  # 배너는 첫머리에 있어야 한다 — 소비자가 레지스트리 페이지에서 처음 보는 줄이다.
  banner="$(sed -n '1,12p' "$f" | grep -m1 '^> \*\*Pre-release\*\*' || true)"
  assert_ok test -n "$banner"
  [ -n "$banner" ] || continue

  if df_is_published "$L"; then
    # 게시됨: "아직"이라고 말하면 안 되고, **어디에 있는지**를 말해야 한다. 부정형만 지우고
    # 아무것도 안 적는 절반짜리 수정을 막으려고 긍정 어서션을 함께 둔다.
    assert_not_contains "$banner" "not yet" \
      "$L 은 게시됐는데 README 배너가 아직 미게시라고 말한다 — 이 README는 레지스트리 랜딩 페이지다"
    assert_contains "$banner" "is on " \
      "$L 배너가 어느 레지스트리에 올라가 있는지 말하지 않는다"
  else
    assert_contains "$banner" "not yet" \
      "$L 은 미게시인데 README 배너가 그렇게 말하지 않는다"
    assert_not_contains "$banner" "is on " \
      "$L 은 미게시인데 배너가 레지스트리에 올라가 있다고 말한다"
  fi
done

# ⚠️ 대조군 — 위 루프가 실제로 언어를 돌았는지 확인한다. `DEPLOY_LANGS`가 비거나 파일 경로
# 규칙이 바뀌면 어서션이 0건 실행되고 이 테스트는 조용히 통과한다(그게 이 저장소가 반복해서
# 겪은 실패다). 개수를 SSOT에서 파생해 맞춘다.
n=0
for L in $DEPLOY_LANGS; do n=$((n + 1)); done
assert_ok test "$n" -ge 9

assert_report
