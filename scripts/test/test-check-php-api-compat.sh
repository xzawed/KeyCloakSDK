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


# ── V010: final 클래스에 후행 선택적 파라미터가 늘었다 ───────────────────────
# 도구는 파라미터 추가를 선택/필수 무관하게 MAJOR 로 낸다. PHP 의 실제 계약은 다르다 —
# final 클래스에 **후행 선택적** 인자를 더하는 것은 기존 호출도 오버라이드도 깨지 않는다.
assert_ok node "$GUARD" --report "$FIX/report-v010-trailing.txt" --base "$FIX/v010-base" --new "$FIX/v010-trailing"

# ⚠️ 대조군 셋 — 술어의 네 연언이 각각 살아있는지. 하나라도 빠지면 이 면제는 진짜 파괴를 축복한다.
# (1) 추가된 파라미터가 **필수**면 기존 호출이 깨진다 → MAJOR.
assert_fails node "$GUARD" --report "$FIX/report-v010-required.txt" --base "$FIX/v010-base" --new "$FIX/v010-required"
out=$(node "$GUARD" --report "$FIX/report-v010-required.txt" --base "$FIX/v010-base" --new "$FIX/v010-required" 2>&1 || true)
assert_contains "$out" "기본값이 없다" "필수 파라미터 추가는 기본값 부재를 사유로 거부"

# (2) ⚠️ **중간 삽입** — 둘 다 기본값이고 final 이라 「final + 기본값」만 보면 통과한다. 그런데
# 기존 위치인자가 조용히 밀린다(하드 실패보다 나쁘다). 이 대조군이 이 PR 의 핵심 교정이다.
assert_fails node "$GUARD" --report "$FIX/report-v010-middle.txt" --base "$FIX/v010-base" --new "$FIX/v010-middle"
out=$(node "$GUARD" --report "$FIX/report-v010-middle.txt" --base "$FIX/v010-base" --new "$FIX/v010-middle" 2>&1 || true)
assert_contains "$out" "접두가 아니다" "중간 삽입은 접두 조건으로 거부(위치인자가 밀린다)"

# (3) 비-final 이면 하위 클래스의 오버라이드가 깨진다 → MAJOR.
assert_fails node "$GUARD" --report "$FIX/report-v010-open.txt" --base "$FIX/v010-base" --new "$FIX/v010-open"
out=$(node "$GUARD" --report "$FIX/report-v010-open.txt" --base "$FIX/v010-open" --new "$FIX/v010-open" 2>&1 || true)
assert_report
