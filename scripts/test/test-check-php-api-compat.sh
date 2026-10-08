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
out=$(node "$GUARD" --report "$FIX/report-v010-open.txt" --base "$FIX/v010-base" --new "$FIX/v010-open" 2>&1 || true)
assert_contains "$out" "하위 클래스의 오버라이드가 깨진다" "비-final 클래스의 V010 은 오버라이드가 깨진다는 사유로 거부"

# ── V016: final 클래스에 protected 메서드가 늘었다 ───────────────────────────
# V015 와 같은 술어다 — 하위 클래스가 있을 수 없다. protected 가 바깥에 닿는 나머지 길(같은 조상을
# 상속한 형제)은 조상이 선언한 메서드 = 재정의에만 열리고, 그 메서드는 재정의 이전에도 닿았다.
# 이 절의 픽스처 행은 전부 php-semver-checker 0.17.0 이 같은 트리 쌍에 실제로 낸 출력이다.
assert_ok node "$GUARD" --report "$FIX/report-final-add-protected.txt" --base "$FIX/base" --new "$FIX/final-add-protected"
out=$(node "$GUARD" --report "$FIX/report-final-add-protected.txt" --base "$FIX/base" --new "$FIX/final-add-protected" 2>&1 || true)
assert_contains "$out" "면제 1건" "final 클래스의 V016 은 면제된다"
assert_contains "$out" "final class Alpha — 상속 불가" "V016 면제 사유를 찍는다"

# 대조군: **비-final** 이면 하위 클래스가 같은 이름을 이미 가졌을 수 있다 → 진짜 MAJOR.
# ⚠️ 사유까지 본다 — 「면제 술어에 해당하지 않는다」로 떨어져도 종료코드는 같아서, 사유가 없으면
# V016 이 final 술어를 거쳤는지를 이 대조군이 증명하지 못한다.
assert_fails node "$GUARD" --report "$FIX/report-open-add-protected.txt" --base "$FIX/base" --new "$FIX/open-add-protected"
out=$(node "$GUARD" --report "$FIX/report-open-add-protected.txt" --base "$FIX/base" --new "$FIX/open-add-protected" 2>&1 || true)
assert_contains "$out" "final 이 아니다" "비-final 클래스의 V016 은 final 술어가 거부"

# ⚠️ 대조군: **매직 메서드**는 final 이어도 면제하지 않는다 — 이름 충돌이 아니라 엔진 연산을 바꾼다.
# protected __construct·__clone 은 바깥의 new·clone 을 막는다(도구는 V016 으로 낸다).
assert_fails node "$GUARD" --report "$FIX/report-final-add-protected-ctor.txt" --base "$FIX/base" --new "$FIX/final-add-protected-ctor"
out=$(node "$GUARD" --report "$FIX/report-final-add-protected-ctor.txt" --base "$FIX/base" --new "$FIX/final-add-protected-ctor" 2>&1 || true)
assert_contains "$out" "매직 메서드" "final 클래스의 protected __construct 추가(V016)는 거부"
assert_fails node "$GUARD" --report "$FIX/report-final-add-protected-clone.txt" --base "$FIX/base" --new "$FIX/final-add-protected-clone"
out=$(node "$GUARD" --report "$FIX/report-final-add-protected-clone.txt" --base "$FIX/base" --new "$FIX/final-add-protected-clone" 2>&1 || true)
assert_contains "$out" "매직 메서드" "final 클래스의 protected __clone 추가(V016)는 거부"

# V015 도 매직 메서드를 싣는다 — public __construct(int $x) 추가는 기존 `new Alpha()` 를 깨는데
# 도구는 그것을 V015 로 낸다. 이 대조군 전에는 (1) 이 그것을 MINOR 로 면제했다.
assert_fails node "$GUARD" --report "$FIX/report-final-add-public-ctor.txt" --base "$FIX/base" --new "$FIX/final-add-public-ctor"
out=$(node "$GUARD" --report "$FIX/report-final-add-public-ctor.txt" --base "$FIX/base" --new "$FIX/final-add-public-ctor" 2>&1 || true)
assert_contains "$out" "매직 메서드" "final 클래스의 public __construct 추가(V015)는 거부"

# ── 회귀: #723 이 실제로 받은 리포트 ─────────────────────────────────────────
# report-pkce-override.txt 는 run 37253446893 의 리포트 그대로다(로그 접두만 뗐다). final 인
# PkceKeycloakProvider 가 league AbstractProvider 의 getResponse(V015)·parseResponse(V016)를
# 재정의했고, V016 이 면제 밖이라 「파괴적 변경 1건」으로 막혔다. 소스 쌍은 그 클래스의 축약본이다.
assert_ok node "$GUARD" --report "$FIX/report-pkce-override.txt" --base "$FIX/pkce-base" --new "$FIX/pkce-override"
out=$(node "$GUARD" --report "$FIX/report-pkce-override.txt" --base "$FIX/pkce-base" --new "$FIX/pkce-override" 2>&1 || true)
assert_contains "$out" "표 26행 · MAJOR 2행" "실제 리포트의 26행·MAJOR 2행을 그대로 파싱"
assert_contains "$out" "면제 2건" "getResponse(V015)·parseResponse(V016) 둘 다 면제"
assert_contains "$out" "남은 MAJOR 0건" "실제 리포트가 게이트를 통과한다"
assert_report
