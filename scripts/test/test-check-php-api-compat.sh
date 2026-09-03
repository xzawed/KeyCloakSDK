#!/usr/bin/env sh
# php API 호환성 가드 자가테스트.
#
# 이 가드의 존재 이유는 「MAJOR 면 실패」가 아니라 **도구의 주장을 소스로 반증**하는 것이다.
# 그래서 테스트의 핵심은 「면제가 동작한다」가 아니라 **면제 술어가 거짓일 때는 면제되지 않는다**이다 —
# 그 대조군이 없으면 이 가드는 곧 게이트를 무력화하는 장치가 된다.
#
# 리포트를 파일로 받으므로 PHP 툴체인 없이 돈다(가드 자신이 그렇게 설계돼 있다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/php-api-compat"
GUARD="$DIR/../check-php-api-compat.mjs"

# ── 면제가 동작한다 ──────────────────────────────────────────────────────────
# final 클래스에 메서드가 늘었다 → 상속 불가라 충돌할 수 없다 = MINOR.
assert_ok node "$GUARD" --report "$FIX/report-final-add.txt" --base "$FIX/base" --new "$FIX/final-add"

# 생성자 파라미터가 바이트 동일한데 도구가 V097 을 주장한다 → 반증된다.
assert_ok node "$GUARD" --report "$FIX/report-v097-same.txt" --base "$FIX/base" --new "$FIX/v097-same"

# 변경 없음.
assert_ok node "$GUARD" --report "$FIX/report-none.txt" --base "$FIX/base" --new "$FIX/base"

# ── 대조군: 술어가 거짓이면 면제되지 않는다 ──────────────────────────────────
# **비-final** 클래스에 메서드가 늘었다 → 하위 클래스와 충돌할 수 있으므로 진짜 MAJOR.
# 이 케이스가 없으면 「메서드 추가는 전부 면제」로 퇴화해도 위 assert_ok 들이 그대로 통과한다.
assert_fails node "$GUARD" --report "$FIX/report-open-add.txt" --base "$FIX/base" --new "$FIX/open-add"
out=$(node "$GUARD" --report "$FIX/report-open-add.txt" --base "$FIX/base" --new "$FIX/open-add" 2>&1 || true)
assert_contains "$out" "final 이 아니다" "비-final 클래스는 면제 사유를 명시하며 거부"

# 생성자 기본값이 **실제로** 바뀌었다 → 면제되지 않는다.
assert_fails node "$GUARD" --report "$FIX/report-v097-diff.txt" --base "$FIX/base" --new "$FIX/v097-diff"
out=$(node "$GUARD" --report "$FIX/report-v097-diff.txt" --base "$FIX/base" --new "$FIX/v097-diff" 2>&1 || true)
assert_contains "$out" "실제로 다르다" "진짜 기본값 변경은 거부"

# 메서드 제거는 어떤 술어에도 해당하지 않는다 → 거부.
assert_fails node "$GUARD" --report "$FIX/report-removed.txt" --base "$FIX/base" --new "$FIX/removed"
out=$(node "$GUARD" --report "$FIX/report-removed.txt" --base "$FIX/base" --new "$FIX/removed" 2>&1 || true)
assert_contains "$out" "V006" "메서드 제거는 그대로 파괴적 변경"

# ── 공허성 하한 ──────────────────────────────────────────────────────────────
# 판정 줄이 없다 = 비교가 일어나지 않았다. 「변경 없음」으로 읽으면 안 된다.
assert_fails node "$GUARD" --report "$FIX/report-noverdict.txt" --base "$FIX/base" --new "$FIX/base"
out=$(node "$GUARD" --report "$FIX/report-noverdict.txt" --base "$FIX/base" --new "$FIX/base" 2>&1 || true)
assert_contains "$out" "비교가 일어나지 않았다" "판정 줄 부재는 측정 실패로 보고"

# 판정은 MAJOR 인데 표를 하나도 파싱하지 못했다 = 파서가 어긋났다. 통과시키면 게이트가 죽는다.
assert_fails node "$GUARD" --report "$FIX/report-parserdrift.txt" --base "$FIX/base" --new "$FIX/base"
out=$(node "$GUARD" --report "$FIX/report-parserdrift.txt" --base "$FIX/base" --new "$FIX/base" 2>&1 || true)
assert_contains "$out" "parser-drift" "표 파싱 실패는 통과가 아니라 실패"

# 비교 대상이 비었다 = 「전부 동일」로 조용히 통과하는 자리.
assert_fails node "$GUARD" --report "$FIX/report-none.txt" --base "$FIX/empty" --new "$FIX/base"
assert_fails node "$GUARD" --report "$FIX/report-none.txt" --base "$FIX/base" --new "$FIX/empty"

# 인자 누락·없는 경로는 실패한다.
assert_fails node "$GUARD" --report "$FIX/report-none.txt" --base "$FIX/base"
assert_fails node "$GUARD" --report "$FIX/does-not-exist.txt" --base "$FIX/base" --new "$FIX/base"

assert_report
