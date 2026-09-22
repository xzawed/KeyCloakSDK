#!/usr/bin/env sh
# 극소형 sh 테스트 어서션(외부 프레임워크 없음). 각 테스트가 source한다.
#
# ⚠️⚠️ **모든 테스트 파일은 마지막에 `assert_report`를 호출해야 한다.**
# 개별 어서션은 `_A_FAIL`만 누적하고 **종료코드를 바꾸지 않는다** — 종료코드를 내는 것은
# `assert_report`의 마지막 줄(`[ "$_A_FAIL" -eq 0 ]`)뿐이다. 빠뜨리면 어서션이 전부 실패해도
# 스크립트가 **exit 0으로 끝나고 CI가 초록이 된다**(테스트가 있다는 사실이 오히려 안심시킨다).
# 이 규칙은 `scripts/test/test-selftest-hygiene.sh`가 기계로 강제한다 — 산문만 있던 시절엔
# 계획서 미체크 항목 안에만 적혀 있어 아무도 보지 않았다.
_A_PASS=0; _A_FAIL=0

# ⚠️ **서브셸에서 실행된 단언은 카운터에 남지 않는다.** `_A_PASS`/`_A_FAIL` 은 현재 셸의
# 변수라, 파이프 오른쪽·`$( )`·`( )` 그룹 안에서 실패한 단언은 `FAIL` 을 찍고도 부모가
# `0 failed` 로 끝난다(종료코드 **0**). 그 자리가 하나 생기는 순간 「테스트가 있다」는 사실이
# 거짓 증명이 된다 — 이 저장소가 가장 비싸게 치러 온 실패 모드다.
#
# 그래서 셸 변수와 **별도로 파일 눈금**을 둔다. 파일 쓰기는 서브셸에서도 부모에게 남으므로,
# `assert_report` 에서 「실행된 단언 수(파일)」와 「계수된 단언 수(변수)」가 어긋나면 그 차이가
# 곧 **증발한 단언 수**다. 정적 금지(문법으로 서브셸 단언을 찾아내기)보다 정확하다 — 여러 줄
# `| while read … done` 이나 중첩 그룹처럼 정규식이 놓치는 모양도 그대로 잡힌다.
#
# ⚠️ **계수 의미는 바꾸지 않았다.** 기존 두 변수와 종료코드 계약은 그대로이고 검증만 덧붙는다
# (등록부가 경고한 「계수기를 갈아엎으면 전부 빨개진다」에 해당하지 않는다 — 코퍼스 39 파일
#  전부 초록임을 확인했다).
# ⚠️ `$$` 는 POSIX 에서 **서브셸 안에서도 부모 셸의 PID** 다 — 실측으로 `( )`·`$( )`·`| while`
# 셋 다 같은 값이었다. 그래서 자식이 쓴 눈금을 부모가 같은 경로에서 읽는다.
_A_TALLY="${TMPDIR:-/tmp}/kcsdk-assert-tally-$$"
: > "$_A_TALLY" 2>/dev/null || _A_TALLY=''
_a_tick() { [ -n "$_A_TALLY" ] && printf . >> "$_A_TALLY" 2>/dev/null; return 0; }

assert_eq() { # expected actual msg
  _a_tick
  if [ "$1" = "$2" ]; then _A_PASS=$((_A_PASS+1)); else _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$1" "$2" >&2; fi
}
assert_contains() { # haystack needle msg
  _a_tick
  case "$1" in *"$2"*) _A_PASS=$((_A_PASS+1)) ;; *) _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  [%s] does not contain [%s]\n' "$3" "$1" "$2" >&2 ;; esac
}
assert_not_contains() { # haystack needle msg
  _a_tick
  case "$1" in *"$2"*) _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  [%s] unexpectedly contains [%s]\n' "$3" "$1" "$2" >&2 ;; *) _A_PASS=$((_A_PASS+1)) ;; esac
}
assert_ok() { # cmd... (expect exit 0)
  _a_tick
  if "$@" >/dev/null 2>&1; then _A_PASS=$((_A_PASS+1)); else _A_FAIL=$((_A_FAIL+1)); printf 'FAIL expected success: %s\n' "$*" >&2; fi
}
assert_fails() { # cmd... (expect non-zero)
  _a_tick
  if "$@" >/dev/null 2>&1; then _A_FAIL=$((_A_FAIL+1)); printf 'FAIL expected failure: %s\n' "$*" >&2; else _A_PASS=$((_A_PASS+1)); fi
}

# ⚠️ **메타 단언 — 단언을 「검출기가 우는가」를 재는 도구로 쓰는 자리.** 이 저장소의 음성/양성
# 대조군은 축 **자신**을 태우고 `_A_FAIL` 이 늘었는지를 본다(대조군 안에 검사를 다시 구현하면
# 같은 변이를 함께 놓친다 — #495 의 교훈). 그 프로브는 보고에 섞이면 안 되므로 계수기를
# 되감는데, **손으로 `_A_FAIL="$saved"` 하면 파일 눈금은 안 되감겨** 위 오라클이 거짓 양성을
# 낸다(실측 2026-09-23: security-defaults 21 · publication-claims 6). 둘을 함께 되감는다.
# ⚠️ 중첩은 지원하지 않는다(전역 한 쌍). 지금 코퍼스에 중첩 사용처는 없다.
_a_save() {
  _A_SAVE_P="$_A_PASS"; _A_SAVE_F="$_A_FAIL"; _A_SAVE_N=0
  if [ -n "$_A_TALLY" ] && [ -f "$_A_TALLY" ]; then _A_SAVE_N="$(wc -c < "$_A_TALLY" | tr -d ' ')"; fi
  return 0
}
_a_restore() {
  _A_PASS="$_A_SAVE_P"; _A_FAIL="$_A_SAVE_F"
  if [ -n "$_A_TALLY" ]; then
    # ⚠️ `printf '%*s'` 로 줄이지 않는다 — 폭 인자는 POSIX 에 있으나 CI 의 `sh` 는 dash 이고
    # 여기서 확인할 수 없다. 눈금은 수백 바이트라 루프로 만들어 **한 번에** 쓴다(의문 제거).
    _a_d=''; _a_i=0
    while [ "$_a_i" -lt "$_A_SAVE_N" ]; do _a_d="$_a_d."; _a_i=$((_a_i + 1)); done
    printf '%s' "$_a_d" > "$_A_TALLY"
  fi
  return 0
}

assert_report() {
  printf '\n%s passed, %s failed\n' "$_A_PASS" "$_A_FAIL"
  _a_n=0; _a_lost=0
  if [ -n "$_A_TALLY" ] && [ -f "$_A_TALLY" ]; then
    _a_n="$(wc -c < "$_A_TALLY" | tr -d ' ')"
    _a_lost=$(( _a_n - _A_PASS - _A_FAIL ))
    rm -f "$_A_TALLY"
  fi
  if [ "$_a_lost" -gt 0 ]; then
    printf '::error::단언 %s 건이 서브셸에서 증발했다 — 실행 %s · 계수 %s. 파이프 오른쪽·$( )·( ) 안에서 단언하지 말 것(카운터는 현재 셸 변수라 부모에 남지 않아 FAIL 을 찍고도 exit 0 이 된다). 입력을 here-string/리다이렉션으로 바꿔 부모 셸에서 돌려라.\n' \
      "$_a_lost" "$_a_n" "$((_A_PASS + _A_FAIL))" >&2
    return 1
  fi
  [ "$_A_FAIL" -eq 0 ]
}

# ⚠️ `assert_ok`는 **명령만** 받는다(메시지 인자를 주면 그것까지 명령으로 해석해 실패한다).
# 메시지를 남기려면 "ok" 여부를 문자열로 만들어 `assert_eq`에 넘긴다.
# ⚠️ **이 헬퍼는 두 자가테스트에 복제돼 있었다**(`test-security-defaults.sh`·`test-config-masking.sh`)
# — 세 번째 파일이 필요해지자 없는 채로 쓰다 `actual: []` 로 열 건이 거짓 실패했다. 여기가 원본이다.
ok_if() { if [ "$1" = 0 ]; then printf 'ok'; else printf '%s' "${2:-NOT-OK}"; fi; }
