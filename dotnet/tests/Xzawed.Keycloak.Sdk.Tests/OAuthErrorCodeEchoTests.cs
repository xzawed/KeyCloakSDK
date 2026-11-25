using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.Json;
using WireMock;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using WireMock.Types;
using WireMock.Util;
using Xunit;
using Xunit.Abstractions;

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
    // Code-shaped on purpose (the shape alone cannot withhold them), and no two share a piece — an echo of one value must
    // be withheld by comparing against THAT value, not a sibling's prefix.
    private const string Secret = "zebrasecretjk";
    private const string Refresh = "yakrefreshvq";
    private const string Token = "walrustokenpx";
    private const string Code = "vulturecodeby";
    private static readonly string Verifier = string.Concat(Enumerable.Repeat("ocelotverifier", 3)) + "xx";

    private readonly WireMockServer _idp = WireMockServer.Start();
    private readonly ConcurrentQueue<Dictionary<string, string>> _sent = new();
    private Func<Dictionary<string, string>, object?> _error = _ => "invalid_request";
    private int _status = 400;
    /// <summary>When set, the whole answer body instead of <c>{"error": …}</c>.</summary>
    private string? _raw;
    /// <summary>When set, a <c>Location</c> header on the answer.</summary>
    private string? _location;
    private readonly ITestOutputHelper _output;

    /// <summary>Where the 3xx cells point <c>Location</c> (this server, same origin) — a client that follows it shows up in
    /// the request log.</summary>
    private const string RedirectTarget = "/redirect-target";

    public OAuthErrorCodeEchoTests(ITestOutputHelper output)
    {
        _output = output;
        _idp.Given(Request.Create().WithPath(RedirectTarget).UsingAnyMethod()).AtPriority(1).RespondWith(Response.Create()
            .WithStatusCode(400).WithHeader("Content-Type", "application/json").WithBody("{\"error\":\"redirect_target_reached\"}"));
        _idp.Given(Request.Create().UsingPost()).AtPriority(10).RespondWith(Response.Create().WithCallback(Handle));
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
        var body = _raw ?? JsonSerializer.Serialize(new Dictionary<string, object?> { ["error"] = _error(sent) });
        var answerHeaders = new Dictionary<string, WireMockList<string>> { ["Content-Type"] = new("application/json") };
        if (_location is { } location)
            answerHeaders["Location"] = new(location);
        return new ResponseMessage
        {
            StatusCode = _status,
            Headers = answerHeaders,
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

    /// <summary>Every piece and every padding, so each direction of the overlap is pinned (the code inside the value · the
    /// value inside the code).</summary>
    private static readonly (string Name, Func<string, string> Shape)[] EchoForms =
    {
        ("whole", v => v),
        ("prefix", v => v[..11]),
        ("suffix", v => v[^11..]),
        ("middle", v => v[2..11]),
        ("extended", v => v + "_x"),
        ("prefixed", v => "x_" + v),
        ("wrapped", v => "x_" + v + "_x"),
    };

    /// <summary>Keycloak answers a bad client with 401, not 400 — and here every error status but 400 takes a branch of its
    /// own (the canonical reason as the message, <c>OAuthError</c> from the same rule or that reason).</summary>
    [Theory]
    [MemberData(nameof(SurfaceNames))]
    public async Task An_echo_on_a_401_is_never_carried(string surface)
    {
        _status = 401;
        foreach (var param in Surfaces[surface].Params.Prepend("client_secret"))
        {
            _error = sent => sent.GetValueOrDefault(param, "");
            var e = await Fail(surface);
            var value = FirstSent()[param];
            Assert.Equal("Unauthorized", e.OAuthError); // the reason phrase, never the echoed value
            foreach (var text in Renderings(e))
                Assert.False(text.Contains(value, StringComparison.Ordinal), $"{surface} · 401 · {param}: {text}");
        }
    }

    /// <summary>An empty value sent is not compared — the empty string is a piece of every code.</summary>
    [Fact]
    public async Task An_empty_grant_value_is_not_compared()
    {
        _error = _ => "invalid_grant";
        using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = Secret });
        var e = Assert.IsType<KeycloakAuthException>(
            await Record.ExceptionAsync(() => kc.Auth.ExchangeCodeAsync(Code, "https://app/cb", "")));
        Assert.Equal("invalid_grant", e.OAuthError);
    }

    /// <summary><c>OAuthErrorCode.Carried</c> itself — each direction of the overlap, every position in <c>sent</c>, and the
    /// absent or empty secret that must not be compared.</summary>
    [Theory]
    [InlineData("invalid_grant", new[] { "s3cret-Value" }, "invalid_grant")]
    [InlineData("mysecret", new[] { "mysecret" }, null)]
    [InlineData("mysecret_x", new[] { "mysecret" }, null)]
    [InlineData("x_mysecret", new[] { "mysecret" }, null)]
    [InlineData("mysec", new[] { "mysecret" }, null)]
    [InlineData("secret", new[] { "mysecret" }, null)]
    [InlineData("yse", new[] { "mysecret" }, null)]
    [InlineData("fresh", new[] { "zzz", "myrefresh" }, null)]
    [InlineData("x_myrefresh", new[] { "zzz", "myrefresh" }, null)]
    [InlineData("invalid_grant", new[] { "", null }, "invalid_grant")]
    [InlineData("invalid_client", new[] { "client" }, null)]
    [InlineData("Invalid_grant", new string[0], null)]
    [InlineData("invalid_grant2", new string[0], null)]
    public void Carried_is_code_shaped_and_overlaps_nothing_sent(string value, string?[] sent, string? expected) =>
        Assert.Equal(expected, OAuthErrorCode.Carried(value, sent));

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

    /// <summary>An IdP or proxy that echoes the secret lowercased — the overlap ignores ASCII case.</summary>
    [Theory]
    [MemberData(nameof(SurfaceNames))]
    public async Task A_lowercased_echo_of_the_client_secret_is_never_carried(string surface)
    {
        _error = sent => sent.GetValueOrDefault("client_secret", "").ToLowerInvariant();
        var e = await Fail(surface, secret: "EchoMixedCase");
        Assert.Equal("EchoMixedCase", FirstSent().GetValueOrDefault("client_secret"));
        AssertWithheld($"{surface} · lowercased", e, "echomixedcase");
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

    // The OAuth `error` at a 3xx and a 5xx (registry node-5xx-oauth-error-code-empty). The contract puts it in the code field
    // "at any status"; that was measured at 400 · 401 (#1199) and the other 2xx (#1207) only. Pinned as the contract reads at
    // 500 · 503 and at 302 (Location on this server — a 3xx is an error status too), which is never followed.
    private const string B5 = "{\"error\":\"temporarily_unavailable\",\"error_description\":\"down\"}";
    private const string NoError = "{\"message\":\"down\"}";

    /// <summary>One surface on a new client at one status and body: <c>OAuthError</c> (null when not an auth error), one
    /// line, and every request the IdP saw.</summary>
    private async Task<(string? Code, string Line, string[] Requests)> ErrorStatusCell(string surface, int status, string body,
        string? location = null)
    {
        _status = status;
        _raw = body;
        _location = location;
        while (_sent.TryDequeue(out _)) { }
        _idp.ResetLogEntries();
        using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = Secret });
        var ex = await Record.ExceptionAsync(() => Surfaces[surface].Run(kc));
        var requests = _idp.LogEntries.Select(e => $"{e.RequestMessage?.Method} {e.RequestMessage?.Path}").ToArray();
        var code = (ex as KeycloakAuthException)?.OAuthError;
        var outcome = ex is null
            ? "success"
            : $"{ex.GetType().Name}({ex.Message}) code={(ex is KeycloakAuthException ? code ?? "null" : "-")}";
        return (code, $"{status} {surface} → {outcome} requests=[{string.Join(", ", requests)}]", requests);
    }

    public static IEnumerable<object[]> ServerErrorCells =>
        Surfaces.Keys.SelectMany(s => new[] { 500, 503 }.Select(status => new object[] { s, status }));

    [Theory]
    [MemberData(nameof(ServerErrorCells))]
    public async Task A_server_error_status_carries_the_OAuth_error(string surface, int status)
    {
        var cell = await ErrorStatusCell(surface, status, B5);
        _output.WriteLine(cell.Line);
        Assert.True(cell.Code == "temporarily_unavailable", cell.Line);
    }

    /// <summary>Controls: the same body at 400 carries it; a 503 whose body names no <c>error</c> carries no code — .NET puts
    /// the reason phrase there (registry <c>dotnet-oauth-error-reason-phrase</c>, as the 401 cells above pin).</summary>
    [Theory]
    [MemberData(nameof(SurfaceNames))]
    public async Task The_error_status_controls_carry_it_at_400_and_no_code_without_one(string surface)
    {
        var at400 = await ErrorStatusCell(surface, 400, B5);
        var none = await ErrorStatusCell(surface, 503, NoError);
        _output.WriteLine(at400.Line);
        _output.WriteLine(none.Line);
        Assert.True(at400.Code == "temporarily_unavailable", at400.Line);
        Assert.True(none.Code == "Service Unavailable", none.Line);
    }

    [Theory]
    [MemberData(nameof(SurfaceNames))]
    public async Task A_redirect_error_status_carries_the_OAuth_error_and_is_never_followed(string surface)
    {
        var cell = await ErrorStatusCell(surface, 302, B5, _idp.Urls[0] + RedirectTarget);
        _output.WriteLine(cell.Line);
        Assert.False(cell.Requests.Any(r => r.EndsWith(" " + RedirectTarget, StringComparison.Ordinal)), cell.Line);
        Assert.True(cell.Code == "temporarily_unavailable", cell.Line);
    }

    // ---- Residual divergences (registry token-response-residual-divergence) ----
    // The targets, per lane × cell: (A) a 200 whose `error` is present and neither null nor "" fails like a 400 carrying
    // it — the lane's error class, no code unless a string the echo filter lets through, nothing in the body used (A1–A4 ·
    // B2); null and "" still succeed (A5 · A6). (C) a 2xx other than 200 gets the verdict the lane gives a 400 with the same
    // body — class and code; the message may differ only by the status number (C1 ~ C2 · C3 ~ C4). Never asserted: which
    // duplicated `error` an error status echoes (B1 · B3 · B4 — RFC 8259 §4 leaves it open) and B5 (a 200 whose duplicated
    // `error` is a code, then "" — a parser differential the registry holds; its outcome class is written). The fake
    // answers with the cell's exact bytes — no serializer, so a duplicated key and an invalid UTF-8 sequence survive (a
    // plain HttpClient reads them back first).

    private sealed record ResidualCell(string Name, int Status, byte[] TokenBody, byte[] IntrospectionBody);

    private const string ResidualTokenMembers = "\"access_token\":\"AT-ok\",\"token_type\":\"Bearer\",\"expires_in\":300";

    private static byte[] Ascii(string s) => Encoding.ASCII.GetBytes(s);

    private static ResidualCell ErrorValueCell(string name, string x) =>
        new(name, 200, Ascii("{" + ResidualTokenMembers + ",\"error\":" + x + "}"),
            Ascii("{\"active\":true,\"username\":\"svc\",\"error\":" + x + "}"));

    private static ResidualCell BothLanesCell(string name, int status, byte[] body) => new(name, status, body, body);

    // `{"error":"invalid_grant","error_description":"` + 0xC3 0x28 + `"}` — 0xC3 opens a two-byte sequence, 0x28 cannot end it.
    private static readonly byte[] InvalidUtf8Body =
        Ascii("{\"error\":\"invalid_grant\",\"error_description\":\"").Concat(new byte[] { 0xC3, 0x28 }).Concat(Ascii("\"}")).ToArray();

    private static readonly ResidualCell[] ResidualCells =
    {
        new("A0", 200, Ascii("{" + ResidualTokenMembers + "}"), Ascii("{\"active\":true,\"username\":\"svc\"}")),
        ErrorValueCell("A1", "123"),
        ErrorValueCell("A2", "{\"a\":1}"),
        ErrorValueCell("A3", "[\"x\"]"),
        ErrorValueCell("A4", "true"),
        ErrorValueCell("A5", "null"),
        ErrorValueCell("A6", "\"\""),
        BothLanesCell("B1", 400, Ascii("{\"error\":\"invalid_grant\",\"error\":\"temporarily_unavailable\"}")),
        new("B2", 200, Ascii("{" + ResidualTokenMembers + ",\"error\":\"invalid_grant\",\"error\":\"temporarily_unavailable\"}"),
            Ascii("{\"active\":true,\"error\":\"invalid_grant\",\"error\":\"temporarily_unavailable\"}")),
        BothLanesCell("B3", 400, Ascii("{\"error\":\"invalid_grant\",\"error\":123}")),
        BothLanesCell("B4", 400, Ascii("{\"error\":123,\"error\":\"invalid_grant\"}")),
        new("B5", 200, Ascii("{" + ResidualTokenMembers + ",\"error\":\"invalid_grant\",\"error\":\"\"}"),
            Ascii("{\"active\":true,\"error\":\"invalid_grant\",\"error\":\"\"}")),
        BothLanesCell("C1", 201, InvalidUtf8Body),
        BothLanesCell("C2", 400, InvalidUtf8Body),
        BothLanesCell("C3", 201, Ascii("not json")),
        BothLanesCell("C4", 400, Ascii("not json")),
    };

    /// <summary>The lanes of <see cref="Surfaces"/> but <c>admin</c>, each returning what its success hands back.</summary>
    private static readonly (string Lane, Func<KeycloakClient, Task<string>> Run)[] ResidualLanes =
    {
        ("ClientCredentialsTokenAsync", async kc => "access_token=" + (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken),
        ("RefreshAsync", async kc => "access_token=" + (await kc.Auth.RefreshAsync(Refresh)).AccessToken),
        ("ExchangeCodeAsync", async kc => "access_token=" + (await kc.Auth.ExchangeCodeAsync(Code, "https://app/cb", Verifier)).AccessToken),
        ("IntrospectAsync", async kc => "active=" + ((await kc.Auth.IntrospectAsync(Token)).Active ? "true" : "false")),
        ("ClientCredentialsTokenProvider", async kc => "access_token=" + await new ClientCredentialsTokenProvider(kc.Auth).GetAccessTokenAsync()),
    };

    private volatile ResidualCell? _residualCell;

    private static ResponseMessage RawJson(int status, byte[] body) => new()
    {
        StatusCode = status,
        Headers = new Dictionary<string, WireMockList<string>> { ["Content-Type"] = new("application/json") },
        BodyData = new BodyData { DetectedBodyType = BodyType.Bytes, BodyAsBytes = body },
    };

    // Every character outside printable ASCII as \u{XXXX} (the code point, uppercase hex), so a line stays one line.
    private static string Printable(string s)
    {
        var b = new StringBuilder();
        for (var i = 0; i < s.Length; i++)
        {
            int cp = s[i];
            if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
                cp = char.ConvertToUtf32(s[i], s[++i]);
            if (cp is >= 0x20 and <= 0x7E) b.Append((char)cp);
            else b.Append("\\u{").Append(cp.ToString("X", CultureInfo.InvariantCulture)).Append('}');
        }
        return b.ToString();
    }

    private static string ClassOf(Exception e) =>
        e.GetType().Namespace?.StartsWith("Xzawed.Keycloak", StringComparison.Ordinal) == true ? e.GetType().Name : e.GetType().FullName ?? e.GetType().Name;

    private static string Failure(Exception e) =>
        $"{ClassOf(e)}|{(e is KeycloakAuthException a ? (a.OAuthError is { } c ? "\"" + Printable(c) + "\"" : "null") : "n/a")}|{Printable(e.Message)}";

    /// <summary>The message with its status number named alike — (C) lets the message differ by it alone.</summary>
    private static string StatusBlind(string message, int status) =>
        message.Replace($"HTTP {status.ToString(CultureInfo.InvariantCulture)}", "HTTP <status>", StringComparison.Ordinal);

    /// <summary>Each cell of one lane that misses its target (A · B2 · C) — none means the lane meets them.</summary>
    private static List<string> ResidualWrong(string lane, IReadOnlyDictionary<string, string[]> rows)
    {
        var wrong = new List<string>();
        // (A) the cells a token or introspection lane takes as success — no `error`, a null one, ""
        foreach (var cell in new[] { "A0", "A5", "A6" })
        {
            if (rows[cell][0] != "SUCCESS") wrong.Add($"{lane} {cell}: {string.Join("|", rows[cell])} -- wants SUCCESS");
        }
        // (A) a 200 whose `error` is a number, an object, an array, a boolean — and (B) a duplicated string one
        foreach (var cell in new[] { "A1", "A2", "A3", "A4", "B2" })
        {
            if (rows[cell][0] != "KeycloakAuthException" || (cell != "B2" && rows[cell][1] != "null"))
                wrong.Add($"{lane} {cell}: {string.Join("|", rows[cell])} -- wants KeycloakAuthException, no code");
        }
        foreach (var (created, refused) in new[] { ("C1", "C2"), ("C3", "C4") })
        {
            var (got, want) = (rows[created], rows[refused]);
            if (got[0] != want[0] || got[1] != want[1] || StatusBlind(got[2], 201) != StatusBlind(want[2], 400))
                wrong.Add($"{lane} {created} {string.Join("|", got)} != {refused} {string.Join("|", want)}");
        }
        return wrong;
    }

    private static string[] Row(string outcome) => outcome.Split('|', 3);

    [Fact]
    public async Task ResidualDivergenceCellsMeetTheirTargets()
    {
        // The cells' text is the assertion's message alone; only B5 is written — its outcome class and whether anything in
        // the body was used, never a code or a message (CodeQL's clear-text-logging heuristic flags a line built from the
        // OAuth code).
        var rows = new Dictionary<string, Dictionary<string, string[]>>();
        var wrong = new List<string>();
        void Keep(string lane, string cell, string outcome, string shown, bool used)
        {
            if (!rows.TryGetValue(lane, out var lanes)) rows[lane] = lanes = new Dictionary<string, string[]>();
            lanes[cell] = Row(outcome);
            if (cell == "B5") _output.WriteLine($"B5|dotnet|{lane}|{shown}|used={(used ? "true" : "false")}");
        }
        var adminAuthorization = new ConcurrentQueue<string>();
        using var idp = WireMockServer.Start();
        idp.Given(Request.Create().UsingAnyMethod()).RespondWith(Response.Create().WithCallback(req =>
        {
            if (req.Method == "GET" && req.Path.EndsWith("/admin/realms/r/users/u1", StringComparison.Ordinal))
            {
                adminAuthorization.Enqueue(req.Headers is { } h && h.TryGetValue("Authorization", out var a) ? string.Join(", ", a) : "<none>");
                return RawJson(200, Ascii("{\"id\":\"u1\",\"username\":\"svc\"}"));
            }
            if (req.Method != "POST" || _residualCell is not { } cell) return RawJson(404, Ascii("{}"));
            return RawJson(cell.Status, req.Path.EndsWith("/token/introspect", StringComparison.Ordinal) ? cell.IntrospectionBody : cell.TokenBody);
        }));
        KeycloakClient NewClient() =>
            KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = Secret });

        using var probe = new HttpClient();
        foreach (var cell in ResidualCells)
        {
            _residualCell = cell;
            // The instrument first: a plain HttpClient reads the cell's exact status and bytes off the wire.
            foreach (var (path, want) in new[] { ("token", cell.TokenBody), ("token/introspect", cell.IntrospectionBody) })
            {
                using var resp = await probe.PostAsync($"{idp.Urls[0]}/realms/r/protocol/openid-connect/{path}", new StringContent(""));
                var same = (await resp.Content.ReadAsByteArrayAsync()).SequenceEqual(want);
                if ((int)resp.StatusCode != cell.Status || !same)
                    wrong.Add($"fake {cell.Name} {path}: status {(int)resp.StatusCode}, bytes {(same ? "equal" : "differ")}");
            }

            foreach (var (lane, run) in ResidualLanes)
            {
                string outcome;
                string shown;
                try
                {
                    using var kc = NewClient();
                    outcome = $"SUCCESS|-|{Printable(await run(kc))}";
                    shown = "SUCCESS";
                }
                catch (Exception e)
                {
                    outcome = Failure(e);
                    shown = ClassOf(e);
                }
                Keep(lane, cell.Name, outcome, shown, shown == "SUCCESS");
            }

            // admin: SUCCESS only when the admin request went out with the token; otherwise the call's error.
            while (adminAuthorization.TryDequeue(out _)) { }
            Exception? failure = null;
            try
            {
                using var kc = NewClient();
                await (await kc.AdminAsync()).Users.GetAsync("u1");
            }
            catch (Exception e) { failure = e; }
            string adminOutcome;
            var sent = adminAuthorization.TryDequeue(out var authorization);
            if (sent)
            {
                var call = failure is null ? "ok" : $"{ClassOf(failure)}: {failure.Message}";
                adminOutcome = $"{(authorization == "Bearer AT-ok" ? "SUCCESS" : "SENT-WITH-OTHER-AUTHORIZATION")}|-|"
                    + Printable($"admin request sent, Authorization={authorization}; call={call}");
            }
            else
            {
                adminOutcome = failure is null ? "NO-REQUEST-NO-ERROR|-|" : Failure(failure);
            }
            Keep("admin", cell.Name, adminOutcome, sent ? "SUCCESS" : failure is null ? "NO-REQUEST-NO-ERROR" : ClassOf(failure), sent);
        }

        wrong.AddRange(rows.SelectMany(lane => ResidualWrong(lane.Key, lane.Value)));
        Assert.True(wrong.Count == 0, $"{wrong.Count} cells:\n{string.Join("\n", wrong)}");
    }
}
