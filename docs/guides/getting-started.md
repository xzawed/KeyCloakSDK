# 시작하기 (Getting Started)

Keycloak polyglot SDK를 로컬에서 설치하고, 첫 토큰 발급 · JWT 검증 · 관리 API 호출까지 최소 코드로 실행하는 안내입니다. 이 SDK는 **여러 프로그래밍 언어**(현재 Java · Python · Node.js · Go · C#/.NET · PHP · Rust)로 제공되며, 언어마다 관용적이되 개념·계층·흐름은 동형(isomorphic)입니다.

> ⚠️ **일곱 SDK 모두 아직 미배포입니다(human-gated 릴리스).** Maven Central·PyPI·npm·Go 모듈 태그·NuGet·Packagist·crates.io를 통한 설치는 아직 동작하지 않습니다. 현재는 **로컬 설치가 기본 경로**입니다(아래 각 언어의 "로컬 설치" 참고). 실배포 절차는 [DEPLOY.md](../../DEPLOY.md)를 참고하세요.

> 🖥️ **먼저 Keycloak *서버*가 필요합니다.** 이 SDK는 클라이언트 라이브러리라 **붙을 Keycloak 서버**가 있어야 동작합니다(서버는 이 SDK에 포함되지 않는 별도 완제품). 로컬 체험은 Docker 한 줄 `docker run -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin quay.io/keycloak/keycloak:26.6 start-dev`, **프로덕션 배포**는 [Keycloak 서버 배포 가이드](deploying-keycloak-server.md)를 참고하세요.

## 요구 런타임

| 언어 | 최소 런타임 | 비고 |
|---|---|---|
| **Java** | **JDK 21+** | 아티팩트가 `--release 21`로 컴파일되어 이전 JDK에서는 `UnsupportedClassVersionError` 발생 |
| **Python** | **3.10+** | `py.typed`(PEP 561) 포함 — 소비자 측 mypy 타입 검사 가능 |
| **Node.js** | **20+** | ESM 전용 · async-only · `.d.ts` 타입 선언 포함 |
| **Go** | **1.25+** | sync + `context.Context` · `x/oauth2` v0.36 요구 |
| **C# / .NET** | **8+** | async-first(`Task<T>`+`CancellationToken`) · `net8.0` 타깃 |
| **PHP** | **8.3+** | `final readonly class` 값타입 · 예외 기반(`KeycloakException` 계급) |
| **Rust** | **1.88+** | edition 2024 + let-chains 요구 MSRV · async-only(tokio) · `thiserror` 기반 `KeycloakError` |
| (선택) Docker | — | **통합 테스트(Testcontainers/docker CLI)에만 필요**. SDK 사용 자체에는 불필요 |

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

## Node.js / TypeScript

### 1) 요구 런타임 — Node 20+

Node.js **20 이상**이 필요합니다. 패키지는 **ESM 전용**(`"type":"module"`)이며 모든 공개 메서드가 `async`(Promise)입니다(`createAuthorizationRequest`만 동기). TypeScript 타입 선언(`.d.ts`)을 포함해 소비자 측에서도 타입 검사가 가능합니다.

### 2) 로컬 설치 (현재 — 미배포)

npm 미배포 상태이므로, 리포지토리를 클론한 뒤 `node/`에서 빌드해 참조합니다:

```bash
cd node && npm ci && npm run build   # dist/ 생성(tsc). npm link 또는 파일 참조로 소비.
# 배포용 아티팩트 확인(업로드 없이): npm pack --dry-run   # dist만 포함(24kB)
```

배포명은 `@xzawed/keycloak-sdk`, import 경로도 동일합니다.

### 3) 배포 후 설치 (미래)

npm 배포가 완료되면:

```bash
npm install @xzawed/keycloak-sdk
```

> ⚠️ **아직 npm에 배포되지 않았습니다(human-gated, npm Trusted Publishing / OIDC + provenance).** 실제 배포는 사람이 `node-v*` 태그를 push해 [`.github/workflows/node-release.yml`](../../.github/workflows/node-release.yml)를 트리거해야 실행됩니다. 절차는 향후 [언어 지원 로드맵](../roadmap/language-support.md)을 참고하세요.

### 4) 최소 사용 예

전체 예제: [`node/examples/quickstart.ts`](../../node/examples/quickstart.ts)

```ts
import { KeycloakClient } from '@xzawed/keycloak-sdk'

const client = KeycloakClient.create({
  serverUrl: 'https://kc.example.com',
  realm: 'myrealm',
  clientId: 'admin-cli',
  clientSecret: 'changeme', // 실제 값은 환경변수/시크릿 매니저에서 로드할 것(config는 로깅 시 마스킹됨)
})

try {
  // 1) client-credentials 토큰 발급. TokenSet의 문자열 표현은 자동 마스킹된다(accessToken=***).
  const token = await client.auth.clientCredentialsToken()
  console.log(`token=${token}`)

  // 2) 발급받은 토큰을 자체 강화 검증(알고리즘 핀닝·iss 정확일치·aud 포함검사·클록 스큐).
  const vt = await client.auth.validate(token.accessToken)
  console.log(`subject=${vt.subject} aud=${vt.audience.join(',')}`)

  // 3) 관리 API — admin은 최초 접근 시 지연 생성된다(client_secret 필요). create()는 신규 id를 반환.
  const admin = await client.admin()
  const userId = await admin.users.create({ username: 'alice', enabled: true })
  console.log(`created user_id=${userId}`)
} finally {
  await client.close() // admin + auth 자원 정리. `await using`(Symbol.asyncDispose)로도 가능.
}
```

> **인가 코드(PKCE) 흐름**: `const { url, codeVerifier, state, nonce } = client.auth.createAuthorizationRequest(redirectUri)`로 시작하고, 콜백에서 `client.auth.exchangeCode(code, redirectUri, codeVerifier, nonce)`로 교환합니다 — `nonce`를 반드시 함께 넘겨야 id_token 검증을 통과합니다.

## Go

### 1) 요구 런타임 — Go 1.25+

Go **1.25 이상**이 필요합니다(의존성 `golang.org/x/oauth2` v0.36이 요구). sync + `context.Context` 관용(모든 네트워크 메서드가 `ctx`를 첫 인자로 받고, `CreateAuthorizationRequest`만 동기). Docker는 통합 테스트에만 필요합니다.

### 2) 로컬 설치 (현재 — 미배포)

Go 모듈은 별도 레지스트리 없이 **VCS 태그로 배포**됩니다. 아직 릴리스 태그(`go/vX.Y.Z`)가 없으므로, 모노레포를 클론해 `go/`에서 빌드하거나 `replace` 지시로 참조합니다:

```bash
cd go && go build ./... && go test ./...   # 단위 40 + 커버리지 게이트(로직 ≥90)
# 소비 프로젝트에서 로컬 참조: go.mod에 `replace github.com/xzawed/KeyCloakSDK/go => ../KeyCloakSDK/go`
```

모듈 경로는 `github.com/xzawed/KeyCloakSDK/go`, 패키지명은 `keycloak`입니다.

### 3) 배포 후 설치 (미래)

릴리스 태그가 push되면:

```bash
go get github.com/xzawed/KeyCloakSDK/go@v0.1.0
```

> ⚠️ **아직 릴리스 태그가 없습니다(human-gated).** Go는 레지스트리 배포가 없어 **태그가 곧 릴리스**입니다 — 사람이 `go/v*` 태그를 push하면 [`.github/workflows/go-release.yml`](../../.github/workflows/go-release.yml)가 검증 + GitHub Release + 프록시 워밍을 수행하고, `proxy.golang.org`가 태그에서 자동 캐시합니다. 저장 시크릿은 필요 없습니다.

### 4) 최소 사용 예

전체 예제(godoc): [`go/example_test.go`](../../go/example_test.go)

```go
package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/Nerzal/gocloak/v13"
	keycloak "github.com/xzawed/KeyCloakSDK/go"
)

func main() {
	client, err := keycloak.New(keycloak.Config{
		ServerURL:    "https://kc.example.com",
		Realm:        "myrealm",
		ClientID:     "admin-cli",
		ClientSecret: "changeme", // 환경변수/시크릿 매니저에서 로드할 것(Config는 로깅 시 마스킹)
	})
	if err != nil {
		panic(err)
	}
	defer client.Close()
	ctx := context.Background()

	// 1) client-credentials 토큰. TokenSet의 String()은 자동 마스킹된다(AccessToken:***).
	token, err := client.Auth.ClientCredentialsToken(ctx)
	if err != nil {
		panic(err)
	}
	fmt.Println(token)

	// 2) 자체 강화 검증(alg 핀·iss 정확일치·aud 포함검사·exp 필수·클록 스큐).
	vt, err := client.Auth.Validate(ctx, token.AccessToken)
	if err != nil {
		panic(err)
	}
	fmt.Println(vt.Subject, vt.Audience)

	// 3) 관리 API — admin은 최초 접근 시 지연 생성(clientSecret 필요). 오류는 errors.Is 센티넬로 분기.
	admin, err := client.Admin(ctx)
	if err != nil {
		panic(err)
	}
	id, err := admin.Users.Create(ctx, gocloak.User{Username: gocloak.StringP("alice"), Enabled: gocloak.BoolP(true)})
	if err != nil {
		panic(err)
	}
	if _, err := admin.Users.Get(ctx, id); errors.Is(err, keycloak.ErrNotFound) {
		fmt.Println("not found")
	}
}
```

> 오류 처리: 관리 API 실패는 `errors.Is(err, keycloak.ErrNotFound)`(·`ErrConflict`·`ErrForbidden`)로 분기하거나 `var ae *keycloak.AdminError; errors.As(err, &ae)`로 `ae.StatusCode`를 얻습니다. 네트워크 실패는 `*keycloak.TransportError`입니다.

## C# / .NET

### 1) 요구 런타임 — .NET 8+

.NET **8 이상**(`net8.0`)이 필요합니다. async-first 관용(모든 네트워크 메서드가 `Task<T>` + 끝자리 `CancellationToken ct = default`를 받고, `CreateAuthorizationRequest`만 순수 동기). Docker는 통합 테스트에만 필요합니다.

### 2) 로컬 설치 (현재 — 미배포)

NuGet 미배포 상태이므로, 리포지토리를 클론한 뒤 소비 프로젝트에서 프로젝트 참조로 붙입니다:

```bash
dotnet add reference ../KeyCloakSDK/dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj
# 로컬 빌드/테스트만 확인: cd dotnet && dotnet build && dotnet test --filter "Category!=Integration"   # 단위 58 + 커버리지 게이트
```

패키지 ID는 `Xzawed.Keycloak.Sdk`, 루트 네임스페이스는 `Xzawed.Keycloak`(admin은 `Xzawed.Keycloak.Admin` 서브네임스페이스)입니다.

### 3) 배포 후 설치 (미래)

NuGet 배포가 완료되면:

```bash
dotnet add package Xzawed.Keycloak.Sdk
```

> ⚠️ **아직 NuGet에 배포되지 않았습니다(human-gated).** 실제 배포는 사람이 `dotnet-v*` 태그를 push해 [`.github/workflows/dotnet-release.yml`](../../.github/workflows/dotnet-release.yml)를 트리거해야 실행됩니다(`NUGET_API_KEY` 시크릿 필요). 절차는 향후 [언어 지원 로드맵](../roadmap/language-support.md)을 참고하세요.

### 4) 최소 사용 예

```csharp
using Keycloak.AuthServices.Sdk.Admin.Models;
using Xzawed.Keycloak;

var config = new KeycloakConfig
{
    ServerUrl = "https://kc.example.com",
    Realm = "myrealm",
    ClientId = "admin-cli",
    ClientSecret = "changeme", // 실제 값은 환경변수/시크릿 매니저에서 로드할 것(ToString/JSON 직렬화는 자동 마스킹됨)
};

// await using: DisposeAsync()가 admin + auth 자원(HttpClient)까지 정리한다. (동기 using도 IDisposable로 지원.)
await using var kc = KeycloakClient.Create(config);

// 1) client-credentials 그랜트로 토큰 발급. TokenSet의 ToString()/JSON 직렬화는 자동 마스킹된다(AccessToken=***).
var tokens = await kc.Auth.ClientCredentialsTokenAsync();
Console.WriteLine(tokens);

// 2) 발급받은 액세스 토큰을 자체 강화 검증(알고리즘 핀닝·iss 정확일치·aud 포함검사·exp 필수·클록 스큐).
var vt = await kc.Auth.ValidateAsync(tokens.AccessToken);
Console.WriteLine($"subject={vt.Subject} aud=[{string.Join(",", vt.Audience)}]");

// 3) 관리 API — admin은 최초 접근 시 지연 생성된다(clientSecret 필요). CreateAsync()는 생성된 사용자 id를 반환.
var admin = await kc.AdminAsync();
var userId = await admin.Users.CreateAsync(new UserRepresentation { Username = "alice", Enabled = true });
Console.WriteLine($"created userId={userId}");

// (참고) 목록 조회
var users = await admin.Users.SearchAsync(username: null, first: 0, max: 20);
foreach (var u in users) Console.WriteLine($" - {u.Username}");
```

> 오류 처리: admin 실패는 `KeycloakNotFoundException`/`KeycloakConflictException`/`KeycloakForbiddenException`(모두 `KeycloakAdminException.StatusCode`를 가짐) 또는 네트워크 실패 시 `KeycloakTransportException`으로 분류됩니다. `admin.Raw`가 하위 `Keycloak.AuthServices.Sdk` 타입드 클라이언트로의 탈출구입니다.

## PHP

### 1) 요구 런타임 — PHP 8.3+

PHP **8.3 이상**이 필요합니다. 값타입은 `final readonly class`(불변)로 선언되고, 예외 기반 관용(`KeycloakException` 계급)을 씁니다. Docker는 통합 테스트에만 필요합니다.

### 2) 로컬 설치 (현재 — 미배포)

Packagist 미배포 상태이므로, 리포지토리를 클론한 뒤 로컬 path repository로 참조하거나 `php/`에서 직접 빌드해 확인합니다:

```bash
cd php && composer install   # 의존성 설치(fschmtt/league/stevenmaguire/firebase 등)
# 소비 프로젝트에서 로컬 참조: composer.json에 path repository 추가
#   { "repositories": [{ "type": "path", "url": "../KeyCloakSDK/php" }] }
#   composer require xzawed/keycloak-sdk:@dev
```

배포명은 `xzawed/keycloak-sdk`, 루트 네임스페이스는 `Xzawed\Keycloak`(admin은 `Xzawed\Keycloak\Admin` 서브네임스페이스)입니다.

### 3) 배포 후 설치 (미래)

Packagist 배포가 완료되면:

```bash
composer require xzawed/keycloak-sdk
```

> ⚠️ **아직 Packagist에 배포되지 않았습니다(human-gated).** Composer/Packagist는 레지스트리 업로드가 아니라 **Packagist가 GitHub 웹훅으로 태그를 감지**해 자동 게시합니다(별도 시크릿 없음). 실제 배포는 사람이 `php-v*` 태그를 push해 [`.github/workflows/php-release.yml`](../../.github/workflows/php-release.yml)를 트리거해야 실행되며, Packagist에 `xzawed/keycloak-sdk` 저장소 등록은 1회 수동 선행이 필요합니다. 향후 언어 확장 로드맵은 [언어 지원 로드맵](../roadmap/language-support.md)을 참고하세요.

### 4) 최소 사용 예

전체 예제: [`php/examples/quickstart.php`](../../php/examples/quickstart.php)

```php
<?php
declare(strict_types=1);
require __DIR__ . '/../vendor/autoload.php';

use Xzawed\Keycloak\{KeycloakClient, KeycloakConfig};
use Fschmtt\Keycloak\Representation\User;

$client = KeycloakClient::create(new KeycloakConfig(
    serverUrl: 'https://kc.example.com',
    realm: 'myrealm',
    clientId: 'admin-cli',
    clientSecret: 'changeme', // 실제 값은 환경변수/시크릿 매니저에서 로드할 것(__toString은 자동 마스킹됨)
));

// 1) client-credentials 그랜트로 토큰 발급. TokenSet의 __toString()은 자동 마스킹된다(accessToken=***).
$token = $client->auth()->clientCredentialsToken();
echo "token type: {$token->tokenType}, expires in: {$token->expiresIn}s\n";

// 2) 발급받은 액세스 토큰을 자체 강화 검증(RS256 핀·iss 정확일치·aud 포함검사·exp 필수·클록 스큐).
$validated = $client->auth()->validate($token->accessToken);
echo "subject: {$validated->subject}, issuer: {$validated->issuer}\n";

// 3) 관리 API — 사용자 생성. fschmtt의 create()는 void를 반환하므로 id는 findIdByUsername()로 후속 조회한다.
$client->admin()->users()->create(new User(username: 'alice', enabled: true));
$userId = $client->admin()->users()->findIdByUsername('alice');
echo "created userId={$userId}\n";
```

> 오류 처리: admin 실패는 `KeycloakNotFoundError`/`KeycloakConflictError`/`KeycloakForbiddenError`(모두 `KeycloakAdminError::getStatusCode()`를 가짐) 또는 네트워크 실패 시 `KeycloakTransportError`로 분류됩니다. `admin()->raw()`가 하위 `Fschmtt\Keycloak\Keycloak` 타입드 클라이언트로의 탈출구입니다.

## Rust

### 1) 요구 런타임 — Rust 1.88+

Rust **1.88 이상**(MSRV — edition 2024 + let-chains 요구)이 필요합니다. async-only(tokio) 관용이며, 예외 대신 `thiserror` 기반 `KeycloakError` enum(`Config`/`Auth`/`Transport`/`Admin`/`TokenValidation`) + `Result<T, KeycloakError>`을 씁니다. Docker는 통합 테스트에만 필요합니다.

### 2) 로컬 설치 (현재 — 미배포)

crates.io 미배포 상태이므로, 리포지토리를 클론한 뒤 소비 프로젝트의 `Cargo.toml`에 path 의존성으로 참조합니다:

```toml
[dependencies]
keycloak-sdk = { path = "../KeyCloakSDK/rust" }
```

```bash
cd rust && cargo build && cargo test   # 로컬 빌드/테스트만 확인: 단위 34개 + 커버리지 게이트
```

크레이트명은 `keycloak-sdk`, 루트 모듈은 `keycloak_sdk`(`keycloak_sdk::{KeycloakClient, KeycloakConfig, ...}`)입니다.

### 3) 배포 후 설치 (미래)

crates.io 배포가 완료되면:

```bash
cargo add keycloak-sdk
```

> ⚠️ **아직 crates.io에 배포되지 않았습니다(human-gated).** 실제 배포는 사람이 `rust-v*` 태그를 push해 [`.github/workflows/rust-release.yml`](../../.github/workflows/rust-release.yml)를 트리거해야 실행됩니다(`CARGO_REGISTRY_TOKEN` 시크릿 필요). 향후 언어 확장 로드맵은 [언어 지원 로드맵](../roadmap/language-support.md)을 참고하세요.

### 4) 최소 사용 예

전체 예제: [`rust/examples/quickstart.rs`](../../rust/examples/quickstart.rs)

```rust
use keycloak::types::UserRepresentation;
use keycloak_sdk::{KeycloakClient, KeycloakConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = KeycloakConfig::new("https://kc.example.com", "myrealm", "admin-cli")?
        .with_client_secret("changeme"); // 실제 값은 환경변수/시크릿 매니저에서 로드할 것(Debug는 마스킹됨)

    let client = KeycloakClient::new(cfg)?;

    // 1) client-credentials 그랜트로 토큰 발급. TokenSet의 Debug는 access/refresh 토큰을 마스킹한다(***).
    let token = client.auth().client_credentials_token().await?;
    println!("token type: {}, expires in: {}s", token.token_type, token.expires_in);

    // 2) 발급받은 액세스 토큰을 자체 강화 검증(RS256 핀·iss 정확일치·aud 포함검사·exp 필수·nbf·클록 스큐).
    let validated = client.auth().validate(&token.access_token).await?;
    println!("subject: {}, issuer: {}", validated.subject, validated.issuer);

    // 3) 관리 API — 사용자 생성. 생성된 id는 응답 Location 헤더에서 추출(없으면 None).
    let user_id = client
        .admin()
        .create_user(UserRepresentation {
            username: Some("alice".into()),
            enabled: Some(true),
            ..Default::default()
        })
        .await?;
    println!("created user_id={user_id:?}");
    Ok(())
}
```

> 오류 처리: admin 실패는 `KeycloakError::Admin(AdminError::NotFound | Conflict | Forbidden | Other { status })`로 매칭하거나 네트워크 실패 시 `KeycloakError::Transport(_)`로 분류됩니다. `admin().raw()`가 하위 `keycloak::KeycloakAdmin` 타입드 클라이언트로의 탈출구입니다.

---

## 다음 단계

- **언어 지원 로드맵** — 현재 지원 언어와 향후 확장(깊이 우선: Java·Python·TypeScript/Node·Go·C#/.NET·PHP·Rust 완료 → Ruby, Kotlin은 JVM 재사용으로 선택적): [../roadmap/language-support.md](../roadmap/language-support.md)
- **새 언어 추가 플레이북** — 기존 Java/Python/Node/Go/C#/PHP/Rust와 동형의 품질로 언어를 추가하는 절차: [add-a-language-playbook.md](add-a-language-playbook.md)

> 언어 중립 API 계약(진실 원천)은 [설계 스펙 §4](../superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md)에 정의되어 있습니다. 모든 언어는 이 계약을 구현하며, JWT 검증 강화(알고리즘 핀닝 · `none` 거부 · `iss` 정확일치 · `aud` 포함검사 · 클록 스큐 · DoS-안전 JWKS 재조회)는 언어 공통 필수 사항입니다. 현재 테스트 수: **Java 123개**(단위 117 + Testcontainers 통합 6) · **Python 235개**(단위 224 + 통합 11) · **Node 76개**(단위 71 + Testcontainers 통합 5) · **Go 41개**(단위 40 + Testcontainers 통합 1 — E2E, 전 흐름·5 admin 리소스) · **C#/.NET 59개**(단위 58 + Testcontainers 통합 1 — E2E `Full_flow`, 전 흐름·5 admin 리소스) · **PHP 67개**(단위 64 + 통합 3 — docker CLI 셸아웃, `FullFlowIT`: 전 흐름·client CRUD·raw 탈출구) · **Rust 35개**(단위 34 + Testcontainers 통합 1 — E2E `full_flow`, 전 흐름·5 admin 리소스).
