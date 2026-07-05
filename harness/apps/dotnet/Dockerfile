# build context = repo root (docker-compose.yml의 context: ..)
# ⚠️ api.nuget.org의 DNS 해석은 docker-compose.yml의 app-dotnet build.extra_hosts를
# 참고(로컬 Docker Desktop DNS 프록시 CNAME/glibc 버그 우회 — 상세 사유는 그쪽 주석).
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
# ProjectReference 대상(SDK)과 앱 소스를 상대경로 보존해 복사(tests 제외)
COPY dotnet/Directory.Build.props ./dotnet/
COPY dotnet/src/ ./dotnet/src/
COPY harness/apps/dotnet/ ./harness/apps/dotnet/
# EnableSourceLink=false: .git 미포함 컨텍스트에서 SourceLink 경고 방지
# TreatWarningsAsErrors=false: 하네스 빌드가 SDK-측 엄격도에 걸리지 않도록(SDK는 자체 CI에서 클린)
RUN dotnet publish harness/apps/dotnet/App.csproj -c Release -o /out \
    -p:EnableSourceLink=false -p:TreatWarningsAsErrors=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
# mcr.microsoft.com/dotnet/aspnet:8.0 이미 비-root 사용자 `app`(uid 1654)을 내장하고 있다
# (adduser로 재생성 시도 시 "user already exists"로 실패 — 실측 확인) — 생성 없이 재사용한다.
COPY --from=build /out/ ./
RUN chown -R app /app
USER app
EXPOSE 8090
ENTRYPOINT ["dotnet", "App.dll"]
