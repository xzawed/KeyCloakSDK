#!/bin/sh
# 런타임 엔트리포인트(go 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 1) install: file GOPROXY(/proxy, publish/go.sh가 합성)에서 github.com/xzawed/KeyCloakSDK/go@v0.1.0을
#    실제 소비자 명령으로 설치(go get). deps(gocloak 등)는 GOPROXY 체인의 공개 폴백(proxy.golang.org)으로.
# 2) quickstart 스모크: 설치된 모듈로 실 Keycloak에 대해 quickstart 실행.
# 3) app boot: harness/apps/go/main.go를 설치된 모듈 의존으로 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
STATUS="${STATUS_DIR:-/status}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

# ⚠️ GOPRIVATE는 절대 설정하지 않는다 — 설정 시 GONOPROXY로 전이돼 direct VCS 폴백을 강제해 file
# GOPROXY(/proxy)를 우회하고 게차대로 실패한다(부록 §go). GOSUMDB=off는 로컬 합성 모듈이 공개
# sumdb에 없어 필요(공개 프록시로 폴스루되는 deps도 동일하게 미검증 — 게차대로 로컬 전용 완화).
export GOPROXY="${GOPROXY:-file:///proxy,https://proxy.golang.org,direct}"
export GOSUMDB=off
export GOTOOLCHAIN=local
export GOPATH=/root/go
cd /app || exit 1

echo "[go-run] 1/3 install — go get github.com/xzawed/KeyCloakSDK/go@v0.1.0 github.com/Nerzal/gocloak/v13@v13.9.0"
# 실제 소비자 명령 형태(패키지@버전을 커맨드라인에 명시) — SDK를 file GOPROXY에서 0.1.0으로 설치.
if go get github.com/xzawed/KeyCloakSDK/go@v0.1.0 github.com/Nerzal/gocloak/v13@v13.9.0 >/tmp/install.log 2>&1 \
    && go build -o /tmp/app-bin . >>/tmp/install.log 2>&1 \
    && go build -o /tmp/quickstart-bin ./quickstart >>/tmp/install.log 2>&1; then
  : > "$STATUS/installed.ok"
  echo "[go-run] install OK"
else
  echo "[go-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[go-run] 2/3 quickstart 스모크 — /tmp/quickstart-bin"
if /tmp/quickstart-bin >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[go-run] quickstart OK"
else
  echo "[go-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[go-run] 3/3 app boot — /tmp/app-bin (APP_PORT=${APP_PORT:-8090})"
exec /tmp/app-bin
