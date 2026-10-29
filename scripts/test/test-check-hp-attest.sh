#!/usr/bin/env sh
# `check-hp-attest.mjs` 자가테스트 — 적대 경로 행렬의 attest 파일(「이 실행에서 행렬이 실제로 돌았다」의 증명) 대조.
#
# ⚠️ **픽스처만 쓴다 — 실제 행렬도 실제 등록부도 읽지 않는다.** 이 파일은 required 체크 `doc-facts` 안에서 돈다.
# 판정이 가드 코드와 `scripts/test/fixtures/hp-attest/` 에만 달려 있어서, 언어 CI 의 실행·산출물·네트워크 어느 것도
# 이 체크를 빨갛게 하지 못한다(빨개지는 것은 가드·픽스처·등록부 판독기를 고친 PR 뿐이다). 실제 attest 대조는 아홉
# 레인의 단위 테스트 단계 바로 뒤의 비-required 단계가 한다. 임시 파일도 만들지 않는다 — 읽기만 한다.
#
# 무게는 「통과한다」가 아니라 아래 셋이다.
#   (a) FAIL 사유마다 1 — 그리고 **그 사유를 말한다.** 종료코드만 보면 판별자 하나를 지워도 다른 사유가 1 을 내서
#       통과한다(check-coverage 자가테스트와 같은 이유) — 그래서 칸마다 사유 문구를 고정한다.
#   (b) 읽지 못한 입력은 2 — 「행렬이 증명하지 못했다」(1)와 「가드가 못 읽었다」(2)를 가른다. ⚠️ 디렉터리가 **없는**
#       것은 2 가 아니라 1 이다 — 행렬이 디렉터리를 만드므로, 없다는 것은 아무 행렬도 쓰지 않았다는 바로 그 사건이다.
#   (c) 양성 대조군 — 맞는 attest 는 0 이고, **열린** id 를 실은 attest 도 0 이다. 이것이 없으면 「무엇을 넣어도
#       FAIL」인 가드가 (a) 를 전부 통과한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-hp-attest.mjs"
FIX="$DIR/fixtures/hp-attest"
REG="$FIX/registry"
N='4242.1.build.0'

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

# ═══ (c) 양성 — 맞는 attest 는 통과한다 ═══════════════════════════════════════════════════════
run "$FIX/ok" --nonce "$N" --lang go --root "$REG"
expect ok-go 0 "ok    go"
assert_contains "$OUT" "rows 12" "[ok-go] 통과 줄이 attest 의 수를 찍어야 한다 — 출력: $OUT"
# 열린 id 두 모양(소문자 · 대문자 첫 마디 + 점)을 실은 attest — 등록부를 실제로 읽고 열림으로 판정한다.
run "$FIX/ok" --nonce "$N" --lang go,rust --root "$REG"
expect ok-two 0 "통과 2"
assert_contains "$OUT" "H9-open-gap-0.44-two" "[ok-two] 열린 known gap 을 통과 줄에 찍어야 한다 — 출력: $OUT"
# `--x=v` 표기도 같은 값이다.
run "$FIX/ok" "--nonce=$N" --lang=go --root "$REG"
expect ok-eq 0 "ok    go"

# ═══ (a) FAIL — 행렬이 이 실행에서 증명하지 못했다 ═══════════════════════════════════════════
# 파일 없음 — 그 언어의 행렬이 돌지 않았다(필터·캐시 재생·skip) 또는 단언이 실패해 쓰지 않았다.
run "$FIX/ok" --nonce "$N" --lang go,java --root "$REG"
expect missing-file 1 "java.json 이 없다"
assert_contains "$OUT" "ok    go" "[missing-file] 다른 언어의 판정은 그대로 찍혀야 한다(한 줄에 하나) — 출력: $OUT"
# 디렉터리가 없다 — 아무 행렬도 쓰지 않았다. 판정 불가(2)가 아니라 FAIL(1)이다.
run "$FIX/does-not-exist" --nonce "$N" --lang go --root "$REG"
expect missing-dir 1 "go.json 이 없다"

run "$FIX/nonce" --nonce "$N" --lang go --root "$REG"
expect nonce 1 "nonce 가 \"4242.2.build.0\""
run "$FIX/lang" --nonce "$N" --lang go --root "$REG"
expect lang 1 "lang 이 \"rust\""
run "$FIX/rows-zero" --nonce "$N" --lang go --root "$REG"
expect rows-zero 1 "rows 가 0"
run "$FIX/rows-string" --nonce "$N" --lang go --root "$REG"
expect rows-string 1 "rows 가 \"12\""
run "$FIX/class-negative" --nonce "$N" --lang go --root "$REG"
expect class-negative 1 "OTHER=-1"
run "$FIX/class-missing" --nonce "$N" --lang go --root "$REG"
expect class-missing 1 "UNDETERMINED=없음"
run "$FIX/class-unknown" --nonce "$N" --lang go --root "$REG"
expect class-unknown 1 "모르는 계급 TOKEN-GRANT"
run "$FIX/class-sum" --nonce "$N" --lang go --root "$REG"
expect class-sum 1 "계급 합 12 ≠ rows 13"
run "$FIX/w3-zero" --nonce "$N" --lang go --root "$REG"
expect w3-zero 1 "w3 가 0"
run "$FIX/w1-false" --nonce "$N" --lang go --root "$REG"
expect w1-false 1 "w1 이 false"
# 문자열 "true" 는 참이 아니다 — 값 비교가 느슨해지면(truthy) 여기서 운다.
run "$FIX/w1-string" --nonce "$N" --lang go --root "$REG"
expect w1-string 1 "w1 이 \"true\""
run "$FIX/gap-closed" --nonce "$N" --lang go --root "$REG"
expect gap-closed 1 "\"closed-gap-one\" 는 등록부"
assert_not_contains "$OUT" "\"open-gap-one\"" "[gap-closed] 열린 id 를 지목하면 안 된다 — 출력: $OUT"
# 하위 불릿에만 나오는 이름은 등록부 항목이 아니다(판독기가 느슨해지면 열림으로 샌다).
run "$FIX/gap-unknown" --nonce "$N" --lang go --root "$REG"
expect gap-unknown 1 "\"prose-only-gap\" 는 등록부에 없다"
run "$FIX/gap-not-array" --nonce "$N" --lang go --root "$REG"
expect gap-not-array 1 "knownGaps 가 문자열 배열이 아니다"

# ═══ (b) 판정 불가 — 가드가 읽지 못했다 ══════════════════════════════════════════════════════
run "$FIX/bad-json" --nonce "$N" --lang go --root "$REG"
expect bad-json 2 "JSON 이 아니다"
run "$FIX/not-object" --nonce "$N" --lang go --root "$REG"
expect not-object 2 "JSON 객체가 아니다"
run "$FIX/ok/go.json" --nonce "$N" --lang go --root "$REG"
expect not-a-dir 2 "디렉터리가 아니다"
# 판정 불가는 FAIL 보다 앞선다 — 섞이면 2 다(check-known-gaps 와 같다).
run "$FIX/ok" --nonce "$N" --lang rust --root "$FIX/registry-dup"
expect registry-dup 2 "2번 있다"
# 대조할 id 가 있는데 등록부가 없다 → 판정 불가.
run "$FIX/ok" --nonce "$N" --lang rust --root "$FIX/ok"
expect registry-missing 2 "등록부 파일이 없다"
# ⚠️ 대조할 id 가 없으면 등록부를 읽지 않는다 — 등록부 표기 사고가 아홉 레인을 함께 빨갛게 하지 않게(머리 주석).
run "$FIX/ok" --nonce "$N" --lang go --root "$FIX/ok"
expect registry-lazy 0 "ok    go"

run "$FIX/ok" --nonce "$N" --lang go --bogus
expect unknown-flag 2 "모르는 플래그 --bogus"
run "$FIX/ok" --nonce "$N" --lang ""
expect empty-lang 2 "빈 언어"
run "$FIX/ok" --nonce "$N" --lang go,,rust
expect empty-lang-item 2 "빈 언어"
run "$FIX/ok" --nonce "$N" --lang ../ok/go
expect lang-grammar 2 "문법"
run "$FIX/ok" --lang go
expect no-nonce 2 "--nonce"
run "$FIX/ok" --nonce "" --lang go
expect empty-nonce 2 "--nonce"
run "$FIX/ok" --nonce --lang go
expect nonce-swallows-flag 2 "--nonce 에 값이 없다"
run --nonce "$N" --lang go
expect no-dir 2 "<dir> 가 없다"
run "$FIX/ok" "$FIX/nonce" --nonce "$N" --lang go
expect extra-arg 2 "인자가 남는다"

# ═══ 계측기 자신 — 서로 다른 결함이 서로 다른 이유를 내는가 ═════════════════════════════════════
# 위 칸들이 전부 같은 문장으로 실패하면(예: 늘 「파일 없음」) 이 테스트는 입력을 보지 않는 가드를 초록으로 감싼다.
run "$FIX/nonce" --nonce "$N" --lang go --root "$REG"
_r1="$OUT"
run "$FIX/w1-false" --nonce "$N" --lang go --root "$REG"
_r2="$OUT"
assert_fails test "$_r1" = "$_r2"

assert_report
