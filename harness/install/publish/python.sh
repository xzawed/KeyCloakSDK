#!/usr/bin/env bash
# publish/python.sh — keycloak-sdk를 로컬 pypiserver 레지스트리에 게시한다(python, node 참조구현 패턴 복제).
#
# 1) 빌드: python:3.12-alpine 컨테이너에서 python/ 를 바인드마운트해 `pip install build && python -m build`를
#    실행한다 — 산출물은 호스트의 python/dist/(keycloak_sdk-0.1.0-py3-none-any.whl + .tar.gz)에 그대로
#    남는다(순수 파이썬 패키지라 node의 멀티스테이지 빌드+docker cp 추출 패턴이 필요 없다 — build가 직접
#    바인드마운트에 쓴다). ⚠️ 이 단계는 빌드 백엔드(hatchling)를 PyPI에서 받으므로 정상 DNS 환경이
#    필요하다(host의 기본 docker 브리지 — install-net에 붙일 필요 없음. 레지스트리 서비스명 해석이
#    필요한 단계가 아니기 때문).
# 2) 게시: python:3.12-alpine 컨테이너에서 install-net에 접속해 더미 자격증명(TWINE_USERNAME/PASSWORD)으로
#    pypiserver에 twine upload한다. pypiserver 컨테이너가 `--overwrite`로 기동되므로(compose.install.yml)
#    재게시가 자연히 멱등이다 — node의 unpublish→재게시 재시도 로직이 필요 없다(서버가 덮어쓰기를 그냥
#    허용).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트
PYTHON_DIR="$REPO_ROOT/python"

# lib.sh에서 hostpath()를 가져온다(Windows에서 docker에 넘길 호스트 경로를 D:/... 형식으로 변환).
# lib.sh의 log()는 아래 로컬 log() 정의가 덮어쓰므로 [publish/python] 접두는 유지된다.
# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

PKG_VER="0.1.0"
PKG_SPEC="keycloak-sdk==${PKG_VER}"
WHEEL="keycloak_sdk-${PKG_VER}-py3-none-any.whl"
SDIST="keycloak_sdk-${PKG_VER}.tar.gz"
REGISTRY_URL="http://pypiserver:8080"

log() { printf '[publish/python] %s\n' "$*" >&2; }

log "1/3 SDK 빌드 — python:3.12-alpine에서 python -m build(python/ 바인드마운트, 정상 DNS 필요)"
rm -f "$PYTHON_DIR/dist/$WHEEL" "$PYTHON_DIR/dist/$SDIST"
if ! docker run --rm -v "$(hostpath "$PYTHON_DIR"):/sdk" -w /sdk python:3.12-alpine \
    sh -c "pip install --no-cache-dir build && python -m build"; then
  log "SDK 빌드 실패(docker run python -m build)"
  exit 1
fi

if [ ! -f "$PYTHON_DIR/dist/$WHEEL" ] || [ ! -f "$PYTHON_DIR/dist/$SDIST" ]; then
  log "예상 빌드 산출물을 찾을 수 없다: $PYTHON_DIR/dist/{$WHEEL,$SDIST}"
  ls -la "$PYTHON_DIR/dist" >&2 || true
  exit 1
fi
log "빌드 산출물 확인됨: $PYTHON_DIR/dist/$WHEEL, $PYTHON_DIR/dist/$SDIST"

log "2/3 게시 — twine upload (pypiserver --overwrite라 재게시도 자연히 성공)"
if ! PUBLISH_OUT=$(docker run --rm --network install-net \
    -v "$(hostpath "$PYTHON_DIR/dist"):/dist" \
    -e TWINE_USERNAME=x -e TWINE_PASSWORD=x \
    python:3.12-alpine sh -c "
      set -e
      pip install --no-cache-dir twine
      twine upload --repository-url $REGISTRY_URL/ /dist/*
    " 2>&1); then
  echo "$PUBLISH_OUT"
  log "게시 실패(twine upload) — 로그 참고"
  exit 1
fi
echo "$PUBLISH_OUT"

log "3/3 완료 — $PKG_SPEC published to $REGISTRY_URL"
