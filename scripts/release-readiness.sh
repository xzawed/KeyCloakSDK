#!/usr/bin/env sh
# release-readiness.sh — 언어별 실배포 준비상태(시크릿·레지스트리·태그)를 읽기전용으로 리포트.
# ⚠️ 읽기전용: 어떤 상태도 변경하지 않는다. 시크릿 값은 조회/출력하지 않는다(이름·존재만).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
# ⚠️ 이 파일이 `. release-readiness.sh --lib`로 다른 스크립트(예: scripts/test/*)에서
# 소싱되면 $0은 소싱하는 쪽(예: scripts/test/test-release-readiness.sh)의 값을 그대로
# 유지한다(POSIX `.`는 $0을 바꾸지 않음) — 이 경우 DIR은 scripts/test가 되어
# "$DIR/lib/deploy-facts.sh"가 없다. scripts/test/../lib로도 시도해 두 호출 경로
# (직접 실행 · 테스트에서 소싱) 모두를 커버한다.
if [ -f "$DIR/lib/deploy-facts.sh" ]; then
  . "$DIR/lib/deploy-facts.sh"
else
  . "$DIR/../lib/deploy-facts.sh"
fi

# 외부호출 래퍼(테스트에서 override 가능) — 실패는 조용히 '?'로 격리.
rr_secret_set() { # <name> → 0 if a repo secret with this name exists
  command -v gh >/dev/null 2>&1 || return 2
  gh secret list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}
rr_url_exists() { # <url> → exit 0=게시됨(2xx) 1=미게시(4xx/5xx, curl -f rc=22) 2=unknown(curl 부재·네트워크/타임아웃 실패)
  command -v curl >/dev/null 2>&1 || return 2
  if curl -sfI "$1" >/dev/null 2>&1; then return 0; fi
  # HEAD가 일부 레지스트리(405 등)에서 미지원일 수 있어 GET으로 재확인 — 최종 판정은 이 결과 기준.
  if curl -sf "$1" >/dev/null 2>&1; then return 0; fi
  rc=$?
  [ "$rc" -eq 22 ] && return 1
  return 2
}
rr_tag_exists() { # <glob> → 0 if any matching tag
  [ -n "$(git tag -l "$1" 2>/dev/null | head -1)" ]
}

# 순수 판정(단위테스트 대상): secrets∈{set,unset,na} registry∈{published,exists(미게시),unknown} tag∈{none,present}
rr_verdict() { # <secrets> <registry> <tag>
  if [ "$3" = present ]; then echo "ℹ️ 태그 이미 존재"; return; fi
  if [ "$2" = published ]; then echo "ℹ️ 이미 게시됨"; return; fi
  case "$1" in
    unset) echo "⚠️ 설정필요: 시크릿" ;;
    *) echo "✅ 준비완료" ;;   # set 또는 na(OIDC/none)
  esac
}

rr_secrets_state() { # <lang> → set|unset|na
  s="$(df_secrets "$1")"
  [ -z "$s" ] && { echo na; return; }
  for name in $s; do rr_secret_set "$name" || { echo unset; return; }; done
  echo set
}

rr_registry_state() { # <lang> → published|exists|unknown  (exists = 확인됨·미게시)
  url="$(df_check_url "$1")"
  [ -z "$url" ] && { echo exists; return; }   # go: 프록시 온디맨드 — 미게시로 간주
  if rr_url_exists "$url"; then
    echo published
  else
    # curl 부재/네트워크·타임아웃 실패(rc≠22)면 unknown, 확인된 4xx/5xx(rc=22)면 exists(미게시)
    rc=$?
    if [ "$rc" -eq 1 ]; then echo exists; else echo unknown; fi
  fi
}

rr_row() { # <lang>
  L="$1"
  sec="$(rr_secrets_state "$L")"
  reg="$(rr_registry_state "$L")"
  tagpat="$(printf "$(df_tag "$L")" '*')"
  if rr_tag_exists "$tagpat"; then tag=present; else tag=none; fi
  verdict="$(rr_verdict "$sec" "$reg" "$tag")"
  # 스펙§4: 시크릿 상태만으로는 "준비완료"라 부를 수 없는 auth 모델이 있다 — 남은 사람 작업이
  # API로 확인 불가한 경우다. auth 값별 case로 두어 새 auth 값이 생기면 여기에 추가하게 한다
  # (이미 게시됨/태그존재 판정이 우선하면 그대로 둔다).
  if [ "$verdict" = "✅ 준비완료" ]; then
    case "$(df_auth "$L")" in
      # OIDC(python/node/ruby): secrets=na라도 pending-publisher 사전등록은 조회 API가 없고
      # 미등록이면 배포가 실패한다.
      OIDC) verdict="ℹ️ 수동 확인: pending-publisher" ;;
      # split-token(php): PHP_SPLIT_TOKEN이 있어도 실제 게시 주체는 이 저장소가 아니라 미러
      # xzawed/keycloak-sdk-php다 — 미러·Packagist 등록 상태는 조회 API가 없어 사람이 확인한다(DEPLOY.md §2-D).
      split-token) verdict="ℹ️ 수동 확인: 미러 xzawed/keycloak-sdk-php + Packagist 등록" ;;
    esac
  fi
  # auth 폭 11 = 가장 긴 값 "split-token" 기준(좁히면 php 행만 컬럼이 밀린다).
  printf '%-8s auth=%-11s secrets=%-6s registry=%-10s tag=%-8s %s\n' "$L" "$(df_auth "$L")" "$sec" "$reg" "$tag" "$verdict"
}

rr_main() {
  langs="$*"; [ -z "$langs" ] && langs="$DEPLOY_LANGS"
  command -v gh   >/dev/null 2>&1 || echo "ℹ️ gh 미설치/미인증 — 시크릿 필요 언어는 'unset'(⚠️ 설정필요)로 표시됨" >&2
  command -v curl >/dev/null 2>&1 || echo "ℹ️ curl 미설치 — registry는 'unknown'으로 표시" >&2
  for L in $langs; do
    if df_known "$L"; then rr_row "$L"; else echo "?? unknown lang: $L" >&2; fi
  done
}

# --lib: 함수만 로드(테스트용). 그 외: main 실행.
#
# ⚠️ 소싱하는 쪽은 반드시 **소싱 전에** 위치인자를 설정해야 한다 — 인자를 dot에 직접 넘기면 안 된다:
#     set -- --lib
#     . "$SH"
# POSIX의 `.`(dot)은 파일명 외의 인자를 정의하지 않는다. bash는 호의로 위치인자를 설정하지만
# **dash는 조용히 무시한다**. 우분투 러너의 `/bin/sh`가 dash라, `. "$SH" --lib`로 쓰면 CI에서만
# `$1`이 비어 rr_main이 실행된다 — 그리고 rr_main은 0으로 끝나므로 테스트가 죽지도 않고
# **매 CI마다 아홉 레지스트리를 실제로 조회해 왔다**(이 저장소가 두 번 데인 "환경 의존 테스트"의
# 세 번째 사례). release-request.sh도 같은 가드를 쓴다 — 넷(스크립트 2·테스트 2)이 같은 방식이어야 한다.
[ "${1:-}" = "--lib" ] || rr_main "$@"
