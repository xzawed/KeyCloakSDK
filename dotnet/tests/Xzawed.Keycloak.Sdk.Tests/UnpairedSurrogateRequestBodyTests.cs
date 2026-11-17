using System.Text.Json.Nodes;
using Keycloak.AuthServices.Sdk.Admin.Models;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// An admin write whose body holds an unpaired UTF-16 surrogate is refused before any request — the transport error and the
/// message of every body JSON cannot carry (registry <c>admin-unencodable-body-residuals</c>). System.Text.Json does not refuse
/// one: it writes U+FFFD in its place, so the server stored a value the caller never sent (measured below, and in
/// <c>UnencodableRequestBodyTests</c>' remarks).
/// </summary>
/// <remarks>
/// <para>Every write — the typed client's and the raw REST ones — and <see cref="AdminClient.Raw"/> are covered: the check sits
/// where every admin request passes before its token is asked for. A counting token provider shows it ran first; WireMock's log
/// shows no admin request went out. A surrogate pair is one character and goes out unchanged, and so does a U+FFFD the caller
/// wrote.</para>
/// <para>Non-finite numbers already end in this message (<c>UnencodableRequestBodyTests</c>, where the serializer refuses them
/// inside the transport) — pinned here for ±Infinity too, with no admin request.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class UnpairedSurrogateRequestBodyTests : IDisposable
{
    private const string Unencodable = "admin request failed: the request body could not be encoded as JSON";

    private readonly WireMockServer _idp = WireMockServer.Start();

    public UnpairedSurrogateRequestBodyTests()
    {
        foreach (var (path, method, status) in new[]
                 {
                     ("/admin/realms/r/users", "POST", 201), ("/admin/realms/r/users/1", "PUT", 204),
                     ("/admin/realms/r/groups", "POST", 201), ("/admin/realms/r/groups/1", "PUT", 204),
                     ("/admin/realms/r/clients", "POST", 201), ("/admin/realms/r/clients/1", "PUT", 204),
                     ("/admin/realms/r/roles", "POST", 201), ("/admin/realms/r/roles/role1", "PUT", 204),
                     ("/admin/realms", "POST", 201), ("/admin/realms/r2", "PUT", 204),
                 })
        {
            var resp = Response.Create().WithStatusCode(status);
            if (status == 201)
                resp = resp.WithHeader("Location", $"http://idp.test{path}/new-id");
            _idp.Given(Request.Create().WithPath(path).UsingMethod(method)).RespondWith(resp);
        }
    }

    public void Dispose() => _idp.Dispose();

    /// <summary>Counts how often the admin client asked for a token — once per request it was about to send.</summary>
    private sealed class CountingProvider : ITokenProvider
    {
        public int Calls;

        public Task<string> GetAccessTokenAsync(CancellationToken ct = default)
        {
            Interlocked.Increment(ref Calls);
            return Task.FromResult("usable-access");
        }
    }

    private async Task<(AdminClient Admin, CountingProvider Tokens)> AdminAsync()
    {
        var tokens = new CountingProvider();
        var admin = await AdminClient.CreateAsync(
            new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" }, tokens);
        return (admin, tokens);
    }

    /// <summary>Every public admin call that sends a representation: a fresh one carrying <c>text</c> in its main string
    /// property, and the call.</summary>
    private static readonly Dictionary<string, (Func<string, object> Make, Func<AdminClient, object, Task> Run)> Writes = new()
    {
        ["Users.CreateAsync"] = (t => new UserRepresentation { Username = t }, (a, r) => a.Users.CreateAsync((UserRepresentation)r)),
        ["Users.UpdateAsync"] = (t => new UserRepresentation { Username = t }, (a, r) => a.Users.UpdateAsync("1", (UserRepresentation)r)),
        ["Groups.CreateAsync"] = (t => new GroupRepresentation { Name = t }, (a, r) => a.Groups.CreateAsync((GroupRepresentation)r)),
        ["Groups.UpdateAsync"] = (t => new GroupRepresentation { Name = t }, (a, r) => a.Groups.UpdateAsync("1", (GroupRepresentation)r)),
        ["Clients.CreateAsync"] = (t => new ClientRepresentation { ClientId = t }, (a, r) => a.Clients.CreateAsync((ClientRepresentation)r)),
        ["Clients.UpdateAsync"] = (t => new ClientRepresentation { ClientId = t }, (a, r) => a.Clients.UpdateAsync("1", (ClientRepresentation)r)),
        ["Roles.CreateAsync"] = (t => new RoleRepresentation { Name = t }, (a, r) => a.Roles.CreateAsync((RoleRepresentation)r)),
        ["Roles.UpdateAsync"] = (t => new RoleRepresentation { Name = t }, (a, r) => a.Roles.UpdateAsync("role1", (RoleRepresentation)r)),
        ["Realms.CreateAsync"] = (t => new RealmRepresentation { Realm = t }, (a, r) => a.Realms.CreateAsync((RealmRepresentation)r)),
        ["Realms.UpdateAsync"] = (t => new RealmRepresentation { Realm = t }, (a, r) => a.Realms.UpdateAsync("r2", (RealmRepresentation)r)),
    };

    public static IEnumerable<object[]> WriteNames => Writes.Keys.Select(k => new object[] { k });

    private static IDictionary<string, object> Extra(object representation) =>
        (IDictionary<string, object>)representation.GetType().GetProperty("AdditionalProperties")!.GetValue(representation)!;

    /// <summary>Where an unpaired surrogate can sit in a body — each one went out as U+FFFD before the fix.</summary>
    private static readonly (string Name, Func<Func<string, object>, object> Body)[] Positions =
    {
        ("a high surrogate with no low one in a string property", make => make("u\ud800")),
        ("a low surrogate with no high one in a string property", make => make("\udc00u")),
        ("a reversed pair in a string property", make => make("u\udc00\ud800")),
        ("an extension-data value", make => With(make("u"), e => e["k"] = "v\ud800")),
        ("an extension-data key", make => With(make("u"), e => e["k\udbff"] = "v")),
        ("a string in a list in a dictionary", make => With(make("u"), e => e["m"] = new Dictionary<string, object> { ["n"] = new List<object> { "x\ud800" } })),
        ("a dictionary key inside a value", make => With(make("u"), e => e["m"] = new Dictionary<string, string> { ["k\ud800"] = "v" })),
        ("a char", make => With(make("u"), e => e["c"] = '\ud800')),
        ("a JsonValue string", make => With(make("u"), e => e["j"] = JsonValue.Create("x\ud800")!)),
        ("a JsonValue char", make => With(make("u"), e => e["j"] = JsonValue.Create('\udc00'))),
        ("a JsonObject key", make => With(make("u"), e => e["j"] = new JsonObject { ["k\ud800"] = 1 })),
        ("a string in a JsonArray", make => With(make("u"), e => e["j"] = new JsonArray(new JsonObject { ["k"] = "x\udfff" }))),
    };

    private static object With(object representation, Action<IDictionary<string, object>> poison)
    {
        poison(Extra(representation));
        return representation;
    }

    private int AdminRequests() => _idp.LogEntries.Count(e => e.RequestMessage?.Path?.StartsWith("/admin/", StringComparison.Ordinal) == true);

    private string Bodies() => string.Join(" ‖ ", _idp.LogEntries.Select(e => e.RequestMessage?.Body ?? "(none)"));

    [Theory]
    [MemberData(nameof(WriteNames))]
    public async Task An_unpaired_surrogate_anywhere_in_the_body_ends_the_write_before_any_request(string write)
    {
        var (make, run) = Writes[write];
        var (admin, tokens) = await AdminAsync();
        using var _ = admin;

        var wrong = new List<string>();
        foreach (var (name, body) in Positions)
        {
            _idp.ResetLogEntries();
            var before = tokens.Calls;
            var ex = await Record.ExceptionAsync(() => run(admin, body(make)));
            if (AdminRequests() != 0 || tokens.Calls != before
                || ex is not KeycloakTransportException { Message: Unencodable })
                wrong.Add($"{name}: {ex?.GetType().Name ?? "no exception"} \"{ex?.Message}\" · admin requests {AdminRequests()} "
                          + $"· token asked {tokens.Calls - before}× · sent {Bodies()}");
        }
        Assert.True(wrong.Count == 0, $"[{write}]\n" + string.Join("\n", wrong));
    }

    [Fact]
    public async Task The_raw_typed_client_is_refused_the_same_way()
    {
        var (admin, tokens) = await AdminAsync();
        using var _ = admin;
        _idp.ResetLogEntries();
        var before = tokens.Calls;

        var ex = await Record.ExceptionAsync(() => admin.Raw.UpdateUserAsync("r", "1", new UserRepresentation { Username = "u\ud800" }));

        Assert.Equal(Unencodable, Assert.IsType<KeycloakTransportException>(ex).Message);
        Assert.Equal(0, AdminRequests());
        Assert.Equal(before, tokens.Calls);
    }

    /// <summary>Control: what is valid UTF-16 goes out as the caller wrote it — a surrogate pair (one astral character) and a
    /// U+FFFD the caller put there are not mistaken for the refused case, nor are a char or a JsonValue that holds no string.
    /// The serializer escapes the non-ASCII ones.</summary>
    [Fact]
    public async Task A_surrogate_pair_and_a_written_replacement_character_go_out_unchanged()
    {
        var (admin, _) = await AdminAsync();
        using var __ = admin;
        _idp.ResetLogEntries();
        var user = new UserRepresentation { Username = "u😀" };
        Extra(user)["k😀"] = "v�";
        Extra(user)["c"] = new JsonObject { ["j"] = "😀", ["n"] = 1.5, ["ch"] = JsonValue.Create('y') };
        Extra(user)["ch"] = 'x';

        await admin.Users.UpdateAsync("1", user);

        var sent = Assert.Single(_idp.LogEntries).RequestMessage!.Body;
        Assert.Equal("{\"username\":\"u\\uD83D\\uDE00\",\"k\\uD83D\\uDE00\":\"v\\uFFFD\","
                     + "\"c\":{\"j\":\"\\uD83D\\uDE00\",\"n\":1.5,\"ch\":\"y\"},\"ch\":\"x\"}", sent);
    }

    /// <summary>NaN and ±Infinity: the serializer refuses them inside the transport (<c>UnencodableRequestBodyTests</c>) — no
    /// admin request, on a typed write and on a raw one.</summary>
    [Theory]
    [InlineData("Users.UpdateAsync")]
    [InlineData("Roles.CreateAsync")]
    public async Task A_non_finite_number_ends_the_write_without_an_admin_request(string write)
    {
        var (make, run) = Writes[write];
        var (admin, _) = await AdminAsync();
        using var __ = admin;

        foreach (var value in new object[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity, float.NegativeInfinity })
        {
            _idp.ResetLogEntries();
            var body = make("u");
            Extra(body)["n"] = value;
            var ex = await Record.ExceptionAsync(() => run(admin, body));
            Assert.Equal(Unencodable, Assert.IsType<KeycloakTransportException>(ex).Message);
            Assert.IsType<ArgumentException>(ex.InnerException);
            Assert.Equal(0, AdminRequests());
        }
    }
}
