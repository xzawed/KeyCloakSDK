# 시작하기 (Getting Started)

Keycloak polyglot SDK를 로컬에서 설치하고, 첫 토큰 발급 · JWT 검증 · 관리 API 호출까지 최소 코드로 실행하는 안내입니다. 이 SDK는 **여러 프로그래밍 언어**(현재 Java · Python)로 제공되며, 언어마다 관용적이되 개념·계층·흐름은 동형(isomorphic)입니다.

> ⚠️ **두 SDK 모두 아직 미배포입니다(`0.1.0-SNAPSHOT` / `0.1.0`, human-gated 릴리스).** Maven Central·PyPI를 통한 설치는 아직 동작하지 않습니다. 현재는 **로컬 설치가 기본 경로**입니다(아래 각 언어의 "로컬 설치" 참고). 실배포 절차는 [DEPLOY.md](../../DEPLOY.md)를 참고하세요.

## 요구 런타임

| 언어 | 최소 런타임 | 비고 |
|---|---|---|
| **Java** | **JDK 21+** | 아티팩트가 `--release 21`로 컴파일되어 이전 JDK에서는 `UnsupportedClassVersionError` 발생 |
| **Python** | **3.10+** | `py.typed`(PEP 561) 포함 — 소비자 측 mypy 타입 검사 가능 |
| (선택) Docker | — | **통합 테스트(Testcontainers)에만 필요**. SDK 사용 자체에는 불필요 |

---

## Java

### 1) 요구 런타임 — JDK 21+

아티팩트는 `--release 21`로 컴파일됩니다. **JDK 21 미만에서 로드하면 `UnsupportedClassVersionError`가 발생**하므로, 소비 애플리케이션도 JDK 21 이상에서 빌드·실행해야 합니다. (초기 Java 17 기준에서 2026-07-03 21 LTS로 상향되었습니다.)

### 2) 로컬 설치 (현재 — 미배포)

Maven Central 미배포 상태이므로, 리포지토리를 클론한 뒤 로컬 `~/.m2`에 설치합니다. `-DskipITs=true`는 **Docker가 필요한 Testcontainers 통합테스트만** 건너뛰고 단위테스트·커버리지 게이트는 그대로 실행하므로, Docker 없이 설치할 수 있습니다:

```bash
mvn -f java/pom.xml install -DskipITs=true
```

설치 후 소비 프로젝트에서 파사드 아티팩트 하나만 추가하면 `core`/`auth`/`admin`이 전이 의존으로 따라옵니다:

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0-SNAPSHOT</version>
</dependency>
```

### 3) 배포 후 설치 (미래)

Maven Central 배포가 완료되면 동일한 좌표를 릴리스 버전으로 참조하면 됩니다(로컬 `install` 불필요):

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0</version>
</dependency>
```

> ⚠️ **아직 Maven Central에 배포되지 않았습니다(human-gated).** 실제 배포는 사람이 `v*` 태그를 push해 [`.github/workflows/release.yml`](../../.github/workflows/release.yml)를 트리거해야 실행됩니다. 절차는 [DEPLOY.md](../../DEPLOY.md), 향후 언어 확장 로드맵은 [언어 지원 로드맵](../roadmap/language-support.md)을 참고하세요.

### 4) 최소 사용 예

전체 예제: [`java/keycloak-sdk-examples/.../QuickStart.java`](../../java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java)

```java
import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.Secrets;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.auth.ValidatedToken;
import java.util.List;
import org.keycloak.representations.idm.UserRepresentation;

KeycloakConfig config = KeycloakConfig.builder()
    .serverUrl("https://kc.example.com").realm("myrealm")
    .clientId("admin-cli").clientSecret("changeme".toCharArray())
    .build();

// try-with-resources: close()가 admin + auth 세션까지 정리한다.
try (KeycloakClient client = KeycloakClient.create(config)) {
  // 1) client-credentials 그랜트로 토큰 발급. 원문은 절대 로그에 남기지 않고 마스킹한다.
  TokenSet tokens = client.auth().clientCredentialsToken();
  System.out.println("Access token: " + Secrets.mask(tokens.getAccessToken()));

  // 2) 발급받은 액세스 토큰을 자체 강화 검증(알고리즘 핀닝·iss 정확일치·aud 포함검사·클록 스큐).
  ValidatedToken vt = client.auth().validate(tokens.getAccessToken());
  System.out.println("subject=" + vt.getSubject() + " aud=" + vt.getAudience());

  // 3) 관리 API — 사용자 생성(CRUD). create()는 생성된 사용자 id(String)를 반환한다.
  UserRepresentation newUser = new UserRepresentation();
  newUser.setUsername("alice");
  newUser.setEnabled(true);
  String userId = client.admin().users().create(newUser);
  System.out.println("created userId=" + userId);

  // (참고) 목록 조회
  List<UserRepresentation> users = client.admin().users().search(null, 0, 20);
  users.forEach(u -> System.out.println(" - " + u.getUsername()));
}
```

---

## Python

### 1) 요구 런타임 — Python 3.10+

Python 3.10 이상이 필요합니다. 패키지는 PEP 561 `py.typed` 마커를 포함하므로 소비자 측에서도 `mypy`로 타입 검사가 가능합니다.

### 2) 로컬 설치 (현재 — 미배포)

PyPI 미배포 상태이므로, 리포지토리를 클론한 뒤 editable 설치하거나 로컬 빌드합니다:

```bash
pip install -e python
# 또는 배포용 아티팩트를 로컬에서 빌드해 확인:
cd python && python -m build   # dist/keycloak_sdk-0.1.0-py3-none-any.whl + .tar.gz
```

배포명은 `keycloak-sdk`, 임포트 패키지명은 `keycloak_sdk`입니다.

### 3) 배포 후 설치 (미래)

PyPI 배포가 완료되면:

```bash
pip install keycloak-sdk
```

> ⚠️ **아직 PyPI에 배포되지 않았습니다(human-gated, PyPI Trusted Publisher / OIDC).** 실제 배포는 사람이 `py-v*` 태그를 push해 [`.github/workflows/python-release.yml`](../../.github/workflows/python-release.yml)를 트리거해야 실행됩니다. 절차는 [DEPLOY.md](../../DEPLOY.md), 향후 언어 확장 로드맵은 [언어 지원 로드맵](../roadmap/language-support.md)을 참고하세요.

### 4) 최소 사용 예

전체 예제: [`python/examples/quickstart.py`](../../python/examples/quickstart.py) · async 예제: [`python/examples/async_quickstart.py`](../../python/examples/async_quickstart.py)

```python
from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk._internal.secrets import mask

config = KeycloakConfig(
    server_url="https://kc.example.com",
    realm="myrealm",
    client_id="admin-cli",
    client_secret="changeme",  # 실제 값은 환경변수/시크릿 매니저에서 로드할 것
)

# with 블록: __exit__가 admin + auth 세션까지 정리한다.
with KeycloakClient.create(config) as kc:
    # 1) client-credentials 토큰 발급. 원문은 절대 로그에 남기지 않고 마스킹한다.
    token = kc.auth.client_credentials_token()
    print(f"access_token={mask(token.access_token)} token_type={token.token_type}")

    # 2) 발급받은 액세스 토큰을 자체 강화 검증(알고리즘 핀닝·iss 정확일치·aud 포함검사·클록 스큐).
    vt = kc.auth.validate(token.access_token)
    print(f"subject={vt.subject} aud={vt.audience}")

    # 3) 관리 API — 사용자 생성(CRUD). create()는 생성된 사용자 id(str)를 반환한다.
    user_id = kc.admin.users.create({"username": "alice", "enabled": True})
    print(f"created user_id={user_id}")

    # (참고) 목록 조회
    users = kc.admin.users.search(first=0, max=20)
    print(f"users={[u.get('username') for u in users]}")
```

**async가 필요하면** (FastAPI 등 이벤트 루프 안전) `keycloak_sdk.aio.AsyncKeycloakClient`를 쓰고 각 호출에 `await`를 붙입니다 — 전체 예제: [`python/examples/async_quickstart.py`](../../python/examples/async_quickstart.py).

---

## 다음 단계

- **언어 지원 로드맵** — 현재 지원 언어와 향후 확장(깊이 우선: TypeScript/Node → Go → C# → PHP → Rust → Ruby, Kotlin은 JVM 재사용으로 선택적): [../roadmap/language-support.md](../roadmap/language-support.md)
- **새 언어 추가 플레이북** — 기존 Java/Python과 동형의 품질로 언어를 추가하는 절차: [add-a-language-playbook.md](add-a-language-playbook.md)

> 언어 중립 API 계약(진실 원천)은 [설계 스펙 §4](../superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md)에 정의되어 있습니다. 모든 언어는 이 계약을 구현하며, JWT 검증 강화(알고리즘 핀닝 · `none` 거부 · `iss` 정확일치 · `aud` 포함검사 · 클록 스큐 · DoS-안전 JWKS 재조회)는 언어 공통 필수 사항입니다. 현재 테스트 수: **Java 123개**(단위 117 + Testcontainers 통합 6) · **Python 235개**(단위 224 + 통합 11).
