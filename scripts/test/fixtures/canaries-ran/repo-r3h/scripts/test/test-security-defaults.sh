#!/usr/bin/env sh
# 픽스처 — 문자열 키가 겹친 옵션(`{ fails: false, 'fails': true }`) — 코드에선 false 키 하나만 보이고 문자열에 또 있어 판정 불가여야
# 한다(키 수와 언급 수가 어긋난다 — 계산된 키 `['fails']` 도 같다).
sd_nonce_canary() {
  case "$1" in
    node) printf '%s\n' "node/test/unit/o.test.ts|it('o11 quoted fails key'" ;;
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
