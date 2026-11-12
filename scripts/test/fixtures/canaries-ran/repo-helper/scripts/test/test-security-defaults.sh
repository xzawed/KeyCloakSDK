#!/usr/bin/env sh
# 픽스처 — python 표가 정의 밖 헬퍼(`sd_py_rows`)를 부른다. 검사는 표 함수 정의만 떼어 실행하므로 그 헬퍼가 없다 —
# 행이 조용히 줄면 안 되고 판정 불가여야 한다(독립 레그 실측: 2 행 → 1 행 · rc 0 이던 자리).
sd_nonce_canary() {
  case "$1" in
    python) printf '%s\n' 'python/tests/unit/test_auth.py|def test_rejects_mismatched_nonce('
            sd_py_rows ;;
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
sd_py_rows() {
  printf '%s\n' 'python/tests/unit/test_auth.py|async def test_aio_rejects_mismatched_nonce('
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
