using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using WireMock;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using WireMock.Types;
using WireMock.Util;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// The OAuth <c>error</c> code an SDK error carries is a code, never a value the request sent (registry
/// <c>token-error-code-secret-echo</c> · <c>oauth-error-field-echo-unmasked</c>).
/// </summary>
/// <remarks>The IdP's <c>error</c> is response body too. An endpoint (or a proxy) that echoes what the request sent puts the
/// client secret, the refresh token or the introspected token there — and the lanes put any value in the RFC 6749 grammar,
/// a Keycloak-style secret or a JWT included, into <c>Message</c>, <c>ToString()</c> and <c>OAuthError</c> (measured on main
/// a7d0fdf3). One rule now (<c>OAuthErrorCode</c>): <c>[a-z_]{1,64}</c> and overlapping no non-empty secret the request
/// sent — neither contains the other, so a truncated or extended echo is withheld too. The price is pinned below: a secret
/// that is a piece of a registered code (<c>client</c>) withholds that code.</remarks>
[Trait("Category", "Unit")]
public sealed class OAuthErrorCodeEchoTests : IDisposable
{
    private const string Secret = "echoedlowersecret"; // code-shaped on purpose: the shape alone cannot withhold it
    private const string Refresh = "echoedlowerrefresh";
    private const string Token = "echoedlowerintrospected";
    private const string Code = "echoedlowercode";
    private static readonly string Verifier = "echoedlowerverifierechoedlowerverifierechoedlower";

    private readonly WireMockServer _idp = WireMockServer.Start();
    private readonly ConcurrentQueue<Dictionary<string, string>> _sent = new();
    private Func<Dictionary<string, string>, object?> _error = _ => "invalid_request";

    public OAuthErrorCodeEchoTests()
    {
        _idp.Given(Request.Create().UsingPost()).RespondWith(Response.Create().WithCallback(Handle));
    }

    public void Dispose() => _idp.Dispose();

    private ResponseMessage Handle(IRequestMessage req)
    {
        var sent = (req.Body ?? "").Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Split('=', 2))
            .ToDictionary(p => Uri.UnescapeDataString(p[0].Replace('+', ' ')),
                p => p.Length > 1 ? Uri.UnescapeDataString(p[1].Replace('+', ' ')) : "", StringComparer.Ordinal);
        if (req.Headers is { } headers && headers.TryGetValue("Authorization", out var auth)
            && auth.FirstOrDefault() is { } basic && basic.StartsWith("Basic ", StringComparison.Ordinal))
        {
            var pair = Encoding.UTF8.GetString(Convert.FromBase64String(basic["Basic ".Length..])).Split(':', 2);
            sent["client_secret"] = Uri.UnescapeDataString(pair[1].Replace('+', ' '));
        }
        _sent.Enqueue(sent);
        var body = JsonSerializer.Serialize(new Dictionary<string, object?> { ["error"] = _error(sent) });
        return new ResponseMessage
        {
            StatusCode = 400,
            Headers = new Dictionary<string, WireMockList<string>> { ["Content-Type"] = new("application/json") },
            BodyData = new BodyData { DetectedBodyType = BodyType.String, BodyAsString = body, Encoding = Encoding.UTF8 },
        };
    }

    private delegate Task Call(KeycloakClient kc);

    /// <summary>Every surface that reads the OAuth <c>error</c>, with the secret form fields it sends besides the client secret.</summary>
    private static readonly Dictionary<string, (string[] Params, Call Run)> Surfaces = new(StringComparer.Ordinal)
    {
        ["ClientCredentialsTokenAsync"] = (Array.Empty<string>(), kc => kc.Auth.ClientCredentialsTokenAsync()),
        ["RefreshAsync"] = (new[] { "refresh_token" }, kc => kc.Auth.RefreshAsync(Refresh)),
        ["ExchangeCodeAsync"] = (new[] { "code", "code_verifier" }, kc => kc.Auth.ExchangeCodeAsync(Code, "https://app/cb", Verifier)),
        ["IntrospectAsync"] = (new[] { "token" }, kc => kc.Auth.IntrospectAsync(Token)),
        ["ClientCredentialsTokenProvider"] = (Array.Empty<string>(), kc => new ClientCredentialsTokenProvider(kc.Auth).GetAccessTokenAsync()),
        ["admin"] = (Array.Empty<string>(), async kc => await (await kc.AdminAsync()).Users.GetAsync("u1")),
    };

    public static IEnumerable<object[]> SurfaceNames => Surfaces.Keys.Select(k => new object[] { k });

    private static readonly (string Name, Func<string, string> Shape)[] EchoForms =
    {
        ("whole", v => v),
        ("truncated", v => v[..11]),
        ("extended", v => v + "_x"),
    };

    private async Task<KeycloakAuthException> Fail(string surface, string? secret = Secret)
    {
        while (_sent.TryDequeue(out _)) { }
        using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = secret });
        var ex = await Record.ExceptionAsync(() => Surfaces[surface].Run(kc));
        return Assert.IsType<KeycloakAuthException>(ex);
    }

    private Dictionary<string, string> FirstSent() => Assert.Single(_sent.Take(1));

    private static IEnumerable<string> Renderings(Exception e)
    {
        yield return e.ToString();
        for (var x = e; x is not null; x = x.InnerException)
        {
            yield return x.Message;
            foreach (var p in x.GetType().GetProperties().Where(p => p.DeclaringType?.Namespace?.StartsWith("System", StringComparison.Ordinal) != true))
                yield return p.GetValue(x)?.ToString() ?? "";
        }
    }

    private static void AssertWithheld(string label, KeycloakAuthException e, string value)
    {
        Assert.True(e.OAuthError is null, $"{label}: OAuthError = {e.OAuthError}");
        foreach (var text in Renderings(e))
            Assert.False(text.Contains(value, StringComparison.Ordinal), $"{label}: a rendering shows {value}: {text}");
    }

    [Theory]
    [MemberData(nameof(SurfaceNames))]
    public async Task An_echoed_client_secret_is_never_carried(string surface)
    {
        foreach (var (form, shape) in EchoForms)
        {
            _error = sent => shape(sent.GetValueOrDefault("client_secret", ""));
            var e = await Fail(surface);
            Assert.Equal(Secret, FirstSent().GetValueOrDefault("client_secret"));
            AssertWithheld($"{surface} · {form}", e, shape(Secret));
        }
    }

    [Theory]
    [MemberData(nameof(SurfaceNames))]
    public async Task An_echoed_grant_value_is_never_carried(string surface)
    {
        foreach (var param in Surfaces[surface].Params)
        {
            foreach (var (form, shape) in EchoForms)
            {
                _error = sent => shape(sent.GetValueOrDefault(param, ""));
                var e = await Fail(surface);
                AssertWithheld($"{surface} · {param} · {form}", e, shape(FirstSent()[param]));
            }
        }
    }

    [Fact]
    public async Task A_public_client_withholds_its_echoed_refresh_token_and_still_gets_a_code()
    {
        _error = sent => sent.GetValueOrDefault("refresh_token", "");
        AssertWithheld("public · echo", await Fail("RefreshAsync", secret: null), Refresh);
        Assert.True(string.IsNullOrEmpty(FirstSent().GetValueOrDefault("client_secret")));
        _error = _ => "invalid_grant";
        Assert.Equal("invalid_grant", (await Fail("RefreshAsync", secret: null)).OAuthError);
    }

    public static IEnumerable<object[]> NotACode =>
        Surfaces.Keys.SelectMany(s => new object[][]
        {
            new object[] { s, "Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5" },
            new object[] { s, "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl" },
            new object[] { s, "Invalid_client" },
            new object[] { s, "invalid client" },
            new object[] { s, "invalid_client2" },
            new object[] { s, new string('a', 65) },
        });

    [Theory]
    [MemberData(nameof(NotACode))]
    public async Task A_value_that_is_not_a_code_is_never_carried(string surface, string value)
    {
        _error = _ => value;
        AssertWithheld($"{surface} · {value}", await Fail(surface), value);
    }

    public static IEnumerable<object[]> Codes =>
        Surfaces.Keys.SelectMany(s => new[] { "invalid_client", "invalid_grant", "slow_down", new string('a', 64) }
            .Select(c => new object[] { s, c }));

    [Theory]
    [MemberData(nameof(Codes))]
    public async Task A_code_that_overlaps_nothing_sent_is_carried(string surface, string code)
    {
        _error = _ => code;
        var e = await Fail(surface);
        Assert.Equal(code, e.OAuthError);
        Assert.EndsWith(": " + code, e.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("ClientCredentialsTokenAsync")]
    [InlineData("ClientCredentialsTokenProvider")]
    [InlineData("admin")]
    public async Task The_price_a_secret_that_is_a_piece_of_the_code_withholds_it(string surface)
    {
        _error = _ => "invalid_client";
        Assert.Null((await Fail(surface, secret: "client")).OAuthError);
    }
}
