#!/usr/bin/env sh
# check-sonar-index.mjs 의 자가테스트 — 네트워크 없이 판정 함수와 진입점을 태운다.
#
# 검사 대상은 「지금 색인 수가 몇인가」가 아니라 **이 계측기가 무너진 스캔을 초록으로 넘기지 않는가**다. #304 는
# 색인 487 → 159 로 소스 집합이 무너지고도 품질 게이트 PASSED 였다(docs/governance/rejected.md 「SonarCloud
# `sonar.tests` 설정」 · 등록부 sonar-tests-revive-instrument).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SCRIPT="$DIR/../check-sonar-index.mjs"

# 모듈 경로를 **인자로 넘기지 않는다** — 그 값이 process.argv[1] 이 되어 진입점 가드가 main() 을 돌린다
# (네트워크를 때린다). scripts/ 로 cd 한 뒤 cwd 상대 지정자로 import 한다. 출력이 비면 즉시 죽는다 — 모듈
# 로드에 실패해 양쪽이 빈 문자열이 되면 비교가 공허하게 통과한다.
call() { # <함수 본문(JS, 모듈을 m 으로)> [stdin] → 그 식의 값
  _o="$(cd "$DIR/.." && printf '%s' "${2:-}" | node -e '
    let s = ""
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      import("./check-sonar-index.mjs").then((m) => {
        process.stdout.write(String(new Function("m", "input", "return (" + process.argv[1] + ")")(m, s)))
      })
    })' "$1")"
  if [ -z "$_o" ]; then
    printf 'FATAL: check-sonar-index.mjs 호출이 빈 출력을 냈다 — 모듈 로드 실패로 테스트가 공허해진다\n' >&2
    exit 1
  fi
  printf '%s' "$_o"
}
count() { call 'String(m.indexedCount(input))' "$1"; }
decide() { # <current|null> <baseline|null> → "<code> <첫 줄>"
  call "(() => { const d = m.decide({ current: $1, baseline: $2, currentRun: '111', baselineRun: '222' }); return d.code + ' ' + d.lines[0] })()"
}

# ── 1. 로그에서 색인 수를 읽는다 — 실측 모양(2026-11-14, PR #1088 의 SonarCloud 잡) ─────────────
LINE='2026-11-14T13:36:39.8158071Z 13:36:39.814 INFO  810 files indexed (done) | time=384ms'
NOISE='2026-11-14T13:36:34.6381250Z 13:36:34.637 INFO  5 files ignored because of inclusion/exclusion patterns
2026-11-14T13:38:09.1804214Z 13:38:09.179 INFO  QUALITY GATE STATUS: PASSED'
assert_eq '810' "$(count "$NOISE
$LINE")" '실측 모양의 줄에서 810 을 읽는다(무시 줄 「5 files ignored」 는 세지 않는다)'
assert_eq '810' "$(count "$LINE
$LINE")" '같은 값이 두 번이면 그 값'
# 못 읽는 것은 null 이다 — 0 이나 첫 값으로 반올림하면 「모른다」가 숫자가 된다.
assert_eq 'null' "$(count "$NOISE")" '「files indexed」 줄이 없으면 null'
assert_eq 'null' "$(count "$LINE
INFO  159 files indexed")" '서로 다른 값이 둘이면 null — 어느 쪽이 이 스캔인지 모른다'
assert_eq 'null' "$(count 'INFO  1,810 files indexed')" '모르는 모양(천 단위 쉼표)은 810 으로 잘라 읽지 않는다'

# ── 2. #304 모양은 빨갛다 — 이 계측기가 있는 이유 ───────────────────────────────────
_r="$(decide 159 487)"
assert_eq '1' "${_r%% *}" '⚠️ 487 → 159(#304 실측)는 exit 1'
assert_contains "$_r" '-67.4% 줄었다' '줄어든 폭을 말한다'
assert_contains "$_r" '색인 487 (main 실행 222) → 159 (이 실행 111)' '두 수와 두 실행을 남긴다'
_r="$(decide 810 810)"
assert_eq '0' "${_r%% *}" '같으면 exit 0'
assert_contains "$_r" '색인 810 (main 실행 222) → 810 (이 실행 111) · +0.0%' '초록이어도 두 수를 남긴다(되살릴 실험의 계측값)'

# ── 3. 문턱 — 줄면 10%, 늘면 25% 까지. 끝에서 고정한다 ────────────────────────────────
# 실측(2026-11-13~14, main push 40 회): 797 → 810, 한 번에 바뀐 폭은 많아야 +4(0.5%).
assert_eq '0' "$(decide 900 1000 | cut -d' ' -f1)" '-10.0% 는 문턱 안'
assert_eq '1' "$(decide 899 1000 | cut -d' ' -f1)" '-10.1% 는 빨강'
assert_eq '0' "$(decide 1250 1000 | cut -d' ' -f1)" '+25.0% 는 문턱 안'
_r="$(decide 1251 1000)"
assert_eq '1' "${_r%% *}" '+25.1% 는 빨강 — 생성물·바이너리가 소스로 색인되는 부류'
assert_contains "$_r" '+25.1% 늘었다' '늘어난 폭을 말한다'

# ── 4. 못 읽으면 exit 2 — 「모른다」를 「같다」로 반올림하지 않는다 ──────────────────────
assert_eq '2' "$(decide null 810 | cut -d' ' -f1)" '이 실행의 수를 못 읽으면 exit 2'
assert_eq '2' "$(decide 810 null | cut -d' ' -f1)" '기준을 못 읽으면 exit 2'

# ── 5. 진입점 — 실행 번호 · 저장소가 없거나 모양이 틀리면 조회 전에 exit 2 ──────────────
_rc=0; GITHUB_REPOSITORY=o/r node "$SCRIPT" >/dev/null 2>&1 || _rc=$?
assert_eq '2' "$_rc" '--run 이 없으면 exit 2'
_rc=0; GITHUB_REPOSITORY=o/r node "$SCRIPT" --run 12x >/dev/null 2>&1 || _rc=$?
assert_eq '2' "$_rc" '--run 이 숫자가 아니면 exit 2'
_rc=0; env -u GITHUB_REPOSITORY node "$SCRIPT" --run 12 >/dev/null 2>&1 || _rc=$?
assert_eq '2' "$_rc" 'GITHUB_REPOSITORY 가 없으면 exit 2'

# ── 6. 진입점 끝까지 — 저장한 로그로 같은 판정을 돌려 판정이 **프로세스 종료 코드**까지 가는지 본다 ───────
# decide() 만 먹이면 `process.exit(d.code)` 를 `process.exit(0)` 으로 바꿔도 초록이다 — 위 5 절의 exit 2 는 인자
# 검사 길이라 판정 길을 안 지난다(등록부 selftests-with-no-negative-case 가 그 부류다).
FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
printf '%s\n%s\n' "$NOISE" "$LINE" > "$FX/now810.log"
printf 'INFO  487 files indexed (done)\n' > "$FX/base487.log"
printf 'INFO  159 files indexed (done)\n' > "$FX/now159.log"
printf '%s\n' "$NOISE" > "$FX/none.log"
cli() { # <인자…> → "<종료 코드>|<출력>"
  _o="$(GITHUB_STEP_SUMMARY="$FX/summary.md" node "$SCRIPT" "$@" 2>&1)" && _c=0 || _c=$?
  printf '%s|%s' "$_c" "$_o"
}
_r="$(cli --log "$FX/now159.log" --base-log "$FX/base487.log")"
assert_eq '1' "${_r%%|*}" '⚠️ 진입점도 #304 모양(487 → 159)에서 exit 1 — 판정이 종료 코드까지 간다'
assert_contains "$_r" '::error::색인이 -67.4% 줄었다' '진입점이 줄어든 폭을 말한다'
assert_contains "$(cat "$FX/summary.md" 2>/dev/null)" '| main 직전 성공 | 487 (실행 ' '요약에 기준 수를 남긴다'
_r="$(cli --log "$FX/now810.log" --base-log "$FX/now810.log")"
assert_eq '0' "${_r%%|*}" '같은 수면 진입점도 exit 0'
assert_contains "$_r" '→ 810 (이 실행 ' '초록이어도 두 수를 낸다'
# 종료 코드는 첫 `|` 앞이다 — 사용법은 두 줄이라 `cut` 은 둘째 줄을 통째로 돌려준다(실측).
_r="$(cli --log "$FX/none.log" --base-log "$FX/base487.log")"
assert_eq '2' "${_r%%|*}" '로그에 색인 수가 없으면 진입점도 exit 2'
_r="$(cli --log "$FX/now810.log")"
assert_eq '2' "${_r%%|*}" '--base-log 없이 --log 만이면 exit 2'
_r="$(cli --log "$FX/absent.log" --base-log "$FX/now810.log")"
assert_eq '2' "${_r%%|*}" '읽을 수 없는 로그면 exit 2'

assert_report
