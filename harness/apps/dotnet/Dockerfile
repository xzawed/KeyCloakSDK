# build context = repo root (docker-compose.yml의 context: ..)
# ⚠️ Alpine(musl) SDK 빌드 이미지 사용: Debian/glibc SDK 이미지는 Docker Desktop(Windows)
# 내장 DNS 프록시가 api.nuget.org의 CNAME 체인 응답을 glibc 리졸버에 실패(NXDOMAIN류)로
# 돌려줘 `dotnet restore`가 NU1301로 막힌다(musl은 동일 환경에서 정상 해석 — dig/getent
# 실측 비교로 확인). musl은 CI(Linux 네이티브 Docker)에서도 문제없이 동작하므로 이식성 있는
# 근본 해결책이다(호스트별 extra_hosts/IP 고정 불필요).
FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS build
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
