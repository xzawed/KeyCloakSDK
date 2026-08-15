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
assert_eq() { # expected actual msg
  if [ "$1" = "$2" ]; then _A_PASS=$((_A_PASS+1)); else _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$1" "$2" >&2; fi
}
assert_contains() { # haystack needle msg
  case "$1" in *"$2"*) _A_PASS=$((_A_PASS+1)) ;; *) _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  [%s] does not contain [%s]\n' "$3" "$1" "$2" >&2 ;; esac
}
assert_not_contains() { # haystack needle msg
  case "$1" in *"$2"*) _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  [%s] unexpectedly contains [%s]\n' "$3" "$1" "$2" >&2 ;; *) _A_PASS=$((_A_PASS+1)) ;; esac
}
assert_ok() { # cmd... (expect exit 0)
  if "$@" >/dev/null 2>&1; then _A_PASS=$((_A_PASS+1)); else _A_FAIL=$((_A_FAIL+1)); printf 'FAIL expected success: %s\n' "$*" >&2; fi
}
assert_fails() { # cmd... (expect non-zero)
  if "$@" >/dev/null 2>&1; then _A_FAIL=$((_A_FAIL+1)); printf 'FAIL expected failure: %s\n' "$*" >&2; else _A_PASS=$((_A_PASS+1)); fi
}
assert_report() { printf '\n%s passed, %s failed\n' "$_A_PASS" "$_A_FAIL"; [ "$_A_FAIL" -eq 0 ]; }
