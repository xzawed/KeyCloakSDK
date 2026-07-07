#!/bin/sh
# 런타임 엔트리포인트(node 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 1) install: Verdaccio에 게시된 @xzawed/keycloak-sdk@0.1.0을 레지스트리 설치(실제 소비자 명령).
# 2) quickstart 스모크: 설치된 패키지로 실 Keycloak에 대해 quickstart 실행.
# 3) app boot: harness/apps/node/server.js를 설치된 패키지 의존으로 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
STATUS="${STATUS_DIR:-/status}"
REG="${REGISTRY_URL:-http://verdaccio:4873}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

echo "[node-run] 1/3 install — npm install @xzawed/keycloak-sdk@0.1.0 express --registry $REG"
# 실제 소비자 명령 형태(패키지@버전을 커맨드라인에 명시) — SDK를 레지스트리에서 0.1.0으로 설치.
if npm install @xzawed/keycloak-sdk@0.1.0 express --registry "$REG" >/tmp/install.log 2>&1; then
  : > "$STATUS/installed.ok"
  echo "[node-run] install OK"
else
  echo "[node-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[node-run] 2/3 quickstart 스모크 — node quickstart.mjs"
if node quickstart.mjs >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[node-run] quickstart OK"
else
  echo "[node-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[node-run] 3/3 app boot — node server.js (APP_PORT=${APP_PORT:-8090})"
exec node server.js
