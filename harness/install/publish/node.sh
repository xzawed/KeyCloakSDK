#!/usr/bin/env bash
# publish/node.sh — @xzawed/keycloak-sdk를 로컬 Verdaccio 레지스트리에 게시한다(node 참조 구현).
#
# 1) 빌드: harness/apps/node/Dockerfile의 기존 "sdk" 빌드 스테이지(npm ci && npm run build && npm pack
#    — ⚠️ build가 pack보다 먼저, prepack 훅이 없어 생략하면 빈 dist/가 게시됨)를 --target sdk로
#    재사용해 tgz를 뽑아낸다. harness/apps/node/ 아래는 이 태스크에서 변경하지 않는다 — 이미 존재하는
#    빌드 스테이지를 재사용(reuse)할 뿐이다.
# 2) 게시: Alpine node 컨테이너에서 install-net에 접속해 더미 `_authToken`으로 Verdaccio에 tgz를
#    그대로 게시한다(바이트 동일 — `npm publish <tgz>`).
# 멱등성: 재실행 시 409 EPUBLISHCONFLICT면 `npm unpublish --force` 후 1회 재게시.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트

# lib.sh에서 hostpath()를 가져온다(Windows에서 docker에 넘길 호스트 경로를 D:/... 형식으로 변환).
# lib.sh의 log()는 아래 로컬 log() 정의가 덮어쓰므로 [publish/node] 접두는 유지된다.
# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

PKG_VER="${PKG_VER:-0.1.0}"
PKG_SPEC="@xzawed/keycloak-sdk@${PKG_VER}"
TARBALL="xzawed-keycloak-sdk-${PKG_VER}.tgz"
BUILDER_IMAGE="install-node-sdk-builder"
EXTRACT_DIR="$INSTALL_DIR/publish/out"
REGISTRY_URL="http://verdaccio:4873"

log() { printf '[publish/node] %s\n' "$*" >&2; }

log "1/4 SDK 빌드 — harness/apps/node/Dockerfile의 'sdk' 스테이지 재사용(npm ci && npm run build && npm pack)"
if ! docker build --target sdk -t "$BUILDER_IMAGE" -f "$(hostpath "$HARNESS_DIR/apps/node/Dockerfile")" "$(hostpath "$REPO_ROOT")"; then
  log "SDK 빌드 실패(docker build --target sdk)"
  exit 1
fi

log "2/4 빌드 산출물(tgz) 추출"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
EXTRACT_CONTAINER="install-node-sdk-extract-$$"
docker rm -f "$EXTRACT_CONTAINER" >/dev/null 2>&1 || true
if ! docker create --name "$EXTRACT_CONTAINER" "$BUILDER_IMAGE" >/dev/null; then
  log "추출용 컨테이너 생성 실패(docker create)"
  exit 1
fi
docker cp "$EXTRACT_CONTAINER:/pack/." "$(hostpath "$EXTRACT_DIR")/"
docker rm -f "$EXTRACT_CONTAINER" >/dev/null 2>&1 || true

if [ ! -f "$EXTRACT_DIR/$TARBALL" ]; then
  log "예상 tarball을 찾을 수 없다: $EXTRACT_DIR/$TARBALL"
  ls -la "$EXTRACT_DIR" >&2 || true
  exit 1
fi
log "빌드 산출물 확인됨: $EXTRACT_DIR/$TARBALL"

# publish_once — Alpine node 컨테이너에서 install-net을 통해 Verdaccio에 tgz를 게시한다.
# ENEEDAUTH는 npm 클라이언트측 사전검사라 실제 인증 여부와 무관하게 더미 토큰이 필요하다
# (registries/verdaccio.yaml의 packages.*.publish: $all 덕에 서버는 익명으로 처리).
# --no-provenance: node/package.json의 publishConfig.provenance=true를 그대로 두면 로컬(비-CI)
# 환경에서 npm이 provenance 생성을 시도하다 실패한다 — 부록 원 명령엔 없으나 이 SDK의 package.json
# 설정 때문에 필요해진 로컬 전용 오버라이드(CLI 플래그가 publishConfig보다 우선).
publish_once() {
  docker run --rm --network install-net \
    -v "$(hostpath "$EXTRACT_DIR"):/work" \
    node:22-alpine sh -c "
      set -e
      echo '//verdaccio:4873/:_authToken=local-anon' > ~/.npmrc
      npm publish /work/$TARBALL --registry $REGISTRY_URL --access public --no-provenance
    "
}

# unpublish_once — 멱등 재실행 경로(409 EPUBLISHCONFLICT)에서만 호출.
unpublish_once() {
  docker run --rm --network install-net \
    node:22-alpine sh -c "
      set -e
      echo '//verdaccio:4873/:_authToken=local-anon' > ~/.npmrc
      npm unpublish '$PKG_SPEC' --registry $REGISTRY_URL --force
    "
}

log "3/4 게시 시도"
if PUBLISH_OUT=$(publish_once 2>&1); then
  echo "$PUBLISH_OUT"
  log "게시 성공"
else
  echo "$PUBLISH_OUT"
  if echo "$PUBLISH_OUT" | grep -qiE "EPUBLISHCONFLICT|E409|409 Conflict|already present|cannot publish over"; then
    log "409 EPUBLISHCONFLICT 감지 — 이전 실행의 잔존 게시로 간주, unpublish --force 후 재게시"
    if ! UNPUB_OUT=$(unpublish_once 2>&1); then
      echo "$UNPUB_OUT"
      log "unpublish 실패 — 그래도 재게시를 시도한다(레지스트리가 이미 정리돼 있을 수 있음)"
    else
      echo "$UNPUB_OUT"
    fi
    if RETRY_OUT=$(publish_once 2>&1); then
      echo "$RETRY_OUT"
      log "재게시 성공"
    else
      echo "$RETRY_OUT"
      log "재게시도 실패 — 게시 단계 포기"
      exit 1
    fi
  else
    log "게시 실패(EPUBLISHCONFLICT 아님) — 로그 참고"
    exit 1
  fi
fi

log "4/4 완료 — $PKG_SPEC published to $REGISTRY_URL"
