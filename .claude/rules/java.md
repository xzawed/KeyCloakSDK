---
paths:
  - "java/**"
  - "harness/apps/java/**"
  - "harness/install/consume/java*"
---

# Java 규칙

## 툴체인 (빌드 명령)

하네스 셸은 프로파일을 소싱하지 않으므로 mvn 명령마다 환경을 인라인 지정한다:
```bash
JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot}" PATH="${KCSDK_TOOLS:-$HOME/tools}/apache-maven-3.9.9/bin:$PATH" mvn -f java/pom.xml <goal>
```
> 다른 PC에서는 `KCSDK_JDK21`(JDK 21+ 경로)·`KCSDK_TOOLS`(포터블 툴 상위 디렉터리)를 덮어쓰거나, 이미 PATH에 있으면 프리픽스를 생략한다. 설치·진단은 [development-setup.md](../../docs/guides/development-setup.md)(`node scripts/doctor.mjs java`).
- 전체 빌드+검증: `mvn -f java/pom.xml verify` (커버리지 게이트 90/85 포함)
- 단위테스트만: `mvn -f java/pom.xml test -DskipITs=true`
- 단일 테스트: `mvn -f java/pom.xml test -pl <module> -Dtest=<ClassName>#<method>`
- 통합테스트(Docker 필요): `mvn -f java/pom.xml verify`
- examples 모듈만 컴파일: `mvn -f java/pom.xml -pl keycloak-sdk-examples -am compile`
- 배포(release) 산출물 로컬 검증(서명·배포 없이): `mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package` — core/auth/admin/keycloak-sdk 각각 `*-sources.jar`/`*-javadoc.jar` 생성 확인
- 실제 `deploy`(Maven Central 배포)는 로컬에서 실행하지 않는다 — `v*` 태그 push 시 `.github/workflows/release.yml`에서만 시크릿과 함께 실행(사람 승인 게이트)
- JDK 21.0.8 (Eclipse Temurin) · Maven 3.9.9 (머신 전용 경로 — 리포지토리에 커밋 안 함, CI는 setup-java 사용)

## 게차

`(Java)` 단일 언어 태그로 표시된 게차 항목은 현재 없다 — Java 관련 게차(admin-client 버전 스큐·jackson-databind·`resteasyClient` 등)는 교차언어(`(Java·Kotlin)`) 항목이거나 태그 없는 프로젝트 공통 항목이라 루트 `CLAUDE.md`의 `## 핵심 게차` 섹션에 전문이 남아있다.
