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

assert_report
