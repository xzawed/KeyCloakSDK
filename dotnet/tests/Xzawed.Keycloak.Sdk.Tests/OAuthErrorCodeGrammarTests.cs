using System.Text;
using System.Text.Json;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// An OAuth <c>error</c> value reaches <c>Message</c> or <c>OAuthError</c> only when it is an RFC 6749 §5.2 error code —
/// <c>error = 1*NQSCHAR</c>, <c>NQSCHAR = %x20-21 / %x23-5B / %x5D-7E</c> — and then unchanged. Any other string is no code
/// at all: nothing is trimmed or stripped into one (<c>"invalid_client\r\n"</c> gives no code, not <c>"invalid_client"</c>).
/// </summary>
/// <remarks>
/// <para>Measured before the fix (2026-10-03): a 400 <c>{"error":"invalid_client\n"}</c> gave the Message
/// <c>Client credentials grant failed: invalid_client\n</c> and the same <c>OAuthError</c> — one logged SDK error split into
/// two log lines. CR, CRLF, an embedded LF, NUL, DEL and non-ASCII (U+2028 included) went through the same way on every
/// grant and on introspection; the 401 branch kept the canonical reason in the Message but carried the raw value in
/// <c>OAuthError</c>. The grammar excludes every control character, <c>"</c>, <c>\</c> and everything past ASCII, so
/// enforcing it costs no valid code — and it still admits every token character, which is why
/// <c>MalformedTokenResponseTests.KnownLeaks</c> keeps an in-grammar code as debugging information.</para>
/// <para>The two branches that carry a code are both here: 400 (the body's <c>error</c> — a 2xx takes the same branch when
/// it carries an error code or an <c>error</c> Duende flags) and every other HTTP error (the canonical reason, with the code
/// in <c>OAuthError</c>).</para>
/// <para>⚠️ Outside this contract: an unpaired UTF-16 surrogate escape (U+D800 alone). System.Text.Json throws
/// <c>InvalidOperationException</c> while decoding it — in Duende's <c>IsError</c> for a token call on 400 or 2xx, in
/// <c>OAuthErrorOf</c> for any call on 401 — so it leaves the SDK as a lower-library exception before any grammar check
/// (introspection's 400 is caught earlier, as "response body is not a JSON object"). Measured 2026-10-03, unchanged here.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class OAuthErrorCodeGrammarTests : IDisposable
{
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private const string NotACode = "error is not an RFC 6749 error code";
    private const string NotAString = "error is not a JSON string";

    private readonly WireMockServer _idp = WireMockServer.Start();

    public void Dispose() => _idp.Dispose();

    /// <param name="ErrorJson">The <c>error</c> member's JSON text.</param>
    /// <param name="Code">What <c>OAuthError</c> carries — the value itself when it is an error code, else <c>null</c>.</param>
    /// <param name="NoCode">The 400 message's tail when it is not one.</param>
    private sealed record Row(string ErrorJson, string? Code, string NoCode);

    private static Row Admitted(string value) => new(JsonSerializer.Serialize(value), value, "");

    private static Row Refused(string value) => new(JsonSerializer.Serialize(value), null, NotACode);

    private static string C(int codePoint) => ((char)codePoint).ToString();

    private static readonly Dictionary<string, Row> Rows = new(StringComparer.Ordinal)
    {
        ["clean control"] = Admitted("invalid_client"),
        ["trailing LF"] = Refused("invalid_client\n"),
        ["trailing CR"] = Refused("invalid_client\r"),
        ["trailing CRLF"] = Refused("invalid_client\r\n"),
        ["embedded LF"] = Refused("invalid\nclient"),
        ["NUL"] = Refused("invalid_client" + C(0x00)),
        ["DEL 0x7F"] = Refused("invalid_client" + C(0x7F)),
        ["0x1F, the control just below space"] = Refused("invalid_client" + C(0x1F)),
        ["non-ASCII U+00E9"] = Refused("invalid_cli" + C(0xE9) + "nt"),
        ["non-ASCII line separator U+2028"] = Refused("invalid" + C(0x2028) + "client"),
        ["quote 0x22, outside NQSCHAR"] = Refused("invalid" + C(0x22) + "client"),
        ["backslash 0x5C, outside NQSCHAR"] = Refused("invalid" + C(0x5C) + "client"),
        ["empty, 1*NQSCHAR needs one"] = Refused(""),
        // Decided: a space-only value IS an error code — %x20 is NQSCHAR, so refusing it would make the 400 message
        // ("not an RFC 6749 error code") false. It cannot split a log line.
        ["space only, 0x20 is NQSCHAR"] = Admitted(" "),
        ["spaces only"] = Admitted("   "),
        ["the grammar's inner edges"] = Admitted("!#[]~"),
        // Not a string at all — keeps its own wording (Duende renders it as raw JSON text).
        ["number, not a JSON string"] = new("42", null, NotAString),
    };

    public static IEnumerable<object[]> Cases =>
        Rows.Keys.SelectMany(row => new[] { new object[] { row, 400 }, new object[] { row, 401 } });

    /// <summary>Every admitted row on a 2xx — the low edge, a common one and the high edge of the success range.</summary>
    public static IEnumerable<object[]> SuccessStatusCases =>
        Rows.Where(kv => kv.Value.Code is not null)
            .SelectMany(kv => new[] { 200, 201, 299 }.Select(status => new object[] { kv.Key, status }));

    private delegate Task<object> Call(KeycloakClient kc);

    /// <summary>Every public call that reads the OAuth <c>error</c> member, with its failure prefix.</summary>
    private static readonly (string Name, string Prefix, Call Run)[] Calls =
    {
        ("ClientCredentialsTokenAsync", "Client credentials grant failed", async kc => await kc.Auth.ClientCredentialsTokenAsync()),
        ("RefreshAsync", "Token refresh failed", async kc => await kc.Auth.RefreshAsync("rt-sent")),
        ("ExchangeCodeAsync", "Authorization code exchange failed",
            async kc => await kc.Auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43), "n1")),
        ("IntrospectAsync", "Token introspection failed", async kc => await kc.Auth.IntrospectAsync("tok-sent")),
    };

    [Theory]
    [MemberData(nameof(Cases))]
    public Task Only_an_RFC_6749_error_code_reaches_Message_or_OAuthError(string row, int status) => Check(row, status);

    /// <summary>A 2xx that carries an error code fails with that code, exactly as a 400 does.</summary>
    /// <remarks>Measured before this check (2026-10-03): Duende's <c>IsError</c> did not flag a 2xx whose <c>error</c> text
    /// is whitespace, so a space-only code — %x20 is NQSCHAR — left every token call failing as "token response missing
    /// access_token" with no <c>OAuthError</c>, and let introspection return a result. A 2xx with any other code was
    /// flagged already.</remarks>
    [Theory]
    [MemberData(nameof(SuccessStatusCases))]
    public Task A_2xx_carrying_an_error_code_fails_with_that_code_as_a_400_does(string row, int status) => Check(row, status);

    private async Task Check(string row, int status)
    {
        var r = Rows[row];
        var body = $$"""{"error":{{r.ErrorJson}}}""";
        foreach (var path in new[] { $"{Oidc}/token", $"{Oidc}/token/introspect" })
        {
            _idp.Given(Request.Create().WithPath(path).UsingPost())
                .RespondWith(Response.Create().WithStatusCode(status).WithHeader("Content-Type", "application/json").WithBody(body));
        }
        using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" });

        var wrong = new List<string>();
        foreach (var (name, prefix, run) in Calls)
        {
            var ex = await Record.ExceptionAsync(() => run(kc));
            // A 400 and a 2xx carry the body's error; any other status gives the canonical reason (401 here).
            var (message, oauthError) = status is 400 or (>= 200 and <= 299)
                ? ($"{prefix}: {r.Code ?? r.NoCode}", r.Code)
                : ($"{prefix}: Unauthorized", r.Code ?? "Unauthorized");
            if (ex is not KeycloakAuthException k || k.Message != message || k.OAuthError != oauthError)
                wrong.Add($"{name}: {Describe(ex)} — want {Visible(message)} / {Visible(oauthError)}");
        }
        Assert.True(wrong.Count == 0, $"[{row} · HTTP {status} · body {body}]\n" + string.Join("\n", wrong));
    }

    private static string Describe(Exception? ex) => ex switch
    {
        null => "no exception",
        KeycloakAuthException k => $"Message={Visible(k.Message)} OAuthError={Visible(k.OAuthError)}",
        _ => ex.GetType().Name,
    };

    /// <summary>The text with every byte outside printable ASCII spelled out — the failure output must not split lines.</summary>
    private static string Visible(string? s)
    {
        if (s is null)
            return "null";
        var sb = new StringBuilder("\"");
        foreach (var c in s)
        {
            sb.Append(c switch
            {
                '\\' => @"\\",
                '"' => "\\\"",
                < ' ' or (char)0x7F => $"\\x{(int)c:X2}",
                > '~' => $"\\u{(int)c:X4}",
                _ => c.ToString(),
            });
        }
        return sb.Append('"').ToString();
    }
}
