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
rr_url_exists() { # <url> → 0 if HTTP 200
  command -v curl >/dev/null 2>&1 || return 2
  curl -sfI "$1" >/dev/null 2>&1 || curl -sf "$1" >/dev/null 2>&1
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
    *) echo "✅ 준비완료" ;;   # set 또는 na(OIDC/none/webhook)
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
  if rr_url_exists "$url"; then echo published; else
    # curl 자체가 없거나 네트워크 실패면 unknown, 200 아님이면 exists(미게시)
    command -v curl >/dev/null 2>&1 && echo exists || echo unknown
  fi
}

rr_row() { # <lang>
  L="$1"
  sec="$(rr_secrets_state "$L")"
  reg="$(rr_registry_state "$L")"
  tagpat="$(printf "$(df_tag "$L")" '*')"
  if rr_tag_exists "$tagpat"; then tag=present; else tag=none; fi
  verdict="$(rr_verdict "$sec" "$reg" "$tag")"
  printf '%-8s auth=%-10s secrets=%-6s registry=%-10s tag=%-8s %s\n' "$L" "$(df_auth "$L")" "$sec" "$reg" "$tag" "$verdict"
}

rr_main() {
  langs="$*"; [ -z "$langs" ] && langs="$DEPLOY_LANGS"
  command -v gh   >/dev/null 2>&1 || echo "ℹ️ gh 미설치/미인증 — secrets는 '?(na)'로 표시" >&2
  command -v curl >/dev/null 2>&1 || echo "ℹ️ curl 미설치 — registry는 'unknown'으로 표시" >&2
  for L in $langs; do df_known "$L" && rr_row "$L" || echo "?? unknown lang: $L" >&2; done
}

# --lib: 함수만 로드(테스트용). 그 외: main 실행.
[ "${1:-}" = "--lib" ] || rr_main "$@"
