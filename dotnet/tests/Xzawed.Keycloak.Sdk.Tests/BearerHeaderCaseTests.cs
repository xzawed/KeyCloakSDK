using System.Text.Json;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xunit.Abstractions;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// The header-case probe, kept as a test: a token the IdP hands out that cannot travel as a header value — CR, LF, NUL,
/// DEL, a character past ASCII, or one longer than the server takes — ends every call that sends it in an SDK error, and
/// no SDK error carries the access token, the refresh token or the client secret in its message, cause chain or stack.
/// </summary>
/// <remarks>
/// <para>Measured before the fix (2026-10-05): a bearer holding LF, CR or CRLF let a raw <c>System.FormatException</c>
/// ("New-line characters are not allowed in header values.") out of every admin call — raw REST, the typed client and an
/// admin built on a consumer <see cref="ITokenProvider"/> — thrown by <c>new AuthenticationHeaderValue</c> in
/// <c>BearerHandler</c>. It quoted no part of the token. NUL and DEL went out on the wire (the server refused them with
/// 400); a character past ASCII was refused by .NET ("Request headers must contain only ASCII characters.") and was
/// already an SDK error; a 70,000-byte bearer drew a 431. Introspection, refresh and logout carry the token in a
/// form-encoded body, so every variant went through them.</para>
/// <para>Node measured the opposite on the leak axis — its raw <c>TypeError</c> quoted the whole bearer — which is why
/// every rendering is searched here, not only the type.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class BearerHeaderCaseTests : IDisposable
{
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private const string Secret = "HC-SECRET-canary-7f3a";
    private const string LineBreakMessage = "admin request failed: the access token holds a CR or LF, which an HTTP header cannot carry";

    private readonly WireMockServer _idp = WireMockServer.Start();
    private readonly ITestOutputHelper _out;

    public BearerHeaderCaseTests(ITestOutputHelper output) => _out = output;

    public void Dispose() => _idp.Dispose();

    /// <summary>The hostile character of each variant (<c>long</c>: a 70,000-byte token, over Kestrel's 32 KiB header
    /// limit here and over Keycloak's 65,459-byte bearer limit).</summary>
    public static IEnumerable<object[]> Variants => new[]
    {
        new object[] { "lf", C(0x0A) }, new object[] { "cr", C(0x0D) }, new object[] { "crlf", C(0x0D) + C(0x0A) },
        new object[] { "nul", C(0x00) }, new object[] { "del", C(0x7F) }, new object[] { "e9", C(0xE9) },
        new object[] { "u100", C(0x100) }, new object[] { "u2028", C(0x2028) }, new object[] { "long", "" },
    };

    /// <summary>One UTF-16 code unit — built, so no editor turns an escape into the character (U+2028 would end the line).</summary>
    private static string C(int codeUnit) => ((char)codeUnit).ToString();

    private static string Hostile(string kind, string v, string ch) => v == "long"
        ? $"HC{kind}LONG" + new string('x', 70_000 - 8)
        : $"HC{kind}-{v}-head{ch}tail-{v}-HCend";

    [Theory]
    [MemberData(nameof(Variants))]
    public async Task A_token_that_cannot_travel_as_a_header_ends_in_an_sdk_error_that_does_not_carry_it(string v, string ch)
    {
        var at = Hostile("AT", v, ch);
        var rt = Hostile("RT", v, ch);
        _idp.Given(Request.Create().WithPath($"{Oidc}/token").UsingPost()).RespondWith(Response.Create().WithStatusCode(200)
            .WithHeader("Content-Type", "application/json")
            .WithBody(JsonSerializer.Serialize(new { access_token = at, token_type = "Bearer", expires_in = 300, refresh_token = rt })));
        _idp.Given(Request.Create().WithPath($"{Oidc}/token/introspect").UsingPost()).RespondWith(Response.Create().WithStatusCode(200)
            .WithHeader("Content-Type", "application/json").WithBody("""{"active":true,"sub":"u1"}"""));
        _idp.Given(Request.Create().WithPath($"{Oidc}/logout").UsingPost()).RespondWith(Response.Create().WithStatusCode(204));
        foreach (var path in new[] { "/admin/realms", "/admin/realms/r/users" })
        {
            _idp.Given(Request.Create().WithPath(path).UsingGet()).RespondWith(Response.Create().WithStatusCode(200)
                .WithHeader("Content-Type", "application/json").WithBody("[]"));
        }

        var cfg = new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = Secret };
        await using var kc = KeycloakClient.Create(cfg);
        Assert.Equal(at, (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken); // the token is handed out as it came
        var admin = await kc.AdminAsync();
        await using var consumerBuilt = await AdminClient.CreateAsync(cfg.Normalized(), new Fixed(at));

        var outcomes = new List<(string Call, Exception? Error)>
        {
            ("admin Realms.ListAsync (raw)", await Record.ExceptionAsync(() => admin.Realms.ListAsync())),
            ("admin Users.SearchAsync (typed)", await Record.ExceptionAsync(() => admin.Users.SearchAsync(null))),
            ("consumer-provider admin Realms.ListAsync", await Record.ExceptionAsync(() => consumerBuilt.Realms.ListAsync())),
            ("IntrospectAsync(at)", await Record.ExceptionAsync(() => kc.Auth.IntrospectAsync(at))),
            ("RefreshAsync(rt)", await Record.ExceptionAsync(() => kc.Auth.RefreshAsync(rt))),
            ("LogoutAsync(rt)", await Record.ExceptionAsync(() => kc.Auth.LogoutAsync(rt))),
            ("ValidateAsync(at)", await Record.ExceptionAsync(() => kc.Auth.ValidateAsync(at))),
        };

        var needles = v == "long"
            ? new[] { at, rt, Secret, at[..16], rt[..16] }
            : new[] { at, rt, Secret, $"HCAT-{v}-head", $"tail-{v}-HCend", $"HCRT-{v}-head" };
        var wrong = new List<string>();
        foreach (var (call, error) in outcomes)
        {
            _out.WriteLine($"{v} {call}: {(error is null ? "ok" : $"{error.GetType().Name}: {error.Message}")}");
            if (error is null)
                continue;
            if (error is not KeycloakException)
                wrong.Add($"{call}: raw {error.GetType().FullName} escaped the SDK");
            foreach (var text in Renderings(error))
            {
                if (needles.FirstOrDefault(n => text.Contains(n, StringComparison.Ordinal)) is { } hit)
                    wrong.Add($"{call}: {error.GetType().Name} carries a secret ({hit[..Math.Min(hit.Length, 16)]}…)");
            }
        }
        // A form-encoded body carries any token: these three must succeed.
        foreach (var call in new[] { "IntrospectAsync(at)", "RefreshAsync(rt)", "LogoutAsync(rt)" })
        {
            if (outcomes.Single(o => o.Call == call).Error is { } e)
                wrong.Add($"{call}: failed ({e.GetType().Name}: {e.Message}) — the token travels in the form body");
        }
        // CR or LF: refused before anything is sent, with a message that says why.
        if (ch.Contains('\r') || ch.Contains('\n'))
        {
            foreach (var (call, error) in outcomes.Where(o => o.Call.Contains("admin", StringComparison.Ordinal)))
            {
                if (error is not KeycloakTransportException || error.Message != LineBreakMessage)
                    wrong.Add($"{call}: {error?.GetType().Name ?? "no exception"} \"{error?.Message}\" — want KeycloakTransportException \"{LineBreakMessage}\"");
            }
            Assert.DoesNotContain(_idp.LogEntries, e => e.RequestMessage?.Path?.StartsWith("/admin/", StringComparison.Ordinal) == true);
        }
        Assert.True(wrong.Count == 0, $"[{v}]\n" + string.Join("\n", wrong));
    }

    /// <summary>Every text a logger may print for an exception: <c>ToString()</c> (message, cause chain, stack), each
    /// message and stack in the chain, and an SDK error's <c>OAuthError</c>.</summary>
    internal static IEnumerable<string> Renderings(Exception error)
    {
        yield return error.ToString();
        for (var e = error; e is not null; e = e.InnerException)
        {
            yield return e.Message;
            yield return e.StackTrace ?? "";
        }
        if (error is KeycloakAuthException { OAuthError: { } code })
            yield return code;
    }

    private sealed class Fixed(string token) : ITokenProvider
    {
        public Task<string> GetAccessTokenAsync(CancellationToken ct = default) => Task.FromResult(token);
    }
}
