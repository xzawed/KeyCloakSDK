# KeyCloak SDK (다국어)

Keycloak을 위한 **다국어 SDK**. **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** 를 모두 다루며, 언어마다 관용적이면서도 개념·계층·흐름이 동형인 SDK를 제공합니다.

- **기준 언어**: Java 17 · Maven (구현 완료)
- **향후**: Python
- **라이선스**: Apache-2.0

## 전략

> 언어마다 **가장 좋은 기반**을 사용 — 공식 클라이언트가 있으면 감싸고(Java: `keycloak-admin-client`), 없으면 OpenAPI 명세에서 코드 생성(Python) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다.

- **Admin API**: Java는 공식 `org.keycloak:keycloak-admin-client` 래핑.
- **인증**: 프로토콜 재구현 없이 Java는 Nimbus OAuth2/OIDC SDK 래핑 (Authorization Code+PKCE, Client Credentials, 토큰 검증/갱신).

## 설치 (Maven)

> ⚠️ 현재 버전 `0.1.0-SNAPSHOT`은 아직 Maven Central에 배포되지 않았습니다. 배포 프로파일(`-Prelease`)과 태그 드리븐 릴리스 CI는 준비되어 있으나, 실제 배포는 사람이 `v*` 태그를 push해야 트리거됩니다(human-gated). 배포 전에는 `mvn install`로 로컬 `~/.m2`에 설치해 사용하세요.

파사드 아티팩트 하나만 추가하면 `core`/`auth`/`admin`이 함께 따라옵니다:

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0-SNAPSHOT</version>
</dependency>
```

여러 모듈(`keycloak-sdk-core`/`-auth`/`-admin`)을 개별적으로 쓰거나 전이 의존(admin-client, Nimbus) 버전을 SDK와 일치시키려면 BOM을 임포트하세요:

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>io.github.xzawed</groupId>
      <artifactId>keycloak-sdk-bom</artifactId>
      <version>0.1.0-SNAPSHOT</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>

<dependencies>
  <dependency>
    <groupId>io.github.xzawed</groupId>
    <artifactId>keycloak-sdk</artifactId>
    <!-- 버전은 BOM이 관리 -->
  </dependency>
</dependencies>
```

## QuickStart

`KeycloakConfig` → `KeycloakClient.create(...)` 로 인증(`auth()`)과 관리(`admin()`) API를 함께 조립합니다. 전체 실행 가능한 코드는 [`java/keycloak-sdk-examples/.../QuickStart.java`](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java)에 있습니다.

```java
KeycloakConfig config = KeycloakConfig.builder()
    .serverUrl("https://kc.example.com")
    .realm("myrealm")
    .clientId("admin-cli")
    .clientSecret("changeme".toCharArray())
    .build();

try (KeycloakClient client = KeycloakClient.create(config)) {
  // client-credentials 토큰 발급 — 원문은 절대 출력하지 않고 마스킹한다.
  TokenSet tokens = client.auth().clientCredentialsToken();
  System.out.println("Access token: " + Secrets.mask(tokens.getAccessToken()));

  // 관리 API로 사용자 목록 조회 (최대 20명).
  List<UserRepresentation> users = client.admin().users().search(null, 0, 20);
  users.forEach(u -> System.out.println(" - " + u.getUsername()));
}
```

로컬에서 예제 모듈만 컴파일 확인:

```bash
mvn -f java/pom.xml -pl keycloak-sdk-examples -am compile
```

## 호환성

| SDK 버전 | Keycloak 서버 | `keycloak-admin-client` |
|---|---|---|
| `0.1.0-SNAPSHOT` | 26.6.x (통합테스트: 실제 Keycloak **26.6.4**) | **26.0.10** (서버와 독립된 버전 트랙 — "26.6.x admin-client"는 존재하지 않음) |

SDK 자체 SemVer는 Keycloak 서버 버전과 분리되어 있습니다. 지원 서버 범위는 이 표(호환 매트릭스)로 안내하며, 새 Keycloak major/minor가 검증되면 갱신합니다.

## 현재 상태

**구현 완료** — Java SDK(6개 모듈: bom/core/auth/admin/keycloak-sdk/examples)가 `feature/java-sdk-mvp` 브랜치에서 구현·단위테스트·통합테스트(Testcontainers, 실제 Keycloak 26.6.4)까지 완료됐습니다(GREEN `mvn -f java/pom.xml clean verify`). Maven Central 배포는 사람 승인 후 태그 릴리스로 진행됩니다.

- 📄 설계 스펙: [docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md)
- 🗂️ 구현 계획(WBS): [docs/superpowers/plans/](docs/superpowers/plans/)
- 📝 검증 로그: [docs/governance/verification-log.md](docs/governance/verification-log.md)

## 개발자 안내

프로젝트 구조·아키텍처·빌드 명령·게이트/게차(gotchas)는 [CLAUDE.md](CLAUDE.md)를 참고하세요.
