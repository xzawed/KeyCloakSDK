using System.Net.Http.Headers;
using System.Text;
using Keycloak.AuthServices.Sdk.Admin.Models;
using WireMock.Matchers;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// An admin response whose <c>Content-Type</c> names a charset .NET will not decode ends in the SDK error the same call
/// gives any body it cannot decode — never the lower library's exception (§4), and neither the charset name nor the body
/// reaches the error. Registry <c>dotnet-admin-bogus-charset-escape</c>.
/// </summary>
/// <remarks>
/// <para>.NET resolves the charset before it reads a byte. An unknown name — bare, quoted, or the empty <c>""</c> — makes
/// <c>Encoding.GetEncoding</c> throw <c>ArgumentException</c>, quoting the name, and <c>HttpContent</c>'s string read and
/// <c>System.Net.Http.Json</c> wrap it in <c>InvalidOperationException</c>. UTF-7 is disabled under every alias:
/// <c>GetEncoding</c> throws <c>NotSupportedException</c>, and neither wraps that.</para>
/// <para>Measured before the fix (2026-10-09, .NET 8.0.23 and 10.0.2): the admin calls that read the body let one of them
/// out raw, an unknown name quoted in <c>ToString()</c> — a 2xx read on the typed and the raw path (only a raw read under
/// UTF-7 was already caught, by the JSON arm), and every call on an error status, whose body is read for the message. A
/// 2xx call that never reads the body (update, delete, create) succeeded, and still must. The auth lane, discovery and
/// the JWKS already ended in SDK errors: Duende catches the failed read itself, logout never reads the body, and the
/// document retriever decodes UTF-8 whatever the header says.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class UnsupportedCharsetResponseTests : IDisposable
{
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private const string BodyCanary = "LK-CHARSET-BODY-canary";
    private const string Undecodable = "admin error response body could not be decoded";

    /// <summary>Charsets .NET refuses: unknown names — the registry's own, two that carry a canary (bare and quoted), the
    /// empty quoted one — and UTF-7 under two of its aliases.</summary>
    private static readonly string[] UnsupportedCharsets =
        { "bogus-cs", "LK-CHARSET-1-canary", "\"LK-CHARSET-2-canary\"", "\"\"", "utf-7", "x-unicode-2-0-utf-7" };

    public static IEnumerable<object[]> Unsupported => UnsupportedCharsets.Select(c => new object[] { c });

    public static IEnumerable<object[]> ErrorCases =>
        from charset in UnsupportedCharsets
        from status in new[] { 400, 403, 404, 409, 500 }
        select new object[] { charset, status };

    private readonly WireMockServer _idp = WireMockServer.Start();

    public void Dispose() => _idp.Dispose();

    private delegate Task<object?> AdminCall(AdminClient admin);

    /// <summary>Every admin call, by the boundary it goes through: typed reads and writes (<c>CallTypedAsync</c>), typed
    /// creates (<c>CreateReturningIdAsync</c>), raw reads (<c>GetJsonAsync</c>), raw writes (<c>SendRawAsync</c>) and the raw
    /// create. <c>Reads</c>: the call decodes a 2xx body. <c>List</c>: its 2xx body is a JSON array.</summary>
    private static readonly (string Name, bool Reads, bool List, AdminCall Run)[] Calls =
    {
        ("typed Realms.GetAsync", true, false, async a => await a.Realms.GetAsync("r")),
        ("typed Users.GetAsync", true, false, async a => await a.Users.GetAsync("1")),
        ("typed Users.SearchAsync", true, true, async a => await a.Users.SearchAsync(null)),
        ("typed Groups.GetAsync", true, false, async a => await a.Groups.GetAsync("1")),
        ("typed Groups.ListAsync", true, true, async a => await a.Groups.ListAsync()),
        ("typed Users.UpdateAsync", false, false, async a => { await a.Users.UpdateAsync("1", new UserRepresentation { Username = "u" }); return null; }),
        ("typed Users.DeleteAsync", false, false, async a => { await a.Users.DeleteAsync("1"); return null; }),
        ("typed Groups.UpdateAsync", false, false, async a => { await a.Groups.UpdateAsync("1", new GroupRepresentation { Name = "g" }); return null; }),
        ("typed Groups.DeleteAsync", false, false, async a => { await a.Groups.DeleteAsync("1"); return null; }),
        ("typed Users.CreateAsync", false, false, async a => await a.Users.CreateAsync(new UserRepresentation { Username = "u" })),
        ("typed Groups.CreateAsync", false, false, async a => await a.Groups.CreateAsync(new GroupRepresentation { Name = "g" })),
        ("raw Realms.ListAsync", true, true, async a => await a.Realms.ListAsync()),
        ("raw Roles.GetAsync", true, false, async a => await a.Roles.GetAsync("n")),
        ("raw Roles.ListAsync", true, true, async a => await a.Roles.ListAsync()),
        ("raw Clients.GetAsync", true, false, async a => await a.Clients.GetAsync("1")),
        ("raw Clients.FindByClientIdAsync", true, true, async a => await a.Clients.FindByClientIdAsync("c")),
        ("raw Realms.CreateAsync", false, false, async a => { await a.Realms.CreateAsync(new RealmRepresentation { Realm = "x" }); return null; }),
        ("raw Realms.UpdateAsync", false, false, async a => { await a.Realms.UpdateAsync("r", new RealmRepresentation { Realm = "x" }); return null; }),
        ("raw Realms.DeleteAsync", false, false, async a => { await a.Realms.DeleteAsync("r"); return null; }),
        ("raw Roles.CreateAsync", false, false, async a => { await a.Roles.CreateAsync(new RoleRepresentation { Name = "n" }); return null; }),
        ("raw Roles.UpdateAsync", false, false, async a => { await a.Roles.UpdateAsync("n", new RoleRepresentation { Name = "n" }); return null; }),
        ("raw Roles.DeleteAsync", false, false, async a => { await a.Roles.DeleteAsync("n"); return null; }),
        ("raw Clients.UpdateAsync", false, false, async a => { await a.Clients.UpdateAsync("1", new ClientRepresentation { ClientId = "c" }); return null; }),
        ("raw Clients.DeleteAsync", false, false, async a => { await a.Clients.DeleteAsync("1"); return null; }),
        ("raw Clients.CreateAsync", false, false, async a => await a.Clients.CreateAsync(new ClientRepresentation { ClientId = "c" })),
    };

    private async Task<(KeycloakClient Kc, AdminClient Admin)> AdminAsync()
    {
        AnswerToken();
        var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" });
        return (kc, await kc.AdminAsync());
    }

    private void AnswerToken() =>
        _idp.Given(Request.Create().WithPath($"{Oidc}/token").UsingPost()).RespondWith(
            Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody("""{"access_token":"usable-access","token_type":"Bearer","expires_in":300}"""));

    /// <summary>Every admin request gets <paramref name="status"/>, a body holding the canary, the charset as given, and a
    /// <c>Location</c> for the creates.</summary>
    private void AnswerAdmin(int status, string charset, bool list)
    {
        _idp.ResetMappings();
        AnswerToken();
        var body = list
            ? $$"""[{"id":"1","name":"{{BodyCanary}}"}]"""
            : $$"""{"id":"1","name":"{{BodyCanary}}","error":"{{BodyCanary}}","errorMessage":"{{BodyCanary}}"}""";
        _idp.Given(Request.Create().WithPath(new WildcardMatcher("/admin/*")).UsingAnyMethod()).RespondWith(
            Response.Create().WithStatusCode(status)
                .WithHeader("Content-Type", $"application/json; charset={charset}")
                .WithHeader("Location", _idp.Urls[0] + "/admin/realms/r/things/new-id")
                .WithBody(Encoding.UTF8.GetBytes(body)));
    }

    /// <summary>A 2xx body in a charset .NET will not decode: a call that reads it fails as an undecodable body does, on
    /// the typed and the raw path alike; a call that does not read it still succeeds.</summary>
    [Theory]
    [MemberData(nameof(Unsupported))]
    public async Task A_success_body_in_an_unsupported_charset_is_an_undecodable_body(string charset)
    {
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            var wrong = new List<string>();
            foreach (var (name, reads, list, run) in Calls)
            {
                AnswerAdmin(200, charset, list);
                var ex = await Record.ExceptionAsync(() => run(admin));
                if (reads)
                    Check(wrong, name, ex, typeof(KeycloakAdminException), 500, "admin response body could not be decoded", charset);
                else if (ex is not null)
                    wrong.Add($"{name}: it reads no body, so it must succeed — got {Describe(ex)}");
            }
            Assert.True(wrong.Count == 0, $"[HTTP 200 · charset={charset}]\n" + string.Join("\n", wrong));
        }
    }

    /// <summary>An error body in a charset .NET will not decode keeps the status it came with, on every call — the same
    /// error the typed path gives an error body it cannot decode (<c>UndecodableResponseTests</c>).</summary>
    [Theory]
    [MemberData(nameof(ErrorCases))]
    public async Task An_error_body_in_an_unsupported_charset_keeps_its_status(string charset, int status)
    {
        var (type, message) = status switch
        {
            404 => (typeof(KeycloakNotFoundException), Undecodable),
            403 => (typeof(KeycloakForbiddenException), Undecodable),
            409 => (typeof(KeycloakConflictException), Undecodable),
            _ => (typeof(KeycloakAdminException), $"HTTP {status}: {Undecodable}"),
        };
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            var wrong = new List<string>();
            foreach (var (name, _, list, run) in Calls)
            {
                AnswerAdmin(status, charset, list);
                Check(wrong, name, await Record.ExceptionAsync(() => run(admin)), type, status, message, charset);
            }
            Assert.True(wrong.Count == 0, $"[HTTP {status} · charset={charset}]\n" + string.Join("\n", wrong));
        }
    }

    /// <summary>Control — a charset .NET does decode (any case, quoted, or an empty unquoted parameter it drops) changes
    /// nothing: every call succeeds on 200, and fails on 404 as a not-found.</summary>
    [Theory]
    [InlineData("UTF-8")]
    [InlineData("\"utf-8\"")]
    [InlineData("")]
    public async Task Control_a_supported_charset_still_decodes(string charset)
    {
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            var wrong = new List<string>();
            foreach (var (name, _, list, run) in Calls)
            {
                AnswerAdmin(200, charset, list);
                if (await Record.ExceptionAsync(() => run(admin)) is { } failed)
                    wrong.Add($"{name} on 200: {Describe(failed)}");
                AnswerAdmin(404, charset, list);
                if (await Record.ExceptionAsync(() => run(admin)) is not KeycloakNotFoundException)
                    wrong.Add($"{name} on 404: not a KeycloakNotFoundException");
            }
            Assert.True(wrong.Count == 0, $"[charset={charset}]\n" + string.Join("\n", wrong));
        }
    }

    /// <summary>Control — the conversion is keyed on what refuses a charset, not on the exception type: an
    /// <see cref="InvalidOperationException"/> or <see cref="NotSupportedException"/> that is not a charset failure leaves
    /// the boundary unchanged. The first two come after an admin response has arrived, so only that test decides, and each
    /// is thrown by the same assembly as its charset twin — System.Net.Http refusing a request URI, CoreLib refusing a
    /// write. A disposed client is the public case (<see cref="ObjectDisposedException"/> is an
    /// <see cref="InvalidOperationException"/>).</summary>
    [Fact]
    public async Task Control_an_exception_that_is_not_a_charset_failure_is_unchanged()
    {
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            AnswerAdmin(200, "utf-8", list: false);
            var seen = new List<string?>();
            var http = await Record.ExceptionAsync(() => admin.CallTypedAsync<int>(async c =>
            {
                seen.Add((await c.GetRealmAsync("r")).Id);
                using var client = new HttpClient();
                using var never = await client.GetAsync(new Uri("relative", UriKind.Relative));
                return 0;
            }));
            Assert.IsType<InvalidOperationException>(http);
            Assert.Equal(typeof(HttpClient).Assembly, http.TargetSite?.DeclaringType?.Assembly); // the control is what it claims

            var write = await Record.ExceptionAsync(() => admin.CallTypedAsync<int>(async c =>
            {
                seen.Add((await c.GetRealmAsync("r")).Id);
                new MemoryStream(new byte[1], writable: false).WriteByte(0);
                return 0;
            }));
            Assert.IsType<NotSupportedException>(write);
            Assert.Equal(typeof(Encoding).Assembly, write.TargetSite?.DeclaringType?.Assembly);
            Assert.Equal(new[] { "1", "1" }, seen); // both threw after an admin response had been decoded

            admin.Dispose();
            foreach (var (name, _, _, run) in Calls)
                Assert.True(await Record.ExceptionAsync(() => run(admin)) is ObjectDisposedException, $"{name} on a disposed client");
        }
    }

    /// <summary>Control — the token provider runs inside the admin call, before any admin response arrives. A consumer's
    /// provider whose own HTTP read fails on a charset throws the very exception .NET throws for a response, and it is not an
    /// admin response that could not be decoded: it leaves every call as it always did.</summary>
    [Theory]
    [InlineData("bogus-cs", typeof(InvalidOperationException))]
    [InlineData("utf-7", typeof(NotSupportedException))]
    public async Task Control_a_charset_failure_before_any_admin_response_is_unchanged(string charset, Type thrown)
    {
        var cfg = new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" };
        using var admin = await AdminClient.CreateAsync(cfg, new CharsetFailingProvider(charset));
        var wrong = new List<string>();
        foreach (var (name, _, _, run) in Calls)
        {
            var ex = await Record.ExceptionAsync(() => run(admin));
            if (ex?.GetType() != thrown)
                wrong.Add($"{name}: {Describe(ex)} — want the provider's own {thrown.Name}");
        }
        Assert.True(wrong.Count == 0, $"[provider read · charset={charset}]\n" + string.Join("\n", wrong));
        Assert.DoesNotContain(_idp.LogEntries, e => e.RequestMessage?.Path?.StartsWith("/admin/", StringComparison.Ordinal) == true);
    }

    /// <summary>Answers the eager warm-up of <see cref="AdminClient.CreateAsync"/>, then reads a token from its own HTTP
    /// content in <paramref name="charset"/> on every call — as a provider that fetches tokens itself would.</summary>
    private sealed class CharsetFailingProvider : ITokenProvider
    {
        private readonly string _charset;
        private int _calls;

        public CharsetFailingProvider(string charset) => _charset = charset;

        public async Task<string> GetAccessTokenAsync(CancellationToken ct = default)
        {
            if (Interlocked.Increment(ref _calls) == 1)
                return "usable-access";
            using var content = new StringContent("token");
            content.Headers.ContentType = MediaTypeHeaderValue.Parse($"text/plain; charset={_charset}");
            return await content.ReadAsStringAsync(ct);
        }
    }

    /// <summary>The expected SDK error, its lower cause kept by type but with nothing it said — the
    /// <c>ArgumentException</c> quotes the charset name (<c>ErrorsTests.Response_read_failure_keeps_types_but_no_message</c>).</summary>
    private static void Check(List<string> wrong, string call, Exception? ex, Type type, int status, string message, string charset)
    {
        if (ex?.GetType() != type || ((KeycloakAdminException)ex).StatusCode != status || ex.Message != message)
        {
            wrong.Add($"{call}: {Describe(ex)} — want {type.Name}({status}) \"{message}\"");
            return;
        }
        var printed = ex.ToString();
        var name = charset.Trim('"');
        if (name.Length > 0 && printed.Contains(name, StringComparison.Ordinal))
            wrong.Add($"{call}: ToString() names the charset {charset}");
        if (printed.Contains(BodyCanary, StringComparison.Ordinal))
            wrong.Add($"{call}: ToString() carries the body");
        var cause = charset.Contains("utf-7", StringComparison.Ordinal)
            ? new[] { "System.NotSupportedException" }
            : new[] { "System.InvalidOperationException", "System.ArgumentException" };
        if (ex.InnerException is null || !cause.All(t => printed.Contains(t, StringComparison.Ordinal)))
            wrong.Add($"{call}: the lower cause ({string.Join(" <- ", cause)}) is not in the chain");
    }

    private static string Describe(Exception? ex) => ex switch
    {
        null => "no exception",
        KeycloakAdminException a => $"{a.GetType().Name}({a.StatusCode}) \"{a.Message}\"",
        _ => $"{ex.GetType().FullName}: {ex.Message}",
    };
}
