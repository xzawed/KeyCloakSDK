#!/usr/bin/env sh
# 픽스처 — 해석이나 판정이 막아야 하는 소스 모양 둘.
#   python 카나리아 def 가 함수(`make_cases`) 안에 있다 — pytest 는 그것을 모으지 않는다 → 판정 불가
#   node   카나리아가 `it.fails(` 로 뒤집혔다 — 보고서의 통과가 곧 단언 실패다 → FAIL
sd_nonce_canary() {
  case "$1" in
    python) printf '%s\n' 'python/tests/unit/test_auth.py|def test_nested(' ;;
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
    node) printf '%s\n' 'canary|node/test/unit/tokens.test.ts|access_token 이 비문자열이면 throw' ;;
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
