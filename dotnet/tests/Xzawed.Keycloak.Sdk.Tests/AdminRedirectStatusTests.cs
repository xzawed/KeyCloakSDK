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
/// </remarks>
[Trait("Category", "Unit")]
public sealed class AdminRedirectStatusTests
{
    private const string TokenPath = "/realms/r/protocol/openid-connect/token";

    private static readonly int[] Statuses = { 300, 302, 399 };

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

    private sealed record Answer(int Status, string Body);

    private static int AdminRequests(KeepAliveIdp idp) => idp.Seen.Count(r => r.Path.StartsWith("/admin/", StringComparison.Ordinal));

    private static string Describe(object? value, Exception? error) => error switch
    {
        null => $"returned {(value is null ? "null (void)" : JsonSerializer.Serialize(value))}",
        KeycloakAdminException admin => $"{admin.GetType().Name}({admin.StatusCode}): {admin.Message}",
        _ => $"{error.GetType().Name}: {error.Message}",
    };

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
}
