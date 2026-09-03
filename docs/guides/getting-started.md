# Getting Started

A guide to installing the Keycloak polyglot SDK locally and running your first token issuance, JWT validation, and Admin API call with minimal code. This SDK is provided in **multiple programming languages** (currently Java · Python · Node.js · Go · C#/.NET · PHP · Rust · Ruby · Kotlin), and while each language is idiomatic, the concepts, layers, and flows are isomorphic.

> ℹ️ **All nine are on a public registry with a stable release** (every language is at `1.0.0` today; that alignment is not a policy, so expect the numbers to diverge again) — PHP (Packagist), Python (PyPI), .NET (NuGet), Rust (crates.io), Ruby (RubyGems), Node (npm), Java (Maven Central), Kotlin (Maven Central) and Go (the Go module proxy). A bare install now resolves `1.0.0` everywhere, which was **not** true while only release candidates existed: pip, Cargo and the `go` command fell back to the prerelease, RubyGems resolved nothing, npm's `latest` pointed at it while a `^0.1.0` range failed with `ETARGET`, and Maven has no prerelease concept at all. Each RC remains on its registry — none of these ecosystems lets you delete a published version — but none of them prefers it any more. Every language also keeps a local-clone path (see each language's "Local installation" below), which is what you want when developing against the SDK itself. For the release procedure, see the unified nine-language [DEPLOY.md](../../DEPLOY.md) (check readiness with `scripts/release-readiness.sh` and tag commands with `scripts/release-trigger.sh <lang> <ver>` — both are human-gates that never push tags automatically).

> 🖥️ **You need a Keycloak *server* first.** This SDK is a client library, so it needs a **Keycloak server to connect to** in order to work (the server is a separate, standalone product not included in this SDK). For a local trial, use the one-line Docker command `docker run -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin quay.io/keycloak/keycloak:26.6 start-dev`; for a **production deployment**, see the [Keycloak server deployment guide](deploying-keycloak-server.md).

> ⚠️ **The validation step of every quickstart below fails on a stock realm — this is expected, and here is why.** Each *Minimal usage example* does three things in order: get a token, `validate()` it, call the Admin API. `validate()` requires the token's `aud` to contain the expected audience, which defaults to your client id. **A stock Keycloak realm does not put the client id into a client-credentials token's `aud`.** So the token issues fine and then validation rejects it. Two ways out, both correct:
> - set the expected audience to what your realm actually issues — the right choice when the token targets a *resource server* rather than the requesting client (`expectedAudience` in Java/Kotlin/Node/PHP, `ExpectedAudience` in .NET/Go, `expected_audience` in Python/Ruby, `.with_expected_audience(…)` in Rust);
> - or add an **Audience** protocol mapper to the client in Keycloak, so the realm issues the audience you expect.
>
> This is a deliberate default, not a rough edge: accepting a token minted for a different audience is the failure the check exists to prevent. Each language's package README repeats it with that language's spelling.

## Required runtime

| Language | Minimum runtime | Notes |
|---|---|---|
| **Java** | **JDK 17+** | Artifacts are compiled with `--release 17`, so older JDKs raise `UnsupportedClassVersionError` |
| **Python** | **3.10+** | Includes `py.typed` (PEP 561) — consumer-side mypy type checking possible |
| **Node.js** | **22+** | ESM-only · async-only · includes `.d.ts` type declarations |
| **Go** | **1.25+** | sync + `context.Context` · requires `x/oauth2` v0.36 |
| **C# / .NET** | **8+** | async-first (`Task<T>` + `CancellationToken`) · targets `net8.0` |
| **PHP** | **8.3+** | `final readonly class` value types · exception-based (`KeycloakException` hierarchy) |
| **Rust** | **1.88+** | MSRV required by edition 2024 + let-chains · async-only (tokio) · `thiserror`-based `KeycloakError` |
| **Ruby** | **3.2+** | sync-only · exception hierarchy (`KeycloakSdk::Error`) · gem `keycloak-sdk` / require `keycloak_sdk` |
| **Kotlin** | **2.2+** (JDK 17+) | coroutines (`suspend`) · data-class value types · sealed `KeycloakException` · reuses the JVM Java SDK stack |
| (optional) Docker | — | **Needed only for integration tests (Testcontainers/docker CLI)**. Not required to use the SDK itself |

---

## Java

### 1) Required runtime — JDK 17+

<!-- doc-guard: kind=runtime lang=java -->
JDK **`17` or newer** is required. Artifacts are compiled with `--release 17`. **Loading them under a JDK earlier than 17 raises `UnsupportedClassVersionError`**, so the consuming application must also be built and run on JDK 17 or newer. (Targeted Java 17 originally, raised to 21 on 2026-07-03, and lowered back to 17 on 2026-09-03 to cover more consumers — the sources never required 21.)

### 2) Local installation (development)

To build against your working copy, clone the repository and install it into your local `~/.m2`. `-DskipITs=true` skips **only the Docker-requiring Testcontainers integration tests** while still running unit tests and the coverage gate, so you can install without Docker:

```bash
mvn -f java/pom.xml install -DskipITs=true
```

After installation, adding just the single facade artifact to your consuming project pulls in `core`/`auth`/`admin` as transitive dependencies. Note the version: the working copy is `1.0.0-SNAPSHOT`, because the release workflow injects the tag value at publish time rather than keeping it in the POM.

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>1.0.0-SNAPSHOT</version>
</dependency>
```

### 3) Installation from Maven Central (stable `1.0.0`)

`1.0.0` is live on Maven Central — the first release under the 1.0 stability guarantee. No local `install` is needed:

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>1.0.0</version>
</dependency>
```

If you depend on the modules individually rather than through the facade, import the BOM (`io.github.xzawed:keycloak-sdk-bom:1.0.0`, `<type>pom</type>` `<scope>import</scope>`) so their versions stay aligned.

> ⚠️ **Maven has no prerelease concept — and that made it the odd one out during the RC.** `0.1.0-RC1` was never "a prerelease of `0.1.0`"; it is a different, lower-sorting coordinate. Nothing filtered it out the way RubyGems does, and nothing fell back to it the way pip and Cargo do, because in Maven you always name the version yourself. `0.1.0` is a **separate** artifact, and the RC stays on Central forever — Central is immutable, with no delete, no yank and no unlist. Releases remain human-gated: a publish runs only when a human pushes a `v*` tag to trigger [`.github/workflows/release.yml`](../../.github/workflows/release.yml), and even then the workflow only stages to the Central Portal until a human clicks Publish. For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Runnable example (token + user search, not the three steps below): [`java/keycloak-sdk-examples/.../QuickStart.java`](../../java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java)

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

// try-with-resources: close() releases the admin client if it was created (AuthClient holds no closeable session).
try (KeycloakClient client = KeycloakClient.create(config)) {
  // 1) Issue a token via the client-credentials grant. Never log the raw value — mask it.
  TokenSet tokens = client.auth().clientCredentialsToken();
  System.out.println("Access token: " + Secrets.mask(tokens.getAccessToken()));

  // 2) Hardened validation of the issued access token (algorithm pinning, exact iss match, aud containment check, clock skew).
  ValidatedToken vt = client.auth().validate(tokens.getAccessToken());
  System.out.println("subject=" + vt.getSubject() + " aud=" + vt.getAudience());

  // 3) Admin API — create a user (CRUD). create() returns the created user id (String).
  UserRepresentation newUser = new UserRepresentation();
  newUser.setUsername("alice");
  newUser.setEnabled(true);
  String userId = client.admin().users().create(newUser);
  System.out.println("created userId=" + userId);

  // (for reference) list query
  List<UserRepresentation> users = client.admin().users().search(null, 0, 20);
  users.forEach(u -> System.out.println(" - " + u.getUsername()));
}
```

---

## Python

### 1) Required runtime — Python 3.10+

<!-- doc-guard: kind=runtime lang=python -->
Python **`3.10` or newer** is required. The package includes the PEP 561 `py.typed` marker, so consumers can also type-check with `mypy`.

### 2) Local installation (from a clone)

To work from a clone, do an editable install or build locally:

```bash
pip install -e python
# Or build the distributable artifact locally to verify:
cd python && python -m build   # dist/keycloak_sdk-*-py3-none-any.whl + .tar.gz
```

The distribution name is `keycloak-sdk` and the import package name is `keycloak_sdk`.

### 3) Installation from PyPI (stable `1.0.0`)

`1.0.0` is live on PyPI:

```bash
pip install keycloak-sdk==1.0.0
```

> ⚠️ **pip skips prereleases again now that `1.0.0` exists.** A bare `pip install keycloak-sdk` resolves the stable release; the earlier `0.1.0rc1` now needs `--pre` or an exact pin. While the RC was the only release, pip fell back to it instead. Releases remain human-gated: a publish runs only when a human pushes a `py-v*` tag to trigger [`.github/workflows/python-release.yml`](../../.github/workflows/python-release.yml) (PyPI Trusted Publisher / OIDC). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Runnable example (token + user search, not the three steps below): [`python/examples/quickstart.py`](../../python/examples/quickstart.py) · async: [`python/examples/async_quickstart.py`](../../python/examples/async_quickstart.py)

```python
from keycloak_sdk import KeycloakClient, KeycloakConfig, mask

config = KeycloakConfig(
    server_url="https://kc.example.com",
    realm="myrealm",
    client_id="admin-cli",
    client_secret="changeme",  # load the real value from an env var / secrets manager
)

# with block: __exit__ closes the auth session (AdminClient owns no session, so its close() is a no-op).
with KeycloakClient.create(config) as kc:
    # 1) Issue a client-credentials token. Never log the raw value — mask it.
    token = kc.auth.client_credentials_token()
    print(f"access_token={mask(token.access_token)} token_type={token.token_type}")

    # 2) Hardened validation of the issued access token (algorithm pinning, exact iss match, aud containment check, clock skew).
    vt = kc.auth.validate(token.access_token)
    print(f"subject={vt.subject} aud={vt.audience}")

    # 3) Admin API — create a user (CRUD). create() returns the created user id (str).
    user_id = kc.admin.users.create({"username": "alice", "enabled": True})
    print(f"created user_id={user_id}")

    # (for reference) list query
    users = kc.admin.users.search(first=0, max=20)
    print(f"users={[u.get('username') for u in users]}")
```

**If you need async** (event-loop safe for FastAPI, etc.), use `keycloak_sdk.aio.AsyncKeycloakClient` and `await` each call — full example: [`python/examples/async_quickstart.py`](../../python/examples/async_quickstart.py).

## Node.js / TypeScript

### 1) Required runtime — Node 22+

<!-- doc-guard: kind=runtime lang=node -->
Node.js **`22` or newer** is required. The package is **ESM-only** (`"type":"module"`) and all public methods are `async` (Promise) (only `createAuthorizationRequest` is synchronous). It includes TypeScript type declarations (`.d.ts`), so consumers can type-check as well.

### 2) Local installation (development)

To build against your working copy, clone the repository and build under `node/`:

```bash
cd node && npm ci && npm run build   # generates dist/ (tsc). Consume via npm link or a file reference.
# Verify the distributable artifact (without uploading): npm pack --dry-run   # 75 files, 38.7 kB — dist/ plus README.md and LICENSE
```

The distribution name is `@xzawed/keycloak-sdk`, and the import path is the same.

### 3) Installation from npm (stable `1.0.0`)

`1.0.0` is live on npm and holds the `latest` dist-tag:

```bash
npm install @xzawed/keycloak-sdk
```

> ⚠️ **npm was the one registry where a bare install silently handed you an RC — and it could not be fixed by hand.** npm assigns `latest` to a package's *first* version regardless of `--tag` and then refuses to remove it (`403` on `DELETE .../dist-tags/latest`), so `latest` and `rc` both pointed at `0.1.0-rc.2`, and a `"^0.1.0"` range failed with `ETARGET` at the same time. Publishing `0.1.0` is what moved `latest`; the `rc` tag still points at the prerelease. Releases remain human-gated: a publish runs only when a human pushes a `node-v*` tag to trigger [`.github/workflows/node-release.yml`](../../.github/workflows/node-release.yml) (npm Trusted Publishing / OIDC + provenance). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Full example: [`node/examples/quickstart.ts`](../../node/examples/quickstart.ts)

```ts
import { KeycloakClient } from '@xzawed/keycloak-sdk'

const client = KeycloakClient.create({
  serverUrl: 'https://kc.example.com',
  realm: 'myrealm',
  clientId: 'admin-cli',
  clientSecret: 'changeme', // load the real value from an env var / secrets manager (config is masked when logged)
})

try {
  // 1) Issue a client-credentials token. The string representation of TokenSet is auto-masked (accessToken=***).
  const token = await client.auth.clientCredentialsToken()
  console.log(`token=${token}`)

  // 2) Hardened validation of the issued token (algorithm pinning, exact iss match, aud containment check, clock skew).
  const vt = await client.auth.validate(token.accessToken)
  console.log(`subject=${vt.subject} aud=${vt.audience.join(',')}`)

  // 3) Admin API — admin is lazily created on first access (client_secret required). create() returns the new id.
  const admin = await client.admin()
  const userId = await admin.users.create({ username: 'alice', enabled: true })
  console.log(`created user_id=${userId}`)
} finally {
  await client.close() // close protocol; both halves are no-ops today (global `fetch` holds no connections). Also possible via `await using` (Symbol.asyncDispose).
}
```

> **Authorization code (PKCE) flow**: start with `const { url, codeVerifier, state, nonce } = client.auth.createAuthorizationRequest(redirectUri)`, then exchange in the callback with `client.auth.exchangeCode(code, redirectUri, codeVerifier, nonce)` — you must pass `nonce` for the id_token validation to pass.

## Go

### 1) Required runtime — Go 1.25+

<!-- doc-guard: kind=runtime lang=go -->
Go **`1.25` or newer** is required (its dependency `golang.org/x/oauth2` v0.36 requires it). The idiom is sync + `context.Context` (every network method takes `ctx` as its first argument, and only `CreateAuthorizationRequest` is synchronous). Docker is needed only for integration tests.

### 2) Local installation (development)

Clone the monorepo and build under `go/`, or reference it from a consuming project with a `replace` directive:

```bash
cd go && go build ./... && go test ./...   # unit tests + coverage gate (logic ≥90)
# Reference locally from a consuming project: add `replace github.com/xzawed/KeyCloakSDK/go => ../KeyCloakSDK/go` to go.mod
```

The module path is `github.com/xzawed/KeyCloakSDK/go` and the package name is `keycloak`.

### 3) Installation from the Go module proxy (stable `1.0.0`)

```bash
go get github.com/xzawed/KeyCloakSDK/go@v1.0.0
```

> Go modules are **published via VCS tags** with no separate registry, so **the tag *is* the release** — `go/v1.0.0` is published and `proxy.golang.org` has cached it. A bare `go get github.com/xzawed/KeyCloakSDK/go` (and `@latest`) now resolves it; while `go/v0.1.0-rc.1` was the only tag, the `go` command fell back to that prerelease instead. ⚠️ The proxy cache is immutable — a published version stays fetchable by exact version forever, and the only remedy for a bad one is a `retract` directive in a *later* release.

### 4) Minimal usage example

Full example (godoc): [`go/example_test.go`](../../go/example_test.go)

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
		ClientSecret: "changeme", // load from an env var / secrets manager (Config is masked when logged)
	})
	if err != nil {
		panic(err)
	}
	defer client.Close()
	ctx := context.Background()

	// 1) client-credentials token. TokenSet's String() is auto-masked (AccessToken:***).
	token, err := client.Auth.ClientCredentialsToken(ctx)
	if err != nil {
		panic(err)
	}
	fmt.Println(token)

	// 2) Hardened validation (alg pin, exact iss match, aud containment check, exp required, clock skew).
	vt, err := client.Auth.Validate(ctx, token.AccessToken)
	if err != nil {
		panic(err)
	}
	fmt.Println(vt.Subject, vt.Audience)

	// 3) Admin API — admin is lazily created on first access (clientSecret required). Branch on errors with the errors.Is sentinels.
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

> Error handling: branch admin API failures with `errors.Is(err, keycloak.ErrNotFound)` (· `ErrConflict` · `ErrForbidden`), or get `ae.StatusCode` via `var ae *keycloak.AdminError; errors.As(err, &ae)`. Network failures are `*keycloak.TransportError`.

## C# / .NET

### 1) Required runtime — .NET 8+

<!-- doc-guard: kind=runtime lang=dotnet -->
.NET **8 or newer** (`net8.0`) is required. The idiom is async-first (every network method takes `Task<T>` + a trailing `CancellationToken ct = default`, and only `CreateAuthorizationRequest` is purely synchronous). Docker is needed only for integration tests.

### 2) Local installation (from a clone)

To work from a clone, attach it as a project reference from your consuming project:

```bash
dotnet add reference ../KeyCloakSDK/dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj
# Just verify a local build/test: cd dotnet && dotnet build && dotnet test --filter "Category!=Integration"   # unit tests + coverage gate
```

The package ID is `Xzawed.Keycloak.Sdk`, and the root namespace is `Xzawed.Keycloak` (admin is the `Xzawed.Keycloak.Admin` sub-namespace).

### 3) Installation from NuGet (stable `1.0.0`)

`1.0.0` is live on NuGet — the first release under the 1.0 stability guarantee:

```bash
dotnet add package Xzawed.Keycloak.Sdk --version 1.0.0   # or omit --version for latest
```

> A plain `dotnet add package Xzawed.Keycloak.Sdk` now resolves `1.0.0`. While only the RC existed it failed outright ("There are no stable versions available") — opting in took `--prerelease` or the exact version. Releases remain human-gated: a publish runs only when a human pushes a `dotnet-v*` tag to trigger [`.github/workflows/dotnet-release.yml`](../../.github/workflows/dotnet-release.yml) (requires the `NUGET_API_KEY` secret). For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

```csharp
using Keycloak.AuthServices.Sdk.Admin.Models;
using Xzawed.Keycloak;

var config = new KeycloakConfig
{
    ServerUrl = "https://kc.example.com",
    Realm = "myrealm",
    ClientId = "admin-cli",
    ClientSecret = "changeme", // load the real value from an env var / secrets manager (ToString/JSON serialization is auto-masked)
};

// await using: DisposeAsync() cleans up admin + auth resources (HttpClient) too. (Synchronous using is also supported via IDisposable.)
await using var kc = KeycloakClient.Create(config);

// 1) Issue a token via the client-credentials grant. TokenSet's ToString()/JSON serialization is auto-masked (AccessToken=***).
var tokens = await kc.Auth.ClientCredentialsTokenAsync();
Console.WriteLine(tokens);

// 2) Hardened validation of the issued access token (algorithm pinning, exact iss match, aud containment check, exp required, clock skew).
var vt = await kc.Auth.ValidateAsync(tokens.AccessToken);
Console.WriteLine($"subject={vt.Subject} aud=[{string.Join(",", vt.Audience)}]");

// 3) Admin API — admin is lazily created on first access (clientSecret required). CreateAsync() returns the created user id.
var admin = await kc.AdminAsync();
var userId = await admin.Users.CreateAsync(new UserRepresentation { Username = "alice", Enabled = true });
Console.WriteLine($"created userId={userId}");

// (for reference) list query
var users = await admin.Users.SearchAsync(username: null, first: 0, max: 20);
foreach (var u in users) Console.WriteLine($" - {u.Username}");
```

> Error handling: admin failures are classified as `KeycloakNotFoundException`/`KeycloakConflictException`/`KeycloakForbiddenException` (all of which carry `KeycloakAdminException.StatusCode`), or `KeycloakTransportException` on a network failure. `admin.Raw` is the escape hatch to the underlying `Keycloak.AuthServices.Sdk` typed client.

## PHP

### 1) Required runtime — PHP 8.3+

<!-- doc-guard: kind=runtime lang=php -->
PHP **`8.3` or newer** is required. Value types are declared as `final readonly class` (immutable), and the idiom is exception-based (`KeycloakException` hierarchy). Docker is needed only for integration tests.

### 2) Local installation (from a clone)

To work from a clone, reference it as a local path repository, or build directly under `php/` to verify:

```bash
cd php && composer install   # install dependencies (fschmtt/league/stevenmaguire/firebase, etc.)
# Reference locally from a consuming project: add a path repository to composer.json
#   { "repositories": [{ "type": "path", "url": "../KeyCloakSDK/php" }] }
#   composer require xzawed/keycloak-sdk:@dev
```

The distribution name is `xzawed/keycloak-sdk`, and the root namespace is `Xzawed\Keycloak` (admin is the `Xzawed\Keycloak\Admin` sub-namespace).

### 3) Installation from Packagist (stable `1.0.0`)

`v1.0.0` is live on Packagist — the first release under the 1.0 stability guarantee:

```bash
composer require "xzawed/keycloak-sdk:1.0.0"
```

> A plain `composer require xzawed/keycloak-sdk` now resolves `1.0.0`. While only the RCs existed it failed outright, because Composer's default `minimum-stability: stable` excludes prereleases — opting in took the exact version or `^0.1@rc`. How publishing works here: PHP does not publish from this monorepo, and it never could — Composer's VCS driver reads only a `composer.json` at a repository **root**, and there is none here (only `php/composer.json`). When a human pushes a `php-v*` tag, [`.github/workflows/php-release.yml`](../../.github/workflows/php-release.yml) verifies, then splits `php/` out with `git subtree split` and pushes it to a separate read-only mirror repository, **`xzawed/keycloak-sdk-php`**, tagging it there with a **bare `vX.Y.Z`** (Composer cannot parse `php-vX.Y.Z` as a version). **That mirror — not this repository — is what is registered on Packagist**; the package name stays `xzawed/keycloak-sdk`, since it comes from `php/composer.json`, which the split carries along. The split job requires a `PHP_SPLIT_TOKEN` secret with write access to the mirror and **fails closed without it** (nothing is pushed, and no GitHub Release is created). The mirror and its Packagist registration exist and serve `v1.0.0` today — for the full procedure, see [DEPLOY.md](../../DEPLOY.md) §2-D. For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Full example: [`php/examples/quickstart.php`](../../php/examples/quickstart.php)

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
    clientSecret: 'changeme', // load the real value from an env var / secrets manager (__toString is auto-masked)
));

// 1) Issue a token via the client-credentials grant. TokenSet's __toString() is auto-masked (accessToken=***).
$token = $client->auth()->clientCredentialsToken();
echo "token type: {$token->tokenType}, expires in: {$token->expiresIn}s\n";

// 2) Hardened validation of the issued access token (RS256 pin, exact iss match, aud containment check, exp required, clock skew).
$validated = $client->auth()->validate($token->accessToken);
echo "subject: {$validated->subject}, issuer: {$validated->issuer}\n";

// 3) Admin API — create a user. fschmtt's create() returns void, so look up the id afterwards with findIdByUsername().
$client->admin()->users()->create(new User(username: 'alice', enabled: true));
$userId = $client->admin()->users()->findIdByUsername('alice');
echo "created userId={$userId}\n";
```

> Error handling: admin failures are classified as `KeycloakNotFoundError`/`KeycloakConflictError`/`KeycloakForbiddenError` (all of which carry `KeycloakAdminError::getStatusCode()`), or `KeycloakTransportError` on a network failure. `admin()->raw()` is the escape hatch to the underlying `Fschmtt\Keycloak\Keycloak` typed client.

> **Authorization code (PKCE) flow**: `$req = $client->auth()->createAuthorizationRequest()` always issues a nonce (on `$req->nonce` and on the authorization URL). Exchange with `$client->auth()->exchangeCode($code, $req->codeVerifier, $req->nonce)` so the `id_token` is signature-verified and the nonce claim is checked. The third argument is optional — omit it and id_token validation is skipped, matching the other eight languages.

## Rust

### 1) Required runtime — Rust 1.88+

<!-- doc-guard: kind=runtime lang=rust -->
Rust **`1.88` or newer** (MSRV — required by edition 2024 + let-chains) is required. The idiom is async-only (tokio), and instead of exceptions it uses a `thiserror`-based `KeycloakError` enum (`Config`/`Auth`/`Transport`/`Admin`/`TokenValidation`) + `Result<T, KeycloakError>`. Docker is needed only for integration tests.

### 2) Local installation (development)

To build against your working copy, reference it as a path dependency in your consuming project's `Cargo.toml`:

```toml
[dependencies]
keycloak-sdk = { path = "../KeyCloakSDK/rust" }
```

```bash
cd rust && cargo build && cargo test   # Just verify a local build/test: unit tests + coverage gate
```

The crate name is `keycloak-sdk`, and the root module is `keycloak_sdk` (`keycloak_sdk::{KeycloakClient, KeycloakConfig, ...}`).

### 3) Installation from crates.io (stable `1.0.0`)

`1.0.0` is live on crates.io — the first release under the 1.0 stability guarantee:

```bash
cargo add keycloak-sdk
```

> The bare `cargo add` above resolves `1.0.0`. While `0.1.0-rc.1` was the only version, Cargo fell back to it — but note the asymmetry that made this confusing: a **hand-written** requirement such as `keycloak-sdk = "0.1"` never matches a pre-release, so during the RC the two forms disagreed. They agree now. Releases remain human-gated: a publish runs only when a human pushes a `rust-v*` tag to trigger [`.github/workflows/rust-release.yml`](../../.github/workflows/rust-release.yml). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Full example: [`rust/examples/quickstart.rs`](../../rust/examples/quickstart.rs)

```rust
// The Admin representation types are re-exported from `keycloak_sdk::types`, so the `keycloak`
// crate does not need to be a direct dependency of your project.
use keycloak_sdk::types::UserRepresentation;
use keycloak_sdk::{KeycloakClient, KeycloakConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = KeycloakConfig::new("https://kc.example.com", "myrealm", "admin-cli")?
        .with_client_secret("changeme"); // load the real value from an env var / secrets manager (Debug is masked)

    let client = KeycloakClient::new(cfg)?;

    // 1) Issue a token via the client-credentials grant. TokenSet's Debug masks the access/refresh tokens (***).
    let token = client.auth().client_credentials_token().await?;
    println!("token type: {}, expires in: {}s", token.token_type, token.expires_in);

    // 2) Hardened validation of the issued access token (RS256 pin, exact iss match, aud containment check, exp required, nbf, clock skew).
    let validated = client.auth().validate(&token.access_token).await?;
    println!("subject: {}, issuer: {}", validated.subject, validated.issuer);

    // 3) Admin API — create a user. The created id is extracted from the response Location header (None if absent).
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

> Error handling: match admin failures on `KeycloakError::Admin(AdminError::NotFound | Conflict | Forbidden | Other { status })`, or classify them as `KeycloakError::Transport(_)` on a network failure. `admin().raw()` is the escape hatch to the underlying `keycloak::KeycloakAdmin` typed client.

## Ruby

### 1) Required runtime — Ruby 3.2+

<!-- doc-guard: kind=runtime lang=ruby -->
Ruby **`3.2` or newer** (dev/CI top end 3.4) is required. The idiom is sync-only (all wrapped gems are synchronous), and it uses exception-based idioms (`KeycloakSdk::Error` hierarchy — isomorphic with Java/Python/Node/C#/PHP, in contrast to the error-value idioms of Go/Rust). Docker is needed only for integration tests.

### 2) Local installation (development)

To build against your working copy, clone the repository and install the dependencies under `ruby/`:

```bash
cd ruby && bundle install   # install dependencies (faraday/jwt/rack-oauth2, etc.)
# Reference locally from a consuming project: add `gem "keycloak-sdk", path: "../KeyCloakSDK/ruby"` to your Gemfile
```

The gem name is `keycloak-sdk` (hyphen), and the require/module name is `keycloak_sdk`/`KeycloakSdk` (underscore — to avoid a clash with the existing `keycloak` gem's `Keycloak` module).

### 3) Installation from RubyGems (stable `1.0.0`)

`1.0.0` is live on RubyGems — the first release under the 1.0 stability guarantee:

```bash
gem install keycloak-sdk -v 1.0.0
```

> A bare `gem install keycloak-sdk` resolves `1.0.0`. RubyGems is stricter than pip or Cargo about prereleases — it never falls back to one — so while `1.0.0.rc1` was the only release a bare install resolved **nothing** and both the command and a `Gemfile` entry needed the version spelled out. Releases remain human-gated: a publish runs only when a human pushes a `ruby-v*` tag to trigger [`.github/workflows/ruby-release.yml`](../../.github/workflows/ruby-release.yml) over RubyGems Trusted Publishing (OIDC — no stored secret). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Full example: [`ruby/examples/quickstart.rb`](../../ruby/examples/quickstart.rb)

```ruby
require "keycloak_sdk"

config = KeycloakSdk::Config.new(
  server_url: "https://kc.example.com",
  realm: "myrealm",
  client_id: "admin-cli",
  client_secret: "changeme" # load the real value from an env var / secrets manager (inspect is auto-masked)
)

client = KeycloakSdk::KeycloakClient.new(config)

# 1) Issue a token via the client-credentials grant. TokenSet#inspect masks the access/refresh/id tokens.
token = client.auth.client_credentials_token
puts token.inspect

# 2) Hardened validation of the issued access token (RS256 pin, exact iss match, aud containment check, exp required, nbf, clock skew).
validated = client.auth.validate(token.access_token)
puts "subject=#{validated.subject} aud=#{validated.audience}"

# 3) Admin API — admin is lazily created on first access (dedicated caching TokenProvider). create() returns the created id.
user_id = client.admin.users.create({ username: "alice", enabled: true })
puts "created user_id=#{user_id}"

client.close
```

> Error handling: admin failures are classified as `KeycloakSdk::NotFoundError`/`ConflictError`/`ForbiddenError` (all of which carry `AdminError#status`), or `KeycloakSdk::TransportError` on a network failure. `admin.raw` is the escape hatch to the underlying `Faraday::Connection`.

> **Authorization code (PKCE) flow**: `req = client.auth.create_authorization_request(redirect_uri: …)` always issues a nonce (on `req.nonce` and on the authorization URL). Exchange with `client.auth.exchange_code(code:, code_verifier: req.code_verifier, redirect_uri:, expected_nonce: req.nonce)` so the `id_token` is signature-verified and the nonce claim is checked. `expected_nonce:` remains optional — omit it and id_token validation is skipped, matching the other eight languages.

---

## Kotlin

### 1) Required runtime — Kotlin 2.2+ / JDK 17+

<!-- doc-guard: kind=runtime lang=kotlin -->
**JDK `17+`** is required (this anchor verifies the emitted bytecode target, not the JDK used to build). Kotlin **2.2 or newer** is also required on that JDK (the same runtime as the sibling Java SDK, whose verified JVM stack it reuses). The SDK is *built* with Kotlin 2.4.10 but pins `languageVersion`/`apiVersion` to 2.2, so the published artifact’s binary metadata is readable by any Kotlin 2.2+ compiler — you do not need to be on 2.4 to consume it. All network methods are `suspend` functions (coroutines; blocking sub-library calls run on `Dispatchers.IO` via `runInterruptible`), value types are data classes, and the exception hierarchy is a sealed `KeycloakException`. Public API visibility is strictly enforced with `explicitApi()`. Docker is needed only for integration tests.

### 2) Local installation (development)

To build against your working copy, clone the repository and publish it to your local `~/.m2` with Gradle:

```bash
cd kotlin && ./gradlew publishToMavenLocal   # installs keycloak-sdk-kotlin-1.0.0.jar (+ sources/javadoc) into ~/.m2
```

Then reference it from a consuming Gradle project via `mavenLocal()` (Gradle Kotlin DSL):

```kotlin
repositories { mavenLocal(); mavenCentral() }
dependencies { implementation("io.github.xzawed:keycloak-sdk-kotlin:1.0.0") }
```

(To just build and test locally without publishing: `cd kotlin && ./gradlew build && ./gradlew test` — unit tests + coverage gate, Docker-free.)

### 3) Installation from Maven Central (stable `1.0.0`)

`1.0.0` is live on Maven Central — the first release under the 1.0 stability guarantee. No local publish is needed:

```kotlin
dependencies { implementation("io.github.xzawed:keycloak-sdk-kotlin:1.0.0") }
```

> ⚠️ **Consumer floor is Kotlin 2.2+, and that is a deliberate choice you can verify.** The published jar carries `@Metadata(mv=[2,2,0])` and its POM declares `kotlin-stdlib 2.2.21` — both lower than the 2.4.10 toolchain that built it, because a jar built without pinning `languageVersion`/`apiVersion` is unreadable to any compiler older than the one that produced it. (Measured on the published artifact: `javap -v` on a class shows `mv=[2,2,0]`, and a clean `mvn dependency:get` resolves `kotlin-stdlib 2.2.21`, not 2.4.x.)
>
> ⚠️ **Maven has no pre-release concept** — `0.1.0-RC1` is a different, lower-sorting coordinate rather than a prerelease of `0.1.0`, so nothing filters it out and nothing falls back to it; name the version explicitly. Releases stay human-gated: a publish runs only when a human pushes a `kotlin-v*` tag to trigger [`.github/workflows/kotlin-release.yml`](../../.github/workflows/kotlin-release.yml) (vanniktech maven.publish → Central Portal staging), and even then the artifact goes public only when a human clicks Publish in the Portal console. For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Full example: [`kotlin/examples/quickstart.kt`](../../kotlin/examples/quickstart.kt)

```kotlin
import io.github.xzawed.keycloak.KeycloakClient
import io.github.xzawed.keycloak.KeycloakConfig
import kotlinx.coroutines.runBlocking
import org.keycloak.representations.idm.UserRepresentation

fun main() = runBlocking {
    val config = KeycloakConfig(
        serverUrl = "https://kc.example.com",
        realm = "myrealm",
        clientId = "admin-cli",
        clientSecret = "changeme".toCharArray(), // load the real value from an env var / secrets manager (toString is auto-masked)
    )

    // use { }: close() releases the admin client if it was created (AuthClient owns no closeable resource).
    KeycloakClient.create(config).use { client ->
        // 1) Issue a token via the client-credentials grant. TokenSet.toString() masks access/refresh tokens as "***".
        val token = client.auth.clientCredentialsToken()
        println("token type=${token.tokenType}")

        // 2) Hardened validation of the issued access token (RS256 pin, exact iss match, aud containment check, exp required, clock skew).
        val validated = client.auth.validate(token.accessToken)
        println("subject=${validated.subject} issuer=${validated.issuer}")

        // 3) Admin API — create a user. The created id is extracted from the response Location header.
        val userId = client.admin.users().create(
            UserRepresentation().apply {
                username = "alice"
                isEnabled = true
            },
        )
        println("created userId=$userId")
    }
}
```

> Error handling: admin failures are surfaced as the sealed `KeycloakAdminException` (carrying `status` + `keycloakError`), with leaves `KeycloakAdminException.NotFound`/`Conflict`/`Forbidden`/`Other`, or `KeycloakTransportException` on a network failure. `admin.raw()` is the escape hatch to the underlying `org.keycloak.admin.client.Keycloak`.

---

## Admin capability

The nine SDKs are isomorphic in **layering and flow**, not method-for-method. What each language's
admin facade covers directly, what it returns, and what to call when a convenience method is absent
are in **[Admin capability reference](../reference/admin-capability.md)**.

## Compatibility

Which Keycloak server range, base libraries and runtimes each published version actually shipped
against is in **[Compatibility reference](../reference/compatibility.md)**.

## Next steps

- **Language support roadmap** — currently supported languages (depth-first: Java · Python · TypeScript/Node · Go · C#/.NET · PHP · Rust · Ruby · Kotlin complete — 9 languages): [../roadmap/language-support.md](../roadmap/language-support.md)
- **Add-a-language playbook** — the procedure for adding a language with quality isomorphic to the existing Java/Python/Node/Go/C#/PHP/Rust/Ruby/Kotlin: [add-a-language-playbook.md](add-a-language-playbook.md)

> The language-neutral API contract (the source of truth) is defined in [CLAUDE.md §4](../../CLAUDE.md). Every language implements this contract, and the JWT validation hardening (algorithm pinning · `none` rejection · exact `iss` match · `aud` containment check · clock skew · DoS-safe JWKS refetch) is a cross-language mandatory requirement. Every language covers the same scenarios (full auth flow · the five admin resources · the JWT hardening probes) with a unit suite plus one Testcontainers or docker-CLI integration test. Exact test counts are intentionally **not** hand-maintained here — the authority is each language's own CI job and coverage gate; run the unit/integration command in [`.claude/rules/<lang>.md`](../../.claude/rules/) to get the current number. Counts copied into prose drift the moment CI's count changes, and the ones this file used to carry were stale for seven of the nine languages.
