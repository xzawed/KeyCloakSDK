#!/usr/bin/env sh
# 픽스처 — 독립 레그 2 의 반례 중 이름을 정할 수 없어 판정 불가여야 하는 모양(언어마다 하나).
#   node   식별자 제목의 describe(`describe(AuthClient, …)`)
#   go     한 줄짜리 Test 뒤의 패키지 수준 표 — 그 표를 쓰는 Test 를 정할 수 없다
#   rust   `#[path = "…"] mod tests;` 로 들인 파일 — 모듈 경로가 파일 경로와 다르다
#   kotlin `@ParameterizedTest` — Gradle 이 표시 이름(`[1] "a"`)을 쓴다
sd_nonce_canary() {
  case "$1" in
    node)   printf '%s\n' "node/test/unit/b.test.ts|it('r2 ident describe'" ;;
    go)     printf '%s\n' 'go/p_test.go|{"r2 package table"}' ;;
    rust)   printf '%s\n' 'rust/src/pathy_tests.rs|fn r2_pathy(' ;;
    kotlin) printf '%s\n' 'kotlin/src/test/kotlin/io/x/P.kt|fun `r2 parameterized`(' ;;
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
_a="$(sd_canary_ok "$ROOT/$f1" "$c1")"
_b="$(sd_canary_ok "$ROOT/$f2" "$c2")"
_c="$(sd_canary_ok "$ROOT/$f3" "$c3")"
_d="$(sd_canary_ok "$ROOT/$f4" "$c4")"
_e="$(sd_canary_ok "$ROOT/$f5" "$c5")"
