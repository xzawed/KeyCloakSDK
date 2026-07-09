# 설치 검증용 소비 이미지(Kotlin 참조 구현) — kotlin/(SDK 소스 트리) 접근 없이, nginx(compose 서비스
# mvn-repo-kotlin)가 정적 서빙하는 staged .m2에서 저장소 해석으로 설치한 `io.github.xzawed:keycloak-sdk-kotlin@0.1.0`
# (게시된 릴리스 패키지)을 조립한다. harness/apps/kotlin/src(Application.kt·무변경)를 boot 앱으로 그대로
# 재사용하고, build.gradle.kts만 SDK 의존성 소스를 mavenLocal→mvn-repo-kotlin 레지스트리로 교체한 전용
# 프로젝트(consume/kotlin-app)를 쓴다(java가 java-app-pom.xml을 쓴 것과 동형 패턴).
#
# ⚠️ 설계: install(mvn-repo-kotlin 저장소 해석)·quickstart 스모크·app boot는 전부 **런타임**(엔트리포인트
# kotlin-run.sh)에 install-net에서 수행한다 — 빌드타임엔 네트워크 의존 단계가 없다(BuildKit이 build-time
# custom --network을 지원하지 않으므로). 상태(installed/quickstartOk)는 호스트 마운트 /status 마커로 회수한다.
FROM eclipse-temurin:21-jdk-alpine AS app
WORKDIR /work

# 소비자 gradle 프로젝트(레지스트리 의존·wrapper) — build.gradle.kts/settings.gradle.kts/gradlew.
COPY harness/install/consume/kotlin-app/ ./app/
# harness app 소스(무변경 재사용) — Application.kt(boot 앱, io.github.xzawed.harness 패키지).
COPY harness/apps/kotlin/src ./app/src
# quickstart 소스(설치 스모크 main) — 같은 패키지 경로에 추가해 함께 컴파일.
COPY harness/install/quickstart/kotlin/Quickstart.kt ./app/src/main/kotlin/io/github/xzawed/harness/Quickstart.kt

COPY harness/install/consume/kotlin-run.sh ./run.sh

EXPOSE 8090
# 런타임 엔트리포인트: install(저장소 해석) → quickstart 스모크 → app boot(전부 install-net에서).
CMD ["sh", "/work/run.sh"]
