#!/usr/bin/env sh
# `measure-lang-universe-fp.sh` 자가테스트 — 오탐 측정기가 **실제로 불일치를 보는지** 고정한다.
#
# 왜 필요한가: 이 측정기의 출력("불일치 0")이 `test-security-defaults.sh` 의 언어 집합 축을
# required 체크 안에 들일 근거다. 측정기가 **무엇을 넣어도 0 을 내는 물건**이면 그 근거가
# 통째로 거짓이 된다 — 「측정 실패」와 「측정 결과」는 같은 종료코드로 도착한다.
#
# 그래서 셋을 고정한다: (a) 알려진 **양성**(불일치를 심은 픽스처)에서 불일치를 낸다 ·
# (b) 알려진 **음성**(손 목록이 트리와 같은 픽스처)에서 0 을 낸다 · (c) 대조한 커밋이 0 건이면
# **공허로 실패**한다(0 을 통과로 내지 않는다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SCRIPT="$DIR/../measure-lang-universe-fp.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 픽스처 저장소 — 최상위에 빌드 매니페스트를 가진 디렉터리 둘(= 파생 언어 둘).
FIX="$TMP/repo"
mkdir -p "$FIX/alpha" "$FIX/beta" "$FIX/scripts/test"
cd "$FIX"
git init -q -b main . && git config user.email t@t && git config user.name t
printf '[package]\n' > alpha/Cargo.toml
printf '{}\n' > beta/package.json
# 측정기는 이 파일에서 SD_MANIFEST 와 SD_LANGS 를 읽는다.
cat > scripts/test/guard.sh <<'GUARD'
SD_MANIFEST='pom\.xml|pyproject\.toml|package\.json|go\.mod|composer\.json|Cargo\.toml|build\.gradle\.kts|[^/]+\.gemspec|[^/]+\.sln'
SD_LANGS='alpha beta'
GUARD
git add -A && git commit -qm "손 목록이 트리와 같다"

# (b) 알려진 음성 — 일치하는 커밋에서 불일치 0.
OUT="$(MLU_ROOT="$FIX" MLU_GUARD='scripts/test/guard.sh' sh "$SCRIPT" 2>&1)" && rc=0 || rc=$?
assert_eq "0" "$rc" "일치하는 이력에서 측정기가 실패하면 안 된다"
assert_contains "$OUT" "불일치(=오탐) 0" "일치하는 이력에서는 0 이 나와야 한다"
assert_contains "$OUT" "SD_LANGS 존재 1" "대조한 커밋 수를 보고해야 한다(공허 판별의 근거)"

# (a) 알려진 양성 — 트리에 세 번째 언어가 들어왔는데 손 목록이 안 따라온 커밋을 심는다.
mkdir -p "$FIX/gamma" && printf '{}\n' > "$FIX/gamma/composer.json"
git add -A && git commit -qm "세 번째 언어가 들어왔는데 SD_LANGS 는 그대로"
OUT="$(MLU_ROOT="$FIX" MLU_GUARD='scripts/test/guard.sh' sh "$SCRIPT" 2>&1)" && rc=0 || rc=$?
assert_eq "1" "$rc" "불일치가 있으면 측정기가 실패해야 한다"
assert_contains "$OUT" "MISMATCH" "어느 커밋이 어긋났는지 지목해야 한다"
assert_contains "$OUT" "gamma" "파생 쪽에 새 언어가 보여야 한다"

# ⚠️ (c) 공허 방어 — `SD_LANGS` 를 담은 커밋이 하나도 없으면 "불일치 0" 이 통과처럼 보인다.
EMPTY="$TMP/empty"
mkdir -p "$EMPTY/scripts/test" && cd "$EMPTY"
git init -q -b main . && git config user.email t@t && git config user.name t
# ⚠️ SD_MANIFEST 는 **있어야** 한다 — 없으면 추출 실패 경로가 먼저 터져 공허 경로를 못 잰다.
cat > scripts/test/guard.sh <<'INNER'
SD_MANIFEST='Cargo\.toml'
INNER
git add -A && git commit -qm "손 목록이 없는 이력"
OUT="$(MLU_ROOT="$EMPTY" MLU_GUARD='scripts/test/guard.sh' sh "$SCRIPT" 2>&1)" && rc=0 || rc=$?
assert_eq "1" "$rc" "대조한 커밋이 0 건이면 공허로 실패해야 한다(0 을 통과로 내면 안 된다)"
assert_contains "$OUT" "공허" "공허가 이유로 나와야 한다"

assert_report
