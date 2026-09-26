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
  # ⚠️ 기존 케이스는 **자리 선언을 쓰지 않는다** — 이 자가테스트가 겨누는 것은 세 결과를
  # 가르는 능력이지 자리 검사가 아니다. 자리 검사는 아래 전용 케이스가 따로 본다.
  ( cd "$SANDBOX" && sh scripts/probe.sh --no-site "$@" ) >/dev/null 2>&1
  _c=$?
  set -e
  echo "$_c"
}

# (a) 잡는다 — 변이가 적용되고 검사가 그것을 본다.
assert_eq "0" "$(code_of "sed -i s/hello/bye/ f.txt" grep -q hello f.txt)" \
  "적용된 변이를 검사가 잡으면 CAUGHT(0)"

# (b) 구멍 — 변이가 적용됐는데 검사가 통과한다.
# ⚠️ **검사 명령은 그 파일을 실제로 읽는 것이라야 한다.** 예전 이 케이스는 `true` 였는데,
# `true` 는 아무것도 안 읽으므로 「가드가 침묵했다」가 아니라 **아무 일도 없었다**이다 —
# 2026-09-15 에 러너가 그 구분을 갖추면서 이 케이스는 INVALID 로 넘어갔다(아래 (b2)).
# `test -f` 는 파일을 **보되 내용을 안 보는** 가드라, 겨누던 「보는데 못 본다」를 그대로 나타낸다.
assert_eq "1" "$(code_of "sed -i s/hello/bye/ f.txt" test -f f.txt)" \
  "적용된 변이를 검사가 놓치면 SILENT(1)"

# (b2) ⚠️ **검사가 바뀐 파일을 읽지 않으면 SILENT 가 아니라 INVALID.** 실측 2026-09-15:
#      `DEPLOY_LANGS` 를 비우는 변이를 그 변수를 **아예 안 쓰는** 자가테스트로 검사해 SILENT 를
#      얻었다. 자리 검사는 통과했다(변이가 선언한 줄을 쳤으므로) — 착지·의미에 이어 **세 번째**
#      사각이었다. 읽지 않는 것을 바꾼 뒤의 통과를 구멍으로 쓰면 **없는 결함**을 보고하게 된다.
assert_eq "2" "$(code_of "sed -i s/hello/bye/ f.txt" true)" \
  "검사가 바뀐 파일을 읽지 않으면 INVALID(2) — SILENT 로 읽으면 없는 구멍이 된다"

# (b3) 면제는 **명시적으로만** — `--no-site` 와 같은 관용이다(런타임 조립 경로용).
_relwaive() {
  set +e
  ( cd "$SANDBOX" && sh scripts/probe.sh --no-site --assume-relevant "sed -i s/hello/bye/ f.txt" true ) >/dev/null 2>&1
  _c=$?
  set -e
  echo "$_c"
}
assert_eq "1" "$(_relwaive)" "--assume-relevant 를 주면 관련성 검사를 면제하고 SILENT(1) 로 판정한다"

# (c) ⚠️ **이 러너의 존재 이유** — 변이가 트리를 바꾸지 않았으면 SILENT 가 아니라 INVALID.
#     실측 두 건이 이 자리였다: `sed` 개행 이스케이프가 깨져 변이가 안 붙었는데
#     「가드가 침묵했다」로 읽었고, `node -e` 의 `\s` 가 두 번 먹혀 9건을 거짓 MISS 로 냈다.
assert_eq "2" "$(code_of "true" true)" \
  "변이가 트리를 안 바꿨으면 INVALID(2) — SILENT 로 읽으면 거짓 구멍이 된다"

# (c2) ⚠️ **줄끝만 바뀐 것은 변경이 아니다.** `core.autocrlf=true` 인 체크아웃에서 워킹트리 파일은
# CRLF 인데 MSYS `sed -i` 는 **매치가 하나도 없어도** 파일을 다시 쓰며 CR 을 떨어뜨린다. 그러면
# `git status --porcelain` 은 ` M f.txt` 를 내고 `git diff` 는 **빈다** — 실측 2026-09-07 에 그
# 어긋남으로 게이트 삭제 프로브 셋이 전부 거짓 `SILENT`(진짜 구멍) 을 냈다. 이 러너가 막으려고
# 만들어진 바로 그 부류라, 내용이 같으면 INVALID 여야 한다.
#
# ⚠️ 이 조건은 **CRLF 로 체크아웃된 파일**에서만 생긴다 — 위 샌드박스의 `f.txt` 는 만든 그대로
# LF 라 재현되지 않는다. 그래서 여기서만 `autocrlf` 를 켜고 다시 받아 CRLF 로 만든다.
(
  cd "$SANDBOX"
  git config core.autocrlf true
  rm -f f.txt
  git checkout -q -- f.txt
) >/dev/null 2>&1
assert_eq "2" "$(code_of "sed -i s/zzz/yyy/ f.txt" true)" \
  "줄끝만 바뀐 변이는 INVALID(2) — status 는 M 을 내지만 내용은 같다. SILENT 로 읽으면 거짓 구멍이 된다"
( cd "$SANDBOX" && git config --unset core.autocrlf && rm -f f.txt && git checkout -q -- f.txt ) >/dev/null 2>&1

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


# ── 선언한 자리 검사 ────────────────────────────────────────────────────────
# ⚠️ **이 러너가 못 잡던 마지막 부류다**: 변이가 **착지했는데 다른 것이 됐고**, 엉뚱한 단언에
# 걸려 `CAUGHT` 으로 기록된 사고 둘(2026-09-12). 「diff 를 눈으로 본다」는 첫 단계에 대한
# 희망이지 두 번째 단계가 아니었다.
code_site() {
  # ⚠️ 위치인자를 고정하지 말 것 — 검사 명령의 인자 수는 호출마다 다르다.
  # 고정했다가 `f.txt` 가 잘려 `grep` 이 **stdin 을 기다리며 멈췄다**(실측).
  _site="$1"; _mut="$2"; shift 2
  set +e
  ( cd "$SANDBOX" && sh scripts/probe.sh --site "$_site" "$_mut" "$@" ) >/dev/null 2>&1 </dev/null
  _c=$?
  set -e
  echo "$_c"
}

# 선언한 자리를 실제로 친 변이 → 정상 판정(CAUGHT).
assert_eq "0" "$(code_site "bye" "sed -i s/hello/bye/ f.txt" grep -q hello f.txt)" \
  "선언한 자리를 담은 변이는 그대로 판정된다"

# ⚠️ 대조군 — 변이는 **착지했지만** 선언한 자리를 안 담았다 → INVALID(2).
# 이것이 없으면 `--site` 는 「아무 값이나 받는 장식」이 된다.
assert_eq "2" "$(code_site "NOT-IN-THE-DIFF" "sed -i s/hello/bye/ f.txt" grep -q hello f.txt)" \
  "착지했어도 선언한 자리를 안 담으면 INVALID — 그 CAUGHT 은 다른 변이에 대한 답이다"

# ⚠️ 대조군 — 선언 패턴이 **문맥 줄**에만 있으면 통과하면 안 된다(실측: 첫 구현이 그랬다).
# f.txt 는 'hello' 를 담고, 변이는 그것을 'bye' 로 바꾼다. 'world' 는 바뀌지 않는 줄에만 있다.
printf 'hello\nworld\n' > "$SANDBOX/f2.txt"
( cd "$SANDBOX" && git add f2.txt && git -c user.email=t@t -c user.name=t commit -qm f2 ) >/dev/null 2>&1
assert_eq "2" "$(code_site "world" "sed -i s/hello/bye/ f2.txt" grep -q hello f2.txt)" \
  "문맥 줄에만 있는 패턴은 「쳤다」가 아니다 — 추가/삭제 줄만 본다"

# ⚠️ **새 파일만 만드는 변이도 판정까지 가야 한다.** 실측 2026-09-26: 변이가 추적 파일을 안 건드리면
# `git diff` 가 비고, 자리 검사의 `grep` 파이프가 1 을 내 `set -e` 가 러너를 **아무것도 안 찍고
# 종료코드 1** 로 죽였다 — 1 은 SILENT(진짜 구멍)의 코드다. 그래서 코드만이 아니라 **판정 줄**을 본다.
verdict_site() {
  _site="$1"; _mut="$2"; shift 2
  set +e
  _o="$( cd "$SANDBOX" && sh scripts/probe.sh --site "$_site" "$_mut" "$@" 2>&1 </dev/null )"
  _c=$?
  set -e
  printf '%s %s' "$_c" "$(printf '%s\n' "$_o" | grep -oE '^(CAUGHT|SILENT) —' | head -1)"
}
assert_eq "0 CAUGHT —" "$(verdict_site "planted" "printf 'planted\n' > new.txt" sh -c '! test -f new.txt')" \
  "새 파일만 만드는 변이를 검사가 잡으면 CAUGHT(0) 판정까지 간다"
_newfile_silent() {
  set +e
  _o="$( cd "$SANDBOX" && sh scripts/probe.sh --site planted --assume-relevant "printf 'planted\n' > new.txt" true 2>&1 </dev/null )"
  _c=$?
  set -e
  printf '%s %s' "$_c" "$(printf '%s\n' "$_o" | grep -oE '^(CAUGHT|SILENT) —' | head -1)"
}
assert_eq "1 SILENT —" "$(_newfile_silent)" \
  "새 파일만 만드는 변이의 SILENT(1) 은 판정 줄을 찍는다 — 줄 없는 1 은 러너가 죽은 것이다"

# 인자를 안 주면 아예 돌지 않는다(생략을 기본값으로 두면 아무도 안 쓴다).
_noarg() { set +e; ( cd "$SANDBOX" && sh scripts/probe.sh "sed -i s/hello/bye/ f.txt" true ) >/dev/null 2>&1; _c=$?; set -e; echo "$_c"; }
assert_eq "2" "$(_noarg)" "--site/--no-site 를 안 주면 거부한다"
assert_report
