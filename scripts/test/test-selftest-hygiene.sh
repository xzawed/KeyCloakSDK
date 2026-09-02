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

# ---- 규칙 1: 모든 test-*.sh는 `assert_report`를 호출해야 한다 ----
# `assert.sh`의 어서션들은 `_A_FAIL`만 누적하고 종료코드를 바꾸지 않는다. 종료코드를 내는 것은
# `assert_report`의 마지막 줄(`[ "$_A_FAIL" -eq 0 ]`)뿐이다. 빠뜨린 테스트는 **전부 실패해도
# exit 0**으로 끝나 CI를 초록으로 만든다 — 가장 나쁜 실패 모드다(없는 것보다 나쁘다).
for f in "$DIR"/test-*.sh; do
  b="$(basename "$f")"
  [ "$b" = "test-selftest-hygiene.sh" ] && continue   # 자기 자신은 아래에서 따로 본다
  if grep -q 'assert_report' "$f"; then
    _A_PASS=$((_A_PASS + 1))
  else
    _A_FAIL=$((_A_FAIL + 1))
    printf 'FAIL %s: assert_report 미호출 — 어서션이 전부 실패해도 exit 0이 된다\n' "$b" >&2
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
ROOT="$(cd "$DIR/../.." && pwd)"
MJS_TESTS="$(cd "$ROOT" && git ls-files -- 'harness/**/*.test.mjs')"
if [ -z "$MJS_TESTS" ]; then
  _A_FAIL=$((_A_FAIL + 1))
  printf 'FAIL harness/**/*.test.mjs 를 하나도 못 찾음 — 스윕이 깨졌거나 파일이 옮겨졌다\n' >&2
elif [ -f "$HYGIENE" ]; then
  RUNLINES_MJS="$(sed 's/#.*//' "$HYGIENE")"
  for m in $MJS_TESTS; do
    if printf '%s' "$RUNLINES_MJS" | grep -q "node $m"; then
      _A_PASS=$((_A_PASS + 1))
    else
      _A_FAIL=$((_A_FAIL + 1))
      printf 'FAIL %s: repo-hygiene.yml에서 실행되지 않음 — 존재하지만 돌지 않는다\n' "$m" >&2
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
# `repo-hygiene.yml` 이 유일하게 `paths:` 필터가 없는 워크플로이므로 대상은 그것 하나다.
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

assert_report
