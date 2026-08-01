#!/usr/bin/env bash
# publish/ruby.sh — keycloak-sdk gem을 로컬 정적 gem repo(gemserver)에 게시한다(ruby 참조 구현).
#
# 1) 빌드: registries/ruby-gemserver.Dockerfile 이미지(webrick + rubygems-generate_index 사전설치)로
#    `gem build keycloak-sdk.gemspec`을 실행해 .gem을 뽑는다(순수 Ruby — 네이티브 컴파일 불요).
#    LICENSE·README.md는 ruby/에 이미 존재(gemspec의 spec.files가 참조 — 부록 게차 그대로).
# 2) 게시: 같은 이미지에서 .gem을 ./publish/ruby-repo/gems/에 쓰고 그 자리에서
#    `gem generate_index --directory /repo`로 레거시 Marshal 인덱스를 (재)생성한다.
#    ./publish/ruby-repo는 compose.install.yml의 gemserver 서비스가 그대로 마운트해 서빙하는
#    호스트 디렉터리다 — webrick은 요청마다 디스크를 읽으므로 재게시에 서버 재시작이 필요 없다.
# 멱등성: 레거시 인덱스는 매번 디렉터리 전체를 스캔해 전면 재생성하므로, npm/Verdaccio류의
# 409 EPUBLISHCONFLICT 개념이 없다 — 같은 버전을 몇 번 재게시해도 안전하다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트

# lib.sh에서 hostpath()를 가져온다(Windows에서 docker에 넘길 호스트 경로를 D:/... 형식으로 변환).
# lib.sh의 log()는 아래 로컬 log() 정의가 덮어쓰므로 [publish/ruby] 접두는 유지된다.
# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

PKG_VER="${PKG_VER:-0.1.0}"
GEM_FILE="keycloak-sdk-${PKG_VER}.gem"
TOOL_IMAGE="install-ruby-gem-tool"
# gemserver(compose.install.yml)가 서빙하는 것과 동일한 호스트 디렉터리 — 경로 문자열까지 일치해야
# 두 프로세스(이 스크립트의 1회성 컨테이너 vs 장수명 gemserver 컨테이너)가 같은 데이터를 본다.
REPO_DIR="$INSTALL_DIR/publish/ruby-repo"

log() { printf '[publish/ruby] %s\n' "$*" >&2; }

log "1/3 gem 빌드/게시 도구 이미지 준비(registries/ruby-gemserver.Dockerfile 재사용 — webrick + rubygems-generate_index)"
if ! docker build -f "$(hostpath "$INSTALL_DIR/registries/ruby-gemserver.Dockerfile")" \
    -t "$TOOL_IMAGE" "$(hostpath "$INSTALL_DIR/registries")"; then
  log "도구 이미지 빌드 실패(docker build)"
  exit 1
fi

mkdir -p "$REPO_DIR/gems"

log "2/3 gem build — ruby/keycloak-sdk.gemspec → $REPO_DIR/gems/$GEM_FILE"
# -w /src: Gem::Specification의 `Dir["lib/**/*.rb", "LICENSE", "README.md"]`는 gemspec 파일 위치가
# 아니라 프로세스 cwd 기준으로 평가되므로(require_relative와 달리) 반드시 /src에서 실행해야 한다.
if ! docker run --rm \
    -v "$(hostpath "$REPO_ROOT/ruby"):/src:ro" \
    -v "$(hostpath "$REPO_DIR"):/repo" \
    -w /src \
    "$TOOL_IMAGE" sh -c "
      set -e
      gem build keycloak-sdk.gemspec --output /repo/gems/$GEM_FILE
    "; then
  log "gem build 실패"
  exit 1
fi

if [ ! -f "$REPO_DIR/gems/$GEM_FILE" ]; then
  log "예상 .gem을 찾을 수 없다: $REPO_DIR/gems/$GEM_FILE"
  ls -la "$REPO_DIR/gems" >&2 || true
  exit 1
fi
log "빌드 산출물 확인됨: $REPO_DIR/gems/$GEM_FILE"

log "3/3 게시 — generate_index --directory /repo (레거시 Marshal 인덱스 전면 재생성)"
if ! docker run --rm \
    -v "$(hostpath "$REPO_DIR"):/repo" \
    "$TOOL_IMAGE" gem generate_index --directory /repo; then
  log "generate_index 실패"
  exit 1
fi

log "완료 — keycloak-sdk@${PKG_VER} published to $REPO_DIR (gemserver가 실시간 서빙, 서버 재시작 불필요)"
