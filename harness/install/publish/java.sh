#!/usr/bin/env bash
# publish/java.sh — io.github.xzawed:keycloak-sdk 릴리스 좌표(0.1.0)를 로컬 staged .m2에 빌드한다
# (java 참조 구현). nginx(compose 서비스 mvn-repo)가 이 디렉터리를 그대로 정적 서빙하므로, verdaccio류
# "게시 API 호출"이 아니라 "파일을 올바른 위치에 만들어낸다"가 이 스크립트의 전부다(레지스트리 데몬에
# 대한 런타임 호출 없음 — 리서치 부록 §java "데몬 불요").
#
# 1) 빌드(Alpine maven:3.9-eclipse-temurin-21-alpine, 인터넷 필요 — Maven Central에서 의존성 해석;
#    install-net이 아니라 기본 브리지 네트워크): java/ 소스를 컨테이너 내부 쓰기 가능 위치로 복사한 뒤
#      mvn versions:set -DnewVersion=0.1.0 -DgenerateBackupPoms=false   (SNAPSHOT→릴리스 버전, 전체 reactor)
#      mvn -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true -Djacoco.skip=true \
#          -Dmaven.repo.local=/work/staging-m2 install
#    ⚠️ `deploy`가 아니라 `install`을 쓴다 — release 프로파일의 central-publishing-maven-plugin은
#    extensions=true로 `deploy` phase를 하이재킹해 Central Portal로 업로드를 시도하므로, 로컬 스테이징엔
#    `install`만 써야 한다(java/pom.xml 게차 주석·CLAUDE.md와 동일 결론).
#    ⚠️ -Djacoco.skip=true는 이 스크립트가 추가한 방어책이다: -DskipTests는 테스트 "실행"만 건너뛰므로
#    jacoco.exec가 생성되지 않는데, java/pom.xml 루트의 jacoco-maven-plugin `check` 실행(phase=verify,
#    라인/브랜치 90/85 게이트)이 install(=verify를 거침) 도중 동작할 수 있어, 이 스테이징 빌드에 한해
#    명시적으로 꺼서 실제 커버리지 검증(별도 `mvn verify`, CLAUDE.md 참고)과 이 게시 단계를 분리한다.
# 2) staging-m2는 **컨테이너 내부 경로**(-Dmaven.repo.local=/work/staging-m2)에 먼저 쓰고, 빌드가 끝난
#    뒤 `docker cp`로 호스트에 추출한다(node.sh의 build→extract 2단계와 동형). ⚠️ 처음엔 이 디렉터리를
#    호스트 바인드 마운트로 직접 잡아 봤으나, Maven Aether의 동시 다운로드 스레드들이 같은 nested 디렉터리
#    (예: org/apache/maven/maven-archiver/)를 동시에 `Files.createDirectories`하려다 Windows Docker
#    Desktop의 bind-mount 파일시스템에서 경쟁해 `NoSuchFileException`으로 빌드가 실패했다(실측 확인) —
#    컨테이너 로컬(overlay2) 파일시스템에 쓰고 빌드 완료 후 단일 `docker cp`로 추출하면 이 경쟁이 없다.
# 3) 산출물 검증: parent POM·BOM POM·core/auth/admin/keycloak-sdk jar(+keycloak-sdk의 sources/javadoc)
#    8개 경로 존재 확인.
#
# 멱등성: staging-m2를 매 실행 내용만 비우고(rm -rf가 아니라 find -mindepth 1 -delete — 아래 1/4 참고)
# 재빌드하므로(파일 기반 산출물이라 verdaccio류 409 충돌 개념 자체가 없음) 재실행은 그냥 최신 산출물로
# 덮어써진다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트

# lib.sh에서 hostpath()를 가져온다(Windows에서 docker에 넘길 호스트 경로를 D:/... 형식으로 변환).
# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

PKG_VER="0.1.0"
BUILD_IMAGE="maven:3.9-eclipse-temurin-21-alpine"
STAGING_DIR="$INSTALL_DIR/publish/out/java/staging-m2"
M2_CACHE_VOLUME="install-java-m2-cache"        # 명명된 도커 볼륨(재실행 시 의존성 재다운로드 절감 — 없으면 자동 생성)
BUILDER_CONTAINER="install-java-sdk-builder-$$"
# mvn 빌드(docker run)가 걸려도(느린 Central 미러·네트워크 단절 등) 오케스트레이터 전체가 무기한 블록되지
# 않도록 상한을 둔다. 환경변수로 조정 가능(느린 CI 러너 대비).
JAVA_BUILD_TIMEOUT_S="${JAVA_BUILD_TIMEOUT_S:-900}"

log() { printf '[publish/java] %s\n' "$*" >&2; }

cleanup() { docker rm -f "$BUILDER_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "1/4 이전 산출물 정리(staging-m2는 mvn-repo nginx 컨테이너가 bind-mount로 물고 있을 수 있어 디렉터리
자체를 rm -rf하지 않고 내용만 비운다 — 마운트된 디렉터리를 지우면 그 아래에서 마운트가 끊길 수 있다)"
mkdir -p "$STAGING_DIR"
find "$STAGING_DIR" -mindepth 1 -delete
docker rm -f "$BUILDER_CONTAINER" >/dev/null 2>&1 || true

log "2/4 빌드(컨테이너 로컬 파일시스템, ${JAVA_BUILD_TIMEOUT_S}s 타임아웃 가드) — versions:set 0.1.0 → mvn -Prelease install(인터넷 필요)"
if ! timeout "${JAVA_BUILD_TIMEOUT_S}s" docker run --name "$BUILDER_CONTAINER" \
    -v "$(hostpath "$REPO_ROOT/java"):/src:ro" \
    -v "$M2_CACHE_VOLUME:/root/.m2" \
    "$BUILD_IMAGE" sh -c "
      set -e
      mkdir -p /work
      cp -r /src /work/java
      find /work/java -type d -name target -prune -exec rm -rf '{}' +
      cd /work/java
      mvn -q -B versions:set -DnewVersion=$PKG_VER -DgenerateBackupPoms=false
      mvn -B -Prelease -DskipTests -Dmaven.test.skip=true -DskipITs=true -Dgpg.skip=true -Djacoco.skip=true \
        -Dmaven.repo.local=/work/staging-m2 install
    "; then
  log "빌드 실패(docker run, ${JAVA_BUILD_TIMEOUT_S}s 타임아웃 가드 초과 시에도 여기로 옴) — 위 mvn 로그 참고"
  exit 1
fi

log "3/4 빌드 산출물(staging-m2) 추출"
# mkdir을 빌드 시작 전이 아니라 여기(추출 직전)에서 한다: 이 하네스는 harness/install/publish/out/
# 아래를 여러 언어 태스크가 각자의 서브디렉터리(out/java, out/dotnet, out/php ...)에 병행해 쓰는 공유
# 트리다. mkdir과 추출 사이에 90초+ 걸리는 mvn 빌드가 끼어 있으면 그 창 동안 디렉터리가(다른
# 작업의 광범위한 정리 등으로) 사라질 여지가 실측으로 확인됐다 — mkdir을 추출 직전으로 옮겨 그 창을 사실상
# 없앤다.
#
# ⚠️ 리눅스 CI 전용 게차: 이 공유 트리(publish/out)는 다른 언어의 publish 스크립트가 루트로 도는
# 컨테이너에 바인드마운트로 넘긴다(예: dotnet.sh의 `-o /out`). 그 결과 out/ 이하가 root 소유가 되어
# runner(uid 1001)가 하위 디렉터리를 만들지 못하고, `docker cp`가
# `mkdir …/staging-m2/com: permission denied`로 실패한다(2026-07-08·07-09 야간 CI 실측).
# Windows Docker Desktop은 바인드마운트 소유권을 마스킹하므로 로컬에서는 재현되지 않는다.
#
# 두 가지로 막는다:
#  (1) 추출 직전에 out/ 트리의 소유권을 현재 사용자로 정규화한다(리눅스에서만 의미가 있다).
#  (2) `docker cp`(호스트 경로에 직접 mkdir) 대신 **tar 스트림**으로 받아 호스트 `tar`가 현재 사용자
#      권한으로 풀게 한다. 이렇게 하면 추출이 컨테이너가 만든 소유권에 의존하지 않는다.
OUT_ROOT="$INSTALL_DIR/publish/out"
log "추출 전 소유권 진단 (uid=$(id -u) gid=$(id -g))"
ls -ld "$OUT_ROOT" "$OUT_ROOT/java" "$STAGING_DIR" 2>&1 | sed 's/^/  /' || true

if [ "$(uname -s)" = "Linux" ]; then
  log "out/ 트리 소유권 정규화 (root 컨테이너 → $(id -u):$(id -g))"
  docker run --rm -v "$(hostpath "$OUT_ROOT"):/out" alpine:3.20 \
    chown -R "$(id -u):$(id -g)" /out || log "소유권 정규화 실패(무시하고 계속)"
fi

mkdir -p "$STAGING_DIR"
find "$STAGING_DIR" -mindepth 1 -delete

# `docker cp <container>:<path> -` 는 tar 아카이브를 stdout으로 스트림한다. 호스트 tar가 현재
# 사용자 권한으로 풀므로 컨테이너 측 소유권(root)이 호스트에 전파되지 않는다.
# --strip-components=1 은 아카이브 최상위 `staging-m2/` 를 벗긴다.
if ! docker cp "$BUILDER_CONTAINER:/work/staging-m2" - | tar -x --strip-components=1 -C "$STAGING_DIR"; then
  log "산출물 추출 실패(tar 스트림)"
  exit 1
fi

log "4/4 산출물 검증 — parent+BOM POM 및 core/auth/admin/keycloak-sdk(+sources/javadoc) 존재 확인"
EXPECTED=(
  "io/github/xzawed/keycloak-sdk-parent/${PKG_VER}/keycloak-sdk-parent-${PKG_VER}.pom"
  "io/github/xzawed/keycloak-sdk-bom/${PKG_VER}/keycloak-sdk-bom-${PKG_VER}.pom"
  "io/github/xzawed/keycloak-sdk-core/${PKG_VER}/keycloak-sdk-core-${PKG_VER}.jar"
  "io/github/xzawed/keycloak-sdk-auth/${PKG_VER}/keycloak-sdk-auth-${PKG_VER}.jar"
  "io/github/xzawed/keycloak-sdk-admin/${PKG_VER}/keycloak-sdk-admin-${PKG_VER}.jar"
  "io/github/xzawed/keycloak-sdk/${PKG_VER}/keycloak-sdk-${PKG_VER}.jar"
  "io/github/xzawed/keycloak-sdk/${PKG_VER}/keycloak-sdk-${PKG_VER}-sources.jar"
  "io/github/xzawed/keycloak-sdk/${PKG_VER}/keycloak-sdk-${PKG_VER}-javadoc.jar"
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

log "완료 — staging-m2 준비됨: $STAGING_DIR (compose 서비스 mvn-repo가 정적 서빙)"
