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
V="$ROOT/harness/verify.sh"

assert_eq "ok" "$([ -f "$V" ] && printf 'ok' || printf 'missing')" \
  "[하네스 증거] harness/verify.sh 가 없다 — 경로가 바뀌었나?"

# (1) 앱 컨테이너 로그를 **신호 디렉터리**로 남긴다. 아티팩트에 실리는 것이 그곳뿐이다
#     (`harness.yml` 의 `path: harness/report/signals/`).
_logcap="$(grep -nE 'docker compose logs[^|]*report/signals/' "$V" | head -1 || true)"
assert_eq "ok" "$(ok_if "$([ -n "$_logcap" ] && echo 0 || echo 1)" "없음")" \
  "[하네스 증거] verify.sh 가 앱 로그를 report/signals/ 로 남기지 않는다 — 실패 원인이 런 뒤에 사라진다"

# (2) 루프를 빠져나가는 **모든** 자리에서 남겨야 한다 — build/up 실패 · healthz 타임아웃 ·
#     정상 종료 셋이다. 하나라도 빠지면 가장 진단이 급한 경우(부팅 중 크래시)에 증거가 없다.
#     ⚠️ **세어서 박는다**: 호출 자리 실측 3(2026-09-16).
HFE_CALLS=3
_calls="$(grep -cE '^[^#]*capture_app_log "\$L"' "$V" || true)"
_enough_calls=1; [ "$_calls" -ge "$HFE_CALLS" ] && _enough_calls=0
assert_eq "ok" "$(ok_if "$_enough_calls" "$_calls")" \
  "[하네스 증거] 앱 로그 캡처 호출이 ${HFE_CALLS}자리 미만이다($_calls) — 빠진 경로에서는 원인이 사라진다"

# (3) 마지막 캡처는 컨테이너를 **stop 하기 전**이어야 한다. 순서가 뒤집히면 EXIT 트랩의
#     `down -v` 뒤에 읽을 컨테이너가 없다.
_caplast="$(grep -nE '^[^#]*capture_app_log "\$L"' "$V" | tail -1 | cut -d: -f1 || true)"
_stoplast="$(grep -nE 'docker compose .*stop "app-\$L"' "$V" | tail -1 | cut -d: -f1 || true)"
_order=1
[ -n "$_caplast" ] && [ -n "$_stoplast" ] && [ "$_caplast" -lt "$_stoplast" ] && _order=0
assert_eq "ok" "$(ok_if "$_order" "캡처=$_caplast stop=$_stoplast")" \
  "[하네스 증거] 마지막 앱 로그 캡처가 stop 뒤에 있다 — 그 순서면 지워진 컨테이너를 읽는다"

# (4) 빈 로그를 증거로 착각하지 않는다 — 비면 그렇게 적는 자리가 있어야 한다.
_empty="$(grep -cE '\[ -s "report/signals/\$[A-Za-z0-9_]+\.app\.log" \]' "$V" || true)"
assert_eq "ok" "$(ok_if "$([ "$_empty" -ge 1 ] && echo 0 || echo 1)" "$_empty")" \
  "[하네스 증거] 빈 로그를 그대로 올린다 — 빈 파일은 「증거 없음」과 구분되지 않는다"

# (5) 캡처 명령 자체가 실패한 경우도 표시해야 한다. `2>&1` 이라 CLI 오류가 파일에 담기고,
#     비어 있지 않으므로 (4)의 표시가 안 붙는다 — 그 28B 가 「증거가 있다」로 읽힌다.
#     ⚠️ 독립 레그가 이 자리를 지목했고, 같은 레그의 다른 주장(프로필이 컨테이너를 가린다)은
#     실측이 기각했다: `--profile apps` 없이도 `logs`·`ps -a` 가 앱을 본다(기동·정지·삭제 전부).
_clierr="$(grep -cE 'docker compose logs 실패' "$V" || true)"
assert_eq "ok" "$(ok_if "$([ "$_clierr" -ge 1 ] && echo 0 || echo 1)" "$_clierr")" \
  "[하네스 증거] logs 명령 실패를 표시하지 않는다 — CLI 오류가 앱 로그로 읽힌다"

# (6) 빌드·기동 실패 자리는 **컨테이너 목록**을 함께 남긴다. 등록부 실측: 중단된 런이 남긴
#     컨테이너 이름 충돌(`Conflict. The container name ... is already in use`)이 「build/up failed」로
#     기록돼, 빌드는 성공했는데도 코드를 뒤지게 만든다.
_psdump="$(grep -cE 'docker compose ps[^|]*report/signals/' "$V" || true)"
assert_eq "ok" "$(ok_if "$([ "$_psdump" -ge 1 ] && echo 0 || echo 1)" "$_psdump")" \
  "[하네스 증거] build/up 실패에 컨테이너 목록을 안 남긴다 — 이름 충돌과 진짜 빌드 실패가 구분되지 않는다"

# (7) 남기는 증거 파일은 **gitignore 안**이어야 한다. 아니면 런마다 워킹트리가 더러워지고,
#     언젠가 실수로 커밋된다. ⚠️ 이 단언은 실제 구멍을 잡았다 — 증거 캡처를 넣은 그 커밋이
#     `*.app.log`·`*.compose-ps.txt` 를 무시 목록에 안 넣어 둘 다 추적 대상으로 떴다(2026-09-16).
_targets="$(grep -oE 'report/signals/\$[A-Za-z0-9_]+\.[A-Za-z0-9.-]+' "$V" | sed -E 's/\$[A-Za-z0-9_]+/probe/' | sort -u)"
_notig=''
for _t in $_targets; do
  git -C "$ROOT" check-ignore -q "harness/$_t" 2>/dev/null || _notig="$_notig $_t"
done
assert_eq "" "$_notig" \
  "[하네스 증거] 생성 증거 파일이 gitignore 밖이다 —$_notig (런마다 워킹트리가 더러워진다)"

# (8) 공허 하한 — 위 검색들이 전부 깨져도 「대상이 없어서」 초록이 되면 안 된다.
#     ⚠️ **세어서 박는다**: verify.sh 가 report/signals/ 를 적는 자리 실측 8(2026-09-16).
HFE_MIN=8
_writes="$(grep -cE 'report/signals/' "$V" || true)"
_enough=1; [ "$_writes" -ge "$HFE_MIN" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_writes")" \
  "[하네스 증거] verify.sh 의 signals 기록 자리를 ${HFE_MIN}개 미만 찾았다 — 검색이 깨졌나?"

assert_report
