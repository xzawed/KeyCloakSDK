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

# 한 언어만 범프 — 언어 간 갈림은 **경고이지 실패가 아니다**.
# SECURITY.md가 소비자에게 명시적으로 약속한다: "각 언어는 독립적으로 버저닝하며, 보안 수정은
# 그 언어에서 준비되는 즉시 릴리스하고 나머지 여덟을 기다리지 않는다." 이 가드가 릴리스 경로
# (install-smoke.yml)에서 실패로 동작하면 그 약속을 지킬 수 없다 — python만 고친 보안 패치가
# 아홉 언어를 전부 올릴 때까지 나갈 수 없게 된다.
# 그리고 이 검사는 애초에 무엇도 지키지 못한다: `py-v0.2.0`을 밀면 python 자신의 태그↔매니페스트
# 가드가 이미 확인하므로 node의 상태는 무관하고, `node-v0.2.0`을 package.json이 0.1.0인 채로 밀면
# node 자신의 가드가 첫 스텝에서 잡는다. 반쯤 적용된 범프는 **해를 끼칠 수 있는 각 지점에서**
# 이미 잡힌다. 남는 역할은 "하나 빠뜨린 것 아닌가" 하는 조율용 알림뿐이다.
cp -r "$FIX/." "$TMP/"
sed -i 's/"version": "0.1.0"/"version": "0.2.0"/' "$TMP/node/package.json"
assert_ok node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "::warning::" "언어 간 갈림은 경고로 알린다"
assert_not_contains "$out" "::error::" "언어 간 갈림을 오류로 올리지 않는다"

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

# --list: 기계가독 모드 — harness/install/install-verify.sh가 무명시 실행에서 언어별 검증 버전을
# 파생할 때 소비한다. 계약은 `lang<TAB>version` 두 컬럼뿐이고 경고·요약이 섞이면 안 된다
# (소비자가 행 단위로 파싱한다). 위와 같은 프리릴리스 표기 픽스처를 그대로 재사용해 레지스트리
# 원표기(0.1.0rc1)가 가공 없이 그대로 나오는 것을 고정한다.
out=$(node "$GUARD" "$TMP" --list)
assert_contains "$out" "$(printf 'python\t0.1.0rc1')" "--list: python 원표기 그대로"
assert_contains "$out" "$(printf 'node\t0.1.0-rc.1')" "--list: node 원표기 그대로"
assert_not_contains "$out" "::warning::" "--list: 경고 미출력(기계가독 계약)"
assert_not_contains "$out" "버전 SSOT" "--list: 사람용 요약 미출력(기계가독 계약)"
# 추출 실패는 --list에서도 하드 실패다 — 소비자가 빈 목록을 "버전 없음"으로 오독하면 안 된다.
: > "$TMP/rust/Cargo.toml"
assert_fails node "$GUARD" "$TMP" --list

assert_report
