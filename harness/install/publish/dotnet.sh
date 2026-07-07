#!/usr/bin/env bash
# publish/dotnet.sh — Xzawed.Keycloak.Sdk를 로컬 BaGetter 레지스트리에 게시한다(dotnet 참조 구현은 node).
#
# 1) 팩(pack): Alpine dotnet SDK 이미지(docker run — 별도 빌더 이미지를 만들 필요 없이 공식
#    mcr.microsoft.com/dotnet/sdk:8.0-alpine을 직접 사용)에서 dotnet/ 서브트리를 마운트해
#    `dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release -o /out
#     -p:Version=0.1.0 -p:ContinuousIntegrationBuild=true`를 실행한다. 이 단계는 기본 브리지
#    네트워크(실 nuget.org에 대한 dotnet restore가 필요 — Alpine/musl이라 Windows Docker Desktop
#    glibc-DNS 게차를 피한다)로 충분하다 — install-net(BaGetter) 접속은 불필요/무관.
#    ⚠️ 마운트는 읽기전용으로 하지 않는다(실측 확인됨) — obj/bin은 프로젝트 기본 경로 그대로 두고
#    (dotnet/.gitignore가 이미 커버), BaseIntermediateOutputPath/BaseOutputPath를 컨테이너 내부
#    경로로 리다이렉트하면 SDK의 기본 Compile glob 제외 패턴(`$(BaseIntermediateOutputPath)**`)이
#    새 경로 기준으로 재계산되어 호스트에 이미 남아있는(로컬 `dotnet build`로 생성된) 구
#    obj/Release/net8.0/*.cs가 더 이상 제외되지 않고 그대로 컴파일에 잡혀 CS0579(중복 Assembly*
#    Attribute) 빌드 실패가 난다 — 기본 경로를 그대로 써서 매번 그 자리를 새로 덮어쓰게 둔다(이
#    리포의 로컬 `dotnet build` 관용과 동일 — dotnet/.gitignore가 obj/bin을 이미 무시한다).
#    ⚠️ EnableSourceLink=false + TreatWarningsAsErrors=false: 이 마운트엔 .git이 없어(dotnet/
#    서브트리만 마운트) SourceLink가 경고를 낼 수 있고, Directory.Build.props의
#    TreatWarningsAsErrors=true가 그 경고를 오류로 승격한다 — harness/apps/dotnet/Dockerfile이
#    이미 같은 이유로 EnableSourceLink=false를 쓰는 선례를 그대로 따른다.
# 2) 게시: 동일 이미지로 install-net에 접속해 BaGetter(NuGet V3 HTTP)에 `dotnet nuget push`.
#    --skip-duplicate로 멱등 재실행(node처럼 unpublish→재게시가 필요 없음 — 레지스트리가 스킵 처리).
#    ⚠️ mcr.microsoft.com/dotnet/sdk:8.0-alpine(SDK 8.0.422)의 `dotnet nuget push`엔
#    `--allow-insecure-connections` 옵션 자체가 없다(실측 확인 — `--help`에 미열거, 지정 시
#    "Unrecognized option" 오류로 즉시 실패. 이 플래그는 더 최신 NuGet 클라이언트에서 추가됐다).
#    대신 `-s|--source`에 **URL이 아니라 nuget.config의 소스 key 이름**을 넘기고, 그 nuget.config에
#    `allowInsecureConnections="true"`를 선언해야 한다(공식 문서가 권장하는 폴백과 일치 — CLI로는
#    이 옵션을 켤 수 없다는 NuGet/Home#14047 논의와도 일치). push_once가 OUT_DIR에 최소
#    nuget.config를 쓰고 `--source local`로 참조한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"       # harness/install
HARNESS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"      # harness
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"        # 리포지토리 루트

# lib.sh에서 hostpath()를 가져온다(Windows에서 docker에 넘길 호스트 경로를 D:/... 형식으로 변환).
# lib.sh의 log()는 아래 로컬 log() 정의가 덮어쓰므로 [publish/dotnet] 접두는 유지된다.
# shellcheck source=../lib.sh
. "$INSTALL_DIR/lib.sh"

PKG_NAME="Xzawed.Keycloak.Sdk"
PKG_VER="0.1.0"
NUPKG="${PKG_NAME}.${PKG_VER}.nupkg"
BUILDER_IMAGE="mcr.microsoft.com/dotnet/sdk:8.0-alpine"
OUT_DIR="$INSTALL_DIR/publish/out"
REGISTRY_URL="http://bagetter:8080/v3/index.json"
API_KEY="LOCALKEY"

log() { printf '[publish/dotnet] %s\n' "$*" >&2; }

log "1/3 SDK 팩(dotnet pack) — Alpine SDK 이미지, 기본 브리지 네트워크로 nuget.org restore"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
if ! docker run --rm \
    -v "$(hostpath "$REPO_ROOT/dotnet"):/src/dotnet" \
    -v "$(hostpath "$OUT_DIR"):/out" \
    -w /src \
    "$BUILDER_IMAGE" \
    dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj \
      -c Release -o /out \
      -p:Version="$PKG_VER" \
      -p:ContinuousIntegrationBuild=true \
      -p:EnableSourceLink=false \
      -p:TreatWarningsAsErrors=false; then
  log "SDK 팩 실패(dotnet pack) — 위 로그 참고"
  exit 1
fi

if [ ! -f "$OUT_DIR/$NUPKG" ]; then
  log "예상 nupkg를 찾을 수 없다: $OUT_DIR/$NUPKG"
  ls -la "$OUT_DIR" >&2 || true
  exit 1
fi
log "빌드 산출물 확인됨: $OUT_DIR/$NUPKG"

# push용 nuget.config — 이름 있는 소스("local")로 등록하고 allowInsecureConnections를 그 소스에 건다
# (위 주석 참고 — CLI --allow-insecure-connections는 이 SDK 버전에 없다). OUT_DIR을 cwd로 두고
# push하면 dotnet CLI가 이 파일을 상위탐색으로 자동 발견한다.
cat > "$OUT_DIR/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="local" value="$REGISTRY_URL" allowInsecureConnections="true" />
  </packageSources>
</configuration>
EOF

# push_once — install-net에서 BaGetter(V3)에 게시한다.
#   --source local           위 nuget.config의 소스 key(URL 아님 — allowInsecureConnections 적용은
#                             이름 있는 소스를 통해서만 유효하다).
#   --skip-duplicate         재실행 시 409(이미 존재) 를 성공으로 처리(멱등).
#   --no-symbols              .snupkg(심볼 패키지)는 게시하지 않는다 — BaGetter의 심볼서버 설정
#                             여부와 무관하게 안정적으로 만든다(이 하네스는 심볼 소비를 검증하지 않음).
push_once() {
  docker run --rm --network install-net \
    -v "$(hostpath "$OUT_DIR"):/out" \
    -w /out \
    "$BUILDER_IMAGE" \
    dotnet nuget push "/out/$NUPKG" \
      --source local \
      --api-key "$API_KEY" \
      --skip-duplicate \
      --no-symbols
}

log "2/3 게시 시도"
if PUSH_OUT=$(push_once 2>&1); then
  echo "$PUSH_OUT"
  log "게시 성공"
else
  echo "$PUSH_OUT"
  log "게시 실패 — 위 로그 참고(--skip-duplicate가 재실행 충돌을 이미 처리하므로 추가 재시도는 없다)"
  exit 1
fi

log "3/3 완료 — ${PKG_NAME}@${PKG_VER} pushed to $REGISTRY_URL"
