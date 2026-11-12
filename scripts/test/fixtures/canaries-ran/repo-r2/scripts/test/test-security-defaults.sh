#!/usr/bin/env sh
# 픽스처 — 독립 레그 2 의 반례(건강한 실행과 FAIL 칸). 판정 불가 칸은 repo-r2b 에 있다.
#   node  닫힌 형제 describe 뒤의 it.each 제목(건강) · 행 스물둘 위의 it.fails.each · 제목에 `it (` 가 든 it.fails(…)
#   go    주석에만 t.Run( 이 든 테스트(건강) · tt.Run 으로 연 서브테스트를 전부 뺀 필터
#   ruby  `it "x",` 다음 줄의 `:aggregate_failures do` — RSpec 의 line_number 는 그 do 줄이다(건강)
sd_nonce_canary() {
  case "$1" in
    node) printf '%s\n' \
            'node/test/unit/a.test.ts|r2 healthy each' \
            'node/test/unit/a.test.ts|r2 fails each' \
            'node/test/unit/a.test.ts|r2 fails it (call)' ;;
    go)   printf '%s\n' \
            'go/r2_test.go|func TestCommentOnly(' \
            'go/r2_test.go|func TestReceiverSubtests(' ;;
    ruby) printf '%s\n' 'ruby/spec/unit/r2_spec.rb|it "aggregates"' ;;
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
