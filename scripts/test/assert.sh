#!/usr/bin/env sh
# 극소형 sh 테스트 어서션(외부 프레임워크 없음). 각 테스트가 source한다.
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
