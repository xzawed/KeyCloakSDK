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
JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot}" PATH="${KCSDK_TOOLS:-$HOME/tools}/apache-maven-3.9.9/bin:$PATH" mvn -f java/pom.xml <goal>
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

- ⚠️ **(Java) 퍼블릭/PKCE 클라이언트에서 `new String((char[]) null)`은 맨 NPE다.** `KeycloakConfig.getClientSecret()`은 `char[]`이고 퍼블릭 클라이언트에서는 null인데, 이를 무조건 문자열화하던 `AuthClient.clientAuth()`가 client-credentials·refresh·logout·introspect 네 경로 전부에서 진단 불가능한 NPE를 던졌다. 지금은 호출 흐름 이름을 인자로 받아 "이 작업은 기밀 클라이언트를 요구한다"는 `KeycloakAuthException`을 던진다(실패 조건은 동일, 진단만 개선 — 네트워크-프리 단위테스트 `AuthClientPublicClientTest`로 고정). **`char[]` 시크릿을 문자열화하는 지점은 전부 null 가드가 선행해야 한다** — 같은 부류의 버그를 다른 경로/언어에 재도입하지 말 것.

그 밖의 Java 게차(admin-client 버전 스큐·jackson-databind 핀·`resteasyClient` 주입)는 교차언어(`(Java·Kotlin)`)이거나 태그 없는 프로젝트 공통 항목이라 루트 `CLAUDE.md`의 `## 핵심 게차`에 있다.
- ⚠️ **(Java·Kotlin) `jwksMinRefetch`는 Nimbus 캐시 TTL(기본 5분)보다 작아야 한다 — 크면 `JWKSourceBuilder.build()`가 `IllegalStateException`을 던진다.** 캐시가 만료돼도 rate-limit이 재조회를 막아 JWKS를 영영 갱신할 수 없는 구성이라 Nimbus가 거부하는 것 자체는 정당하다. 문제는 그 foreign 예외가 `JwtValidator.forRealm`에서 **그대로 새어나와** 공개 API에 하위 라이브러리 타입이 노출됐다는 것(§4 위반)이다 — 지금은 두 언어 모두 경계에서 `KeycloakConfigException`으로 변환하고 한계값을 메시지에 담는다. 회귀 테스트: Java `jwksMinRefetch_atOrAboveCacheTtl_isRejectedAsConfigError`, Kotlin `jwksMinRefetch at or above cache ttl is rejected as config error`. **JWKS rate-limit을 테스트할 때는 반드시 대조군(간격 0 또는 검증기 재생성)을 함께 둘 것** — 캐시만으로도 "히트가 토큰 수보다 적다"가 성립해 `.rateLimited(...)` 한 줄을 지워도 통과한다(Node에서 먼저 겪은 함정).
- ⚠️ **(Java·Kotlin) `resteasyClient(...)` 주입은 admin-client의 `JacksonProvider` 등록을 통째로 우회한다.** admin-client는 이 프로바이더를 자기가 만든 클라이언트에만 등록하므로, 타임아웃 주입용으로 우리 클라이언트를 넘기면 `NON_NULL`(null필드 미전송)과 `FAIL_ON_UNKNOWN_PROPERTIES=false`(미지필드 무시)를 둘 다 잃는다 — 버전스큐에서 양방향 파손(클라이언트가 앞서면 400 *Unrecognized field*, 서버가 앞서면 역직렬화 깨짐). **26.0.11의 `UserRepresentation.verifiableCredentials`에서 실제 발현(PR #84)**. `buildTimeoutClient`가 `.register(JacksonProvider.class,100)`+`.register(StreamMessageBodyReader.class)`를 직접 수행 — ⚠️ **`StreamMessageBodyReader`는 26.0.11에만 존재**(26.0.10까지는 JacksonProvider 내장, 26.0.11에서 분리 — 프로바이더의 stream 참조 26.0.10 **9건** → 26.0.11 **0건** 실측). `ClientBuilder.newBuilder()` 유지 필수 — `createClientBuilder()`로 바꾸면 커넥션풀이 50→10으로 조용히 축소. ⚠️ **동작 계약**: NON_NULL이 켜지면 부분 업데이트에서 null로 필드를 비우는 것이 불가능해진다(미설정 필드는 전송되지 않아 서버가 '변경 없음'으로 처리) — 공식 admin-client와 동일한 동작이다. 비우려면 빈 문자열/전용 API를 쓴다.
- ⚠️ **(Java) `admin`↔`auth`의 유일한 접착제는 `core`의 `TokenProvider` 인터페이스다** — `admin`은 `auth`를 직접 알지 못한다. 그래서 auth 없이도 admin을 자체 토큰 소스로 쓸 수 있고, 내부 라이브러리를 갈아도 소비자에게 파급되지 않는다(§4).
