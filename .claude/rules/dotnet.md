---
paths:
  - "dotnet/**"
  - "harness/apps/dotnet/**"
  - "harness/install/consume/dotnet*"
  - "harness/install/consume/dotnet/**"
  - ".github/workflows/dotnet-*.yml"
---

# C#/.NET rules

## Toolchain

System install — ask `node scripts/doctor.mjs dotnet` for the SDK actually present (⚠️ this line claimed SDK 10; measured 8.0.424). Commands run from `dotnet/`.

```bash
cd dotnet && dotnet build                                       # warnaserror · Nullable · AnalysisLevel 8.0
cd dotnet && dotnet test --filter "Category!=Integration"       # unit. No Docker
cd dotnet && dotnet test --filter "Category=Integration"        # integration E2E. Needs Docker (KC 26.6)
cd dotnet && dotnet format Keycloak.Sdk.sln --verify-no-changes
cd dotnet && dotnet pack src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release   # release build check
```

- A single test: `dotnet test --filter "FullyQualifiedName~<TestName>"`
- **Coverage happens in two stages.** Collection is the coverlet **collector**; the verdict is `scripts/check-coverage.mjs` (the SSOT for the exclusion filters is `dotnet/coverlet.runsettings`):
  ```bash
  cd dotnet && dotnet test --filter "Category!=Integration" \
    --collect:"XPlat Code Coverage" --settings coverlet.runsettings --results-directory /tmp/cov
  node ../scripts/check-coverage.mjs /tmp/cov --min-line 90 --min-branch 85
  ```
  ⚠️ **The numbers are not written here.** `check-coverage.mjs` prints lines, branches and the headroom on every run — read them from it. This line used to carry `96.91% (188/194)` / `90.00% (45/50)`; the denominators moved to 213 and 52 and every transcribed figure went false while the rule read as verified.
- Releasing goes `dotnet-v*` tag → `dotnet-release.yml` (human approval gate). The `integration` job is in `needs:` ahead of publishing.
- The solution uses the old format, `Keycloak.Sdk.sln` — newer SDKs default to `.slnx`. `AnalysisLevel=8.0` pins the analyzer band so a locally-installed SDK newer than CI's cannot introduce warnings CI never sees. ⚠️ This line used to justify both by "local is SDK 10", which was false; both settings are still right, the stated reason was not. `GenerateDocumentationFile` and the packaging props are conditioned on `IsTestProject != true` — without that, the test projects fail the build with CS1591.

## Two coverage traps

- ⚠️ **Do not use the coverlet **msbuild** integration.** It flushes hits on `ProcessExit`, and VSTest waits only briefly for the process to exit, so on a slow run you get a report where the denominator survives but **the numerator alone is 0**. Its built-in threshold gate reports that in **exactly the same words** as a genuine drop (re-running the same commit passed). The collector flushes on `SessionEnd`, so it has no such path, and `check-coverage.mjs` **looks at the numerator and the denominator separately** (`lines-valid>0` with `lines-covered==0` is a measurement failure, not a drop).
- ⚠️ **Read the headroom on the branch gate as a count, not as a percentage.** The denominator is small enough that one branch is worth about two percentage points, so a single `if` without an `else` can break the gate. That is why `check-coverage.mjs` prints `브랜치 여유: N개` ("branch headroom: N") on every run. **Seeing 0% and lowering the threshold is precisely the wrong response.**

## admin surface

- ⚠️ **`Raw` is a typed client, so it only covers users, groups and realm-read.** For every other operation, this SDK's idiom is for the facade to implement it directly against the raw Admin REST API (`SendRawAsync` / `GetJsonAsync`) — do not stop just because a new admin operation is missing from the typed client. Currently 25/25.
- ⚠️ **Namespace shadowing**: inside `Xzawed.Keycloak.Admin`, `new KeycloakClient(http)` binds to the facade (whose ctor is private) and gives CS1729 — the alias `using KcAdminClient = Keycloak.AuthServices.Sdk.Admin.KeycloakClient;` is required.
- `CreateUserAsync` returns void, so take the id from `CreateUserWithResponseAsync` plus the `Location` header.
- ⚠️ **`POST /admin/realms` (creating a new realm) is master-realm only** — a service account in any realm gets a 403. The E2E verifies it with the master bootstrap admin.

## Library gotchas

- ⚠️ **`JsonWebTokenHandler.ValidateTokenAsync` does not throw on failure** — checking `result.IsValid` is mandatory. Its defaults are not safe either: `ValidAlgorithms` is `null` (everything allowed), so pin `["RS256"]`; `ClockSkew` 5 minutes → 30 seconds; `RequireExpirationTime=true`. **Test trap**: `CreateToken` injects `exp` automatically, so a no-exp test needs `SetDefaultTimesOnTokenCreation=false`.
- ⚠️ **A forged signature triggers a JWKS refetch — of all nine languages, .NET is the only one where that happens.** `Microsoft.IdentityModel` reads a signature failure as a key-rotation signal, calls `RequestRefresh()` and retries, and it cannot be turned off short of abandoning `ConfigurationManager`. The only thing limiting the actual damage is `RefreshIntervalSeconds` (30 seconds) — measured: 6 forgeries → 1 extra fetch. **Do not change the test to "0 times"** — that would assert something this SDK does not do.
- ⚠️ **An expiring `HttpClient.Timeout` raises `TaskCanceledException`, not `HttpRequestException`** — catch and convert it at the boundary with `catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)`.
- ⚠️ **The Duende.IdentityModel extension methods do not throw** (check `resp.IsError`). Bad credentials also come back as a 401 (`ErrorType=Http`), so read the error code from `resp.Json["error"]`. PKCE is unsupported (generate it by hand), and logout is a manual POST.
- ⚠️ **A `record`'s generated `ToString()` exposes every token and secret** — `TokenSet` and `KeycloakConfig` mask them with a `ToString()` override plus a `JsonConverter<T>`. **But Serilog's `{@}` destructuring reads the raw properties directly and bypasses the masking, so never write those two types with `{@}`.**
- ⚠️ **`AddKeycloak(config)` also registers `KeycloakConfig` as a singleton** — a consumer who adds their own `AddSingleton<KeycloakConfig>` makes the resolution ambiguous.

## Dependency and structural decisions

- ⚠️ **`Keycloak.AuthServices.Sdk` 3.0.0 is net10-only, so net8.0 pins 2.7.0.** Anything below the `DI.Abstractions >= 9.0.8` that 2.7.0 requires is a hard NU1605 error.
- ⚠️ **The 10.x major of `DI.Abstractions` is on hold under the keep-net8 policy** — take the 9.x patches, close 10.x. The current pin is written only in the dependency table in the root `CLAUDE.md`.
- **`IHttpClientFactory` is deliberately not used** — a single long-lived `HttpClient` plus `PooledConnectionLifetime` (5 minutes) avoids stale DNS. This is a library used without DI, so it does not force a factory lifecycle onto the consumer.
- The glue between `admin` and `auth` is `ITokenProvider` alone (`AuthClient : ITokenSource` is the default source) — §4 isomorphic.
