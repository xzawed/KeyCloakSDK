using System.Text;
using System.Text.Json;
using Keycloak.AuthServices.Sdk.Admin.Models;
using Xunit;
using Xunit.Abstractions;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// A 3xx without <c>Location</c> is never an admin facade call's success — registry <c>go-admin-3xx-read-as-success</c>, its
/// class rescanned in .NET. There Go returned zero values for 24 of its 25 facade calls and PHP returned a User on a 302; .NET's
/// 3xx was measured only as an error-body row of <c>AdminResponseBodyTests</c> (300, a body of spaces, five calls).
/// </summary>
/// <remarks>
/// <para>The contract: each of the 25 facade calls — users, clients, realms, roles and groups × create, get, list/search,
/// update, delete, the 25 the integration admin-surface suite runs — answered 300, 302 (no <c>Location</c>) or 399 with a JSON
/// body shaped like that call's success body (an array for a list or search, an object otherwise) fails with
/// <see cref="KeycloakAdminException"/> carrying that status. A value, null, an empty list or an id is a wrong cell, and so is
/// any other exception — a transport or decode error would pass a test that only asked for "an error".</para>
/// <para>Both admin paths are in the table: the typed client (users, groups, realm get) and raw REST (clients, roles, the rest
/// of realms). The token comes the default way — <see cref="KeycloakClient.AdminAsync"/>'s client-credentials provider, from
/// the server's token endpoint answered normally — and each cell must have sent exactly one admin request. The premise (the
/// server's 3xx carries no <c>Location</c>) is measured once per status with a client that does not follow redirects.</para>
/// <para>Two more cases run the same 25 calls. The error body's shape — registry <c>python-admin-list-error-array-body</c>, its
/// class rescanned (there Python's five list calls raised a transport error without a status on an array body): 404 and 500
/// with a JSON body that is not an object (<c>[]</c>, <c>"boom"</c>, <c>42</c>, <c>true</c>, <c>null</c>, 100,000 <c>[</c>
/// then 100,000 <c>]</c>) or with the object control <c>{"error":"x"}</c> fail with that status's admin error —
/// <see cref="KeycloakNotFoundException"/> for 404, <see cref="KeycloakAdminException"/> itself for 500. A followable redirect —
/// registry <c>admin-followable-redirect-class-divergent</c> (Go raised a transport error there): a 302 whose <c>Location</c>
/// points at <c>/redirected-target</c>, which answers 200 with the call's success body, is not followed — each call fails with
/// <see cref="KeycloakAdminException"/> itself carrying 302, and the target gets no request. Both cases require exactly one
/// admin request per cell; their premises (the body goes out byte for byte as <c>application/json</c>; the 302 carries that
/// <c>Location</c> and the target answers 200 with the success body) are measured with the same non-following client.
/// Measured 2026-11-14 on main ad16554d: error body 300/300 (control 50/50), redirect 25/25 — already right.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class AdminRedirectStatusTests
{
    private const string TokenPath = "/realms/r/protocol/openid-connect/token";

    // Where the followable 302 points — it answers 200 with the call's success body.
    private const string TargetPath = "/redirected-target";

    private static readonly int[] Statuses = { 300, 302, 399 };

    private static readonly int[] ErrorStatuses = { 404, 500 };

    // Success bodies: a resource-shaped object (get, create, update, delete) and an array of one (list, search).
    private const string User = """{"id":"u1","username":"alice","enabled":true}""";
    private const string Client = """{"id":"c1","clientId":"app","enabled":true}""";
    private const string Realm = """{"id":"r","realm":"r","enabled":true}""";
    private const string Role = """{"id":"role-1","name":"reader","composite":false}""";
    private const string Group = """{"id":"g1","name":"staff","path":"/staff"}""";

    /// <summary>The 25 facade calls: name, the call's success body, and the call — its value, or null for a void call.</summary>
    private static readonly (string Name, string Body, Func<AdminClient, Task<object?>> Run)[] Ops =
    {
        ("typed Users.CreateAsync", User, async a => await a.Users.CreateAsync(new UserRepresentation { Username = "alice" })),
        ("typed Users.GetAsync", User, async a => await a.Users.GetAsync("u1")),
        ("typed Users.SearchAsync", $"[{User}]", async a => await a.Users.SearchAsync("alice")),
        ("typed Users.UpdateAsync", User, async a => { await a.Users.UpdateAsync("u1", new UserRepresentation { FirstName = "Alice" }); return null; }),
        ("typed Users.DeleteAsync", User, async a => { await a.Users.DeleteAsync("u1"); return null; }),
        ("raw Clients.CreateAsync", Client, async a => await a.Clients.CreateAsync(new ClientRepresentation { ClientId = "app" })),
        ("raw Clients.GetAsync", Client, async a => await a.Clients.GetAsync("c1")),
        ("raw Clients.FindByClientIdAsync", $"[{Client}]", async a => await a.Clients.FindByClientIdAsync("app")),
        ("raw Clients.UpdateAsync", Client, async a => { await a.Clients.UpdateAsync("c1", new ClientRepresentation { Enabled = false }); return null; }),
        ("raw Clients.DeleteAsync", Client, async a => { await a.Clients.DeleteAsync("c1"); return null; }),
        ("raw Realms.CreateAsync", Realm, async a => { await a.Realms.CreateAsync(new RealmRepresentation { Realm = "r2" }); return null; }),
        ("typed Realms.GetAsync", Realm, async a => await a.Realms.GetAsync("r")),
        ("raw Realms.ListAsync", $"[{Realm}]", async a => await a.Realms.ListAsync()),
        ("raw Realms.UpdateAsync", Realm, async a => { await a.Realms.UpdateAsync("r", new RealmRepresentation { Enabled = true }); return null; }),
        ("raw Realms.DeleteAsync", Realm, async a => { await a.Realms.DeleteAsync("r2"); return null; }),
        ("raw Roles.CreateAsync", Role, async a => { await a.Roles.CreateAsync(new RoleRepresentation { Name = "reader" }); return null; }),
        ("raw Roles.GetAsync", Role, async a => await a.Roles.GetAsync("reader")),
        ("raw Roles.ListAsync", $"[{Role}]", async a => await a.Roles.ListAsync()),
        ("raw Roles.UpdateAsync", Role, async a => { await a.Roles.UpdateAsync("reader", new RoleRepresentation { Description = "d" }); return null; }),
        ("raw Roles.DeleteAsync", Role, async a => { await a.Roles.DeleteAsync("reader"); return null; }),
        ("typed Groups.CreateAsync", Group, async a => await a.Groups.CreateAsync(new GroupRepresentation { Name = "staff" })),
        ("typed Groups.GetAsync", Group, async a => await a.Groups.GetAsync("g1")),
        ("typed Groups.ListAsync", $"[{Group}]", async a => await a.Groups.ListAsync()),
        ("typed Groups.UpdateAsync", Group, async a => { await a.Groups.UpdateAsync("g1", new GroupRepresentation { Name = "staff2" }); return null; }),
        ("typed Groups.DeleteAsync", Group, async a => { await a.Groups.DeleteAsync("g1"); return null; }),
    };

    /// <summary>Error bodies: the object control, then six JSON values that are not an object — the last 100,000 <c>[</c> then
    /// 100,000 <c>]</c> (200,000 bytes).</summary>
    private static readonly (string Label, string Body)[] ErrorBodies =
    {
        ("""{"error":"x"}""", """{"error":"x"}"""),
        ("[]", "[]"),
        ("\"boom\"", "\"boom\""),
        ("42", "42"),
        ("true", "true"),
        ("null", "null"),
        ("deep", new string('[', 100_000) + new string(']', 100_000)),
    };

    private readonly ITestOutputHelper _out;

    public AdminRedirectStatusTests(ITestOutputHelper output) => _out = output;

    /// <summary>What the server answers an admin request with — set per cell, read on the server's own threads.</summary>
    private sealed class Plan
    {
        private Answer _answer = new(200, "{}");

        public Answer Answer
        {
            get => Volatile.Read(ref _answer);
            set => Volatile.Write(ref _answer, value);
        }
    }

    /// <summary>An admin answer. <c>Location</c>, when set, goes out as its <c>Location</c> header, and the redirect target
    /// answers 200 with <c>Target</c> (only the error-body and redirect cases' <see cref="Route"/> reads those two).</summary>
    private sealed record Answer(int Status, string Body, string? Location = null, string Target = "{}");

    private static int AdminRequests(KeepAliveIdp idp) => idp.Seen.Count(r => r.Path.StartsWith("/admin/", StringComparison.Ordinal));

    private static int TargetRequests(KeepAliveIdp idp) => idp.Seen.Count(r => r.Path == TargetPath);

    private static string Describe(object? value, Exception? error) => error switch
    {
        null => $"returned {(value is null ? "null (void)" : JsonSerializer.Serialize(value))}",
        KeycloakAdminException admin => $"{admin.GetType().Name}({admin.StatusCode}): {admin.Message}",
        _ => $"{error.GetType().Name}: {error.Message}",
    };

    /// <summary><see cref="Describe"/> cut to 300 characters — the admin error's message carries the server's error body for
    /// most calls, 200,000 characters on the deep row (measured 2026-11-14).</summary>
    private static string Brief(object? value, Exception? error)
    {
        var full = Describe(value, error);
        return full.Length <= 300 ? full : $"{full[..300]}… ({full.Length} chars)";
    }

    /// <summary>The admin error this SDK raises for <paramref name="status"/>, carrying it: <see cref="KeycloakNotFoundException"/>
    /// for 404 and <see cref="KeycloakAdminException"/> itself — no subclass — for any other status.</summary>
    private static bool IsAdminErrorOf(Exception? error, int status) =>
        error is KeycloakAdminException admin && admin.StatusCode == status
        && admin.GetType() == (status == 404 ? typeof(KeycloakNotFoundException) : typeof(KeycloakAdminException));

    /// <summary>The server of the error-body and redirect cases: the token endpoint answered normally, an admin request with the
    /// plan's answer (and its <c>Location</c>, when it has one), the redirect target with 200 and the plan's target body.</summary>
    private static KeepAliveIdp.Resp Route(KeepAliveIdp.Req req, Plan plan)
    {
        if (req.Path == TokenPath)
            return KeepAliveIdp.Resp.Json("""{"access_token":"at","token_type":"Bearer","expires_in":300}""");
        var answer = plan.Answer;
        if (req.Path == TargetPath)
            return KeepAliveIdp.Resp.Json(answer.Target);
        return new KeepAliveIdp.Resp(Encoding.UTF8.GetBytes(answer.Body), 0, Chunked: false, Status: answer.Status,
            ExtraHeaders: answer.Location is { } location ? $"Location: {location}\r\n" : "");
    }

    [Fact]
    public async Task A_location_less_3xx_fails_every_facade_call_with_the_admin_error_and_its_status()
    {
        var plan = new Plan();
        using var idp = new KeepAliveIdp(req => req.Path == TokenPath
            ? KeepAliveIdp.Resp.Json("""{"access_token":"at","token_type":"Bearer","expires_in":300}""")
            : new KeepAliveIdp.Resp(Encoding.UTF8.GetBytes(plan.Answer.Body), 0, Chunked: false, Status: plan.Answer.Status));
        await using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s" });
        var admin = await kc.AdminAsync();
        using var direct = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false });

        var wrong = new List<string>();
        foreach (var status in Statuses)
        {
            // The premise: the server's answer at this status carries no Location.
            plan.Answer = new Answer(status, "{}");
            using (var probe = await direct.GetAsync(new Uri($"{idp.Url}/admin/realms/r/users/u1")))
            {
                if ((int)probe.StatusCode != status || probe.Headers.Location is not null)
                    wrong.Add($"{status} premise: the server answered {(int)probe.StatusCode} with Location {probe.Headers.Location}");
            }

            var passed = 0;
            foreach (var (name, body, run) in Ops)
            {
                plan.Answer = new Answer(status, body);
                var before = AdminRequests(idp);
                object? value = null;
                var error = await Record.ExceptionAsync(async () => value = await run(admin));
                var sent = AdminRequests(idp) - before;
                var got = Describe(value, error);
                _out.WriteLine($"[3xx] {status} {name}: {got} · admin requests {sent}");
                if (error is KeycloakAdminException { StatusCode: var code } && code == status && sent == 1)
                    passed++;
                else
                    wrong.Add($"{status} {name}: {got} · admin requests {sent}");
            }
            _out.WriteLine($"[3xx] {status}: {passed}/{Ops.Length} cells pass");
        }
        _out.WriteLine($"[3xx] token endpoint requests: {idp.Seen.Count(r => r.Path == TokenPath)}");

        Assert.True(wrong.Count == 0, $"{wrong.Count} cell(s) wrong:\n{string.Join('\n', wrong)}");
    }

    [Fact]
    public async Task A_non_object_JSON_error_body_fails_every_facade_call_with_that_status_admin_error()
    {
        var plan = new Plan();
        using var idp = new KeepAliveIdp(req => Route(req, plan));
        await using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s" });
        var admin = await kc.AdminAsync();
        using var direct = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false });

        var wrong = new List<string>();
        foreach (var status in ErrorStatuses)
        {
            foreach (var (label, body) in ErrorBodies)
            {
                // The premise: the server answers this status with exactly this body, as application/json.
                plan.Answer = new Answer(status, body);
                using (var probe = await direct.GetAsync(new Uri($"{idp.Url}/admin/realms/r/users/u1")))
                {
                    var sentBody = await probe.Content.ReadAsStringAsync();
                    if ((int)probe.StatusCode != status || probe.Content.Headers.ContentType?.MediaType != "application/json" || sentBody != body)
                        wrong.Add($"{status} {label} premise: the server answered {(int)probe.StatusCode} · {probe.Content.Headers.ContentType} · {sentBody.Length} chars");
                }

                var passed = 0;
                foreach (var (name, _, run) in Ops)
                {
                    var before = AdminRequests(idp);
                    object? value = null;
                    var error = await Record.ExceptionAsync(async () => value = await run(admin));
                    var sent = AdminRequests(idp) - before;
                    var got = Brief(value, error);
                    _out.WriteLine($"[error body] {status} {label} {name}: {got} · admin requests {sent}");
                    if (IsAdminErrorOf(error, status) && sent == 1)
                        passed++;
                    else
                        wrong.Add($"{status} {label} {name}: {got} · admin requests {sent}");
                }
                _out.WriteLine($"[error body] {status} {label}: {passed}/{Ops.Length} cells pass");
            }
        }

        Assert.True(wrong.Count == 0, $"{wrong.Count} cell(s) wrong:\n{string.Join('\n', wrong)}");
    }

    [Fact]
    public async Task A_followable_redirect_is_not_followed_and_fails_every_facade_call_with_302()
    {
        var plan = new Plan();
        using var idp = new KeepAliveIdp(req => Route(req, plan));
        await using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s" });
        var admin = await kc.AdminAsync();
        using var direct = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false });
        var location = $"{idp.Url}{TargetPath}";

        var wrong = new List<string>();
        // The premise: the 302 carries that Location, and the target answers 200 with the success body — following it would succeed.
        plan.Answer = new Answer(302, "{}", location, User);
        using (var probe = await direct.GetAsync(new Uri($"{idp.Url}/admin/realms/r/users/u1")))
        {
            if ((int)probe.StatusCode != 302 || probe.Headers.Location?.OriginalString != location)
                wrong.Add($"premise: the server answered {(int)probe.StatusCode} with Location {probe.Headers.Location}");
        }
        using (var probe = await direct.GetAsync(new Uri(location)))
        {
            var targetBody = await probe.Content.ReadAsStringAsync();
            if ((int)probe.StatusCode != 200 || targetBody != User)
                wrong.Add($"premise: the target answered {(int)probe.StatusCode} with {targetBody}");
        }

        var passed = 0;
        foreach (var (name, body, run) in Ops)
        {
            plan.Answer = new Answer(302, "{}", location, body);
            var before = AdminRequests(idp);
            var targetBefore = TargetRequests(idp);
            object? value = null;
            var error = await Record.ExceptionAsync(async () => value = await run(admin));
            var sent = AdminRequests(idp) - before;
            var reached = TargetRequests(idp) - targetBefore;
            var got = Brief(value, error);
            _out.WriteLine($"[redirect] 302 {name}: {got} · admin requests {sent} · target requests {reached}");
            if (IsAdminErrorOf(error, 302) && sent == 1 && reached == 0)
                passed++;
            else
                wrong.Add($"302 {name}: {got} · admin requests {sent} · target requests {reached}");
        }
        _out.WriteLine($"[redirect] 302: {passed}/{Ops.Length} cells pass");

        Assert.True(wrong.Count == 0, $"{wrong.Count} cell(s) wrong:\n{string.Join('\n', wrong)}");
    }
}
