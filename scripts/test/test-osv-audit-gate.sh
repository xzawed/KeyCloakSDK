#!/usr/bin/env sh
# OSV 감사의 **fail-closed 지점**이 dep-tree 를 읽는 모든 자리에 있는가.
#
# 왜 이 가드가 필요한가: `gradlew dependencies` 는 의존을 **하나도 해석하지 못해도 exit 0** 이고,
# 그 트리에 `<좌표> FAILED` 를 찍는다. 그것을 좌표 파이프라인이 버전 `"X FAILED"` 인 가짜 좌표로
# 통과시키면 OSV 는 「그런 좌표에 취약점 없음」을 답하고, **아무것도 감사하지 않은 잡이 초록으로
# 끝난다**(실측 2026-08-28: 가짜 9좌표 → 취약 0건 · 대조군 netty-codec-http 4.1.119.Final → 18건).
# 목록이 비었는지만 보는 검사로는 안 잡힌다 — 목록은 비지 않고 **틀린 채로** 찬다.
#
# ⚠️ **이 부류는 이미 한 번 절반만 고쳐졌다.** 게이트는 `security-audit.yml` 의 `harness-kotlin`
# 잡에만 들어갔고 Kotlin **SDK** 잡 둘은 그대로였다(실측 2026-09-07: 생산자 3 · 게이트 1). 사본이
# 셋인데 하나만 고치는 것이 이 저장소가 반복해서 겪은 죽는 방식이라, 사람이 눈으로 세는 대신
# 여기서 **트리를 훑어** 대조한다 — 새 잡이 생겨도 자동으로 범위에 들어온다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
cd "$ROOT"

# 생산자 — `dep-tree.txt` 를 만드는 자리. 이것이 있는 파일은 반드시 게이트도 그 수만큼 있어야 한다.
# ⚠️ 잡 이름을 손으로 적지 않는다. 열 번째 언어·새 하네스 앱이 붙어도 이 셈이 따라간다.
osv_producers() { grep -c '> dep-tree\.txt' "$1" 2>/dev/null || true; }
# fail-closed 게이트 — 맨 `FAILED` 가 아니라 ` FAILED$`. 그것이 Gradle 렌더러의 접미사이고
# (`+--- <group>:<artifact>:<version> FAILED`), Maven 좌표에는 공백이 못 들어가므로 정상 좌표가
# 이 패턴을 만들 수 없다(실측: 실패 트리 9/9 동일 · 정상 트리 352줄에서 둘 다 0).
osv_gates() { grep -cF "if grep -qE ' FAILED\$' dep-tree.txt; then" "$1" 2>/dev/null || true; }

_total_p=0
_files=0
for WF in $(git ls-files '.github/workflows/*.yml'); do
  _p="$(osv_producers "$WF")"; _p=${_p:-0}
  [ "$_p" -gt 0 ] || continue
  _files=$((_files + 1))
  _total_p=$((_total_p + _p))
  _g="$(osv_gates "$WF")"; _g=${_g:-0}
  assert_eq "$_p" "$_g" \
    "[osv] $(basename "$WF") 의 dep-tree 생산자 $_p 개 중 fail-closed 게이트가 $_g 개다 — 게이트 없는 자리는 해석 실패 좌표를 가짜 버전으로 OSV 에 물어 '취약점 없음'으로 초록이 된다"
done

# ⚠️ **공허 하한.** 위 루프는 생산자가 하나도 없으면 어서션을 0건 실행하고 조용히 통과한다.
# 파일이 옮겨지거나 명령 표기가 바뀌면 그 순간 이 가드가 아무것도 안 보게 되므로, 코퍼스에서
# 실제로 센 수를 하한으로 박는다(2026-09-07 실측: kotlin-ci.yml 1 · security-audit.yml 2 = 3).
assert_eq "ok" "$([ "$_total_p" -ge 3 ] && printf ok || printf "TOO-FEW($_total_p)")" \
  "[osv] dep-tree 생산자가 3개 미만이다 — 추출 표기가 바뀌었거나 잡이 사라졌다. 이 가드가 공허해졌는지 먼저 확인하라"
assert_eq "ok" "$([ "$_files" -ge 2 ] && printf ok || printf "TOO-FEW($_files)")" \
  "[osv] 생산자를 가진 워크플로가 2개 미만이다 — 사본이 갈리는 것을 막는 것이 이 가드의 요점이라 파일이 하나면 볼 것이 없다"

# 게이트가 **판정을 가르지 않는다**는 것도 본다 — 메시지는 갈려도 `exit 1` 은 어느 갈래에서도
# 돌아야 한다. 갈래마다 exit 를 두면 한쪽을 지워도 문법은 성립해 조용히 fail-open 이 된다.
for WF in $(git ls-files '.github/workflows/*.yml'); do
  _g="$(osv_gates "$WF")"; _g=${_g:-0}
  [ "$_g" -gt 0 ] || continue
  # 게이트 블록마다 그 뒤에 `exit 1` 이 하나씩 있어야 한다(블록 밖 exit 는 세지 않는다).
  _e="$(awk "/if grep -qE ' FAILED\\\$' dep-tree.txt; then/{d=1} d&&/^[[:space:]]*exit 1\$/{n++; d=0} END{print n+0}" "$WF")"
  assert_eq "$_g" "$_e" \
    "[osv] $(basename "$WF") 의 fail-closed 게이트 $_g 개 중 $_e 개만 exit 1 로 끝난다 — 메시지만 가르고 판정은 가르지 않아야 한다"
done

assert_report
