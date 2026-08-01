#!/bin/sh
# 런타임 엔트리포인트(python — node 참조 구현 패턴 복제) — install-net에서 실행된다
# (docker run --network install-net).
# 1) install: pypiserver에 게시된 keycloak-sdk==0.1.0을 레지스트리 설치(실제 소비자 명령) + app 의존성.
# 2) quickstart 스모크: 설치된 패키지로 실 Keycloak에 대해 quickstart 실행.
# 3) app boot: harness/apps/python/main.py(FastAPI)를 설치된 패키지 의존으로 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
STATUS="${STATUS_DIR:-/status}"
REG="${REGISTRY_URL:-http://pypiserver:8080}"
# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다(기본값은 단독 실행용).
PKG_VER="${PKG_VER:-0.1.0}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

# PIP_TRUSTED_HOST는 포트 없는 호스트명이어야 pip가 인식한다(리서치 부록 §python 게차 — "pypiserver:8080"
# 이면 pip가 무시한다). REG(예: http://pypiserver:8080)에서 스킴/포트/경로를 모두 벗겨 호스트명만 남긴다.
REG_HOST="${REG#*://}"
REG_HOST="${REG_HOST%%/*}"
REG_HOST="${REG_HOST%%:*}"
export PIP_EXTRA_INDEX_URL="${REG}/simple/"
export PIP_TRUSTED_HOST="$REG_HOST"

echo "[python-run] 1/3 install — pip install keycloak-sdk==$PKG_VER -r requirements.txt (extra-index=$PIP_EXTRA_INDEX_URL trusted-host=$PIP_TRUSTED_HOST)"
# 실제 소비자 명령 형태(패키지==버전을 커맨드라인에 명시) — SDK를 레지스트리에서 $PKG_VER로 설치.
if pip install --no-cache-dir "keycloak-sdk==$PKG_VER" -r requirements.txt >/tmp/install.log 2>&1; then
  : > "$STATUS/installed.ok"
  echo "[python-run] install OK"
else
  echo "[python-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[python-run] 2/3 quickstart 스모크 — python3 quickstart.py"
if python3 quickstart.py >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[python-run] quickstart OK"
else
  echo "[python-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[python-run] 3/3 app boot — uvicorn main:app (APP_PORT=${APP_PORT:-8090})"
exec uvicorn main:app --host 0.0.0.0 --port "${APP_PORT:-8090}"
