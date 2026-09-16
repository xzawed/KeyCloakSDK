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

# (3) 기본값은 서로 달라야 한다. 복붙으로 같은 기본값이 둘이면 두 서비스가 함께 뜨지 못하는데,
#     그 실패는 「내 PC 에서만 안 된다」로 보여 원인을 못 찾는다.
_defaults="$(printf '%s\n' "$_maps" | sed -nE 's/.*\$\{[A-Za-z_][A-Za-z0-9_]*:-([0-9]+)\}:[0-9]+.*/\1/p')"
_dupes="$(printf '%s\n' "$_defaults" | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "" "$_dupes" \
  "[하네스 포트] 기본 호스트 포트가 겹친다 — [$_dupes] (서비스마다 달라야 함께 뜬다)"

# (4) 변수 이름도 서로 달라야 한다 — 이름이 겹치면 한 값이 두 서비스를 동시에 움직여
#     (3)의 고유성 검사를 통과한 채로 충돌한다.
_names="$(printf '%s\n' "$_maps" | sed -nE 's/.*\$\{([A-Za-z_][A-Za-z0-9_]*):-[0-9]+\}:[0-9]+.*/\1/p')"
_ndupes="$(printf '%s\n' "$_names" | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "" "$_ndupes" \
  "[하네스 포트] 호스트 포트 변수 이름이 겹친다 — [$_ndupes]"

assert_report
