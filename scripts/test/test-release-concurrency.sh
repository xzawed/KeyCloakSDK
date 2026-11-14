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

# 판정기 — <워크플로 디렉터리> → _tagged(`tags:` 트리거를 가진 워크플로 = 이 검사의 대상) · _missing(최상위
# `concurrency:` 가 없다) · _cancels(cancel-in-progress 가 false 가 아니다)를 설정한다(앞 공백 없이 공백 구분).
# 살아 있는 검사와 끝의 음성 대조가 같은 함수를 부른다.
# 최상위 `concurrency:` 블록 — 그 다음 줄부터 다음 최상위 키 전까지(CR 은 벗긴다). cancel-in-progress 는 여기서만
# 읽는다 — 파일 전체에서 찾으면 잡 수준 concurrency 의 false 가 최상위의 true 를 가린다(실측 2026-11-14).
rc_top_block() { # <워크플로>
  awk '{ sub(/\r$/, "") } /^concurrency:/ { inb = 1; next } inb && /^[^[:space:]#]/ { exit } inb' "$1"
}
rc_scan() {
  _tagged=''; _missing=''; _cancels=''
  for f in "$1"/*.yml; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]+tags:' "$f" || continue
    b="$(basename "$f")"
    _tagged="$_tagged $b"
    if grep -qE '^concurrency:' "$f"; then
      rc_top_block "$f" | grep -qE '^[[:space:]]+cancel-in-progress:[[:space:]]*false[[:space:]]*(#.*)?$' || _cancels="$_cancels $b"
    else
      _missing="$_missing $b"
    fi
  done
  _tagged="${_tagged# }"; _missing="${_missing# }"; _cancels="${_cancels# }"
}

rc_scan "$WFDIR"
_n="$(printf '%s\n' $_tagged | grep -c . || true)"

# 공허 방지 — 트리거 표기가 바뀌어 0 개를 고르면 아래 단언은 언제나 통과한다. 실측 9(2026-09-22).
assert_eq "ok" "$(ok_if "$([ "$_n" -ge 1 ] && printf 0 || printf 1)" "$_n")" \
  "[릴리스동시성] \`tags:\` 트리거를 가진 워크플로를 ${_n}개 찾았다 — 트리거 표기가 바뀌었나? (0 개를 훑고 통과시키지 않는다)"

assert_eq "" "$_missing" \
  "[릴리스동시성] 태그 트리거인데 최상위 concurrency 가 없다 — 같은 접두 태그 둘이 동시에 게시된다"

assert_eq "" "$_cancels" \
  "[릴리스동시성] cancel-in-progress 가 false 가 아니다 — 게시 도중 취소는 되돌릴 수 없다"

# 음성 대조 — 판정기가 두 위반을 실제로 짚는가(실측 2026-11-14 SILENT: 둘 다 「빈 목록」만 단언했다).
#   a.yml 태그 트리거 · 최상위 concurrency 없음(잡 수준만 있다)                    → _missing
#   b.yml 최상위 cancel-in-progress: true — 주석과 잡 수준 concurrency 가 false 를 말한다 → _cancels
#   c.yml 정상 · d.yml 태그 트리거가 아니다(대상 밖)
_rc_fx="$(mktemp -d)"
printf '%s\n' 'on:' '  push:' '    tags: ["a-v*"]' 'jobs:' '  publish:' '    concurrency:' '      group: a' \
  '      cancel-in-progress: false' '    runs-on: ubuntu-latest' > "$_rc_fx/a.yml"
printf '%s\n' 'on:' '  push:' '    tags: ["b-v*"]' '# `cancel-in-progress: false` 는 의도다 — 게시 도중 취소는 되돌릴 수 없다' \
  'concurrency:' '  group: b' '  cancel-in-progress: true' 'jobs:' '  publish:' '    concurrency:' '      group: b-job' \
  '      cancel-in-progress: false' '    runs-on: ubuntu-latest' > "$_rc_fx/b.yml"
printf '%s\n' 'on:' '  push:' '    tags: ["c-v*"]' 'concurrency:' '  group: c' '  cancel-in-progress: false' 'jobs: {}' > "$_rc_fx/c.yml"
printf '%s\n' 'on:' '  push:' '    branches: [main]' 'jobs: {}' > "$_rc_fx/d.yml"
rc_scan "$_rc_fx"
rm -rf "$_rc_fx"
assert_eq "a.yml b.yml c.yml" "$_tagged" "[음성대조] 태그 트리거 워크플로만 골라야 한다"
assert_eq "a.yml" "$_missing" "[음성대조] 최상위 concurrency 가 없는 태그 워크플로를 짚어야 한다(잡 수준은 대신하지 못한다)"
assert_eq "b.yml" "$_cancels" \
  "[음성대조] 최상위 cancel-in-progress: true 를 짚어야 한다 — 주석 · 잡 수준의 false 가 그것을 가리면 안 된다"

assert_report
