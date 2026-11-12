#!/usr/bin/env sh
# 픽스처 — 선언 꼴 카나리아가 **문자열 안**에만 있다(#1017 레그: go GF · node NDUM, ruby 는 같은 꼴). 그 문자열을 담은
# 다른 테스트가 카나리아 대신 돌아 통과로 읽히므로 판정 불가여야 한다(진짜 선언은 공백 · `.skip` · `xit` 로 비켰다).
sd_nonce_canary() {
  case "$1" in
    go)   printf '%s\n' 'go/x_test.go|func TestRealEmpty(' ;;
    node) printf '%s\n' "node/test/unit/n.test.ts|it('n1 real'" ;;
    ruby) printf '%s\n' 'ruby/spec/unit/r_spec.rb|it "r1 real"' ;;
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
