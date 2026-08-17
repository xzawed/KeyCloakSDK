---
paths:
  - "java/**"
  - "harness/apps/java/**"
  - "harness/install/consume/java*"
---

# Java 규칙

## 툴체인

JDK 21 + Maven 3.9.x. 하네스 셸은 프로파일을 소싱하지 않으므로 환경을 인라인 지정한다.

```bash
JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot}" \
PATH="${KCSDK_TOOLS:-$HOME/tools}/apache-maven-3.9.9/bin:$PATH" mvn -f java/pom.xml <goal>
```

- 전체 빌드+검증: `mvn -f java/pom.xml verify`(커버리지 게이트 90/85 + 통합테스트 포함, Docker 필요)
- 단위만: `mvn -f java/pom.xml test -DskipITs=true` · 단일: `-pl <module> -Dtest=<Class>#<method>`
- 배포 산출물 로컬 검증: `mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package`
- 실제 배포는 `v*` 태그 → `release.yml`(사람 승인 게이트).
- ⚠️ **정확한 패치 버전을 여기 적지 않는다** — 실측은 `java -version`·`node scripts/doctor.mjs java`다. 예전에 이 파일 안에서 두 자리가 갈린 채 굳은 적이 있다.
- ⚠️ **`jacoco:check`는 `verify` 페이즈 바인딩이라 `mvn test`로는 커버리지 게이트가 검증되지 않는다.**

## 게차

- ⚠️ **퍼블릭/PKCE 클라이언트에서 `char[]` 시크릿을 무조건 문자열화하면 맨 NPE다.** `getClientSecret()`은 퍼블릭 클라이언트에서 null인데 `AuthClient.clientAuth()`가 이를 그대로 `new String(...)`에 넘겨 client-credentials·refresh·logout·introspect 네 경로 전부에서 진단 불가능한 NPE를 냈다. 지금은 호출 흐름 이름을 받아 "이 작업은 기밀 클라이언트를 요구한다"는 `KeycloakConfigException`을 던진다. **`char[]` 시크릿을 문자열화하는 지점에는 전부 null 가드가 선행해야 한다.**
- ⚠️ **admin-client와 Keycloak 서버는 독립 버전 트랙이다** — 서버 라인과 같은 번호의 admin-client는 존재하지 않는다. `representation` 필드가 서버와 어긋날 수 있어 의존하는 필드는 실서버로 검증한다. 핀은 루트 `CLAUDE.md` 의존성 표가 SSOT다. Kotlin도 같은 좌표를 재사용한다.
- ⚠️ **admin 타임아웃·자원정리.** `AdminClient`는 connect/read 타임아웃을 `KeycloakBuilder.resteasyClient(...)`로 주입해야 무한 대기를 막는다(미주입 = 스레드 고갈 DoS). `close()`는 admin뿐 아니라 **auth 세션까지** 정리한다(미정리 = FD/커넥션풀 누수).
- ⚠️ **그런데 `resteasyClient(...)` 주입은 admin-client의 `JacksonProvider` 등록을 통째로 우회한다.** `NON_NULL`(null 필드 미전송)과 `FAIL_ON_UNKNOWN_PROPERTIES=false`를 함께 잃어 버전 스큐에서 양방향으로 깨진다(클라이언트가 앞서면 400 *Unrecognized field*, 서버가 앞서면 역직렬화 파손). `buildTimeoutClient`가 `JacksonProvider`와 `StreamMessageBodyReader`를 직접 등록한다. **`ClientBuilder.newBuilder()`를 유지할 것** — `createClientBuilder()`로 바꾸면 커넥션풀이 50→10으로 조용히 줄어든다.
  - **동작 계약**: NON_NULL이 켜지면 부분 업데이트에서 null로 필드를 비울 수 없다(미설정 필드는 전송되지 않아 서버가 '변경 없음'으로 처리) — 공식 admin-client와 같은 동작이다. 비우려면 빈 문자열이나 전용 API를 쓴다.
- ⚠️ **jackson-databind는 `dependencyManagement`로 고정한다**(핀은 루트 `CLAUDE.md` 표). **보안 불변식**: 자체 `ObjectMapper`나 default/polymorphic typing을 쓰지 않고 신뢰된 Keycloak 응답만 고정 POJO로 역직렬화한다 — default typing 활성화 · 커스텀 JAX-RS Jackson provider 등록 · 미신뢰 JSON 다형 역직렬화 도입 **전부 금지**이고 CI `invariant` 잡이 막는다.
- ⚠️ **`jwksMinRefetch`는 Nimbus 캐시 TTL(기본 5분) 미만이어야 한다** — 넘으면 `JWKSourceBuilder.build()`가 던지고, 그 foreign 예외가 공개 API로 새면 §4 위반이다. 경계에서 `KeycloakConfigException`으로 변환한다. ⚠️ **JWKS rate-limit 테스트에는 대조군(간격 0 또는 검증기 재생성)을 반드시 둔다** — 캐시만으로도 통과해 하드닝 한 줄을 지워도 초록이 된다.
- **admin은 토큰을 자체 소유한다** — `AdminClient(KeycloakConfig)`가 admin-client 내장 client-credentials를 쓰고, `TokenProvider` 기반 생성자는 RESTEasy 필터 충돌로 제거됐다. admin은 auth를 직접 알지 못한다(§4).
- **어떤 Java OIDC 라이브러리도 자체 인증("certified")이 아니다** — 필요하면 완성 제품을 OIDF에 별도 인증한다.
- **`release` 프로파일의 `maven-javadoc-plugin`에는 `<doclint>none</doclint>`가 필요하다** — Java 17+ doclint 기본 엄격이라 문서 경고만으로 `-javadoc.jar` 생성이 실패한다.
