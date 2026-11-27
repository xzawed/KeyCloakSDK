// measurement only — not for merge (task n3 · registry consumer-http-client-redirect-unmeasured).
//
// The two public ctors that take a consumer HttpClient — AuthClient(cfg, ep, validator, HttpClient) and
// JwtValidator(issuer, opts, HttpClient) — are given `new HttpClient()` (the .NET default handler: AllowAutoRedirect on).
// Origin A answers the SDK's request with 302 · 303 · 307 · 308 whose Location points at `/moved<same path>` on A itself
// (same origin) or on a second WireMock server B (another port = cross origin). The target answers every request with a
// usable success body, so `result` shows what the SDK does with an answer that came from the redirect target. The JWKS
// rows sign the token with a key only the target serves (kid kB): `result=Ok` means the SDK validated against the
// target's key. Controls: the same cells through KeycloakClient.Create (the SDK's own client — AllowAutoRedirect=false).
//
// Run: N3_OUT=<file> dotnet test -f net10.0 --filter "FullyQualifiedName~ZzN3RedirectMeasure"
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.Tokens;
using WireMock;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using WireMock.Types;
using WireMock.Util;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public sealed class ZzN3RedirectMeasure : IDisposable
{
    private const string Realm = "it-realm";
    private const string ClientId = "it-client";
    private const string Secret = "dummy-secret-MARK";
    private const string Refresh = "dummy-refresh-MARK";
    private const string Code = "dummy-code-MARK";
    private const string Verifier = "dummy-verifier-MARK";
    private const string Introspected = "dummy-introspected-MARK";
    private const string RealmPath = "/realms/" + Realm;
    private const string Oidc = RealmPath + "/protocol/openid-connect";
    private const string Discovery = RealmPath + "/.well-known/openid-configuration";
    private static readonly int[] Statuses = { 302, 303, 307, 308 };

    private enum Op { AuthCc, AuthCode, AuthRefresh, AuthIntrospect, AuthLogout, ValidateDiscovery3xx, ValidateJwks3xx }

    private static readonly Op[] Ops = Enum.GetValues<Op>();

    private readonly WireMockServer _a = WireMockServer.Start();
    private readonly WireMockServer _b = WireMockServer.Start();
    private readonly RsaSecurityKey _targetKey = new(RSA.Create(2048)) { KeyId = "kB" };
    private readonly List<string> _out = new();
    private Cell? _cell;
    private Bounce? _bounce;

    /// <summary>One cell: which path on A answers the 3xx, where it points, and which server is the target.</summary>
    private sealed record Cell(string OriginPath, int Status, string Location, string TargetOrigin, bool GenuineDiscoveryOnA);

    private sealed class Bounce
    {
        internal int TokenHits;
    }

    public ZzN3RedirectMeasure()
    {
        _a.Given(Request.Create().UsingAnyMethod()).RespondWith(Response.Create().WithCallback(r => Serve("A", r)));
        _b.Given(Request.Create().UsingAnyMethod()).RespondWith(Response.Create().WithCallback(r => Serve("B", r)));
    }

    public void Dispose()
    {
        _a.Dispose();
        _b.Dispose();
    }

    private string A => _a.Urls[0];
    private string B => _b.Urls[0];
    private string IssuerA => A + RealmPath;

    private ResponseMessage Serve(string origin, IRequestMessage req)
    {
        var path = req.Path ?? "";
        if (_bounce is { } bounce)
        {
            if (origin == "A" && path == "/token")
                return ++bounce.TokenHits == 1 ? Redirect(307, B + "/hop") : Json(200, """{"access_token":"AT","token_type":"Bearer"}""");
            if (origin == "B" && path == "/hop")
                return Redirect(307, A + "/token");
        }
        if (path == "/start" && origin == "A" && _cell is { } probe)
            return Redirect(probe.Status, probe.Location);
        if (path == "/moved/start")
            return Json(200, "{}");
        if (_cell is not { } cell)
            return Json(404, "{}");
        if (origin == "A" && path == cell.OriginPath)
            return Redirect(cell.Status, cell.Location);
        if (origin == "A" && cell.GenuineDiscoveryOnA && path == Discovery)
            return Json(200, $$"""{"issuer":"{{IssuerA}}","jwks_uri":"{{IssuerA}}/protocol/openid-connect/certs"}""");
        if (origin == cell.TargetOrigin && path.StartsWith("/moved/", StringComparison.Ordinal))
            return Target(origin, path);
        return Json(404, "{}");
    }

    /// <summary>The redirect target — a usable success answer for every request it gets, whatever the method.</summary>
    private ResponseMessage Target(string origin, string path)
    {
        var self = origin == "A" ? A : B;
        if (path.EndsWith("/openid-configuration", StringComparison.Ordinal))
            return Json(200, $$"""{"issuer":"{{IssuerA}}","jwks_uri":"{{self}}/moved{{Oidc}}/certs"}""");
        if (path.EndsWith("/certs", StringComparison.Ordinal))
            return Json(200, $$"""{"keys":[{{JwksOctKeyTests.RsaJwk(_targetKey)}}]}""");
        if (path.EndsWith("/token/introspect", StringComparison.Ordinal))
            return Json(200, """{"active":true,"username":"target-user","client_id":"target-client"}""");
        if (path.EndsWith("/logout", StringComparison.Ordinal))
            return new ResponseMessage { StatusCode = 204 };
        return Json(200, """{"access_token":"TARGET-AT","token_type":"Bearer","expires_in":300,"refresh_token":"TARGET-RT"}""");
    }

    private static ResponseMessage Redirect(int status, string location) => new()
    {
        StatusCode = status,
        Headers = new Dictionary<string, WireMockList<string>> { ["Location"] = new(location) },
    };

    private static ResponseMessage Json(int status, string body) => new()
    {
        StatusCode = status,
        Headers = new Dictionary<string, WireMockList<string>> { ["Content-Type"] = new("application/json") },
        BodyData = new BodyData { DetectedBodyType = BodyType.Bytes, BodyAsBytes = Encoding.UTF8.GetBytes(body) },
    };

    private static string OriginPath(Op op) => op switch
    {
        Op.AuthCc or Op.AuthCode or Op.AuthRefresh => Oidc + "/token",
        Op.AuthIntrospect => Oidc + "/token/introspect",
        Op.AuthLogout => Oidc + "/logout",
        Op.ValidateDiscovery3xx => Discovery,
        Op.ValidateJwks3xx => Oidc + "/certs",
        _ => throw new ArgumentOutOfRangeException(nameof(op)),
    };

    private static string Name(Op op) => op switch
    {
        Op.AuthCc => "ClientCredentialsTokenAsync(POST form)",
        Op.AuthCode => "ExchangeCodeAsync(POST form)",
        Op.AuthRefresh => "RefreshAsync(POST form)",
        Op.AuthIntrospect => "IntrospectAsync(POST form)",
        Op.AuthLogout => "LogoutAsync(POST form)",
        Op.ValidateDiscovery3xx => "ValidateAsync[discovery 3xx](GET)",
        Op.ValidateJwks3xx => "ValidateAsync[jwks 3xx](GET)",
        _ => throw new ArgumentOutOfRangeException(nameof(op)),
    };

    private static string Ctor(Op op) => op is Op.ValidateDiscovery3xx or Op.ValidateJwks3xx
        ? "JwtValidator(issuer,opts,HttpClient)"
        : "AuthClient(cfg,ep,validator,HttpClient)";

    private KeycloakConfig Config() => new KeycloakConfig
    {
        ServerUrl = A,
        Realm = Realm,
        ClientId = ClientId,
        ClientSecret = Secret,
    }.Normalized();

    /// <summary>A token signed with the key only the redirect target serves — iss is A's realm.</summary>
    private string TargetSignedToken() => JwksOctKeyTests.Sign(
        $$"""{"iss":"{{IssuerA}}","sub":"signed-by-target-key","aud":"{{ClientId}}","typ":"Bearer","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}}""",
        _targetKey, SecurityAlgorithms.RsaSha256);

    private async Task<string> CallLowLevel(Op op, KeycloakConfig cfg, HttpClient http)
    {
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        var validator = new JwtValidator(ep.Issuer, KeycloakClient.ValidatorOptionsFor(cfg, ep.Issuer), http);
        var auth = new AuthClient(cfg, ep, validator, http);
        return await Call(op, auth, t => validator.ValidateAsync(t)).ConfigureAwait(false);
    }

    private async Task<string> CallSdk(Op op, KeycloakConfig cfg)
    {
        await using var client = KeycloakClient.Create(cfg);
        return await Call(op, client.Auth, t => client.Auth.ValidateAsync(t)).ConfigureAwait(false);
    }

    private async Task<string> Call(Op op, AuthClient auth, Func<string, Task<ValidatedToken>> validate)
    {
        try
        {
            switch (op)
            {
                case Op.AuthCc:
                    return $"Ok(access_token={(await auth.ClientCredentialsTokenAsync().ConfigureAwait(false)).AccessToken})";
                case Op.AuthCode:
                    return $"Ok(access_token={(await auth.ExchangeCodeAsync(Code, "https://app.example/cb", Verifier).ConfigureAwait(false)).AccessToken})";
                case Op.AuthRefresh:
                    return $"Ok(access_token={(await auth.RefreshAsync(Refresh).ConfigureAwait(false)).AccessToken})";
                case Op.AuthIntrospect:
                    var r = await auth.IntrospectAsync(Introspected).ConfigureAwait(false);
                    return $"Ok(active={r.Active} username={r.Username})";
                case Op.AuthLogout:
                    await auth.LogoutAsync(Refresh).ConfigureAwait(false);
                    return "Ok(())";
                default:
                    var v = await validate(TargetSignedToken()).ConfigureAwait(false);
                    return $"Ok(validated sub={v.Subject})";
            }
        }
        catch (Exception e)
        {
            return Err(e);
        }
    }

    private static string Err(Exception e)
    {
        var extra = e switch
        {
            KeycloakAuthException a => $" status={a.StatusCode?.ToString() ?? "null"} oauth_error={a.OAuthError ?? "null"}",
            _ => "",
        };
        return Clean($"Err({e.GetType().Name}: {e.Message}{extra})");
    }

    private static string Clean(string s) => s.Replace('|', '/').Replace('\r', ' ').Replace('\n', ' ');

    private static List<IRequestMessage> Requests(WireMockServer s, Func<string, bool> keep) =>
        s.LogEntries.Select(e => e.RequestMessage).OfType<IRequestMessage>().Where(r => keep(r.Path ?? "")).ToList();

    private static string Header(IRequestMessage r, string name)
    {
        if (r.Headers is null) return "none";
        foreach (var (k, v) in r.Headers)
        {
            if (string.Equals(k, name, StringComparison.OrdinalIgnoreCase))
                return string.Join(",", v.ToArray());
        }
        return "none";
    }

    private static string BodyText(IRequestMessage r) =>
        r.BodyAsBytes is { Length: > 0 } bytes ? Encoding.UTF8.GetString(bytes) : r.Body ?? "";

    private static string AuthOf(IRequestMessage r)
    {
        var v = Header(r, "Authorization");
        if (v == "none") return "none";
        if (v.StartsWith("Basic ", StringComparison.Ordinal))
        {
            string decoded;
            try { decoded = Encoding.UTF8.GetString(Convert.FromBase64String(v[6..])); }
            catch (FormatException) { decoded = "?"; }
            return decoded == $"{ClientId}:{Secret}" ? "Basic(client_id:client_secret)" : $"Basic({decoded})";
        }
        return $"other({v})";
    }

    private static string BodySecretOf(IRequestMessage r)
    {
        var b = BodyText(r);
        if (b.Length == 0) return "no-body";
        var marks = new List<string>();
        if (b.Contains($"client_secret={Secret}", StringComparison.Ordinal)) marks.Add("client_secret");
        if (b.Contains($"refresh_token={Refresh}", StringComparison.Ordinal)) marks.Add("refresh_token");
        if (b.Contains($"code={Code}", StringComparison.Ordinal)) marks.Add("code");
        if (b.Contains($"code_verifier={Verifier}", StringComparison.Ordinal)) marks.Add("code_verifier");
        if (b.Contains($"token={Introspected}", StringComparison.Ordinal)) marks.Add("introspected_token");
        return marks.Count == 0 ? "none" : string.Join("+", marks);
    }

    private static string BodyOf(IRequestMessage r)
    {
        var b = BodyText(r);
        if (b.Length == 0) return "0B";
        var keys = string.Join(",", b.Split('&').Select(kv => kv.Split('=')[0]));
        return $"{Encoding.UTF8.GetByteCount(b)}B[{keys}]";
    }

    private static string HopOf(IRequestMessage r) => $"{r.Method} auth={AuthOf(r)} body_secret={BodySecretOf(r)}";

    private static string Each(List<IRequestMessage> reqs, Func<IRequestMessage, string> f) =>
        reqs.Count == 0 ? "-" : string.Join(",", reqs.Select(f));

    private string Label(string url) => url.Replace(A, "{A}", StringComparison.Ordinal).Replace(B, "{B}", StringComparison.Ordinal);

    private async Task<string> CellLine(Op op, int status, bool cross, bool sdkPath)
    {
        _a.ResetLogEntries();
        _b.ResetLogEntries();
        var opath = OriginPath(op);
        var targetOrigin = cross ? "B" : "A";
        var location = $"{(cross ? B : A)}/moved{opath}";
        _cell = new Cell(opath, status, location, targetOrigin, op == Op.ValidateJwks3xx);
        var cfg = Config();
        string result;
        if (sdkPath)
        {
            result = await CallSdk(op, cfg);
        }
        else
        {
            using var http = new HttpClient();   // the default a consumer gets with no options
            result = await CallLowLevel(op, cfg, http);
        }
        var targetSrv = cross ? _b : _a;
        var first = Requests(_a, p => p == opath);
        var moved = Requests(targetSrv, p => p.StartsWith("/moved/", StringComparison.Ordinal));
        _cell = null;
        return string.Join("|", new[]
        {
            "CELL",
            sdkPath ? "KeycloakClient.Create(control)" : Ctor(op),
            Name(op),
            status.ToString(System.Globalization.CultureInfo.InvariantCulture),
            cross ? "cross-origin" : "same-origin",
            $"followed={(moved.Count == 0 ? "no" : "yes")}",
            $"method={Each(moved, r => r.Method)}",
            $"body_secret={Each(moved, BodySecretOf)}",
            $"auth={Each(moved, AuthOf)}",
            $"result={result}",
            $"body={Each(moved, BodyOf)}",
            $"ctype={Each(moved, r => Header(r, "Content-Type"))}",
            $"referer={Each(moved, r => Label(Header(r, "Referer")))}",
            $"target_paths={Each(moved, r => r.Path ?? "")}",
            $"origin_hop={Each(first, HopOf)}",
            $"hits=origin:{first.Count}/target:{moved.Count}",
        });
    }

    private static FormUrlEncodedContent SecretForm() => new(new Dictionary<string, string> { ["client_secret"] = Secret });

    private static System.Net.Http.Headers.AuthenticationHeaderValue Basic() =>
        new("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{ClientId}:{Secret}")));

    /// <summary>After the fact: one hop A→B — does the response's RequestMessage.RequestUri differ from the request URL?</summary>
    private async Task<string> DetectSingle(int status)
    {
        _a.ResetLogEntries();
        _b.ResetLogEntries();
        _cell = new Cell("/start", status, B + "/moved/start", "B", false);
        var url = A + "/start";
        using var http = new HttpClient();
        using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = SecretForm() };
        req.Headers.Authorization = Basic();
        using var resp = await http.SendAsync(req);
        var finalUri = resp.RequestMessage?.RequestUri?.ToString() ?? "null";
        var bGot = Requests(_b, p => p == "/moved/start");
        _cell = null;
        return $"DETECT|single hop {status} A->B|request_url={Label(url)}|response.RequestMessage.RequestUri={Label(finalUri)}|status={(int)resp.StatusCode}|url_differs={finalUri != url}|B_got={Each(bGot, HopOf)}";
    }

    /// <summary>After the fact: A 307 → B 307 → A (A answers 200 the second time). The final URI equals the request URL.</summary>
    private async Task<string> DetectBounce()
    {
        _a.ResetLogEntries();
        _b.ResetLogEntries();
        _bounce = new Bounce();
        var url = A + "/token";
        using var http = new HttpClient();
        using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = SecretForm() };
        req.Headers.Authorization = Basic();
        using var resp = await http.SendAsync(req);
        var finalUri = resp.RequestMessage?.RequestUri?.ToString() ?? "null";
        var hop = Requests(_b, p => p == "/hop");
        var aHits = Requests(_a, p => p == "/token");
        _bounce = null;
        return $"DETECT|bounce A-307->B-307->A|request_url={Label(url)}|response.RequestMessage.RequestUri={Label(finalUri)}|status={(int)resp.StatusCode}|url_differs={finalUri != url}|B_got={Each(hop, HopOf)}|A_hits={aHits.Count}|A_hops={Each(aHits, HopOf)}";
    }

    private static string Version(Type t)
    {
        var a = t.Assembly;
        return a.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
            ?? a.GetName().Version?.ToString() ?? "?";
    }

    [Fact]
    public async Task Measure()
    {
        var path = Environment.GetEnvironmentVariable("N3_OUT");
        Assert.False(string.IsNullOrEmpty(path), "set N3_OUT to the output file");
        _out.Add($"ENV|runtime={RuntimeInformation.FrameworkDescription}|System.Net.Http={Version(typeof(HttpClient))}|Duende.IdentityModel={Version(typeof(Duende.IdentityModel.Client.TokenResponse))}|Microsoft.IdentityModel.Protocols.OpenIdConnect={Version(typeof(Microsoft.IdentityModel.Protocols.OpenIdConnect.OpenIdConnectConfiguration))}|WireMock.Net={Version(typeof(WireMockServer))}");
        using (var handler = new HttpClientHandler())
            _out.Add($"API|new HttpClientHandler()|AllowAutoRedirect={handler.AllowAutoRedirect}|MaxAutomaticRedirections={handler.MaxAutomaticRedirections}");
        using (var sockets = new SocketsHttpHandler())
            _out.Add($"API|new SocketsHttpHandler()|AllowAutoRedirect={sockets.AllowAutoRedirect}|MaxAutomaticRedirections={sockets.MaxAutomaticRedirections}");
        _out.Add("HEADER|ctor|op|status|target|followed|method@target|body_secret@target|auth@target|result|body@target|content-type@target|referer@target|paths@target|origin_hop|hits");
        var followed = new int[2];
        var total = new int[2];
        foreach (var sdkPath in new[] { false, true })
        {
            foreach (var op in Ops)
            {
                foreach (var status in Statuses)
                {
                    foreach (var cross in new[] { false, true })
                    {
                        var line = await CellLine(op, status, cross, sdkPath);
                        total[sdkPath ? 1 : 0]++;
                        if (line.Contains("|followed=yes|", StringComparison.Ordinal)) followed[sdkPath ? 1 : 0]++;
                        _out.Add(line);
                    }
                }
            }
        }
        _out.Add($"SUMMARY|consumer new HttpClient() followed {followed[0]}/{total[0]} cells|controls followed {followed[1]}/{total[1]} cells");
        foreach (var status in Statuses)
            _out.Add(await DetectSingle(status));
        _out.Add(await DetectBounce());
        await File.WriteAllLinesAsync(path!, _out);
    }
}
