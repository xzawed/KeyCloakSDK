using System.Text.Json;
using System.Text.Json.Serialization;
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

// ROPC(Resource Owner Password Credentials)는 SDK 표면에 없다(SDK 표면 불변 원칙 — 8개 하네스 앱 동일 패턴,
// harness/apps/ruby/app.rb 참고). 여기서는 별도 HttpClient로 Keycloak 토큰 엔드포인트에 직접 POST한다.
// top-level statements의 암시 Main 메서드 본문에는 진짜 `static` 지역변수가 존재하지 않으므로(로컬 함수만
// static 가능), 프로세스 수명 내내 살아있는 캡처 지역변수로 동일 효과를 낸다(기존 kc/config와 동일 패턴).
var ropcHttp = new HttpClient();
string? lastRefreshToken = null;

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

app.MapPost("/token/password", async (PasswordBody body, CancellationToken ct) =>
{
    try
    {
        var form = new Dictionary<string, string>
        {
            ["grant_type"] = "password",
            ["client_id"] = config.ClientId,
            ["client_secret"] = config.ClientSecret ?? "",
            ["username"] = body.Username,
            ["password"] = body.Password,
        };
        var url = $"{config.ServerUrl.TrimEnd('/')}/realms/{config.Realm}/protocol/openid-connect/token";
        var resp = await ropcHttp.PostAsync(url, new FormUrlEncodedContent(form), ct);
        var json = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
            return Fail(401, $"ROPC(password) grant failed: HTTP {(int)resp.StatusCode}");
        var tok = JsonSerializer.Deserialize<PasswordTokenResponse>(json);
        lastRefreshToken = tok?.RefreshToken;
        return Results.Json(new
        {
            tokenType = tok?.TokenType,
            expiresIn = tok?.ExpiresIn,
            hasRefresh = !string.IsNullOrEmpty(tok?.RefreshToken),
        });
    }
    catch (Exception e) { return Fail(401, e.Message); }
});

app.MapPost("/refresh", async (CancellationToken ct) =>
{
    try
    {
        if (string.IsNullOrEmpty(lastRefreshToken)) return Fail(401, "no refresh token available");
        var ts = await kc.Auth.RefreshAsync(lastRefreshToken!, ct);
        if (!string.IsNullOrEmpty(ts.RefreshToken)) lastRefreshToken = ts.RefreshToken;
        return Results.Json(new { tokenType = ts.TokenType, expiresIn = ts.ExpiresIn });
    }
    catch (Exception e) { return Fail(401, e.Message); }
});

app.MapPost("/logout", async (CancellationToken ct) =>
{
    try
    {
        await kc.Auth.LogoutAsync(lastRefreshToken!, ct);
        return Results.StatusCode(204);
    }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapGet("/authz-url", (string? redirect_uri) =>
{
    try
    {
        var ar = kc.Auth.CreateAuthorizationRequest(string.IsNullOrEmpty(redirect_uri) ? "http://x/cb" : redirect_uri);
        return Results.Json(new { url = ar.Url, state = ar.State });
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

// ---- admin: clients ----
app.MapPost("/admin/clients", async (ClientBody body, CancellationToken ct) =>
{
    if (string.IsNullOrEmpty(body?.ClientId)) return Fail(400, "clientId required");
    try
    {
        var admin = await kc.AdminAsync(ct);
        var id = await admin.Clients.CreateAsync(new ClientRepresentation { ClientId = body.ClientId, Enabled = true }, ct);
        return Results.Json(new { id }, statusCode: 201);
    }
    catch (KeycloakConflictException e) { return Fail(409, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapGet("/admin/clients/{id}", async (string id, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        var c = await admin.Clients.GetAsync(id, ct);
        return Results.Json(new { id = c.Id, clientId = c.ClientId });
    }
    catch (KeycloakNotFoundException e) { return Fail(404, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapDelete("/admin/clients/{id}", async (string id, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        await admin.Clients.DeleteAsync(id, ct);
        return Results.StatusCode(204);
    }
    catch (KeycloakNotFoundException e) { return Fail(404, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

// ---- admin: roles (realm role — client role 아님·name 키) ----
app.MapPost("/admin/roles", async (RoleBody body, CancellationToken ct) =>
{
    if (string.IsNullOrEmpty(body?.Name)) return Fail(400, "name required");
    try
    {
        var admin = await kc.AdminAsync(ct);
        await admin.Roles.CreateAsync(new RoleRepresentation { Name = body.Name }, ct);
        return Results.Json(new { name = body.Name }, statusCode: 201);
    }
    catch (KeycloakConflictException e) { return Fail(409, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapGet("/admin/roles/{name}", async (string name, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        var r = await admin.Roles.GetAsync(name, ct);
        return Results.Json(new { name = r.Name });
    }
    catch (KeycloakNotFoundException e) { return Fail(404, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapDelete("/admin/roles/{name}", async (string name, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        await admin.Roles.DeleteAsync(name, ct);
        return Results.StatusCode(204);
    }
    catch (KeycloakNotFoundException e) { return Fail(404, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

// ---- admin: groups ----
app.MapPost("/admin/groups", async (GroupBody body, CancellationToken ct) =>
{
    if (string.IsNullOrEmpty(body?.Name)) return Fail(400, "name required");
    try
    {
        var admin = await kc.AdminAsync(ct);
        var id = await admin.Groups.CreateAsync(new GroupRepresentation { Name = body.Name }, ct);
        return Results.Json(new { id }, statusCode: 201);
    }
    catch (KeycloakConflictException e) { return Fail(409, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapGet("/admin/groups/{id}", async (string id, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        var g = await admin.Groups.GetAsync(id, ct);
        return Results.Json(new { id = g.Id, name = g.Name });
    }
    catch (KeycloakNotFoundException e) { return Fail(404, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.MapDelete("/admin/groups/{id}", async (string id, CancellationToken ct) =>
{
    try
    {
        var admin = await kc.AdminAsync(ct);
        await admin.Groups.DeleteAsync(id, ct);
        return Results.StatusCode(204);
    }
    catch (KeycloakNotFoundException e) { return Fail(404, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

// ---- admin: realms (master 전용 — 하네스는 realm SA라 항상 403, CONTRACT.md 참고) ----
app.MapPost("/admin/realms", async (RealmBody body, CancellationToken ct) =>
{
    if (string.IsNullOrEmpty(body?.Realm)) return Fail(400, "realm required");
    try
    {
        var admin = await kc.AdminAsync(ct);
        await admin.Realms.CreateAsync(new RealmRepresentation { Realm = body.Realm, Enabled = true }, ct);
        return Results.Json(new { realm = body.Realm }, statusCode: 201);
    }
    catch (KeycloakForbiddenException e) { return Fail(403, e.Message); }
    catch (Exception e) { return Fail(500, e.Message); }
});

app.Run($"http://0.0.0.0:{Env("APP_PORT", "8090")}");

record TokenBody(string Token);
record CreateBody(string Username, string? Email);
record PasswordBody(string Username, string Password);
record ClientBody(string ClientId);
record RoleBody(string Name);
record GroupBody(string Name);
record RealmBody(string Realm);

record PasswordTokenResponse(
    [property: JsonPropertyName("token_type")] string? TokenType,
    [property: JsonPropertyName("expires_in")] int ExpiresIn,
    [property: JsonPropertyName("refresh_token")] string? RefreshToken);
