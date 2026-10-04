using System.Text.Json;
using Keycloak.AuthServices.Sdk.Admin.Models;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// A representation System.Text.Json refuses to write ends every admin write in an SDK error — never the serializer's own
/// exception (§4). Registry <c>dotnet-unpaired-surrogate-escapes</c>, its "typed request body that cannot be encoded" input.
/// </summary>
/// <remarks>
/// <para>Every representation carries <c>AdditionalProperties</c> (<c>IDictionary&lt;string, object&gt;</c>, written as
/// extra members), so any value the serializer refuses can sit in any request body: the representation itself (a cycle —
/// <c>JsonException</c>), a <c>System.Type</c> (<c>NotSupportedException</c>), <c>double.NaN</c>
/// (<c>ArgumentException</c>).</para>
/// <para>Measured on f3fd71e (verifier probe, 2026-10-05): of 52 writes — the ten below with five bodies each, plus a group
/// whose <c>SubGroups</c> holds itself on <c>Groups.CreateAsync</c> and inside a realm on <c>Realms.CreateAsync</c> — 30 let
/// the serializer's exception out raw (origin/main: 32). Only <c>Users.UpdateAsync</c>/<c>Groups.UpdateAsync</c> with a
/// cycle were SDK errors, because <c>CallTypedAsync</c> caught <c>JsonException</c> alone; the creates and the raw writes
/// caught none of the three. The body is serialized lazily inside the transport (every raw stack ran through
/// <c>System.Net.Http.HttpConnection</c>), so every write meets it in <c>BearerHandler</c>.</para>
/// <para>Not covered here: a lone surrogate in a string is not refused — the serializer writes U+FFFD in its place
/// (measured: the server received U+FFFD where the surrogate was), and a <c>default(JsonElement)</c> value is wrapped by
/// the transport into <c>HttpRequestException</c>, already "admin request failed".</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class UnencodableRequestBodyTests : IDisposable
{
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private const string Unencodable = "admin request failed: the request body could not be encoded as JSON";

    private readonly WireMockServer _idp = WireMockServer.Start();

    public UnencodableRequestBodyTests()
    {
        Answer($"{Oidc}/token", "POST", 200, """{"access_token":"usable-access","token_type":"Bearer","expires_in":300}""");
        foreach (var (path, method, status) in new[]
                 {
                     ("/admin/realms/r/users", "POST", 201), ("/admin/realms/r/users/1", "PUT", 204),
                     ("/admin/realms/r/groups", "POST", 201), ("/admin/realms/r/groups/1", "PUT", 204),
                     ("/admin/realms/r/clients", "POST", 201), ("/admin/realms/r/clients/1", "PUT", 204),
                     ("/admin/realms/r/roles", "POST", 201), ("/admin/realms/r/roles/role1", "PUT", 204),
                     ("/admin/realms", "POST", 201), ("/admin/realms/r2", "PUT", 204),
                 })
        {
            Answer(path, method, status, "", status == 201 ? $"http://idp.test{path}/new-id" : null);
        }
    }

    public void Dispose() => _idp.Dispose();

    private void Answer(string path, string method, int status, string body, string? location = null)
    {
        var resp = Response.Create().WithStatusCode(status).WithHeader("Content-Type", "application/json").WithBody(body);
        if (location is not null)
            resp = resp.WithHeader("Location", location);
        _idp.Given(Request.Create().WithPath(path).UsingMethod(method)).RespondWith(resp);
    }

    /// <summary>Every public admin call that sends a representation: a fresh one, and the call.</summary>
    private static readonly Dictionary<string, (Func<object> Make, Func<AdminClient, object, Task> Run)> Writes = new()
    {
        ["Users.CreateAsync"] = (() => new UserRepresentation { Username = "u1" }, (a, r) => a.Users.CreateAsync((UserRepresentation)r)),
        ["Users.UpdateAsync"] = (() => new UserRepresentation { Username = "u1" }, (a, r) => a.Users.UpdateAsync("1", (UserRepresentation)r)),
        ["Groups.CreateAsync"] = (() => new GroupRepresentation { Name = "g1" }, (a, r) => a.Groups.CreateAsync((GroupRepresentation)r)),
        ["Groups.UpdateAsync"] = (() => new GroupRepresentation { Name = "g1" }, (a, r) => a.Groups.UpdateAsync("1", (GroupRepresentation)r)),
        ["Clients.CreateAsync"] = (() => new ClientRepresentation { ClientId = "c1" }, (a, r) => a.Clients.CreateAsync((ClientRepresentation)r)),
        ["Clients.UpdateAsync"] = (() => new ClientRepresentation { ClientId = "c1" }, (a, r) => a.Clients.UpdateAsync("1", (ClientRepresentation)r)),
        ["Roles.CreateAsync"] = (() => new RoleRepresentation { Name = "role1" }, (a, r) => a.Roles.CreateAsync((RoleRepresentation)r)),
        ["Roles.UpdateAsync"] = (() => new RoleRepresentation { Name = "role1" }, (a, r) => a.Roles.UpdateAsync("role1", (RoleRepresentation)r)),
        ["Realms.CreateAsync"] = (() => new RealmRepresentation { Realm = "r2" }, (a, r) => a.Realms.CreateAsync((RealmRepresentation)r)),
        ["Realms.UpdateAsync"] = (() => new RealmRepresentation { Realm = "r2" }, (a, r) => a.Realms.UpdateAsync("r2", (RealmRepresentation)r)),
    };

    public static IEnumerable<object[]> WriteNames => Writes.Keys.Select(k => new object[] { k });

    private static IDictionary<string, object> Extra(object representation) =>
        (IDictionary<string, object>)representation.GetType().GetProperty("AdditionalProperties")!.GetValue(representation)!;

    /// <summary>A value the serializer refuses, and the exception it refuses it with.</summary>
    private static readonly (string Name, Action<object> Poison, Type Refusal)[] Refusals =
    {
        ("the representation holds itself", r => Extra(r)["loop"] = r, typeof(JsonException)),
        ("a System.Type value", r => Extra(r)["type"] = typeof(string), typeof(NotSupportedException)),
        ("a double.NaN value", r => Extra(r)["nan"] = double.NaN, typeof(ArgumentException)),
    };

    private static KeycloakClient Facade(string url) =>
        KeycloakClient.Create(new KeycloakConfig { ServerUrl = url, Realm = "r", ClientId = "c", ClientSecret = "s" });

    [Theory]
    [MemberData(nameof(WriteNames))]
    public async Task A_body_the_serializer_refuses_ends_the_write_in_an_sdk_error(string write)
    {
        var (make, run) = Writes[write];
        await using var kc = Facade(_idp.Urls[0]);
        var admin = await kc.AdminAsync();

        await run(admin, make()); // control: an encodable body still goes through

        var wrong = new List<string>();
        foreach (var (name, poison, refusal) in Refusals)
        {
            var body = make();
            poison(body);
            var ex = await Record.ExceptionAsync(() => run(admin, body));
            if (ex is not KeycloakTransportException { Message: Unencodable } || ex.InnerException?.GetType() != refusal)
                wrong.Add($"{name}: {ex?.GetType().FullName ?? "no exception"} \"{ex?.Message}\" (cause {ex?.InnerException?.GetType().Name ?? "none"}) — want KeycloakTransportException \"{Unencodable}\" caused by {refusal.Name}");
        }
        Assert.True(wrong.Count == 0, $"[{write}]\n" + string.Join("\n", wrong));
    }

    /// <summary>The input the cycle was first measured with — a group whose <c>SubGroups</c> holds itself — on the create
    /// paths, which the typed update's catch never covered.</summary>
    [Fact]
    public async Task A_group_that_contains_itself_fails_the_create_paths_with_an_sdk_error()
    {
        await using var kc = Facade(_idp.Urls[0]);
        var admin = await kc.AdminAsync();
        var group = new GroupRepresentation { Name = "g" };
        group.SubGroups = new List<GroupRepresentation> { group };

        var create = await Record.ExceptionAsync(() => admin.Groups.CreateAsync(group));
        var realm = await Record.ExceptionAsync(() => admin.Realms.CreateAsync(new RealmRepresentation { Realm = "r2", Groups = new List<GroupRepresentation> { group } }));

        Assert.Equal(Unencodable, Assert.IsType<KeycloakTransportException>(create).Message);
        Assert.Equal(Unencodable, Assert.IsType<KeycloakTransportException>(realm).Message);
    }
}
