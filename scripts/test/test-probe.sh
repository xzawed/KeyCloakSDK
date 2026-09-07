#!/usr/bin/env sh
# `scripts/probe.sh` 자가테스트 — 변이 프로브 러너가 **세 결과를 가르는지** 본다.
#
# 겨누는 것은 종료코드 셋의 구분이다. 이 러너가 존재하는 이유가 「구멍」과 「프로브
# 무효」를 같은 코드로 내지 않는 것이므로, 그 구분이 깨지면 러너는 있으나 마나다.
#   0 CAUGHT · 1 SILENT · 2 INVALID
#
# ⚠️ 실제 저장소가 아니라 **샌드박스 저장소**에서 잰다 — 이 테스트가 도는 시점의
# 본 트리 상태(깨끗한지 아닌지)에 결과가 좌우되면 그 자체가 계측기 오염이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
PROBE="$DIR/../probe.sh"

assert_ok test -f "$PROBE"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# 샌드박스: 커밋 하나짜리 저장소 + 그 안에 러너 사본.
mkdir -p "$SANDBOX/scripts"
cp "$PROBE" "$SANDBOX/scripts/probe.sh"
chmod +x "$SANDBOX/scripts/probe.sh"
(
  cd "$SANDBOX"
  git init -q
  git config user.email probe@test.local
  git config user.name probe
  echo hello > f.txt
  git add -A
  git commit -qm init
) >/dev/null 2>&1

# 종료코드를 그대로 돌려준다.
# ⚠️ `set -e` 를 반드시 꺼야 한다 — 켠 채로 두면 비영 종료에서 이 함수가 **죽어서**
#    코드를 찍지 못하고 빈 문자열이 나간다(실측: 1·2 를 기대한 네 케이스가 `actual: []`).
#    그러면 「INVALID 을 못 낸다」와 「함수가 죽었다」가 구분되지 않는다.
code_of() {
  set +e
  ( cd "$SANDBOX" && sh scripts/probe.sh "$@" ) >/dev/null 2>&1
  _c=$?
  set -e
  echo "$_c"
}

# (a) 잡는다 — 변이가 적용되고 검사가 그것을 본다.
assert_eq "0" "$(code_of "sed -i s/hello/bye/ f.txt" grep -q hello f.txt)" \
  "적용된 변이를 검사가 잡으면 CAUGHT(0)"

# (b) 구멍 — 변이가 적용됐는데 검사가 통과한다.
assert_eq "1" "$(code_of "sed -i s/hello/bye/ f.txt" true)" \
  "적용된 변이를 검사가 놓치면 SILENT(1)"

# (c) ⚠️ **이 러너의 존재 이유** — 변이가 트리를 바꾸지 않았으면 SILENT 가 아니라 INVALID.
#     실측 두 건이 이 자리였다: `sed` 개행 이스케이프가 깨져 변이가 안 붙었는데
#     「가드가 침묵했다」로 읽었고, `node -e` 의 `\s` 가 두 번 먹혀 9건을 거짓 MISS 로 냈다.
assert_eq "2" "$(code_of "true" true)" \
  "변이가 트리를 안 바꿨으면 INVALID(2) — SILENT 로 읽으면 거짓 구멍이 된다"

# (d) 기준선이 이미 빨갛다 — 그 상태에서 '잡았다'는 변이 때문인지 알 수 없다.
assert_eq "2" "$(code_of "sed -i s/hello/bye/ f.txt" grep -q nope f.txt)" \
  "기준선이 실패하면 INVALID(2)"

# (e) 미커밋 작업 위에서는 시작하지 않는다 — 복원 단계가 그것을 지운다.
echo dirty > "$SANDBOX/uncommitted.txt"
assert_eq "2" "$(code_of "sed -i s/hello/bye/ f.txt" grep -q hello f.txt)" \
  "더러운 트리에서는 INVALID(2)"
rm -f "$SANDBOX/uncommitted.txt"

# (f) 대조군 — 트리를 다시 깨끗하게 하면 (a)가 되돌아온다. 이게 없으면 (e)가
#     「러너가 늘 2를 낸다」와 구분되지 않는다.
assert_eq "0" "$(code_of "sed -i s/hello/bye/ f.txt" grep -q hello f.txt)" \
  "트리가 다시 깨끗하면 CAUGHT(0) 로 복귀한다"

# (g) 본 트리 불변 — 러너는 워크트리에서만 변이한다.
assert_eq "hello" "$(cat "$SANDBOX/f.txt")" "러너가 본 트리의 파일을 바꿨다"
assert_eq "" "$(cd "$SANDBOX" && git status --porcelain)" "러너가 본 트리를 더럽혔다"

assert_report
