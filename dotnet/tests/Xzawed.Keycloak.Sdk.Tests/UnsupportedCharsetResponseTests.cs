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
/// <para>⚠️ That holds for a body <b>not labelled JSON</b>, which is what these tests answer with (<c>text/plain</c>). A JSON
/// body's charset has no effect (RFC 8259 §11 — registry <c>token-response-class-divergent</c> D2, 2026-11-10): it is read as
/// UTF-8 like any other JSON body (<see cref="A_JSON_body_reads_the_same_whatever_charset_it_names"/>). These tests answered
/// with <c>application/json</c> until then, and pinned the 500 that D2 removed.</para>
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

    internal delegate Task<object?> AdminCall(AdminClient admin);

    /// <summary>Every admin call, by the boundary it goes through: typed reads (<c>CallTypedAsync</c>) and writes
    /// (<c>WriteTypedAsync</c>), typed creates (<c>CreateReturningIdAsync</c>), raw reads (<c>GetJsonAsync</c>), raw writes
    /// (<c>WriteRawAsync</c>) and the raw create. <c>Reads</c>: the call decodes a 2xx body. <c>List</c>: its 2xx body is a JSON
    /// array. Also used by <c>TokenProviderFailureTests</c>.</summary>
    internal static readonly (string Name, bool Reads, bool List, AdminCall Run)[] Calls =
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

    /// <summary>Every admin request gets <paramref name="status"/>, a body holding the canary, the charset as given on a media
    /// type that is not JSON (a JSON body's charset has no effect — see the class remarks), and a <c>Location</c> for the
    /// creates.</summary>
    private void AnswerAdmin(int status, string charset, bool list) => AnswerAdminAs(status, $"text/plain; charset={charset}", list);

    /// <summary>As <see cref="AnswerAdmin"/>, under the whole <c>Content-Type</c> given.</summary>
    private void AnswerAdminAs(int status, string contentType, bool list)
    {
        _idp.ResetMappings();
        AnswerToken();
        var body = list
            ? $$"""[{"id":"1","name":"{{BodyCanary}}"}]"""
            : $$"""{"id":"1","name":"{{BodyCanary}}","error":"{{BodyCanary}}","errorMessage":"{{BodyCanary}}"}""";
        _idp.Given(Request.Create().WithPath(new WildcardMatcher("/admin/*")).UsingAnyMethod()).RespondWith(
            Response.Create().WithStatusCode(status)
                .WithHeader("Content-Type", contentType)
                .WithHeader("Location", _idp.Urls[0] + "/admin/realms/r/things/new-id")
                .WithBody(Encoding.UTF8.GetBytes(body)));
    }

    public static IEnumerable<object[]> JsonCharsetCases =>
        from charset in new[] { "x-no-such-charset", "\"x-no-such-charset\"", "utf-7" }
        from status in new[] { 200, 400, 404 }
        select new object[] { charset, status };

    /// <summary>Registry <c>token-response-class-divergent</c> D2 — a <c>charset</c> on <c>application/json</c> has no effect (RFC
    /// 8259 §11), so every admin call reads a JSON body that names one exactly as it reads the same body without it: the same
    /// result, or the same error under the same status.</summary>
    /// <remarks>Measured before the fix (2026-11-10): after a good grant, a read answered 200 with
    /// <c>application/json; charset=x-no-such-charset</c> failed as <c>KeycloakAdminException(500)</c> "admin response body could
    /// not be decoded" — a 500 the server never sent — and an error status lost its message to the same words.</remarks>
    [Theory]
    [MemberData(nameof(JsonCharsetCases))]
    public async Task A_JSON_body_reads_the_same_whatever_charset_it_names(string charset, int status)
    {
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            var wrong = new List<string>();
            foreach (var (name, _, list, run) in Calls)
            {
                AnswerAdminAs(status, "application/json", list);
                var plain = await OutcomeAsync(() => run(admin));
                AnswerAdminAs(status, $"application/json; charset={charset}", list);
                var labelled = await OutcomeAsync(() => run(admin));
                if (labelled != plain)
                    wrong.Add($"{name}: {labelled} — want what the same body without a charset gives: {plain}");
            }
            Assert.True(wrong.Count == 0, $"[HTTP {status} · application/json; charset={charset}]\n" + string.Join("\n", wrong));
        }
    }

    /// <summary>The JSON label decides — <c>application/json</c> or an <c>application/*+json</c> type, in any case — and nothing
    /// else does: the same unknown charset on another type is still a body .NET cannot decode (the tests above).</summary>
    [Theory]
    [InlineData("application/problem+json", true)]
    [InlineData("APPLICATION/JSON", true)]
    [InlineData("application/xml", false)]
    [InlineData("text/json", false)]
    public async Task Only_a_JSON_label_makes_the_charset_irrelevant(string mediaType, bool readsAsJson)
    {
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            AnswerAdminAs(200, $"{mediaType}; charset=x-no-such-charset", list: false);
            var outcome = await OutcomeAsync(async () => await admin.Users.GetAsync("1"));
            Assert.Equal(readsAsJson ? "ok" : "KeycloakAdminException(500) \"admin response body could not be decoded\"",
                readsAsJson ? outcome[..2] : outcome);
        }
    }

    /// <summary>D2 reaches charsets .NET could decode as well: a UTF-8 body labelled ISO-8859-1 reads as the UTF-8 it is, on the
    /// typed and the raw path — .NET used to decode it as ISO-8859-1 ("JosÃ©").</summary>
    [Fact]
    public async Task A_UTF8_JSON_body_labelled_with_another_charset_reads_as_UTF8()
    {
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            _idp.ResetMappings();
            AnswerToken();
            _idp.Given(Request.Create().WithPath(new WildcardMatcher("/admin/*")).UsingGet()).RespondWith(
                Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json; charset=iso-8859-1")
                    .WithBody(Encoding.UTF8.GetBytes("""{"id":"1","username":"José","clientId":"José"}""")));

            Assert.Equal("José", (await admin.Users.GetAsync("1")).Username);
            Assert.Equal("José", (await admin.Clients.GetAsync("1")).ClientId);
        }
    }

    /// <summary>The rewrite happens where every admin response passes (<c>BearerHandler</c>), so a JSON response the <c>Raw</c>
    /// client hands back names <c>charset=utf-8</c> too — not the name the server sent. One with no charset gets none.</summary>
    [Fact]
    public async Task A_JSON_response_Raw_hands_back_has_its_charset_rewritten_too()
    {
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            AnswerAdminAs(200, "application/json; charset=x-no-such-charset", list: false);
            using (var labelled = await admin.Raw.GetUserWithResponseAsync("r", "1"))
            {
                Assert.Equal("application/json", labelled.Content.Headers.ContentType?.MediaType);
                Assert.Equal("utf-8", labelled.Content.Headers.ContentType?.CharSet);
            }
            AnswerAdminAs(200, "application/json", list: false);
            using var bare = await admin.Raw.GetUserWithResponseAsync("r", "1");
            Assert.Null(bare.Content.Headers.ContentType?.CharSet);
        }
    }

    public static IEnumerable<object[]> ForeignEncodingCases =>
        from charset in new[] { "utf-16", "iso-8859-1" }
        from status in new[] { 200, 400, 404 }
        select new object[] { charset, status };

    /// <summary>The other side of D2: a JSON body really encoded in a charset .NET used to decode (UTF-16, ISO-8859-1) is read as
    /// UTF-8, and so is undecodable — a read fails as the undecodable body, an error status keeps its status with the
    /// undecodable message, a write that reads no body succeeds. And nothing undecodable is quoted: no error carries U+0000,
    /// U+FFFD or the bytes a decoder refused.</summary>
    /// <remarks>Measured before the fix (2026-11-10, review leg and this test): a raw 404 in UTF-16 put the body, read as UTF-8,
    /// in the message — NULs between the letters; an ISO-8859-1 one put U+FFFD there, on the typed path too; a 200 in ISO-8859-1
    /// kept System.Text.Json's <c>DecoderFallbackException</c> in the chain, quoting the byte ("Unable to translate bytes [E9]
    /// at index …").</remarks>
    [Theory]
    [MemberData(nameof(ForeignEncodingCases))]
    public async Task A_JSON_body_really_in_another_charset_is_undecodable_and_quoted_nowhere(string charset, int status)
    {
        var encoding = Encoding.GetEncoding(charset);
        var (type, message) = status switch
        {
            404 => (typeof(KeycloakNotFoundException), Undecodable),
            200 => (typeof(KeycloakAdminException), "admin response body could not be decoded"),
            _ => (typeof(KeycloakAdminException), $"HTTP {status}: {Undecodable}"),
        };
        var (kc, admin) = await AdminAsync();
        using (kc)
        {
            var wrong = new List<string>();
            foreach (var (name, reads, list, run) in Calls)
            {
                _idp.ResetMappings();
                AnswerToken();
                // "id" holds the letter that is not ASCII: every representation decodes it — System.Text.Json skips a member the
                // type does not map without decoding it, so a bad byte only there goes unseen (measured: Realms.GetAsync,
                // Users.GetAsync).
                var body = list
                    ? """[{"id":"José","name":"José"}]"""
                    : """{"id":"José","name":"José","error":"José","errorMessage":"José"}""";
                _idp.Given(Request.Create().WithPath(new WildcardMatcher("/admin/*")).UsingAnyMethod()).RespondWith(
                    Response.Create().WithStatusCode(status)
                        .WithHeader("Content-Type", $"application/json; charset={charset}")
                        .WithHeader("Location", _idp.Urls[0] + "/admin/realms/r/things/new-id")
                        .WithBody(encoding.GetBytes(body)));
                var ex = await Record.ExceptionAsync(() => run(admin));
                if (status == 200 && !reads)
                {
                    if (ex is not null)
                        wrong.Add($"{name}: it reads no body, so it must succeed — got {Describe(ex)}");
                    continue;
                }
                if (ex?.GetType() != type || ((KeycloakAdminException)ex).StatusCode != (status == 200 ? 500 : status) || ex.Message != message)
                    wrong.Add($"{name}: {Describe(ex)} — want {type.Name}({(status == 200 ? 500 : status)}) \"{message}\"");
                var printed = ex?.ToString() ?? "";
                foreach (var (what, mark) in new[] { ("U+0000", "\0"), ("U+FFFD", "�"), ("a decoder's byte quote", "translate bytes") })
                {
                    if (printed.Contains(mark, StringComparison.Ordinal))
                        wrong.Add($"{name}: ToString() carries {what}");
                }
            }
            Assert.True(wrong.Count == 0, $"[HTTP {status} · body in {charset}, labelled so]\n" + string.Join("\n", wrong));
        }
    }

    /// <summary>A call's result as JSON, or its error by type, status and message.</summary>
    private static async Task<string> OutcomeAsync(Func<Task<object?>> run)
    {
        try { return "ok " + System.Text.Json.JsonSerializer.Serialize(await run()); }
        catch (Exception e) { return Describe(e); }
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
