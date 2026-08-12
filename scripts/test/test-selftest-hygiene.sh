#!/usr/bin/env sh
# 자가테스트 자체의 위생을 검사한다 — "테스트가 있다"가 "테스트가 돈다"를 뜻하지 않는 두 경로를 막는다.
#
# 이 파일이 생긴 이유: 아래 두 규칙이 `docs/superpowers/plans/`의 미체크 체크박스 안에만
# 산문으로 적혀 있었다. 그 계획서들은 941개의 미체크 항목을 갖고 있어 아무도 읽지 않고,
# 실제로 이 저장소는 같은 부류의 비용을 이미 치렀다(커밋 `24d60bb` — "자동화를 켜는 절차가
# 계획 문서의 미체크 항목으로만 있었다"). 산문을 가드로 옮긴다.
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
if [ -f "$HYGIENE" ]; then
  RUNLINES="$(sed 's/#.*//' "$HYGIENE")"
  for f in "$DIR"/test-*.sh; do
    b="$(basename "$f")"
    if printf '%s' "$RUNLINES" | grep -q "sh scripts/test/$b"; then
      _A_PASS=$((_A_PASS + 1))
    else
      _A_FAIL=$((_A_FAIL + 1))
      printf 'FAIL %s: repo-hygiene.yml에서 실행되지 않음 — 존재하지만 돌지 않는다\n' "$b" >&2
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

# ---- 대조군: 규칙 3(harness *.test.mjs 배선)이 실제로 잡는가 ----
# I1을 고치며 넣은 규칙 3이 공허하지 않음을 규칙 1·2와 같은 방식으로 보인다: 실제로 배선된
# 파일 하나는 잡히고, 주석에만 등장하는 가짜 경로는 안 잡혀야 한다.
assert_ok grep -q 'node harness/install/report/install-matrix.test.mjs' "$HYGIENE"
assert_fails sh -c 'printf "%s" "$(sed "s/#.*//" "$1")" | grep -q "node harness/does/not/exist.test.mjs"' _ "$HYGIENE"

assert_report
