#!/usr/bin/env sh
# 픽스처 — `check-canaries-ran.mjs` 자가테스트가 이 파일의 표 함수만 떼어 실행한다(파일 자체는 돌지 않는다).
# 실제 가드(`scripts/test/test-security-defaults.sh`)와 같은 함수 이름 · 같은 행 모양이다.
sd_nonce_canary() {
  case "$1" in
    java)   printf '%s\n' 'java/core/src/test/java/io/x/TokenTest.java|void rejectsMismatchedNonce(' ;;
    kotlin) printf '%s\n' 'kotlin/src/test/kotlin/io/x/AuthTest.kt|fun `rejects mismatched nonce`(' ;;
    python) printf '%s\n' \
              'python/tests/unit/test_auth.py|def test_rejects_mismatched_nonce(' \
              'python/tests/unit/test_auth.py|async def test_aio_rejects_mismatched_nonce(' ;;
    node)   printf '%s\n' "node/test/unit/auth.test.ts|it('nonce 가 틀리면 거부한다" ;;
    go)     printf '%s\n' 'go/auth_test.go|func TestNonceValidation(' ;;
    dotnet) printf '%s\n' 'dotnet/tests/X.Tests/AuthTests.cs|public async Task Nonce_mismatch_throws(' ;;
    php)    printf '%s\n' 'php/tests/Unit/TokenTest.php|public function testRejectsMismatchedNonce(' ;;
    rust)   printf '%s\n' 'rust/src/auth.rs|async fn rejects_mismatched_nonce(' ;;
    ruby)   printf '%s\n' 'ruby/spec/unit/tokens_spec.rb|it "rejects a mismatched nonce"' ;;
  esac
}
sd_backoff_canary() {
  case "$1" in
    rust) printf '%s\n' 'rust/src/jwks.rs|async fn backoff_bounds_cold_retries(' ;;
  esac
}
sd_mask_test() {
  case "$1" in
    go)   printf '%s' 'go/masking_test.go' ;;
    java) printf '%s' 'java/core/src/test/java/io/x/TokenTest.java' ;;
  esac
}
sd_mask_canary() {
  case "$1" in
    go)   printf '%s\n' 'assertMasked(t, "TokenSet "+verb' '{"TokenSet", ts,' ;;
    java) printf '%s' 'toString_masksTokens' ;;
  esac
}
sd_mask2_test() {
  case "$1" in
    kotlin) printf '%s' 'kotlin/src/test/kotlin/io/x/AuthTest.kt' ;;
  esac
}
sd_mask2_canary() {
  case "$1" in
    kotlin) printf '%s' 'AuthorizationRequest toString masks codeVerifier' ;;
  esac
}
sd_token_type_anchor() {
  case "$1" in
    python) printf '%s\n' 'canary|python/tests/unit/test_tokens.py|def test_non_string_access_token_is_rejected(' ;;
    node)   printf '%s\n' 'canary|node/test/unit/tokens.test.ts|access_token 이 비문자열이면 throw' ;;
    dotnet) printf '%s\n' 'canary|dotnet/tests/X.Tests/AuthTests.cs|public async Task Rejects_non_string_access_token(' ;;
    php)    printf '%s\n' 'canary|php/tests/Unit/TokenTest.php|public function testNonStringAccessTokenIsRejected(' ;;
    ruby)   printf '%s\n' 'canary|ruby/spec/unit/tokens_spec.rb|it "rejects a non-string access_token (#{bad.inspect})"' \
              'hook|ruby/lib/tokens.rb|raise ArgumentError' ;;
  esac
}
sd_empty_canary() {
  case "$1" in
    none) ;;
  esac
}
# 호출 자리 — 검사기는 `sd_canary_ok "$ROOT/…` 를 세기만 한다(축 여섯 = 자리 여섯).
_a="$(sd_canary_ok "$ROOT/$f1" "$c1")"
_b="$(sd_canary_ok "$ROOT/$f2" "$c2")"
_c="$(sd_canary_ok "$ROOT/$f3" "$c3")"
_d="$(sd_canary_ok "$ROOT/$f4" "$c4")"
_e="$(sd_canary_ok "$ROOT/$f5" "$c5")"
_f="$(sd_canary_ok "$ROOT/$f6" "$c6")"
# 주석 속 자리는 세지 않는다: sd_canary_ok "$ROOT/$x" "$y"
