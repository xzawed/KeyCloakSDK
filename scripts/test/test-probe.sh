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
# ⚠️ **끝 개행이 없는 새 파일** — 미리보기의 마지막 줄이 안 닫혀 판정이 그 줄 뒤에 붙었다
# (`+plantedCAUGHT — …`). 종료코드는 맞지만 `^CAUGHT` 로 읽는 쪽은 판정이 없다고 본다(실측 2026-09-26,
# Grok 레그의 퍼저 193 사례 중 둘).
assert_eq "0 CAUGHT —" "$(verdict_site "planted" "printf 'planted' > new.txt" sh -c '! test -f new.txt')" \
  "끝 개행 없는 새 파일도 판정 줄이 줄 머리에 온다"
# ⚠️ **이름에 공백이 든 새 파일** — 목록을 단어로 쪼개 본문을 못 읽고, 선언한 자리가 없다며 INVALID 로 갔다.
assert_eq "0 CAUGHT —" "$(verdict_site "planted" "printf 'planted\n' > 'new file.txt'" sh -c '! test -f "new file.txt"')" \
  "이름에 공백이 든 새 파일의 자리도 읽는다"
assert_eq "1 SILENT —" "$(_newfile_silent)" \
  "새 파일만 만드는 변이의 SILENT(1) 은 판정 줄을 찍는다 — 줄 없는 1 은 러너가 죽은 것이다"

# 인자를 안 주면 아예 돌지 않는다(생략을 기본값으로 두면 아무도 안 쓴다).
_noarg() { set +e; ( cd "$SANDBOX" && sh scripts/probe.sh "sed -i s/hello/bye/ f.txt" true ) >/dev/null 2>&1; _c=$?; set -e; echo "$_c"; }
assert_eq "2" "$(_noarg)" "--site/--no-site 를 안 주면 거부한다"

# ── 빌드·적재 실패는 CAUGHT 가 아니다 ───────────────────────────────────────
# ⚠️ 컴파일 안 되는 변이는 INVALID 다(함정 (i)) — 검사 명령이 비영으로 끝났다고 단언이 변이를 잡은 것이
# 아니다. 실측(2026-10-05): go 변이가 컴파일되지 않아 `FAIL … [build failed]` 로 끝났는데 CAUGHT 이 났다.
# ⚠️ **먹이는 줄은 지어내지 않는다 — 그 도구가 실제로 낸 줄이다**(2026-10-09, 이 저장소의 SDK 를 일부러
# 깨서 받았다 · 경로만 지웠다). 지어낸 줄로 고른 초안의 표식 둘은 실제 출력에 한 번도 안 맞았다:
# pytest 수집 오류의 머리는 `____ ERROR collecting … ____` 이고 PHPUnit 12 는 `ParseError:` 를 찍는다.
# ⚠️ 기준선은 통과해야 한다 — 변이 전(hello)에는 grep 이 성공하고 변이 뒤에만 그 줄을 찍는다. 변이 전부터
# 실패하면 「기준선이 이미 실패한다」로 INVALID 가 돼 이 표식을 시험한 것이 아니게 된다.
# 줄은 변수로 넘긴다 — `$( … )` 안에 괄호·따옴표가 섞인 리터럴을 두면 셸마다 파싱이 갈린다(CI 는 dash).
line_code() { code_of "sed -i s/hello/bye/ f.txt" sh -c 'grep -q hello f.txt || { printf "%s\n" "$1"; exit 1; }' sh "$1"; }
_tab="$(printf '\t')"

# 양성 — 컴파일·적재 실패. 도구마다 실제 출력의 한 줄.
_l="FAIL${_tab}github.com/xzawed/KeyCloakSDK/go [build failed]"
assert_eq "2" "$(line_code "$_l")" "go test 빌드 실패(미사용 변수·vet·미정의 이름 셋 다 이 줄로 끝났다) — INVALID(2)"
_l="FAIL${_tab}github.com/xzawed/KeyCloakSDK/go [setup failed]"
assert_eq "2" "$(line_code "$_l")" "go test 셋업 실패(없는 패키지 import) — INVALID(2)"
_l='[ERROR] COMPILATION ERROR : '
assert_eq "2" "$(line_code "$_l")" "maven 컴파일 실패 — INVALID(2)"
_l="e: file:///kotlin/src/main/kotlin/io/github/xzawed/keycloak/ZzProbe.kt:3:31 Unresolved reference 'undefinedProbe'."
assert_eq "2" "$(line_code "$_l")" "kotlin 컴파일러 진단 — INVALID(2)"
_l="Execution failed for task ':compileKotlin' (registered by plugin 'org.jetbrains.kotlin.jvm')."
assert_eq "2" "$(line_code "$_l")" "gradle 9 의 compileKotlin 실패(꼬리에 플러그인 이름이 붙는다) — INVALID(2)"
_l="src/config.ts(146,30): error TS2304: Cannot find name 'undefinedProbe'."
assert_eq "2" "$(line_code "$_l")" "tsc 진단 — INVALID(2)"
_l='Error: Transform failed with 1 error:'
assert_eq "2" "$(line_code "$_l")" "vitest 5 변환 실패(구문 오류) — INVALID(2)"
_l='error[E0425]: cannot find value `undefined_probe` in this scope'
assert_eq "2" "$(line_code "$_l")" "rustc 진단 — INVALID(2)"
_l='error: could not compile `keycloak-sdk` (lib) due to 1 previous error'
assert_eq "2" "$(line_code "$_l")" "cargo 컴파일 실패 — INVALID(2)"
_l="src/Xzawed.Keycloak.Sdk/ZzProbe.cs(2,60): error CS0103: The name 'undefinedProbe' does not exist in the current context [src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj]"
assert_eq "2" "$(line_code "$_l")" "dotnet 컴파일러 진단 — INVALID(2)"
_l='E   SyntaxError: invalid syntax'
assert_eq "2" "$(line_code "$_l")" "pytest 수집 오류 본문의 SyntaxError — INVALID(2)"
_l='!!!!!!!!!!!!!!!!!!! Interrupted: 33 errors during collection !!!!!!!!!!!!!!!!!!!'
assert_eq "2" "$(line_code "$_l")" "pytest 수집 중단(NameError·ImportError 는 이 줄로만 갈린다) — INVALID(2)"
_l="ParseError: Unclosed '(' on line 146"
assert_eq "2" "$(line_code "$_l")" "PHPUnit 12 의 ParseError — INVALID(2)"
_l='An error occurred while loading ./spec/unit/admin_spec.rb.'
assert_eq "2" "$(line_code "$_l")" "rspec 적재 실패(NameError) — INVALID(2)"
_l='0 examples, 0 failures, 24 errors occurred outside of examples'
assert_eq "2" "$(line_code "$_l")" "rspec 예제 밖 오류(SyntaxError 는 이 요약으로만 갈린다) — INVALID(2)"
# 섞인 출력 — 한 패키지는 단언 실패, 다른 패키지는 빌드 실패. 보수적으로 INVALID 다(문서화한 동작을 고정한다).
_l="$(printf 'FAIL\tgithub.com/xzawed/KeyCloakSDK/go/a\t0.412s\nFAIL\tgithub.com/xzawed/KeyCloakSDK/go/b [build failed]')"
assert_eq "2" "$(line_code "$_l")" "단언 실패와 빌드 실패가 섞이면 INVALID(2) — 변이를 격리해 다시 잰다"

# 음성 대조군 — 실제 단언 실패의 줄은 그대로 CAUGHT. 같은 도구들이 상수 변이에 실제로 낸 줄이다.
_l="FAIL${_tab}github.com/xzawed/KeyCloakSDK/go${_tab}10.716s"
assert_eq "0" "$(line_code "$_l")" "go test 단언 실패 요약 — CAUGHT(0)"
_l='--- FAIL: TestAdminTokenRefreshOverCapSendsNoAdminRequest (0.01s)'
assert_eq "0" "$(line_code "$_l")" "go test 단언 실패 줄 — CAUGHT(0)"
_l='FAILED tests/unit/test_token_response_cap.py::test_reads_never_ask_for_more_than_one_byte_past_the_cap'
assert_eq "0" "$(line_code "$_l")" "pytest 단언 실패 — CAUGHT(0)"
_l='266 examples, 22 failures'
assert_eq "0" "$(line_code "$_l")" "rspec 단언 실패 요약 — CAUGHT(0)"
_l='Tests: 366, Assertions: 4021, Failures: 5.'
assert_eq "0" "$(line_code "$_l")" "PHPUnit 단언 실패 요약 — CAUGHT(0)"
# 앵커 대조군 — 표식 단어가 줄 **중간**에 있다. 부분문자열로 보면 INVALID 로 오진한다.
_l='FAIL expected SyntaxError: text in docs'
assert_eq "0" "$(line_code "$_l")" "줄 중간의 SyntaxError 는 표식이 아니다 — CAUGHT(0)"
_l='FAIL note: [build failed] appears mid-line'
assert_eq "0" "$(line_code "$_l")" "줄 중간의 [build failed] 는 표식이 아니다(줄 끝 앵커) — CAUGHT(0)"
assert_report
