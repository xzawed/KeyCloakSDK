#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/doc-guard"
GUARD="$DIR/../check-docs.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 정상 픽스처는 통과해야 한다.
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# 변이 1: 문서의 값을 훼손하면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
sed -i 's/| 1\.2\.3 |/| 9.9.9 |/' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# 변이 2: 표를 지우면 min 미달로 실패해야 한다(침묵 금지).
cp -r "$FIX/." "$TMP/"
sed -i '/org.example/d' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# 변이 3: 소스를 비우면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
: > "$TMP/src/build.gradle.kts"
assert_fails node "$GUARD" "$TMP"

# ---- Defect 1: 앵커는 바로 뒤 표만 소유한다 ----
# 앵커 바로 다음 줄이 산문이고, 그 뒤에 (min을 충족하는) 디코이 표가 오고,
# 그보다 더 뒤에 실제로 드리프트된 진짜 표가 있는 문서. 구버전은 산문·디코이
# 표를 건너뛰어 디코이를 "앵커의 표"로 오인해 통과(0종료)하고 진짜 드리프트
# (Beta 9.9.9)는 검사하지 않는다 — 고친 버전은 앵커 직후가 표가 아니므로
# "앵커 뒤에 표가 없다"로 즉시 잡아야 한다(침묵 통과 금지).
cp -r "$FIX/." "$TMP/"
cat > "$TMP/ok.md" <<'EOF'
# fixture

<!-- doc-guard: kind=dep source=src/build.gradle.kts min=2 -->
앵커 바로 다음 줄에 산문이 온다 — 표가 아니다.

| 무관한 항목 | 좌표 | 버전 |
|---|---|---|
| Alpha decoy | `org.example:alpha` | 1.2.3 |
| Beta decoy | `org.example:beta` | 4.5.6 |

| 이름 | 좌표 | 버전 |
|---|---|---|
| Alpha | `org.example:alpha` | 1.2.3 |
| Beta | `org.example:beta` | 9.9.9 |
EOF
assert_fails node "$GUARD" "$TMP"

# ---- Defect 2: min= 은 1 이상의 정수만 허용한다 ----
# min=0: 표를 완전히 비워도(추출 0건) "0 < 0"은 거짓이라 통과해선 안 된다
# ("추출이 0건으로 떨어짐" 탐지기를 min=0이 무력화하는 정확한 시나리오).
cp -r "$FIX/." "$TMP/"
sed -i 's/min=2/min=0/' "$TMP/ok.md"
sed -i '/org.example/d' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# min=oops: 표가 멀쩡해도 숫자가 아닌 min 값 자체를 거부해야 한다
# ("checked < NaN"은 항상 거짓이라 구버전은 침묵 통과한다).
cp -r "$FIX/." "$TMP/"
sed -i 's/min=2/min=oops/' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# ---- Defect 3~5: 확장된 픽스처(pom 리액터·package-lock.json·펜스 앵커)가
# 전부 통과해야 한다. 구버전은 pom-reactor.md(단일파일 파싱이라 좌표를 못 찾음)와
# fenced.md(펜스 안 앵커를 진짜로 오인해 존재하지 않는 소스 추출 실패)에서
# 거짓 FAIL을 낸다. ----
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# Defect 3 드리프트 확인: 리액터 해석이 비교 자체를 무력화하지 않는다
# (부모 pom의 property + 자식 pom의 dependency를 정확히 병합해도, 문서 값이
# 실제와 다르면 여전히 잡혀야 한다).
cp -r "$FIX/." "$TMP/"
sed -i 's/| 2\.0\.0 |/| 9.9.9 |/' "$TMP/pom-reactor.md"
assert_fails node "$GUARD" "$TMP"

# Defect 4 드리프트 확인: package-lock.json에서 뽑은 해석된 버전도 실제로 대조된다.
cp -r "$FIX/." "$TMP/"
sed -i 's/| 3\.2\.1 |/| 9.9.9 |/' "$TMP/npm-lock.md"
assert_fails node "$GUARD" "$TMP"

assert_report
