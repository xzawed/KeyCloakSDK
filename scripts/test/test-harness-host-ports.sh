#!/usr/bin/env sh
# 하네스 compose 가 **호스트 포트를 못박지 않게** 한다.
#
# ⚠️ **실측이 이 가드를 만들었다**(2026-09-16). `docker-compose.yml` 이 keycloak 을
# `"8080:8080"` 으로 퍼블리시해, 8080 을 다른 프로세스가 쥔 PC 에서는 하네스가 **기동조차
# 못 했다**(`Bind for 127.0.0.1:8080 failed: port is already allocated`). 검증 경로는 전부
# compose 네트워크 안(`http://keycloak:8080`)이라 **호스트 퍼블리시는 사람 편의일 뿐**인데,
# 그 편의가 전체 실행을 막았다.
#
# ⚠️ **스크립트는 이미 동적이다** — `run.sh`·`verify.sh` 는 `docker compose port` 로 호스트
# 포트를 읽는다. 즉 못박힌 것은 compose 파일 한 곳뿐이고, 기본값을 유지한 채 변수로 빼면
# 아무 동작도 안 바뀐다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${HHP_ROOT:-$DIR/../..}"
C="$ROOT/harness/docker-compose.yml"

assert_eq "ok" "$([ -f "$C" ] && printf 'ok' || printf 'missing')" \
  "[하네스 포트] harness/docker-compose.yml 이 없다 — 경로가 바뀌었나?"

# 퍼블리시 항목 전수(`- "<host>:<container>"` 형태의 줄).
_maps="$(grep -nE '^[[:space:]]*-[[:space:]]*"[^"]*:[0-9]+"[[:space:]]*$' "$C" || true)"
_n="$(printf '%s\n' "$_maps" | grep -c . || true)"

# (1) 공허 하한 — 검색이 깨지면 「대상이 없어서」 초록이 된다.
#     ⚠️ **세어서 박는다**: keycloak 1 + 앱 9 = 실측 10(2026-09-16).
HHP_MIN=10
_enough=1; [ "$_n" -ge "$HHP_MIN" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_n")" \
  "[하네스 포트] 퍼블리시 항목을 ${HHP_MIN}개 미만 찾았다($_n) — 검색이 깨졌나?"

# (2) 호스트 쪽은 **전부** `${VAR:-기본값}` 이어야 한다. 리터럴이 하나라도 남으면 그 자리가
#     충돌하는 PC 에서 하네스 전체가 멈춘다.
_hard=''
for _ln in $(printf '%s\n' "$_maps" | cut -d: -f1); do
  _line="$(sed -n "${_ln}p" "$C")"
  case "$_line" in
    *'${'*':-'*'}:'*) : ;;
    *) _hard="$_hard $_ln" ;;
  esac
done
assert_eq "" "$_hard" \
  "[하네스 포트] 호스트 포트를 박은 줄이 있다 —$_hard (\${VAR:-기본값}:컨테이너포트 로 쓸 것)"

# (3)(4)의 판정 — 라이브와 아래 음성 대조가 **같은 함수**를 부른다. $1=퍼블리시 줄들.
hp_defaults() { printf '%s\n' "$1" | sed -nE 's/.*\$\{[A-Za-z_][A-Za-z0-9_]*:-([0-9]+)\}:[0-9]+.*/\1/p'; }
hp_names() { printf '%s\n' "$1" | sed -nE 's/.*\$\{([A-Za-z_][A-Za-z0-9_]*):-[0-9]+\}:[0-9]+.*/\1/p'; }
hp_dup_defaults() { printf '%s\n' "$(hp_defaults "$1")" | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//'; }
hp_dup_names() { printf '%s\n' "$(hp_names "$1")" | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//'; }

# (1b) 추출한 목록의 하한 — (1)은 **줄** 수를 세므로 추출이 깨져 빈 목록이 돼도 (3)(4)가 「겹침 없음」으로
#      초록이었다(실측 2026-11-14 SILENT). 퍼블리시 줄마다 기본값 하나 · 이름 하나가 뽑혀야 한다.
assert_eq "$_n" "$(hp_defaults "$_maps" | grep -c . || true)" \
  "[하네스 포트] 기본 호스트 포트를 퍼블리시 줄 수($_n)만큼 못 뽑았다 — 추출이 깨졌나?"
assert_eq "$_n" "$(hp_names "$_maps" | grep -c . || true)" \
  "[하네스 포트] 호스트 포트 변수 이름을 퍼블리시 줄 수($_n)만큼 못 뽑았다 — 추출이 깨졌나?"

# (3) 기본값은 서로 달라야 한다. 복붙으로 같은 기본값이 둘이면 두 서비스가 함께 뜨지 못하는데,
#     그 실패는 「내 PC 에서만 안 된다」로 보여 원인을 못 찾는다.
_dupes="$(hp_dup_defaults "$_maps")"
assert_eq "" "$_dupes" \
  "[하네스 포트] 기본 호스트 포트가 겹친다 — [$_dupes] (서비스마다 달라야 함께 뜬다)"

# (4) 변수 이름도 서로 달라야 한다 — 이름이 겹치면 한 값이 두 서비스를 동시에 움직여
#     (3)의 고유성 검사를 통과한 채로 충돌한다.
_ndupes="$(hp_dup_names "$_maps")"
assert_eq "" "$_ndupes" \
  "[하네스 포트] 호스트 포트 변수 이름이 겹친다 — [$_ndupes]"

# 음성 대조 — 겹치는 기본값 · 겹치는 이름을 담은 퍼블리시 줄을 같은 판정에 태운다(라이브는 늘 「겹침 없음」이라
# 판정이 깨져도 초록이었다 — 실측 2026-11-14 SILENT 둘). 서로 다른 축이 서로를 대신하지 않는지도 본다.
_hp_fx1="$(printf '%s\n' '      - "${HP_A_PORT:-8080}:8080"' '      - "${HP_B_PORT:-8080}:8090"')"
_hp_fx2="$(printf '%s\n' '      - "${HP_A_PORT:-8080}:8080"' '      - "${HP_A_PORT:-8081}:8090"')"
assert_eq "8080" "$(hp_dup_defaults "$_hp_fx1")" "[하네스 포트·음성대조] 겹치는 기본 호스트 포트를 못 잡는다"
assert_eq "" "$(hp_dup_names "$_hp_fx1")" "[하네스 포트·음성대조] 이름이 다른데 겹친다고 한다"
assert_eq "HP_A_PORT" "$(hp_dup_names "$_hp_fx2")" "[하네스 포트·음성대조] 겹치는 호스트 포트 변수 이름을 못 잡는다"
assert_eq "" "$(hp_dup_defaults "$_hp_fx2")" "[하네스 포트·음성대조] 기본값이 다른데 겹친다고 한다"

assert_report
