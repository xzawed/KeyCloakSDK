using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using WireMock;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using WireMock.Types;
using WireMock.Util;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// <see cref="KeycloakAuthException.StatusCode"/> is the HTTP status of the response that made the call fail — on every lane,
/// at every status, a 3xx and a 2xx included — and null where no response decided the failure (registry
/// <c>dotnet-oauth-error-reason-phrase</c>, the owner's decision of 2026-11-27: add the status now, drop the reason phrase
/// <see cref="KeycloakAuthException.OAuthError"/> falls back to in the next major).
/// </summary>
/// <remarks>Each cell also pins the message its lane gives, so a row reaches the site it is written for: the error statuses
/// (the canonical reason · the 400 code · a 2xx other than 200), and a 200 whose body is unusable — not UTF-8, not JSON, a JSON
/// root that is no object, a non-string or undecodable <c>access_token</c>, none at all, no boolean <c>active</c>, a value
/// Duende cannot convert, an <c>error</c> member. The phrase <see cref="KeycloakAuthException.OAuthError"/> still carries is
/// pinned where it always was (<c>OAuthErrorCodeEchoTests</c> · <c>OAuthErrorCodeGrammarTests</c> ·
/// <c>TokenResponseClassTests</c>).</remarks>
[Trait("Category", "Unit")]
public sealed class AuthStatusCodeTests : IDisposable
{
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private const string Secret = "S3CR3T-status-9";
    private const string GoodToken = """{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":300}""";

    private readonly WireMockServer _idp = WireMockServer.Start();
    private readonly HttpClient _http = new();
    private volatile Cell? _cell;
    private volatile int _logoutStatus = 204;

    /// <summary>What the token and introspection endpoints answer, and what each lane must give for it. <c>{p}</c> in a
    /// message is the lane's failure prefix; a null token message means the token lanes succeed on that answer.</summary>
    private sealed record Cell(int Status, byte[] Token, byte[] Introspection, string? TokenMessage, string IntrospectionMessage);

    public AuthStatusCodeTests()
    {
        _idp.Given(Request.Create().UsingAnyMethod()).RespondWith(Response.Create().WithCallback(Answer));
    }

    public void Dispose()
    {
        _idp.Dispose();
        _http.Dispose();
    }

    private ResponseMessage Answer(IRequestMessage req)
    {
        if (req.Method == "POST" && req.Path == $"{Oidc}/logout")
            return Raw(_logoutStatus, Array.Empty<byte>());
        if (req.Method != "POST" || _cell is not { } cell)
            return Raw(404, Ascii("{}"));
        return req.Path == $"{Oidc}/token/introspect" ? Raw(cell.Status, cell.Introspection) : Raw(cell.Status, cell.Token);
    }

    private static ResponseMessage Raw(int status, byte[] body) => new()
    {
        StatusCode = status,
        Headers = new Dictionary<string, WireMockList<string>> { ["Content-Type"] = new("application/json") },
        BodyData = new BodyData { DetectedBodyType = BodyType.Bytes, BodyAsBytes = body },
    };

    private static byte[] Ascii(string s) => Encoding.ASCII.GetBytes(s);

    /// <summary>Text parts as ASCII, int parts as raw bytes — how a body that is not UTF-8 is written.</summary>
    private static byte[] Bytes(params object[] parts) => parts.SelectMany(p => p is string s ? Ascii(s) : new[] { (byte)(int)p }).ToArray();

    private static Cell Both(int status, string body, string tokenMessage, string introspectionMessage) =>
        new(status, Ascii(body), Ascii(body), tokenMessage, introspectionMessage);

    private static readonly byte[] Html = Ascii("<html><body><h1>Service Unavailable</h1></body></html>");

    private static readonly Dictionary<string, Cell> Cells = new(StringComparer.Ordinal)
    {
        // The error statuses — the four the registry line names (401 · 503 · 520 and the 400 code), a 500 that carries a code,
        // a 3xx (the SDK's client follows no redirect, so it is the answer) and a 2xx other than 200, which fails as a 400 with
        // that body does. The last two are the values below 400 that still mean a failure.
        ["400 invalid_grant"] = Both(400, """{"error":"invalid_grant"}""", "{p}: invalid_grant", "{p}: invalid_grant"),
        ["302 a redirect"] = Both(302, """{"error":"temporarily_unavailable"}""", "{p}: Found", "{p}: Found"),
        ["401 invalid_client"] = Both(401, """{"error":"invalid_client"}""", "{p}: Unauthorized", "{p}: Unauthorized"),
        ["500 server_error"] = Both(500, """{"error":"server_error"}""", "{p}: Internal Server Error", "{p}: Internal Server Error"),
        ["503 no code"] = Both(503, """{"message":"down"}""", "{p}: Service Unavailable", "{p}: Service Unavailable"),
        ["520 empty body"] = Both(520, "", "{p}: HTTP 520", "{p}: HTTP 520"),
        ["201 a usable answer"] = new(201, Ascii(GoodToken), Ascii("""{"active":true,"username":"svc"}"""),
            "{p}: error is missing", "{p}: error is missing"),
        // A body that arrived and could not be used — at 200 (the call still failed after a 200), and at 400 where the class
        // is the same, so the value is the status and no constant.
        ["200 not UTF-8"] = new(200,
            Bytes("""{"access_token":"AT-""", 0xFF, "\",\"token_type\":\"Bearer\",\"expires_in\":300}"),
            Bytes("""{"active":true,"username":"s""", 0xFF, "\"}"),
            "{p}: response is not valid UTF-8", "{p}: response is not valid UTF-8"),
        ["200 not JSON"] = new(200, Html, Html,
            "{p}: response body could not be parsed as JSON (HTTP 200)", "{p}: response body could not be parsed as JSON (HTTP 200)"),
        ["400 not JSON"] = new(400, Html, Html,
            "{p}: response body could not be parsed as JSON (HTTP 400)", "{p}: response body could not be parsed as JSON (HTTP 400)"),
        ["200 a JSON root that is no object"] = Both(200, """["x"]""",
            "{p}: response body is not a JSON object", "{p}: response body is not a decodable JSON object"),
        ["400 a JSON root that is no object"] = Both(400, """["x"]""",
            "{p}: response body is not a JSON object", "{p}: response body is not a decodable JSON object"),
        ["200 access_token a number"] = new(200,
            Ascii("""{"access_token":12345,"token_type":"Bearer","expires_in":300}"""), Ascii("""{"active":"true","username":"svc"}"""),
            "{p}: access_token is not a JSON string", "{p}: response has no boolean active"),
        ["200 no access_token"] = new(200,
            Ascii("""{"token_type":"Bearer","expires_in":300}"""), Ascii("""{"username":"svc"}"""),
            "token response missing access_token", "{p}: response has no boolean active"),
        ["200 an unpaired surrogate escape"] = new(200,
            Ascii("""{"access_token":"\ud800","token_type":"Bearer","expires_in":300}"""), Ascii("""{"active":true,"username":"\ud800"}"""),
            "{p}: access_token holds an unpaired surrogate escape", "{p}: response body is not a decodable JSON object"),
        // Introspection only — a token response does not read exp, so this answer is a usable token.
        ["200 exp a word"] = new(200, Ascii(GoodToken), Ascii("""{"active":true,"exp":"soon","username":"svc"}"""),
            null, "{p}: response body holds a value that could not be converted (HTTP 200)"),
        ["200 an error member"] = new(200,
            Ascii("""{"error":"invalid_grant","access_token":"AT-ok-token","token_type":"Bearer","expires_in":300}"""),
            Ascii("""{"error":"invalid_token","active":true}"""),
            "{p}: invalid_grant", "{p}: invalid_token"),
    };

    private delegate Task Call(KeycloakClient kc);

    /// <summary>Every lane that reads a token or introspection response, with its failure prefix. The provider and the admin
    /// facade's own grant end in the client-credentials grant's error unchanged.</summary>
    private static readonly Dictionary<string, (bool Introspection, string Prefix, Call Run)> Lanes = new(StringComparer.Ordinal)
    {
        ["ClientCredentialsTokenAsync"] = (false, "Client credentials grant failed", kc => kc.Auth.ClientCredentialsTokenAsync()),
        ["RefreshAsync"] = (false, "Token refresh failed", kc => kc.Auth.RefreshAsync("rt-sent")),
        ["ExchangeCodeAsync"] = (false, "Authorization code exchange failed",
            kc => kc.Auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43))),
        ["IntrospectAsync"] = (true, "Token introspection failed", kc => kc.Auth.IntrospectAsync("tok-sent")),
        ["ClientCredentialsTokenProvider"] = (false, "Client credentials grant failed",
            kc => new ClientCredentialsTokenProvider(kc.Auth).GetAccessTokenAsync()),
        ["AdminAsync"] = (false, "Client credentials grant failed", async kc => await kc.AdminAsync()),
    };

    public static IEnumerable<object[]> LaneNames => Lanes.Keys.Select(k => new object[] { k });

    private KeycloakClient Client() =>
        KeycloakClient.Create(new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = Secret });

    /// <summary>One row per lane: every answer that fails it gives a <see cref="KeycloakAuthException"/> whose
    /// <see cref="KeycloakAuthException.StatusCode"/> is the status the IdP answered, with the message of the site that
    /// refused it.</summary>
    [Theory]
    [MemberData(nameof(LaneNames))]
    public async Task StatusCode_is_the_status_of_the_response_that_failed_the_call(string lane)
    {
        var (introspection, prefix, run) = Lanes[lane];
        var wrong = new List<string>();
        foreach (var (name, cell) in Cells)
        {
            var want = introspection ? cell.IntrospectionMessage : cell.TokenMessage;
            if (want is null)
                continue;
            want = want.Replace("{p}", prefix, StringComparison.Ordinal);
            _cell = cell;
            using var kc = Client();
            var ex = await Record.ExceptionAsync(() => run(kc));
            if (ex is not KeycloakAuthException e || e.StatusCode != cell.Status || e.Message != want)
                wrong.Add($"{name}: {Describe(ex)} — want KeycloakAuthException StatusCode={cell.Status} \"{want}\"");
        }
        Assert.True(wrong.Count == 0, $"[{lane}]\n" + string.Join("\n", wrong));
    }

    /// <summary>Logout fails on any status but 204, and its error carries that status.</summary>
    [Theory]
    [InlineData(200)]
    [InlineData(302)]
    [InlineData(400)]
    [InlineData(500)]
    [InlineData(503)]
    public async Task A_refused_logout_carries_its_status(int status)
    {
        _logoutStatus = status;
        using var kc = Client();
        var e = Assert.IsType<KeycloakAuthException>(await Record.ExceptionAsync(() => kc.Auth.LogoutAsync("rt-sent")));
        Assert.Equal($"Logout failed (HTTP {status})", e.Message);
        Assert.Equal(status, e.StatusCode);
    }

    // ── null: no response decided the failure ──

    private const string Nonce = "expected-nonce";

    /// <summary>An AuthClient whose id_token check trusts <paramref name="key"/> alone — no discovery or JWKS request.</summary>
    private AuthClient WithKey(SecurityKey key, out string issuer)
    {
        var cfg = new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = Secret }.Normalized();
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        issuer = ep.Issuer;
        var tvp = JwtValidator.BuildParameters(ep.Issuer, new JwtValidatorOptions { Issuer = ep.Issuer, Audiences = new[] { "c" } });
        tvp.IssuerSigningKey = key;
        tvp.ConfigurationManager = null;
        return new AuthClient(cfg, ep, new JwtValidator(tvp), _http);
    }

    private static string IdToken(string issuer, string nonce, SecurityKey key)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var payload = $$"""{"iss":"{{issuer}}","sub":"u","aud":"c","azp":"c","nonce":"{{nonce}}","typ":"ID","exp":{{now + 300}},"iat":{{now}}}""";
        return new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }
            .CreateToken(payload, new SigningCredentials(key, SecurityAlgorithms.RsaSha256));
    }

    /// <summary>The token endpoint answers 200 with a usable token and, when given, <paramref name="idToken"/>.</summary>
    private void TokenAnswer(string? idToken)
    {
        var body = idToken is null ? GoodToken : GoodToken.TrimEnd('}') + $$""","id_token":"{{idToken}}"}""";
        _cell = new Cell(200, Ascii(body), Ascii("{}"), null, "");
    }

    /// <summary>The id_token checks run on a token response the exchange accepted (200): what fails the call is the SDK's own
    /// check, not that response — so no status. Each row is pinned to its check by the message.</summary>
    [Theory]
    [InlineData("id_token missing for nonce validation")]
    [InlineData("id_token validation failed")]
    [InlineData("id_token nonce mismatch")]
    public async Task An_id_token_check_carries_no_status(string message)
    {
        var key = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        var auth = WithKey(key, out var issuer);
        TokenAnswer(message switch
        {
            "id_token missing for nonce validation" => null,
            "id_token validation failed" => IdToken(issuer, Nonce, new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" }),
            _ => IdToken(issuer, "another-nonce", key),
        });
        var e = await Assert.ThrowsAsync<KeycloakAuthException>(() => auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43), Nonce));
        Assert.Equal(message, e.Message);
        Assert.Null(e.StatusCode);
    }

    /// <summary>A 200 whose token the admin facade could not send: the grant returns it, the provider refuses it before any
    /// admin request — its own check, so no status.</summary>
    [Fact]
    public async Task A_token_the_provider_refuses_carries_no_status()
    {
        _cell = new Cell(200, Ascii("""{"access_token":"AT with a space","token_type":"Bearer","expires_in":300}"""), Ascii("{}"), null, "");
        using var kc = Client();
        Assert.Equal("AT with a space", (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken); // the control: the grant hands it out
        var e = await Assert.ThrowsAsync<KeycloakAuthException>(() => new ClientCredentialsTokenProvider(kc.Auth).GetAccessTokenAsync());
        Assert.Equal(BearerToken.GrantRefused, e.Message);
        Assert.Null(e.StatusCode);
    }

    /// <summary><see cref="TokenSet.Create"/> called by the consumer's own code read no response.</summary>
    [Fact]
    public void TokenSet_Create_called_directly_carries_no_status()
    {
        var e = Assert.Throws<KeycloakAuthException>(() => TokenSet.Create("", "Bearer", 60, null, null, null, 0));
        Assert.Equal("token response missing access_token", e.Message);
        Assert.Null(e.StatusCode);
    }

    private static string Describe(Exception? ex) => ex switch
    {
        null => "no exception",
        KeycloakAuthException k => $"KeycloakAuthException StatusCode={k.StatusCode?.ToString(CultureInfo.InvariantCulture) ?? "null"} \"{k.Message}\"",
        _ => $"{ex.GetType().FullName} \"{ex.Message}\"",
    };
}
