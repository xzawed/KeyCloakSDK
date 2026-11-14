#!/usr/bin/env sh
# PHP 미러(xzawed/keycloak-sdk-php)가 아직 우리가 아는 상태인가.
#
# 왜 이 저장소에서 미러를 보는가: **아홉 중 php 만 게시 주체가 이 저장소가 아니다.** `php/`는
# subtree split 으로 미러에 밀리고 Packagist 는 그 미러를 서빙한다. 그래서 이 저장소의 가드가
# 전부 초록이어도 미러 쪽에서 벌어진 일은 아무것도 잡히지 않는다 — 실제로 그 확인은 사람의
# 눈에만 맡겨져 있었다(2026-08-23 실측 전까지).
#
# ⚠️ **판정 로직을 여기에 다시 쓰지 않는다.** `release-readiness.sh` 의 `rr_mirror_tag` ·
# `rr_packagist_source` · `rr_packagist_version` 을 그대로 부른다 — 두 번째 정의 자리가 생기면 다음
# 릴리스에 조용히 갈린다.
#
# 인자 없이(CI `php-mirror` 잡)는 **게시가 확인된 직전 버전**(`rr_php_last_published`)을 본다. 예전
# 기본값 `df_published_version` 은 태그 **전** 커밋에서 움직여(DEPLOY.md §4 1단계) php 릴리스 PR 마다
# 「미러에 v<새 버전> 이 없다」로 빨갰다(실측: #937 · #938). 게시 **뒤** 확인은 버전을 준다:
# `sh scripts/check-php-mirror.sh <X.Y.Z>` — 미러 태그 · Packagist 소스 · Packagist 에 그 버전.
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

VER="${VER_ARG:-$(rr_php_last_published)}"
[ -n "$VER" ] || { echo "::error::rr_php_last_published 가 비었다(df_api_baseline php) — 무엇을 확인할지 알 수 없다"; exit 2; }

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
# 그 버전을 Packagist 가 집어 갔는가 — 소스가 미러로 확인됐을 때만 묻는다(아니면 위 줄이 이미 답했다).
# 사람이 Packagist 페이지를 열어 보던 확인이다. 계속 없으면 Packagist 가 미러를 더는 따라오지 않는다.
if [ "$_p" -eq 0 ]; then
  if rr_packagist_version "$VER"; then _v=0; else _v=$?; fi
  case "$_v" in
    0) printf '  ✅ Packagist 에 v%s 버전이 있다\n' "$VER" ;;
    1) printf '::error::Packagist 에 v%s 버전이 없다 — split 직후라면 몇 분 뒤 다시 돌린다. 계속 없으면 Packagist 가 미러를 따라오지 않는다(자동 갱신)\n' "$VER"; rc=1 ;;
    *) printf '  ℹ️ Packagist 버전 조회 실패(네트워크) — 확인하지 못했다. 실패로 치지 않는다\n' ;;
  esac
fi

exit "$rc"
