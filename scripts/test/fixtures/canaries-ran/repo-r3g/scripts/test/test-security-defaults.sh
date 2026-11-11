#!/usr/bin/env sh
# 픽스처 — 선언 꼴 node 카나리아가 여러 줄 템플릿 리터럴 안의 줄에만 있다(그 줄엔 템플릿 따옴표가 없다). 진짜 시험은
# 백틱 제목이라 카나리아 글자와 안 맞고 `{ fails: true }` 다 — 줄 단위로 읽으면 가짜 줄의 제목 · 옵션을 읽어 통과였다
# (#1018 레그 실측). 파일 단위로 문자열을 비워 읽으면 템플릿 안이라 판정 불가다.
sd_nonce_canary() {
  case "$1" in
    node) printf '%s\n' "node/test/unit/g.test.ts|it('g1 template canary'" ;;
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
