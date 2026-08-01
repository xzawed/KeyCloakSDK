#!/usr/bin/env sh
# 버전 SSOT 가드 자가테스트 — 가드가 **실제로 어긋남을 잡는지**, 그리고 **잡으면 안 되는 것을
# 잡지는 않는지**(오탐)를 둘 다 확인한다. 통과만 확인하는 자가테스트는 공허하다: 가드가 아무것도
# 검사하지 않아도 통과하기 때문이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/version-ssot"
GUARD="$DIR/../check-versions.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 정상 픽스처는 통과해야 한다.
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# 변이 1: Java POM 하나만 범프 — 범프가 반쯤 적용된 상태. 버전이 7개 파일에 있어 실제로 잘 일어난다.
cp -r "$FIX/." "$TMP/"
sed -i 's|<parent><version>0.1.0-SNAPSHOT</version></parent>|<parent><version>0.2.0-SNAPSHOT</version></parent>|' "$TMP/java/mod-a/pom.xml"
assert_fails node "$GUARD" "$TMP"

# 변이 2: 한 언어만 범프 — 언어 간 갈림. 릴리스 워크플로의 태그↔매니페스트 가드는 자기 언어만
# 보므로 이것을 잡지 못한다. 이 가드가 유일한 방어선이다.
cp -r "$FIX/." "$TMP/"
sed -i 's/"version": "0.1.0"/"version": "0.2.0"/' "$TMP/node/package.json"
assert_fails node "$GUARD" "$TMP"

# 변이 3: 매니페스트에서 버전 줄을 없애면 실패해야 한다 — 추출 실패를 통과로 처리하면 가드가
# 조용히 무력화된다(공허한 통과 방지).
cp -r "$FIX/." "$TMP/"
: > "$TMP/rust/Cargo.toml"
assert_fails node "$GUARD" "$TMP"

# 오탐 방지: 레지스트리마다 프리릴리스 표기가 다른 것은 **정상**이다(PEP 440 rc1 · SemVer -rc.1 ·
# RubyGems .rc1 · Maven -RC1). 표기 통일을 요구하면 각 레지스트리가 그 버전을 거부한다.
# 기저 버전(X.Y.Z)이 같으면 통과해야 한다.
cp -r "$FIX/." "$TMP/"
sed -i 's/version = "0.1.0"/version = "0.1.0rc1"/' "$TMP/python/pyproject.toml"
sed -i 's/"version": "0.1.0"/"version": "0.1.0-rc.1"/' "$TMP/node/package.json"
sed -i 's/VERSION = "0.1.0"/VERSION = "0.1.0.rc1"/' "$TMP/ruby/lib/keycloak_sdk/version.rb"
sed -i 's/version = "0.1.0"/version = "0.1.0-RC1"/' "$TMP/kotlin/build.gradle.kts"
assert_ok node "$GUARD" "$TMP"

assert_report
