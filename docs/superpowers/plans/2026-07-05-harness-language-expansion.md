# 하네스 5개 언어 확장 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 하네스에 C#/Node/Python/Java 샘플 앱 4종을 동일 HTTP 계약으로 추가해, `./run.sh go dotnet node python java` 한 줄로 5개 SDK를 실제 Keycloak에 대해 기능 정확성(checks==1.00) 강제 + 성능 실측 비교한다.

**Architecture:** 각 앱은 기존 Go 앱과 동형이다 — 계약(`harness/contract/CONTRACT.md`)의 8엔드포인트를 그 언어의 관용 웹 프레임워크로 노출하고, 로컬 SDK를 소비(빌드가 곧 배포가능성 스모크)하며, 멀티스테이지 Dockerfile(빌드 컨텍스트=리포지토리 루트)로 패키징한다. 드라이버·리포트·`run.sh`는 이미 언어-무관이라 손대지 않는다. 각 앱마다 `docker-compose.yml`에 `app-<lang>` 서비스(profile `apps`)를 추가한다.

**Tech Stack:** C#/.NET 8(ASP.NET Core Minimal API) · Node 22(Express 5, ESM) · Python 3.12(FastAPI + uvicorn, async `keycloak_sdk.aio`) · Java 21(Spring Boot 3, Spring MVC) · Docker Compose · k6.

## Global Constraints

이 섹션은 모든 태스크에 암묵적으로 적용된다.

- **환경변수(하네스 관례, `KC_*`)**: `KC_SERVER_URL`(기본 `http://localhost:8080`), `KC_REALM`(`it-realm`), `KC_CLIENT_ID`(`it-client`), `KC_CLIENT_SECRET`(`it-secret`), `APP_PORT`(`8090`). 앱 코드는 반드시 이 이름을 읽는다(`KEYCLOAK_*` 아님 — 기존 compose와 일치해야 함).
- **포트**: 컨테이너 **내부 포트는 전 언어 8090**(계약 단순화, `run.sh`의 `app_port()` 고정). **호스트 포트만 상이**: go=8090 · dotnet=8091 · node=8092 · python=8093 · java=8094.
- **빌드 컨텍스트 = 리포지토리 루트**(`docker-compose.yml`의 `context: ..`). Dockerfile은 SDK 소스와 앱 소스를 상대경로 보존해 복사한다.
- **SDK는 로컬 소비**: 각 앱은 발행되지 않은 로컬 SDK를 그 언어 관용 방식으로 소비한다(빌드가 배포가능성 스모크). 절대 원격 레지스트리에서 받지 않는다.
- **계약 고정**: `harness/contract/CONTRACT.md`의 8엔드포인트·요청/응답 스키마·오류 매핑을 정확히 구현한다. 계약·`driver/scenarios.js`·`report/aggregate.mjs`·`run.sh`는 **수정 금지**.
- **오류 매핑(동형성)**: SDK NotFound류→404 · SDK Conflict류→409 · JWT 검증 실패→401 · 기타→500 `{"error":"<msg>"}`. 토큰/시크릿은 응답·로그에 노출 금지.
- **런타임 이미지 비-root 사용자**(기존 Go 앱과 동일 관례).
- **검증에는 Docker 필요**: 각 태스크 검증(`./run.sh <lang>`)은 로컬 Docker Desktop이 실행 중이어야 한다. Keycloak 컨테이너 부팅(~30s) + 앱 빌드 + k6 30s로 태스크당 수 분 소요(Java Spring Boot 빌드가 가장 김).
- **프레임워크 오버헤드 주의**: 관용 프레임워크 선택이므로 성능 실측은 "SDK-in-idiomatic-app" 수치다(pure SDK 아님). 기능 게이트(checks==1.00)는 프레임워크와 무관.

**계약 8엔드포인트(참조):**

| 메서드·경로 | 요청 body | 성공 | 실패 |
|---|---|---|---|
| `GET /healthz` | — | 200 `{"status":"ok"}` | 503 |
| `POST /token` | — | 200 `{"tokenType":"Bearer","expiresIn":<int>}` | 500 `{"error":".."}` |
| `POST /validate` | `{"token":"<jwt>"}` | 200 `{"subject","audience","issuer","expiresAt"}` | 401 `{"error":".."}` |
| `POST /introspect` | `{"token":"<jwt>"}` | 200 `{"active","username","clientId"}` | 500 |
| `POST /admin/users` | `{"username","email"}` | 201 `{"id"}` | 409/500 |
| `GET /admin/users/{id}` | — | 200 `{"id","username"}` | 404 |
| `GET /admin/users?username=<u>` | — | 200 `[{"id","username"}]` | 500 |
| `DELETE /admin/users/{id}` | — | 204 | 404 |

---

### Task 0: 공유 `.dockerignore` (빌드 위생)

빌드 컨텍스트가 리포지토리 루트라, 각 언어의 로컬 빌드 산출물(`bin`/`obj`/`target`/`node_modules`/`.venv`/`dist`)이 Docker 컨텍스트로 딸려 들어가면 이미지 오염·restore 충돌을 일으킨다. 루트 `.dockerignore`로 차단한다. Go MVP는 클린 빌드라 영향 없다.

**Files:**
- Create: `.dockerignore`

- [ ] **Step 1: `.dockerignore` 작성**

```
# 하네스 Docker 빌드(컨텍스트=리포 루트)에서 언어별 로컬 산출물 제외
**/bin/
**/obj/
**/target/
**/node_modules/
**/.venv/
**/__pycache__/
**/*.pyc
node/dist/
.git/
```

> 주: `node/dist/`는 Node SDK Dockerfile이 이미지 내부에서 재빌드하므로 호스트 dist 제외가 안전하다. `.git/`은 dotnet SourceLink가 없어도 되도록 제외(Dockerfile에서 `EnableSourceLink=false`로 이중 안전).

- [ ] **Step 2: 기존 Go 빌드 회귀 없음 확인**

Run: `cd harness && ./run.sh go`
Expected: 기존과 동일하게 `report/RESULTS.md`의 go 행이 checks 100%(✅). `.dockerignore`가 Go 빌드에 무해함을 확인.

- [ ] **Step 3: Commit**

```bash
git add .dockerignore
git commit -m "chore(harness): 루트 .dockerignore — 언어별 빌드 산출물 제외(멀티랭 앱 빌드 위생)"
```

---

### Task 1: C#/.NET 샘플 앱 (`app-dotnet`)

**Files:**
- Create: `harness/apps/dotnet/App.csproj`
- Create: `harness/apps/dotnet/Program.cs`
- Create: `harness/apps/dotnet/Dockerfile`
- Modify: `harness/docker-compose.yml` (append `app-dotnet` service)

**Interfaces:**
- Consumes(SDK): `KeycloakClient.Create(KeycloakConfig)` → facade; `client.Auth.ClientCredentialsTokenAsync(ct)`→`TokenSet{TokenType,ExpiresIn(long)}`; `client.Auth.ValidateAsync(token,ct)`→`ValidatedToken{Subject,Audience(IReadOnlyList<string>),Issuer,ExpiresAt(long?)}`; `client.Auth.IntrospectAsync(token,ct)`→`IntrospectionResult{Active,Username?,ClientId?}`; `await client.AdminAsync(ct)`→`AdminClient`; `admin.Users.CreateAsync(UserRepresentation,ct)`→`string id`; `admin.Users.GetAsync(id,ct)`→`UserRepresentation{Id,Username}`; `admin.Users.SearchAsync(username,0,20,ct)`→`IReadOnlyList<UserRepresentation>`; `admin.Users.DeleteAsync(id,ct)`. Exceptions: `KeycloakNotFoundException`(404), `KeycloakConflictException`(409), `KeycloakTokenValidationException`/`KeycloakAuthException`(→401).
- Produces(harness): compose 서비스 `app-dotnet`(호스트 8091), `./run.sh dotnet`로 구동 가능.

- [ ] **Step 1: compose 서비스 추가(게이트 배선)**

`harness/docker-compose.yml` 끝에 append:

```yaml

  app-dotnet:
    build: { context: .., dockerfile: harness/apps/dotnet/Dockerfile }
    environment:
      KC_SERVER_URL: http://keycloak:8080
      KC_REALM: it-realm
      KC_CLIENT_ID: it-client
      KC_CLIENT_SECRET: it-secret
      APP_PORT: "8090"
    ports:
      - "8091:8090"
    depends_on:
      keycloak:
        condition: service_healthy
    profiles: ["apps"]
```

- [ ] **Step 2: 게이트가 실패하는지 확인(앱 미존재)**

Run: `cd harness && ./run.sh dotnet`
Expected: FAIL — `app-dotnet` 빌드 단계에서 Dockerfile/소스가 없어 비0 종료(리포트에 dotnet MISSING 또는 빌드 실패). 게이트가 배선됐음을 확인.

- [ ] **Step 3: `App.csproj` 작성**

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>Harness.Dotnet</RootNamespace>
  </PropertyGroup>
  <ItemGroup>
    <!-- 로컬 SDK 소스 참조(Go replace와 동형) — 빌드=배포가능성 스모크 -->
    <ProjectReference Include="../../../dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj" />
  </ItemGroup>
</Project>
```

- [ ] **Step 4: `Program.cs` 작성 (Minimal API, 8엔드포인트)**

```csharp
using Xzawed.Keycloak;
using Xzawed.Keycloak.Admin;
using Keycloak.AuthServices.Sdk.Admin.Models;

var builder = WebApplication.CreateBuilder(args);

static string Env(string k, string d) =>
    Environment.GetEnvironmentVariable(k) is { Length: > 0 } v ? v : d;

var config = new KeycloakConfig
{
    ServerUrl = Env("KC_SERVER_URL", "http://localhost:8080"),
    Realm = Env("KC_REALM", "it-realm"),
    ClientId = Env("KC_CLIENT_ID", "it-client"),
    ClientSecret = Env("KC_CLIENT_SECRET", "it-secret"),
};
var kc = KeycloakClient.Create(config);

var app = builder.Build();

static IResult Fail(int code, string msg) =>
    Results.Json(new { error = msg }, statusCode: code);

app.MapGet("/healthz", () => Results.Json(new { status = "ok" }));

app.MapPost("/token", async (CancellationToken ct) =>
{
    try
    {
        var ts = await kc.Auth.ClientCredentialsTokenAsync(ct);
        return Results.Json(new { tokenType = ts.TokenType, expiresIn = ts.ExpiresIn });
    }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapPost("/validate", async (TokenBody body, CancellationToken ct) =>
{
    if (string.IsNullOrEmpty(body?.Token)) return Fail(400, "token required");
    try
    {
        var vt = await kc.Auth.ValidateAsync(body.Token, ct);
        return Results.Json(new { subject = vt.Subject, audience = vt.Audience, issuer = vt.Issuer, expiresAt = vt.ExpiresAt });
    }
    catch (KeycloakTokenValidationException e) { return Fail(401, e.Message); }
    catch (KeycloakAuthException e) { return Fail(401, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapPost("/introspect", async (TokenBody body, CancellationToken ct) =>
{
    if (string.IsNullOrEmpty(body?.Token)) return Fail(400, "token required");
    try
    {
        var ir = await kc.Auth.IntrospectAsync(body.Token, ct);
        return Results.Json(new { active = ir.Active, username = ir.Username, clientId = ir.ClientId });
    }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapPost("/admin/users", async (CreateBody body, CancellationToken ct) =>
{
    if (string.IsNullOrEmpty(body?.Username)) return Fail(400, "username required");
    try
    {
        var admin = await kc.AdminAsync(ct);
        var id = await admin.Users.CreateAsync(
            new UserRepresentation { Username = body.Username, Email = body.Email, Enabled = true }, ct);
        return Results.Json(new { id }, statusCode: 201);
    }
    catch (KeycloakConflictException e) { return Fail(409, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapGet("/admin/users/{id}", async (string id, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        var u = await admin.Users.GetAsync(id, ct);
        return Results.Json(new { id = u.Id, username = u.Username });
    }
    catch (KeycloakNotFoundException e) { return Fail(404, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapGet("/admin/users", async (string? username, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        var us = await admin.Users.SearchAsync(username, 0, 20, ct);
        return Results.Json(us.Select(u => new { id = u.Id, username = u.Username }));
    }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapDelete("/admin/users/{id}", async (string id, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        await admin.Users.DeleteAsync(id, ct);
        return Results.StatusCode(204);
    }
    catch (KeycloakNotFoundException e) { return Fail(404, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.Run($"http://0.0.0.0:{Env("APP_PORT", "8090")}");

record TokenBody(string Token);
record CreateBody(string Username, string? Email);
```

> 주: ASP.NET Core JSON 바인딩은 기본 대소문자 무시라 `{"token":...}`→`TokenBody.Token`에 바인딩된다. TokenSet.ExpiresIn(long)이 있어 `/token`의 expiresIn을 직접 노출(Python/Java와 달리 파생 불필요).

- [ ] **Step 5: `Dockerfile` 작성**

```dockerfile
# build context = repo root (docker-compose.yml의 context: ..)
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
# ProjectReference 대상(SDK)과 앱 소스를 상대경로 보존해 복사(tests 제외)
COPY dotnet/Directory.Build.props ./dotnet/
COPY dotnet/src/ ./dotnet/src/
COPY harness/apps/dotnet/ ./harness/apps/dotnet/
# EnableSourceLink=false: .git 미포함 컨텍스트에서 SourceLink 경고 방지
# TreatWarningsAsErrors=false: 하네스 빌드가 SDK-측 엄격도에 걸리지 않도록(SDK는 자체 CI에서 클린)
RUN dotnet publish harness/apps/dotnet/App.csproj -c Release -o /out \
    -p:EnableSourceLink=false -p:TreatWarningsAsErrors=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
RUN adduser --disabled-password --uid 10001 app && chown app /app
COPY --from=build /out/ ./
USER app
EXPOSE 8090
ENTRYPOINT ["dotnet", "App.dll"]
```

- [ ] **Step 6: 게이트 통과 확인**

Run: `cd harness && ./run.sh dotnet`
Expected: PASS — `report/RESULTS.md`의 dotnet 행 checks 100%(✅), validate/admin p95·RPS 실측 채워짐, 오류율 0%. (k6 `checks: rate==1.00` 게이트 통과 → `run.sh` rc=0.)

- [ ] **Step 7: (디버깅용, 게이트 실패 시) 수동 스모크**

```bash
cd harness && docker compose up -d keycloak
# keycloak healthy 대기 후:
docker compose --profile apps up -d --build app-dotnet
curl -s localhost:8091/healthz            # {"status":"ok"}
curl -s -XPOST localhost:8091/token       # {"tokenType":"Bearer","expiresIn":...}
docker compose --profile apps down -v
```

- [ ] **Step 8: Commit**

```bash
git add harness/apps/dotnet harness/docker-compose.yml
git commit -m "feat(harness): C#/.NET 샘플 앱(app-dotnet) — ASP.NET Core Minimal API + SDK ProjectReference 소비"
```

---

### Task 2: Node 샘플 앱 (`app-node`)

**Files:**
- Create: `harness/apps/node/package.json`
- Create: `harness/apps/node/server.js`
- Create: `harness/apps/node/Dockerfile`
- Modify: `harness/docker-compose.yml` (append `app-node` service)

**Interfaces:**
- Consumes(SDK, from `@xzawed/keycloak-sdk`): `KeycloakClient.create({serverUrl,realm,clientId,clientSecret})`; `client.auth.clientCredentialsToken()`→`{tokenType,expiresIn}`; `client.auth.validate(token)`→`{subject,audience(array),issuer,expiresAt}`; `client.auth.introspect(token)`→`{active,username,clientId}`; `await client.admin()`→AdminClient; `admin.users.create({username,email,enabled})`→`id:string`; `admin.users.get(id)`→user(throws `KeycloakNotFoundError`); `admin.users.search(username,0,20)`→user[]; `admin.users.delete(id)`. Error classes: `KeycloakNotFoundError`, `KeycloakConflictError`, `KeycloakTokenValidationError`.
- Produces(harness): compose 서비스 `app-node`(호스트 8092).

- [ ] **Step 1: compose 서비스 추가**

`harness/docker-compose.yml` 끝에 append:

```yaml

  app-node:
    build: { context: .., dockerfile: harness/apps/node/Dockerfile }
    environment:
      KC_SERVER_URL: http://keycloak:8080
      KC_REALM: it-realm
      KC_CLIENT_ID: it-client
      KC_CLIENT_SECRET: it-secret
      APP_PORT: "8090"
    ports:
      - "8092:8090"
    depends_on:
      keycloak:
        condition: service_healthy
    profiles: ["apps"]
```

- [ ] **Step 2: `package.json` 작성**

```json
{
  "name": "harness-app-node",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "@xzawed/keycloak-sdk": "file:./xzawed-keycloak-sdk.tgz",
    "express": "^5"
  }
}
```

> 주: SDK는 `npm pack` 산출 tarball(`file:`)로 소비 — `files:["dist"]` 실제 배포 형상을 검증(가장 강한 배포가능성 스모크). tarball은 Dockerfile이 install 전에 `./xzawed-keycloak-sdk.tgz`로 배치한다.

- [ ] **Step 3: `server.js` 작성 (ESM, Express 5, 8엔드포인트)**

```js
import express from 'express'
import {
  KeycloakClient,
  KeycloakNotFoundError,
  KeycloakConflictError,
  KeycloakTokenValidationError,
} from '@xzawed/keycloak-sdk'

const env = (k, d) => process.env[k] || d
const kc = KeycloakClient.create({
  serverUrl: env('KC_SERVER_URL', 'http://localhost:8080'),
  realm: env('KC_REALM', 'it-realm'),
  clientId: env('KC_CLIENT_ID', 'it-client'),
  clientSecret: env('KC_CLIENT_SECRET', 'it-secret'),
})

const app = express()
app.use(express.json())
const fail = (res, code, msg) => res.status(code).json({ error: msg })

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }))

app.post('/token', async (_req, res) => {
  try {
    const ts = await kc.auth.clientCredentialsToken()
    res.json({ tokenType: ts.tokenType, expiresIn: ts.expiresIn })
  } catch (e) { fail(res, 500, e.message) }
})

app.post('/validate', async (req, res) => {
  const token = req.body?.token
  if (!token) return fail(res, 400, 'token required')
  try {
    const vt = await kc.auth.validate(token)
    res.json({ subject: vt.subject, audience: vt.audience, issuer: vt.issuer, expiresAt: vt.expiresAt })
  } catch (e) {
    if (e instanceof KeycloakTokenValidationError) return fail(res, 401, e.message)
    fail(res, 500, e.message)
  }
})

app.post('/introspect', async (req, res) => {
  const token = req.body?.token
  if (!token) return fail(res, 400, 'token required')
  try {
    const ir = await kc.auth.introspect(token)
    res.json({ active: ir.active, username: ir.username, clientId: ir.clientId })
  } catch (e) { fail(res, 500, e.message) }
})

app.post('/admin/users', async (req, res) => {
  const { username, email } = req.body || {}
  if (!username) return fail(res, 400, 'username required')
  try {
    const admin = await kc.admin()
    const id = await admin.users.create({ username, email, enabled: true })
    res.status(201).json({ id })
  } catch (e) {
    if (e instanceof KeycloakConflictError) return fail(res, 409, e.message)
    fail(res, 500, e.message)
  }
})

app.get('/admin/users/:id', async (req, res) => {
  try {
    const admin = await kc.admin()
    const u = await admin.users.get(req.params.id)
    res.json({ id: u.id, username: u.username })
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

app.get('/admin/users', async (req, res) => {
  try {
    const admin = await kc.admin()
    const us = await admin.users.search(req.query.username, 0, 20)
    res.json(us.map((u) => ({ id: u.id, username: u.username })))
  } catch (e) { fail(res, 500, e.message) }
})

app.delete('/admin/users/:id', async (req, res) => {
  try {
    const admin = await kc.admin()
    await admin.users.delete(req.params.id)
    res.status(204).end()
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

const port = env('APP_PORT', '8090')
app.listen(Number(port), () => console.log(`listening on ${port}`))
```

> 주: `kc.admin()`은 **메서드**라 매번 `await`(첫 호출만 실제 빌드, 이후 캐시 즉시반환). `users.create`는 **id 문자열을 직접 반환**(C#처럼 Location 파싱 불필요). `users.get`은 부재 시 `KeycloakNotFoundError` throw(null 반환 아님).

- [ ] **Step 4: `Dockerfile` 작성**

```dockerfile
# build context = repo root
FROM node:22-alpine AS sdk
WORKDIR /sdk
COPY node/ ./
# SDK 빌드(dist) 후 배포 형상 tarball 생성(files:["dist"]만 포함)
RUN npm ci && npm run build && npm pack --pack-destination /pack

FROM node:22-alpine AS app
WORKDIR /app
COPY harness/apps/node/package.json ./package.json
# npm pack 산출물(xzawed-keycloak-sdk-<ver>.tgz)을 package.json이 참조하는 고정 이름으로 배치
COPY --from=sdk /pack/*.tgz ./xzawed-keycloak-sdk.tgz
COPY harness/apps/node/server.js ./server.js
RUN npm install --omit=dev
USER node
EXPOSE 8090
CMD ["node", "server.js"]
```

> 주: `npm install`이 tarball의 `dependencies`(@keycloak/keycloak-admin-client·openid-client·jose)까지 전이 설치한다. `node:22-alpine`엔 `node` 사용자(uid 1000)가 내장.

- [ ] **Step 5: 게이트 통과 확인**

Run: `cd harness && ./run.sh node`
Expected: PASS — `report/RESULTS.md`의 node 행 checks 100%(✅), 성능 실측 채워짐.

- [ ] **Step 6: Commit**

```bash
git add harness/apps/node harness/docker-compose.yml
git commit -m "feat(harness): Node 샘플 앱(app-node) — Express 5(ESM) + SDK npm-pack tarball 소비"
```

---

### Task 3: Python 샘플 앱 (`app-python`)

**Files:**
- Create: `harness/apps/python/main.py`
- Create: `harness/apps/python/requirements.txt`
- Create: `harness/apps/python/Dockerfile`
- Modify: `harness/docker-compose.yml` (append `app-python` service)

**Interfaces:**
- Consumes(SDK): `AsyncKeycloakClient.create(KeycloakConfig(server_url,realm,client_id,client_secret))`; `await kc.auth.client_credentials_token()`→`TokenSet{token_type, expires_at(절대 epoch)}`; `await kc.auth.validate(token)`→`ValidatedToken{subject,audience(tuple),issuer,expires_at}`; `await kc.auth.introspect(token)`→`IntrospectionResult{active,username,client_id}`; `kc.admin`은 **lazy property**; `await kc.admin.users.create(dict)`→`id:str`; `await kc.admin.users.get(id)`→`dict`(throws `KeycloakNotFoundError`); `await kc.admin.users.search(username,0,20)`→`list[dict]`; `await kc.admin.users.delete(id)`. Exceptions: `KeycloakNotFoundError`, `KeycloakConflictError`, `TokenValidationError`(→401).
- Produces(harness): compose 서비스 `app-python`(호스트 8093).

- [ ] **Step 1: compose 서비스 추가**

`harness/docker-compose.yml` 끝에 append:

```yaml

  app-python:
    build: { context: .., dockerfile: harness/apps/python/Dockerfile }
    environment:
      KC_SERVER_URL: http://keycloak:8080
      KC_REALM: it-realm
      KC_CLIENT_ID: it-client
      KC_CLIENT_SECRET: it-secret
      APP_PORT: "8090"
    ports:
      - "8093:8090"
    depends_on:
      keycloak:
        condition: service_healthy
    profiles: ["apps"]
```

- [ ] **Step 2: `requirements.txt` 작성**

```
fastapi>=0.115
uvicorn[standard]>=0.30
```

- [ ] **Step 3: `main.py` 작성 (FastAPI, async, 8엔드포인트)**

```python
import os
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import (
    KeycloakConflictError,
    KeycloakNotFoundError,
    TokenValidationError,
)


def env(k: str, d: str) -> str:
    v = os.environ.get(k)
    return v if v else d


@asynccontextmanager
async def lifespan(app: FastAPI):
    config = KeycloakConfig(
        server_url=env("KC_SERVER_URL", "http://localhost:8080"),
        realm=env("KC_REALM", "it-realm"),
        client_id=env("KC_CLIENT_ID", "it-client"),
        client_secret=env("KC_CLIENT_SECRET", "it-secret"),
    )
    app.state.kc = AsyncKeycloakClient.create(config)  # 동기·무 I/O
    try:
        yield
    finally:
        await app.state.kc.aclose()  # 종료 시 소켓/FD 정리


app = FastAPI(lifespan=lifespan)


class TokenBody(BaseModel):
    token: str | None = None


class CreateBody(BaseModel):
    username: str | None = None
    email: str | None = None


def fail(code: int, msg: str) -> JSONResponse:
    return JSONResponse(status_code=code, content={"error": msg})


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/token")
async def token(request: Request) -> Any:
    kc = request.app.state.kc
    try:
        ts = await kc.auth.client_credentials_token()
        # Python TokenSet은 절대 expires_at만 보유 → expiresIn 파생
        expires_in = int(ts.expires_at - time.time()) if ts.expires_at else 0
        return {"tokenType": ts.token_type, "expiresIn": expires_in}
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.post("/validate")
async def validate(request: Request, body: TokenBody) -> Any:
    if not body.token:
        return fail(400, "token required")
    kc = request.app.state.kc
    try:
        vt = await kc.auth.validate(body.token)
        return {
            "subject": vt.subject,
            "audience": list(vt.audience),
            "issuer": vt.issuer,
            "expiresAt": int(vt.expires_at) if vt.expires_at else None,
        }
    except TokenValidationError as e:
        return fail(401, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.post("/introspect")
async def introspect(request: Request, body: TokenBody) -> Any:
    if not body.token:
        return fail(400, "token required")
    kc = request.app.state.kc
    try:
        ir = await kc.auth.introspect(body.token)
        return {"active": ir.active, "username": ir.username, "clientId": ir.client_id}
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.post("/admin/users")
async def admin_create(request: Request, body: CreateBody) -> Any:
    if not body.username:
        return fail(400, "username required")
    kc = request.app.state.kc
    try:
        uid = await kc.admin.users.create(
            {"username": body.username, "email": body.email, "enabled": True}
        )
        return JSONResponse(status_code=201, content={"id": uid})
    except KeycloakConflictError as e:
        return fail(409, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.get("/admin/users/{user_id}")
async def admin_get(request: Request, user_id: str) -> Any:
    kc = request.app.state.kc
    try:
        u = await kc.admin.users.get(user_id)
        return {"id": u.get("id"), "username": u.get("username")}
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.get("/admin/users")
async def admin_search(request: Request, username: str | None = None) -> Any:
    kc = request.app.state.kc
    try:
        us = await kc.admin.users.search(username, 0, 20)
        return [{"id": u.get("id"), "username": u.get("username")} for u in us]
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))


@app.delete("/admin/users/{user_id}")
async def admin_delete(request: Request, user_id: str) -> Response:
    kc = request.app.state.kc
    try:
        await kc.admin.users.delete(user_id)
        return Response(status_code=204)
    except KeycloakNotFoundError as e:
        return fail(404, str(e))
    except Exception as e:  # noqa: BLE001
        return fail(500, str(e))
```

> 주: `kc.admin`은 **property**(메서드 아님) — `kc.admin.users...`. admin 사용자 객체는 plain `dict` → `.get(...)`. `/token`·`/validate`의 시간 필드는 절대 epoch에서 파생/정수화.

- [ ] **Step 4: `Dockerfile` 작성**

```dockerfile
# build context = repo root
FROM python:3.12-slim
WORKDIR /app
# SDK 소스 로컬 설치(hatchling 휠 빌드) — 실제 배포 패키지 소비
COPY python/ /sdk/
RUN pip install --no-cache-dir /sdk
COPY harness/apps/python/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY harness/apps/python/main.py ./main.py
RUN useradd -u 10001 app
USER app
EXPOSE 8090
# uvicorn 단일 워커 + 비동기 이벤트 루프로 동시성(aio 미러 실측 쇼케이스)
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${APP_PORT:-8090}"]
```

> 주: `.dockerignore`가 `python/.venv`·`__pycache__`를 제외하므로 `COPY python/`는 `src/`·`pyproject.toml`만 실질 반입.

- [ ] **Step 5: 게이트 통과 확인**

Run: `cd harness && ./run.sh python`
Expected: PASS — `report/RESULTS.md`의 python 행 checks 100%(✅).

- [ ] **Step 6: Commit**

```bash
git add harness/apps/python harness/docker-compose.yml
git commit -m "feat(harness): Python 샘플 앱(app-python) — FastAPI+uvicorn 비동기(keycloak_sdk.aio) + 로컬 휠 소비"
```

---

### Task 4: Java 샘플 앱 (`app-java`)

**Files:**
- Create: `harness/apps/java/pom.xml`
- Create: `harness/apps/java/src/main/java/io/github/xzawed/harness/App.java`
- Create: `harness/apps/java/src/main/java/io/github/xzawed/harness/HarnessController.java`
- Create: `harness/apps/java/src/main/resources/application.properties`
- Create: `harness/apps/java/Dockerfile`
- Modify: `harness/docker-compose.yml` (append `app-java` service)

**Interfaces:**
- Consumes(SDK, sync): `KeycloakClient.create(KeycloakConfig)` (builder, `clientSecret(char[])`); `client.auth().clientCredentialsToken()`→`TokenSet{getTokenType(),getExpiresAt():Instant}`(**expiresIn 접근자 없음**); `client.auth().validate(token)`→`ValidatedToken{getSubject(),getAudience():List<String>,getIssuer(),getExpiresAt():Instant}`; `client.auth().introspect(token)`→`IntrospectionResult{isActive(),getUsername():Optional<String>,getClientId():Optional<String>}`; `client.admin().users().create(UserRepresentation)`→`String id`; `client.admin().users().get(id)`→`Optional<UserRepresentation>`(부재 시 throw); `client.admin().users().search(username,0,20)`→`List<UserRepresentation>`; `client.admin().users().delete(id)`. Exceptions(unchecked): `KeycloakNotFoundException`(404), `KeycloakConflictException`(409), `TokenValidationException`/`KeycloakAuthException`(→401).
- Produces(harness): compose 서비스 `app-java`(호스트 8094).

- [ ] **Step 1: compose 서비스 추가**

`harness/docker-compose.yml` 끝에 append:

```yaml

  app-java:
    build: { context: .., dockerfile: harness/apps/java/Dockerfile }
    environment:
      KC_SERVER_URL: http://keycloak:8080
      KC_REALM: it-realm
      KC_CLIENT_ID: it-client
      KC_CLIENT_SECRET: it-secret
      APP_PORT: "8090"
    ports:
      - "8094:8090"
    depends_on:
      keycloak:
        condition: service_healthy
    profiles: ["apps"]
```

- [ ] **Step 2: `pom.xml` 작성 (Spring Boot, aggregate SDK 의존)**

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.5</version> <!-- Java 21 지원 현행 3.3.x/3.4.x면 무엇이든 가능 -->
    <relativePath/>
  </parent>
  <groupId>io.github.xzawed.harness</groupId>
  <artifactId>harness-app-java</artifactId>
  <version>0.0.1</version>
  <properties>
    <java.version>21</java.version>
  </properties>
  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <!-- 로컬 .m2에 install된 aggregate(core+auth+admin 집약) -->
      <groupId>io.github.xzawed</groupId>
      <artifactId>keycloak-sdk</artifactId>
      <version>0.1.0-SNAPSHOT</version>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

- [ ] **Step 3: `application.properties` 작성**

Path: `harness/apps/java/src/main/resources/application.properties`

```properties
server.port=${APP_PORT:8090}
spring.main.banner-mode=off
```

- [ ] **Step 4: `App.java` 작성 (부트스트랩 + SDK 빈)**

Path: `harness/apps/java/src/main/java/io/github/xzawed/harness/App.java`

```java
package io.github.xzawed.harness;

import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;

@SpringBootApplication
public class App {
    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }

    private static String env(String k, String d) {
        String v = System.getenv(k);
        return (v != null && !v.isEmpty()) ? v : d;
    }

    // 단일 장수명 KeycloakClient(스레드-안전, admin lazy). 종료 시 close()로 커넥션 풀 정리.
    @Bean(destroyMethod = "close")
    KeycloakClient keycloakClient() {
        KeycloakConfig config = KeycloakConfig.builder()
            .serverUrl(env("KC_SERVER_URL", "http://localhost:8080"))
            .realm(env("KC_REALM", "it-realm"))
            .clientId(env("KC_CLIENT_ID", "it-client"))
            .clientSecret(env("KC_CLIENT_SECRET", "it-secret").toCharArray())
            .scopes("openid")
            .build();
        return KeycloakClient.create(config);
    }
}
```

- [ ] **Step 5: `HarnessController.java` 작성 (8엔드포인트)**

Path: `harness/apps/java/src/main/java/io/github/xzawed/harness/HarnessController.java`

```java
package io.github.xzawed.harness;

import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.auth.IntrospectionResult;
import io.github.xzawed.keycloak.auth.ValidatedToken;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakConflictException;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.keycloak.representations.idm.UserRepresentation;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HarnessController {
    private final KeycloakClient kc;

    public HarnessController(KeycloakClient kc) {
        this.kc = kc;
    }

    // Map.of는 null 값을 금지하므로 null 허용 맵을 만든다.
    private static ResponseEntity<Object> fail(int code, String msg) {
        Map<String, Object> m = new HashMap<>();
        m.put("error", msg);
        return ResponseEntity.status(code).body(m);
    }

    @GetMapping("/healthz")
    public Map<String, String> healthz() {
        return Map.of("status", "ok");
    }

    @PostMapping("/token")
    public ResponseEntity<Object> token() {
        try {
            TokenSet ts = kc.auth().clientCredentialsToken();
            // Java TokenSet은 getExpiresAt():Instant만 → expiresIn 파생
            long expiresIn = Math.max(0, ts.getExpiresAt().getEpochSecond() - Instant.now().getEpochSecond());
            Map<String, Object> m = new HashMap<>();
            m.put("tokenType", ts.getTokenType());
            m.put("expiresIn", expiresIn);
            return ResponseEntity.ok(m);
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @PostMapping("/validate")
    public ResponseEntity<Object> validate(@RequestBody Map<String, String> body) {
        String tok = body.get("token");
        if (tok == null || tok.isEmpty()) {
            return fail(400, "token required");
        }
        try {
            ValidatedToken vt = kc.auth().validate(tok);
            Map<String, Object> m = new HashMap<>();
            m.put("subject", vt.getSubject());
            m.put("audience", vt.getAudience());
            m.put("issuer", vt.getIssuer());
            m.put("expiresAt", vt.getExpiresAt().getEpochSecond());
            return ResponseEntity.ok(m);
        } catch (TokenValidationException | KeycloakAuthException e) {
            return fail(401, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @PostMapping("/introspect")
    public ResponseEntity<Object> introspect(@RequestBody Map<String, String> body) {
        String tok = body.get("token");
        if (tok == null || tok.isEmpty()) {
            return fail(400, "token required");
        }
        try {
            IntrospectionResult ir = kc.auth().introspect(tok);
            Map<String, Object> m = new HashMap<>();
            m.put("active", ir.isActive());
            m.put("username", ir.getUsername().orElse(null));
            m.put("clientId", ir.getClientId().orElse(null));
            return ResponseEntity.ok(m);
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @PostMapping("/admin/users")
    public ResponseEntity<Object> createUser(@RequestBody Map<String, String> body) {
        String username = body.get("username");
        if (username == null || username.isEmpty()) {
            return fail(400, "username required");
        }
        try {
            UserRepresentation rep = new UserRepresentation();
            rep.setUsername(username);
            rep.setEmail(body.get("email"));
            rep.setEnabled(true);
            String id = kc.admin().users().create(rep);
            return ResponseEntity.status(201).body(Map.of("id", id));
        } catch (KeycloakConflictException e) {
            return fail(409, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @GetMapping("/admin/users/{id}")
    public ResponseEntity<Object> getUser(@PathVariable String id) {
        try {
            UserRepresentation u = kc.admin().users().get(id).orElseThrow();
            return ResponseEntity.ok(Map.of("id", u.getId(), "username", u.getUsername()));
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @GetMapping("/admin/users")
    public ResponseEntity<Object> searchUsers(@RequestParam(required = false) String username) {
        try {
            List<UserRepresentation> us = kc.admin().users().search(username, 0, 20);
            List<Map<String, String>> out = us.stream()
                .map(u -> Map.of("id", u.getId(), "username", u.getUsername()))
                .toList();
            return ResponseEntity.ok(out);
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @DeleteMapping("/admin/users/{id}")
    public ResponseEntity<Object> deleteUser(@PathVariable String id) {
        try {
            kc.admin().users().delete(id);
            return ResponseEntity.noContent().build();
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }
}
```

> 주: 모든 SDK 예외는 unchecked. `users().get(id)`는 `Optional`이지만 부재 시 `KeycloakNotFoundException`을 던진다(`.orElseThrow()`는 방어적 언랩). TokenSet엔 expiresIn 접근자가 없어 Instant에서 파생.

- [ ] **Step 6: `Dockerfile` 작성**

```dockerfile
# build context = repo root
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
# 1) SDK 리액터를 로컬 .m2에 설치(앱이 io.github.xzawed:keycloak-sdk 해석) — 테스트/IT 스킵
COPY java/ ./java/
RUN mvn -f java/pom.xml -q -DskipTests -DskipITs install
# 2) 하네스 앱 빌드(Spring Boot fat jar)
COPY harness/apps/java/ ./app/
RUN mvn -f app/pom.xml -q -DskipTests package

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN useradd -u 10001 app
COPY --from=build /build/app/target/*.jar ./app.jar
USER app
EXPOSE 8090
ENTRYPOINT ["java", "-jar", "app.jar"]
```

> 주(스펙의 명시 트레이드오프): 가장 무거운 빌드 — 풀 Maven 리액터 install + Spring Boot fat jar. `.dockerignore`가 `java/**/target`을 제외해 stale 산출물 반입 방지. Spring Boot 콜드 스타트(~10-20s)는 `run.sh` healthz 90초 대기가 커버.

- [ ] **Step 7: 게이트 통과 확인**

Run: `cd harness && ./run.sh java`
Expected: PASS — `report/RESULTS.md`의 java 행 checks 100%(✅). (빌드가 길어 첫 실행은 수 분.)

- [ ] **Step 8: Commit**

```bash
git add harness/apps/java harness/docker-compose.yml
git commit -m "feat(harness): Java 샘플 앱(app-java) — Spring Boot 3(MVC) + aggregate SDK(mvn install) 소비"
```

---

### Task 5: 5언어 통합 · CI(안 A) · 문서 최신화

**Files:**
- Modify: `.github/workflows/harness.yml`
- Modify: `harness/README.md`
- Modify: `README.md` (루트)
- Modify: `docs/roadmap/language-support.md`
- Modify: `CLAUDE.md` (하네스 언급이 있으면)
- Modify: 자동 메모리(`MEMORY.md` + 관련 파일)

- [ ] **Step 1: 5언어 통합 실행 확인(최종 오라클)**

Run: `cd harness && ./run.sh go dotnet node python java`
Expected: PASS(rc=0) — `report/RESULTS.md`에 **5행**(go/dotnet/node/python/java) 모두 checks 100%(✅), 성능 비교표(validate p95·admin CRUD p95·RPS·오류율) 채워짐. 하나라도 ❌면 그 언어 태스크로 돌아가 수정.

- [ ] **Step 2: `harness.yml` 안 A로 갱신**

전체 파일을 다음으로 교체:

```yaml
name: harness
on:
  push:
    paths: ['harness/**', 'go/**', '.github/workflows/harness.yml']
  pull_request:
    paths: ['harness/**', 'go/**', '.github/workflows/harness.yml']
  workflow_dispatch:
  schedule:
    - cron: '0 3 * * *'   # 매일 03:00 UTC 야간 5언어 비교
permissions:
  contents: read
jobs:
  mvp-go:
    # 빠른 PR 게이트(Go 스모크) — push/PR 트리거에만
    if: github.event_name == 'push' || github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - name: 하네스 실행(Go MVP)
        run: cd harness && ./run.sh go
      - name: 결과 업로드
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: harness-results-go
          path: harness/report/RESULTS.md

  all-langs:
    # 5언어 전체 비교 — 수동(workflow_dispatch) + 야간(schedule)에만
    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'
    runs-on: ubuntu-latest
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - name: 하네스 실행(5개 언어 비교)
        run: cd harness && ./run.sh go dotnet node python java
      - name: 결과 업로드
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: harness-results-all
          path: harness/report/RESULTS.md
```

> 주: `workflow_dispatch`/`schedule`는 paths 필터 무관하게 발동한다. `if`로 각 잡을 트리거별로 게이트 — push/PR엔 mvp-go만, dispatch/schedule엔 all-langs만.

- [ ] **Step 3: `harness/README.md` 갱신**

구성 트리를 5개 앱으로 확장하고, 사용법을 5언어로, 프레임워크-별 선택과 오버헤드 주의를 명시. 최소 반영 지점:
- `apps/` 트리에 `dotnet/`(ASP.NET Core), `node/`(Express 5), `python/`(FastAPI), `java/`(Spring Boot) 추가
- 사용법에 `./run.sh go dotnet node python java` 예시
- "성능은 관용 프레임워크 포함 실측(SDK-in-idiomatic-app)이며 pure SDK 비용이 아니다" 한 줄
- 호스트 포트 표(go 8090 / dotnet 8091 / node 8092 / python 8093 / java 8094)

- [ ] **Step 4: 루트 `README.md` 갱신**

하네스 현황 문장을 "MVP(Go)" → "5개 언어(Go/C#/Node/Python/Java) 샘플 앱 완료, `./run.sh`로 언어간 실측 비교"로 갱신.

- [ ] **Step 5: `docs/roadmap/language-support.md` 갱신**

마지막 문단의 "MVP(Go 샘플 앱)는 완료·CI GREEN, C#/Node/Python/Java 샘플 앱 확장은 계획 단계다." →
"5개 언어(Go/C#/Node/Python/Java) 샘플 앱 완료 — `./run.sh go dotnet node python java`로 기능 정확성(checks==1.00) 강제 + 성능 실측 비교. CI(harness.yml)는 PR에 Go 스모크, 야간/수동에 5언어 전체(안 A)."로 교체.

- [ ] **Step 6: `CLAUDE.md` 갱신**

하네스 관련 언급이 있으면 5언어 완료로 갱신. 없으면 "현재 상태" 또는 아키텍처 섹션에 하네스 5언어 확장 완료를 1~2문장 추가(앱 위치·`run.sh` 명령·프레임워크 매핑·CI 안 A). 언어별 툴체인 섹션 관례를 따른다.

- [ ] **Step 7: 자동 메모리 갱신**

`MEMORY.md` 인덱스 라인과 `node-sdk-build-in-progress.md`(또는 신규 파일)를 갱신 — "하네스 5언어 앱 완료(PR #NN)", 다음 로드맵은 PHP(rank 4) depth-first로 정리.

- [ ] **Step 8: 문서·CI 커밋**

```bash
git add .github/workflows/harness.yml harness/README.md README.md docs/roadmap/language-support.md CLAUDE.md
git commit -m "docs+ci(harness): 5언어 확장 문서 최신화 + harness.yml 안 A(Go PR게이트 + 야간/수동 5언어)"
```

- [ ] **Step 9: 최종 검증 및 PR 준비**

Run: `cd harness && ./run.sh go dotnet node python java && echo OK`
Expected: `report/RESULTS.md` 5행 전부 ✅ + `OK`. 이후 `finishing-a-development-branch` 스킬로 PR 생성.

---

## Self-Review (작성자 체크)

**Spec coverage(스펙 §별 대응):**
- §2.2 신규(4 앱 + compose 4 서비스) → Task 1~4. ✅
- §2.1 재사용(driver/report/run.sh/contract 무수정) → Global Constraints에 명시, 어떤 태스크도 수정 안 함. ✅
- §4.2 언어별(프레임워크·소비·좌표) → Task 1~4의 Dockerfile/매니페스트. ✅
- §5 compose(내부 8090/호스트 8091~8094) → 각 Task Step 1. ✅
- §6 CI 안 A → Task 5 Step 2. ✅
- §7 검증(checks==1.00 오라클) → 각 Task의 `./run.sh <lang>` + Task 5 5언어. ✅
- §2.3 문서 → Task 5 Step 3~7. ✅
- §8 리스크(Java 무거움·Node dist·프레임워크 오버헤드·issuer 일치·realm 파일명) → Global Constraints + Task 주석. ✅

**Placeholder scan:** 앱 소스·Dockerfile·compose·CI 전부 실제 코드. Spring Boot 버전 `3.3.5`는 구체값(현행 3.3.x/3.4.x면 대체 가능하다는 주석). 문서 태스크(Step 3~7)는 "무엇을 어디로 바꾸는지"를 구체 지정. ✅

**Type consistency:** 각 언어 응답 필드가 계약과 일치 — `/token`{tokenType,expiresIn}, `/validate`{subject,audience,issuer,expiresAt}, `/introspect`{active,username,clientId}, admin {id}/{id,username}. Python/Java의 expiresIn·expiresAt는 절대시각에서 파생(정수화) 명시. 예외 타입은 워크플로우 추출 실측값 사용(C# `KeycloakNotFoundException`, Node `KeycloakNotFoundError`, Python `KeycloakNotFoundError`, Java `KeycloakNotFoundException`). ✅
