#!/usr/bin/env sh
# PHP 미러(xzawed/keycloak-sdk-php)가 아직 우리가 아는 상태인가.
#
# 왜 이 저장소에서 미러를 보는가: **아홉 중 php 만 게시 주체가 이 저장소가 아니다.** `php/`는
# subtree split 으로 미러에 밀리고 Packagist 는 그 미러를 서빙한다. 그래서 이 저장소의 가드가
# 전부 초록이어도 미러 쪽에서 벌어진 일은 아무것도 잡히지 않는다 — 실제로 그 확인은 사람의
# 눈에만 맡겨져 있었다(2026-08-23 실측 전까지).
#
# ⚠️ **판정 로직을 여기에 다시 쓰지 않는다.** `release-readiness.sh` 의 `rr_mirror_tag` ·
# `rr_packagist_source` 를 그대로 부른다 — 두 번째 정의 자리가 생기면 다음 릴리스에 조용히 갈린다.
#
# ⚠️ **네트워크 실패로는 실패하지 않는다(fail-open).** 이 검사는 GitHub·Packagist 라는 바깥
# 상태에 의존하므로, 그것이 흔들릴 때 저장소 작업을 막으면 안 된다. 막는 것은 **확인된 불일치**
# 뿐이다 — 이 저장소가 "모른다"를 "안전하다"로 반올림하지 않는 것과 짝을 이루는 반대편 규칙이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
# ⚠️ 호출자의 인자를 **소싱 전에** 보관한다. `. release-readiness.sh` 는 `--lib` 를 위치인자로
# 받아야 하는데(POSIX `.` 는 인자를 받지 않아 `set --` 로 넘긴다), 그 `set --` 가 `$1` 을
# 덮는다 — 그대로 두면 버전 인자가 `--lib` 로 읽힌다(실측: `v--lib` 을 조회했다).
VER_ARG="${1:-}"
set -- --lib
. "$DIR/release-readiness.sh"

VER="${VER_ARG:-$(df_published_version php)}"
[ -n "$VER" ] || { echo "::error::df_published_version php 가 비었다 — 무엇을 확인할지 알 수 없다"; exit 2; }

printf 'PHP 미러 확인: %s · v%s\n' "$RR_PHP_MIRROR" "$VER"

if rr_mirror_tag "$VER"; then _m=0; else _m=$?; fi
if rr_packagist_source; then _p=0; else _p=$?; fi

rc=0
case "$_m" in
  0) printf '  ✅ 미러에 v%s 태그가 있다\n' "$VER" ;;
  1) printf '::error::미러에 v%s 태그가 없다 — split 이 안 갔거나 실패했다\n' "$VER"; rc=1 ;;
  *) printf '  ℹ️ 미러 조회 실패(네트워크) — 확인하지 못했다. 실패로 치지 않는다\n' ;;
esac
case "$_p" in
  0) printf '  ✅ Packagist 가 이 미러를 소스로 서빙한다\n' ;;
  1) printf '::error::Packagist 가 이 미러를 소스로 서빙하지 않는다 — 등록을 확인할 것\n'; rc=1 ;;
  *) printf '  ℹ️ Packagist 조회 실패(네트워크) — 확인하지 못했다. 실패로 치지 않는다\n' ;;
esac

exit "$rc"
