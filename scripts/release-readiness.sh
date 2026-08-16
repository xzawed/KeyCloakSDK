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
# ⚠️ **User-Agent가 없으면 crates.io가 403을 준다 — 그리고 403은 "미게시"로 읽힌다.**
# crates.io API는 UA 없는 요청을 거절하는데(실측: UA 없음 403 / UA 있음 200 / 없는 크레이트 404),
# 아래 판정은 확인된 4xx를 "미게시"로 취급하므로 **이미 게시된 크레이트가 미게시로 보고됐다**
# (`rust … registry=exists`가 crates.io에 `keycloak-sdk 0.1.0-rc.1`이 살아 있는 동안 계속 표시됐다).
# 되돌릴 수 없는 행위 직전에 보는 도구가 반대로 말한 것이라, UA는 선택이 아니라 정확성의 일부다.
# ⚠️ 자가테스트는 curl을 스텁으로 대체해 **순수 판정 로직만** 보므로 이 부류를 구조적으로 못 잡는다.
RR_UA="kcsdk-release-readiness (+https://github.com/xzawed/KeyCloakSDK)"
rr_url_exists() { # <url> → exit 0=게시됨(2xx) 1=미게시(4xx/5xx, curl -f rc=22) 2=unknown(curl 부재·네트워크/타임아웃 실패)
  command -v curl >/dev/null 2>&1 || return 2
  if curl -sfI -A "$RR_UA" "$1" >/dev/null 2>&1; then return 0; fi
  # HEAD가 일부 레지스트리(405 등)에서 미지원일 수 있어 GET으로 재확인 — 최종 판정은 이 결과 기준.
  # ⚠️ `if curl …; then …; fi` 뒤에서 `$?`를 읽으면 안 된다 — 그건 curl이 아니라 **if 문 자체의**
  # 종료코드이고, 조건이 거짓이고 else가 없으면 POSIX는 그걸 0으로 정의한다. 그래서 예전 코드는
  # 4xx에서 rc=0을 보고 `-eq 22` 분기를 영영 타지 못했다 — **"미게시(exists)" 판정이 죽어 있었고**
  # 모든 미게시 좌표가 `unknown`으로 보고됐다(실측: 404 URL에 buggy rc=0 / fixed rc=22).
  curl -sf -A "$RR_UA" "$1" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
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
    # ⚠️ "준비완료"가 아니라 "저장소측 OK"다. 이 스크립트는 시크릿 **이름**·공개 레지스트리 URL·
    # 로컬 태그만 본다 — 토큰 뒤의 **레지스트리 계정 상태**는 볼 수 없다. 예전 문구(`✅ 준비완료`)를
    # 믿고 rust 태그를 밀었다가 게이트를 다 통과한 뒤 crates.io가 400으로 거부한 적이 있다
    # ("A verified email address is required to publish"). 아무것도 게시되지 않았지만 태그는 소모됐다.
    *) echo "✅ 저장소측 OK" ;;   # set 또는 na(OIDC/none)
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
  # ⚠️ 조회 URL이 없다는 것은 "미게시"가 아니라 **확인하지 않았다**이다. 예전에는 여기서
  # exists(=확인됨·미게시)를 냈는데, 그건 한 번도 조회하지 않은 좌표에 대해 판정을 지어내는
  # 것이라 go가 실제로 게시된 뒤에도 계속 미게시로 보고했다. 되돌릴 수 없는 행위 직전에 보는
  # 도구에서 "모른다"를 "안전하다"로 반올림하지 않는다(crates.io 403을 미게시로 읽은 것과 같은 부류).
  # 지금은 아홉 전부 URL이 있어 이 분기는 새 언어를 추가하고 df_check_url을 빠뜨렸을 때만 열린다.
  [ -z "$url" ] && { echo unknown; return; }
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
  if [ "$verdict" = "✅ 저장소측 OK" ]; then
    case "$(df_auth "$L")" in
      # OIDC(python/node/ruby): secrets=na라도 pending-publisher 사전등록은 조회 API가 없고
      # 미등록이면 배포가 실패한다.
      OIDC) verdict="ℹ️ 수동 확인: pending-publisher" ;;
      # split-token(php): PHP_SPLIT_TOKEN이 있어도 실제 게시 주체는 이 저장소가 아니라 미러
      # xzawed/keycloak-sdk-php다 — 미러·Packagist 등록 상태는 조회 API가 없어 사람이 확인한다(DEPLOY.md §2-D).
      split-token) verdict="ℹ️ 수동 확인: 미러 xzawed/keycloak-sdk-php + Packagist 등록" ;;
      # api-token(rust/dotnet): 시크릿 **이름**이 있다는 것만 확인했다. 토큰이 유효한지, 스코프가
      # 맞는지, 그 토큰이 속한 계정이 게시 가능한 상태인지는 값 없이 볼 수 없다.
      # 실제로 rust가 여기서 걸렸다 — crates.io는 **이메일 인증**을 요구하고, 그건 계정 UI에만 있다.
      api-token) verdict="ℹ️ 수동 확인: 레지스트리 계정(이메일 인증·토큰 유효·스코프)" ;;
      # maven-gpg(java/kotlin): 시크릿 4종이 다 있어도 네임스페이스 검증·GPG 공개키의 키서버 배포는
      # 조회 API가 없고, 게다가 워크플로는 Portal **스테이징까지만** 한다 — 공개는 사람이 누른다.
      maven-gpg) verdict="ℹ️ 수동 확인: 네임스페이스 검증·GPG 키서버 배포·Portal 수동 Publish" ;;
      # none(go): 계정도 시크릿도 없다 — 태그가 곧 게시라 저장소측 확인이 실제로 전부다.
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
