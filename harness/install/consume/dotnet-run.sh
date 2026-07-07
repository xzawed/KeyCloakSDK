#!/bin/sh
# 런타임 엔트리포인트(dotnet 참조 구현은 node) — install-net에서 실행된다(docker run --network install-net).
# 1) nuget.config 배치: local(BaGetter) 소스를 "추가"(치환 아님) + packageSourceMapping
#    (Xzawed.Keycloak.Sdk만 local, *는 nuget.org) + allowInsecureConnections(http 소스라서 필요).
# 2) install: 실 소비자 명령 `dotnet add package Xzawed.Keycloak.Sdk --version 0.1.0`을 App
#    프로젝트에 실행한다(⚠️ -s로 단일 소스 치환하지 않는다 — 그러면 Duende.IdentityModel 등
#    전이 의존성이 nuget.org로 해석되지 못해 실패한다. packageSourceMapping이 정답).
# 3) quickstart 스모크: 별도 콘솔 프로젝트에도 같은 방식으로 설치 후 `dotnet run`으로 실 Keycloak에
#    대해 client-credentials 발급 → validate를 구동한다.
# 4) app boot: harness/apps/dotnet/Program.cs(무변경 COPY)를 설치된 패키지로 publish → 실행.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
STATUS="${STATUS_DIR:-/status}"
REG="${REGISTRY_URL:-http://bagetter:8080/v3/index.json}"
PKG_VER="0.1.0"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

echo "[dotnet-run] 1/4 nuget.config 배치 — local(BaGetter) 소스 추가 + packageSourceMapping"
cat > /work/nuget.config <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="local" value="${REG}" allowInsecureConnections="true" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="local">
      <package pattern="Xzawed.Keycloak.Sdk" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
EOF
# /work/nuget.config는 /work/app과 /work/quickstart 양쪽의 조상 디렉터리라, 두 프로젝트 모두
# 이 파일 하나를 상속한다(dotnet CLI가 cwd에서 위로 올라가며 nuget.config를 찾는 관용 — 파일을
# 중복 배치할 필요 없음).

echo "[dotnet-run] 2/4 install — dotnet add package Xzawed.Keycloak.Sdk --version $PKG_VER (app 프로젝트)"
# 실제 소비자 명령 형태(패키지@버전 명시, -s 없음 — packageSourceMapping이 소스를 가른다).
if (cd /work/app && dotnet add package Xzawed.Keycloak.Sdk --version "$PKG_VER") >/tmp/install.log 2>&1; then
  : > "$STATUS/installed.ok"
  echo "[dotnet-run] install OK"
else
  echo "[dotnet-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[dotnet-run] 3/4 quickstart 스모크 — dotnet add package(quickstart 프로젝트) + dotnet run"
if (cd /work/quickstart && dotnet add package Xzawed.Keycloak.Sdk --version "$PKG_VER" && dotnet run) >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[dotnet-run] quickstart OK"
else
  echo "[dotnet-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[dotnet-run] 4/4 app boot — dotnet publish(app) → dotnet App.dll (APP_PORT=${APP_PORT:-8090})"
if ! (cd /work/app && dotnet publish App.csproj -c Release -o /work/app/out) >/tmp/publish.log 2>&1; then
  echo "[dotnet-run] app publish FAILED"; cat /tmp/publish.log
  cp /tmp/publish.log "$STATUS/publish.log" 2>/dev/null || true
  sleep 3600; exit 1
fi
exec dotnet /work/app/out/App.dll
