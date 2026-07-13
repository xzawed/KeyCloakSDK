# Getting Started

A guide to installing the Keycloak polyglot SDK locally and running your first token issuance, JWT validation, and Admin API call with minimal code. This SDK is provided in **multiple programming languages** (currently Java · Python · Node.js · Go · C#/.NET · PHP · Rust · Ruby), and while each language is idiomatic, the concepts, layers, and flows are isomorphic.

> ⚠️ **None of the nine SDKs have been published yet (human-gated release).** Installation via Maven Central, PyPI, npm, Go module tags, NuGet, Packagist, crates.io, or RubyGems does not work yet. For now, **local installation is the default path** (see each language's "Local installation" below). For the real release procedure, see the unified nine-language [DEPLOY.md](../../DEPLOY.md) (check readiness with `scripts/release-readiness.sh` and tag commands with `scripts/release-trigger.sh <lang> <ver>` — both are human-gates that never push tags automatically).

> 🖥️ **You need a Keycloak *server* first.** This SDK is a client library, so it needs a **Keycloak server to connect to** in order to work (the server is a separate, standalone product not included in this SDK). For a local trial, use the one-line Docker command `docker run -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin quay.io/keycloak/keycloak:26.6 start-dev`; for a **production deployment**, see the [Keycloak server deployment guide](deploying-keycloak-server.md).

## Required runtime

| Language | Minimum runtime | Notes |
|---|---|---|
| **Java** | **JDK 21+** | Artifacts are compiled with `--release 21`, so older JDKs raise `UnsupportedClassVersionError` |
| **Python** | **3.10+** | Includes `py.typed` (PEP 561) — consumer-side mypy type checking possible |
| **Node.js** | **20+** | ESM-only · async-only · includes `.d.ts` type declarations |
| **Go** | **1.25+** | sync + `context.Context` · requires `x/oauth2` v0.36 |
| **C# / .NET** | **8+** | async-first (`Task<T>` + `CancellationToken`) · targets `net8.0` |
| **PHP** | **8.3+** | `final readonly class` value types · exception-based (`KeycloakException` hierarchy) |
| **Rust** | **1.88+** | MSRV required by edition 2024 + let-chains · async-only (tokio) · `thiserror`-based `KeycloakError` |
| **Ruby** | **3.2+** | sync-only · exception hierarchy (`KeycloakSdk::Error`) · gem `keycloak-sdk` / require `keycloak_sdk` |
| (optional) Docker | — | **Needed only for integration tests (Testcontainers/docker CLI)**. Not required to use the SDK itself |

---

## Java

### 1) Required runtime — JDK 21+

Artifacts are compiled with `--release 21`. **Loading them under a JDK earlier than 21 raises `UnsupportedClassVersionError`**, so the consuming application must also be built and run on JDK 21 or newer. (Originally targeted Java 17, then raised to 21 LTS on 2026-07-03.)

### 2) Local installation (current — not yet published)

Since it is not published to Maven Central, clone the repository and install it into your local `~/.m2`. `-DskipITs=true` skips **only the Docker-requiring Testcontainers integration tests** while still running unit tests and the coverage gate, so you can install without Docker:

```bash
mvn -f java/pom.xml install -DskipITs=true
```

After installation, adding just the single facade artifact to your consuming project pulls in `core`/`auth`/`admin` as transitive dependencies:

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0-SNAPSHOT</version>
</dependency>
```

### 3) Installation after release (future)

Once publishing to Maven Central is complete, just reference the same coordinates at the release version (no local `install` needed):

```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0</version>
</dependency>
```

> ⚠️ **Not yet published to Maven Central (human-gated).** The actual publish runs only when a human pushes a `v*` tag to trigger [`.github/workflows/release.yml`](../../.github/workflows/release.yml). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Full example: [`java/keycloak-sdk-examples/.../QuickStart.java`](../../java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java)

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

// try-with-resources: close() cleans up admin + auth sessions too.
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

Python 3.10 or newer is required. The package includes the PEP 561 `py.typed` marker, so consumers can also type-check with `mypy`.

### 2) Local installation (current — not yet published)

Since it is not published to PyPI, clone the repository and do an editable install or build locally:

```bash
pip install -e python
# Or build the distributable artifact locally to verify:
cd python && python -m build   # dist/keycloak_sdk-0.1.0-py3-none-any.whl + .tar.gz
```

The distribution name is `keycloak-sdk` and the import package name is `keycloak_sdk`.

### 3) Installation after release (future)

Once publishing to PyPI is complete:

```bash
pip install keycloak-sdk
```

> ⚠️ **Not yet published to PyPI (human-gated, PyPI Trusted Publisher / OIDC).** The actual publish runs only when a human pushes a `py-v*` tag to trigger [`.github/workflows/python-release.yml`](../../.github/workflows/python-release.yml). For the procedure, see [DEPLOY.md](../../DEPLOY.md); for the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Full example: [`python/examples/quickstart.py`](../../python/examples/quickstart.py) · async example: [`python/examples/async_quickstart.py`](../../python/examples/async_quickstart.py)

```python
from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk._internal.secrets import mask

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

### 1) Required runtime — Node 20+

Node.js **20 or newer** is required. The package is **ESM-only** (`"type":"module"`) and all public methods are `async` (Promise) (only `createAuthorizationRequest` is synchronous). It includes TypeScript type declarations (`.d.ts`), so consumers can type-check as well.

### 2) Local installation (current — not yet published)

Since it is not published to npm, clone the repository and build it under `node/` to reference it:

```bash
cd node && npm ci && npm run build   # generates dist/ (tsc). Consume via npm link or a file reference.
# Verify the distributable artifact (without uploading): npm pack --dry-run   # includes dist only (24kB)
```

The distribution name is `@xzawed/keycloak-sdk`, and the import path is the same.

### 3) Installation after release (future)

Once publishing to npm is complete:

```bash
npm install @xzawed/keycloak-sdk
```

> ⚠️ **Not yet published to npm (human-gated, npm Trusted Publishing / OIDC + provenance).** The actual publish runs only when a human pushes a `node-v*` tag to trigger [`.github/workflows/node-release.yml`](../../.github/workflows/node-release.yml). For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

Go **1.25 or newer** is required (its dependency `golang.org/x/oauth2` v0.36 requires it). The idiom is sync + `context.Context` (every network method takes `ctx` as its first argument, and only `CreateAuthorizationRequest` is synchronous). Docker is needed only for integration tests.

### 2) Local installation (current — not yet published)

Go modules are **published via VCS tags** with no separate registry. There is no release tag (`go/vX.Y.Z`) yet, so clone the monorepo and build under `go/`, or reference it with a `replace` directive:

```bash
cd go && go build ./... && go test ./...   # 40 unit tests + coverage gate (logic ≥90)
# Reference locally from a consuming project: add `replace github.com/xzawed/KeyCloakSDK/go => ../KeyCloakSDK/go` to go.mod
```

The module path is `github.com/xzawed/KeyCloakSDK/go` and the package name is `keycloak`.

### 3) Installation after release (future)

Once a release tag is pushed:

```bash
go get github.com/xzawed/KeyCloakSDK/go@v0.1.0
```

> ⚠️ **No release tag yet (human-gated).** Go has no registry publish, so **the tag *is* the release** — when a human pushes a `go/v*` tag, [`.github/workflows/go-release.yml`](../../.github/workflows/go-release.yml) runs verification + a GitHub Release + proxy warming, and `proxy.golang.org` auto-caches from the tag. No stored secrets are needed.

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

.NET **8 or newer** (`net8.0`) is required. The idiom is async-first (every network method takes `Task<T>` + a trailing `CancellationToken ct = default`, and only `CreateAuthorizationRequest` is purely synchronous). Docker is needed only for integration tests.

### 2) Local installation (current — not yet published)

Since it is not published to NuGet, clone the repository and attach it as a project reference from your consuming project:

```bash
dotnet add reference ../KeyCloakSDK/dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj
# Just verify a local build/test: cd dotnet && dotnet build && dotnet test --filter "Category!=Integration"   # 58 unit tests + coverage gate
```

The package ID is `Xzawed.Keycloak.Sdk`, and the root namespace is `Xzawed.Keycloak` (admin is the `Xzawed.Keycloak.Admin` sub-namespace).

### 3) Installation after release (future)

Once publishing to NuGet is complete:

```bash
dotnet add package Xzawed.Keycloak.Sdk
```

> ⚠️ **Not yet published to NuGet (human-gated).** The actual publish runs only when a human pushes a `dotnet-v*` tag to trigger [`.github/workflows/dotnet-release.yml`](../../.github/workflows/dotnet-release.yml) (requires the `NUGET_API_KEY` secret). For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

PHP **8.3 or newer** is required. Value types are declared as `final readonly class` (immutable), and the idiom is exception-based (`KeycloakException` hierarchy). Docker is needed only for integration tests.

### 2) Local installation (current — not yet published)

Since it is not published to Packagist, clone the repository and reference it as a local path repository, or build directly under `php/` to verify:

```bash
cd php && composer install   # install dependencies (fschmtt/league/stevenmaguire/firebase, etc.)
# Reference locally from a consuming project: add a path repository to composer.json
#   { "repositories": [{ "type": "path", "url": "../KeyCloakSDK/php" }] }
#   composer require xzawed/keycloak-sdk:@dev
```

The distribution name is `xzawed/keycloak-sdk`, and the root namespace is `Xzawed\Keycloak` (admin is the `Xzawed\Keycloak\Admin` sub-namespace).

### 3) Installation after release (future)

Once publishing to Packagist is complete:

```bash
composer require xzawed/keycloak-sdk
```

> ⚠️ **Not yet published to Packagist (human-gated).** Composer/Packagist is not a registry upload — instead **Packagist detects the tag via a GitHub webhook** and publishes it automatically (no separate secrets). The actual publish runs only when a human pushes a `php-v*` tag to trigger [`.github/workflows/php-release.yml`](../../.github/workflows/php-release.yml), and registering the `xzawed/keycloak-sdk` repository on Packagist requires a one-time manual step first. For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

## Rust

### 1) Required runtime — Rust 1.88+

Rust **1.88 or newer** (MSRV — required by edition 2024 + let-chains) is required. The idiom is async-only (tokio), and instead of exceptions it uses a `thiserror`-based `KeycloakError` enum (`Config`/`Auth`/`Transport`/`Admin`/`TokenValidation`) + `Result<T, KeycloakError>`. Docker is needed only for integration tests.

### 2) Local installation (current — not yet published)

Since it is not published to crates.io, clone the repository and reference it as a path dependency in your consuming project's `Cargo.toml`:

```toml
[dependencies]
keycloak-sdk = { path = "../KeyCloakSDK/rust" }
```

```bash
cd rust && cargo build && cargo test   # Just verify a local build/test: 34 unit tests + coverage gate
```

The crate name is `keycloak-sdk`, and the root module is `keycloak_sdk` (`keycloak_sdk::{KeycloakClient, KeycloakConfig, ...}`).

### 3) Installation after release (future)

Once publishing to crates.io is complete:

```bash
cargo add keycloak-sdk
```

> ⚠️ **Not yet published to crates.io (human-gated).** The actual publish runs only when a human pushes a `rust-v*` tag to trigger [`.github/workflows/rust-release.yml`](../../.github/workflows/rust-release.yml) (requires the `CARGO_REGISTRY_TOKEN` secret). For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

### 4) Minimal usage example

Full example: [`rust/examples/quickstart.rs`](../../rust/examples/quickstart.rs)

```rust
use keycloak::types::UserRepresentation;
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

Ruby **3.2 or newer** (dev/CI top end 3.4) is required. The idiom is sync-only (all wrapped gems are synchronous), and it uses exception-based idioms (`KeycloakSdk::Error` hierarchy — isomorphic with Java/Python/Node/C#/PHP, in contrast to the error-value idioms of Go/Rust). Docker is needed only for integration tests.

### 2) Local installation (current — not yet published)

Since it is not published to RubyGems, clone the repository and install the dependencies under `ruby/` to verify:

```bash
cd ruby && bundle install   # install dependencies (faraday/jwt/rack-oauth2, etc.)
# Reference locally from a consuming project: add `gem "keycloak-sdk", path: "../KeyCloakSDK/ruby"` to your Gemfile
```

The gem name is `keycloak-sdk` (hyphen), and the require/module name is `keycloak_sdk`/`KeycloakSdk` (underscore — to avoid a clash with the existing `keycloak` gem's `Keycloak` module).

### 3) Installation after release (future)

Once publishing to RubyGems is complete:

```bash
gem install keycloak-sdk
```

> ⚠️ **Not yet published to RubyGems (human-gated, RubyGems Trusted Publishing / OIDC).** The actual publish runs only when a human pushes a `ruby-v*` tag to trigger [`.github/workflows/ruby-release.yml`](../../.github/workflows/ruby-release.yml) (the first time requires either a manual API-key publish or pre-registering a Trusted Publisher in the rubygems.org UI — you cannot register one before the gem exists). For the future language expansion roadmap, see the [language support roadmap](../roadmap/language-support.md).

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

---

## Compatibility

Each SDK's own SemVer is decoupled from the Keycloak server and underlying library versions. See the table below for the supported server range and the base libraries · runtimes.

| SDK | Target Keycloak server | Base libraries · runtime |
|---|---|---|
| Java `0.1.0-SNAPSHOT` | 26.6.x (integration tests: actual **26.6.4**) | `keycloak-admin-client` **26.0.10** (an independent version track from the server — there is no "26.6.x admin-client") · Nimbus `oauth2-oidc-sdk` **11.37.2** · JDK 21+ |
| Python `0.1.0` | 26.6.x (integration tests: actual **26.6.4**) | `python-keycloak` **7.1.x** · `joserfc` **1.7.x** · Python 3.10+ |
| Node `0.1.0` | 26.6.x (integration tests: actual **26.6**) | `@keycloak/keycloak-admin-client` **26.6.4** · `openid-client` **6.8.4** · `jose` **5.10.0** · Node 20+ |
| Go `0.1.0` | 26.6.x (integration tests: actual **26.6**) | `Nerzal/gocloak/v13` **13.9.0** · `golang.org/x/oauth2` **0.36.0** · `go-jose/v4` **4.1.4** · Go 1.25+ |
| C#/.NET `0.1.0` | 26.6.x (integration tests: actual **26.6**) | `Keycloak.AuthServices.Sdk` **2.7.0** · `Duende.IdentityModel` **8.1.0** · `Microsoft.IdentityModel.JsonWebTokens` **8.19.1** · .NET 8+ |
| PHP `0.1.0` | 26.6.x (integration tests: actual **26.6**, docker CLI shell-out) | `fschmtt/keycloak-rest-api-client-php` **0.42.0** · `league/oauth2-client` **^2.8** · `stevenmaguire/oauth2-keycloak` **^6.1** · `firebase/php-jwt` **^7.1** · PHP 8.3+ |
| Rust `0.1.0` | 26.6.x (integration tests: actual **26.6**, Testcontainers) | `keycloak` **=26.6.2** (`reqwest12` feature) · `openidconnect` **=4.0.1** · `jsonwebtoken` **=10.4.0** · Rust 1.88+ (edition 2024) |
| Ruby `0.1.0` | 26.6.x (integration tests: actual **26.6**, docker CLI shell-out) | `rack-oauth2` **~>2.3** · `faraday` **~>2.0** · `jwt` (ruby-jwt) **~>3.2** · Ruby 3.2+ |
| Kotlin `0.1.0` | 26.6.x (integration tests: actual **26.6**, Testcontainers) | `keycloak-admin-client` **26.0.10** · `oauth2-oidc-sdk` **11.37.2** · `nimbus-jose-jwt` **10.9.1** (same JVM stack as Java) · Kotlin 2.2.20+ / JDK 21+ |

---

## Next steps

- **Language support roadmap** — currently supported languages (depth-first: Java · Python · TypeScript/Node · Go · C#/.NET · PHP · Rust · Ruby · Kotlin complete — 9 languages): [../roadmap/language-support.md](../roadmap/language-support.md)
- **Add-a-language playbook** — the procedure for adding a language with quality isomorphic to the existing Java/Python/Node/Go/C#/PHP/Rust/Ruby/Kotlin: [add-a-language-playbook.md](add-a-language-playbook.md)

> The language-neutral API contract (the source of truth) is defined in [design spec §4](../superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md). Every language implements this contract, and the JWT validation hardening (algorithm pinning · `none` rejection · exact `iss` match · `aud` containment check · clock skew · DoS-safe JWKS refetch) is a cross-language mandatory requirement. Current test counts: **Java 123** (117 unit + 6 Testcontainers integration) · **Python 235** (224 unit + 11 integration) · **Node 76** (71 unit + 5 Testcontainers integration) · **Go 41** (40 unit + 1 Testcontainers integration — E2E, full flow · 5 admin resources) · **C#/.NET 59** (58 unit + 1 Testcontainers integration — E2E `Full_flow`, full flow · 5 admin resources) · **PHP 67** (64 unit + 3 integration — docker CLI shell-out, `FullFlowIT`: full flow · client CRUD · raw escape hatch) · **Rust 35** (34 unit + 1 Testcontainers integration — E2E `full_flow`, full flow · 5 admin resources) · **Ruby 74** (73 unit + 1 integration — docker CLI shell-out, E2E `full_flow`, full flow · 5 admin resources) · **Kotlin 101** (100 unit + 1 Testcontainers integration — E2E `FullFlowIT`, full flow · 5 admin resources). Total **811**.
