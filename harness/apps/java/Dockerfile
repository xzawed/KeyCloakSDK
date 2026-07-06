# build context = repo root
# ⚠️ Alpine(musl) 빌드/런타임 이미지 사용: Debian/glibc 이미지(maven:3.9-eclipse-temurin-21,
# eclipse-temurin:21-jre)는 Docker Desktop(Windows) 내장 DNS 프록시가 Maven Central
# (repo.maven.apache.org → Fastly CNAME 체인)의 CNAME 응답을 glibc 리졸버에 실패로 돌려줘
# 빌드가 DNS 에러로 막힌다(dotnet/node/python 앱에서 동일 패턴 실측). musl은 CI(Linux 네이티브
# Docker)에서도 문제없이 동작하므로 이식성 있는 근본 해결책이다(호스트별 extra_hosts/IP 고정 불필요).
FROM maven:3.9-eclipse-temurin-21-alpine AS build
WORKDIR /build
# 1) SDK 리액터를 로컬 .m2에 설치(앱이 io.github.xzawed:keycloak-sdk 해석) — 테스트/IT 스킵
COPY java/ ./java/
RUN mvn -f java/pom.xml -q -DskipTests -DskipITs install
# 2) 하네스 앱 빌드(Spring Boot fat jar)
COPY harness/apps/java/ ./app/
RUN mvn -f app/pom.xml -q -DskipTests package

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
# Alpine(busybox)엔 useradd가 없다 — adduser(-D: 시스템 계정, 홈 디렉터리 스킵)를 사용한다.
RUN adduser -D -u 10001 app
COPY --from=build /build/app/target/*.jar ./app.jar
USER app
EXPOSE 8090
ENTRYPOINT ["java", "-jar", "app.jar"]
