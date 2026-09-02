# build context = repo root
# ⚠️ Alpine(musl) 빌드/런타임 이미지: Debian/glibc 이미지는 Docker Desktop(Windows) 내장 DNS 프록시가
# Maven Central(Fastly CNAME 체인)을 glibc 리졸버에 실패로 돌려줘 의존성 다운로드가 막힌다(java/dotnet/
# node/python 앱에서 동일 패턴 실측). musl은 CI(Linux 네이티브 Docker)에서도 무해한 이식성 해결책이다.
FROM eclipse-temurin:21-jdk-alpine AS build
WORKDIR /build
ENV GRADLE_USER_HOME=/root/.gradle
# 1) Kotlin SDK를 로컬 .m2에 publish(앱이 build.gradle.kts가 선언한 좌표를 해석) — 테스트 스킵.
#    ⚠️ 버전을 여기 다시 박지 말 것 — 옛 주석이 `0.1.0-RC1`을 박아 두어 1.0.0 이후 거짓이 됐고,
#    check-versions.mjs는 이 자리를 보지 않는다(#170이 같은 부류로 남긴 사고 지점이다).
#    서명은 in-memory 키가 없으면 자동 비활성(build.gradle.kts의 signingKeyPresent 가드) → 무서명 게시.
COPY kotlin/ ./kotlin/
WORKDIR /build/kotlin
# ⚠️ gradlew를 `sh`로 호출하고 CRLF를 스트립한다 — Windows 워킹트리 체크아웃의 gradlew는 CRLF라
# Alpine sh가 `#!/usr/bin/env sh\r` shebang을 못 찾아 exit 127로 죽는다(Docker는 로컬 파일을 COPY).
# CI(Linux, LF 체크아웃)에선 sed가 no-op이라 무해하고, `sh` 호출로 +x 비트 유무와도 무관해진다.
RUN sed -i 's/\r$//' gradlew && sh ./gradlew --no-daemon publishToMavenLocal -x test
# 2) 하네스 앱 빌드(gradle 내장 application 플러그인 installDist → bin/lib, shadow 버전호환 리스크 회피)
WORKDIR /build
COPY harness/apps/kotlin/ ./app/
WORKDIR /build/app
RUN sed -i 's/\r$//' gradlew && sh ./gradlew --no-daemon installDist

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
# Alpine(busybox)엔 useradd가 없다 — adduser(-D: 시스템 계정)를 사용한다(java 앱 동형).
RUN adduser -D -u 10001 app
COPY --from=build /build/app/build/install/harness-app-kotlin/ ./
USER app
EXPOSE 8090
ENTRYPOINT ["/app/bin/harness-app-kotlin"]
