#!/usr/bin/env sh
# 픽스처 — 언어마다 해석이 깨지는 모양 하나씩(전부 판정 불가여야 한다).
#   java   카나리아가 주석 밖 두 줄에 있다
#   kotlin 카나리아가 선언 이름이 아니라 같은 줄의 문자열 안에 있다
#   go     카나리아 줄을 감싼 최상위 함수가 Test 함수가 아니다
#   python 카나리아 파일이 없다
#   node   카나리아 파일이 언어 디렉터리 밖이다
#   ruby   카나리아가 하나도 없다(공허)
sd_nonce_canary() {
  case "$1" in
    java)   printf '%s\n' 'java/T.java|void twice(' ;;
    kotlin) printf '%s\n' 'kotlin/T.kt|rejects mismatched nonce' ;;
    python) printf '%s\n' 'python/tests/test_gone.py|def test_gone(' ;;
    node)   printf '%s\n' 'java/T.java|void twice(' ;;
  esac
}
sd_backoff_canary() {
  case "$1" in
    none) ;;
  esac
}
sd_mask_test() {
  case "$1" in
    go) printf '%s' 'go/m_test.go' ;;
  esac
}
sd_mask_canary() {
  case "$1" in
    go) printf '%s' 'assertMasked(t, "TokenSet"' ;;
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
