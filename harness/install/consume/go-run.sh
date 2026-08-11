#!/bin/sh
# 런타임 엔트리포인트(go 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 1) install: file GOPROXY(/proxy, publish/go.sh가 합성)에서 github.com/xzawed/KeyCloakSDK/go@v0.1.0을
#    실제 소비자 명령으로 설치(go get). deps(gocloak 등)는 GOPROXY 체인의 공개 폴백(proxy.golang.org)으로.
# 2) quickstart 스모크: 설치된 모듈로 실 Keycloak에 대해 quickstart 실행.
# 3) app boot: harness/apps/go/main.go를 설치된 모듈 의존으로 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
# SDK+의존성(gocloak 등)은 전부 순수 Go다 — 명시적으로 꺼둬서 향후 실수로 cgo 의존성이 섞여도
# (예: 새 전이 의존성이 cgo를 요구) 여기서 "혼란스러운 링크 실패" 대신 명확하게 실패하게 한다.
export CGO_ENABLED=0
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
# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다(기본값은 단독 실행용).
# publish/go.sh가 합성한 file GOPROXY의 태그(go/v$PKG_VER)와 반드시 같은 값이어야 한다.
PKG_VER="${PKG_VER:-0.1.0}"
cd /app || exit 1

# ⚠️ **출처를 "파일 존재"가 아니라 "실제 다운로드"로 관측한다**(이슈 #167). 예전 구현은 `/proxy`에
# `v<VER>.info`가 있는지만 봤는데, Go의 GOPROXY 체인은 **파일 단위로** 404에서 다음 프록시로
# 넘어간다(`file://` 프록시의 파일 부재 = 404). 그래서 `.info`만 있고 `.zip`이 없으면 모듈 본문을
# 공개 프록시가 서빙하는데도 "로컬이 출처"로 보고됐다(실측: `.info`만 남긴 프록시로 체인 실행 시
# `go mod download` 성공 + 옛 단언 통과). 지금은 **공개 폴백 없이** file 프록시만으로 모듈 전체를
# 받아본다 — 성공하면 그 뒤 체인 `go get`은 모듈 캐시가 단락시켜 공개에서 다시 받을 수 없다.
echo "[go-run] 0/3 출처 확인 — GOPROXY=file:///proxy 단독으로 모듈 전체(.info/.mod/.zip) 다운로드"
if GOPROXY="file:///proxy" go mod download "github.com/xzawed/KeyCloakSDK/go@v$PKG_VER" >/tmp/prov.log 2>&1; then
  PROVENANCE_OK=1
else
  PROVENANCE_OK=0
  echo "[go-run] file GOPROXY 단독 다운로드 실패(체인이라면 공개 프록시로 폴스루했을 상황):"; cat /tmp/prov.log
fi

echo "[go-run] 1/3 install — go get github.com/xzawed/KeyCloakSDK/go@v$PKG_VER github.com/Nerzal/gocloak/v13@v13.9.0"
# 실제 소비자 명령 형태(패키지@버전을 커맨드라인에 명시) — SDK를 file GOPROXY에서 $PKG_VER로 설치.
if go get "github.com/xzawed/KeyCloakSDK/go@v$PKG_VER" github.com/Nerzal/gocloak/v13@v13.9.0 >/tmp/install.log 2>&1 \
    && go build -o /tmp/app-bin . >>/tmp/install.log 2>&1 \
    && go build -o /tmp/quickstart-bin ./quickstart >>/tmp/install.log 2>&1; then
  echo "[go-run] go get/build 성공 — 출처 확인 중"
  # ⚠️ **출처를 기록한다**(이슈 #167). GOPROXY 체인(`file:///proxy,https://proxy.golang.org,direct`)의
  # `,`는 404/410에서만 다음으로 넘어가므로 **앞이 가지고 있으면 앞이 이긴다** — 즉 file 프록시가 그
  # 버전을 가지고 있는지가 곧 출처다(go는 받은 모듈 옆에 프록시 URL을 남기지 않아 사후 조회가 안 된다).
  # 동시에 **공개 프록시도 그 버전을 아는지**를 함께 잰다: 둘 다 참인 순간부터 file 합성이 실패해도
  # 공개 프록시가 받아줘 초록이 되고, 그 사각지대가 영구화된다(go/v* 태그를 미는 순간 그렇게 된다).
  # 위 0/3 단계의 관측 결과를 리포트용으로 남긴다(판정은 이미 PROVENANCE_OK에 있다).
  {
    if [ "$PROVENANCE_OK" = 1 ]; then
      echo "file:///proxy 단독으로 모듈 전체를 받았다 — 출처는 file GOPROXY다"
    else
      echo "file:///proxy 단독 다운로드 실패 — 체인이라면 공개 프록시가 서빙했을 것이다"
    fi
    # ⚠️ busybox wget에는 `-S`가 없다(alpine 베이스) — `--spider`의 종료코드로 존재 여부를 잰다.
    # ⚠️ `-T`가 없으면 응답하지 않는 피어에서 busybox 기본 900초를 기다린다(실측: 150초 지나도 미종료).
    if wget -q -T 5 --spider "https://proxy.golang.org/github.com/xzawed/!key!cloak!s!d!k/go/@v/v${PKG_VER}.info" 2>/dev/null; then
      echo "공개 프록시: v${PKG_VER} **보유** — file 합성이 실패하면 폴스루가 조용히 성공할 수 있는 상태다"
    else
      echo "공개 프록시: v${PKG_VER} 미보유 — 지금은 폴스루해도 실패한다(go/v* 태그를 미는 순간 위 줄로 바뀐다)"
    fi
  } >"$STATUS/provenance.txt" 2>/dev/null || true
  echo "[go-run] SDK 출처: $(tr '\n' ' | ' <"$STATUS/provenance.txt" 2>/dev/null)"
  # ⚠️ **출처 단언**(이슈 #167) — file 프록시가 그 버전을 갖고 있지 않으면 체인이 공개 프록시로
  # 폴스루한 것이고, 그때 검증 대상은 방금 합성한 산출물이 아니다. 지금은 공개 프록시가 이 모듈을
  # 모르므로 폴스루는 곧 실패지만, `go/v*` 태그를 미는 순간 폴스루가 **조용히 성공**하게 된다.
  if grep -q '^file:///proxy (' "$STATUS/provenance.txt" 2>/dev/null; then
    PROVENANCE_OK=1
  else
    PROVENANCE_OK=0
  fi
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[go-run] install OK (file GOPROXY가 서빙했다)"
  else
    echo "[go-run] install FAILED — file GOPROXY가 v$PKG_VER를 갖고 있지 않다(공개 프록시 폴스루): $(tr '\n' ' | ' <"$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
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
