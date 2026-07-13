#!/usr/bin/env bash
# publish/kotlin.sh — io.github.xzawed:keycloak-sdk-kotlin:0.1.0을 로컬 staged .m2에 빌드한다(Gradle 참조 구현).
# nginx(compose 서비스 mvn-repo-kotlin)가 이 디렉터리를 그대로 정적 서빙하므로, "게시 API 호출"이 아니라
# "파일을 올바른 Maven 저장소 레이아웃 위치에 만들어낸다"가 이 스크립트의 전부다(레지스트리 데몬 불요 —
# java 참조 구현과 동일 모델). SDK 아티팩트만 게시하고, 전이 의존성(coroutines·keycloak-admin-client·
# nimbus·Ktor 등)은 소비자가 Maven Central에서 해석한다(install-net이 실인터넷을 통과 — java-settings.xml
# 게차 주석과 동일). Kotlin 좌표는 groupId=io.github.xzawed, artifactId=keycloak-sdk-kotlin이다.
#
# 1) 빌드(eclipse-temurin:21-jdk-alpine, 인터넷 필요 — Maven Central에서 SDK 의존성 해석; install-net이
#    아니라 기본 브리지 네트워크): kotlin/ 소스를 컨테이너 내부 쓰기 가능 위치로 복사한 뒤 gradle wrapper로
#      ./gradlew publishToMavenLocal -x test   (테스트 스킵; 서명은 in-memory 키 없으면 자동 비활성 —
#       build.gradle.kts의 signingKeyPresent 가드, 무서명 게시)
#    → ~/.m2/repository/io/github/xzawed/keycloak-sdk-kotlin/0.1.0/ 에 jar+pom+module(+sources/javadoc) 생성.
#    ⚠️ gradlew는 CRLF 스트립 후 `sh`로 호출한다(Windows 워킹트리 gradlew는 CRLF라 Alpine sh가 exit 127).
# 2) SDK 서브트리만 staging-m2로 복사(전이 의존성은 소비자가 Central에서 받으므로 게시 불요) 후, 컨테이너
#    로컬(overlay2)에서 빌드하고 단일 `docker cp`로 호스트에 추출한다(java.sh의 bind-mount 경쟁 회피 동형).
# 3) 산출물 검증: keycloak-sdk-kotlin-0.1.0.jar + .pom 존재 확인.
#
# 멱등성: staging-m2 내용만 비우고 재빌드(파일 기반이라 409 충돌 개념 없음).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트

# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

PKG_VER="0.1.0"
BUILD_IMAGE="eclipse-temurin:21-jdk-alpine"
STAGING_DIR="$INSTALL_DIR/publish/out/kotlin/staging-m2"
GRADLE_CACHE_VOLUME="install-kotlin-gradle-cache"   # 명명 볼륨(재실행 시 gradle·의존성 재다운로드 절감)
BUILDER_CONTAINER="install-kotlin-sdk-builder-$$"
KOTLIN_BUILD_TIMEOUT_S="${KOTLIN_BUILD_TIMEOUT_S:-900}"

log() { printf '[publish/kotlin] %s\n' "$*" >&2; }

cleanup() { docker rm -f "$BUILDER_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "1/4 이전 산출물 정리(마운트 유지 위해 디렉터리 자체가 아니라 내용만 비운다 — java.sh 동형)"
mkdir -p "$STAGING_DIR"
find "$STAGING_DIR" -mindepth 1 -delete
docker rm -f "$BUILDER_CONTAINER" >/dev/null 2>&1 || true

log "2/4 빌드(컨테이너 로컬 fs, ${KOTLIN_BUILD_TIMEOUT_S}s 가드) — ./gradlew publishToMavenLocal(인터넷 필요)"
if ! timeout "${KOTLIN_BUILD_TIMEOUT_S}s" docker run --name "$BUILDER_CONTAINER" \
    -v "$(hostpath "$REPO_ROOT/kotlin"):/src:ro" \
    -v "$GRADLE_CACHE_VOLUME:/root/.gradle" \
    "$BUILD_IMAGE" sh -c "
      set -e
      cp -r /src /work-kotlin
      cd /work-kotlin
      rm -rf build .gradle
      sed -i 's/\r\$//' gradlew
      sh ./gradlew --no-daemon publishToMavenLocal -x test
      mkdir -p /work/staging-m2/io/github/xzawed
      cp -r /root/.m2/repository/io/github/xzawed/keycloak-sdk-kotlin /work/staging-m2/io/github/xzawed/
    "; then
  log "빌드 실패(docker run) — 위 gradle 로그 참고"
  exit 1
fi

log "3/4 빌드 산출물(staging-m2) 추출(docker cp)"
mkdir -p "$STAGING_DIR"
docker cp "$BUILDER_CONTAINER:/work/staging-m2/." "$(hostpath "$STAGING_DIR")/"

log "4/4 산출물 검증 — keycloak-sdk-kotlin-${PKG_VER}.jar + .pom 존재 확인"
EXPECTED=(
  "io/github/xzawed/keycloak-sdk-kotlin/${PKG_VER}/keycloak-sdk-kotlin-${PKG_VER}.jar"
  "io/github/xzawed/keycloak-sdk-kotlin/${PKG_VER}/keycloak-sdk-kotlin-${PKG_VER}.pom"
)
MISSING=0
for f in "${EXPECTED[@]}"; do
  if [ ! -f "$STAGING_DIR/$f" ]; then
    log "예상 산출물 누락: $f"
    MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  log "필수 아티팩트 누락 — 게시 실패로 간주"
  exit 1
fi

log "완료 — staging-m2 준비됨: $STAGING_DIR (compose 서비스 mvn-repo-kotlin가 정적 서빙)"
