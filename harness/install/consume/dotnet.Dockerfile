# 설치 검증용 소비 이미지(dotnet) — harness/dotnet(SDK 소스 트리) 접근 없이, BaGetter에 게시된
# `Xzawed.Keycloak.Sdk@0.1.0`을 레지스트리 설치로 조립한다. harness/apps/dotnet/Program.cs는
# 무변경으로 그대로 재사용한다(빌드 컨텍스트 = 리포지토리 루트 — Program.cs COPY 경로 때문).
#
# ⚠️ 설계: install(bagetter)·quickstart 스모크(keycloak)·app boot(빌드 포함)는 전부 **런타임**
# (엔트리포인트 run.sh)에 install-net에서 수행한다(node 참조 구현과 동형 — BuildKit이 build-time
# custom --network을 지원하지 않으므로 기본 빌더로 빌드되도록, 그리고 app-boot/conformance와 동일한
# install-net 서비스명 해석 경로를 재사용하려는 의도). dotnet은 컴파일 언어라 "설치"가 곧 복원
# (restore)이므로 node보다도 더 이 설계가 자연스럽다 — 빌드타임엔 네트워크 의존 단계가 전혀 없다.
# 상태(installed/quickstartOk)는 호스트 마운트 `/status`의 마커 파일로 회수한다(컨테이너 생존 여부와
# 무관하게 오케스트레이터가 읽는다).
FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS app
WORKDIR /work

# App 프로젝트 스캐폴딩(SDK PackageReference 없음 — 런타임에 실제 소비자 명령
# `dotnet add package Xzawed.Keycloak.Sdk --version 0.1.0`으로 추가한다, dotnet-run.sh).
COPY harness/install/consume/dotnet/App.csproj ./app/App.csproj
COPY harness/apps/dotnet/Program.cs ./app/Program.cs

# quickstart 콘솔 프로젝트(dotnet/examples에 quickstart 부재 — harness/install/quickstart/dotnet/에 신설).
COPY harness/install/quickstart/dotnet/Quickstart.csproj ./quickstart/Quickstart.csproj
COPY harness/install/quickstart/dotnet/Program.cs ./quickstart/Program.cs

COPY harness/install/consume/dotnet-run.sh ./run.sh

EXPOSE 8090
# 런타임 엔트리포인트: nuget.config 배치 → install(add package) → quickstart 스모크 → app boot(전부 install-net에서).
CMD ["sh", "/work/run.sh"]
