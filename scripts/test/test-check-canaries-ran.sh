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
expect sites 2 "부르는 자리가 8 인데 이 검사가 아는 축은 7"
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

# ═══ 독립 레그(2026-11-09)가 실측으로 찾은 구멍 — 고치기 전 검사에서는 전부 0 이었다(should_panic 만 우연히 1) ═══════
# 속성값 안의 `>` — XML 은 이스케이프를 요구하지 않는다. 태그를 거기서 끊으면 건너뛴 카나리아가 통과로 읽힌다.
run --lang python --report "$REP/python-gt-attr.xml" --root "$REPO"
expect leg-gt-attr 1 "test_rejects_mismatched_nonce — 건너뛰었다"
# 다른 describe 의 같은 제목 — 카나리아가 빠졌는데 그 통과가 대신 읽혔다(describe 경로까지 맞춘다).
run --lang node --report "$REP/node-decoy.xml" --root "$REPO"
expect leg-node-describe 1 "nonce 가 틀리면 거부한다(이 설정에서 검사가 돈다) — 보고서에 없다"
# 괄호를 담은 kotlin 백틱 이름 — `rejects mismatched nonce(legacy client)` 가 카나리아로 읽혔다.
run --lang kotlin --report "$REP/kotlin-decoy.xml" --root "$REPO"
expect leg-kotlin-paren 1 "rejects mismatched nonce — 보고서에 없다"
# 서브테스트를 전부 뺀 필터(-skip 'TestX/.') — 부모의 PASS 만 남는다.
run --lang go --report "$REP/go-subfiltered.txt" --root "$REPO"
expect leg-go-subfiltered 1 "서브테스트가 하나도 보고되지 않았다"
# 더 깊은 모듈의 같은 이름 — 경로를 정확히 맞춘다.
run --lang rust --report "$REP/rust-decoy.txt" --root "$REPO"
expect leg-rust-depth 1 "auth::tests::rejects_mismatched_nonce — 보고서에 없다"
# should_panic — 통과가 곧 단언 실패다(예전엔 줄을 못 읽어 우연히 「보고서에 없다」였다).
run --lang rust --report "$REP/rust-should-panic.txt" --root "$REPO"
expect leg-rust-should-panic 1 "뒤집혔다"
# 같은 파일의 비슷한 제목(`#{…}` 가 아무 글자) — 정의 줄로 맞춘다.
run --lang ruby --report "$REP/ruby-decoy.json" --root "$REPO"
expect leg-ruby-line 1 "보고서에 없다"
# it.fails — 보고서의 통과가 곧 카나리아 단언의 실패다.
run --lang node --report "$REP/node-pass.xml" --root "$FIX/repo-more"
expect leg-node-fails 1 "뒤집혔다"
# 함수 안의 def — pytest 가 모으지 않는데 바깥 클래스의 테스트로 읽혔다.
run --lang python --list --root "$FIX/repo-more"
expect leg-python-nested 2 "함수 안에 있다"
# 표 함수가 정의 밖 헬퍼를 부른다 — 예전엔 그 행만 조용히 빠지고 rc 0 이었다.
run --lang python --list --root "$FIX/repo-helper"
expect leg-helper 2 "정의 밖의 무엇"

# ═══ 독립 레그 2 의 반례 — 건강한 실행의 거짓 FAIL · 남은 0 · 정할 수 없는 이름(옛 판 f3df9ef1 과 대조했다) ═════════
# node: 닫힌 형제 describe 뒤의 it.each 제목은 건강하다(옛 판은 그 describe 를 감싼 것으로 읽어 FAIL) · 행 스물둘 위의
# it.fails.each 와 제목에 `it (` 가 든 it.fails(…) 는 뒤집힘이다(옛 판은 20 줄 창·제목 속 글자 탓에 놓쳤다).
run --lang node --report "$REP/node-r2.xml" --root "$FIX/repo-r2"
expect r2-node 1 "통과 1 · FAIL 2"
assert_contains "$OUT" "r2 healthy each: %s — 1 통과" "[r2-node] 닫힌 형제 describe 를 감싼 것으로 읽었다 — 출력: $OUT"
assert_contains "$OUT" "r2 fails each: %s — 뒤집혔다" "[r2-node] 행 스물둘 위의 it.fails.each 를 놓쳤다 — 출력: $OUT"
assert_contains "$OUT" "r2 fails it (call): number — 뒤집혔다" "[r2-node] 제목 속 \`it (\` 를 호출로 읽었다 — 출력: $OUT"
# go: 주석 속 t.Run( 은 서브테스트가 아니다(건강) · tt.Run 으로 연 서브테스트를 전부 빼면 FAIL.
run --lang go --report "$REP/go-r2.txt" --root "$FIX/repo-r2"
expect r2-go 1 "통과 1 · FAIL 1"
assert_contains "$OUT" "TestCommentOnly — 1 통과" "[r2-go] 주석 속 t.Run( 을 서브테스트로 읽었다 — 출력: $OUT"
assert_contains "$OUT" "TestReceiverSubtests — 서브테스트를 여는" "[r2-go] tt.Run 으로 연 서브테스트를 못 봤다 — 출력: $OUT"
# ruby: `it "x",` 다음 줄의 `do` — RSpec 의 line_number 는 그 do 줄이다(건강).
run --lang ruby --report "$REP/ruby-r2.json" --root "$FIX/repo-r2"
expect r2-ruby 0 "통과 1 · FAIL 0"
# 이름을 정할 수 없는 모양은 추측하지 않고 판정 불가다.
run --lang node --list --root "$FIX/repo-r2b"
expect r2-node-describe 2 "describe 제목이 리터럴이 아니다"
run --lang go --list --root "$FIX/repo-r2b"
expect r2-go-table 2 "본문(5–5행) 밖이다"
run --lang rust --list --root "$FIX/repo-r2b"
expect r2-rust-path 2 "로 들인 모듈이다"
run --lang kotlin --list --root "$FIX/repo-r2b"
expect r2-kotlin-param 2 "표시 이름을 바꾸는 어노테이션"

# ═══ vitest 옵션 인자의 fails — JUnit 은 「expected fail」을 그냥 통과로 적는다(vitest 5.1 실측 · #1017 레그) ═══════
# 건강 열둘과 뒤집힘 일곱(픽스처 머리 주석). 판독은 파일 단위로 문자열 · 템플릿 · 주석 · 정규식을 비운 글(maskJs)에서
# 한다 — 줄 단위로 비웠을 때 #1018 레그가 낸 오탐 다섯(인자 사이 주석 · 이름 붙은 타임아웃 · 주석 속 「fails」 · 주석 단
# describe · 여러 줄 템플릿을 담은 감싼 함수)과 우회 넷(주석 속 `}` · 주석으로 시작하는 줄의 describe · `.skipIf(…).fails(`
# 사슬 · 정규식 속 `}`)이 이 칸들이다.
run --lang node --report "$REP/node-r3.xml" --root "$FIX/repo-r3"
expect r3-node 1 "통과 12 · FAIL 9"
# 템플릿 `${}` 안의 중첩 템플릿 — 식을 따라가지 않으면 템플릿이 그 안의 백틱에서 끝난 것으로 읽혀 옵션 객체를 놓친다
# (변이 L15 가 처음엔 SILENT 였다 — 감싼 함수 칸에선 잘못 읽어도 결론이 같은 「건강」으로 떨어졌다).
assert_contains "$OUT" "o13 template expression in options — 뒤집혔다" "[r3-node] 템플릿 \${} 안의 중첩 템플릿에서 옵션 객체를 놓쳤다 — 출력: $OUT"
# 키워드 뒤 정규식(`return /}/`) — 나눗셈으로 읽으면 그 `}` 가 옵션 객체를 일찍 닫아 `fails: true` 를 숨겼다(Grok 레그 Q1).
assert_contains "$OUT" "o12 regex after return — 뒤집혔다" "[r3-node] 키워드 뒤 정규식 속 괄호가 옵션 객체를 일찍 닫았다 — 출력: $OUT"
for _h in "o3c single-parameter arrow" "o3d async arrow" "o3e function keyword" "o3f comment before the function" \
  "o3g named timeout constant" "o3h comment mentions fails" "o3i inside a commented describe" "o3j wrapped function"; do
  assert_contains "$OUT" "$_h — 1 통과" "[r3-node] 건강한 꼴($_h)을 옵션 · 뒤집힘 · 판정 불가로 읽었다 — 출력: $OUT"
done
for _i in "o7 comment with a brace" "o8 inside a commented fails describe" "o9 chained fails" "o10 regex with a brace"; do
  assert_contains "$OUT" "$_i — 뒤집혔다" "[r3-node] 뒤집힌 꼴($_i)을 놓쳤다 — 출력: $OUT"
done
assert_contains "$OUT" "o1 timeout options — 1 통과" "[r3-node] timeout 옵션을 뒤집힘으로 읽었다 — 출력: $OUT"
assert_contains "$OUT" "o2 fails false — 1 통과" "[r3-node] fails: false 를 뒤집힘으로 읽었다 — 출력: $OUT"
assert_contains "$OUT" "o3 function reference — 1 통과" "[r3-node] 함수 참조를 옵션으로 읽었다 — 출력: $OUT"
# 함수 참조 + 숫자 타임아웃(`it(제목, fn, 5000)`)은 vitest 5 가 받는 건강한 꼴이다 — 식별자 뒤 `,` 를 옵션 변수로 읽으면
# 판정 불가가 된다(Grok 레그 Q2 · vitest 5.1 실측).
assert_contains "$OUT" "o3b function reference and timeout — 1 통과" "[r3-node] 함수 참조 + 타임아웃을 옵션 변수로 읽었다 — 출력: $OUT"
assert_contains "$OUT" "o4 fails true — 뒤집혔다" "[r3-node] 옵션 인자의 fails: true 를 놓쳤다 — 출력: $OUT"
assert_contains "$OUT" "o5 fails multi-line — 뒤집혔다" "[r3-node] 여러 줄 옵션의 fails 를 놓쳤다 — 출력: $OUT"
assert_contains "$OUT" "o6 inside a fails describe — 뒤집혔다" "[r3-node] describe 옵션의 fails 를 놓쳤다 — 출력: $OUT"
# 가릴 수 없는 옵션은 추측하지 않고 판정 불가다(첫 판정 불가가 실행을 멈추므로 저장소 하나에 하나씩).
run --lang node --list --root "$FIX/repo-r3b"
expect r3-node-var 2 "리터럴 객체가 아니다"
run --lang node --list --root "$FIX/repo-r3c"
expect r3-node-spread 2 "펼침"
run --lang node --list --root "$FIX/repo-r3d"
expect r3-node-expr 2 "true/false 리터럴이 아니다"
run --lang node --list --root "$FIX/repo-r3h"
expect r3-node-quoted 2 "문자열 · 계산된 키"
# 선언 꼴 카나리아가 문자열 안에만 있으면 그 문자열을 담은 다른 테스트가 대신 통과로 읽혔다(#1017 레그: go 는 감싼 함수 ·
# node 는 제목이 `it('…'` 인 가짜 시험 — ruby 는 같은 꼴). 이름으로 항목을 찾는 언어는 진짜 항목에 닿아 해당 없다.
run --lang go --list --root "$FIX/repo-r3e"
expect r3e-go 2 "선언 자리가 아니다"
run --lang node --list --root "$FIX/repo-r3e"
expect r3e-node 2 "선언 자리가 아니다"
run --lang ruby --list --root "$FIX/repo-r3e"
expect r3e-ruby 2 "선언 자리가 아니다"
# 따옴표 없는 줄(여러 줄 raw 문자열 속)의 들여쓴 `func Test…(` — 문자열 규칙은 못 보고 go 줄 머리 규칙만 막는다.
run --lang go --list --root "$FIX/repo-r3f"
expect r3f-go 2 "선언 자리가 아니다"
# 여러 줄 템플릿 안의 가짜 `it('…'` 줄 — 줄 단위로는 코드로 보였다(#1018 레그). 파일 단위로 비우면 템플릿 안이다.
run --lang node --list --root "$FIX/repo-r3g"
expect r3g-node 2 "선언 자리가 아니다"

# ═══ 계측기 자신 — 서로 다른 결함이 서로 다른 이유를 내는가 ═════════════════════════════════════════
# 위 칸들이 전부 같은 문장으로 실패하면(예: 늘 「보고서에 없다」) 이 테스트는 입력을 보지 않는 검사를 초록으로 감싼다.
run --lang python --report "$REP/python-skip.xml" --root "$REPO"
_r1="$OUT"
run --lang python --report "$REP/python-absent.xml" --root "$REPO"
_r2="$OUT"
assert_fails test "$_r1" = "$_r2"

assert_report
