# 설치 검증용 소비 이미지(dotnet, net10.0) — 게시본의 `lib/net10.0` 을 SDK 10 소비자가 받아 quickstart 를 돈다.
# consume/dotnet.Dockerfile(SDK 8 · net8.0 = 이전 판 소비자)과 같은 파일 · 같은 엔트리포인트(dotnet-run.sh)를 쓰고 대상만
# 바꾼다(TFM=net10.0 · QUICKSTART_ONLY=1). 출처 단언과 자산 단언은 그 스크립트 하나가 소유한다 — 가드(test-harness-registries)가
# 보는 자리가 하나로 남는다. app boot · conformance 는 기본 소비자만 돈다(같은 포트 · 같은 신호 파일을 쓰게 되기 때문이다).
# 빌드 컨텍스트 = 리포지토리 루트(dotnet.Dockerfile 과 같다). 빌드타임 네트워크 의존 단계는 없다.
FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS app
WORKDIR /work

COPY harness/install/consume/dotnet/App.csproj ./app/App.csproj
COPY harness/apps/dotnet/Program.cs ./app/Program.cs
COPY harness/install/quickstart/dotnet/Quickstart.csproj ./quickstart/Quickstart.csproj
COPY harness/install/quickstart/dotnet/Program.cs ./quickstart/Program.cs
COPY harness/install/consume/dotnet-run.sh ./run.sh

ENV TFM=net10.0 QUICKSTART_ONLY=1
CMD ["sh", "/work/run.sh"]
