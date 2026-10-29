using System.Security.Cryptography;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;
using Xunit.Abstractions;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// The bearer grammar every admin request goes out under — the same in all nine SDKs (registry
/// <c>bearer-token-grammar-divergent</c>): SP, HTAB, CR and LF are trimmed from both ends and nothing else is, and what
/// remains must be an RFC 6750 <c>b64token</c> (<c>[A-Za-z0-9-._~+/]+=*</c>). It goes out as
/// <c>Authorization: Bearer &lt;remainder&gt;</c>, or the request is not sent. One predicate (<c>BearerToken.Sendable</c>) at
/// two seams: <c>BearerHandler</c>, which every admin request passes — the typed facade, its raw REST calls and the
/// <see cref="AdminClient.Raw"/> escape hatch — and <see cref="ClientCredentialsTokenProvider"/>, which does not cache a
/// token that fails it.
/// </summary>
/// <remarks>
/// <para>Measured before (2026-10-29, this file on the unchanged SDK): a consumer token's LF or CRLF ended every admin call in
/// <see cref="KeycloakTransportException"/> ("… holds a CR or LF …") instead of being trimmed; SP and HTAB — leading,
/// trailing or inside — went out as they came, and so did <c>a=bc</c>, while an empty or null token went out as a bare
/// <c>Bearer</c>; a character past ASCII reached the <see cref="AdminClient.Raw"/> escape hatch as a raw
/// <see cref="HttpRequestException"/>. The SDK's own provider cached every one of them.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class BearerTokenGrammarTests
{
    private const string TokenSuffix = "/protocol/openid-connect/token";
    internal const string SendRefused = "admin request failed: the access token is not a valid RFC 6750 bearer token (b64token)";
    internal const string GrantRefused = "Client credentials grant failed: access_token is not a valid RFC 6750 bearer token (b64token)";

    private static readonly string Jws = MintJws();

    /// <summary>id → the token, and what follows <c>Bearer </c> on the wire (null: no request is sent). The canonical table,
    /// then the .NET extras: a lone surrogate (a string is UTF-16), and <c>null</c> from a consumer provider.</summary>
    private static readonly Dictionary<string, (string? Token, string? Sent)> Table = new()
    {
        ["plain"] = ("abc.DEF-ghi_jkl~mno+pqr/stu", "abc.DEF-ghi_jkl~mno+pqr/stu"),
        ["pad"] = ("abc==", "abc=="),
        ["jwt"] = (Jws, Jws),
        ["lf"] = ("abc\n", "abc"),
        ["crlf"] = ("abc\r\n", "abc"),
        ["lead-tab"] = (" \tabc\t ", "abc"),
        ["inner-sp"] = ("a bc", null),
        ["inner-tab"] = ("a\tbc", null),
        ["inner-crlf"] = ("a\r\nX-Evil: 1", null),
        ["mid-pad"] = ("a=bc", null),
        ["empty"] = ("", null),
        ["blank"] = (" \t\r\n", null),
        ["latin1"] = ("abc" + (char)0x00E9, null),
        ["above-ff"] = ("abc" + (char)0x0100, null),
        ["c1"] = ("abc\u0085", null),
        ["nul"] = ("abc\u0000", null),
        ["del"] = ("abc\u007F", null),
        ["nbsp"] = ("abc" + (char)0x00A0, null),
        ["ideographic"] = ((char)0x3000 + "abc", null),
        ["vt"] = ("abc\u000B", null),
        ["lone-surrogate"] = ("abc" + (char)0xD800, null),
        ["null"] = (null, null),
    };

    public static IEnumerable<object[]> Ids => Table.Keys.Select(id => new object[] { id });

    private readonly ITestOutputHelper _out;

    public BearerTokenGrammarTests(ITestOutputHelper output) => _out = output;

    /// <summary>(a)+(b) A consumer <see cref="ITokenProvider"/>'s token on the typed facade, a raw REST call and the escape
    /// hatch: sent trimmed, or refused with no request.</summary>
    [Theory]
    [MemberData(nameof(Ids))]
    public async Task A_consumer_token_goes_out_on_every_admin_route_only_under_the_grammar(string id)
    {
        var (token, sent) = Table[id];
        using var idp = new CapIdp(Route(token));
        await using var admin = await AdminClient.CreateAsync(Config(idp).Normalized(), new Fixed(token));
        var routes = new (string Name, Func<Task> Call)[]
        {
            ("typed Users.SearchAsync", () => admin.Users.SearchAsync(null)),
            ("raw REST Realms.ListAsync", () => admin.Realms.ListAsync()),
            ("escape hatch Raw.GetRealmAsync", () => admin.Raw.GetRealmAsync("r")),
        };

        var wrong = new List<string>();
        foreach (var (name, call) in routes)
        {
            var before = idp.Seen.Count;
            var error = await Record.ExceptionAsync(call);
            var reqs = idp.Seen.Skip(before).Where(IsAdmin).ToList();
            _out.WriteLine($"{id} {name}: {Outcome(error, reqs)}");
            if (sent is null)
            {
                if (error is not KeycloakTransportException { Message: SendRefused })
                    wrong.Add($"{name}: {Describe(error)} — want KeycloakTransportException \"{SendRefused}\"");
                if (reqs.Count != 0)
                    wrong.Add($"{name}: {reqs.Count} admin request(s) reached the server — want none");
                wrong.AddRange(Leaks(id, token, error).Select(w => $"{name}: {w}"));
            }
            else if (error is not null || reqs.Count != 1 || reqs[0].RawAuthorization != " Bearer " + sent)
            {
                wrong.Add($"{name}: {Outcome(error, reqs)} — want one request carrying \"Bearer {Escape(sent)}\"");
            }
        }
        Assert.True(wrong.Count == 0, $"[{id}]\n" + string.Join("\n", wrong));
    }

    /// <summary>(c) The SDK's own admin: a token from the token endpoint that fails the grammar fails the grant and is not
    /// cached — the next build asks the IdP again — and no admin request goes out; one that passes is cached and goes out
    /// trimmed.</summary>
    [Theory]
    [MemberData(nameof(Ids))]
    public async Task The_sdk_admin_caches_only_a_grant_under_the_grammar(string id)
    {
        var (token, sent) = Table[id];
        using var idp = new CapIdp(Route(token));
        await using var kc = KeycloakClient.Create(Config(idp));

        var wrong = new List<string>();
        if (sent is null)
        {
            foreach (var attempt in new[] { "first", "second" })
            {
                var error = await Record.ExceptionAsync(() => kc.AdminAsync());
                _out.WriteLine($"{id} AdminAsync ({attempt}): {Describe(error)}");
                if (error is not KeycloakAuthException)
                    wrong.Add($"AdminAsync ({attempt}): {Describe(error)} — want KeycloakAuthException");
                wrong.AddRange(Leaks(id, token, error).Select(w => $"AdminAsync ({attempt}): {w}"));
            }
            if (TokenRequests(idp) != 2)
                wrong.Add($"{TokenRequests(idp)} token request(s) for two builds — a refused grant must not be cached");
        }
        else
        {
            var admin = await kc.AdminAsync();
            await admin.Realms.ListAsync();
            await admin.Users.SearchAsync(null);
            if (TokenRequests(idp) != 1)
                wrong.Add($"{TokenRequests(idp)} token request(s) — want one, cached");
        }
        var adminReqs = idp.Seen.Where(IsAdmin).ToList();
        _out.WriteLine($"{id} wire: {Outcome(null, adminReqs)}");
        if (sent is null ? adminReqs.Count != 0 : adminReqs.Count != 2 || adminReqs.Any(r => r.RawAuthorization != " Bearer " + sent))
            wrong.Add($"admin requests: {Outcome(null, adminReqs)} — want {(sent is null ? "none" : $"two carrying \"Bearer {Escape(sent)}\"")}");
        Assert.True(wrong.Count == 0, $"[{id}]\n" + string.Join("\n", wrong));
    }

    /// <summary>(c) The grant-time predicate itself, on <see cref="ClientCredentialsTokenProvider"/> over a source that hands
    /// the token over as it is — no JSON or <see cref="TokenSet.Create"/> check in between: a failing token is refused on
    /// every call and the source is asked each time; a passing one is returned trimmed and asked for once.</summary>
    [Theory]
    [MemberData(nameof(Ids))]
    public async Task The_token_provider_does_not_cache_a_token_outside_the_grammar(string id)
    {
        var (token, sent) = Table[id];
        var source = new CountingSource(token);
        var provider = new ClientCredentialsTokenProvider(source, skewSeconds: 0);

        var wrong = new List<string>();
        foreach (var attempt in new[] { "first", "second" })
        {
            string? got = null;
            var error = await Record.ExceptionAsync(async () => got = await provider.GetAccessTokenAsync());
            _out.WriteLine($"{id} GetAccessTokenAsync ({attempt}): {(error is null ? $"\"{Escape(got)}\"" : Describe(error))}");
            if (sent is null)
            {
                if (error is not KeycloakAuthException { Message: GrantRefused })
                    wrong.Add($"{attempt}: {Describe(error)} — want KeycloakAuthException \"{GrantRefused}\"");
                wrong.AddRange(Leaks(id, token, error).Select(w => $"{attempt}: {w}"));
            }
            else if (error is not null || got != sent)
            {
                wrong.Add($"{attempt}: {(error is null ? $"\"{Escape(got)}\"" : Describe(error))} — want \"{Escape(sent)}\"");
            }
        }
        var wantCalls = sent is null ? 2 : 1;
        if (source.Calls != wantCalls)
            wrong.Add($"the source was asked {source.Calls} time(s) — want {wantCalls}");
        Assert.True(wrong.Count == 0, $"[{id}]\n" + string.Join("\n", wrong));
    }

    private static KeycloakConfig Config(CapIdp idp) =>
        new() { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s" };

    /// <summary>The token endpoint answers with <paramref name="token"/>; the realm read answers with a realm, every other admin
    /// read with an empty list.</summary>
    private static Func<CapIdp.Req, CapIdp.Resp> Route(string? token) => req =>
        req.Path.EndsWith(TokenSuffix, StringComparison.Ordinal)
            ? CapIdp.Resp.Json(200, $$"""{"access_token":{{JsonString(token)}},"token_type":"Bearer","expires_in":300}""")
            : CapIdp.Resp.Json(200, req.Path == "/admin/realms/r" ? """{"realm":"r"}""" : "[]");

    private static bool IsAdmin(CapIdp.Req r) => r.Path.StartsWith("/admin/", StringComparison.Ordinal);

    private static int TokenRequests(CapIdp idp) => idp.Seen.Count(r => r.Path.EndsWith(TokenSuffix, StringComparison.Ordinal));

    /// <summary>A JSON string literal escaping every character outside printable ASCII — the token arrives as it is, a lone
    /// surrogate included.</summary>
    private static string JsonString(string? s) => s is null
        ? "null"
        : "\"" + string.Concat(s.Select(c => c is >= ' ' and <= '~' and not '"' and not '\\' ? c.ToString() : $"\\u{(int)c:x4}")) + "\"";

    /// <summary>Where a refusal quotes the token — its message, cause chain or stack: the whole token, <c>abc</c>, and the
    /// injected header name.</summary>
    private static IEnumerable<string> Leaks(string id, string? token, Exception? error)
    {
        if (error is null)
            yield break;
        var needles = new[] { "abc", token?.Trim(' ', '\t', '\r', '\n'), "X-Evil" }
            .Where(n => !string.IsNullOrEmpty(n) && n.Length > 1).Cast<string>().ToList();
        foreach (var text in BearerHeaderCaseTests.Renderings(error))
        {
            if (needles.FirstOrDefault(n => text.Contains(n, StringComparison.Ordinal)) is { } hit)
                yield return $"{error.GetType().Name} quotes the token ({id}: \"{Escape(hit)}\")";
        }
    }

    private static string Outcome(Exception? error, List<CapIdp.Req> reqs) =>
        (error is null ? "ok" : Describe(error)) + $" · {reqs.Count} admin request(s)"
        + string.Concat(reqs.Select(r => $" [Authorization:{Escape(r.RawAuthorization)}]"));

    private static string Describe(Exception? e) => e is null ? "no exception" : $"{e.GetType().Name}: \"{e.Message}\"";

    /// <summary>Control and non-ASCII characters as <c>\uXXXX</c>, so the output shows what was sent.</summary>
    private static string Escape(string? s) => s is null
        ? "(null)"
        : string.Concat(s.Select(c => c is >= ' ' and <= '~' ? c.ToString() : $"\\u{(int)c:X4}"));

    private static string MintJws()
    {
        using var rsa = RSA.Create(2048);
        var credentials = new SigningCredentials(new RsaSecurityKey(rsa) { KeyId = "k1" }, SecurityAlgorithms.RsaSha256);
        return new JsonWebTokenHandler().CreateToken("""{"sub":"svc","azp":"c"}""", credentials);
    }

    private sealed class Fixed(string? token) : ITokenProvider
    {
        public Task<string> GetAccessTokenAsync(CancellationToken ct = default) => Task.FromResult(token!);
    }

    /// <summary>Hands the token over as it is (an object initializer, not <see cref="TokenSet.Create"/>), counting the asks.</summary>
    private sealed class CountingSource(string? token) : ITokenSource
    {
        private int _calls;

        public int Calls => Volatile.Read(ref _calls);

        public Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default)
        {
            Interlocked.Increment(ref _calls);
            return Task.FromResult(new TokenSet { AccessToken = token!, TokenType = "Bearer", ExpiresIn = 300 });
        }
    }
}
