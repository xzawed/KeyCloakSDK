#!/bin/sh
# 언어 집합 파생의 **오탐률**을 이력으로 잰다.
#
# 왜 필요한가: `test-security-defaults.sh` 의 「언어 집합 축」은 required 체크 `doc-facts` 안에서
# 돌고 룰셋은 `bypass_actors: []` 다 — 오탐 하나가 모든 PR 을 막고 소유자도 못 푼다. 그래서
# 등록부(`guard-detection-surface-hand-narrowed`)가 **「required 밖에서 먼저 돌려 오탐 0 을
# 실측할 것」**을 되살릴 조건으로 걸었다. 이 스크립트가 그 측정이다.
#
# 무엇을 재는가: 각 커밋에서 (1) 그 커밋의 `SD_LANGS` 손 목록과 (2) 그 커밋의 트리에서 파생한
# 언어 집합을 대조한다. `main` 은 늘 초록이었으므로 **여기서 나오는 불일치는 전부 오탐**이다.
#
# ⚠️ 「불일치 0」을 「이 파생이 옳다」로 읽지 말 것 — 그건 **거짓양성이 없다**만 말한다.
# 거짓음성(이 파생이 못 잡는 언어)은 여기서 안 잡히고, 축 주석이 따로 적는다.
#
# 사용: sh scripts/measure-lang-universe-fp.sh [커밋수]   (생략하면 main 전수)
set -eu

# ⚠️ 루트·브랜치는 덮어쓸 수 있어야 한다 — 자가테스트의 음성 대조군이 **불일치를 심은** 픽스처
# 저장소를 가리켜 「이 측정이 불일치를 실제로 본다」를 잰다. 고정이면 그 대조군을 쓸 수 없다.
ROOT="${MLU_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
BRANCH="${MLU_BRANCH:-main}"
cd "$ROOT"
GUARD="${MLU_GUARD:-scripts/test/test-security-defaults.sh}"
LIMIT="${1:-}"

# ⚠️ 이 정규식은 축과 **같아야 한다** — 갈리면 이 측정이 다른 것을 재게 된다. 축에서 읽어온다.
MANIFEST="$(sed -n "s/^SD_MANIFEST='\(.*\)'\$/\1/p" "$GUARD" | head -1)"
[ -n "$MANIFEST" ] || { echo "::error::$GUARD 에서 SD_MANIFEST 를 못 읽었다 — 추출 실패도 실패다" >&2; exit 1; }

tree_langs() { # $1=commit
  git ls-tree -d --name-only "$1" | while read -r d; do
    if git ls-tree --name-only "$1" "$d/" | grep -qE "^$d/($MANIFEST)\$"; then printf '%s\n' "$d"; fi
  done | sort | tr '\n' ' '
}

if [ -n "$LIMIT" ]; then
  COMMITS=$(git rev-list --first-parent -n "$LIMIT" "$BRANCH")
else
  COMMITS=$(git rev-list --first-parent "$BRANCH")
fi

total=0; checked=0; mismatch=0
for c in $COMMITS; do
  total=$((total + 1))
  sd=$(git show "$c:$GUARD" 2>/dev/null | grep -oE "^SD_LANGS=['\"][^'\"]*['\"]" \
        | sed "s/.*=['\"]//;s/['\"]//" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ') || true
  [ -z "$sd" ] && continue   # 그 커밋에 아직 이 목록이 없다 — 측정 대상이 아니다
  checked=$((checked + 1))
  tl=$(tree_langs "$c")
  if [ "$sd" != "$tl" ]; then
    mismatch=$((mismatch + 1))
    printf '  MISMATCH %s\n    SD_LANGS: %s\n    derived : %s\n' \
      "$(git log -1 --format='%h %ad' --date=short "$c")" "$sd" "$tl"
  fi
done

# 공허 방어 — 대조한 커밋이 0 건이면 "불일치 0" 이 통과처럼 보인다.
if [ "$checked" -eq 0 ]; then
  echo "::error::SD_LANGS 를 담은 커밋을 하나도 못 찾았다 — 이 측정이 공허하다" >&2
  exit 1
fi

printf '\n커밋 전수 %s · SD_LANGS 존재 %s · 불일치(=오탐) %s\n' "$total" "$checked" "$mismatch"
[ "$mismatch" -eq 0 ] || exit 1
