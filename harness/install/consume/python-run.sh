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
# ⚠️ **출처를 기록한다**(이슈 #167). `PIP_EXTRA_INDEX_URL`은 기본 인덱스(PyPI)를 대체하지 않고
# **추가**하며, pip에는 인덱스 우선순위 개념이 없다 — 같은 좌표·같은 버전이 PyPI에도 있으면
# 거기서 받아도 설치는 초록이고, 그 순간 이 하네스가 검증하는 대상은 방금 만든 산출물이 아니라
# 공개 패키지다. 초록/빨강으로는 그 차이가 보이지 않으므로 **출처 자체를 관측**한다.
# `--report`는 설치된 각 배포의 `download_info.url`을 기계가독으로 남긴다(pip 22.2+).
if pip install --no-cache-dir --report /tmp/pip-report.json "keycloak-sdk==$PKG_VER" -r requirements.txt >/tmp/install.log 2>&1; then
  echo "[python-run] pip install 성공 — 출처 확인 중"
  # 오케스트레이터가 읽을 수 있게 SDK 자기 좌표의 다운로드 URL만 뽑아 남긴다(실패해도 비치명).
  python3 - <<'PY' >"$STATUS/provenance.txt" 2>/dev/null || true
import json
with open("/tmp/pip-report.json", encoding="utf-8") as f:
    rep = json.load(f)
for item in rep.get("install", []):
    if item.get("metadata", {}).get("name", "").replace("_", "-").lower() == "keycloak-sdk":
        print(item.get("download_info", {}).get("url", "<no url>"))
PY
  echo "[python-run] SDK 출처: $(cat "$STATUS/provenance.txt" 2>/dev/null)"
  # ⚠️ **출처 단언**(이슈 #167) — 기록만으로는 부족하다. 기록은 사람이 읽어야 동작하고 야간
  # 실행의 로그를 매일 읽는 사람은 없다. 판정(`installed.ok`)이 출처에 의존해야 한다.
  # 실측: 로컬 인덱스를 못 쓰는 상태에서도 pip은 PyPI에서 받아 exit 0으로 끝난다 — 그때
  # 이 단언이 없으면 하네스는 **공개 패키지를 검증하고 초록**이 된다.
  # ⚠️ **전부 로컬이라야 한다**(기록된 줄이 하나라도 로컬이 아니면 실패) + 빈 파일도 실패.
  # 여섯 언어가 같은 규칙을 쓴다 — "하나라도 로컬"은 부분 출처·시도 URL 혼입을 통과시킨다.
  if [ -s "$STATUS/provenance.txt" ] && ! grep -v -F "$REG" "$STATUS/provenance.txt" | grep -q .; then
    PROVENANCE_OK=1
  else
    PROVENANCE_OK=0
  fi
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[python-run] install OK (로컬 레지스트리에서 받았다)"
  else
    echo "[python-run] install FAILED — SDK를 로컬($REG)이 아닌 곳에서 받았다: $(cat "$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
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
