# Keycloak Java SDK 구현 계획 (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keycloak의 인증(OIDC/OAuth2)과 관리 REST API를 함께 다루는, 공식 `keycloak-admin-client`와 Nimbus OIDC SDK를 감싼 Java 17 SDK를 만들어 Maven Central에 배포한다.

**Architecture:** Maven 멀티모듈 모노레포. `core`(설정·토큰·예외·보안 정책) 위에 `auth`(Nimbus 래퍼)와 `admin`(공식 admin-client 래퍼)이 각각 얹히고, `admin`은 `auth`를 직접 모른 채 `core`의 `TokenProvider` 인터페이스로만 결합된다. `keycloak-sdk` 파사드가 셋을 조립한다.

**Tech Stack:** Java 17, Maven, `keycloak-admin-client` 26.0.10, `oauth2-oidc-sdk` 11.37.2, `nimbus-jose-jwt` 10.9.1, JUnit 6.1.1, Mockito 5.23.0, Testcontainers 2.0.5 + `testcontainers-keycloak` 4.2.1.

## Global Constraints

모든 태스크의 요구사항은 아래를 암묵적으로 포함한다. 값은 스펙에서 그대로 옮긴 것이다.

- **Java 베이스라인**: 17 (`maven.compiler.release=17`). record/sealed 사용 가능.
- **groupId**: `io.github.xzawed` · **라이선스**: Apache-2.0 (모든 모듈 POM `<licenses>`).
- **대상 Keycloak 서버**: 26.6.x. **admin-client**: `26.0.10` (⚠️ 서버 버전과 다른 독립 트랙, "26.6.x admin-client"는 없음).
- **동기(sync) API만** — 공개 계약은 블로킹.
- **의존성 버전 고정(BOM)**: `oauth2-oidc-sdk` 11.37.2, `nimbus-jose-jwt` 10.9.1(명시적 핀닝, 전이는 10.9), Jackson 2.21.2/RESTEasy 6.2.15는 admin-client 전이.
- **보안**: 토큰/시크릿을 로그·`toString()`·예외 메시지에 남기지 않음(마스킹). 시크릿은 `char[]`. TLS 검증 기본 on. 토큰 저장 기본 인메모리 + 교체 가능한 `TokenStore` SPI.
- **JWT 검증**: 허용 알고리즘 핀닝(토큰 헤더 `alg` 불신, `none` 거부), issuer/audience 검증, `exp`/`nbf` + 소량 클록 스큐(기본 30s). JWKS 캐시.
- **예외**: `jakarta.ws.rs.*`·`com.nimbusds.*` 타입을 공개 API에 노출하지 않음 — 경계에서 SDK 예외로 변환.
- **결합 규칙**: `admin` 모듈은 `auth` 모듈에 의존하지 않는다. 접착제는 `core`의 `TokenProvider`뿐.
- **버전 정책**: SDK 자체 SemVer는 Keycloak 버전과 분리. 지원 서버는 호환 매트릭스로 안내.
- **TDD·DRY·YAGNI·잦은 커밋**. 각 태스크는 독립적으로 테스트 가능한 산출물로 끝난다.

**거버넌스 부록** ([AI 거버넌스 프레임워크](../../governance/ai-governance-framework.md) 적용):
- **툴체인 프리픽스**: 모든 mvn 명령은 인라인 환경으로 실행 (JDK 17.0.19 + Maven 3.9.9). 리포지토리엔 이 경로를 커밋하지 않음.
  - Bash: `JAVA_HOME='/c/Program Files/Microsoft/jdk-17.0.19.10-hotspot' PATH="/c/Users/dirtc/tools/apache-maven-3.9.9/bin:$PATH" mvn ...`
  - PowerShell: `$env:JAVA_HOME='C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot'; $env:Path='C:\Users\dirtc\tools\apache-maven-3.9.9\bin;' + $env:Path; mvn ...`
- **커밋 규약**: 모든 커밋 스텝은 `git add -A && git commit -m "..."` 사용 (`git commit -am`은 신규 파일 누락 → **금지**). 구현 push는 `feature/java-sdk-mvp`에만, main은 PR(사람 승인).
- **명명 충돌 회피**: SDK의 인증요청 타입은 Nimbus `AuthorizationRequest`와 충돌하므로 **`AuthorizationUrlRequest`** 로 명명(Task 3.3).
- **커버리지 게이트(G3)**: JaCoCo 라인 ≥ 90% / 브랜치 ≥ 85% (로직 모듈). 부모 POM(Task 1.1)에 `jacoco-maven-plugin`(prepare-agent + `check` 규칙) 추가, 통합 전용 클래스는 exclude. 미달 시 빌드 실패.
- **Codex 교차검증(G5)**: 모든 태스크 diff를 Codex(GPT-5)가 독립 검토 → "confirmed" + 불일치 0 이어야 완료.
- **루프 엔지니어링**: 게이트 미달 시 RCA→시정→재검증 루프(게이트당 최대 3회, 초과 시 에스컬레이션). 결과는 [검증 로그](../../governance/verification-log.md)에 기록.
- **브랜치 격리**: `feature/java-sdk-mvp`에서 구현, main에 PR(사람 승인). Maven Central 배포는 사람 승인 필수.

---

## WBS 개요 (Work Breakdown Structure)

| WBS | Phase / Work Package | 산출물(Deliverable) | 선행(Dep) |
|---|---|---|---|
| **1** | **기반 (Foundation)** | 빌드 가능한 멀티모듈 골격 + CI | — |
| 1.1 | 부모 POM & reactor | `mvn -q validate` 성공 | — |
| 1.2 | BOM 모듈 | 버전 고정 BOM 설치 | 1.1 |
| 1.3 | CI 골격 (build/test) | PR에서 JDK 17/21 빌드 | 1.1 |
| **2** | **core 모듈** | 설정·토큰·예외·SPI | 1 |
| 2.1 | 예외 계층 | `KeycloakSdkException` 트리 | 1.2 |
| 2.2 | `KeycloakConfig` (빌더·검증) | 불변 설정 + 검증 | 2.1 |
| 2.3 | `TokenSet` 모델 | 토큰 값 객체 + 만료 판정 | 2.1 |
| 2.4 | `TokenProvider` / `TokenStore` SPI | 인터페이스 + 인메모리 저장소 | 2.3 |
| 2.5 | 시크릿 마스킹 유틸 | 로그 안전 문자열 | 2.1 |
| **3** | **auth 모듈** | 인증 흐름 | 2 |
| 3.1 | OIDC 메타데이터 해석 | discovery 로딩 | 2.2 |
| 3.2 | PKCE 유틸 | verifier/challenge 생성 | 2.1 |
| 3.3 | Authorization Code + PKCE | 로그인 URL + 코드 교환 | 3.1, 3.2 |
| 3.4 | Client Credentials | M2M 토큰 | 3.1 |
| 3.5 | Refresh / Logout | 갱신·end-session | 3.1 |
| 3.6 | JWT 검증 (JWKS·핀닝) | `validate()` | 3.1 |
| 3.7 | Introspection | `introspect()` | 3.1 |
| 3.8 | `ClientCredentialsTokenProvider` | `TokenProvider` 구현(single-flight) | 3.4, 2.4 |
| **4** | **admin 모듈** | 관리 파사드 | 2, (3.8 테스트) |
| 4.1 | `AdminClient` 골격·수명주기 | `Keycloak` 래핑, `AutoCloseable` | 2.4 |
| 4.2 | 예외 경계 변환 | `jakarta.ws.rs` → SDK | 4.1, 2.1 |
| 4.3 | `users()` | 사용자 CRUD | 4.2 |
| 4.4 | `clients()` | 클라이언트 CRUD | 4.2 |
| 4.5 | `realms()` | 렐름 조회/생성 | 4.2 |
| 4.6 | `roles()` | 역할 CRUD | 4.2 |
| 4.7 | `groups()` | 그룹 CRUD | 4.2 |
| 4.8 | `raw()` 탈출구 | 공식 클라이언트 노출 | 4.1 |
| **5** | **facade 모듈** | 통합 진입점 | 3, 4 |
| 5.1 | `KeycloakClient` | `auth()`+`admin()` 조립, `AutoCloseable` | 3.8, 4.1 |
| **6** | **통합 테스트** | Testcontainers E2E | 5 |
| 6.1 | Testcontainers 하네스 + realm import | 컨테이너 부팅 | 5.1 |
| 6.2 | 인증 흐름 E2E | client-credentials·검증 | 6.1 |
| 6.3 | 관리 작업 E2E | user/client CRUD | 6.1 |
| **7** | **배포 & 문서** | Maven Central + 문서 | 6 |
| 7.1 | 배포 플러그인 설정 | sources/javadoc/gpg/central | 1.2 |
| 7.2 | 릴리스 CI | 태그 드리븐 배포 | 7.1 |
| 7.3 | examples 모듈 | 실행 예제 | 5.1 |
| 7.4 | 문서 최신화 | README·CLAUDE.md 명령 | 6 |

**진행 순서**: 1 → 2 → 3 → 4 → 5 → 6 → 7. 3과 4는 core(2) 완료 후 병렬 가능하나, 단일 세션 실행 시 순차 권장.

---

## 파일 구조 (File Structure)

```
java/pom.xml                                  # 부모 reactor POM
java/keycloak-sdk-bom/pom.xml                 # BOM
java/keycloak-sdk-core/
  pom.xml
  src/main/java/io/github/xzawed/keycloak/core/
    KeycloakConfig.java                        # 불변 설정 + Builder
    TokenSet.java                              # 토큰 값 객체
    TokenProvider.java                         # SPI (String getAccessToken())
    TokenStore.java                            # SPI (save/load/clear)
    InMemoryTokenStore.java                    # 기본 구현
    Secrets.java                               # 마스킹 유틸
    exception/KeycloakSdkException.java 외 (2.1)
  src/test/java/io/github/xzawed/keycloak/core/...
java/keycloak-sdk-auth/
  src/main/java/io/github/xzawed/keycloak/auth/
    AuthClient.java                            # 인증 진입점
    OidcMetadata.java                          # discovery 결과
    Pkce.java                                  # PKCE 유틸
    AuthorizationRequest.java                  # URL + verifier + state
    JwtValidator.java                          # JWKS 검증
    ClientCredentialsTokenProvider.java        # TokenProvider 구현
java/keycloak-sdk-admin/
  src/main/java/io/github/xzawed/keycloak/admin/
    AdminClient.java                           # 파사드 진입점, AutoCloseable
    AdminExceptions.java                       # 경계 변환
    UsersResource.java / ClientsResource.java / RealmsResource.java
    RolesResource.java / GroupsResource.java
java/keycloak-sdk/
  src/main/java/io/github/xzawed/keycloak/KeycloakClient.java
java/keycloak-sdk-examples/                    # 배포 제외
spec/                                          # OpenAPI (Python 향후)
.github/workflows/ci.yml / release.yml
```

---

# Phase 1 — 기반 (Foundation)

### Task 1.1: 부모 POM & 멀티모듈 reactor

**Files:**
- Create: `java/pom.xml`
- Create: `java/keycloak-sdk-core/pom.xml`, `java/keycloak-sdk-auth/pom.xml`, `java/keycloak-sdk-admin/pom.xml`, `java/keycloak-sdk/pom.xml`

**Interfaces:**
- Produces: 부모 groupId `io.github.xzawed`, version `0.1.0-SNAPSHOT`, `maven.compiler.release=17`, 공통 `<licenses>`(Apache-2.0), `<developers>`, `<scm>`.

- [ ] **Step 1: 부모 POM 작성**

```xml
<!-- java/pom.xml -->
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk-parent</artifactId>
  <version>0.1.0-SNAPSHOT</version>
  <packaging>pom</packaging>
  <name>Keycloak SDK (parent)</name>
  <description>Multi-language Keycloak SDK — Java reference implementation</description>
  <url>https://github.com/xzawed/KeyCloakSDK</url>

  <licenses>
    <license>
      <name>Apache-2.0</name>
      <url>https://www.apache.org/licenses/LICENSE-2.0.txt</url>
    </license>
  </licenses>
  <developers>
    <developer><name>xzawed</name><email>xzawed31@gmail.com</email></developer>
  </developers>
  <scm>
    <connection>scm:git:https://github.com/xzawed/KeyCloakSDK.git</connection>
    <developerConnection>scm:git:https://github.com/xzawed/KeyCloakSDK.git</developerConnection>
    <url>https://github.com/xzawed/KeyCloakSDK</url>
  </scm>

  <modules>
    <module>keycloak-sdk-bom</module>
    <module>keycloak-sdk-core</module>
    <module>keycloak-sdk-auth</module>
    <module>keycloak-sdk-admin</module>
    <module>keycloak-sdk</module>
  </modules>

  <properties>
    <maven.compiler.release>17</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    <keycloak.adminclient.version>26.0.10</keycloak.adminclient.version>
    <nimbus.oidc.version>11.37.2</nimbus.oidc.version>
    <nimbus.jose.version>10.9.1</nimbus.jose.version>
    <junit.version>6.1.1</junit.version>
    <mockito.version>5.23.0</mockito.version>
    <testcontainers.version>2.0.5</testcontainers.version>
    <testcontainers.keycloak.version>4.2.1</testcontainers.keycloak.version>
  </properties>

  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.junit</groupId><artifactId>junit-bom</artifactId>
        <version>${junit.version}</version><type>pom</type><scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <build>
    <pluginManagement>
      <plugins>
        <plugin>
          <groupId>org.apache.maven.plugins</groupId>
          <artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version>
        </plugin>
      </plugins>
    </pluginManagement>
    <plugins>
      <!-- G3 커버리지 게이트: 라인 90% / 브랜치 85% -->
      <plugin>
        <groupId>org.jacoco</groupId>
        <artifactId>jacoco-maven-plugin</artifactId>
        <version>0.8.12</version>
        <configuration>
          <excludes>
            <exclude>**/*IT.class</exclude>
            <exclude>**/KeycloakContainerSupport.class</exclude>
          </excludes>
        </configuration>
        <executions>
          <execution><id>prepare</id><goals><goal>prepare-agent</goal></goals></execution>
          <execution><id>report</id><phase>verify</phase><goals><goal>report</goal></goals></execution>
          <execution>
            <id>check</id><phase>verify</phase><goals><goal>check</goal></goals>
            <configuration>
              <rules>
                <rule>
                  <element>BUNDLE</element>
                  <limits>
                    <limit><counter>LINE</counter><value>COVEREDRATIO</value><minimum>0.90</minimum></limit>
                    <limit><counter>BRANCH</counter><value>COVEREDRATIO</value><minimum>0.85</minimum></limit>
                  </limits>
                </rule>
              </rules>
            </configuration>
          </execution>
        </executions>
      </plugin>
      <!-- 의존성 수렴 + Java/Maven 버전 강제 (스펙 §7) -->
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-enforcer-plugin</artifactId>
        <version>3.5.0</version>
        <executions>
          <execution>
            <id>enforce</id><goals><goal>enforce</goal></goals>
            <configuration>
              <rules>
                <dependencyConvergence/>
                <requireJavaVersion><version>[17,)</version></requireJavaVersion>
                <requireMavenVersion><version>[3.9,)</version></requireMavenVersion>
              </rules>
            </configuration>
          </execution>
        </executions>
      </plugin>
    </plugins>
  </build>
</project>
```
> ⚠️ 커버리지 `check`는 `verify` 단계에서 실행된다. 초기 골격(코드 없음)에서는 클래스가 없어 규칙이 vacuously 통과한다. 통합 전용 모듈(`keycloak-sdk`의 IT)·`examples`는 `<jacoco.skip>true</jacoco.skip>` 또는 exclude로 게이트에서 제외하고, 로직 모듈(core/auth/admin)에만 90/85를 강제한다.

- [ ] **Step 2: 각 자식 모듈 POM 작성 (core 예시, 나머지 동일 골격)**

```xml
<!-- java/keycloak-sdk-core/pom.xml -->
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>io.github.xzawed</groupId>
    <artifactId>keycloak-sdk-parent</artifactId>
    <version>0.1.0-SNAPSHOT</version>
  </parent>
  <artifactId>keycloak-sdk-core</artifactId>
  <name>Keycloak SDK :: core</name>
  <dependencies>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.mockito</groupId><artifactId>mockito-core</artifactId><version>${mockito.version}</version><scope>test</scope></dependency>
    <dependency><groupId>org.mockito</groupId><artifactId>mockito-junit-jupiter</artifactId><version>${mockito.version}</version><scope>test</scope></dependency>
  </dependencies>
</project>
```
`auth`/`admin`/`keycloak-sdk` POM도 같은 골격으로 만들되 `<artifactId>`와 모듈별 의존만 다르게 한다(각 Phase 시작 태스크에서 의존 추가).

- [ ] **Step 3: 빌드 검증**

Run: `mvn -q -f java/pom.xml validate`
Expected: BUILD SUCCESS (5개 모듈 인식).

- [ ] **Step 4: Commit**

```bash
git add java/pom.xml java/*/pom.xml
git commit -m "build: Maven 멀티모듈 reactor 골격 (WBS 1.1)"
```

---

### Task 1.2: BOM 모듈

**Files:**
- Create: `java/keycloak-sdk-bom/pom.xml`

**Interfaces:**
- Produces: `io.github.xzawed:keycloak-sdk-bom` — 내부 모듈 + 외부 의존(admin-client 26.0.10, nimbus 11.37.2/10.9.1) 버전 고정.

- [ ] **Step 1: BOM POM 작성**

```xml
<!-- java/keycloak-sdk-bom/pom.xml -->
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>io.github.xzawed</groupId>
    <artifactId>keycloak-sdk-parent</artifactId>
    <version>0.1.0-SNAPSHOT</version>
  </parent>
  <artifactId>keycloak-sdk-bom</artifactId>
  <packaging>pom</packaging>
  <name>Keycloak SDK :: BOM</name>
  <dependencyManagement>
    <dependencies>
      <dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk-core</artifactId><version>${project.version}</version></dependency>
      <dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk-auth</artifactId><version>${project.version}</version></dependency>
      <dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk-admin</artifactId><version>${project.version}</version></dependency>
      <dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk</artifactId><version>${project.version}</version></dependency>
      <dependency><groupId>org.keycloak</groupId><artifactId>keycloak-admin-client</artifactId><version>${keycloak.adminclient.version}</version></dependency>
      <dependency><groupId>com.nimbusds</groupId><artifactId>oauth2-oidc-sdk</artifactId><version>${nimbus.oidc.version}</version></dependency>
      <dependency><groupId>com.nimbusds</groupId><artifactId>nimbus-jose-jwt</artifactId><version>${nimbus.jose.version}</version></dependency>
    </dependencies>
  </dependencyManagement>
</project>
```

- [ ] **Step 2: 설치 검증** — Run: `mvn -q -f java/pom.xml install -pl keycloak-sdk-bom` · Expected: BUILD SUCCESS.
- [ ] **Step 3: Commit** — `git add java/keycloak-sdk-bom/pom.xml && git commit -m "build: 의존성 고정 BOM 모듈 (WBS 1.2)"`

---

### Task 1.3: CI 골격 (build/test)

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: 워크플로 작성**

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix: { java: ['17', '21'] }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: 'temurin', java-version: '${{ matrix.java }}', cache: 'maven' }
      - name: Build & unit test
        run: mvn -B -f java/pom.xml verify -DskipITs=true
```

- [ ] **Step 2: 로컬 검증** — Run: `mvn -B -f java/pom.xml verify -DskipITs=true` · Expected: BUILD SUCCESS (테스트 0개라도 통과).
- [ ] **Step 3: Commit & push** — `git add .github/workflows/ci.yml && git commit -m "ci: JDK 17/21 빌드·단위테스트 워크플로 (WBS 1.3)" && git push`

---

# Phase 2 — core 모듈

### Task 2.1: 예외 계층

**Files:**
- Create: `java/keycloak-sdk-core/src/main/java/io/github/xzawed/keycloak/core/exception/KeycloakSdkException.java` (+ 하위 예외)
- Test: `.../core/exception/KeycloakSdkExceptionTest.java`

**Interfaces:**
- Produces: `KeycloakSdkException(RuntimeException)` base; 하위 `KeycloakConfigException`, `KeycloakAuthException`, `TokenValidationException`, `KeycloakAdminException`, `KeycloakNotFoundException`/`KeycloakConflictException`/`KeycloakForbiddenException`(AdminException 하위), `KeycloakTransportException`. `KeycloakAdminException`은 `int getStatus()` + `String getKeycloakError()` 보유.

- [ ] **Step 1: 실패 테스트 작성**

```java
package io.github.xzawed.keycloak.core.exception;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class KeycloakSdkExceptionTest {
  @Test void adminException_carriesStatusAndError() {
    KeycloakAdminException e = new KeycloakNotFoundException(404, "User not found", null);
    assertEquals(404, e.getStatus());
    assertEquals("User not found", e.getKeycloakError());
    assertInstanceOf(KeycloakSdkException.class, e);
  }
  @Test void baseException_isRuntime() {
    assertInstanceOf(RuntimeException.class, new KeycloakConfigException("bad", null));
  }
}
```

- [ ] **Step 2: 테스트 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-core -Dtest=KeycloakSdkExceptionTest` · Expected: 컴파일 실패(클래스 없음).

- [ ] **Step 3: 예외 클래스 구현**

```java
// KeycloakSdkException.java
package io.github.xzawed.keycloak.core.exception;
public class KeycloakSdkException extends RuntimeException {
  public KeycloakSdkException(String message, Throwable cause) { super(message, cause); }
}
```
```java
// KeycloakConfigException.java
package io.github.xzawed.keycloak.core.exception;
public class KeycloakConfigException extends KeycloakSdkException {
  public KeycloakConfigException(String message, Throwable cause) { super(message, cause); }
}
```
```java
// KeycloakAuthException.java
package io.github.xzawed.keycloak.core.exception;
public class KeycloakAuthException extends KeycloakSdkException {
  private final String error;            // OAuth error code (nullable)
  public KeycloakAuthException(String message, String error, Throwable cause) {
    super(message, cause); this.error = error;
  }
  public String getError() { return error; }
}
```
```java
// TokenValidationException.java
package io.github.xzawed.keycloak.core.exception;
public class TokenValidationException extends KeycloakSdkException {
  public TokenValidationException(String message, Throwable cause) { super(message, cause); }
}
```
```java
// KeycloakTransportException.java
package io.github.xzawed.keycloak.core.exception;
public class KeycloakTransportException extends KeycloakSdkException {
  public KeycloakTransportException(String message, Throwable cause) { super(message, cause); }
}
```
```java
// KeycloakAdminException.java
package io.github.xzawed.keycloak.core.exception;
public class KeycloakAdminException extends KeycloakSdkException {
  private final int status; private final String keycloakError;
  public KeycloakAdminException(int status, String keycloakError, Throwable cause) {
    super("Keycloak admin error (HTTP " + status + ")", cause);
    this.status = status; this.keycloakError = keycloakError;
  }
  public int getStatus() { return status; }
  public String getKeycloakError() { return keycloakError; }
}
```
```java
// KeycloakNotFoundException.java (409/403도 동일 패턴)
package io.github.xzawed.keycloak.core.exception;
public class KeycloakNotFoundException extends KeycloakAdminException {
  public KeycloakNotFoundException(int status, String keycloakError, Throwable cause) { super(status, keycloakError, cause); }
}
```
`KeycloakConflictException`(409), `KeycloakForbiddenException`(403)도 위와 동일하게 `KeycloakAdminException`을 상속해 각각 생성한다.

- [ ] **Step 4: 테스트 통과 확인** — Run: 동일 명령 · Expected: PASS.
- [ ] **Step 5: Commit** — `git add java/keycloak-sdk-core/src/.../exception/ && git commit -m "feat(core): SDK 예외 계층 (WBS 2.1)"`

---

### Task 2.2: `KeycloakConfig` (빌더 + 검증)

**Files:**
- Create: `.../core/KeycloakConfig.java`
- Test: `.../core/KeycloakConfigTest.java`

**Interfaces:**
- Produces: 불변 `KeycloakConfig`. `builder()` → `Builder{ serverUrl(String), realm(String), clientId(String), clientSecret(char[]), scopes(String...), connectTimeout(Duration), readTimeout(Duration), tlsVerification(boolean), clockSkew(Duration), build() }`. 게터: `getServerUrl()`, `getRealm()`, `getClientId()`, `getClientSecret()`(char[] 복제 반환), `getScopes()`(List<String>), `getConnectTimeout()`/`getReadTimeout()`/`getClockSkew()`(Duration), `isTlsVerification()`. 기본값: connect/read 10s/30s, tls true, clockSkew 30s. `build()`는 serverUrl/realm/clientId 누락 시 `KeycloakConfigException`.

- [ ] **Step 1: 실패 테스트 작성**

```java
package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.time.Duration;
import org.junit.jupiter.api.Test;

class KeycloakConfigTest {
  @Test void buildsWithDefaults() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    assertEquals("https://kc.example.com", c.getServerUrl());
    assertEquals(Duration.ofSeconds(30), c.getClockSkew());
    assertTrue(c.isTlsVerification());
  }
  @Test void missingRealm_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("x").clientId("app");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void clientSecret_isDefensivelyCopied() {
    char[] secret = "s3cr3t".toCharArray();
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app")
        .clientSecret(secret).build();
    secret[0] = 'X';
    assertArrayEquals("s3cr3t".toCharArray(), c.getClientSecret());
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-core -Dtest=KeycloakConfigTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```java
package io.github.xzawed.keycloak.core;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.time.Duration;
import java.util.*;

public final class KeycloakConfig {
  private final String serverUrl, realm, clientId;
  private final char[] clientSecret;               // nullable (public client)
  private final List<String> scopes;
  private final Duration connectTimeout, readTimeout, clockSkew;
  private final boolean tlsVerification;

  private KeycloakConfig(Builder b) {
    this.serverUrl = b.serverUrl; this.realm = b.realm; this.clientId = b.clientId;
    this.clientSecret = b.clientSecret == null ? null : b.clientSecret.clone();
    this.scopes = List.copyOf(b.scopes);
    this.connectTimeout = b.connectTimeout; this.readTimeout = b.readTimeout;
    this.clockSkew = b.clockSkew; this.tlsVerification = b.tlsVerification;
  }
  public String getServerUrl() { return serverUrl; }
  public String getRealm() { return realm; }
  public String getClientId() { return clientId; }
  public char[] getClientSecret() { return clientSecret == null ? null : clientSecret.clone(); }
  public List<String> getScopes() { return scopes; }
  public Duration getConnectTimeout() { return connectTimeout; }
  public Duration getReadTimeout() { return readTimeout; }
  public Duration getClockSkew() { return clockSkew; }
  public boolean isTlsVerification() { return tlsVerification; }

  public static Builder builder() { return new Builder(); }

  public static final class Builder {
    private String serverUrl, realm, clientId;
    private char[] clientSecret;
    private List<String> scopes = new ArrayList<>();
    private Duration connectTimeout = Duration.ofSeconds(10);
    private Duration readTimeout = Duration.ofSeconds(30);
    private Duration clockSkew = Duration.ofSeconds(30);
    private boolean tlsVerification = true;

    public Builder serverUrl(String v) { this.serverUrl = v; return this; }
    public Builder realm(String v) { this.realm = v; return this; }
    public Builder clientId(String v) { this.clientId = v; return this; }
    public Builder clientSecret(char[] v) { this.clientSecret = v == null ? null : v.clone(); return this; }
    public Builder scopes(String... v) { this.scopes = Arrays.asList(v); return this; }
    public Builder connectTimeout(Duration v) { this.connectTimeout = v; return this; }
    public Builder readTimeout(Duration v) { this.readTimeout = v; return this; }
    public Builder clockSkew(Duration v) { this.clockSkew = v; return this; }
    public Builder tlsVerification(boolean v) { this.tlsVerification = v; return this; }

    public KeycloakConfig build() {
      require(serverUrl, "serverUrl"); require(realm, "realm"); require(clientId, "clientId");
      return new KeycloakConfig(this);
    }
    private static void require(String v, String name) {
      if (v == null || v.isBlank())
        throw new KeycloakConfigException("Missing required config: " + name, null);
    }
  }
}
```

- [ ] **Step 4: 통과 확인** — Run: 동일 명령 · Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): KeycloakConfig 빌더·검증 (WBS 2.2)"`

---

### Task 2.3: `TokenSet` 모델

**Files:**
- Create: `.../core/TokenSet.java` · Test: `.../core/TokenSetTest.java`

**Interfaces:**
- Produces: `TokenSet`(record 유사 불변): 필드 `accessToken`(String), `refreshToken`(String, nullable), `idToken`(String, nullable), `tokenType`(String), `scope`(String, nullable), `expiresAt`(Instant). 메서드 `boolean isExpired(Clock, Duration skew)` — `now+skew >= expiresAt`. `toString()`은 토큰 값을 마스킹.

- [ ] **Step 1: 실패 테스트**

```java
package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import java.time.*;
import org.junit.jupiter.api.Test;

class TokenSetTest {
  @Test void isExpired_respectsSkew() {
    Instant exp = Instant.parse("2026-07-02T00:00:30Z");
    TokenSet t = new TokenSet("acc", null, null, "Bearer", null, exp);
    Clock at5 = Clock.fixed(Instant.parse("2026-07-02T00:00:05Z"), ZoneOffset.UTC);
    assertTrue(t.isExpired(at5, Duration.ofSeconds(30)));   // 5+30 >= 30
    assertFalse(t.isExpired(at5, Duration.ofSeconds(10)));  // 5+10 < 30
  }
  @Test void toString_masksTokens() {
    TokenSet t = new TokenSet("supersecret", "refreshsecret", null, "Bearer", null, Instant.now());
    assertFalse(t.toString().contains("supersecret"));
    assertFalse(t.toString().contains("refreshsecret"));
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-core -Dtest=TokenSetTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```java
package io.github.xzawed.keycloak.core;
import java.time.*;
public final class TokenSet {
  private final String accessToken, refreshToken, idToken, tokenType, scope;
  private final Instant expiresAt;
  public TokenSet(String accessToken, String refreshToken, String idToken,
                  String tokenType, String scope, Instant expiresAt) {
    this.accessToken = accessToken; this.refreshToken = refreshToken; this.idToken = idToken;
    this.tokenType = tokenType; this.scope = scope; this.expiresAt = expiresAt;
  }
  public String getAccessToken() { return accessToken; }
  public String getRefreshToken() { return refreshToken; }
  public String getIdToken() { return idToken; }
  public String getTokenType() { return tokenType; }
  public String getScope() { return scope; }
  public Instant getExpiresAt() { return expiresAt; }
  public boolean isExpired(Clock clock, Duration skew) {
    return !Instant.now(clock).plus(skew).isBefore(expiresAt);
  }
  @Override public String toString() {
    return "TokenSet{tokenType=" + tokenType + ", scope=" + scope
        + ", accessToken=***, refreshToken=" + (refreshToken == null ? "null" : "***")
        + ", expiresAt=" + expiresAt + "}";
  }
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(core): TokenSet 모델 + 만료·마스킹 (WBS 2.3)"`

---

### Task 2.4: `TokenProvider` / `TokenStore` SPI + 인메모리 저장소

**Files:**
- Create: `.../core/TokenProvider.java`, `.../core/TokenStore.java`, `.../core/InMemoryTokenStore.java`
- Test: `.../core/InMemoryTokenStoreTest.java`

**Interfaces:**
- Produces: `interface TokenProvider { String getAccessToken(); }` (유효 bearer 토큰 반환, 필요 시 내부 갱신). `interface TokenStore { void save(TokenSet); Optional<TokenSet> load(); void clear(); }`. `InMemoryTokenStore implements TokenStore` (thread-safe, `volatile`/synchronized).

- [ ] **Step 1: 실패 테스트**

```java
package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import java.time.Instant; import java.util.Optional;
import org.junit.jupiter.api.Test;

class InMemoryTokenStoreTest {
  @Test void saveThenLoad_returnsToken() {
    InMemoryTokenStore s = new InMemoryTokenStore();
    assertTrue(s.load().isEmpty());
    TokenSet t = new TokenSet("a", null, null, "Bearer", null, Instant.now());
    s.save(t);
    assertEquals(Optional.of(t), s.load());
    s.clear();
    assertTrue(s.load().isEmpty());
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-core -Dtest=InMemoryTokenStoreTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```java
// TokenProvider.java
package io.github.xzawed.keycloak.core;
public interface TokenProvider { String getAccessToken(); }
```
```java
// TokenStore.java
package io.github.xzawed.keycloak.core;
import java.util.Optional;
public interface TokenStore {
  void save(TokenSet tokens);
  Optional<TokenSet> load();
  void clear();
}
```
```java
// InMemoryTokenStore.java
package io.github.xzawed.keycloak.core;
import java.util.Optional;
public final class InMemoryTokenStore implements TokenStore {
  private volatile TokenSet current;
  @Override public void save(TokenSet tokens) { this.current = tokens; }
  @Override public Optional<TokenSet> load() { return Optional.ofNullable(current); }
  @Override public void clear() { this.current = null; }
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(core): TokenProvider/TokenStore SPI + 인메모리 저장소 (WBS 2.4)"`

---

### Task 2.5: 시크릿 마스킹 유틸

**Files:**
- Create: `.../core/Secrets.java` · Test: `.../core/SecretsTest.java`

**Interfaces:**
- Produces: `Secrets.mask(String)` → 앞 2~3자만 남기고 `***`, 짧으면 전부 `***`. `Secrets.maskBearer(String header)` → `Bearer ***`.

- [ ] **Step 1: 실패 테스트**

```java
package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
class SecretsTest {
  @Test void mask_hidesMostOfValue() {
    assertEquals("***", Secrets.mask("ab"));
    assertEquals("abc***", Secrets.mask("abcdef123"));
    assertEquals("***", Secrets.mask(null));
  }
  @Test void maskBearer_hidesToken() {
    assertEquals("Bearer ***", Secrets.maskBearer("Bearer eyJraWQ..."));
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-core -Dtest=SecretsTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```java
package io.github.xzawed.keycloak.core;
public final class Secrets {
  private Secrets() {}
  public static String mask(String value) {
    if (value == null || value.length() <= 4) return "***";
    return value.substring(0, 3) + "***";
  }
  public static String maskBearer(String header) {
    if (header == null) return "***";
    return header.regionMatches(true, 0, "Bearer ", 0, 7) ? "Bearer ***" : "***";
  }
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(core): 시크릿 마스킹 유틸 (WBS 2.5)"`

---

# Phase 3 — auth 모듈

> auth 모듈 POM에 의존 추가: `keycloak-sdk-core`, `com.nimbusds:oauth2-oidc-sdk`, `com.nimbusds:nimbus-jose-jwt`(BOM에서 버전). 첫 태스크(3.1) Step에서 추가한다.

### Task 3.1: OIDC 메타데이터 해석 (discovery)

**Files:**
- Modify: `java/keycloak-sdk-auth/pom.xml` (의존 추가)
- Create: `.../auth/OidcMetadata.java`
- Test: `.../auth/OidcMetadataTest.java`

**Interfaces:**
- Produces: `OidcMetadata` — `authorizationEndpoint`, `tokenEndpoint`, `introspectionEndpoint`, `endSessionEndpoint`, `jwksUri`, `issuer`(모두 `URI`/String). `static OidcMetadata forRealm(KeycloakConfig)` — `{serverUrl}/realms/{realm}` 이슈어에서 표준 경로 구성(네트워크 없이 규약 기반 URL 조립; discovery fetch는 3.3 이후 실제 호출에서). 이슈어 = `serverUrl/realms/realm`.

- [ ] **Step 1: pom 의존 추가**

```xml
<!-- java/keycloak-sdk-auth/pom.xml <dependencies> -->
<dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk-core</artifactId><version>${project.version}</version></dependency>
<dependency><groupId>com.nimbusds</groupId><artifactId>oauth2-oidc-sdk</artifactId><version>${nimbus.oidc.version}</version></dependency>
<dependency><groupId>com.nimbusds</groupId><artifactId>nimbus-jose-jwt</artifactId><version>${nimbus.jose.version}</version></dependency>
```

- [ ] **Step 2: 실패 테스트**

```java
package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import org.junit.jupiter.api.Test;

class OidcMetadataTest {
  @Test void buildsStandardKeycloakEndpoints() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("myrealm").clientId("app").build();
    OidcMetadata m = OidcMetadata.forRealm(c);
    assertEquals("https://kc.example.com/realms/myrealm", m.getIssuer());
    assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/token", m.getTokenEndpoint().toString());
    assertEquals("https://kc.example.com/realms/myrealm/protocol/openid-connect/certs", m.getJwksUri().toString());
  }
}
```

- [ ] **Step 3: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-auth -Dtest=OidcMetadataTest` · Expected: 컴파일 실패.

- [ ] **Step 4: 구현**

```java
package io.github.xzawed.keycloak.auth;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;
public final class OidcMetadata {
  private final String issuer;
  private final URI authorizationEndpoint, tokenEndpoint, introspectionEndpoint, endSessionEndpoint, jwksUri;
  private OidcMetadata(String issuer, URI auth, URI token, URI introspect, URI endSession, URI jwks) {
    this.issuer = issuer; this.authorizationEndpoint = auth; this.tokenEndpoint = token;
    this.introspectionEndpoint = introspect; this.endSessionEndpoint = endSession; this.jwksUri = jwks;
  }
  public static OidcMetadata forRealm(KeycloakConfig c) {
    String base = c.getServerUrl().replaceAll("/+$", "") + "/realms/" + c.getRealm();
    String oc = base + "/protocol/openid-connect";
    return new OidcMetadata(base,
        URI.create(oc + "/auth"), URI.create(oc + "/token"),
        URI.create(oc + "/token/introspect"), URI.create(oc + "/logout"),
        URI.create(oc + "/certs"));
  }
  public String getIssuer() { return issuer; }
  public URI getAuthorizationEndpoint() { return authorizationEndpoint; }
  public URI getTokenEndpoint() { return tokenEndpoint; }
  public URI getIntrospectionEndpoint() { return introspectionEndpoint; }
  public URI getEndSessionEndpoint() { return endSessionEndpoint; }
  public URI getJwksUri() { return jwksUri; }
}
```

- [ ] **Step 5: 통과 확인** · **Step 6: Commit** — `git commit -am "feat(auth): OIDC 메타데이터 엔드포인트 해석 (WBS 3.1)"`

---

### Task 3.2: PKCE 유틸

**Files:** Create `.../auth/Pkce.java` · Test `.../auth/PkceTest.java`

**Interfaces:**
- Produces: `Pkce.generate()` → `Pkce{ String getVerifier(); String getChallenge(); String getMethod()="S256"; }`. verifier는 43~128자 URL-safe, challenge는 SHA-256(verifier) base64url.

- [ ] **Step 1: 실패 테스트**

```java
package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
class PkceTest {
  @Test void generatesValidS256Pair() {
    Pkce p = Pkce.generate();
    assertEquals("S256", p.getMethod());
    assertTrue(p.getVerifier().length() >= 43 && p.getVerifier().length() <= 128);
    assertNotEquals(p.getVerifier(), p.getChallenge());
    assertFalse(p.getChallenge().contains("="));  // base64url no padding
  }
  @Test void distinctVerifiersAcrossCalls() {
    assertNotEquals(Pkce.generate().getVerifier(), Pkce.generate().getVerifier());
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-auth -Dtest=PkceTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현** (Nimbus `CodeVerifier`/`CodeChallenge` 사용)

```java
package io.github.xzawed.keycloak.auth;
import com.nimbusds.oauth2.sdk.pkce.*;
public final class Pkce {
  private final CodeVerifier verifier; private final String challenge;
  private Pkce(CodeVerifier v) {
    this.verifier = v;
    this.challenge = CodeChallenge.compute(CodeChallengeMethod.S256, v).getValue();
  }
  public static Pkce generate() { return new Pkce(new CodeVerifier()); }
  public String getVerifier() { return verifier.getValue(); }
  public String getChallenge() { return challenge; }
  public String getMethod() { return "S256"; }
  CodeVerifier nimbusVerifier() { return verifier; }  // 패키지 전용, 3.3에서 사용
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(auth): PKCE(S256) 유틸 (WBS 3.2)"`

---

### Task 3.3: Authorization Code + PKCE

**Files:** Create `.../auth/AuthorizationRequest.java`, `.../auth/AuthClient.java` · Test `.../auth/AuthClientAuthCodeTest.java`

**Interfaces:**
- Produces:
  - `AuthorizationUrlRequest{ URI getAuthorizationUrl(); String getCodeVerifier(); String getState(); String getNonce(); }` (Nimbus `AuthorizationRequest`와 이름충돌 회피)
  - `AuthClient(KeycloakConfig, OidcMetadata)` 생성자 (⚠️ `java.net.http.HttpClient`는 받지 않음 — Nimbus는 자체 HTTP 스택 사용). `AuthorizationUrlRequest createAuthorizationRequest(URI redirectUri)`.
  - `TokenSet exchangeCode(String code, String codeVerifier, URI redirectUri)` (실제 HTTP는 통합 테스트에서 검증. 단위 테스트는 URL 조립·상태 생성만).
  - 내부: Nimbus `HTTPRequest`에 `config.getConnectTimeout()`/`config.getReadTimeout()`를 밀리초로 설정한 뒤 `send()` — 타임아웃을 `KeycloakConfig`에서 적용.
- Consumes: `OidcMetadata`(3.1), `Pkce`(3.2), `KeycloakConfig`(2.2), `TokenSet`(2.3), `KeycloakAuthException`(2.1).

- [ ] **Step 1: 실패 테스트 (URL 조립·PKCE·state 검증)**

```java
package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;
import org.junit.jupiter.api.Test;

class AuthClientAuthCodeTest {
  private AuthClient newClient() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .scopes("openid","profile").build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }
  @Test void authorizationUrl_containsPkceAndState() {
    AuthorizationUrlRequest req = newClient().createAuthorizationRequest(URI.create("https://app/cb"));
    String url = req.getAuthorizationUrl().toString();
    assertTrue(url.startsWith("https://kc.example.com/realms/r/protocol/openid-connect/auth"));
    assertTrue(url.contains("code_challenge="));
    assertTrue(url.contains("code_challenge_method=S256"));
    assertTrue(url.contains("state=" ));
    assertTrue(url.contains("response_type=code"));
    assertNotNull(req.getCodeVerifier());
    assertNotNull(req.getState());
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-auth -Dtest=AuthClientAuthCodeTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현** (Nimbus `AuthorizationRequest` 빌더 사용; 코드 교환은 `TokenRequest`+`AuthorizationCodeGrant`)

```java
// AuthorizationUrlRequest.java
package io.github.xzawed.keycloak.auth;
import java.net.URI;
public final class AuthorizationUrlRequest {
  private final URI authorizationUrl; private final String codeVerifier, state, nonce;
  AuthorizationUrlRequest(URI url, String verifier, String state, String nonce) {
    this.authorizationUrl = url; this.codeVerifier = verifier; this.state = state; this.nonce = nonce;
  }
  public URI getAuthorizationUrl() { return authorizationUrl; }
  public String getCodeVerifier() { return codeVerifier; }
  public String getState() { return state; }
  public String getNonce() { return nonce; }
}
```
```java
// AuthClient.java (auth code 부분; 다른 흐름은 3.4~3.7에서 메서드 추가)
package io.github.xzawed.keycloak.auth;
import com.nimbusds.oauth2.sdk.*;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.id.*;
import com.nimbusds.oauth2.sdk.pkce.CodeChallengeMethod;
import com.nimbusds.openid.connect.sdk.*;
import io.github.xzawed.keycloak.core.*;
import java.net.URI;

public class AuthClient {
  private final KeycloakConfig config; private final OidcMetadata metadata;
  public AuthClient(KeycloakConfig config, OidcMetadata metadata) {
    this.config = config; this.metadata = metadata;
  }
  // Nimbus HTTPRequest에 KeycloakConfig 타임아웃 적용 후 전송 (3.4~3.7 공용 헬퍼)
  HTTPRequest applyTimeouts(HTTPRequest req) {
    req.setConnectTimeout((int) config.getConnectTimeout().toMillis());
    req.setReadTimeout((int) config.getReadTimeout().toMillis());
    return req;
  }
  public AuthorizationUrlRequest createAuthorizationRequest(URI redirectUri) {
    Pkce pkce = Pkce.generate();
    State state = new State(); Nonce nonce = new Nonce();
    Scope scope = new Scope(config.getScopes().toArray(new String[0]));
    if (scope.isEmpty()) scope = new Scope("openid");
    com.nimbusds.openid.connect.sdk.AuthenticationRequest ar =
        new com.nimbusds.openid.connect.sdk.AuthenticationRequest.Builder(
            new ResponseType(ResponseType.Value.CODE), scope,
            new ClientID(config.getClientId()), redirectUri)
          .endpointURI(metadata.getAuthorizationEndpoint())
          .state(state).nonce(nonce)
          .codeChallenge(pkce.nimbusVerifier(), CodeChallengeMethod.S256)
          .build();
    return new AuthorizationUrlRequest(ar.toURI(), pkce.getVerifier(), state.getValue(), nonce.getValue());
  }
  // exchangeCode(...) 는 3.3 확장: TokenRequest(AuthorizationCodeGrant)를 applyTimeouts(tr.toHTTPRequest()).send() 후 toTokenSet 매핑.
  // 실제 HTTP 성공/실패 경로는 통합 테스트(6.2)에서 검증.
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(auth): Authorization Code+PKCE URL 생성 (WBS 3.3)"`

---

### Task 3.4: Client Credentials (M2M 토큰)

**Files:** Modify `AuthClient.java` · Test `.../auth/AuthClientClientCredentialsTest.java` (Nimbus 응답 → TokenSet 매핑 단위 검증; 실제 엔드포인트는 6.2)

**Interfaces:**
- Produces: `AuthClient.clientCredentialsToken()` → `TokenSet`. 내부 `static TokenSet toTokenSet(com.nimbusds...Tokens, long issuedAtEpoch)` 매핑 헬퍼(패키지 전용)로 응답을 `TokenSet`으로 변환(만료 = issuedAt + expires_in).
- Consumes: `OidcMetadata.getTokenEndpoint()`, `KeycloakConfig.getClientSecret()`.

- [ ] **Step 1: 실패 테스트 (매핑 헬퍼 단위)**

```java
package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.token.*;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class AuthClientClientCredentialsTest {
  @Test void mapsBearerTokensToTokenSet() {
    BearerAccessToken at = new BearerAccessToken("acc", 300, null); // expires_in=300
    Tokens tokens = new Tokens(at, null);
    io.github.xzawed.keycloak.core.TokenSet ts = AuthClient.toTokenSet(tokens, 1000L);
    assertEquals("acc", ts.getAccessToken());
    assertEquals(Instant.ofEpochSecond(1300), ts.getExpiresAt());
    assertEquals("Bearer", ts.getTokenType());
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-auth -Dtest=AuthClientClientCredentialsTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현** — `AuthClient`에 추가:

```java
import com.nimbusds.oauth2.sdk.auth.*;
import com.nimbusds.oauth2.sdk.token.Tokens;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import java.time.Instant;

public io.github.xzawed.keycloak.core.TokenSet clientCredentialsToken() {
  try {
    ClientAuthentication auth = new ClientSecretBasic(
        new com.nimbusds.oauth2.sdk.id.ClientID(config.getClientId()),
        new Secret(new String(config.getClientSecret())));
    TokenRequest tr = new TokenRequest.Builder(metadata.getTokenEndpoint(), auth,
        new ClientCredentialsGrant())
        .scope(new com.nimbusds.oauth2.sdk.Scope(config.getScopes().toArray(new String[0])))
        .build();
    long issuedAt = Instant.now().getEpochSecond();
    TokenResponse resp = TokenResponse.parse(applyTimeouts(tr.toHTTPRequest()).send());
    if (!resp.indicatesSuccess()) {
      var err = resp.toErrorResponse().getErrorObject();
      throw new KeycloakAuthException("Client credentials failed: " + err.getDescription(),
          err.getCode(), null);
    }
    return toTokenSet(resp.toSuccessResponse().getTokens(), issuedAt);
  } catch (java.io.IOException | com.nimbusds.oauth2.sdk.ParseException e) {
    throw new KeycloakAuthException("Client credentials request error", null, e);
  }
}
static io.github.xzawed.keycloak.core.TokenSet toTokenSet(Tokens tokens, long issuedAtEpoch) {
  var at = tokens.getAccessToken();
  Instant exp = Instant.ofEpochSecond(issuedAtEpoch + at.getLifetime());
  String refresh = tokens.getRefreshToken() == null ? null : tokens.getRefreshToken().getValue();
  return new io.github.xzawed.keycloak.core.TokenSet(
      at.getValue(), refresh, null, "Bearer",
      at.getScope() == null ? null : at.getScope().toString(), exp);
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(auth): Client Credentials 토큰 + 매핑 (WBS 3.4)"`

---

### Task 3.5: Refresh / Logout

**Files:** Modify `AuthClient.java` · Test `.../auth/AuthClientRefreshTest.java`

**Interfaces:**
- Produces: `AuthClient.refresh(String refreshToken)` → `TokenSet`; `AuthClient.logout(String refreshToken)` → `void` (end-session 호출, 실패 시 `KeycloakAuthException`).

- [ ] **Step 1~2: 실패 테스트/확인** — `refresh`는 `RefreshTokenGrant` 사용. 단위 테스트는 `toTokenSet` 재사용을 확인하는 스텁(위 3.4 매핑 테스트로 커버되므로, 여기선 `logout` 인자 검증만). Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-auth -Dtest=AuthClientRefreshTest` · Expected: 컴파일 실패.

```java
package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
class AuthClientRefreshTest {
  @Test void logout_rejectsNullRefreshToken() {
    io.github.xzawed.keycloak.core.KeycloakConfig c = io.github.xzawed.keycloak.core.KeycloakConfig.builder()
        .serverUrl("https://kc").realm("r").clientId("app").build();
    AuthClient a = new AuthClient(c, OidcMetadata.forRealm(c));
    assertThrows(IllegalArgumentException.class, () -> a.logout(null));
  }
}
```

- [ ] **Step 3: 구현** — `AuthClient`에 `refresh`(RefreshTokenGrant→toTokenSet)와 `logout`(end-session 엔드포인트에 refresh_token+client 인증 POST; null 인자 `IllegalArgumentException`) 추가.
- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(auth): 토큰 갱신·로그아웃 (WBS 3.5)"`

---

### Task 3.6: JWT 검증 (JWKS·알고리즘 핀닝)

**Files:** Create `.../auth/JwtValidator.java` · Test `.../auth/JwtValidatorTest.java`

**Interfaces:**
- Produces: `JwtValidator(OidcMetadata, KeycloakConfig, Set<JWSAlgorithm> allowedAlgs, String expectedAudience)`. `JWTClaimsSet validate(String accessToken)` — JWKS 원격 소스로 서명 검증, `alg` 핀닝(허용 목록 외/`none` 거부), issuer=`metadata.getIssuer()`, audience 검증, `exp`/`nbf` + `config.getClockSkew()`. 실패 시 `TokenValidationException`. `AuthClient.validate(...)`가 위임.
- 구현: Nimbus `JWKSourceBuilder`/`RemoteJWKSet` + `DefaultJWTProcessor` + `JWSVerificationKeySelector` + `DefaultJWTClaimsVerifier`. **JWKSource는 issuer당 싱글턴으로 캐시**(생성자에서 1회).

- [ ] **Step 1: 실패 테스트** — 로컬 RSA 키쌍으로 서명한 JWT를 검증(성공)하고, `alg=none`·잘못된 issuer·만료 토큰이 `TokenValidationException`을 던지는지 테스트. (테스트는 in-memory `JWKSet`을 주입하는 패키지 전용 생성자 오버로드 사용.)

```java
package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.jose.*; import com.nimbusds.jose.crypto.*;
import com.nimbusds.jose.jwk.*; import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.*;
import java.util.*;
import org.junit.jupiter.api.Test;

class JwtValidatorTest {
  @Test void validSignedToken_passes() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis()+60000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));
    assertEquals(issuer, v.validate(jwt.serialize()).getIssuer());
  }
  @Test void noneAlg_rejected() {
    JwtValidator v = JwtValidator.withStaticJwks(new JWKSet(), "iss", "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));
    // alg=none 토큰: 헤더 {"alg":"none"} — base64url + "." + payload + "."
    String noneJwt = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJpc3MifQ.";
    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(noneJwt));
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-auth -Dtest=JwtValidatorTest` · Expected: 컴파일 실패.
- [ ] **Step 3: 구현** (nimbus-jose-jwt 10.9.1 API 확정)

```java
package io.github.xzawed.keycloak.auth;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.*;
import com.nimbusds.jose.proc.*;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.proc.*;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.time.Duration; import java.util.*;

public final class JwtValidator {
  private final ConfigurableJWTProcessor<SecurityContext> processor;   // issuer당 1회 구성(JWKSource 캐시)
  private JwtValidator(JWKSource<SecurityContext> jwkSource, String issuer, String audience,
                       Set<JWSAlgorithm> allowedAlgs, Duration skew) {
    DefaultJWTProcessor<SecurityContext> p = new DefaultJWTProcessor<>();
    p.setJWSKeySelector(new JWSVerificationKeySelector<>(allowedAlgs, jwkSource)); // 허용 alg만 → none/기타 거부
    // ⚠️ audience는 exactMatchClaims에 넣지 않는다 — 실제 Keycloak 토큰의 aud는 다중 값
    // (예: ["client","realm-management"])이라 정확 일치가 아니라 '포함 검사'여야 한다(통합테스트 발견).
    // requiredAudience 파라미터가 포함 검사를 수행. issuer만 정확 일치.
    JWTClaimsSet exact = new JWTClaimsSet.Builder().issuer(issuer).build();
    DefaultJWTClaimsVerifier<SecurityContext> v =
        new DefaultJWTClaimsVerifier<>(audience, exact, Set.of("exp"));
    v.setMaxClockSkew((int) skew.getSeconds());
    p.setJWTClaimsSetVerifier(v);
    this.processor = p;
  }
  public static JwtValidator forRealm(OidcMetadata md, io.github.xzawed.keycloak.core.KeycloakConfig cfg,
                                      Set<JWSAlgorithm> allowedAlgs, String audience) {
    try {
      JWKSource<SecurityContext> src = JWKSourceBuilder.create(md.getJwksUri().toURL()).build();
      return new JwtValidator(src, md.getIssuer(), audience, allowedAlgs, cfg.getClockSkew());
    } catch (java.net.MalformedURLException e) {
      throw new TokenValidationException("Invalid JWKS URI", e);
    }
  }
  static JwtValidator withStaticJwks(JWKSet jwks, String issuer, String audience,
                                     Set<JWSAlgorithm> allowedAlgs, Duration skew) {
    return new JwtValidator(new ImmutableJWKSet<>(jwks), issuer, audience, allowedAlgs, skew);
  }
  public JWTClaimsSet validate(String accessToken) {
    try { return processor.process(accessToken, null); }
    catch (Exception e) { throw new TokenValidationException("JWT validation failed", e); }
  }
}
```
> `AuthClient.validate(token)`는 `JwtValidator.forRealm(metadata, config, Set.of(JWSAlgorithm.RS256), config.getClientId())`를 지연 생성·캐시해 위임. `none`은 `JWSVerificationKeySelector`가 허용 alg만 받으므로 자동 거부되고, unsecured JWT는 `DefaultJWTProcessor`가 기본 거부.
- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(auth): JWKS 기반 JWT 검증 + 알고리즘 핀닝 (WBS 3.6)"`

---

### Task 3.7: Token Introspection

**Files:** Modify `AuthClient.java` · Test는 통합(6.2)에서 실제 검증; 단위는 요청 조립만.

**Interfaces:**
- Produces: `AuthClient.introspect(String token)` → `boolean`(active) 또는 `IntrospectionResult{ boolean isActive(); Optional<String> getUsername(); Optional<String> getClientId(); }`. Nimbus `TokenIntrospectionRequest`/`Response` 사용, client 인증 포함.

- [ ] **Step 1~5: TDD** — 요청 URL·client 인증이 `metadata.getIntrospectionEndpoint()`를 향하는지 단위 검증 후 구현·커밋. Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-auth -Dtest=AuthClientIntrospectTest` · Commit: `git commit -am "feat(auth): 토큰 introspection (WBS 3.7)"`

---

### Task 3.8: `ClientCredentialsTokenProvider` (single-flight)

**Files:** Create `.../auth/ClientCredentialsTokenProvider.java` · Test `.../auth/ClientCredentialsTokenProviderTest.java`

**Interfaces:**
- Produces: `ClientCredentialsTokenProvider implements TokenProvider` — 생성자 `(AuthClient, Clock, Duration skew)`. `getAccessToken()`은 캐시된 `TokenSet`이 유효하면 반환, 만료 임박 시 **single-flight**(동시 갱신 1회)로 `authClient.clientCredentialsToken()` 호출 후 캐시. `core`의 `TokenProvider` 구현으로, **고급 `AdminClient(KeycloakConfig, TokenProvider)` 경로**에서 소비 가능(기본 파사드는 네이티브 그랜트 사용). 독립적으로 테스트·제공되는 유틸.
- Consumes: `AuthClient.clientCredentialsToken()`(3.4), `TokenSet.isExpired`(2.3), `TokenProvider`(2.4).

- [ ] **Step 1: 실패 테스트 (Mockito로 AuthClient 목)**

```java
package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import io.github.xzawed.keycloak.core.TokenSet;
import java.time.*;
import org.junit.jupiter.api.Test;

class ClientCredentialsTokenProviderTest {
  @Test void cachesTokenUntilExpiry() {
    AuthClient auth = mock(AuthClient.class);
    Instant future = Instant.parse("2026-07-02T01:00:00Z");
    when(auth.clientCredentialsToken())
        .thenReturn(new TokenSet("tok1", null, null, "Bearer", null, future));
    Clock clock = Clock.fixed(Instant.parse("2026-07-02T00:00:00Z"), ZoneOffset.UTC);
    ClientCredentialsTokenProvider p = new ClientCredentialsTokenProvider(auth, clock, Duration.ofSeconds(30));
    assertEquals("tok1", p.getAccessToken());
    assertEquals("tok1", p.getAccessToken());
    verify(auth, times(1)).clientCredentialsToken();   // 캐시 → 1회만
  }
  @Test void refetchesAfterExpiry() {
    AuthClient auth = mock(AuthClient.class);
    when(auth.clientCredentialsToken())
        .thenReturn(new TokenSet("tok1", null, null, "Bearer", null, Instant.parse("2026-07-02T00:00:10Z")))
        .thenReturn(new TokenSet("tok2", null, null, "Bearer", null, Instant.parse("2026-07-02T02:00:00Z")));
    Clock clock = Clock.fixed(Instant.parse("2026-07-02T00:00:00Z"), ZoneOffset.UTC);
    ClientCredentialsTokenProvider p = new ClientCredentialsTokenProvider(auth, clock, Duration.ofSeconds(30));
    assertEquals("tok1", p.getAccessToken());  // 만료 임박(10s < now+30s)이지만 최초 로드
    assertEquals("tok2", p.getAccessToken());  // 만료 판정 → 재요청
    verify(auth, times(2)).clientCredentialsToken();
  }
}
```
> 참고: 첫 호출은 캐시가 비어 무조건 로드. 두 번째 호출에서 `isExpired`가 참이면 재요청. 위 테스트의 tok1 만료(00:00:10)는 skew 30s 기준 `now(00:00:00)+30s=00:00:30 >= 00:00:10` → 만료로 판정되어 재요청.

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-auth -Dtest=ClientCredentialsTokenProviderTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```java
package io.github.xzawed.keycloak.auth;
import io.github.xzawed.keycloak.core.*;
import java.time.*;
public final class ClientCredentialsTokenProvider implements TokenProvider {
  private final AuthClient auth; private final Clock clock; private final Duration skew;
  private volatile TokenSet cached;
  private final Object lock = new Object();
  public ClientCredentialsTokenProvider(AuthClient auth, Clock clock, Duration skew) {
    this.auth = auth; this.clock = clock; this.skew = skew;
  }
  @Override public String getAccessToken() {
    TokenSet t = cached;
    if (t != null && !t.isExpired(clock, skew)) return t.getAccessToken();
    synchronized (lock) {                       // single-flight
      if (cached == null || cached.isExpired(clock, skew)) {
        cached = auth.clientCredentialsToken();
      }
      return cached.getAccessToken();
    }
  }
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(auth): ClientCredentialsTokenProvider single-flight (WBS 3.8)"`

---

# Phase 4 — admin 모듈

> admin 모듈 POM에 의존 추가: `keycloak-sdk-core`, `org.keycloak:keycloak-admin-client`(BOM 버전). auth에는 의존하지 않는다.

### Task 4.1: `AdminClient` 골격 & 수명주기

**Files:** Modify `java/keycloak-sdk-admin/pom.xml` · Create `.../admin/AdminClient.java` · Test `.../admin/AdminClientLifecycleTest.java`

**Interfaces:**
- Produces: `AdminClient` — 단일 생성자. `implements AutoCloseable`(`close()`가 내부 `Keycloak.close()` 호출). `org.keycloak.admin.client.Keycloak raw()`. 리소스 접근자 `users()/clients()/realms()/roles()/groups()`(4.3~4.7에서 반환 타입 추가).
  - **`AdminClient(KeycloakConfig)`**: Keycloak admin-client 내장 client-credentials 그랜트 사용. `KeycloakBuilder.builder().serverUrl(cfg.getServerUrl()).realm(cfg.getRealm()).clientId(cfg.getClientId()).clientSecret(new String(cfg.getClientSecret())).grantType(OAuth2Constants.CLIENT_CREDENTIALS).build()` → Keycloak TokenManager가 자동 획득·갱신. `clientSecret`이 null이면 `KeycloakConfigException`.
  > ⚠️ **설계 변경(Codex 검증 반영)**: 원래 계획한 고급 생성자 `AdminClient(KeycloakConfig, TokenProvider)`(ClientRequestFilter 주입)는 keycloak-admin-client 26.0.10의 `KeycloakBuilder.build()`가 grantType/자격증명을 반드시 요구해(`IllegalStateException: username required`) 구조적으로 성립하지 않음이 **경험적으로 확인**되어 **MVP에서 제거**함. `TokenProvider` SPI(core)와 `ClientCredentialsTokenProvider`(3.8)는 독립 유틸/향후 확장점으로 유지.
- Consumes: 기본 생성자는 auth 모듈·TokenProvider에 의존하지 않음(결합 규칙 유지). 테스트 주입용 패키지 전용 팩토리 `static AdminClient withKeycloak(KeycloakConfig cfg, Keycloak injected)`.

- [ ] **Step 1: pom 의존 추가**

```xml
<!-- java/keycloak-sdk-admin/pom.xml -->
<dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk-core</artifactId><version>${project.version}</version></dependency>
<dependency><groupId>org.keycloak</groupId><artifactId>keycloak-admin-client</artifactId><version>${keycloak.adminclient.version}</version></dependency>
```

- [ ] **Step 2: 실패 테스트 (수명주기 — close 위임, raw 노출)**

```java
package io.github.xzawed.keycloak.admin;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import io.github.xzawed.keycloak.core.*;
import org.junit.jupiter.api.Test;
import org.keycloak.admin.client.Keycloak;

class AdminClientLifecycleTest {
  @Test void close_delegatesToKeycloak_andRawExposesIt() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    Keycloak kc = mock(Keycloak.class);
    AdminClient admin = AdminClient.withKeycloak(c, kc);   // 패키지 전용 팩토리(테스트 주입)
    assertSame(kc, admin.raw());
    assertInstanceOf(AutoCloseable.class, admin);
    admin.close();
    verify(kc).close();                    // 수명주기 위임 검증
  }
}
```

- [ ] **Step 3: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-admin -Dtest=AdminClientLifecycleTest` · Expected: 컴파일 실패.

- [ ] **Step 4: 구현** —
  - **기본 생성자** `AdminClient(KeycloakConfig cfg)`: `KeycloakBuilder.builder().serverUrl(cfg.getServerUrl()).realm(cfg.getRealm()).clientId(cfg.getClientId()).clientSecret(new String(cfg.getClientSecret())).grantType(org.keycloak.OAuth2Constants.CLIENT_CREDENTIALS).build()` → `withKeycloak(cfg, kc)` 위임. (Keycloak TokenManager가 자동 갱신)
  - **고급 생성자** `AdminClient(KeycloakConfig cfg, TokenProvider tp)`: 커스텀 `ClientRequestFilter`(매 요청 `requestContext.getHeaders().putSingle("Authorization", "Bearer " + tp.getAccessToken())`)를 register한 RESTEasy `Client`를 만들어 `KeycloakBuilder.builder().serverUrl(...).realm(...).resteasyClient(client).build()`로 생성 → `withKeycloak(cfg, kc)` 위임. `KeycloakBuilder.authorization(String)`은 쓰지 않는다.
  - **패키지 전용 팩토리** `static AdminClient withKeycloak(KeycloakConfig cfg, Keycloak injected)`: 주입된 `Keycloak` 보관(테스트·양 생성자 공용).
  - `close()`는 `keycloak.close()` 위임. `raw()`는 `keycloak` 반환. 리소스 접근자는 후속 태스크에서 채움.
  > 결합 규칙: 기본 생성자는 auth 모듈·TokenProvider에 의존하지 않는다. 고급 생성자만 `core`의 `TokenProvider`로 느슨히 결합.
- [ ] **Step 5: 통과 확인** · **Step 6: Commit** — `git commit -am "feat(admin): AdminClient 골격·수명주기·raw (WBS 4.1)"`

---

### Task 4.2: 예외 경계 변환

**Files:** Create `.../admin/AdminExceptions.java` · Test `.../admin/AdminExceptionsTest.java`

**Interfaces:**
- Produces: `AdminExceptions.translate(jakarta.ws.rs.WebApplicationException)` → 적절한 `KeycloakAdminException` 하위(404→`KeycloakNotFoundException`, 409→`KeycloakConflictException`, 403→`KeycloakForbiddenException`, 그 외→`KeycloakAdminException`), HTTP status와 응답 본문(Keycloak error) 보존. `<T> T call(Supplier<T>)` 래퍼 — 리소스 메서드가 이걸로 감싸 호출.

- [ ] **Step 1: 실패 테스트**

```java
package io.github.xzawed.keycloak.admin;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.exception.*;
import jakarta.ws.rs.*;
import org.junit.jupiter.api.Test;

class AdminExceptionsTest {
  @Test void notFound_mapsToKeycloakNotFound() {
    KeycloakAdminException e = assertThrows(KeycloakNotFoundException.class,
        () -> AdminExceptions.call(() -> { throw new NotFoundException(); }));
    assertEquals(404, e.getStatus());
  }
  @Test void conflict_mapsToConflict() {
    assertThrows(KeycloakConflictException.class,
        () -> AdminExceptions.call(() -> { throw new ClientErrorException(409); }));
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-admin -Dtest=AdminExceptionsTest` · Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```java
package io.github.xzawed.keycloak.admin;
import io.github.xzawed.keycloak.core.exception.*;
import jakarta.ws.rs.WebApplicationException;
import java.util.function.Supplier;
public final class AdminExceptions {
  private AdminExceptions() {}
  public static <T> T call(Supplier<T> action) {
    try { return action.get(); }
    catch (WebApplicationException e) { throw translate(e); }
  }
  public static void run(Runnable action) { call(() -> { action.run(); return null; }); }
  public static KeycloakAdminException translate(WebApplicationException e) {
    int status = e.getResponse() == null ? 0 : e.getResponse().getStatus();
    String body = safeBody(e);
    return switch (status) {
      case 404 -> new KeycloakNotFoundException(status, body, e);
      case 409 -> new KeycloakConflictException(status, body, e);
      case 403 -> new KeycloakForbiddenException(status, body, e);
      default -> new KeycloakAdminException(status, body, e);
    };
  }
  private static String safeBody(WebApplicationException e) {
    try { return e.getResponse() != null && e.getResponse().hasEntity()
        ? e.getResponse().readEntity(String.class) : e.getMessage(); }
    catch (RuntimeException ex) { return e.getMessage(); }
  }
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(admin): jakarta.ws.rs 예외 → SDK 예외 경계 변환 (WBS 4.2)"`

---

### Task 4.3: `users()` 리소스

**Files:** Create `.../admin/UsersResource.java` · Modify `AdminClient.java`(`users()` 반환) · Test는 통합(6.3)에서 실제 검증; 단위는 위임·예외 변환 경로.

**Interfaces:**
- Produces: `UsersResource{ String create(UserRepresentation); Optional<UserRepresentation> get(String id); List<UserRepresentation> search(String username, int first, int max); void update(String id, UserRepresentation); void delete(String id); }` — 내부적으로 `keycloak.realm(realm).users()`에 위임하고 모든 호출을 `AdminExceptions.call(...)`로 감쌈. (모델 타입은 admin-client의 `org.keycloak.representations.idm.UserRepresentation`을 그대로 사용 — 관용 파사드이므로 재정의하지 않음.)

- [ ] **Step 1: 실패 테스트 (Mockito로 admin-client의 UsersResource 목 주입 — 위임·예외 변환 검증)**

```java
package io.github.xzawed.keycloak.admin;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import jakarta.ws.rs.NotFoundException;
import org.junit.jupiter.api.Test;
import org.keycloak.admin.client.resource.UserResource;
import org.keycloak.admin.client.resource.UsersResource as KcUsers; // 실제는 import 별칭 없이 FQN 사용

class UsersResourceTest {
  @Test void get_missingUser_translatesNotFound() {
    org.keycloak.admin.client.resource.UsersResource kc =
        mock(org.keycloak.admin.client.resource.UsersResource.class);
    UserResource ur = mock(UserResource.class);
    when(kc.get("missing")).thenReturn(ur);
    when(ur.toRepresentation()).thenThrow(new NotFoundException());
    UsersResource users = new UsersResource(kc);
    assertThrows(KeycloakNotFoundException.class, () -> users.get("missing"));
  }
}
```
> 실제 파일에서는 `import ... as ...` 문법이 없으므로 FQN(`org.keycloak.admin.client.resource.UsersResource`)을 사용하고 SDK 클래스는 패키지가 달라 이름 충돌이 없다.

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk-admin -Dtest=UsersResourceTest` · Expected: 컴파일 실패.
- [ ] **Step 3: 구현** — 생성자 `UsersResource(org.keycloak.admin.client.resource.UsersResource delegate)`; 각 메서드가 `AdminExceptions.call(() -> delegate...)`로 위임(`create`는 Response의 Location에서 id 추출, `get`은 NotFound→`Optional.empty()`가 아니라 예외 그대로 전파하되 테스트대로 변환). `AdminClient.users()`는 `new UsersResource(raw().realm(config.getRealm()).users())` 반환.
- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(admin): users() 리소스 파사드 (WBS 4.3)"`

---

### Task 4.4~4.7: `clients()` / `realms()` / `roles()` / `groups()`

각 태스크는 **4.3과 동일한 패턴**을 각 리소스에 적용한다(위임 + `AdminExceptions.call`). 재사용을 위해 코드를 반복 기재한다.

- **4.4 `clients()`**: `ClientsResource{ String create(ClientRepresentation); Optional<ClientRepresentation> get(String id); List<ClientRepresentation> findByClientId(String clientId); void update(String id, ClientRepresentation); void delete(String id); }` → `raw().realm(realm).clients()` 위임. 테스트: 존재하지 않는 client get → NotFound 변환. Commit: `feat(admin): clients() 파사드 (WBS 4.4)`.
- **4.5 `realms()`**: `RealmsResource{ void create(RealmRepresentation); Optional<RealmRepresentation> get(String realmName); void delete(String realmName); }` → `raw().realms()` 위임. Commit: `feat(admin): realms() 파사드 (WBS 4.5)`.
- **4.6 `roles()`**: `RolesResource{ void create(RoleRepresentation); Optional<RoleRepresentation> get(String name); List<RoleRepresentation> list(); void delete(String name); }` → `raw().realm(realm).roles()` 위임. Commit: `feat(admin): roles() 파사드 (WBS 4.6)`.
- **4.7 `groups()`**: `GroupsResource{ String create(GroupRepresentation); Optional<GroupRepresentation> get(String id); List<GroupRepresentation> list(int first, int max); void delete(String id); }` → `raw().realm(realm).groups()` 위임. Commit: `feat(admin): groups() 파사드 (WBS 4.7)`.

각 태스크 TDD 사이클: (1) 해당 리소스 목으로 NotFound/Conflict 변환 테스트 작성 → (2) 실패 확인 → (3) 위임 구현 + `AdminClient`에 접근자 추가 → (4) 통과 → (5) commit.

---

### Task 4.8: `raw()` 탈출구

4.1에서 이미 `raw()`를 노출했다. 여기서는 **문서화 테스트**만 추가: `raw()`가 반환하는 `Keycloak`으로 파사드가 감싸지 않은 엔드포인트(예: `serverInfo()`)에 접근 가능함을 통합 테스트(6.3)에서 1케이스 확인. 별도 커밋 불필요(6.3에 포함).

---

# Phase 5 — facade 모듈

### Task 5.1: `KeycloakClient`

**Files:** Modify `java/keycloak-sdk/pom.xml`(core+auth+admin 의존) · Create `.../keycloak/KeycloakClient.java` · Test `.../keycloak/KeycloakClientTest.java`

**Interfaces:**
- Produces: `KeycloakClient implements AutoCloseable` — `static KeycloakClient create(KeycloakConfig)`. `AuthClient auth()`, `AdminClient admin()`, `close()`(admin·auth 자원 정리). 내부에서 `OidcMetadata.forRealm(config)` → `AuthClient` 생성 → `ClientCredentialsTokenProvider`로 `AdminClient` 구성(admin이 auth의 client-credentials 토큰을 `TokenProvider`로 소비, 단 결합은 `TokenProvider` 인터페이스로만).
- Consumes: 전 Phase의 공개 타입.

- [ ] **Step 1: 실패 테스트**

```java
package io.github.xzawed.keycloak;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import org.junit.jupiter.api.Test;

class KeycloakClientTest {
  @Test void create_wiresAuthAndAdmin() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s".toCharArray()).build();
    try (KeycloakClient kc = KeycloakClient.create(c)) {
      assertNotNull(kc.auth());
      assertNotNull(kc.admin());
    }
  }
}
```

- [ ] **Step 2: 실패 확인** — Run: `mvn -q -f java/pom.xml test -pl keycloak-sdk -Dtest=KeycloakClientTest` · Expected: 컴파일 실패(의존 추가 필요).
- [ ] **Step 3: pom 의존 추가 + 구현**

```xml
<!-- java/keycloak-sdk/pom.xml -->
<dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk-core</artifactId><version>${project.version}</version></dependency>
<dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk-auth</artifactId><version>${project.version}</version></dependency>
<dependency><groupId>io.github.xzawed</groupId><artifactId>keycloak-sdk-admin</artifactId><version>${project.version}</version></dependency>
```
```java
package io.github.xzawed.keycloak;
import io.github.xzawed.keycloak.admin.AdminClient;
import io.github.xzawed.keycloak.auth.*;
import io.github.xzawed.keycloak.core.*;

public final class KeycloakClient implements AutoCloseable {
  private final AuthClient auth; private final AdminClient admin;
  private KeycloakClient(AuthClient auth, AdminClient admin) { this.auth = auth; this.admin = admin; }
  public static KeycloakClient create(KeycloakConfig config) {
    OidcMetadata md = OidcMetadata.forRealm(config);
    AuthClient auth = new AuthClient(config, md);
    AdminClient admin = new AdminClient(config);   // 기본: 네이티브 client-credentials 그랜트 (auth와 독립)
    return new KeycloakClient(auth, admin);
  }
  public AuthClient auth() { return auth; }
  public AdminClient admin() { return admin; }
  @Override public void close() { admin.close(); }
}
```

- [ ] **Step 4: 통과 확인** · **Step 5: Commit** — `git commit -am "feat(sdk): KeycloakClient 통합 진입점 (WBS 5.1)"`

---

# Phase 6 — 통합 테스트 (Testcontainers)

> `keycloak-sdk` 모듈 test 의존에 추가: `com.github.dasniko:testcontainers-keycloak:4.2.1`, `org.testcontainers:testcontainers-junit-jupiter:2.0.5`(⚠️ 구 `junit-jupiter` 아님), `org.testcontainers:testcontainers:2.0.5`. IT는 `*IT.java` 네이밍 + `maven-failsafe-plugin`(또는 surefire에서 `-DskipITs` 게이팅). 6.1 Step에서 설정.

### Task 6.1: Testcontainers 하네스 + realm import

**Files:** Modify `java/keycloak-sdk/pom.xml`(failsafe + test deps) · Create `java/keycloak-sdk/src/test/resources/test-realm.json` · Create `.../keycloak/KeycloakContainerSupport.java`(공유 컨테이너)

**Interfaces:**
- Produces: `@Testcontainers` 지원 베이스 — `static KeycloakContainer` (`quay.io/keycloak/keycloak:26.6`) `.withRealmImportFile("/test-realm.json")`. `test-realm.json`은 realm `it-realm`, confidential client `it-client`(secret 고정), service account 활성 + `realm-management` 역할 부여(admin 호출용), 테스트 사용자 1명.

- [ ] **Step 1: realm import JSON 작성** — `it-realm` + `it-client`(serviceAccountsEnabled, secret `it-secret`, `realm-management`의 `manage-users`/`manage-clients` 역할) + 사용자 `alice`.
- [ ] **Step 2: failsafe + test 의존 설정** — `maven-failsafe-plugin` 실행(`integration-test`/`verify` goal), 위 3개 test 의존 추가.
- [ ] **Step 3: 컨테이너 부팅 스모크 IT**

```java
package io.github.xzawed.keycloak;
import static org.junit.jupiter.api.Assertions.*;
import dasniko.testcontainers.keycloak.KeycloakContainer;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.*;

@Testcontainers
class KeycloakContainerSmokeIT {
  @Container static KeycloakContainer KC =
      new KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/test-realm.json");
  @Test void containerStarts() { assertTrue(KC.isRunning()); assertNotNull(KC.getAuthServerUrl()); }
}
```

- [ ] **Step 4: 실행** — Run: `mvn -q -f java/pom.xml verify -pl keycloak-sdk` (Docker 필요) · Expected: 컨테이너 기동, IT PASS.
- [ ] **Step 5: Commit** — `git commit -am "test(it): Testcontainers Keycloak 하네스 + realm import (WBS 6.1)"`

---

### Task 6.2: 인증 흐름 E2E

**Files:** Create `.../keycloak/AuthFlowIT.java`

- [ ] **Step 1: IT 작성** — 컨테이너의 `it-realm`/`it-client`/`it-secret`로 `KeycloakConfig` 구성(serverUrl=`KC.getAuthServerUrl()`). (a) `auth().clientCredentialsToken()`이 non-null access token 반환, (b) 그 토큰을 `auth().validate(token)`이 통과시키고 issuer가 `.../realms/it-realm`, (c) `auth().introspect(token)`가 active=true.
- [ ] **Step 2: 실행** — Run: `mvn -q -f java/pom.xml verify -pl keycloak-sdk -Dit.test=AuthFlowIT` · Expected: PASS.
- [ ] **Step 3: Commit** — `git commit -am "test(it): 인증 흐름 E2E (client-credentials·검증·introspect) (WBS 6.2)"`

---

### Task 6.3: 관리 작업 E2E

**Files:** Create `.../keycloak/AdminOpsIT.java`

- [ ] **Step 1: IT 작성** — `KeycloakClient.create(config)`로 (a) `admin().users().create(...)` → id 반환, (b) `get(id)`로 조회 일치, (c) `search("newuser",0,10)` 목록에 포함, (d) `delete(id)` 후 `get`이 `KeycloakNotFoundException`, (e) `admin().raw().serverInfo().getInfo()` non-null(탈출구 4.8 확인).
- [ ] **Step 2: 실행** — Run: `mvn -q -f java/pom.xml verify -pl keycloak-sdk -Dit.test=AdminOpsIT` · Expected: PASS.
- [ ] **Step 3: Commit** — `git commit -am "test(it): 관리 작업 E2E (user CRUD + raw) (WBS 6.3)"`

---

# Phase 7 — 배포 & 문서

### Task 7.1: Maven Central 배포 플러그인 설정

**Files:** Modify `java/pom.xml`(release 프로파일: sources/javadoc/gpg/central-publishing)

**Interfaces:**
- Produces: `release` 프로파일 — `maven-source-plugin`(sources jar), `maven-javadoc-plugin`(javadoc jar), `maven-gpg-plugin`(.asc 서명), `org.sonatype.central:central-publishing-maven-plugin:0.11.0`(`<extensions>true</extensions>`, `<publishingServerId>central</publishingServerId>`). 배포 대상은 `keycloak-sdk-bom`/`core`/`auth`/`admin`/`keycloak-sdk`(examples 제외 `<skip>`).

- [ ] **Step 1: release 프로파일 추가** — 위 4개 플러그인을 `<profile id=release>`에 구성. `keycloak-sdk-examples`는 `<maven.deploy.skip>true</maven.deploy.skip>`.
- [ ] **Step 2: 로컬 산출물 검증** — Run: `mvn -q -f java/pom.xml -Prelease -DskipTests -Dgpg.skip=true package` · Expected: 각 모듈 `*-sources.jar`/`*-javadoc.jar` 생성.
- [ ] **Step 3: Commit** — `git commit -am "build: Maven Central(Central Portal) 배포 프로파일 (WBS 7.1)"`

---

### Task 7.2: 릴리스 CI (태그 드리븐)

**Files:** Create `.github/workflows/release.yml`

- [ ] **Step 1: 워크플로 작성** — `on: push: tags: ['v*']`. GPG 개인키·Central Portal 토큰을 GitHub Secrets(`MAVEN_GPG_PRIVATE_KEY`, `MAVEN_GPG_PASSPHRASE`, `CENTRAL_TOKEN_USER`, `CENTRAL_TOKEN_PW`)에서 주입, `setup-java`의 `server-id: central` + `gpg-private-key`. `mvn -B -Prelease deploy`.
- [ ] **Step 2: 검증** — 워크플로 문법 확인(`act` 또는 push 전 dry). Secrets 미설정 시 배포 스텝은 tag push에서만 동작. (배포 전 확인 항목: GPG 키 생성·키서버 배포, Central Portal 토큰 발급 — 스펙 §11.)
- [ ] **Step 3: Commit & push** — `git commit -am "ci: 태그 드리븐 Maven Central 릴리스 (WBS 7.2)" && git push`

---

### Task 7.3: examples 모듈

**Files:** Create `java/keycloak-sdk-examples/pom.xml` + `src/main/java/.../QuickStart.java` · 부모 `<modules>`에 추가

- [ ] **Step 1: 모듈 추가 + 예제 작성** — `KeycloakConfig` 구성 → `KeycloakClient.create` → client-credentials 토큰 출력(마스킹) + user 목록 조회 예제. `<maven.deploy.skip>true</maven.deploy.skip>`.
- [ ] **Step 2: 빌드 확인** — Run: `mvn -q -f java/pom.xml -pl keycloak-sdk-examples compile` · Expected: SUCCESS.
- [ ] **Step 3: Commit** — `git commit -am "docs(examples): QuickStart 예제 (WBS 7.3)"`

---

### Task 7.4: 문서 최신화

**Files:** Modify `README.md`, `CLAUDE.md`, `docs/`

- [ ] **Step 1: 빌드/테스트 명령 추가** — `CLAUDE.md`에 실제 명령 기입: 전체 빌드 `mvn -f java/pom.xml verify`, 단위만 `mvn -f java/pom.xml test -DskipITs=true`, 단일 테스트 `mvn -f java/pom.xml test -pl <module> -Dtest=<ClassName>#<method>`, 통합 `mvn -f java/pom.xml verify`(Docker 필요). "현재 상태" 섹션을 "구현됨"으로 갱신.
- [ ] **Step 2: README 사용 예제** — QuickStart 코드 스니펫, 의존성 좌표(`io.github.xzawed:keycloak-sdk`), 호환 매트릭스(SDK ↔ Keycloak 서버 26.6.x) 추가.
- [ ] **Step 3: Commit & push** — `git add -A && git commit -m "docs: 빌드 명령·사용 예제·호환 매트릭스 최신화 (WBS 7.4)" && git push`

---

## 자체 검토 (Self-Review)

**Spec 커버리지**: §3 구조→WBS 1,5 · §4 언어중립계약→WBS 전반(관용 파사드 명명) · §5 API(config/auth/admin)→2.2,3.x,4.x · §6.1 예외→2.1,4.2 · §6.2 보안(마스킹/시크릿/TLS/PKCE)→2.5,2.2,3.2,3.3 · §6.3 JWT 강화→3.6 · §6.4 스레드안전·수명주기→3.8,4.1 · §6.5 회복탄력성→2.2(타임아웃), 3.x(재시도는 후속 개선으로 표기) · §7 의존성/BOM→1.2 · §8 테스트→2~6 · §9 배포/버전→1.1(SemVer 0.1.0),7.1,7.2 · §10 Python→비범위(별도 스펙) · §11 배포 전 항목→7.2 Step2.

**갭·주의**: (1) §6.5의 지수 백오프 재시도는 MVP에서 타임아웃까지만 구현하고 재시도 정책은 후속 개선 항목으로 명시(YAGNI — 통합 테스트 안정화 후 추가). (2) admin의 `TokenProvider` 토큰 주입 방식은 admin-client 버전별 API에 따라 4.1 구현 시 실제 클래스(`KeycloakBuilder`)로 확정한다. (3) Docker 미가용 환경에서는 Phase 6 IT를 `-DskipITs=true`로 건너뛰고 단위 테스트만 실행.

**플레이스홀더 스캔**: TODO/TBD 없음. 각 코드 스텝은 실제 코드 포함. 반복 리소스(4.4~4.7)는 4.3 패턴을 인터페이스·커밋 메시지까지 구체화.

**타입 일관성**: `TokenProvider.getAccessToken():String`, `TokenSet` 생성자 6인자, `AdminExceptions.call/run`, 예외 생성자 시그니처가 전 태스크에서 일치.
