# 설치 검증용 소비 이미지(java 참조 구현) — harness/java... 아니라 리포지토리의 java/(SDK 소스 트리)
# 접근 없이, nginx(compose 서비스 mvn-repo)가 정적 서빙하는 staged .m2에서 저장소 해석으로 설치한
# `io.github.xzawed:keycloak-sdk@0.1.0`을 조립한다. harness/apps/java/src(App.java·HarnessController.java·
# application.properties)는 무변경으로 그대로 재사용한다(빌드 컨텍스트 = 리포지토리 루트 — COPY 경로
# 때문) — 다만 그 pom.xml(0.1.0-SNAPSHOT 로컬 reactor 참조)은 BOM import + 무버전 keycloak-sdk로
# 교체한 전용 pom(java-app-pom.xml)을 대신 쓴다(node가 harness/apps/node/package.json 대신 최소
# 신규 package.json을 쓴 것과 동형 패턴).
#
# ⚠️ 설계: install(mvn-repo 저장소 해석)·quickstart 스모크(keycloak)·app boot는 전부 **런타임**
# (엔트리포인트 run.sh)에 install-net에서 수행한다 — 빌드타임엔 네트워크 의존 단계가 없다(BuildKit이
# build-time custom `--network`를 지원하지 않으므로 기본 빌더로 빌드되도록, 그리고 app-boot/conformance와
# 동일한 install-net 서비스명 해석 경로를 재사용하려는 의도). 상태(installed/quickstartOk)는 호스트 마운트
# `/status`의 마커 파일로 회수한다 — 컨테이너 생존 여부와 무관하게 오케스트레이터가 읽는다.
FROM maven:3.9-eclipse-temurin-21-alpine AS app
WORKDIR /work

COPY harness/install/consume/java-settings.xml ./settings.xml

# quickstart 스모크(별도 최소 Maven 프로젝트 — java/ 소스 트리와 무관, SDK를 저장소 해석으로 설치해 사용).
COPY harness/install/consume/java-quickstart-pom.xml ./quickstart/pom.xml
COPY harness/install/quickstart/java/io ./quickstart/src/main/java/io

# harness app(설치된 패키지 소비 pom) + 무변경 소스(App.java/HarnessController.java/application.properties).
COPY harness/install/consume/java-app-pom.xml ./app/pom.xml
COPY harness/apps/java/src ./app/src

COPY harness/install/consume/java-run.sh ./run.sh

EXPOSE 8090
# 런타임 엔트리포인트: install(저장소 해석) → quickstart 스모크 → app boot(전부 install-net에서).
CMD ["sh", "/work/run.sh"]
