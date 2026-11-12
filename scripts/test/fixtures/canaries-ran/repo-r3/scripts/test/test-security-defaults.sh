#!/usr/bin/env sh
# 픽스처 — vitest 옵션 인자(`it(제목, { fails: true }, fn)`)로 뒤집힌 node 카나리아. JUnit 은 「expected fail」을 그냥
# 통과로 적는다(vitest 5.1 실측). 건강 열둘(timeout 옵션 · fails: false · 함수 참조 · 참조+타임아웃 · 한 인자 화살표 ·
# async · function · 인자 사이 주석 · 이름 붙은 타임아웃 · 주석 속 「fails」 · 주석 단 describe · 감싼 함수(여러 줄 템플릿
# 속 괄호)) — 건강 칸마다 둘째 인자를 읽는 분기가 하나씩이고, 뒤 다섯은 #1018 레그가 낸 오탐이다. 뒤집힘 일곱(한 줄 ·
# 여러 줄 · describe · 주석 속 `}` · 주석으로 시작하는 줄의 describe · `.skipIf(…).fails(` 사슬 · 정규식 속 `}`).
# 판정 불가 칸(변수 옵션 · 펼침 · 식 · 템플릿 속 가짜 선언)은 repo-r3b · r3c · r3d · r3g 에 하나씩 있다(첫 판정 불가가
# 실행을 멈춘다).
sd_nonce_canary() {
  case "$1" in
    node) printf '%s\n' \
            "node/test/unit/o.test.ts|it('o1 timeout options'" \
            "node/test/unit/o.test.ts|it('o2 fails false'" \
            "node/test/unit/o.test.ts|it('o3 function reference'" \
            "node/test/unit/o.test.ts|it('o3b function reference and timeout'" \
            "node/test/unit/o.test.ts|it('o3c single-parameter arrow'" \
            "node/test/unit/o.test.ts|it('o3d async arrow'" \
            "node/test/unit/o.test.ts|it('o3e function keyword'" \
            "node/test/unit/o.test.ts|it('o3f comment before the function'" \
            "node/test/unit/o.test.ts|it('o3g named timeout constant'" \
            "node/test/unit/o.test.ts|it('o3h comment mentions fails'" \
            "node/test/unit/o.test.ts|it('o3i inside a commented describe'" \
            "node/test/unit/o.test.ts|it('o3j wrapped function'" \
            "node/test/unit/o.test.ts|it('o4 fails true'" \
            "node/test/unit/o.test.ts|it('o5 fails multi-line'" \
            "node/test/unit/o.test.ts|it('o6 inside a fails describe'" \
            "node/test/unit/o.test.ts|it('o7 comment with a brace'" \
            "node/test/unit/o.test.ts|it('o8 inside a commented fails describe'" \
            "node/test/unit/o.test.ts|o9 chained fails" \
            "node/test/unit/o.test.ts|it('o10 regex with a brace'" \
            "node/test/unit/o.test.ts|it('o12 regex after return'" \
            "node/test/unit/o.test.ts|it('o13 template expression in options'" ;;
  esac
}
sd_backoff_canary() {
  case "$1" in
    none) ;;
  esac
}
sd_mask_test() {
  case "$1" in
    none) ;;
  esac
}
sd_mask_canary() {
  case "$1" in
    none) ;;
  esac
}
sd_mask2_test() {
  case "$1" in
    none) ;;
  esac
}
sd_mask2_canary() {
  case "$1" in
    none) ;;
  esac
}
sd_token_type_anchor() {
  case "$1" in
    none) ;;
  esac
}
sd_backoff_exempt() {
  case "$1" in
    none) ;;
  esac
}
sd_empty_canary() {
  case "$1" in
    none) ;;
  esac
}
_a="$(sd_canary_ok "$ROOT/$f1" "$c1")"
_b="$(sd_canary_ok "$ROOT/$f2" "$c2")"
_c="$(sd_canary_ok "$ROOT/$f3" "$c3")"
_d="$(sd_canary_ok "$ROOT/$f4" "$c4")"
_e="$(sd_canary_ok "$ROOT/$f5" "$c5")"
_f="$(sd_canary_ok "$ROOT/$f6" "$c6")"
_g="$(sd_canary_ok "$ROOT/$f7" "$c7")"
