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

assert_report
