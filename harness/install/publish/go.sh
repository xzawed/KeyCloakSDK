#!/usr/bin/env bash
# publish/go.sh — github.com/xzawed/KeyCloakSDK/go 를 로컬 file GOPROXY 디렉터리에 "게시"한다(go 참조
# 구현: docs/superpowers/specs/2026-07-07-install-recipes-research.md §go 그대로).
#
# go 모듈에는 레지스트리 데몬이 없다 — GOPROXY 자체가 <module>/@v/<version>.{info,mod,zip,ziphash}
# 레이아웃의 단순 정적 디렉터리이므로, 그 디렉터리를 직접 합성한다:
#
# 1) 격리 합성 저장소: go/ 소스(호스트, 읽기전용 마운트)를 컨테이너 임시 경로의 "go/" 서브디렉토리로
#    복사한 신선한 git repo를 만들고 커밋 후 태그 go/v0.1.0을 찍는다(서브디렉토리 모듈이라 프리픽스
#    필수 — bare v0.1.0은 go 툴체인이 무시한다). ⚠️ 실제 리포지토리(D:\Source\KeyCloakSDK)에는 태그를
#    남기지 않는다 — 컨테이너 안의 휘발성 사본이라 재실행마다 자연히 멱등(레지스트리 데몬의 게시
#    이력이 없어 node의 409 EPUBLISHCONFLICT류 충돌도 애초에 없다).
# 2) 격리 HOME: `git config --global url."file:///tmp/repo".insteadOf "https://github.com/xzawed/KeyCloakSDK"`.
#    github.com/xzawed/KeyCloakSDK/go 모듈 경로는 이 저장소 URL 아래의 "go/" 서브디렉토리이므로,
#    insteadOf가 걸리면 go 툴체인은 file:///tmp/repo에서 git archive → go/ 서브트리 추출 → zip 합성을
#    공개 프록시(proxy.golang.org)와 동일한 알고리즘으로 수행한다.
# 3) `GOPROXY=direct GOSUMDB=off go mod download -x <module>@v0.1.0`이 $GOPATH/pkg/mod/cache/download/에
#    이미 GOPROXY 디렉터리 레이아웃(대문자→"!"+소문자 케이스인코딩 포함, go 툴체인이 자동 생성)으로
#    산출물을 남긴다 — 그 서브트리를 그대로 호스트 publish/out/go/proxy로 복사하면 소비자 컨테이너가
#    -v로 마운트해 GOPROXY=file:///proxy로 즉시 쓸 수 있다.
#
# 멱등성: PROXY_DIR을 매회 rm -rf 후 재합성.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트

# lib.sh에서 hostpath()를 가져온다(Windows에서 docker에 넘길 호스트 경로를 D:/... 형식으로 변환).
# lib.sh의 log()는 아래 로컬 log() 정의가 덮어쓰므로 [publish/go] 접두는 유지된다.
# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

MODULE_PATH="github.com/xzawed/KeyCloakSDK/go"
MODULE_ORIGIN="https://github.com/xzawed/KeyCloakSDK"
PKG_VER="0.1.0"
SRC_DIR="$REPO_ROOT/go"
PROXY_DIR="$INSTALL_DIR/publish/out/go/proxy"

log() { printf '[publish/go] %s\n' "$*" >&2; }

log "1/2 준비 — 이전 산출물 정리(publish/out/go/proxy)"
rm -rf "$PROXY_DIR"
mkdir -p "$PROXY_DIR"

log "2/2 file GOPROXY 합성 — 격리 git repo(go/v${PKG_VER} 태그) → go mod download → cache/download 추출"
if ! docker run --rm \
    -e MODULE_PATH="$MODULE_PATH" \
    -e MODULE_ORIGIN="$MODULE_ORIGIN" \
    -e PKG_VER="$PKG_VER" \
    -v "$(hostpath "$SRC_DIR"):/src:ro" \
    -v "$(hostpath "$PROXY_DIR"):/out" \
    golang:1.25-alpine sh -euc '
      apk add --no-cache git >/dev/null
      export HOME=/tmp/home GOPATH=/tmp/gopath GOSUMDB=off GOPROXY=direct GOTOOLCHAIN=local GIT_TERMINAL_PROMPT=0
      mkdir -p "$HOME" "$GOPATH"

      rm -rf /tmp/repo
      mkdir -p /tmp/repo/go
      cp -a /src/. /tmp/repo/go/
      cd /tmp/repo
      git -c init.defaultBranch=main init -q
      git config user.email "publish@install.local"
      git config user.name  "install-harness"
      git add -A
      git commit -q -m "go/v$PKG_VER"
      git tag "go/v$PKG_VER"
      # 격리 HOME(위 export) 안에서만 유효한 --global 설정 — 모듈 경로가 이 origin URL의 하위이면
      # file:///tmp/repo로 리다이렉트되어 실제 github.com에 나가지 않는다.
      git config --global url."file:///tmp/repo".insteadOf "$MODULE_ORIGIN"

      cd /tmp
      go mod download -x "$MODULE_PATH@v$PKG_VER"

      mkdir -p /out
      cp -a "$GOPATH/pkg/mod/cache/download/." /out/
    '; then
  log "file GOPROXY 합성 실패(위 로그 참고)"
  exit 1
fi

if [ ! -d "$PROXY_DIR/github.com" ]; then
  log "예상 GOPROXY 레이아웃을 찾을 수 없다: $PROXY_DIR/github.com"
  ls -la "$PROXY_DIR" >&2 || true
  exit 1
fi

log "완료 — ${MODULE_PATH}@v${PKG_VER} synthesized at $PROXY_DIR (file GOPROXY layout)"
