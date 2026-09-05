#!/usr/bin/env sh
# 자가테스트 자체의 위생을 검사한다 — "테스트가 있다"가 "테스트가 돈다"를 뜻하지 않는 두 경로를 막는다.
#
# 이 파일이 생긴 이유: 아래 두 규칙이 끝난 계획서의 미체크 체크박스 안에만
# 산문으로 적혀 있었다. 실제로 이 저장소는 같은 부류의 비용을 이미 치렀다
# (커밋 `24d60bb` — "자동화를 켜는 절차가 계획 문서의 미체크 항목으로만 있었다").
# 산문을 가드로 옮긴다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
HYGIENE="$DIR/../../.github/workflows/repo-hygiene.yml"

# ---- 규칙 1: 모든 test-*.sh는 `assert_report`를 **마지막 실행 명령으로** 호출해야 한다 ----
# `assert.sh`의 어서션들은 `_A_FAIL`만 누적하고 종료코드를 바꾸지 않는다. 종료코드를 내는 것은
# `assert_report`의 마지막 줄(`[ "$_A_FAIL" -eq 0 ]`)뿐이다. 빠뜨린 테스트는 **전부 실패해도
# exit 0**으로 끝나 CI를 초록으로 만든다 — 가장 나쁜 실패 모드다(없는 것보다 나쁘다).
#
# ⚠️ **`grep -q 'assert_report'` 로는 부족하다 — 그것은 「등장」이지 「호출」이 아니다.**
# 실측(2026-09-05): 그 검사는 아래 넷을 **전부 통과**시켰다.
#     # assert_report              (주석)
#     assert_report || true        (실패 삼킴)
#     echo "assert_report"         (문자열)
#     if grep -q "assert_report"   (자기 인용)
# 그리고 실제 코퍼스에서 `test-check-versions.sh`·`test-publication-claims.sh` 둘은 본문에
# `assert_report` 를 주석으로도 인용하고 있어, **진짜 호출을 지워도 규칙 1이 초록**이었다.
#
# ⚠️ **그래서 「마지막 실행 명령」까지 본다.** 호출이 있어도 그 뒤에 다른 명령이 오면 그 명령의
# 종료코드가 스크립트의 종료코드가 되어 실패가 다시 삼켜진다(독립 검증 레그가 가장 현실적인
# 잔여 구멍으로 지목했고, 이 저장소의 불변식은 이미 `.claude/rules/ci.md`·`assert.sh` 에서
# **"as its last line"** 이라 선언돼 있다 — 가드가 그 선언에 못 미치고 있었다).
# 실측: 새 판정으로 26개 파일 **전부 통과**(오탐 0), 위 넷은 전부 거부.
#
# ⚠️ **자기 자신을 제외하지 않는다.** 예전에는 `continue` 로 건너뛰었고, 그 결과 이 파일의
# `assert_report` 를 주석 처리하면 **종료코드 0 · 출력 한 줄 없이** 끝났다(실측). 저장소 어디에도
# 그것을 잡는 것이 없었다 — 집행자가 자기 계약만 면제받는 자리였다.
sh_last_cmd() { # $1=파일 → 주석을 걷어낸 마지막 비어있지 않은 줄(양끝 공백 제거)
  sed 's/#.*//' "$1" | grep -vE '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
# ⚠️ **`grep -c` 는 0건일 때 exit 1 이고, `set -e` 아래의 명령치환 대입은 그대로 스크립트를
# 죽인다** — 실측(2026-09-05): 이 가드가 위반 파일을 만나면 **진단 한 줄 없이 exit 1** 로 끝났다.
# 그건 지금 고치려는 결함과 같은 부류(초록/빨강만 있고 이유가 없다)라, `|| true` 로 상태를 끊고
# 세는 것과 판정하는 것을 분리한다.
sd_calls() { sed 's/#.*//' "$1" | grep -cE '^[[:space:]]*assert_report[[:space:]]*$' || true; }
for f in "$DIR"/test-*.sh; do
  b="$(basename "$f")"
  # 호출형(주석·문자열·`|| true` 가 아닌 단독 호출)이 하나라도 있는가.
  _calls="$(sd_calls "$f")"
  if [ "$_calls" -ge 1 ]; then
    _A_PASS=$((_A_PASS + 1))
  else
    _A_FAIL=$((_A_FAIL + 1))
    printf 'FAIL %s: assert_report 호출이 없다(주석·문자열·`|| true` 는 호출이 아니다) — 어서션이 전부 실패해도 exit 0이 된다\n' "$b" >&2
  fi
  # 그리고 그것이 마지막 실행 명령인가 — 뒤에 명령이 오면 그 종료코드가 스크립트의 종료코드다.
  if [ "$(sh_last_cmd "$f")" = "assert_report" ]; then
    _A_PASS=$((_A_PASS + 1))
  else
    _A_FAIL=$((_A_FAIL + 1))
    printf 'FAIL %s: assert_report 가 마지막 실행 명령이 아니다(마지막=[%s]) — 뒤 명령의 종료코드가 실패를 삼킨다\n' \
      "$b" "$(sh_last_cmd "$f")" >&2
  fi
done

# ---- 규칙 2: 모든 test-*.sh는 CI에 배선돼 있어야 한다 ----
# 파일이 존재하는 것과 실행되는 것은 다르다. `repo-hygiene.yml`이 그 파일들을 돌리는 유일한
# 워크플로이고, 이 저장소는 자가테스트가 **어떤 워크플로에도 배선되지 않은 채** 오래 방치된
# 이력을 `repo-hygiene.yml` 주석에 기록하고 있다.
# ⚠️ **언급이 아니라 실행을 세야 한다.** 첫 구현은 `grep -q "$b"`였는데, 이 워크플로는 주석에서
# `test-deploy-md.sh`를 사례로 인용하고 있어 **배선을 지워도 통과했다**(변이검증으로 발현).
# 주석을 걷어내고 `sh scripts/test/<name>` 형태의 실제 호출만 본다.
# ⚠️ **인터프리터까지 봐야 한다.** 첫 구현은 `grep -q "sh scripts/test/$b"`였는데 그 문자열은
# `bash scripts/test/$b`의 **부분문자열**이라 둘을 구분하지 못했다. 그래서 두 방향이 다 새어나갔다 —
# bash 전용 문법(`declare -A` 등)을 쓰는 테스트가 `sh`로 불려 CI에서 문법 에러로 죽는 쪽,
# 그리고 `sh` 셰방 테스트가 `bash`로 불려 **dash 발산을 숨기는** 쪽(우분투의 /bin/sh는 dash다).
# 셰방이 요구하는 인터프리터로 정확히 불리는지 단어 경계로 본다.
if [ -f "$HYGIENE" ]; then
  RUNLINES="$(sed 's/#.*//' "$HYGIENE")"
  for f in "$DIR"/test-*.sh; do
    b="$(basename "$f")"
    # ⚠️ `case … in *bash)` 는 **플래그가 붙은 셰방을 놓친다**(실측: `#!/bin/bash -eu` 와
    # `#!/usr/bin/env -S bash -eu` 가 둘 다 sh 로 분류됐다) — 그러면 bash 전용 테스트가 sh 로
    # 불려도 통과해 이 규칙의 존재 이유가 사라진다. 인터프리터 이름을 단어로 뽑는다.
    sb="$(head -1 "$f")"
    case "$sb" in
      '#!'*) : ;;
      *) _A_FAIL=$((_A_FAIL + 1))
         printf 'FAIL %s: 셰방이 없다 — 인터프리터를 판정할 수 없다\n' "$b" >&2
         continue ;;
    esac
    if printf '%s' "$sb" | grep -qE '[/ ]bash([[:space:]]|$)'; then want=bash; else want=sh; fi
    # 파일명이 정규식으로 해석되지 않게 메타문자를 이스케이프한다(`test-a.b.sh` 의 `.` 가 임의문자가 되면 안 된다).
    b_re="$(printf '%s' "$b" | sed 's/[].[^$*\\]/\\&/g')"
    if printf '%s' "$RUNLINES" | grep -qE "(^|[^[:alnum:]_])$want scripts/test/$b_re([[:space:]]|$)"; then
      _A_PASS=$((_A_PASS + 1))
    else
      _A_FAIL=$((_A_FAIL + 1))
      printf 'FAIL %s: repo-hygiene.yml에서 `%s`로 실행되지 않음 — 존재하지만 돌지 않거나, 셰방과 다른 인터프리터로 돈다\n' "$b" "$want" >&2
    fi
  done
else
  _A_FAIL=$((_A_FAIL + 1))
  printf 'FAIL repo-hygiene.yml을 찾지 못함(%s) — 배선 검사 불가\n' "$HYGIENE" >&2
fi

# ---- 규칙 3: harness의 회귀 테스트(*.test.mjs)도 CI에 배선돼야 한다 ----
# I1(2026-08-12 최종 리뷰): install-matrix.test.mjs·score.test.mjs·verdict.test.mjs 세 파일이
# 하네스의 헤드라인 회귀 테스트인데 `grep -rn "install-matrix.test\|score.test\|verdict.test"
# .github/ scripts/`가 아무것도 못 찾을 만큼 어떤 워크플로에도 배선돼 있지 않았다. 규칙 2는
# `scripts/test/test-*.sh`만 훑어 harness/ 아래는 애초에 스코프 밖이라 이 누락을 못 잡았다.
# git으로 추적된 harness/**/*.test.mjs 전부가 repo-hygiene.yml에서 `node <path>` 형태로
# 실제 실행되는지 본다(규칙 2와 동형 — 언급이 아니라 실행을 센다).
#
# ⚠️ **규칙 2와 같은 엄격도로 본다 — 예전에는 `grep -q "node $m"` 이었고 둘이 샜다**(실측):
#   (a) 경로가 정규식으로 해석돼 `.` 가 임의문자였다 → `install-matrixXtest.mjs` 가
#       `install-matrix.test.mjs` 검색에 걸린다(다른 파일이 배선을 위장한다).
#   (b) 단어경계가 없어 `node <path>.disabled` 도 배선으로 계수됐다(비활성화가 안 보인다).
#
# ⚠️ **판정을 함수로 뽑은 것은 취향이 아니라 대조군 때문이다.** 처음에는 정규식을 대조군에
# 그대로 **베껴 적었는데**, 그러면 본체를 옛 `grep -q` 로 되돌려도 대조군은 사본을 검사하느라
# 초록이었다(변이검증 실측: 129 passed 0 failed — 변이가 살아남았다). 대조군이 본체와 같은
# 함수를 불러야 그 변이가 죽는다.
mjs_wired() { # $1=주석 걷어낸 워크플로 본문 $2=경로 → 배선돼 있으면 0
  _mw_re="$(printf '%s' "$2" | sed 's/[].[^$*\\]/\\&/g')"
  printf '%s' "$1" | grep -qE "(^|[^[:alnum:]_])node $_mw_re([[:space:]]|$)"
}
ROOT="$(cd "$DIR/../.." && pwd)"
MJS_TESTS="$(cd "$ROOT" && git ls-files -- 'harness/**/*.test.mjs')"
if [ -z "$MJS_TESTS" ]; then
  _A_FAIL=$((_A_FAIL + 1))
  printf 'FAIL harness/**/*.test.mjs 를 하나도 못 찾음 — 스윕이 깨졌거나 파일이 옮겨졌다\n' >&2
elif [ -f "$HYGIENE" ]; then
  RUNLINES_MJS="$(sed 's/#.*//' "$HYGIENE")"
  for m in $MJS_TESTS; do
    if mjs_wired "$RUNLINES_MJS" "$m"; then
      _A_PASS=$((_A_PASS + 1))
    else
      _A_FAIL=$((_A_FAIL + 1))
      printf 'FAIL %s: repo-hygiene.yml에서 `node %s`로 실행되지 않는다 — 존재하지만 돌지 않는다\n' "$m" "$m" >&2
    fi
  done
else
  _A_FAIL=$((_A_FAIL + 1))
  printf 'FAIL repo-hygiene.yml을 찾지 못함(%s) — harness .test.mjs 배선 검사 불가\n' "$HYGIENE" >&2
fi

# ---- 규칙 4: 추적되는 모든 *.sh 는 인덱스에 실행비트(100755)가 있어야 한다 ----
# 2026-08-14: 이 규칙이 CI에만 있고 로컬에는 없어서, 이번 브랜치의 repo-hygiene가 **11번 연속
# 빨간 채로** 작업이 계속됐다. 로컬 자가테스트는 전건 초록이었다 — `sh <file>` 로 직접 부르면
# 실행비트가 없어도 돌기 때문이다. 원인은 환경이다: Windows 체크아웃은 파일시스템 실행비트를
# 갖지 않아 새로 만든 `.sh` 가 `100644` 로 인덱스에 들어간다(이번에 4개가 그랬다).
# `shell-exec-bits` 는 `main` 룰셋 PRIMARY 의 required 체크 **둘 중 하나**라, 이 상태로는
# 브랜치가 아예 머지되지 않는다. 규칙 1~3과 같은 부류다 — **파일은 있는데 돌지 않는다.**
# 고치는 법: `git update-index --chmod=+x <file>`
NONEXEC="$(cd "$ROOT" && git ls-files -s -- '*.sh' | awk '$1 == "100644" { print $4 }')"
if [ -z "$NONEXEC" ]; then
  _A_PASS=$((_A_PASS + 1))
else
  for f in $NONEXEC; do
    _A_FAIL=$((_A_FAIL + 1))
    printf 'FAIL %s: 인덱스 모드가 100644 — 실행비트 없음(git update-index --chmod=+x)\n' "$f" >&2
  done
fi
# 스윕이 깨져 0개를 훑고 통과하는 공허를 막는다(규칙 3의 빈 목록 검사와 동형).
SH_ALL="$(cd "$ROOT" && git ls-files -- '*.sh' | wc -l)"
if [ "$SH_ALL" -gt 0 ]; then
  _A_PASS=$((_A_PASS + 1))
else
  _A_FAIL=$((_A_FAIL + 1))
  printf 'FAIL 추적되는 *.sh 를 하나도 못 찾음 — 스윕이 깨졌다\n' >&2
fi

# ---- 대조군: 이 가드가 실제로 잡는가 ----
# ⚠️ 없으면 "전부 통과"가 검사가 도는 증거인지 grep이 항상 참인지 구분할 수 없다.
# 임시 파일로 두 위반을 실제로 만들어 규칙이 반응하는지 본다.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '#!/usr/bin/env sh' 'assert_eq 1 2 "boom"' > "$TMP/test-noreport.sh"
assert_fails grep -q 'assert_report' "$TMP/test-noreport.sh"
printf '%s\n' '#!/usr/bin/env sh' 'assert_report' > "$TMP/test-hasreport.sh"
assert_ok grep -q 'assert_report' "$TMP/test-hasreport.sh"

# ⚠️ **여기부터가 규칙 1의 「등장 ≠ 호출」 대조군이다.** 위 두 줄은 옛 `grep -q` 판정만 재현하고,
# 그 판정이 통과시키던 네 형태를 새 판정이 실제로 거부하는지는 증명하지 않는다. 넷을 각각 만든다.
# 판정 함수(`sd_calls`·`sh_last_cmd`)는 규칙 1 이 쓰는 **그 함수 그대로** 부른다 — 대조군이
# 사본을 검사하면 본체가 썩어도 초록이다.

printf '%s\n' '#!/usr/bin/env sh' '# assert_report' > "$TMP/test-c1.sh"
assert_eq "0" "$(sd_calls "$TMP/test-c1.sh")" '주석 처리된 assert_report 는 호출이 아니다'
assert_ok grep -q 'assert_report' "$TMP/test-c1.sh"   # 옛 판정은 통과시켰다(이 대비가 요점)

printf '%s\n' '#!/usr/bin/env sh' 'assert_report || true' > "$TMP/test-c2.sh"
assert_eq "0" "$(sd_calls "$TMP/test-c2.sh")" '`assert_report || true` 는 실패를 삼키므로 호출로 세지 않는다'

printf '%s\n' '#!/usr/bin/env sh' 'echo "assert_report"' > "$TMP/test-c3.sh"
assert_eq "0" "$(sd_calls "$TMP/test-c3.sh")" '문자열 안의 assert_report 는 호출이 아니다'

printf '%s\n' '#!/usr/bin/env sh' 'if grep -q "assert_report" x; then :; fi' > "$TMP/test-c4.sh"
assert_eq "0" "$(sd_calls "$TMP/test-c4.sh")" '자기 인용(grep 인자)은 호출이 아니다'

printf '%s\n' '#!/usr/bin/env sh' '  assert_report  ' > "$TMP/test-c5.sh"
assert_eq "1" "$(sd_calls "$TMP/test-c5.sh")" '들여쓰기된 단독 호출은 호출로 센다(오탐 방지)'

# ⚠️ 「마지막 실행 명령」 축의 대조군 — 호출이 있어도 뒤에 명령이 오면 실패가 삼켜진다.
printf '%s\n' '#!/usr/bin/env sh' 'assert_report' 'echo done' > "$TMP/test-c6.sh"
assert_eq "1" "$(sd_calls "$TMP/test-c6.sh")" '호출 자체는 있다'
assert_eq "echo done" "$(sh_last_cmd "$TMP/test-c6.sh")" '그러나 마지막 실행 명령은 assert_report 가 아니다'
printf '%s\n' '#!/usr/bin/env sh' 'assert_report' '' '# 끝' > "$TMP/test-c7.sh"
assert_eq "assert_report" "$(sh_last_cmd "$TMP/test-c7.sh")" '뒤따르는 빈 줄·주석은 명령이 아니다(오탐 방지)'

# ⚠️ 규칙 3의 두 누수 대조군 — **본체가 쓰는 `mjs_wired` 를 그대로 부른다.** 정규식을 여기
# 베껴 적으면 본체를 옛 `grep -q` 로 되돌려도 이 대조군은 초록이다(실측으로 겪었다).
_m3='harness/report/score.test.mjs'
assert_fails mjs_wired 'node harness/report/scoreXtest.mjs' "$_m3"        # (a) `.` 가 임의문자면 통과했다
assert_fails mjs_wired 'node harness/report/score.test.mjs.disabled' "$_m3" # (b) 단어경계가 없으면 통과했다
assert_ok    mjs_wired 'node harness/report/score.test.mjs' "$_m3"          # 정상 배선은 통과해야 한다(오탐 방지)

# 이 파일 자신도 규칙 1·2를 지켜야 한다(아래 assert_report 호출이 규칙 1을 만족시킨다).
assert_ok grep -q 'sh scripts/test/test-selftest-hygiene.sh' "$HYGIENE"
# ⚠️ 대조군 — 주석에만 등장하는 이름이 배선으로 오인되지 않는지. 이 어서션이 없었다면
# 첫 구현의 결함(주석 매치)이 그대로 남았을 것이다.
assert_fails sh -c 'printf "%s" "$(sed "s/#.*//" "$1")" | grep -q "sh scripts/test/test-does-not-exist.sh"' _ "$HYGIENE"

# ⚠️ 대조군 — 인터프리터 구분이 실제로 되는가. `bash X`가 `sh X` 검색에 걸리던 것이 원래 결함이다.
# 이것들이 없으면 위 루프의 정규식·셰방 판정이 느슨해져도 "전부 통과"로 보인다.
assert_ok   sh -c 'printf "%s" "bash scripts/test/t.sh" | grep -qE "(^|[^[:alnum:]_])bash scripts/test/t\.sh"'
assert_fails sh -c 'printf "%s" "bash scripts/test/t.sh" | grep -qE "(^|[^[:alnum:]_])sh scripts/test/t\.sh"'
assert_ok   sh -c 'printf "%s" "  run: sh scripts/test/t.sh" | grep -qE "(^|[^[:alnum:]_])sh scripts/test/t\.sh"'
# bash 셰방을 가진 유일한 테스트가 실제로 bash로 배선돼 있다(위 루프가 보는 그 짝).
assert_ok grep -q 'bash scripts/test/test-install-verify.sh' "$HYGIENE"
# ⚠️ 셰방 판정이 **플래그·env -S**까지 보는가. 이 넷이 위 루프가 쓰는 그 정규식이다 —
# 느슨해지면 bash 전용 테스트가 sh 로 불려도 초록이 된다(Grok 반증에서 발현).
for _sb in '#!/usr/bin/env bash' '#!/bin/bash' '#!/bin/bash -eu' '#!/usr/bin/env -S bash -eu'; do
  assert_ok sh -c 'printf "%s" "$1" | grep -qE "[/ ]bash([[:space:]]|$)"' _ "$_sb"
done
assert_fails sh -c 'printf "%s" "#!/usr/bin/env sh" | grep -qE "[/ ]bash([[:space:]]|$)"'
# 접두 일치로 인접 파일명을 주워오지 않는가(`test-doctor.sh` 검색이 `test-doctor.sh.disabled`에 걸리면 안 된다).
assert_fails sh -c 'printf "%s" "  run: sh scripts/test/t.sh.disabled" | grep -qE "(^|[^[:alnum:]_])sh scripts/test/t\.sh([[:space:]]|$)"'

# ---- 대조군: 규칙 3(harness *.test.mjs 배선)이 실제로 잡는가 ----
# I1을 고치며 넣은 규칙 3이 공허하지 않음을 규칙 1·2와 같은 방식으로 보인다: 실제로 배선된
# 파일 하나는 잡히고, 주석에만 등장하는 가짜 경로는 안 잡혀야 한다.
assert_ok grep -q 'node harness/install/report/install-matrix.test.mjs' "$HYGIENE"
assert_fails sh -c 'printf "%s" "$(sed "s/#.*//" "$1")" | grep -q "node harness/does/not/exist.test.mjs"' _ "$HYGIENE"

# ---- 규칙 5: 가드 스크립트는 **자기가 바뀐 PR 에서 돈다** ----
#
# 규칙 1~3 은 「파일은 있는데 돌지 않는다」를 겨눈다. 이 규칙은 그 한 칸 옆이다 —
# **돌긴 도는데 자기를 고친 PR 에서는 안 돈다.** `paths:` 필터는 잡을 스킵하는 것이 아니라
# 체크를 **만들지 않으므로**(#368), 언어 레인에만 배선된 가드는 그 가드를 부수는 PR 에서
# 아무 신호도 내지 않는다. 실측(2026-09-02): 저장소의 열세 개 `scripts/*.{mjs,sh}` 중
# `check-node-public-surface.mjs` 한 자리가 그랬다(node-ci 의 `paths:` 밖에 있었다).
#
# 판정 기준을 「모든 PR 에서 도는 워크플로가 그 파일을 행사하는가」로 잡는다 —
# ⚠️ `pull_request` 로 도는 워크플로 중 `paths:` 가 없는 것은 **둘**이다(`repo-hygiene.yml` ·
# `sonarcloud.yml`). 이 규칙이 repo-hygiene 하나만 보는 것은 그것이 **유일해서가 아니라**
# 가드를 행사하는 쪽이기 때문이다(sonarcloud 는 커버리지만 올린다). 예전 주석은 「유일하게」라
# 적었고 그것은 거짓이다 — 24개 중 13개에 `paths:` 가 없고, 나머지 11개는 push/tag·schedule·
# `workflow_call` 이다(YAML 파서로 실측. 줄단위 정규식은 인라인 플로우 맵을 놓친다).
# 직접 부르거나(`node scripts/check-x.mjs`), 그것이 돌리는 자가테스트가 부르면 충족이다.
if [ -f "$HYGIENE" ]; then
  # ⚠️ 전제부터 검사한다 — repo-hygiene 에 `paths:` 가 붙는 순간 이 규칙 전체가 조용히 약해진다.
  if grep -qE '^[[:space:]]*paths:' "$HYGIENE"; then
    _A_FAIL=$((_A_FAIL + 1))
    printf 'FAIL repo-hygiene.yml 에 paths: 필터가 생겼다 — 규칙 5 의 전제가 깨졌다(모든 PR 에서 돌지 않는다)\n' >&2
  else
    _A_PASS=$((_A_PASS + 1))
  fi
  HY_RUN="$(sed 's/#.*//' "$HYGIENE")"
  GUARDS="$(cd "$ROOT" && git ls-files -- 'scripts/' | grep -E '^scripts/[^/]+\.(mjs|sh)$' || true)"
  # 스윕 공허성 — 목록이 비면 아래 루프가 0건을 돌고 통과한다(규칙 3·4 와 동형).
  G_N="$(printf '%s\n' "$GUARDS" | grep -c . || true)"
  if [ "$G_N" -ge 13 ]; then
    _A_PASS=$((_A_PASS + 1))
  else
    _A_FAIL=$((_A_FAIL + 1))
    printf 'FAIL scripts/ 최상위 가드 스크립트를 %s개만 찾았다(하한 13) — 스윕이 깨졌다\n' "$G_N" >&2
  fi
  # 간접 경로용 본문 — repo-hygiene 이 **실제로 돌리는** 자가테스트들의 주석 제거된 본문.
  # ⚠️ **언급이 아니라 호출을 세야 한다** — 규칙 2 가 같은 실수를 이미 한 번 했다. 첫 구현은
  # 주석까지 훑었고, 그래서 **이 파일 자신의 주석**이 `check-node-public-surface.mjs` 를
  # 인용하고 있어 배선을 통째로 지운 변이가 통과했다(변이검증에서 발현). 주석을 걷어내고
  # 경로 형태(`.../<파일>`)로만 인정한다.
  # ⚠️ 가드마다 다시 훑지 않고 **한 번만** 모은다 — 13×23 스폰은 이 PC 에서 1분이 넘었다.
  WIRED_BODY=""
  for t in "$DIR"/test-*.sh; do
    tb="$(basename "$t")"
    printf '%s' "$HY_RUN" | grep -qF "scripts/test/$tb" || continue
    WIRED_BODY="$WIRED_BODY
$(sed 's/#.*//' "$t")"
  done
  for g in $GUARDS; do
    gb="$(basename "$g")"
    if printf '%s' "$HY_RUN" | grep -qF "$gb"; then
      _A_PASS=$((_A_PASS + 1))
      continue
    fi
    _hit=0
    printf '%s' "$WIRED_BODY" | grep -qF "/$gb" && _hit=1
    if [ "$_hit" -eq 1 ]; then
      _A_PASS=$((_A_PASS + 1))
    else
      _A_FAIL=$((_A_FAIL + 1))
      printf 'FAIL %s: 모든 PR 에서 도는 워크플로가 이 가드를 행사하지 않는다 — 이 파일을 고치는 PR 에서 체크가 생성조차 되지 않는다\n' "$g" >&2
    fi
  done
else
  _A_FAIL=$((_A_FAIL + 1))
  printf 'FAIL repo-hygiene.yml을 찾지 못함(%s) — 규칙 5 검사 불가\n' "$HYGIENE" >&2
fi

# ---- 규칙 6: 가드 워크플로의 어떤 스텝도 실패를 삼켜서는 안 된다 ----
# 규칙 2 는 자가테스트가 **호출되는지**만 본다 — 호출된 채로 실패가 무시되면 그대로 통과한다.
# 실측(A/B): `test-check-coverage.sh` 스텝에 `continue-on-error: true` 한 줄을 붙였더니
# 규칙 1~5 도, `check-ci-permissions.mjs` 도 전부 초록이었다. 배선을 지우지 않고 **무력화**하는
# 경로가 열려 있었던 것이다.
#
# 저장소 전체 실측: `continue-on-error` 는 24개 워크플로에 **0건**이다. 그래서 예외 목록 없이
# 금지할 수 있다 — 예외 목록은 반드시 썩는다는 것이 이 저장소의 판단이다.
#
# ⚠️ `|| true` 는 **일부러 대상에서 뺐다.** 기각 체크리스트 5 에 걸린다 — 참/거짓이 문맥에
# 달렸고 정규식이 수렴하지 않는다. 실제로 이 파일 안에 정당한 용례가 있다:
# `xargs grep -lnE '...' || true` 는 「매치 없음(exit 1)」을 정상으로 만드는 관용이지 가드를
# 끄는 것이 아니다. 되살릴 조건: 가드 호출 자체를 `|| true` 로 감싼 것이 실측될 때.
if [ -f "$HYGIENE" ]; then
  COE="$(grep -n 'continue-on-error' "$HYGIENE" || true)"
  if [ -n "$COE" ]; then
    _A_FAIL=$((_A_FAIL + 1))
    printf 'FAIL repo-hygiene.yml 에 continue-on-error 가 있다 — 가드의 실패를 삼킨다:\n%s\n' "$COE" >&2
  else
    _A_PASS=$((_A_PASS + 1))
  fi
fi

# ---- 규칙 7: 문서가 말하는 CI 사실이 트리와 같은가 ----
# 2026-09-05 실측: `.claude/rules/ci.md` 의 CI 서술 셋이 트리와 어긋나 있었다. 둘은 **개수**가
# 틀렸고(핀 종류 3 vs 4), 하나는 **행동을 잘못 유도**했다("SonarCloud 커버리지는 kover 단독이니
# 비-Kotlin PR 실패는 예상된 잡음") — 그 문장을 믿고 required 가 아닌 빨강을 두 번 흘려보냈다.
#
# ⚠️ **여기서 검사하는 것은 「종류 분류」가 아니라 「이름·집합」이다.** 종류는 사람의 분류라
# 기계가 수렴시킬 수 없다(독립 검증 레그가 `# kind:` 태그 방식을 스스로 철회했다 — 손으로 다는
# 태그는 두 번째 진실 원천이라, 태그가 틀리면 가드는 초록인데 문서는 틀린 채 남는다).
# 그래서 셋 중 둘만 기계로 잡고, 「네 종류」의 **분류 정확성은 리뷰의 몫으로 남긴다**.

# (7a) SonarCloud 커버리지 공급자 — 「단독」 주장이 리포트 경로 수와 모순되지 않는가.
SONARP="$ROOT/sonar-project.properties"
CIRULES="$ROOT/.claude/rules/ci.md"
if [ -f "$SONARP" ] && [ -f "$CIRULES" ]; then
  _cov_paths="$(grep -cE '^sonar\.[a-z]+\.(coverage|lcov)\.[a-zA-Z]*[Rr]eportPaths=' "$SONARP" || true)"
  assert_ok test "$_cov_paths" -ge 2   # 스윕 공허 방지: 경로가 0~1이면 이 규칙 자체가 무의미하다
  # 공급자가 둘 이상인데 문서가 "kover alone" 류의 단독 주장을 하면 거짓이다.
  _sole=1
  grep -qiE 'kover alone|fed by [A-Za-z]+ (kover )?alone|coverage is [A-Za-z]+ only' "$CIRULES" && _sole=0
  assert_eq "1" "$_sole" \
    "ci.md 가 커버리지 공급자를 '단독'이라 주장한다 — sonar-project.properties 의 리포트 경로는 $_cov_paths 개다"
else
  _A_FAIL=$((_A_FAIL + 1))
  printf 'FAIL sonar-project.properties 또는 .claude/rules/ci.md 를 찾지 못함 — 7a 검사 불가\n' >&2
fi

# (7b) `pull_request` 로 도는데 `paths:` 가 없는 워크플로 집합이 문서가 적은 그대로인가.
# ⚠️ **YAML 파서로 센다.** 줄단위 정규식은 이 저장소의 인라인 플로우 맵
# (`push: { branches: [main], paths: [...] }`)을 놓친다 — 실측으로 ci.yml 을 오분류했다.
# 같은 부류가 등록부에 이미 있다(`ci-perms-flow-style-permissions-bypass`).
# ⚠️ **의존성 없이 판정한다.** 첫 구현은 `node/node_modules/yaml` 을 썼는데, `doc-facts` 잡은
# `npm ci` 를 돌지 않아 CI 에서 **required 체크가 환경 이유로 빨개졌다**(실측). 가드가 자기 레인에서
# 못 도는 것은 이 저장소가 규칙 5 로 막는 부류다. 그래서 `on:` 의 `pull_request` 트리거 범위만
# 손으로 훑되, **블록 표기와 인라인 플로우 맵을 둘 다** 본다.
_prnp="$(cd "$ROOT" && node -e '
  const fs=require("fs"), path=require("path");
  const d=".github/workflows";
  const out=[];
  for (const f of fs.readdirSync(d).filter(x=>/\.ya?ml$/.test(x)).sort()) {
    const lines=fs.readFileSync(path.join(d,f),"utf8").split(/\r?\n/)
      .map(l=>l.replace(/(^|\s)#.*$/,""));           // 주석 제거(따옴표 안 # 은 드물다)
    let i=lines.findIndex(l=>/^\s{0,2}pull_request(_target)?\s*:/.test(l));
    if (i<0) continue;
    const head=lines[i];
    const indent=head.match(/^(\s*)/)[1].length;
    let scope=head;                                   // 인라인 플로우 맵이면 이 줄에 다 있다
    if (!/\{/.test(head)) {                           // 블록 표기면 더 들여쓴 줄을 모은다
      for (let j=i+1;j<lines.length;j++){
        const l=lines[j];
        if (!l.trim()) continue;
        if (l.match(/^(\s*)/)[1].length<=indent) break;
        scope+="\n"+l;
      }
    }
    if (!/(^|\s|\{|,)paths(-ignore)?\s*:/.test(scope)) out.push(f);
  }
  console.log(out.join(" "));
' 2>/dev/null || true)"
# 스윕 공허 방지 — 목록이 비면 파서가 깨진 것이지 「전부 paths 가 있다」가 아니다.
assert_ok test -n "$_prnp"
assert_eq "repo-hygiene.yml sonarcloud.yml" "$_prnp" \
  "pull_request 로 돌면서 paths: 가 없는 워크플로 집합이 바뀌었다 — ci.md·CONTRIBUTING.md 의 서술을 함께 고쳐라"
# 문서 둘이 「유일한」이라 말하지 않는가(집합이 둘인데 하나라고 적으면 거짓이다).
_only=1
grep -q 'the only workflow with no `paths:` filter' "$CIRULES" && _only=0
assert_eq "1" "$_only" "ci.md 가 여전히 'the only workflow with no paths: filter' 라 적는다 — 집합은 둘이다"

# ---- 규칙 8: 버전 매트릭스가 있으면 `fail-fast: false` 가 있어야 한다 ----
# 왜: 기본값 `fail-fast: true` 에서는 한 레그가 깨지면 **나머지가 취소된다**. 이 리포의 매트릭스는
# 「같은 테스트의 반복」이 아니라 레그마다 다른 계약이고, 그중 하나는 **매니페스트가 선언한
# 소비자 하한**이다(java 17 · dotnet net8.0 · go 1.25 · node 22 · php 8.3 · python 3.10 ·
# ruby 3.2 · rust 1.88 — 여덟 전부 실측 일치). 최신 레그가 먼저 깨지면 하한 레그가 취소되고,
# 그 빨강은 「최신이 깨졌다」로 읽혀 하한과 무관해 보인다.
# ⚠️ **하한 레그가 유일한 검증이다** — `check-docs.mjs` 의 하한 대조(`kind=runtime` 앵커)는
# 「문서가 하한을 옳게 적었는가」만 본다. 코드가 그 하한에서 **실제로 도는지**는 이 레그뿐이다.
# ⚠️ 머지 규칙은 안 바뀐다 — required 는 `doc-facts`·`shell-exec-bits` 둘뿐이라 언어 CI 는
# 애초에 머지를 막지 않는다(`.github/rulesets/main.json`). 이 규칙이 사는 것은 **진단**이다.
# ⚠️ 인라인 플로우 맵(`matrix: { java: [...] }`)이 절반이 넘으므로 줄단위 정규식으로 세지 않는다.
_mx="$(node -e '
  const fs = require("fs")
  const d = ".github/workflows"
  const hasMatrix = (L) =>
    L.some((l) => { const s = l.replace(/#.*$/, ""); return /(^|\s)matrix:\s*\{/.test(s) || /^\s*matrix:\s*$/.test(s) })
  const out = []
  for (const f of fs.readdirSync(d).filter((x) => x.endsWith(".yml"))) {
    const L = fs.readFileSync(d + "/" + f, "utf8").split(/\r?\n/)
    if (hasMatrix(L) && !L.some((l) => /^\s*fail-fast\s*:/.test(l.replace(/#.*$/, "")))) out.push(f)
  }
  console.log(out.join(" "))
' 2>/dev/null || true)"
# 공허 방지 — 매트릭스를 가진 워크플로가 8개 미만으로 잡히면 파서가 깨진 것이지 「전부 있다」가 아니다.
_mxall="$(node -e '
  const fs = require("fs")
  const d = ".github/workflows"
  let n = 0
  for (const f of fs.readdirSync(d).filter((x) => x.endsWith(".yml"))) {
    const L = fs.readFileSync(d + "/" + f, "utf8").split(/\r?\n/)
    if (L.some((l) => { const s = l.replace(/#.*$/, ""); return /(^|\s)matrix:\s*\{/.test(s) || /^\s*matrix:\s*$/.test(s) })) n++
  }
  console.log(n)
' 2>/dev/null || echo 0)"
assert_ok test "$_mxall" -ge 8
assert_eq "" "$_mx" "매트릭스가 있는데 fail-fast: false 가 없는 워크플로가 생겼다 — 최신 레그가 깨지면 소비자 하한 레그가 취소되고 그날 하한 검증이 사라진다"

assert_report
