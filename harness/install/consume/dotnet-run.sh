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
# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다(기본값은 단독 실행용).
PKG_VER="${PKG_VER:-0.1.0}"
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
  # ⚠️ **출처 단언**(이슈 #167 · 계획서 S-A2). `packageSourceMapping`이 구조적 격리이긴 하지만
  # node·rust도 구조 격리를 갖고서 게이트를 함께 둔다(`5fe1c9c`·`d275579`) — 이 리포의 결정은
  # **격리는 단언을 대체하지 않는다**이다. dotnet만 아홉 중 유일하게 게이트가 없어 `dotnet add
  # package`가 exit 0이면 어디서 받았든 `installed.ok`를 썼다.
  #
  # 관측 지점: NuGet은 글로벌 패키지 폴더의 `.nupkg.metadata`에 **패키지별 해석 피드**를 남긴다.
  # 실측(이 PC 캐시 샘플): `{"version":2,"contentHash":"…","source":"https://api.nuget.org/v3/index.json"}`.
  # ⚠️ 다른 후보는 전부 출처를 안 남긴다 — `dotnet list package --format json`은 id/버전만,
  # `obj/project.assets.json`의 `project.restore.sources`는 **설정된 피드 목록**이지 해석 결과가
  # 아니며(rust가 `cargo metadata.source`를 기각한 것과 같은 함정), `.nuget.g.props`는 캐시 폴더뿐이다.
  # ⚠️ NuGet은 폴더명에서 id·버전을 **소문자화**한다.
  _nupkgs="${NUGET_PACKAGES:-$HOME/.nuget/packages}"
  _vlc="$(printf '%s' "$PKG_VER" | tr 'A-Z' 'a-z')"
  _meta="$_nupkgs/xzawed.keycloak.sdk/$_vlc/.nupkg.metadata"
  sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_meta" >"$STATUS/provenance.txt" 2>/dev/null || true
  [ -s "$STATUS/provenance.txt" ] || echo "<.nupkg.metadata에서 source를 찾지 못했다: $_meta>" >"$STATUS/provenance.txt"
  echo "[dotnet-run] SDK 출처: $(tr '\n' ' ' <"$STATUS/provenance.txt" 2>/dev/null)"
  # ⚠️ `$REG`는 origin이 아니라 **인덱스 URL 전체**(`http://bagetter:8080/v3/index.json`)이고
  # `.nupkg.metadata`의 `source`도 설정된 그 문자열 그대로다 — 그래서 접두가 아니라 **정확일치**가
  # 옳다. `grep -x`(줄 전체 일치)로 음성 조건도 같은 강도로 맞춘다.
  # >>> provenance-gate
  _src_local=0
  if [ -n "$REG" ] && [ -s "$STATUS/provenance.txt" ]; then
    while IFS= read -r _pline || [ -n "$_pline" ]; do
      [ "$_pline" = "$REG" ] && { _src_local=1; break; }
    done <"$STATUS/provenance.txt"
  fi
  if [ -n "$REG" ] && [ -s "$STATUS/provenance.txt" ] \
     && ! grep -v -F -x "$REG" "$STATUS/provenance.txt" | grep -q . \
     && [ "$_src_local" = 1 ]; then
    PROVENANCE_OK=1
  else
    PROVENANCE_OK=0
  fi
  # <<< provenance-gate
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[dotnet-run] install OK (로컬 레지스트리 $REG 가 서빙했다)"
  else
    echo "[dotnet-run] install FAILED — SDK를 로컬($REG)이 아닌 곳에서 받았거나 출처 기록이 없다: $(tr '\n' ' ' <"$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
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
