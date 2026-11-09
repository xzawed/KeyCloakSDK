#!/usr/bin/env sh
# 하네스가 **실패했을 때 그 원인을 증거로 남기는가**.
#
# ⚠️ **실측이 이 가드를 만들었다**(2026-09-16). 야간 `score-all` 이 2026-09-08~09-15 **여덟 밤**
# 연속 빨갰는데, 아티팩트에 남은 것은 `{"name":"token(client-creds)","ok":false,"detail":"500"}`
# 뿐이었다. 앱이 던진 예외 문장(`wrong number of arguments (given 2, expected 1)`)은
# **어디에도 없었다** — `verify.sh` 가 앱 컨테이너를 `stop` 하고 EXIT 트랩이 `down -v` 로 지우면
# 로그가 사라진다. 원인을 알아내는 데 로컬 재빌드 + 통제 실험이 필요했고, 그 비용은 전부
# 「신호가 증상만 담고 원인을 안 담는다」에서 나왔다.
#
# ⚠️ **빈 로그를 증거로 착각하지 않게 한다**(독립 레그가 지목한 침묵 실패). 컨테이너가 stdout 에
# 아무것도 안 쓰면 빈 파일이 올라가고, 그것은 「증거를 남겼다」와 구분되지 않는다. 그래서
# 캡처 자리는 **빈 경우 그렇게 적어야** 한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${HFE_ROOT:-$DIR/../..}"

# 파생 — **앱 컨테이너를 띄우는 하네스 스크립트 전수**가 대상이다. 경로를 박으면 사본이
# 규칙 밖에 남는다(#505 가 같은 부류에서 배운 것: 「주석이 있어도 사본은 안 읽는다」).
# ⚠️ **실측 2026-09-16: `run.sh` 가 정확히 그 상태였다** — `verify.sh` 에 캡처를 넣은 첫 커밋이
# 사본을 빠뜨렸고, 부류 재스캔이 그것을 찾았다. 그래서 이 가드는 경로를 세지 않고 훑는다.
HFE_FILES="$(cd "$ROOT" && git grep -ln -- 'docker compose --profile apps up' -- 'harness/*.sh' 2>/dev/null || true)"
_nf="$(printf '%s\n' "$HFE_FILES" | grep -c . || true)"
# 공허 하한 — 검색이 깨지면 「대상이 없어서」 초록이 된다. ⚠️ **세어서 박는다**: 실측 2(run.sh · verify.sh).
HFE_SCRIPTS=2
_enough_files=1; [ "$_nf" -ge "$HFE_SCRIPTS" ] && _enough_files=0
assert_eq "ok" "$(ok_if "$_enough_files" "$_nf")" \
  "[하네스 증거] 앱을 띄우는 하네스 스크립트를 ${HFE_SCRIPTS}개 미만 찾았다($_nf) — 검색이 깨졌나?"

for _rel in $HFE_FILES; do
V="$ROOT/$_rel"

# (1) 앱 컨테이너 로그를 **신호 디렉터리**로 남긴다. 아티팩트에 실리는 것이 그곳뿐이다
#     (`harness.yml` 의 `path: harness/report/signals/`).
_logcap="$(grep -nE 'docker compose logs[^|]*report/signals/' "$V" | head -1 || true)"
assert_eq "ok" "$(ok_if "$([ -n "$_logcap" ] && echo 0 || echo 1)" "없음")" \
  "[하네스 증거] $_rel 가 앱 로그를 report/signals/ 로 남기지 않는다 — 실패 원인이 런 뒤에 사라진다"

# (2) 루프를 빠져나가는 **모든** 자리에서 남겨야 한다 — build/up 실패 · healthz 타임아웃 ·
#     정상 종료 셋이다. 하나라도 빠지면 가장 진단이 급한 경우(부팅 중 크래시)에 증거가 없다.
#     ⚠️ **세어서 박는다**: 호출 자리 실측 3(2026-09-16).
HFE_CALLS=3
_calls="$(grep -cE '^[^#]*capture_app_log "\$[A-Za-z_][A-Za-z0-9_]*"' "$V" || true)"
_enough_calls=1; [ "$_calls" -ge "$HFE_CALLS" ] && _enough_calls=0
assert_eq "ok" "$(ok_if "$_enough_calls" "$_calls")" \
  "[하네스 증거] $_rel 의 앱 로그 캡처 호출이 ${HFE_CALLS}자리 미만이다($_calls) — 빠진 경로에서는 원인이 사라진다"

# (3) 마지막 캡처는 컨테이너를 **stop 하기 전**이어야 한다. 순서가 뒤집히면 EXIT 트랩의
#     `down -v` 뒤에 읽을 컨테이너가 없다.
_caplast="$(grep -nE '^[^#]*capture_app_log "\$[A-Za-z_][A-Za-z0-9_]*"' "$V" | tail -1 | cut -d: -f1 || true)"
_stoplast="$(grep -nE 'docker compose .*stop "app-\$[A-Za-z_][A-Za-z0-9_]*"' "$V" | tail -1 | cut -d: -f1 || true)"
_order=1
[ -n "$_caplast" ] && [ -n "$_stoplast" ] && [ "$_caplast" -lt "$_stoplast" ] && _order=0
assert_eq "ok" "$(ok_if "$_order" "캡처=$_caplast stop=$_stoplast")" \
  "[하네스 증거] $_rel 의 마지막 앱 로그 캡처가 stop 뒤에 있다 — 그 순서면 지워진 컨테이너를 읽는다"

# (4) 빈 로그를 증거로 착각하지 않는다 — 비면 그렇게 적는 자리가 있어야 한다.
_empty="$(grep -cE '\[ -s "report/signals/\$[A-Za-z0-9_]+\.app\.log" \]' "$V" || true)"
assert_eq "ok" "$(ok_if "$([ "$_empty" -ge 1 ] && echo 0 || echo 1)" "$_empty")" \
  "[하네스 증거] $_rel 가 빈 로그를 그대로 올린다 — 빈 파일은 「증거 없음」과 구분되지 않는다"

# (5) 캡처 명령 자체가 실패한 경우도 표시해야 한다. `2>&1` 이라 CLI 오류가 파일에 담기고,
#     비어 있지 않으므로 (4)의 표시가 안 붙는다 — 그 28B 가 「증거가 있다」로 읽힌다.
#     ⚠️ 독립 레그가 이 자리를 지목했고, 같은 레그의 다른 주장(프로필이 컨테이너를 가린다)은
#     실측이 기각했다: `--profile apps` 없이도 `logs`·`ps -a` 가 앱을 본다(기동·정지·삭제 전부).
_clierr="$(grep -cE 'docker compose logs 실패' "$V" || true)"
assert_eq "ok" "$(ok_if "$([ "$_clierr" -ge 1 ] && echo 0 || echo 1)" "$_clierr")" \
  "[하네스 증거] $_rel 가 logs 명령 실패를 표시하지 않는다 — CLI 오류가 앱 로그로 읽힌다"

# (6) 빌드·기동 실패 자리는 **컨테이너 목록**을 함께 남긴다. 등록부 실측: 중단된 런이 남긴
#     컨테이너 이름 충돌(`Conflict. The container name ... is already in use`)이 「build/up failed」로
#     기록돼, 빌드는 성공했는데도 코드를 뒤지게 만든다.
_psdump="$(grep -cE 'docker compose ps[^|]*report/signals/' "$V" || true)"
assert_eq "ok" "$(ok_if "$([ "$_psdump" -ge 1 ] && echo 0 || echo 1)" "$_psdump")" \
  "[하네스 증거] $_rel 가 build/up 실패에 컨테이너 목록을 안 남긴다 — 이름 충돌과 진짜 빌드 실패가 구분되지 않는다"

# (7) 남기는 증거 파일은 **gitignore 안**이어야 한다. 아니면 런마다 워킹트리가 더러워지고,
#     언젠가 실수로 커밋된다. ⚠️ 이 단언은 실제 구멍을 잡았다 — 증거 캡처를 넣은 그 커밋이
#     `*.app.log`·`*.compose-ps.txt` 를 무시 목록에 안 넣어 둘 다 추적 대상으로 떴다(2026-09-16).
_targets="$(grep -oE 'report/signals/\$[A-Za-z0-9_]+\.[A-Za-z0-9.-]+' "$V" | sed -E 's/\$[A-Za-z0-9_]+/probe/' | sort -u)"
_notig=''
for _t in $_targets; do
  git -C "$ROOT" check-ignore -q "harness/$_t" 2>/dev/null || _notig="$_notig $_t"
done
assert_eq "" "$_notig" \
  "[하네스 증거] $_rel 의 생성 증거 파일이 gitignore 밖이다 —$_notig (런마다 워킹트리가 더러워진다)"

# (8) 공허 하한 — 위 검색들이 전부 깨져도 「대상이 없어서」 초록이 되면 안 된다.
#     ⚠️ **세어서 박는다**: 대상 스크립트가 `report/signals/` 를 적는 자리 실측 — `verify.sh` 11 ·
#     `run.sh` 5(2026-09-16). 하한은 **둘 중 작은 쪽**이다. 파일마다 다른 수를 박으면 그 표가
#     곧 손 목록이 되고, 이 가드가 막으려는 바로 그 부류가 된다.
HFE_MIN=5
_writes="$(grep -cE 'report/signals/' "$V" || true)"
_enough=1; [ "$_writes" -ge "$HFE_MIN" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_writes")" \
  "[하네스 증거] $_rel 의 signals 기록 자리를 ${HFE_MIN}개 미만 찾았다 — 검색이 깨졌나?"

done

# ── (9) 단위 스위트도 원인을 남긴다 ─────────────────────────────────────────────────────────────
# ⚠️ **실측이 이 절을 만들었다**(2026-11-06). 야간 score-all 이 「dotnet 통과 621/622」로 빨갰는데 어느 테스트인지
# 알 길이 없었다 — suites/<lang>.sh 아홉이 마지막 JSON 한 줄만 내고 테스트 출력을 버려, signals 아티팩트의
# *.suite.raw 가 각 127–137 B 였다. 규약은 harness/suites/run-suite.sh 머리(___SUITE_LOG_*)가 소유한다.
# 여기서는 **행동**으로 잰다: 가짜 docker 가 정해 둔 출력을 내면 스위트의 판정과 덤프가 그 출력만으로 갈린다.
# 대상은 손 목록이 아니라 df_tree_langs 다 — 스위트 없는 열 번째 언어는 여기서 실패한다.
. "$DIR/../lib/deploy-facts.sh"
_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/bin" "$_tmp/h/suites" "$_tmp/h/report"
printf '%s\n' '#!/usr/bin/env sh' '[ "${1:-}" = run ] && cat "$HFE_FAKE_OUT"' 'exit 0' > "$_tmp/bin/docker"
chmod +x "$_tmp/bin/docker"
_canary="HFE-CANARY-$$"
# 깨진 출력 — 테스트 종료코드 마커 1. java 는 surefire 요약 행이 없으면 실패다(fail-closed) — 이것으로 아홉이 다 깨진다.
printf '%s\n' "$_canary --- FAIL: TestCanary" '___TESTEXIT=1' > "$_tmp/fail.out"
# 통과 출력 — 아홉이 각자 보는 통과 마커를 다 담는다(surefire 요약 · 설치 0 · 테스트 0). 음성 대조군이다.
printf '%s\n' "$_canary ok" 'Tests run: 3, Failures: 0, Errors: 0, Skipped: 0' '___INSTALLEXIT=0' '___TESTEXIT=0' > "$_tmp/pass.out"
_nl=0
for _l in $(df_tree_langs "$ROOT"); do
  _nl=$((_nl + 1))
  _s="$ROOT/harness/suites/$_l.sh"
  if [ ! -f "$_s" ]; then
    assert_eq "있음" "없음" "[하네스 증거] harness/suites/$_l.sh 가 없다 — $_l 의 단위 스위트가 야간에 안 돈다"
    continue
  fi
  _fo="$(PATH="$_tmp/bin:$PATH" HFE_FAKE_OUT="$_tmp/fail.out" bash "$_s" 2>&1 || true)"
  _po="$(PATH="$_tmp/bin:$PATH" HFE_FAKE_OUT="$_tmp/pass.out" bash "$_s" 2>&1 || true)"
  assert_contains "$_fo" '"testsPassed":false' "[하네스 증거] $_l.sh 가 깨진 출력을 실패로 판정하지 않는다 — 아래 단언이 공허하다"
  assert_contains "$_fo" "___SUITE_LOG_BEGIN
$_canary --- FAIL: TestCanary" "[하네스 증거] $_l.sh 가 깨진 테스트의 출력을 ___SUITE_LOG 블록으로 남기지 않는다"
  assert_contains "$_fo" "___SUITE_LOG_END" "[하네스 증거] $_l.sh 의 실패 단서 블록이 닫히지 않는다"
  assert_contains "$_po" '"testsPassed":true' "[하네스 증거] $_l.sh 가 통과 출력을 통과로 판정하지 않는다 — 음성 대조가 공허하다"
  assert_not_contains "$_po" "___SUITE_LOG_BEGIN" "[하네스 증거] $_l.sh 가 통과한 런에도 블록을 낸다 — 단서가 소음이 된다"
done
# 공허 하한 — 파생이 깨져 언어가 줄면 위 루프가 「대상이 없어서」 초록이 된다. ⚠️ 세어서 박는다: 실측 9(2026-11-09).
assert_eq "ok" "$(ok_if "$([ "$_nl" -ge 9 ] && echo 0 || echo 1)" "$_nl")" \
  "[하네스 증거] 스위트 대상 언어가 9 미만이다($_nl) — df_tree_langs 가 깨졌나?"

# run-suite.sh 가 실패한 언어의 블록에서 **실패 표지 줄만** 잡 로그에 찍는가 — 진짜 run-suite.sh 를 가짜 스위트 셋으로.
cp "$ROOT/harness/suites/run-suite.sh" "$_tmp/h/suites/run-suite.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  '{ echo ___SUITE_LOG_BEGIN; echo "=== RUN   TestQuiet"; echo "--- FAIL: TestLoud"; echo ___SUITE_LOG_END; } >&2' \
  'echo "{\"lang\":\"broke\",\"ran\":true,\"testsPassed\":false}"' > "$_tmp/h/suites/broke.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "{\"lang\":\"bare\",\"ran\":true,\"testsPassed\":false}"' > "$_tmp/h/suites/bare.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "{\"lang\":\"fine\",\"ran\":true,\"testsPassed\":true}"' > "$_tmp/h/suites/fine.sh"
chmod +x "$_tmp/h/suites/"*.sh
_rrc=0
_ro="$(bash "$_tmp/h/suites/run-suite.sh" broke bare fine 2>&1)" || _rrc=$?
assert_eq "1" "$_rrc" "[하네스 증거] run-suite.sh 가 실패한 스위트에 0 이 아닌 코드로 끝나지 않는다"
assert_contains "$_ro" "--- FAIL: TestLoud" "[하네스 증거] run-suite.sh 가 실패 표지 줄을 잡 로그에 찍지 않는다"
assert_not_contains "$_ro" "TestQuiet" "[하네스 증거] run-suite.sh 가 블록 전체를 잡 로그에 쏟는다 — 실패 표지 줄만이어야 한다"
assert_contains "$_ro" "[bare] 실패 단서 블록이 없다" "[하네스 증거] run-suite.sh 가 블록 없는 실패를 말하지 않는다 — 빈칸이 「단서 없음」으로 안 읽힌다"
assert_not_contains "$_ro" "[fine]" "[하네스 증거] run-suite.sh 가 통과한 스위트에 실패 단서를 찍는다"

assert_report
