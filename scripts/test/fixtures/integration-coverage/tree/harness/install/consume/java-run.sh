#!/bin/sh
# 픽스처 — 실제 harness/install/consume/java-run.sh 의 퀵스타트 꼴. 장부의 하네스 소유 판정이 읽는다(실행하지 않는다).
set -u
STATUS="${STATUS_DIR:-/status}"
rm -f "$STATUS/quickstart.ok"
if KEYCLOAK_URL="$KC_SERVER_URL" \
   mvn -B -q -f /work/quickstart/pom.xml compile exec:java >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
fi
