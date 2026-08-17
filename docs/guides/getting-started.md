# Getting Started

A guide to installing the Keycloak polyglot SDK locally and running your first token issuance, JWT validation, and Admin API call with minimal code. This SDK is provided in **multiple programming languages** (currently Java · Python · Node.js · Go · C#/.NET · PHP · Rust · Ruby · Kotlin), and while each language is idiomatic, the concepts, layers, and flows are isomorphic.

> ℹ️ **All nine are on a public registry, as first release candidates** — PHP (Packagist), Python (PyPI), .NET (NuGet), Rust (crates.io), Ruby (RubyGems), Node (npm), Java (Maven Central), Kotlin (Maven Central) and Go (the Go module proxy). **No language has a stable release**, and ecosystems disagree sharply about what a bare install does when only a prerelease exists — pip, Cargo and the `go` command fall back to it, RubyGems resolves nothing, npm resolves it too (its `latest` tag points at the prerelease — but a `^0.1.0` *range* excludes prereleases and fails with `ETARGET`), and Maven has no prerelease concept at all (you always name the version, so nothing filters and nothing falls back). Each language section spells out the incantation its ecosystem needs; do not copy one language's wording to another. Every language also keeps a local-clone path (see each language's "Local installation" below), which is what you want when developing against the SDK itself. For the real release procedure, see the unified nine-language [DEPLOY.md](../../DEPLOY.md) (check readiness with `scripts/release-readiness.sh` and tag commands with `scripts/release-trigger.sh <lang> <ver>` — both are human-gates that never push tags automatically).

> 🖥️ **You need a Keycloak *server* first.** This SDK is a client library, so it needs a **Keycloak server to connect to** in order to work (the server is a separate, standalone product not included in this SDK). For a local trial, use the one-line Docker command `docker run -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin quay.io/keycloak/keycloak:26.6 start-dev`; for a **production deployment**, see the [Keycloak server deployment guide](deploying-keycloak-server.md).

> ⚠️ **The validation step of every quickstart below fails on a stock realm — this is expected, and here is why.** Each *Minimal usage example* does three things in order: get a token, `validate()` it, call the Admin API. `validate()` requires the token's `aud` to contain the expected audience, which defaults to your client id. **A stock Keycloak realm does not put the client id into a client-credentials token's `aud`.** So the token issues fine and then validation rejects it. Two ways out, both correct:
> - set the expected audience to what your realm actually issues — the right choice when the token targets a *resource server* rather than the requesting client (`expectedAudience` in Java/Kotlin/Node/PHP, `ExpectedAudience` in .NET/Go, `expected_audience` in Python/Ruby, `.with_expected_audience(…)` in Rust);
> - or add an **Audience** protocol mapper to the client in Keycloak, so the realm issues the audience you expect.
>
> This is a deliberate default, not a rough edge: accepting a token minted for a different audience is the failure the check exists to prevent. Each language's package README repeats it with that language's spelling.

## Required runtime

| Language | Minimum runtime | Notes |
|---|---|---|
| **Java** | **JDK 21+** | Artifacts are compiled with `--release 21`, so older JDKs raise `UnsupportedClassVersionError` |
| **Python** | **3.10+** | Includes `py.typed` (PEP 561) — consumer-side mypy type checking possible |
| **Node.js** | **22+** | ESM-only · async-only · includes `.d.ts` type declarations |
| **Go** | **1.25+** | sync + `context.Context` · requires `x/oauth2` v0.36 |
| **C# / .NET** | **8+** | async-first (`Task<T>` + `CancellationToken`) · targets `net8.0` |
| **PHP** | **8.3+** | `final readonly class` value types · exception-based (`KeycloakException` hierarchy) |
| **Rust** | **1.88+** | MSRV required by edition 2024 + let-chains · async-only (tokio) · `thiserror`-based `KeycloakError` |
| **Ruby** | **3.2+** | sync-only · exception hierarchy (`KeycloakSdk::Error`) · gem `keycloak-sdk` / require `keycloak_sdk` |
| **Kotlin** | **2.2+** (JDK 21+) | coroutines (`suspend`) · data-class value types · sealed `KeycloakException` · reuses the JVM Java SDK stack |
| (optional) Docker | — | **Needed only for integration tests (Testcontainers/docker CLI)**. Not required to use the SDK itself |

---

## Java

### 1) Required runtime — JDK 21+

<!-- doc-guard: kind=runtime lang=java -->
JDK **`21` or newer** is required. Artifacts are compiled with `--release 21`. **Loading them under a JDK earlier than 21 raises `UnsupportedClassVersionError`**, so the consuming application must also be built and run on JDK 21 or newer. (Originally targeted Java 17, then raised to 21 LTS on 2026-07-03.)

### 2) Local installation (development)

To build against your working copy, clone the repository and install it into your local `~/.m2`. `-DskipITs=true` skips **only the Docker-requiring Testcontainers integration tests** while still running unit tests and the coverage gate, so you can install without Docker:

```bash
mvn -f java/pom.xml install -DskipITs=true
```

After installation, adding just the single facade artifact to your consuming project pulls in `core`/`auth`/`admin` as transitive dependencies. Note the version: the working copy is `0.1.0-SNAPSHOT`, because the release workflow injects the tag value at publish time rather than keeping it in the POM.

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0-SNAPSHOT</version>
</dependency>
```

### 3) Installation from Maven Central (first release candidate available)

The first release candidate, `0.1.0-RC1`, is live on Maven Central; there is no stable release yet. No local `install` is needed:

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0-RC1</version>
</dependency>
```

If you depend on the modules individually rather than through the facade, import the BOM (`io.github.xzawed:keycloak-sdk-bom:0.1.0-RC1`, `<type>pom</type>` `<scope>import</scope>`) so their versions stay aligned.

> ⚠️ **Maven has no prerelease concept — and that makes it the odd one out here.** `0.1.0-RC1` is not "a prerelease of `0.1.0`"; it is simply a different, lower-sorting coordinate. Nothing filters it out the way RubyGems does, and nothing falls back to it the way pip and Cargo do, because in Maven you always name the version yourself. The consequence is on the other side: once `0.1.0` is released it is a **separate** artifact, and this RC stays on Central forever — Central is immutable, with no delete, no yank and no unlist. Releases remain human-gated: a publish runs only when a human pushes a `v*` tag to trigger [`.github/workflows/release.yml`](../../.github/workflows/release.yml), and even then the workflow only stages to the Central Portal until a human clicks Publish. For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

### 3) Installation from PyPI (first release candidate available)

The first release candidate, `0.1.0rc1`, is live on PyPI; there is no stable release yet:

```bash
pip install keycloak-sdk==0.1.0rc1
```

> ⚠️ **Prerelease-only caveat**: while the RC is the *only* release on PyPI, a bare `pip install keycloak-sdk` also resolves it — pip falls back to pre-releases when no stable release exists. Pin the exact version to be explicit about opting into an RC. Releases remain human-gated: a publish runs only when a human pushes a `py-v*` tag to trigger [`.github/workflows/python-release.yml`](../../.github/workflows/python-release.yml) (PyPI Trusted Publisher / OIDC). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

# with block: __exit__ cleans up admin + auth sessions too.
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

### 3) Installation from npm (first release candidate available)

The first release candidate, `0.1.0-rc.2`, is live on npm; there is no stable release yet:

```bash
npm install @xzawed/keycloak-sdk@rc
```

> ⚠️ **A bare install gives you the RC here, unlike the other prerelease-only languages.** The workflow publishes under the `rc` tag, but npm assigns `latest` to a package's *first* version regardless of `--tag` and then refuses to remove it (`403` on `DELETE .../dist-tags/latest`), so `latest` and `rc` both point at `0.1.0-rc.2`. A bare `npm install @xzawed/keycloak-sdk` and a `"^0.1.0"` range therefore resolve the prerelease **silently**. Use `@rc` as above, or pin `@0.1.0-rc.2`, so the choice stays visible — and so it keeps working once a stable release takes over `latest`. (Contrast RubyGems, which resolves nothing at all, and pip/Cargo, which fall back deliberately.) Releases remain human-gated: a publish runs only when a human pushes a `node-v*` tag to trigger [`.github/workflows/node-release.yml`](../../.github/workflows/node-release.yml) (npm Trusted Publishing / OIDC + provenance). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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
  await client.close() // clean up admin + auth resources. Also possible via `await using` (Symbol.asyncDispose).
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

### 3) Installation from the Go module proxy (first release candidate available)

```bash
go get github.com/xzawed/KeyCloakSDK/go@v0.1.0-rc.1
```

> Go modules are **published via VCS tags** with no separate registry, so **the tag *is* the release** — `go/v0.1.0-rc.1` is published and `proxy.golang.org` has cached it. Measured: a bare `go get github.com/xzawed/KeyCloakSDK/go` (and `@latest`) resolves this RC today, because the `go` command falls back to a pre-release when a module has no stable version. Pin the version explicitly, as above, if you mean to stay on the RC once a stable release lands. ⚠️ The proxy cache is immutable — a published version stays fetchable by exact version forever, and the only remedy for a bad one is a `retract` directive in a *later* release.

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

### 3) Installation from NuGet (first release candidate available)

The first release candidate, `0.1.0-rc.1`, is live on NuGet; there is no stable release yet:

```bash
dotnet add package Xzawed.Keycloak.Sdk --version 0.1.0-rc.1   # or: --prerelease
```

> ⚠️ A plain `dotnet add package Xzawed.Keycloak.Sdk` fails while only the RC exists ("There are no stable versions available") — pass `--prerelease` or the exact version to opt in. Releases remain human-gated: a publish runs only when a human pushes a `dotnet-v*` tag to trigger [`.github/workflows/dotnet-release.yml`](../../.github/workflows/dotnet-release.yml) (requires the `NUGET_API_KEY` secret). For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

### 3) Installation from Packagist (release candidate available)

The newest release candidate, `v0.1.0-rc.2`, is live on Packagist; there is no stable release yet:

```bash
composer require "xzawed/keycloak-sdk:0.1.0-rc.2"
```

> ⚠️ A plain `composer require xzawed/keycloak-sdk` fails while only the RC exists (default `minimum-stability: stable` excludes it) — require the exact version, or `^0.1@rc`, to opt in. How publishing works here: PHP does not publish from this monorepo, and it never could — Composer's VCS driver reads only a `composer.json` at a repository **root**, and there is none here (only `php/composer.json`). When a human pushes a `php-v*` tag, [`.github/workflows/php-release.yml`](../../.github/workflows/php-release.yml) verifies, then splits `php/` out with `git subtree split` and pushes it to a separate read-only mirror repository, **`xzawed/keycloak-sdk-php`**, tagging it there with a **bare `vX.Y.Z`** (Composer cannot parse `php-vX.Y.Z` as a version). **That mirror — not this repository — is what is registered on Packagist**; the package name stays `xzawed/keycloak-sdk`, since it comes from `php/composer.json`, which the split carries along. The split job requires a `PHP_SPLIT_TOKEN` secret with write access to the mirror and **fails closed without it** (nothing is pushed, and no GitHub Release is created). The mirror and its Packagist registration exist and serve `v0.1.0-rc.2` today — for the full procedure, see [DEPLOY.md](../../DEPLOY.md) §2-D. For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

### 3) Installation from crates.io (first release candidate available)

The first release candidate, `0.1.0-rc.1`, is live on crates.io; there is no stable release yet:

```bash
cargo add keycloak-sdk
```

> ⚠️ **Prerelease-only caveat, and it differs from pip's.** The bare `cargo add` above resolves the RC today, because Cargo falls back to a pre-release when a crate has no stable version — but once a stable release lands, that one wins instead, so pin explicitly (`cargo add keycloak-sdk@0.1.0-rc.1`) if you mean to stay on the RC. Note the asymmetry: a **hand-written** requirement such as `keycloak-sdk = "0.1"` never matches a pre-release, so spell it out (`keycloak-sdk = "0.1.0-rc.1"`). Releases remain human-gated: a publish runs only when a human pushes a `rust-v*` tag to trigger [`.github/workflows/rust-release.yml`](../../.github/workflows/rust-release.yml). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

### 3) Installation from RubyGems (first release candidate available)

The first release candidate, `0.1.0.rc1`, is live on RubyGems; there is no stable release yet:

```bash
gem install keycloak-sdk -v 0.1.0.rc1
```

> ⚠️ **Prerelease-only caveat, and RubyGems is stricter than pip or Cargo.** A bare `gem install keycloak-sdk` resolves **nothing** while an RC is the only release — RubyGems never falls back to a pre-release. Pass `--pre` or pin the exact version (a `Gemfile` needs `gem "keycloak-sdk", "0.1.0.rc1"` for the same reason). Releases remain human-gated: a publish runs only when a human pushes a `ruby-v*` tag to trigger [`.github/workflows/ruby-release.yml`](../../.github/workflows/ruby-release.yml) over RubyGems Trusted Publishing (OIDC — no stored secret). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

### 1) Required runtime — Kotlin 2.2+ / JDK 21+

<!-- doc-guard: kind=runtime lang=kotlin -->
**JDK `21+`** is required (this anchor verifies the JDK toolchain, not the Kotlin language version). Kotlin **2.2 or newer** is also required on that JDK (the same runtime as the sibling Java SDK, whose verified JVM stack it reuses). The SDK is *built* with Kotlin 2.4.10 but pins `languageVersion`/`apiVersion` to 2.2, so the published artifact’s binary metadata is readable by any Kotlin 2.2+ compiler — you do not need to be on 2.4 to consume it. All network methods are `suspend` functions (coroutines; blocking sub-library calls run on `Dispatchers.IO` via `runInterruptible`), value types are data classes, and the exception hierarchy is a sealed `KeycloakException`. Public API visibility is strictly enforced with `explicitApi()`. Docker is needed only for integration tests.

### 2) Local installation (development)

To build against your working copy, clone the repository and publish it to your local `~/.m2` with Gradle:

```bash
gradle -p kotlin publishToMavenLocal   # installs keycloak-sdk-kotlin-0.1.0-RC1.jar (+ sources/javadoc) into ~/.m2
```

Then reference it from a consuming Gradle project via `mavenLocal()` (Gradle Kotlin DSL):

```kotlin
repositories { mavenLocal(); mavenCentral() }
dependencies { implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0-RC1") }
```

(To just build and test locally without publishing: `gradle -p kotlin build && gradle -p kotlin test` — unit tests + coverage gate, Docker-free.)

### 3) Installation from Maven Central (first release candidate available)

The first release candidate, `0.1.0-RC1`, is live on Maven Central; there is no stable release yet. No local publish is needed:

```kotlin
dependencies { implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0-RC1") }
```

> ⚠️ **Consumer floor is Kotlin 2.2+, and that is a deliberate choice you can verify.** The published jar carries `@Metadata(mv=[2,2,0])` and its POM declares `kotlin-stdlib 2.2.21` — both lower than the 2.4.10 toolchain that built it, because a jar built without pinning `languageVersion`/`apiVersion` is unreadable to any compiler older than the one that produced it. (Measured on the published artifact: `javap -v` on a class shows `mv=[2,2,0]`, and a clean `mvn dependency:get` resolves `kotlin-stdlib 2.2.21`, not 2.4.x.)
>
> ⚠️ **Maven has no pre-release concept** — `0.1.0-RC1` is simply a different, lower-sorting coordinate, so nothing filters it out and nothing falls back to it; name it explicitly. Releases stay human-gated: a publish runs only when a human pushes a `kotlin-v*` tag to trigger [`.github/workflows/kotlin-release.yml`](../../.github/workflows/kotlin-release.yml) (vanniktech maven.publish → Central Portal staging), and even then the artifact goes public only when a human clicks Publish in the Portal console. For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

    // use { }: close() cleans up admin + auth resources too.
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

## Admin capability matrix

The nine SDKs are isomorphic in **layering and flow**, not in method-for-method coverage. The admin facade wraps a different underlying library in each language, and those libraries do not expose the same surface. This table tells you what you can call directly, what you get back, and — where a convenience method is absent — what to call instead.

Every SDK also exposes a `raw` escape hatch that returns the underlying client. Reaching for it is normal and expected for the blank cells below. **One caveat that applies everywhere:** the `raw` path bypasses the SDK's error translation, so lower-library exception types surface there. The "no lower-library types leak" guarantee covers the facade path only.

### Direct coverage

✅ present · — absent (use the escape hatch)

| | users | clients | realms | roles | groups |
|---|---|---|---|---|---|
| | C G L U D | C G L U D | C G L U D | C G L U D | C G L U D |
| **Ruby** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Java** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅—​—✅ | ✅✅✅—✅ | ✅✅✅—✅ |
| **Kotlin** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅—​—✅ | ✅✅✅—✅ | ✅✅✅—✅ |
| **Python** (sync + `aio`) | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Node** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Go** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **.NET** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **PHP** | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ | ✅✅✅✅✅ |
| **Rust** | ✅✅✅—✅ | ✅✅—​—✅ | ✅✅—​—✅ | ✅✅—​—✅ | ✅✅—​—✅ |

C=create G=get L=list/find U=update D=delete

Two languages share exactly the same four gaps: `realms.list`, `realms.update`, `roles.update`, `groups.update`. Go, Node and Python have since been filled. ⚠️ In Go, `realms.update` is the one method that does not delegate to gocloak — gocloak builds the request path from the representation and so cannot express a rename; every other language keeps path and body separate. (.NET used to be a sixth, but three of its gaps were unreachable even through the escape hatch, so they were filled directly rather than documented as workarounds.) PHP now matches .NET and Ruby at 25/25 — `update` on all five resources plus `realms.all` (the library already had both; the facade had not exposed them). Rust has no `update` and no `list` outside users.

### What you get back

| Returns representation types from the wrapped library | Returns plain maps |
|---|---|
| Java · Kotlin (`org.keycloak.representations.idm.*`) · Node (`@keycloak/keycloak-admin-client` defs) · Go (`gocloak.*`, **as pointers** — nil-check) · .NET (`Keycloak.AuthServices.Sdk.Admin.Models.*`) · PHP (`Fschmtt\Keycloak\Representation\*`, **lists come back as `*Collection` wrappers**) · Rust (`keycloak::types::*`, re-exported as `keycloak_sdk::types` so you need no extra dependency) | Python — `dict[str, Any]` · Ruby — `Hash` |

This is a deliberate, documented decision: re-wrapping stable Keycloak representation types in SDK-owned DTOs was judged not worth the cost.

### Filling the gaps

| Language | Escape hatch | Example — the `realms.update` gap |
|---|---|---|
| Java · Kotlin | `raw()` → `org.keycloak.admin.client.Keycloak` | `raw().realm(name).update(rep)` |
| Python | `raw` → `keycloak.KeycloakAdmin` | no gaps; the facade's `realms.update(current_name, rep)` wraps exactly this call (the `aio` mirror wraps `a_update_realm`) |
| Node | `raw()` → `KcAdminClient` | no gaps; the facade's `realms.update(currentName, rep)` wraps exactly this call |
| Go | `Raw()` → `*gocloak.GoCloak` | no gaps; ⚠️ do **not** reach for `Raw().UpdateRealm` — it builds the path from the representation and so cannot rename. The facade's `Realms.Update(ctx, currentName, rep)` issues the request directly for that reason |
| PHP | `raw()` → `Fschmtt\Keycloak\Keycloak` | no gaps; the hatch is the typed fschmtt client |
| Rust | `raw()` → `&KeycloakAdmin<SdkTokenSupplier>` | `raw().realm_put(&realm, rep).await` |
| Ruby | `raw` → `Faraday::Connection` | no gaps; the hatch is a general bearer-authed connection |
| .NET | `Raw` → `IKeycloakClient` (users, groups, realm-read only) | no gaps; for anything outside that typed surface the facade already uses raw Admin REST internally |

⚠️ **Go's hatch needs a token.** Every `gocloak` method takes a bearer token, and the admin facade's cached provider is not exported. Get one with `client.Auth.ClientCredentialsToken(ctx)`. Note this performs a fresh grant rather than reusing the facade's cached, single-flighted token.

⚠️ **Kotlin's hatch is blocking.** `raw()` returns the JAX-RS client directly; calls are not wrapped in `runInterruptible(Dispatchers.IO)` and will block the coroutine dispatcher. Wrap them yourself.

### Known rough edges

These are real and worth knowing before you port code between languages.

- **.NET has full coverage, for a specific reason.** Its `Raw` accessor is a *typed* client covering only users, groups, and realm-read, so `realms.list`, `realms.update`, and `roles.update` were once reachable by no route at all — short of hand-rolling a parallel `HttpClient`, which forfeits the facade's error translation, timeout injection, and redirect hardening. They are now implemented directly on the facade via raw Admin REST, the same mechanism it already used for clients and roles. Do not assume `Raw` covers everything in .NET; prefer the facade.
- **Rust `search_users` requires you to state the page explicitly** — `search_users(username, first, max)`. There is deliberately no default: Keycloak silently applies 100 when `max` is omitted, so an optional parameter would read as "no limit" and truncate anyway. Pass a negative `max` if you really want no server-side cap. For an exact single-user lookup use `find_user_by_username`, which cannot truncate. (It used to hardcode `max=20` and match exactly, with no way to detect the truncation.)
- **`findByClientId` returns different things.** Java, Kotlin, Node, Go, and .NET return a list of client representations. **Python returns the client's UUID string** (or `None`). Ruby has no such method — use `clients.list(clientId: "…")`.
- **`create` return values differ.** Most languages give you the new id. **PHP returns nothing** — for users, follow up with `findIdByUsername`; for groups there is no equivalent lookup. **Rust returns `Option<String>`**, so a successful create may still yield no id. Go returns `(string, error)`.
- **PHP uses `import`, not `create`, for clients and realms** (users, roles, and groups still use `create`). Both require the id/realm pre-set on the object you pass in.
- **Rust's admin facade is flat** — `create_user`, `get_client`, `delete_group` directly on the client, with no `users`/`clients`/… sub-objects. And **`get_realm()` takes no argument**: it returns the configured realm, while `delete_realm(name)` is name-addressed.
- **Pagination is spelled differently.** Java, Kotlin, and Go take positional `(first, max)` with no defaults; Python, Node, and .NET default them; Ruby takes free-form keyword params; PHP takes a `Criteria` object. Kotlin also requires a non-null `username` for `search`, so "list all users" is not expressible there the way it is in Node, Python, or .NET.
- **`realms.create` exists everywhere but is master-realm-only at runtime.** A realm-scoped service account gets 403 regardless of its roles.
- **Java's `Optional` and Python's `| None` on `get` are never actually empty.** Both raise a not-found error instead. Kotlin deliberately returns the value directly rather than copying the Java idiom.

## Compatibility

Each SDK's own SemVer is decoupled from the Keycloak server and underlying library versions. See the table below for the supported server range and the base libraries · runtimes.

> ⚠️ **Each row describes what that row's published version actually shipped.** The library versions in a cell are the values in the release named in the first column, not whatever `main` happens to pin today. `main` can already be ahead; the next release of that language is when this table should move. Java and Kotlin have no lockfile — their published POM / `build.gradle.kts` pins are the source; Go has no lockfile either, so its row is the `go/go.mod` of the tagged commit (`go/v0.1.0-rc.1`, which the proxy serves as the module's `.mod`). Every row now names a published version — there is no "current `main`" row left. The contract a *new* consumer resolves is still the range in each manifest; read the manifest, not this table, when that difference matters.

| SDK | Target Keycloak server | Base libraries · runtime |
|---|---|---|
| Java `0.1.0-RC1` | 26.6.x (integration tests: actual **26.6.4**) | `keycloak-admin-client` **26.0.11** (an independent version track from the server — there is no "26.6.x admin-client") · Nimbus `oauth2-oidc-sdk` **11.38.2** · JDK 21+ |
| Python `0.1.0rc1` | 26.6.x (integration tests: actual **26.6.4**) | `python-keycloak` **7.1.x** · `joserfc` **1.7.x** · Python 3.10+ |
| Node `0.1.0-rc.2` | 26.6.x (integration tests: actual **26.6**) | `@keycloak/keycloak-admin-client` **26.7.0** · `openid-client` **6.8.4** · `jose` **6.2.4** · Node 22+ |
| Go `0.1.0-rc.1` | 26.6.x (integration tests: actual **26.6**) | `Nerzal/gocloak/v13` **13.9.0** · `golang.org/x/oauth2` **0.36.0** · `go-jose/v4` **4.1.4** · Go 1.25+ |
| C#/.NET `0.1.0-rc.1` | 26.6.x (integration tests: actual **26.6**) | `Keycloak.AuthServices.Sdk` **2.7.0** · `Duende.IdentityModel` **8.1.0** · `Microsoft.IdentityModel.JsonWebTokens` **8.22.0** · .NET 8+ |
| PHP `0.1.0-rc.2` | 26.6.x (integration tests: actual **26.6**, docker CLI shell-out) | `fschmtt/keycloak-rest-api-client-php` **0.42.0** · `league/oauth2-client` **^2.8** · `stevenmaguire/oauth2-keycloak` **^6.1** · `firebase/php-jwt` **^7.1** · PHP 8.3+ |
| Rust `0.1.0-rc.1` | 26.6.x (integration tests: actual **26.6**, Testcontainers) | `keycloak` **~26.6.2** (`reqwest12` feature) · `openidconnect` **^4.0.1** · `jsonwebtoken` **^11.0.0** · Rust 1.88+ (edition 2024) |
| Ruby `0.1.0.rc1` | 26.6.x (integration tests: actual **26.6**, docker CLI shell-out) | `rack-oauth2` **~>2.3** · `faraday` **~>2.0** · `jwt` (ruby-jwt) **~>3.2** · Ruby 3.2+ |
| Kotlin `0.1.0-RC1` | 26.6.x (integration tests: actual **26.6**, Testcontainers) | `keycloak-admin-client` **26.0.11** · `oauth2-oidc-sdk` **11.38.2** · `nimbus-jose-jwt` **10.9.1** (same JVM stack as Java) · Kotlin 2.2+ consumers (built with 2.4.10, metadata pinned to 2.2) · JDK 21+ |

> Note on the Rust row: those are **ranges, not exact `=` pins**. An exact pin in a *library* crate hard-fails dependency resolution for any consumer whose tree also wants a newer compatible version. `openidconnect`/`jsonwebtoken` are ordinary semver crates and take a caret; the `keycloak` crate takes a tilde (`>=26.6.2, <26.7.0`) because its version tracks the Keycloak **server** line rather than semver. Reproducibility of *our* builds comes from the committed [`rust/Cargo.lock`](../../rust/Cargo.lock) — cargo ignores a dependency's lockfile, so as a consumer you pin with your own.

---

## Next steps

- **Language support roadmap** — currently supported languages (depth-first: Java · Python · TypeScript/Node · Go · C#/.NET · PHP · Rust · Ruby · Kotlin complete — 9 languages): [../roadmap/language-support.md](../roadmap/language-support.md)
- **Add-a-language playbook** — the procedure for adding a language with quality isomorphic to the existing Java/Python/Node/Go/C#/PHP/Rust/Ruby/Kotlin: [add-a-language-playbook.md](add-a-language-playbook.md)

> The language-neutral API contract (the source of truth) is defined in [CLAUDE.md §4](../../CLAUDE.md). Every language implements this contract, and the JWT validation hardening (algorithm pinning · `none` rejection · exact `iss` match · `aud` containment check · clock skew · DoS-safe JWKS refetch) is a cross-language mandatory requirement. Every language covers the same scenarios (full auth flow · the five admin resources · the JWT hardening probes) with a unit suite plus one Testcontainers or docker-CLI integration test. Exact test counts are intentionally **not** hand-maintained here — the authority is each language's own CI job and coverage gate; run the unit/integration command in [`.claude/rules/<lang>.md`](../../.claude/rules/) to get the current number. Counts copied into prose drift the moment CI's count changes, and the ones this file used to carry were stale for seven of the nine languages.
