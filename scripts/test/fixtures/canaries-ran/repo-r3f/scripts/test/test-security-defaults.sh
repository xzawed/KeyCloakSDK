#!/usr/bin/env sh
# 픽스처 — 선언 꼴 go 카나리아가 여러 줄 raw 문자열 안의 들여쓴 줄에만 있다. 그 줄엔 따옴표가 없어 문자열 규칙이
# 못 보고, 줄 머리 규칙(gofmt — 최상위 func 은 0 열)만 막는다. 없으면 감싼 TestHolder 로 읽힌다.
sd_nonce_canary() {
  case "$1" in
    go) printf '%s\n' 'go/y_test.go|func TestRealDecl(' ;;
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
