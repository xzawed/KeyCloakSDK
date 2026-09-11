#!/usr/bin/env sh
# conformance authz-url 판정 자가테스트.
#
# ⚠️ **이 가드의 존재 이유**: 이 판정은 Docker 전체 런 없이는 시험할 수 없어서, 아무도 재보지
# 않은 채 아홉 언어에 「authz-url S256 통과」를 발급하고 있었다. 그 초록이 무엇을 근거로
# 나오는지가 이 파일이 답하는 것이다.
#
# ⚠️ **핵심 대조군은 `ignores-redirect-uri`다.** 옛 판정은 요청한 redirect_uri를 응답과
# 대조하지 않았고, 검사가 보내는 값(`http://x/cb`)이 아홉 앱 **전부의 폴백**과 같아서
# 「앱이 요청을 무시했다」와 「앱이 요청을 지켰다」가 같은 초록을 냈다. 이 픽스처가 실패로
# 뒤집히지 않으면 이 가드는 다시 공허해진 것이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/conformance-authz-url"
MOD="$DIR/../../harness/conformance/authz-url.mjs"

# ── 양성: 계약을 지킨 응답은 통과한다(오탐 없음). ───────────────────────────
assert_ok node "$MOD" "$FIX/compliant.json"

# ── 이 PR이 겨누는 공허 셋 ──────────────────────────────────────────────────
# 1) 요청한 redirect_uri를 무시하고 자기 폴백을 쓴 응답.
assert_fails node "$MOD" "$FIX/ignores-redirect-uri.json"
out=$(node "$MOD" "$FIX/ignores-redirect-uri.json" 2>&1 || true)
assert_contains "$out" "redirect-uri-mismatch" "요청 무시를 redirect-uri-mismatch로 보고"

# 2) PKCE가 사실상 꺼진 응답(code_challenge 빈 값). 옛 정규식 `/code_challenge=/`는 통과시켰다.
assert_fails node "$MOD" "$FIX/empty-code-challenge.json"
out=$(node "$MOD" "$FIX/empty-code-challenge.json" 2>&1 || true)
assert_contains "$out" "code-challenge-invalid" "빈 challenge를 code-challenge-invalid로 보고"

# 3) URL의 state와 돌려준 state가 다른 응답. 옛 검사는 둘의 존재만 따로 봤다.
assert_fails node "$MOD" "$FIX/state-mismatch.json"
out=$(node "$MOD" "$FIX/state-mismatch.json" 2>&1 || true)
assert_contains "$out" "state-mismatch" "state 불일치를 state-mismatch로 보고"

# 3b) state가 빈 값인 응답 — `/[?&]state=/`가 통과시키던 같은 부류.
assert_fails node "$MOD" "$FIX/empty-state.json"

# ── 옛 판정이 이미 잡던 것들 — 강화하면서 잃지 않았는가(회귀 대조군). ──────
assert_fails node "$MOD" "$FIX/leaks-verifier.json"
out=$(node "$MOD" "$FIX/leaks-verifier.json" 2>&1 || true)
assert_contains "$out" "code-verifier-leaked" "verifier 누출을 code-verifier-leaked로 보고"

assert_fails node "$MOD" "$FIX/plain-challenge-method.json"
assert_fails node "$MOD" "$FIX/status-500.json"

# ── 계측기 자신의 (c): 알려진 음성 입력에서 **다른 답**이 나오는가. ─────────
# 위 assert_fails들이 전부 같은 이유로 실패하면(예: 파서가 늘 터진다) 이 테스트는
# 「무엇을 넣어도 FAIL」인 계측기를 초록으로 감싼다. 그래서 이유가 서로 다름을 본다.
r1=$(node "$MOD" "$FIX/ignores-redirect-uri.json" 2>&1 || true)
r2=$(node "$MOD" "$FIX/state-mismatch.json" 2>&1 || true)
if [ "$r1" = "$r2" ]; then
  printf 'FAIL 서로 다른 결함이 같은 이유를 낸다 — 판정기가 입력을 보지 않는다\n  [%s]\n' "$r1" >&2
  _A_FAIL=$((_A_FAIL+1))
else
  _A_PASS=$((_A_PASS+1))
fi

# ── conformance.mjs가 실제로 이 모듈을 쓰는가. ──────────────────────────────
# 모듈만 고치고 호출부가 옛 인라인 정규식을 그대로 두면 이 테스트 전부가 공허하다.
CONF="$DIR/../../harness/conformance/conformance.mjs"
if grep -q 'judgeAuthzUrl' "$CONF"; then
  _A_PASS=$((_A_PASS+1))
else
  printf 'FAIL conformance.mjs가 판정 모듈을 쓰지 않는다 — 모듈만 고치고 호출부가 옛 정규식이면 위 전부가 공허하다\n' >&2
  _A_FAIL=$((_A_FAIL+1))
fi
if grep -q 'code_challenge_method=S256' "$CONF"; then
  printf 'FAIL conformance.mjs에 옛 인라인 정규식이 남아 있다\n' >&2
  _A_FAIL=$((_A_FAIL+1))
else
  _A_PASS=$((_A_PASS+1))
fi

# ⚠️ **판정을 고쳐도 보내는 값이 앱 폴백이면 공허가 그대로 돌아온다** — 요청을 무시한 앱이
# 폴백을 돌려주고, 그 폴백이 곧 요청값이라 대조가 통과한다. 그래서 「폴백과 다른 값을
# 보내는가」를 여기서 못박는다. 아홉 앱의 폴백은 전부 `http://x/cb`다(실측 2026-09-12:
# node·python·go·java·dotnet·ruby·kotlin은 쿼리 폴백, php는 config 고정, rust는 쿼리 무시).
#
# ⚠️ **주석을 걷어내고 센다.** 이 검사를 처음 쓸 때 바로 이 파일의 *설명 주석* 에 걸려
# 빨개졌다 — 등록부가 이름 붙인 부류(`guard-probes-count-mentions-not-declarations`)를
# 가드 자신이 저지른 것이다. 산문 언급은 선언이 아니다.
conf_code=$(grep -v '^[[:space:]]*//' "$CONF")
case "$conf_code" in
  *x/cb*)
    printf 'FAIL conformance.mjs가 앱 폴백(http://x/cb)을 그대로 보낸다 — 무시와 준수가 구분되지 않는다\n' >&2
    _A_FAIL=$((_A_FAIL+1))
    ;;
  *) _A_PASS=$((_A_PASS+1)) ;;
esac
# 실행마다 달라야 한다 — 리터럴 하나로 고정하면 앱이 그 값을 하드코딩하는 순간 다시 공허하다.
if grep -q 'probeRedirect = .*rnd()' "$CONF"; then
  _A_PASS=$((_A_PASS+1))
else
  printf 'FAIL conformance.mjs의 프로브 redirect_uri가 실행마다 달라지지 않는다\n' >&2
  _A_FAIL=$((_A_FAIL+1))
fi

assert_report
