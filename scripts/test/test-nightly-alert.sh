#!/usr/bin/env sh
# `nightly-alert.yml` 의 감시 목록이 **예약 실행을 가진 워크플로 전부**를 덮는지 본다.
#
# ⚠️ 왜 가드가 필요한가: `workflow_run.workflows:` 는 파일명이 아니라 **`name:` 값**으로 맞춘다.
# 어느 워크플로가 `name:` 을 바꾸거나, 새 워크플로에 `schedule:` 을 달면 이 목록에서 **조용히**
# 빠진다 — 그리고 빠진 것은 「알림이 안 온다」로만 드러나는데, 그건 애초에 고치려던 실패다
# (등록부 `nightly-failure-reaches-nobody`). 산문으로는 못 막는다.
#
# ⚠️ 이 테스트는 **음성 대조**를 함께 든다. 살아 있는 상태만 단언하면 비교 로직을 지워도 초록이
# 된다(등록부 `selftests-with-no-negative-case` 가 그 부류다) — 아래에서 목록 한 줄을 일부러
# 빼고 검출기가 **실제로 운다**는 것을 확인한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${NA_ROOT:-$DIR/../..}"
WFDIR="$ROOT/.github/workflows"
ALERT="$WFDIR/nightly-alert.yml"

# 파생 1 — `schedule:` 을 가진 워크플로의 `name:` 집합(자기 자신은 제외: workflow_run 은 자기를 못 본다).
_sched_names() { # $1 = 워크플로 디렉터리
  for f in "$1"/*.yml; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = 'nightly-alert.yml' ] && continue
    grep -qE '^[[:space:]]*schedule:' "$f" || continue
    sed -n 's/^name:[[:space:]]*//p' "$f" | head -1
  done | sed 's/[[:space:]]*$//' | sort
}

# 파생 2 — `nightly-alert.yml` 의 `workflows:` 목록.
_alert_names() { # $1 = nightly-alert.yml 경로
  awk '
    /^[[:space:]]*workflows:[[:space:]]*$/ { inlist = 1; next }
    inlist && /^[[:space:]]*types:/        { inlist = 0 }
    inlist && /^[[:space:]]*-[[:space:]]/  { sub(/^[[:space:]]*-[[:space:]]*/, ""); print }
  ' "$1" | sed 's/[[:space:]]*$//' | sort
}

assert_eq "yes" "$([ -f "$ALERT" ] && echo yes || echo no)" "[야간알림] nightly-alert.yml 이 없다"

# ⚠️ `diff <(...)` 는 bash 전용이다 — 이 파일은 `sh` 라 임시 파일로 비교한다.
NA_TMP="$(mktemp -d)"
trap 'rm -rf "$NA_TMP"' EXIT

SCHED="$(_sched_names "$WFDIR")"
WATCHED="$(_alert_names "$ALERT")"

# 공허 하한 — 추출이 깨지면 「대상이 없어서」 두 집합이 모두 비고 조용히 초록이 된다.
# ⚠️ 세어서 박는다: 실측 11(2026-09-21). 예약 워크플로를 늘리면 이 수도 함께 올린다.
NA_MIN=11
_n="$(printf '%s\n' "$SCHED" | grep -c . || true)"
_enough=1; [ "$_n" -ge "$NA_MIN" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_n")" \
  "[야간알림] schedule 워크플로를 ${NA_MIN}개 미만 찾았다($_n) — 추출이 깨졌나?"

# 본 검사 — 두 집합이 정확히 같아야 한다.
printf '%s\n' "$SCHED"   > "$NA_TMP/sched"
printf '%s\n' "$WATCHED" > "$NA_TMP/watched"
assert_eq "" "$(diff "$NA_TMP/sched" "$NA_TMP/watched" || true)" \
  "[야간알림] 감시 목록이 예약 워크플로 집합과 다르다 (< 가 빠진 것, > 가 남는 것)"

# ── 음성 대조: 한 줄을 빼면 검출기가 울어야 한다 ──────────────────────────────
_victim="$(printf '%s\n' "$WATCHED" | head -1)"
grep -v -- "^      - $_victim\$" "$ALERT" > "$NA_TMP/nightly-alert.yml"
BROKEN="$(_alert_names "$NA_TMP/nightly-alert.yml")"
printf '%s\n' "$SCHED"   > "$NA_TMP/s"
printf '%s\n' "$BROKEN"  > "$NA_TMP/b"
_neg=0; diff -q "$NA_TMP/s" "$NA_TMP/b" >/dev/null 2>&1 || _neg=1
assert_eq "1" "$_neg" \
  "[야간알림·음성대조] '$_victim' 을 목록에서 빼도 검출기가 침묵했다 — 비교가 공허하다"

assert_report
