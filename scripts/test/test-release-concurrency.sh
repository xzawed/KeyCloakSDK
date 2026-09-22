#!/usr/bin/env sh
# **태그로 트리거되는 워크플로는 겹쳐 돌지 않아야 한다.**
#
# ⚠️ 왜: 실측 2026-09-22 — 릴리스 워크플로 10 개 중 **9 개에 `concurrency:` 가 없었다**
# (있는 것은 `dispatch-release.yml` 하나뿐). 태그 둘을 연달아 밀면 publish 잡이 동시에 돌고,
# php 는 subtree split 결과를 미러의 `refs/heads/main` 에 `git push --force` 로 덮으므로
# **늦게 끝난 쪽이 이긴다** — 먼저 올라간 버전의 미러가 통째로 사라진다.
#
# ⚠️ **목록을 손으로 적지 않는다.** 「아홉 개인가」는 언어가 늘면 다시 맞춰야 하는 수다.
# 여기서 묻는 것은 규칙이다 — **`tags:` 로 트리거되는 워크플로는 전부** 최상위
# `concurrency:` 를 가진다. 열 번째 언어가 생기면 그 파일이 자동으로 범위에 든다.
#
# ⚠️ `cancel-in-progress` 는 **false 여야 한다.** 게시 도중 취소하는 것은 큐에서 기다리는
# 것보다 나쁘다 — 반쯤 올라간 아티팩트는 되돌릴 수 없고, 레지스트리는 같은 버전의 재게시를
# 거부한다. 그룹 키를 어떻게 잡을지는 워크플로마다 다르므로(php 는 전역, 나머지는 ref 포함)
# 여기서 강제하지 않는다 — 강제하는 것은 **있는가**와 **취소하지 않는가** 둘뿐이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${RC_ROOT:-$DIR/../..}"
WFDIR="$ROOT/.github/workflows"

assert_eq "yes" "$([ -d "$WFDIR" ] && echo yes || echo no)" "[릴리스동시성] 워크플로 디렉터리가 없다: $WFDIR"

# `tags:` 트리거를 가진 워크플로 = 이 검사의 대상.
_tagged=''
for f in "$WFDIR"/*.yml; do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]+tags:' "$f" || continue
  _tagged="$_tagged $(basename "$f")"
done
_n="$(printf '%s\n' $_tagged | grep -c . || true)"

# 공허 방지 — 트리거 표기가 바뀌어 0 개를 고르면 아래 단언은 언제나 통과한다. 실측 9(2026-09-22).
assert_eq "ok" "$(ok_if "$([ "$_n" -ge 1 ] && printf 0 || printf 1)" "$_n")" \
  "[릴리스동시성] \`tags:\` 트리거를 가진 워크플로를 ${_n}개 찾았다 — 트리거 표기가 바뀌었나? (0 개를 훑고 통과시키지 않는다)"

_missing=''
_cancels=''
for b in $_tagged; do
  f="$WFDIR/$b"
  if grep -qE '^concurrency:' "$f"; then
    grep -qE '^[[:space:]]+cancel-in-progress:[[:space:]]*false' "$f" || _cancels="$_cancels $b"
  else
    _missing="$_missing $b"
  fi
done

assert_eq "" "$(printf '%s' "$_missing" | sed 's/^ //')" \
  "[릴리스동시성] 태그 트리거인데 최상위 concurrency 가 없다 — 같은 접두 태그 둘이 동시에 게시된다"

assert_eq "" "$(printf '%s' "$_cancels" | sed 's/^ //')" \
  "[릴리스동시성] cancel-in-progress 가 false 가 아니다 — 게시 도중 취소는 되돌릴 수 없다"

assert_report
