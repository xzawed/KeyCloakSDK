#!/usr/bin/env sh
# `nightly-alert.yml` 의 감시 목록이 **예약 실행을 가진 워크플로**와 **main 에 대한 push 로 도는
# 워크플로** 전부를 덮는지, 그리고 잡이 그 두 이벤트를 실제로 받는지 본다.
#
# ⚠️ 왜 가드가 필요한가: `workflow_run.workflows:` 는 파일명이 아니라 **`name:` 값**으로 맞춘다.
# 어느 워크플로가 `name:` 을 바꾸거나, 새 워크플로에 `schedule:` 이나 main push 를 달면 이 목록에서
# **조용히** 빠진다 — 그리고 빠진 것은 「알림이 안 온다」로만 드러나는데, 그건 애초에 고치려던
# 실패다(등록부 `nightly-failure-reaches-nobody` · `push-lane-failures-still-silent`). 산문으로는 못 막는다.
#
# ⚠️ 이 테스트는 **음성 대조**를 함께 든다. 살아 있는 상태만 단언하면 비교 로직을 지워도 초록이
# 된다(등록부 `selftests-with-no-negative-case` 가 그 부류다) — 아래에서 목록 줄을 일부러 빼고,
# push 판별기에 손으로 만든 워크플로를 먹이고, 잡 조건을 일부러 깨서 검출기가 **실제로 운다**는
# 것을 확인한다.
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

# main 에 대한 push 로 도는가(종료 0). `on:` 블록의 `push` 가 받는 브랜치를 본다 — 흐름형
# `push: {branches: [main], …}` · 블록형 `branches: [main]` · 목록 `- main` 모두. 브랜치도 태그도 없는
# push 와 한 줄짜리 `on: push` · `on: [push, …]` 는 모든 브랜치(main 포함)다. 태그만 받는 push(릴리스)는
# 아니다. ⚠️ 주석은 먼저 벗긴다 — 주석 속 `branches: [main]` 은 트리거가 아니다. ⚠️ 브랜치 값만 본다 —
# `paths: ['src/main/**']` 의 main 은 브랜치가 아니다.
_pushes_main() { # $1 = 워크플로 파일
  awk '
    function brhas(s) { return s ~ /(^|[^A-Za-z0-9_.\/*-])main([^A-Za-z0-9_.\/*-]|$)/ }
    function done_push() {
      if (!inpush) return
      if (brs) { if (brmain) hit = 1 } else if (!tags) hit = 1
      inpush = 0
    }
    /^[[:space:]]*#/ { next }
    { sub(/[[:space:]]+#.*$/, "") }
    /^on:[[:space:]]*push[[:space:]]*$/ { hit = 1 }
    /^on:[[:space:]]*\[/ && /[[ ,]push[] ,]/ { hit = 1 }
    /^on:[[:space:]]*$/ { on = 1; next }
    on && /^[^[:space:]]/ { done_push(); on = 0 }
    on && /^  [A-Za-z_]+:/ {
      done_push()
      if ($0 !~ /^  push:/) next
      inpush = 1; brs = 0; brmain = 0; tags = 0; inbr = 0
    }
    on && inpush {
      s = $0
      if (inbr) {
        if (s ~ /^[[:space:]]*-/) { if (brhas(s)) brmain = 1; next }
        inbr = 0
      }
      if (s ~ /branches:/) {
        brs = 1; b = s; sub(/.*branches:/, "", b)
        if (b ~ /^[[:space:]]*$/) inbr = 1
        else { sub(/\].*/, "", b); if (brhas(b)) brmain = 1 }
      }
      if (s ~ /tags:/) tags = 1
    }
    END { done_push(); exit hit ? 0 : 1 }
  ' "$1"
}

# 파생 2 — main 에 대한 push 로 도는 워크플로의 `name:` 집합.
_push_main_names() { # $1 = 워크플로 디렉터리
  for f in "$1"/*.yml; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = 'nightly-alert.yml' ] && continue
    _pushes_main "$f" || continue
    sed -n 's/^name:[[:space:]]*//p' "$f" | head -1
  done | sed 's/[[:space:]]*$//' | sort
}

# 감시 목록 — `nightly-alert.yml` 의 `workflows:` 목록.
_alert_names() { # $1 = nightly-alert.yml 경로
  awk '
    /^[[:space:]]*workflows:[[:space:]]*$/ { inlist = 1; next }
    inlist && /^[[:space:]]*types:/        { inlist = 0 }
    inlist && /^[[:space:]]*-[[:space:]]/  { sub(/^[[:space:]]*-[[:space:]]*/, ""); print }
  ' "$1" | sed 's/[[:space:]]*$//' | sort
}

# 잡 조건 — `alert` 잡의 `if:` 블록(주석 줄 제외)이 예약 실행과 main push 를 둘 다 받는가(종료 0).
_job_takes_both() { # $1 = nightly-alert.yml 경로
  cond="$(awk '
    /^[[:space:]]*#/ { next }
    /^    if:/ { inif = 1 }
    inif && /^    runs-on:/ { inif = 0 }
    inif { print }
  ' "$1")"
  printf '%s\n' "$cond" | grep -qF "github.event.workflow_run.event == 'schedule'" &&
    printf '%s\n' "$cond" | grep -qF "github.event.workflow_run.event == 'push'" &&
    printf '%s\n' "$cond" | grep -qF "github.event.workflow_run.head_branch == 'main'"
}

assert_eq "yes" "$([ -f "$ALERT" ] && echo yes || echo no)" "[야간알림] nightly-alert.yml 이 없다"

# ⚠️ `diff <(...)` 는 bash 전용이다 — 이 파일은 `sh` 라 임시 파일로 비교한다.
NA_TMP="$(mktemp -d)"
trap 'rm -rf "$NA_TMP"' EXIT

SCHED="$(_sched_names "$WFDIR")"
PUSHED="$(_push_main_names "$WFDIR")"
EXPECTED="$(printf '%s\n%s\n' "$SCHED" "$PUSHED" | grep . | sort -u)"
WATCHED="$(_alert_names "$ALERT")"

# 공허 하한 — 추출이 깨지면 「대상이 없어서」 두 집합이 모두 비고 조용히 초록이 된다.
# ⚠️ 세어서 박는다: schedule 실측 11(2026-09-21) · main push 실측 13(2026-11-14). 늘리면 함께 올린다.
NA_MIN=11
_n="$(printf '%s\n' "$SCHED" | grep -c . || true)"
_enough=1; [ "$_n" -ge "$NA_MIN" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_n")" \
  "[야간알림] schedule 워크플로를 ${NA_MIN}개 미만 찾았다($_n) — 추출이 깨졌나?"
NA_PUSH_MIN=13
_p="$(printf '%s\n' "$PUSHED" | grep -c . || true)"
_enough=1; [ "$_p" -ge "$NA_PUSH_MIN" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_p")" \
  "[야간알림] main push 워크플로를 ${NA_PUSH_MIN}개 미만 찾았다($_p) — 추출이 깨졌나?"

# 본 검사 — 감시 목록이 두 집합의 합집합과 정확히 같아야 한다.
printf '%s\n' "$EXPECTED" > "$NA_TMP/expected"
printf '%s\n' "$WATCHED"  > "$NA_TMP/watched"
assert_eq "" "$(diff "$NA_TMP/expected" "$NA_TMP/watched" || true)" \
  "[야간알림] 감시 목록이 예약 ∪ main push 워크플로 집합과 다르다 (< 가 빠진 것, > 가 남는 것)"

# 잡이 두 이벤트를 받는다 — 목록에 있어도 `if:` 가 schedule 만 받으면 main push 는 여전히 무성이다.
_both=1; _job_takes_both "$ALERT" && _both=0
assert_eq "ok" "$(ok_if "$_both" "if")" \
  "[야간알림] alert 잡의 if: 가 예약 실행과 main push(head_branch == 'main')를 둘 다 받지 않는다"

# ── 음성 대조 1: 감시 목록에서 한 줄을 빼면 검출기가 울어야 한다 ─────────────────────
# 예약 집합의 것 하나와, 예약이 없는 main push 레인 하나(그것이 합집합에 실제로 들어갔다는 증거)를 뺀다.
_push_only="$(printf '%s\n' "$PUSHED" | while IFS= read -r n; do
  printf '%s\n' "$SCHED" | grep -qxF -- "$n" || { printf '%s\n' "$n"; break; }
done)"
assert_eq "yes" "$([ -n "$_push_only" ] && echo yes || echo no)" \
  "[야간알림·음성대조] 예약이 없는 main push 레인을 찾지 못했다 — 합집합 검사가 공허할 수 있다"
for _victim in "$(printf '%s\n' "$SCHED" | head -1)" "$_push_only"; do
  grep -v -- "^      - $_victim\$" "$ALERT" > "$NA_TMP/nightly-alert.yml"
  printf '%s\n' "$(_alert_names "$NA_TMP/nightly-alert.yml")" > "$NA_TMP/b"
  _neg=0; diff -q "$NA_TMP/expected" "$NA_TMP/b" >/dev/null 2>&1 || _neg=1
  assert_eq "1" "$_neg" \
    "[야간알림·음성대조] '$_victim' 을 목록에서 빼도 검출기가 침묵했다 — 비교가 공허하다"
done

# ── 음성 대조 2: 잡 조건에서 main push 를 빼면 검출기가 울어야 한다 ───────────────────
grep -vF "head_branch == 'main'" "$ALERT" > "$NA_TMP/nightly-alert.yml"
_neg=1; _job_takes_both "$NA_TMP/nightly-alert.yml" || _neg=0
assert_eq "0" "$_neg" "[야간알림·음성대조] if: 에서 main push 를 빼도 검출기가 침묵했다"

# ── 판별기 대조: 손으로 만든 워크플로 — main push 인 것과 아닌 것 ─────────────────────
_fixture() { # $1 = 이름, 나머지 = 파일 줄
  _f="$NA_TMP/fx-$1.yml"; shift
  printf '%s\n' "$@" > "$_f"
  printf '%s' "$_f"
}
_expect_push() { # $1 = 기대(yes|no), $2 = 이름, $3 = 파일
  _got=no; _pushes_main "$3" && _got=yes
  assert_eq "$1" "$_got" "[야간알림·판별기] $2 — main push 판정이 $_got(기대 $1)"
}
_expect_push yes '블록형 branches: [main]' \
  "$(_fixture a 'name: a' 'on:' '  push:' '    branches: [main]' '  pull_request:')"
_expect_push yes '흐름형 push: {branches: [main], paths}' \
  "$(_fixture b 'name: b' 'on:' "  push: {branches: [main], paths: ['src/**']}")"
_expect_push yes '목록형 branches: - main' \
  "$(_fixture c 'name: c' 'on:' '  push:' '    branches:' '      - main' "    paths: ['x/**']")"
_expect_push yes '브랜치 · 태그 없는 push(paths 만)' \
  "$(_fixture d 'name: d' 'on:' '  push:' "    paths: ['x/**']")"
_expect_push yes '한 줄 on: [push, pull_request]' \
  "$(_fixture e 'name: e' 'on: [push, pull_request]')"
_expect_push no '태그만 받는 push(릴리스)' \
  "$(_fixture f 'name: f' 'on:' '  push:' "    tags: ['v*']")"
_expect_push no 'branches 는 release 뿐 — paths 의 main 은 브랜치가 아니다' \
  "$(_fixture g 'name: g' 'on:' '  push:' '    branches: [release]' "    paths: ['src/main/**']")"
_expect_push no '주석 속 branches: [main] 은 트리거가 아니다' \
  "$(_fixture h 'name: h' 'on:' '  push:' '    # branches: [main]' "    tags: ['v*']")"
_expect_push no 'push 없음(schedule · pull_request)' \
  "$(_fixture i 'name: i' 'on:' '  pull_request:' '    branches: [main]' '  schedule:' "    - cron: '0 0 * * *'")"

assert_report
