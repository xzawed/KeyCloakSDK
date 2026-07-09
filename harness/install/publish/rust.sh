#!/usr/bin/env bash
# publish/rust.sh — keycloak-sdk를 로컬 cargo-local-registry 디렉터리(볼륨)로 "게시"한다(rust 구현).
#
# node/python/php/ruby/dotnet/java와 달리 rust에는 상시 구동 레지스트리 *서비스*가 없다 — 소스 치환
# ([source.local] local-registry = "…")이 가리키는 **디렉터리**가 곧 레지스트리다(리서치 부록
# docs/superpowers/specs/2026-07-07-install-recipes-research.md §rust — go의 file GOPROXY와 동류라
# compose.install.yml에 rust 전용 서비스가 없다).
#
# 1) 빌드: publish/rust.Dockerfile(rust:1.88-alpine 빌더)이 keycloak-sdk를 cargo package(cargo
#    publish와 동일 tarball)하고, harness/apps/rust(axum 등 앱 전용 의존성 포함)를 클로저 매니페스트
#    삼아 cargo local-registry sync로 트랜지티브 의존성 전체를 미러링한 뒤, keycloak-sdk 자신(path
#    소스라 sync 미대상)을 .crate 복사 + index/ke/yc/keycloak-sdk에 v2 JSON 한 줄로 수동 주입한다.
# 2) 추출: 빌드 산출물(/opt/local-registry)을 docker create+cp로 호스트
#    harness/install/publish/out/rust-local-registry/ 로 뽑아낸다(node.sh의 tgz 추출과 동형 패턴).
#    consume 컨테이너는 이 디렉터리를 read-only 볼륨(-v …:/opt/local-registry:ro)으로 마운트해
#    `cargo build --offline`로 소비한다 — install-net 불필요(네트워크 서비스가 아니라 디렉터리 마운트).
#
# 멱등성: 상시 상태를 갖는 서버가 없으므로 매 실행이 곧 "재게시"다 — 산출 디렉터리를 통째로 비우고
# 다시 채운다(rm -rf 후 mkdir). node.sh의 409 EPUBLISHCONFLICT/unpublish 같은 별도 처리는 불필요.
# Docker 빌드 캐시 덕에 rust/ 소스가 바뀌지 않았다면 cargo package/generate-lockfile/sync 레이어는
# 재사용된다(툴체인 설치 레이어는 항상 캐시됨).
#
# ⚠️ 소요시간: Dockerfile 1단계가 `cargo package --no-verify`로 verify 빌드(SDK 전체 재컴파일)를
# 생략하므로, 이 publish는 더 이상 SDK를 컴파일하지 않는다 — .crate 생성 + 트랜지티브 클로저
# 다운로드(cargo local-registry sync)만 남아 수 분이면 끝난다(cargo-local-registry 설치 레이어는
# 항상 캐시). SDK의 실제 컴파일은 consume 단계(cargo build --offline)가 수행한다 — 예전엔 publish의
# verify 빌드 + consume 빌드로 SDK를 두 번 컴파일했으나 이제 한 번이다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트

# lib.sh에서 hostpath()를 가져온다(Windows에서 docker에 넘길 호스트 경로를 D:/... 형식으로 변환).
# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

BUILDER_IMAGE="install-rust-sdk-builder"
EXTRACT_DIR="$INSTALL_DIR/publish/out/rust-local-registry"
CRATE_FILE="keycloak-sdk-0.1.0.crate"

log() { printf '[publish/rust] %s\n' "$*" >&2; }

log "1/3 로컬 레지스트리 빌드 — publish/rust.Dockerfile(rust:1.88-alpine, cargo package + local-registry sync + 수동주입)"
if ! docker build -t "$BUILDER_IMAGE" -f "$(hostpath "$SCRIPT_DIR/rust.Dockerfile")" "$(hostpath "$REPO_ROOT")"; then
  log "빌드 실패(docker build) — publish/rust.Dockerfile 로그 참고"
  exit 1
fi

log "2/3 산출물(local-registry 디렉터리) 추출"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
EXTRACT_CONTAINER="install-rust-registry-extract-$$"
docker rm -f "$EXTRACT_CONTAINER" >/dev/null 2>&1 || true
if ! docker create --name "$EXTRACT_CONTAINER" "$BUILDER_IMAGE" >/dev/null; then
  log "추출용 컨테이너 생성 실패(docker create)"
  exit 1
fi
docker cp "$EXTRACT_CONTAINER:/opt/local-registry/." "$(hostpath "$EXTRACT_DIR")/"
docker rm -f "$EXTRACT_CONTAINER" >/dev/null 2>&1 || true

if [ ! -f "$EXTRACT_DIR/$CRATE_FILE" ] || [ ! -f "$EXTRACT_DIR/index/ke/yc/keycloak-sdk" ]; then
  log "예상 산출물을 찾을 수 없다: $EXTRACT_DIR/$CRATE_FILE 또는 $EXTRACT_DIR/index/ke/yc/keycloak-sdk"
  ls -la "$EXTRACT_DIR" >&2 || true
  exit 1
fi
log "로컬 레지스트리 확인됨: $EXTRACT_DIR ($CRATE_FILE + index/ke/yc/keycloak-sdk)"

log "3/3 완료 — keycloak-sdk 0.1.0 published to local cargo registry directory ($EXTRACT_DIR)"
