#!/bin/sh
# 런타임 엔트리포인트(java 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 1) install: mvn-repo(nginx 정적 .m2)에 게시된 io.github.xzawed:keycloak-sdk@0.1.0을 저장소 해석
#    (실제 소비자 명령 — `mvn dependency:get`은 프로젝트 없이도 좌표 하나의 해석 가능 여부를 검증하는
#    표준 방법이다).
# 2) quickstart 스모크: 설치된 패키지로 실 Keycloak에 대해 quickstart 실행.
# 3) app boot: harness/apps/java/src(무변경)를 설치된 패키지 의존으로 spring-boot:run 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
#
# ⚠️ install(settings.xml의 mvn-repo 저장소) · quickstart · app boot 전부 이 스크립트(런타임)에서
# 수행한다 — consume/java.Dockerfile은 파일만 담고 빌드타임 네트워크 의존 단계가 없다(node-run.sh와
# 동형 설계 — BuildKit이 build-time custom --network을 지원하지 않기 때문).
set -u
STATUS="${STATUS_DIR:-/status}"
SETTINGS=/work/settings.xml
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

echo "[java-run] 1/3 install — mvn dependency:get -Dartifact=io.github.xzawed:keycloak-sdk:0.1.0 (mvn-repo)"
if mvn -s "$SETTINGS" -B -q dependency:get -Dartifact=io.github.xzawed:keycloak-sdk:0.1.0 >/tmp/install.log 2>&1; then
  : > "$STATUS/installed.ok"
  echo "[java-run] install OK"
else
  echo "[java-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[java-run] 2/3 quickstart 스모크 — mvn -f /work/quickstart/pom.xml compile exec:java"
if mvn -s "$SETTINGS" -B -q -f /work/quickstart/pom.xml compile exec:java >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[java-run] quickstart OK"
else
  echo "[java-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[java-run] 3/3 app boot — mvn -f /work/app/pom.xml spring-boot:run (APP_PORT=${APP_PORT:-8090})"
# -q를 빼서 컨테이너 로그(docker logs)에 Spring Boot 부팅 로그가 그대로 남게 한다(node의 exec node
# server.js와 동형 — 실패 진단은 여기서부터는 healthz 미응답으로 오케스트레이터가 판정).
exec mvn -s "$SETTINGS" -B -f /work/app/pom.xml spring-boot:run
