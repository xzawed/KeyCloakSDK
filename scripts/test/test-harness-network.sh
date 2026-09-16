#!/usr/bin/env sh
# 하네스가 **compose 네트워크 이름을 박지 않게** 한다.
#
# ⚠️ **실측이 이 가드를 만들었다**(2026-09-15). `verify.sh` 는 keycloak 기동 뒤 실제 네트워크를
# 조회하는데(`docker compose ps --format '{{.Networks}}'`), `run.sh` 는 `NET=harness_default` 를
# **박아** 뒀다. 그 이름은 **디렉터리 이름에서 오는 compose 기본값**이라 `COMPOSE_PROJECT_NAME` 을
# 바꾸거나 디렉터리를 리네임하면 가정이 깨지고, 컨테이너가 keycloak 을 DNS 로 못 찾아
# **조용히 전부 실패**한다(스코어카드 0점). `verify.sh:14-22` 가 그 실패 모드를 이미 적고 있었는데
# **사본이 그것을 못 받았다** — 「한 곳이 배운 것을 다른 곳이 모른다」 부류다.
#
# ⚠️ **`install-net` 은 이 규칙 밖이다** — install 하네스는 그 네트워크를 **자기가 만든다**.
# 자기가 만든 이름을 쓰는 것은 가정이 아니라 사실이라, 리터럴이 옳다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${HN_ROOT:-$DIR/../..}"

# 파생 — compose 네트워크를 **변수로** 받아 `docker run` 에 넘기는 스크립트 전수.
HN_FILES="$(cd "$ROOT" && git grep -ln -- '--network "$NET"' -- harness/ 2>/dev/null || true)"
_n="$(printf '%s\n' "$HN_FILES" | grep -c . || true)"
# 공허 하한 — 검색이 깨지면 「대상이 없어서」 초록이 된다. ⚠️ **세어서 박는다**: 실측 2(2026-09-15).
HN_MIN=2
_enough=1; [ "$_n" -ge "$HN_MIN" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_n")" \
  "[하네스 네트워크] --network \"\$NET\" 를 쓰는 스크립트를 ${HN_MIN}개 미만 찾았다($_n) — 검색이 깨졌나?"

# 그 스크립트들은 `NET` 을 **조회해서** 얻어야 한다. 리터럴 대입만 있으면 운다.
_hard=''
for f in $HN_FILES; do
  [ -n "$f" ] || continue
  # `NET=` 대입 중 compose 조회를 담은 것이 하나라도 있어야 한다(폴백 대입은 따로 허용된다).
  grep -qE '^[[:space:]]*NET="?\$\(docker compose ps' "$ROOT/$f" || _hard="$_hard $f"
done
assert_eq "" "$_hard" \
  "[하네스 네트워크] compose 네트워크 이름을 박았다 —$_hard (keycloak 기동 뒤 docker compose ps 로 조회할 것)"

# 폴백은 있어야 한다 — 조회가 실패할 때 빈 이름으로 `docker run` 하면 진단이 나쁘다.
_nofb=''
for f in $HN_FILES; do
  [ -n "$f" ] || continue
  grep -qE 'NET=harness_default' "$ROOT/$f" || _nofb="$_nofb $f"
done
assert_eq "" "$_nofb" "[하네스 네트워크] 조회 실패 시 폴백이 없다 —$_nofb"

assert_report
