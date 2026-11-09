#!/usr/bin/env sh
# `check-canaries-ran.mjs` 자가테스트 — 보안 기본값 가드의 행위 카나리아가 레인의 시험 보고서에서 「돌아 통과했다」로
# 읽히는가.
#
# ⚠️ **픽스처만 쓴다 — 실제 가드도 실제 시험 보고서도 읽지 않는다.** 이 파일은 required 체크 `doc-facts` 안에서 돈다.
# 판정이 검사기 코드와 `scripts/test/fixtures/canaries-ran/` 에만 달려 있어서, 언어 CI 의 실행·산출물·네트워크 어느
# 것도 이 체크를 빨갛게 하지 못한다(빨개지는 것은 검사기·픽스처를 고친 PR 뿐이다). 실제 대조는 아홉 레인의 단위 테스트
# 단계 바로 뒤의 비-required 단계가 한다. 임시 파일도 만들지 않는다 — 읽기만 한다.
#
# 무게는 「통과한다」가 아니라 아래 셋이다.
#   (a) FAIL 사유마다 1 — 그리고 **그 사유를 말한다**(건너뜀 · 보고서에 없음 · 실패 · 보고서 없음). 종료코드만 보면
#       판별자 하나를 지워도 다른 사유가 1 을 내서 통과한다.
#   (b) 해석·판독이 깨진 입력은 2 — 「카나리아가 안 돌았다」(1)와 「검사가 못 읽었다」(2)를 가른다.
#   (c) 양성 대조군 — 아홉 언어의 통과 보고서는 0 이다. 그리고 픽스처마다 **미끼**가 있다(같은 접두의 다른 테스트 ·
#       다른 모듈의 같은 이름 · 다른 바이너리 · 다른 파일의 같은 제목 · CDATA 속 `<skipped/>` 글자) — 매칭이 느슨하면
#       미끼가 양성을 빨갛게 한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-canaries-ran.mjs"
FIX="$DIR/fixtures/canaries-ran"
REPO="$FIX/repo"
REP="$FIX/reports"

# run <args…> → OUT · CODE (출력은 stdout·stderr 합본 — ::error:: 줄이 stderr 로 간다)
run() {
  set +e
  OUT="$(node "$GUARD" "$@" 2>&1)"
  CODE=$?
  set -e
}
expect() { # expect <이름> <종료코드> <출력에 있어야 할 것>
  assert_eq "$2" "$CODE" "[$1] 종료코드 — 출력: $OUT"
  assert_contains "$OUT" "$3" "[$1] 출력에 「$3」"
}

# ═══ (c) 양성 — 아홉 언어의 통과 보고서 ═══════════════════════════════════════════════════════════
run --lang java --report "$REP/java/pass" --root "$REPO"
expect ok-java 0 "통과 2 · FAIL 0"
assert_contains "$OUT" "io.x.TokenTest#rejectsMismatchedNonce — 1 통과" "[ok-java] CDATA 속 <skipped/> 를 건너뜀으로 읽었다 — 출력: $OUT"
run --lang kotlin --report "$REP/kotlin-pass.xml" --root "$REPO"
expect ok-kotlin 0 "통과 2 · FAIL 0"
run --lang python --report "$REP/python-pass.xml" --root "$REPO"
expect ok-python 0 "통과 3 · FAIL 0"
assert_contains "$OUT" "test_non_string_access_token_is_rejected — 3 통과" "[ok-python] 매개변수 셋을 다 세야 한다(다른 모듈의 같은 이름은 빼고) — 출력: $OUT"
assert_contains "$OUT" "TestAio::test_aio_rejects_mismatched_nonce — 1 통과" "[ok-python] 클래스 안 테스트 — 출력: $OUT"
run --lang node --report "$REP/node-pass.xml" --root "$REPO"
expect ok-node 0 "통과 2 · FAIL 0"
assert_contains "$OUT" "throw: %s — 2 통과" "[ok-node] it.each 의 %s 자리 — 출력: $OUT"
run --lang go --report "$REP/go-pass.txt" --root "$REPO"
expect ok-go 0 "통과 3 · FAIL 0"
assert_contains "$OUT" "go/masking_test.go:19 → TestSlogMasks — 1 통과" "[ok-go] 표 행 카나리아는 감싼 Test 함수로 — 출력: $OUT"
run --lang dotnet --report "$REP/dotnet/pass" --root "$REPO"
expect ok-dotnet 0 "통과 2 · FAIL 0"
run --lang php --report "$REP/php-pass.xml" --root "$REPO"
expect ok-php 0 "통과 2 · FAIL 0"
assert_contains "$OUT" "testNonStringAccessTokenIsRejected — 2 통과" "[ok-php] 데이터 셋 둘 — 출력: $OUT"
run --lang rust --report "$REP/rust-pass.txt" --root "$REPO"
expect ok-rust 0 "통과 2 · FAIL 0"
# CI 의 rust 레인은 `CARGO_TERM_COLOR=always`(dtolnay/rust-toolchain)라 `Running …` 줄에 ANSI 색이 붙는다 — 그것을 못 걷으면
# 바이너리를 못 읽어 src 카나리아가 전부 「보고서에 없다」가 된다(#996 첫 CI 실측). 다른 바이너리의 ignored 미끼도 있다.
run --lang rust --report "$REP/rust-ansi.txt" --root "$REPO"
expect ok-rust-ansi 0 "통과 2 · FAIL 0"
run --lang ruby --report "$REP/ruby-pass.json" --root "$REPO"
expect ok-ruby 0 "통과 2 · FAIL 0"
assert_contains "$OUT" "(#{bad.inspect}) — 2 통과" "[ok-ruby] 보간 제목 둘 — 출력: $OUT"
# 보고서 둘을 함께 줄 수 있다 — 항목이 합쳐진다.
run --lang python --report "$REP/python-absent.xml" --report "$REP/python-pass.xml" --root "$REPO"
expect ok-two-reports 0 "통과 3 · FAIL 0"
# `--x=v` 표기도 같은 값이다.
run --lang=go "--report=$REP/go-pass.txt" "--root=$REPO"
expect ok-eq 0 "통과 3 · FAIL 0"
# --list — 해석만(보고서 없이).
run --lang go --list --root "$REPO"
expect list-go 0 "canaries go: 3"

# ═══ (a) FAIL — 카나리아가 이 실행에서 통과하지 않았다 ═══════════════════════════════════════════════
run --lang java --report "$REP/java/skip" --root "$REPO"
expect skip-java 1 "건너뛰었다 — 1/1 항목이 skip"
run --lang kotlin --report "$REP/kotlin-skip.xml" --root "$REPO"
expect skip-kotlin 1 "건너뛰었다"
run --lang python --report "$REP/python-skip.xml" --root "$REPO"
expect skip-python 1 "TestAio::test_aio_rejects_mismatched_nonce — 건너뛰었다"
run --lang python --report "$REP/python-param-skip.xml" --root "$REPO"
expect skip-python-param 1 "건너뛰었다 — 1/3 항목이 skip"
run --lang python --report "$REP/python-fail.xml" --root "$REPO"
expect fail-python 1 "실패했다 — 1/1 항목"
run --lang python --report "$REP/python-absent.xml" --root "$REPO"
expect absent-python 1 "보고서에 없다"
run --lang node --report "$REP/node-skip.xml" --root "$REPO"
expect skip-node 1 "건너뛰었다"
run --lang go --report "$REP/go-subskip.txt" --root "$REPO"
expect skip-go-sub 1 "TestNonceValidation — 건너뛰었다 — 1/2 항목이 skip"
run --lang go --report "$REP/go-absent.txt" --root "$REPO"
expect absent-go 1 "TestSlogMasks — 보고서에 없다"
run --lang dotnet --report "$REP/dotnet-skip.trx" --root "$REPO"
expect skip-dotnet 1 "X.Tests.AuthTests.Nonce_mismatch_throws — 건너뛰었다"
run --lang dotnet --report "$REP/dotnet-fail.trx" --root "$REPO"
expect fail-dotnet 1 "Rejects_non_string_access_token — 실패했다"
run --lang php --report "$REP/php-skip.xml" --root "$REPO"
expect skip-php 1 "testRejectsMismatchedNonce — 건너뛰었다"
run --lang rust --report "$REP/rust-ignored.txt" --root "$REPO"
expect skip-rust 1 "backoff_bounds_cold_retries — 건너뛰었다"
run --lang ruby --report "$REP/ruby-pending.json" --root "$REPO"
expect skip-ruby 1 "건너뛰었다 — 1/2 항목이 skip"
# 보고서가 없다 — 시험 단계가 보고서를 쓰지 않았다. 판정 불가(2)가 아니라 FAIL(1)이다.
run --lang python --report "$REP/does-not-exist.xml" --root "$REPO"
expect missing-report 1 "보고서가 없다"
run --lang java --report "$REP/no-such-dir" --root "$REPO"
expect missing-dir 1 "보고서가 없다"
# 디렉터리는 있는데 그 안에 보고서가 없다(TEST-*.xml 0 개) — 역시 FAIL.
run --lang java --report "$REP/dotnet/pass" --root "$REPO"
expect empty-dir 1 "보고서가 없다"

# ═══ (b) 판정 불가 — 검사가 못 읽었다 ═════════════════════════════════════════════════════════════════
run --lang python --report "$REP/not-junit.xml" --root "$REPO"
expect not-junit 2 "JUnit XML 이 아니다"
run --lang python --report "$REP/empty-junit.xml" --root "$REPO"
expect empty-report 2 "테스트 항목을 하나도 읽지 못했다"
run --lang ruby --report "$REP/python-pass.xml" --root "$REPO"
expect not-rspec 2 "RSpec JSON 이 아니다"
run --lang dotnet --report "$REP/python-pass.xml" --root "$REPO"
expect not-trx 2 "TRX 가 아니다"
run --lang go --report "$REP/java/pass" --root "$REPO"
expect go-dir 2 "디렉터리를 받지 않는다"
run --lang java --list --root "$FIX/repo-sites"
expect sites 2 "부르는 자리가 6 인데 이 검사가 아는 축은 5"
run --lang java --list --root "$FIX/repo-nofn"
expect nofn 2 "표 함수 \`sd_mask2_canary() {\` 가 없다"
run --lang java --list --root "$FIX/repo-bad"
expect twice 2 "주석 밖 2 줄에 있다"
run --lang kotlin --list --root "$FIX/repo-bad"
expect off-decl 2 "선언의 이름이 카나리아 자리와 겹치지 않는다"
run --lang go --list --root "$FIX/repo-bad"
expect go-helper 2 "Test 함수가 아니다(func helper"
run --lang python --list --root "$FIX/repo-bad"
expect gone 2 "python/tests/test_gone.py: 못 읽었다"
run --lang node --list --root "$FIX/repo-bad"
expect outside 2 "node/ 밖이다"
run --lang ruby --list --root "$FIX/repo-bad"
expect vacuous 2 "카나리아를 하나도 얻지 못했다"
run --lang swift --report x --root "$REPO"
expect unknown-lang 2 "모르는 언어다: swift"
run --lang python --root "$REPO"
expect no-report 2 "--report 가 없다"
run --lang python --list --report x --root "$REPO"
expect list-and-report 2 "--list 는 --report 와 함께"
run --lang --report x
expect lang-swallows-flag 2 "--lang 에 값이 없다"
run --lang python --report "$REP/python-pass.xml" extra
expect extra-arg 2 "인자가 남는다"

# ═══ 계측기 자신 — 서로 다른 결함이 서로 다른 이유를 내는가 ═════════════════════════════════════════
# 위 칸들이 전부 같은 문장으로 실패하면(예: 늘 「보고서에 없다」) 이 테스트는 입력을 보지 않는 검사를 초록으로 감싼다.
run --lang python --report "$REP/python-skip.xml" --root "$REPO"
_r1="$OUT"
run --lang python --report "$REP/python-absent.xml" --root "$REPO"
_r2="$OUT"
assert_fails test "$_r1" = "$_r2"

assert_report
