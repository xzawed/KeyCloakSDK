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

# 판정 둘 — 라이브와 아래 음성 대조가 **같은 함수**를 부른다. $1=루트 $2=파일 목록 → 걸린 파일
# 그 스크립트들은 `NET` 을 **조회해서** 얻어야 한다. 리터럴 대입만 있으면 운다.
hn_hard() {
  _hh=''
  for f in $2; do
    [ -n "$f" ] || continue
    # `NET=` 대입 중 compose 조회를 담은 것이 하나라도 있어야 한다(폴백 대입은 따로 허용된다).
    grep -qE '^[[:space:]]*NET="?\$\(docker compose ps' "$1/$f" || _hh="$_hh $f"
  done
  printf '%s' "$_hh"
}
# 폴백은 있어야 한다 — 조회가 실패할 때 빈 이름으로 `docker run` 하면 진단이 나쁘다.
hn_nofb() {
  _hn=''
  for f in $2; do
    [ -n "$f" ] || continue
    grep -qE 'NET=harness_default' "$1/$f" || _hn="$_hn $f"
  done
  printf '%s' "$_hn"
}

_hard="$(hn_hard "$ROOT" "$HN_FILES")"
assert_eq "" "$_hard" \
  "[하네스 네트워크] compose 네트워크 이름을 박았다 —$_hard (keycloak 기동 뒤 docker compose ps 로 조회할 것)"

_nofb="$(hn_nofb "$ROOT" "$HN_FILES")"
assert_eq "" "$_nofb" "[하네스 네트워크] 조회 실패 시 폴백이 없다 —$_nofb"

# 음성 대조 — 이름을 박기만 한 스크립트 · 폴백 없는 스크립트를 같은 판정에 태운다. 라이브 둘은 늘 둘 다 갖춰
# 판정이 「늘 있다」로 깨져도 초록이었다(실측 2026-11-14 SILENT 둘). 한 축이 다른 축을 대신하지 않는지도 본다.
_hn_fx="$(mktemp -d)"
trap 'rm -rf "$_hn_fx"' EXIT
printf '%s\n' 'NET=harness_default' 'docker run --rm --network "$NET" x' > "$_hn_fx/hard.sh"
printf '%s\n' 'NET="$(docker compose ps --format '"'"'{{.Networks}}'"'"' keycloak | head -1)"' 'docker run --rm --network "$NET" x' \
  > "$_hn_fx/nofb.sh"
assert_eq " hard.sh" "$(hn_hard "$_hn_fx" "hard.sh nofb.sh")" \
  "[하네스 네트워크·음성대조] 조회 없이 이름만 박은 스크립트를 못 잡거나, 조회하는 스크립트를 잡는다"
assert_eq " nofb.sh" "$(hn_nofb "$_hn_fx" "hard.sh nofb.sh")" \
  "[하네스 네트워크·음성대조] 폴백 없는 스크립트를 못 잡거나, 폴백 있는 스크립트를 잡는다"

assert_report
