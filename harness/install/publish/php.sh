#!/usr/bin/env bash
# publish/php.sh — xzawed/keycloak-sdk를 로컬 Satis(정적 type:composer) 레지스트리에 게시한다(php 구현).
#
# 1) subtree-split: 모노레포 php/ 하위트리(vendor/.git 등 제외)를 격리 git repo로 복제해
#    `v0.1.0` 태그를 붙인다. 실 배포 태그 `php-v0.1.0`는 Composer VCS 드라이버가 서브디렉토리를
#    지원하지 않아 파싱하지 못하므로(부록 php절) 격리 repo + bare `v0.1.0`가 전제조건이다.
# 2) satis build: composer/satis:latest(php:8.4-cli-alpine 베이스, git 내장)로 registries/php-satis.json을
#    빌드해 정적 packages.json + p2 메타데이터 + dist zip을 산출한다. 이 단계는 로컬 파일만 다루므로
#    install-net 등 네트워크가 전혀 필요 없다(호스트/기본 브리지에서 충분 — java의 정적 .m2 스테이징과
#    동형: "레지스트리 서버 없이 산출물부터 만든다").
# 3) satis-web(nginx)이 이 산출물을 서빙하는 것은 run_lang_php()의 몫이다(publish 다음 순서 —
#    verdaccio(빈 상태로 먼저 기동 가능한 실서버)와 달리 satis는 정적 파일 서버라 콘텐츠가 있어야
#    헬스체크가 의미 있다).
#
# 멱등성: 매 실행마다 WORK_DIR을 통째로 재생성(rm -rf 후 재빌드)하므로 별도 "재게시 충돌" 처리가
# 필요 없다(정적 파일이라 verdaccio류의 서버측 상태 충돌이 애초에 존재하지 않는다).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트

# lib.sh에서 hostpath()를 가져온다(Windows에서 docker/git 등 네이티브 exe에 넘길 호스트 경로를
# D:/... 형식으로 변환). lib.sh의 log()는 아래 로컬 log() 정의가 덮어쓰므로 [publish/php] 접두는 유지된다.
# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

PKG_VER="0.1.0"
TAG="v${PKG_VER}"
WORK_DIR="$INSTALL_DIR/publish/out/php"
SRC_DIR="$WORK_DIR/php-src"
OUT_DIR="$WORK_DIR/output"
SATIS_JSON_SRC="$INSTALL_DIR/registries/php-satis.json"
SATIS_IMAGE="composer/satis:latest"

log() { printf '[publish/php] %s\n' "$*" >&2; }

# ⚠️ install-verify.sh가 MSYS_NO_PATHCONV=1을 전역 설정한다(컨테이너측 경로 보호 목적). 이는 docker.exe
# 뿐 아니라 git-for-windows의 git.exe(같은 msys 런타임 인자변환 경로를 타는 네이티브 exe)에도 적용되므로,
# 이 값이 설정된 상태에서 `git -C <posix경로>`를 그대로 넘기면 "cannot change to ...: No such file or
# directory"로 실패한다(실측 확인됨 — docker.exe와 동일한 근본원인, 그래서 동일한 hostpath() 처방).
# 따라서 아래 모든 host-side git 호출은 반드시 $(hostpath "$SRC_DIR")로 감싼다.
git_src() { git -C "$(hostpath "$SRC_DIR")" "$@"; }

log "1/4 subtree-split — php/ (vendor/.git 등 제외)를 격리 repo로 복제 후 ${TAG} 태그"
rm -rf "$WORK_DIR"
mkdir -p "$SRC_DIR" "$OUT_DIR"
cp -r "$REPO_ROOT/php/." "$SRC_DIR/"
rm -rf "$SRC_DIR/vendor" "$SRC_DIR/.phpunit.cache" "$SRC_DIR/composer.lock" "$SRC_DIR/clover.xml" "$SRC_DIR/.php-cs-fixer.cache"

if ! git_src init -q -b main \
  || ! git_src config user.email "harness@localhost" \
  || ! git_src config user.name "harness" \
  || ! git_src add -A \
  || ! git_src commit -q -m "harness release ${PKG_VER}" \
  || ! git_src tag "$TAG"; then
  log "subtree-split repo 생성 실패(git init/commit/tag)"
  exit 1
fi
log "subtree-split 완료: $(git_src rev-parse --short HEAD) tagged ${TAG}"

log "2/4 satis.json 배치(registries/php-satis.json — homepage=http://satis-web, dist 서빙 URL과 일치)"
cp "$SATIS_JSON_SRC" "$WORK_DIR/satis.json"

log "3/4 satis build — ${SATIS_IMAGE}(git 내장, 네트워크 불요 — 로컬 /build/php-src만 읽음)"
if ! docker run --rm -v "$(hostpath "$WORK_DIR"):/build" "$SATIS_IMAGE" build satis.json output; then
  log "satis build 실패(docker run ${SATIS_IMAGE})"
  exit 1
fi

if [ ! -f "$OUT_DIR/packages.json" ]; then
  log "예상 산출물을 찾을 수 없다: $OUT_DIR/packages.json"
  ls -la "$OUT_DIR" >&2 || true
  exit 1
fi
log "산출물 확인됨: $OUT_DIR/packages.json (+ p2/ + dist/*.zip)"

log "4/4 완료 — xzawed/keycloak-sdk@${PKG_VER} built for local Satis (satis-web이 뜨면 서빙 시작)"
