using System.Text;
using Keycloak.AuthServices.Sdk.Admin.Models;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// A response the SDK cannot decode ends in an SDK error with a message that says so — never a lower-library exception
/// (§4), never a value rewritten into a "valid" one. Registry <c>dotnet-unpaired-surrogate-escapes</c>.
/// </summary>
/// <remarks>
/// <para>System.Text.Json parses an unpaired UTF-16 surrogate escape (<c>"\ud800"</c>, <c>"\udc00"</c>,
/// <c>"\ud800x"</c>) — RFC 8259 §8.2 lets the grammar carry one — but refuses to decode it: <c>GetString</c> throws
/// <c>InvalidOperationException</c>. Duende decodes lazily, in its getters.</para>
/// <para>Measured before the fix (2026-10-05, fake IdP, every variant): an <c>error</c> holding one let a raw
/// <c>InvalidOperationException</c> out of client credentials, refresh, code exchange and the admin token fetch at 400
/// and 200 (Duende's <c>IsError</c>), and out of all five calls at 401 (the SDK's own <c>GetString</c> in
/// <c>OAuthErrorOf</c>); an <c>access_token</c> or <c>refresh_token</c> holding one did the same from <c>ToTokenSet</c>;
/// introspection turned every such body — including a JSON object with one bad claim — into the false message "response
/// body is not a JSON object". On the admin side the typed client let <c>System.Text.Json.JsonException</c> out for a
/// 200 body with invalid UTF-8 or such an escape, and for a 400/404 error body with the escape (it decodes error bodies
/// itself).</para>
/// <para>An undecodable <c>error</c> member is no code, as the RFC 6749 grammar rule has it
/// (<c>OAuthErrorCodeGrammarTests</c>): <c>OAuthError</c> is <c>null</c> on 400 and 2xx, the canonical reason elsewhere.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class UndecodableResponseTests : IDisposable
{
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private const string NotACode = "error is not an RFC 6749 error code";
    private const string IntrospectionUndecodable = "Token introspection failed: response body is not a decodable JSON object";

    /// <summary>The escape text as it travels — JSON, not a .NET surrogate.</summary>
    public static readonly string[] Escapes = { @"\ud800", @"\udc00", @"\ud800x" };

    private readonly WireMockServer _idp = WireMockServer.Start();

    public void Dispose() => _idp.Dispose();

    private delegate Task<object> Call(KeycloakClient kc);

    /// <summary>The calls that read a token-endpoint response, with their failure prefix. The admin facade's own token
    /// fetch goes through client credentials.</summary>
    private static readonly (string Name, string Prefix, Call Run)[] TokenCalls =
    {
        ("ClientCredentialsTokenAsync", "Client credentials grant failed", async kc => await kc.Auth.ClientCredentialsTokenAsync()),
        ("RefreshAsync", "Token refresh failed", async kc => await kc.Auth.RefreshAsync("rt-sent")),
        ("ExchangeCodeAsync", "Authorization code exchange failed",
            async kc => await kc.Auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43), "n1")),
        ("AdminAsync", "Client credentials grant failed", async kc => await kc.AdminAsync()),
    };

    public static IEnumerable<object[]> ErrorCases =>
        from escape in Escapes
        from status in new[] { 400, 401, 200 }
        select new object[] { escape, status };

    private KeycloakClient Facade() =>
        KeycloakClient.Create(new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" });

    private void Answer(string path, int status, string body) =>
        _idp.Given(Request.Create().WithPath(path).UsingPost()).RespondWith(
            Response.Create().WithStatusCode(status).WithHeader("Content-Type", "application/json").WithBody(body));

    private void AnswerBoth(int status, string body)
    {
        Answer($"{Oidc}/token", status, body);
        Answer($"{Oidc}/token/introspect", status, body);
    }

    private int AdminRequests() => _idp.LogEntries.Count(e => e.RequestMessage?.Path?.StartsWith("/admin/", StringComparison.Ordinal) == true);

    /// <summary>An <c>error</c> member holding an unpaired surrogate escape: no code, an SDK error, on every call.</summary>
    [Theory]
    [MemberData(nameof(ErrorCases))]
    public async Task An_undecodable_error_member_is_no_code(string escape, int status)
    {
        AnswerBoth(status, $$"""{"error":"{{escape}}"}""");
        var wrong = new List<string>();
        foreach (var (name, prefix, run) in TokenCalls)
        {
            using var kc = Facade();
            var (message, code) = status == 401 ? ($"{prefix}: Unauthorized", "Unauthorized") : ($"{prefix}: {NotACode}", (string?)null);
            Expect(wrong, name, await Record.ExceptionAsync(() => run(kc)), message, code);
        }
        using (var kc = Facade())
        {
            var (message, code) = status == 401
                ? ("Token introspection failed: Unauthorized", "Unauthorized")
                : (IntrospectionUndecodable, (string?)null);
            Expect(wrong, "IntrospectAsync", await Record.ExceptionAsync(() => kc.Auth.IntrospectAsync("tok-sent")), message, code);
        }
        Assert.True(wrong.Count == 0, $"[error {escape} · HTTP {status}]\n" + string.Join("\n", wrong));
        Assert.Equal(0, AdminRequests());
    }

    /// <summary>A token-response string member holding an unpaired surrogate escape fails the call by name — the member is
    /// never decoded into something else, and the admin lane sends no admin request.</summary>
    [Theory]
    [InlineData("access_token")]
    [InlineData("refresh_token")]
    [InlineData("id_token")]
    [InlineData("token_type")]
    [InlineData("scope")]
    [InlineData("expires_in")]
    public async Task An_undecodable_token_member_fails_the_call_by_name(string member)
    {
        foreach (var escape in Escapes)
        {
            var fields = new Dictionary<string, string>
            {
                ["access_token"] = "\"usable-access\"",
                ["token_type"] = "\"Bearer\"",
                ["expires_in"] = "300",
                ["refresh_token"] = "\"rt-1\"",
            };
            fields[member] = $"\"{escape}\"";
            AnswerBoth(200, "{" + string.Join(",", fields.Select(kv => $"\"{kv.Key}\":{kv.Value}")) + "}");
            var wrong = new List<string>();
            foreach (var (name, prefix, run) in TokenCalls)
            {
                using var kc = Facade();
                Expect(wrong, name, await Record.ExceptionAsync(() => run(kc)), $"{prefix}: {member} holds an unpaired surrogate escape", null);
            }
            using (var kc = Facade())
                Expect(wrong, "IntrospectAsync", await Record.ExceptionAsync(() => kc.Auth.IntrospectAsync("tok-sent")), IntrospectionUndecodable, null);
            Assert.True(wrong.Count == 0, $"[{member} = {escape}]\n" + string.Join("\n", wrong));
            Assert.Equal(0, AdminRequests());
            _idp.ResetMappings();
        }
    }

    /// <summary>An introspection claim holding one: the body is a JSON object, so the message must not say it is not.</summary>
    [Fact]
    public async Task An_undecodable_introspection_claim_is_reported_as_undecodable()
    {
        foreach (var escape in Escapes)
        {
            _idp.ResetMappings();
            Answer($"{Oidc}/token/introspect", 200, $$"""{"active":true,"sub":"{{escape}}","username":"svc"}""");
            using var kc = Facade();
            var ex = await Record.ExceptionAsync(() => kc.Auth.IntrospectAsync("tok-sent"));
            var auth = Assert.IsType<KeycloakAuthException>(ex);
            Assert.Equal(IntrospectionUndecodable, auth.Message);
            Assert.Null(auth.OAuthError);
        }
    }

    /// <summary>Control — the same shapes, decodable, still succeed: a surrogate PAIR escape and a non-ASCII escape decode.</summary>
    [Fact]
    public async Task Control_decodable_responses_still_succeed()
    {
        var pair = Esc(0xD83D) + Esc(0xDE00);   // U+1F600 as a JSON escape pair
        AnswerBoth(200, $$"""{"access_token":"usable-access","token_type":"Bearer","expires_in":300,"refresh_token":"rt-{{pair}}","scope":"openid","active":true,"sub":"{{Esc(0xE9)}}"}""");
        using var kc = Facade();
        Assert.Equal("usable-access", (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken);
        Assert.Equal("rt-" + char.ConvertFromUtf32(0x1F600), (await kc.Auth.RefreshAsync("rt")).RefreshToken);
        Assert.Equal(((char)0xE9).ToString(), (await kc.Auth.IntrospectAsync("tok")).Claims["sub"]);
    }

    /// <summary>The six-character JSON escape for a UTF-16 code unit — built, so no tool or editor turns it into the
    /// character itself.</summary>
    private static string Esc(int codeUnit) => "\\u" + codeUnit.ToString("x4", System.Globalization.CultureInfo.InvariantCulture);

    // ── admin: the typed client decodes 200 bodies and error bodies itself ─────────────────────────────────────────

    private async Task<Xzawed.Keycloak.Admin.AdminClient> AdminAsync(KeycloakClient kc)
    {
        Answer($"{Oidc}/token", 200, """{"access_token":"usable-access","token_type":"Bearer","expires_in":300}""");
        return await kc.AdminAsync();
    }

    private void AdminAnswers(int status, byte[] body)
    {
        foreach (var path in new[] { "/admin/realms", "/admin/realms/r", "/admin/realms/r/users", "/admin/realms/r/users/1", "/admin/realms/r/groups", "/admin/realms/r/groups/1", "/admin/realms/r/roles", "/admin/realms/r/clients/1" })
        {
            _idp.Given(Request.Create().WithPath(path).UsingGet()).RespondWith(
                Response.Create().WithStatusCode(status).WithHeader("Content-Type", "application/json").WithBody(body));
        }
    }

    private delegate Task<object?> AdminCall(Xzawed.Keycloak.Admin.AdminClient admin);

    /// <summary>The typed calls (Keycloak.AuthServices decodes the body) and the raw ones (<c>GetJsonAsync</c>).</summary>
    private static readonly (string Name, bool Typed, AdminCall Run)[] AdminCalls =
    {
        ("typed Realms.GetAsync", true, async a => await a.Realms.GetAsync("r")),
        ("typed Users.SearchAsync", true, async a => await a.Users.SearchAsync(null)),
        ("typed Users.GetAsync", true, async a => await a.Users.GetAsync("1")),
        ("typed Groups.ListAsync", true, async a => await a.Groups.ListAsync()),
        ("typed Groups.GetAsync", true, async a => await a.Groups.GetAsync("1")),
        ("raw Realms.ListAsync", false, async a => await a.Realms.ListAsync()),
        ("raw Roles.ListAsync", false, async a => await a.Roles.ListAsync()),
        ("raw Clients.GetAsync", false, async a => await a.Clients.GetAsync("1")),
    };

    private static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);

    /// <summary>The body with an invalid UTF-8 byte (0xFF) or a surrogate escape in a string field.</summary>
    public static IEnumerable<object[]> BadBodies =>
        new[] { "0xFF", @"\ud800", @"\udc00" }.Select(b => new object[] { b });

    /// <summary><paramref name="json"/> with every <c>BAD</c> replaced by the bad bytes.</summary>
    private static byte[] Field(string kind, string json)
    {
        var bad = kind == "0xFF" ? new byte[] { 0xFF } : Utf8(kind);
        var parts = json.Split("BAD");
        return parts.Skip(1).Aggregate(Utf8(parts[0]).AsEnumerable(), (acc, part) => acc.Concat(bad).Concat(Utf8(part))).ToArray();
    }

    /// <summary>A 2xx body that cannot be decoded: the same SDK error on the typed and the raw path.</summary>
    [Theory]
    [MemberData(nameof(BadBodies))]
    public async Task An_undecodable_admin_body_is_an_sdk_error(string kind)
    {
        using var kc = Facade();
        var admin = await AdminAsync(kc);
        var wrong = new List<string>();
        foreach (var (name, typed, run) in AdminCalls)
        {
            _idp.ResetMappings();
            // A list for the list calls, an object for the rest — the bad bytes sit in a string field either way.
            var isList = name.Contains("List", StringComparison.Ordinal) || name.Contains("Search", StringComparison.Ordinal);
            var json = isList ? """[{"id":"1","realm":"vBADx","username":"vBADx","name":"vBADx"}]""" : """{"id":"1","realm":"vBADx","username":"vBADx","name":"vBADx","clientId":"vBADx"}""";
            AdminAnswers(200, Field(kind, json));
            var ex = await Record.ExceptionAsync(() => run(admin));
            if (ex is not KeycloakAdminException { StatusCode: 500 } k || k.GetType() != typeof(KeycloakAdminException) || k.Message != "admin response body could not be decoded")
                wrong.Add($"{name} ({(typed ? "typed" : "raw")}): {Describe(ex)}");
        }
        Assert.True(wrong.Count == 0, $"[200 with {kind}]\n" + string.Join("\n", wrong));
    }

    /// <summary>An error body the typed client cannot decode keeps the HTTP status it came with — a 404 is still a
    /// <see cref="KeycloakNotFoundException"/>.</summary>
    [Theory]
    [InlineData(404, typeof(KeycloakNotFoundException), "admin error response body could not be decoded")]
    [InlineData(403, typeof(KeycloakForbiddenException), "admin error response body could not be decoded")]
    [InlineData(400, typeof(KeycloakAdminException), "HTTP 400: admin error response body could not be decoded")]
    public async Task An_undecodable_admin_error_body_keeps_its_status(int status, Type type, string message)
    {
        using var kc = Facade();
        var admin = await AdminAsync(kc);
        var wrong = new List<string>();
        foreach (var escape in Escapes)
        {
            foreach (var (name, _, run) in AdminCalls.Where(c => c.Typed))
            {
                _idp.ResetMappings();
                AdminAnswers(status, Utf8($$"""{"error":"e{{escape}}","errorMessage":"m{{escape}}"}"""));
                var ex = await Record.ExceptionAsync(() => run(admin));
                if (ex?.GetType() != type || ((KeycloakAdminException)ex).StatusCode != status || ex.Message != message)
                    wrong.Add($"{name} {escape}: {Describe(ex)}");
            }
        }
        Assert.True(wrong.Count == 0, $"[HTTP {status} error body]\n" + string.Join("\n", wrong));
    }

    /// <summary>The same catch sees a JSON failure that happened before any response: a request body the typed client could
    /// not encode. It must not be reported as an undecodable response — it was a raw <c>JsonException</c> before.</summary>
    [Fact]
    public async Task A_request_body_that_cannot_be_encoded_is_not_reported_as_a_response()
    {
        using var kc = Facade();
        var admin = await AdminAsync(kc);
        var group = new GroupRepresentation { Name = "g" };
        group.SubGroups = new List<GroupRepresentation> { group }; // contains itself

        var ex = await Record.ExceptionAsync(() => admin.Groups.UpdateAsync("1", group));

        var transport = Assert.IsType<KeycloakTransportException>(ex);
        Assert.Equal("admin request failed: the request body could not be encoded as JSON", transport.Message);
    }

    private static void Expect(List<string> wrong, string call, Exception? ex, string message, string? code)
    {
        if (ex is not KeycloakAuthException k || k.Message != message || k.OAuthError != code)
            wrong.Add($"{call}: {Describe(ex)} — want KeycloakAuthException \"{message}\" / OAuthError {code ?? "null"}");
    }

    private static string Describe(Exception? ex) => ex switch
    {
        null => "no exception",
        KeycloakAuthException k => $"KeycloakAuthException \"{k.Message}\" OAuthError={k.OAuthError ?? "null"}",
        KeycloakAdminException a => $"{a.GetType().Name}({a.StatusCode}) \"{a.Message}\"",
        _ => $"{ex.GetType().FullName}: {ex.Message}",
    };
}
