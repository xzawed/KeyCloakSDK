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
