#!/usr/bin/env sh
# 커버리지 게이트 가드 자가테스트 — 이 가드의 존재 이유는 임계값 비교가 아니라 **"측정 실패"와
# "커버리지 하락"을 구분**하는 것이다. 그래서 테스트의 핵심은 "낮으면 실패한다"가 아니라
# "0%일 때 하락이 아니라 측정 실패라고 말한다"이다 — 둘 다 exit 1이므로 종료코드만 보는
# 테스트는 이 가드의 유일한 가치를 검증하지 못한다(그래서 stderr 문구까지 고정한다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/coverage-gate"
GUARD="$DIR/../check-coverage.mjs"

# 정상 리포트는 통과한다(오탐 없음).
assert_ok node "$GUARD" "$FIX/healthy.xml" --min-line 90 --min-branch 85

# 정상 리포트라도 임계값을 올리면 실패해야 한다 — 가드가 임계값을 실제로 읽는다는 대조군.
# 이게 없으면 비교문을 통째로 지워도 위 assert_ok가 통과해 테스트가 공허해진다.
assert_fails node "$GUARD" "$FIX/healthy.xml" --min-line 99 --min-branch 85
assert_fails node "$GUARD" "$FIX/healthy.xml" --min-line 90 --min-branch 95

# 진짜 하락: 분모가 살아있고 분자도 있는데 임계값 미달 → 하락으로 보고한다.
out=$(node "$GUARD" "$FIX/regression.xml" --min-line 90 --min-branch 85 2>&1 || true)
assert_contains "$out" "coverage-regression" "하락은 coverage-regression으로 보고"
assert_not_contains "$out" "measurement" "하락을 측정 실패로 오분류하지 않는다"

# 플레이크 서명: 분모(lines-valid)는 멀쩡한데 분자(lines-covered)가 0.
# 테스트가 통과했는데 히트가 0인 것은 물리적으로 하락일 수 없다 — 측정 실패로 보고해야 한다.
# 이 케이스를 "커버리지 90 미만"이라고 말하던 것이 정확히 우리가 고치는 결함이다.
out=$(node "$GUARD" "$FIX/zero-hits.xml" --min-line 90 --min-branch 85 2>&1 || true)
assert_contains "$out" "coverage-measurement-failed" "0 히트는 측정 실패로 보고"
assert_not_contains "$out" "coverage-regression" "0 히트를 하락으로 보고하지 않는다"

# 아무것도 계측되지 않음(lines-valid=0) → 역시 측정 실패. 0으로 접으면 안 된다.
out=$(node "$GUARD" "$FIX/nothing-instrumented.xml" --min-line 90 --min-branch 85 2>&1 || true)
assert_contains "$out" "coverage-measurement-failed" "미계측은 측정 실패로 보고"

# 리포트 파일 자체가 없음 → 조용히 통과하면 게이트가 무력화된다. fail-closed.
out=$(node "$GUARD" "$FIX/does-not-exist.xml" --min-line 90 --min-branch 85 2>&1 || true)
assert_contains "$out" "coverage-measurement-failed" "리포트 부재는 측정 실패로 보고"
assert_fails node "$GUARD" "$FIX/does-not-exist.xml" --min-line 90 --min-branch 85

# 디렉터리를 주면 하위에서 cobertura 리포트를 찾는다 — collector는 msbuild 통합과 달리 고정 경로가
# 아니라 `TestResults/<랜덤 guid>/coverage.cobertura.xml`에 쓰므로 경로를 못박을 수 없다.
assert_ok node "$GUARD" "$FIX/nested" --min-line 90 --min-branch 85

# ── 임계값 인자 파싱 ─────────────────────────────────────────────────────────
# ⚠️ 이 가드의 최악은 미달 오판이 아니라 **임계값이 조용히 사라지는 것**이다. `numArg`가
# `argv.indexOf(name)`만 보던 시절, 등호 표기 `--min-line=99`는 이름과 매치되지 않아 기본값
# 0으로 떨어졌고, 회귀 픽스처(라인 82.87%)가 「커버리지 OK — 임계 0/0」으로 **통과**했다.
# 비수치·값 누락도 각각 NaN·0이 되어 비교가 항상 거짓이 된다. 셋 다 exit 0이라
# 종료코드만 보는 테스트로는 잡히지 않는다.

# 등호 표기도 공백 표기와 **같은** 판정을 내야 한다(회귀 픽스처는 어느 표기로도 실패).
assert_fails node "$GUARD" "$FIX/regression.xml" --min-line=99 --min-branch=99
assert_fails node "$GUARD" "$FIX/regression.xml" --min-line 99 --min-branch 99
# 그리고 등호 표기로 임계를 낮추면 통과해야 한다 — 값이 실제로 읽힌다는 대조군.
# (이게 없으면 "등호 표기는 무조건 실패"로 퇴화해도 위 assert_fails가 통과한다.)
assert_ok node "$GUARD" "$FIX/healthy.xml" --min-line=90 --min-branch=85
assert_fails node "$GUARD" "$FIX/healthy.xml" --min-line=99 --min-branch=85

# 비수치 임계값은 통과가 아니라 **설정 오류**다.
assert_fails node "$GUARD" "$FIX/healthy.xml" --min-line abc --min-branch 85
out=$(node "$GUARD" "$FIX/healthy.xml" --min-line abc --min-branch 85 2>&1 || true)
assert_contains "$out" "threshold-invalid" "비수치 임계값은 threshold-invalid로 보고"
assert_not_contains "$out" "커버리지 OK" "비수치 임계값을 통과로 읽지 않는다"

# 값이 없는 플래그(마지막 위치)도 마찬가지다.
assert_fails node "$GUARD" "$FIX/healthy.xml" --min-branch 85 --min-line
out=$(node "$GUARD" "$FIX/healthy.xml" --min-branch 85 --min-line 2>&1 || true)
assert_contains "$out" "threshold-invalid" "값 없는 플래그는 threshold-invalid로 보고"

# 플래그 뒤에 **다른 플래그**가 오는 것도 값 누락이다.
assert_fails node "$GUARD" "$FIX/healthy.xml" --min-line --min-branch 85

assert_report
