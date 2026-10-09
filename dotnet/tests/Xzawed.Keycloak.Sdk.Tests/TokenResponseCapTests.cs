using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Xunit;
using Xunit.Abstractions;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// The facade client reads every token, introspection and logout response through one cap — exactly 1,048,576 bytes
/// (<c>AuthClient.MaxTokenResponseBytes</c>), registry <c>token-response-size-unbounded</c>. Admin REST responses are not
/// capped: the admin facade builds its own client (<c>AdminClient.CreateAsync</c>).
/// </summary>
/// <remarks>
/// <para>Measured before the fix (2026-10-05, fake IdP, one process per lane): a usable token response followed by 32 MiB
/// of JSON whitespace was ACCEPTED on all five lanes — client credentials, refresh, code exchange, introspection and the
/// admin lane's own token fetch — with the process peak going from 35 MB to 195 MB and 317 MB allocated during the call;
/// a 1,048,577-byte body was accepted too. The facade client's <c>MaxResponseContentBufferSize</c> was
/// <c>int.MaxValue</c>.</para>
/// <para>The lower edge is Keycloak's own: 26.6 accepts a bearer of 65,459 bytes and answers 431 to 65,460 (registry
/// measurement, 2026-10-03), so the cap is sixteen times the largest token the server will take.</para>
/// <para>The IdP here is a raw socket: the framing (chunked or Content-Length) and the body length are exact, and a large
/// body is written from one reusable buffer — WireMock would allocate the whole body in this process and the
/// allocation tests below would measure the server.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class TokenResponseCapTests
{
    /// <summary>The cap, written independently of <c>AuthClient.MaxTokenResponseBytes</c> on purpose — a boundary test that read
    /// the constant would move with it.</summary>
    internal const int Cap = 1024 * 1024;

    /// <summary>The longest bearer Keycloak 26.6 accepts with its default settings (registry measurement, 2026-10-03).</summary>
    internal const int KeycloakMaxBearer = 65459;

    private const string Prefix = "/realms/r/protocol/openid-connect";

    /// <summary>One lane: the public call, the failure message it must carry above the cap, and the body the IdP pads.</summary>
    internal sealed record Lane(string Name, string Path, string? FailurePrefix, Func<KeycloakClient, string, Task<string>> Run);

    /// <summary>Every lane that reads a response through the facade client. <c>Run</c> returns what proves the response was
    /// used — the token it handed back, or what the IdP saw.</summary>
    internal static readonly Lane[] Lanes =
    {
        new("ClientCredentialsTokenAsync", $"{Prefix}/token", "Client credentials grant failed",
            async (kc, _) => (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken),
        new("RefreshAsync", $"{Prefix}/token", "Token refresh failed",
            async (kc, _) => (await kc.Auth.RefreshAsync("rt-sent")).AccessToken),
        new("ExchangeCodeAsync", $"{Prefix}/token", "Authorization code exchange failed",
            async (kc, _) => (await kc.Auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43))).AccessToken),
        new("IntrospectAsync", $"{Prefix}/token/introspect", "Token introspection failed",
            async (kc, token) => (await kc.Auth.IntrospectAsync(token)).Claims["token_len"]?.ToString() ?? "null"),
        new("AdminAsync (its token fetch)", $"{Prefix}/token", "Client credentials grant failed",
            async (kc, _) => (await (await kc.AdminAsync()).Realms.ListAsync())[0].Realm ?? "null"),
        new("LogoutAsync", $"{Prefix}/logout", "Logout failed",
            async (kc, token) => { await kc.Auth.LogoutAsync(token); return "logged out"; }),
    };

    public static IEnumerable<object[]> LaneNames => Lanes.Select(l => new object[] { l.Name });

    public static IEnumerable<object[]> LanesByFraming =>
        Lanes.SelectMany(l => new[] { new object[] { l.Name, true }, new object[] { l.Name, false } });

    /// <summary>The usable JSON head a lane's endpoint answers with (the rest of a padded body is JSON whitespace).</summary>
    internal static byte[] HeadFor(string path, string token, CapIdp.Req req) => Encoding.UTF8.GetBytes(path switch
    {
        _ when path.EndsWith("/token/introspect", StringComparison.Ordinal) =>
            $$"""{"active":true,"sub":"u1","client_id":"c","token_len":{{FormValue(req.Body, "token").Length}}}""",
        _ when path.EndsWith("/token", StringComparison.Ordinal) =>
            $$"""{"access_token":"{{token}}","token_type":"Bearer","expires_in":300,"refresh_token":"rt-1"}""",
        _ => "{}",
    });

    internal static string FormValue(string form, string name) =>
        form.Split('&').Select(p => p.Split('=', 2)).Where(kv => kv[0] == name).Select(kv => Uri.UnescapeDataString(kv[1].Replace('+', ' '))).FirstOrDefault() ?? "";

    /// <summary>An IdP whose every OIDC endpoint answers with a body of <paramref name="total"/> bytes (usable head + spaces),
    /// and whose admin endpoint reports the bearer it received.</summary>
    internal static CapIdp PaddedIdp(string token, long total, bool chunked) => new(req =>
    {
        if (req.Path.StartsWith("/admin/", StringComparison.Ordinal))
        {
            var bearer = req.Authorization is { } a && a.StartsWith("Bearer ", StringComparison.Ordinal) ? a["Bearer ".Length..] : "";
            return CapIdp.Resp.Json(200, $$"""[{"realm":"bearer-len-{{bearer.Length}}-match-{{(bearer == token).ToString().ToLowerInvariant()}}"}]""");
        }
        return new CapIdp.Resp(200, HeadFor(req.Path, token, req), total, chunked);
    });

    private static KeycloakClient Facade(CapIdp idp) =>
        KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s" });

    /// <summary>A usable bearer of exactly 65,459 bytes goes through every lane intact — the cap must not refuse what the
    /// server accepts.</summary>
    [Theory]
    [MemberData(nameof(LaneNames))]
    public async Task The_largest_bearer_Keycloak_accepts_succeeds_on_every_lane(string laneName)
    {
        var lane = Lanes.Single(l => l.Name == laneName);
        var token = UsableToken(KeycloakMaxBearer);
        using var idp = PaddedIdp(token, total: 0, chunked: false);
        await using var kc = Facade(idp);

        var got = await lane.Run(kc, token);

        Assert.Equal(ExpectedUse(lane, token), got);
        // The token reached the IdP whole wherever a lane sends one.
        if (lane.Name is "IntrospectAsync" or "LogoutAsync")
            Assert.Contains(idp.Seen, r => r.Path == lane.Path && FormValue(r.Body, lane.Name == "LogoutAsync" ? "refresh_token" : "token") == token);
    }

    /// <summary>A body of exactly the cap is used as it is today; one byte more fails with the SDK's transport error for
    /// that call — and the admin lane sends no admin request.</summary>
    [Theory]
    [MemberData(nameof(LanesByFraming))]
    public async Task A_body_of_exactly_the_cap_succeeds_and_one_byte_more_fails(string laneName, bool chunked)
    {
        var lane = Lanes.Single(l => l.Name == laneName);
        var token = UsableToken(600);

        using (var atCap = PaddedIdp(token, Cap, chunked))
        {
            await using var kc = Facade(atCap);
            Assert.Equal(ExpectedUse(lane, token), await lane.Run(kc, token));
        }

        using var over = PaddedIdp(token, Cap + 1, chunked);
        await using var kc2 = Facade(over);
        var ex = await Assert.ThrowsAsync<KeycloakTransportException>(() => lane.Run(kc2, token));
        Assert.Equal($"{lane.FailurePrefix}: response exceeds a size limit", ex.Message);
        Assert.IsType<HttpRequestException>(ex.InnerException);
        Assert.Equal(HttpRequestError.ConfigurationLimitExceeded, ((HttpRequestException)ex.InnerException!).HttpRequestError);
        Assert.DoesNotContain(over.Seen, r => r.Path.StartsWith("/admin/", StringComparison.Ordinal));
    }

    /// <summary>The admin lane re-fetches its token when the cached one lapses: an oversized response there fails the admin
    /// call before it is sent.</summary>
    [Fact]
    public async Task An_oversized_token_response_on_the_admin_lanes_refetch_sends_no_admin_request()
    {
        var token = UsableToken(600);
        var oversized = false;
        using var idp = new CapIdp(req =>
        {
            if (req.Path.StartsWith("/admin/", StringComparison.Ordinal))
                return CapIdp.Resp.Json(200, """[{"realm":"r"}]""");
            // expires_in 1 is inside the provider's 30 s skew, so every admin request fetches a new token.
            var head = Encoding.UTF8.GetBytes($$"""{"access_token":"{{token}}","token_type":"Bearer","expires_in":1}""");
            return new CapIdp.Resp(200, head, oversized ? Cap + 1 : 0, Chunked: true);
        });
        await using var kc = Facade(idp);
        var admin = await kc.AdminAsync();
        Assert.Single(await admin.Realms.ListAsync());
        var adminRequests = idp.Seen.Count(r => r.Path.StartsWith("/admin/", StringComparison.Ordinal));

        oversized = true;
        var ex = await Assert.ThrowsAsync<KeycloakTransportException>(() => admin.Realms.ListAsync());

        Assert.Equal("Client credentials grant failed: response exceeds a size limit", ex.Message);
        Assert.Equal(adminRequests, idp.Seen.Count(r => r.Path.StartsWith("/admin/", StringComparison.Ordinal)));
    }

    /// <summary>Admin REST is not capped — a user list is legitimately large, and the admin facade has its own client.</summary>
    [Fact]
    public async Task An_admin_response_above_the_cap_is_not_capped()
    {
        var token = UsableToken(600);
        var big = new StringBuilder("[");
        for (var i = 0; big.Length <= Cap + 4096; i++)
            big.Append(i == 0 ? "" : ",").Append($$"""{"id":"{{i:D12}}","realm":"realm-{{i:D12}}","enabled":true}""");
        var list = big.Append(']').ToString();
        using var idp = new CapIdp(req => req.Path.StartsWith("/admin/", StringComparison.Ordinal)
            ? CapIdp.Resp.Json(200, list)
            : new CapIdp.Resp(200, HeadFor(req.Path, token, req), 0, Chunked: false));
        await using var kc = Facade(idp);

        var realms = await (await kc.AdminAsync()).Realms.ListAsync();

        Assert.True(Encoding.UTF8.GetByteCount(list) > Cap, "the admin body must be above the cap for this test to mean anything");
        Assert.Equal(list.Count(c => c == '{'), realms.Count);
    }

    /// <summary>The token a usable response carries, and what each lane hands back for it.</summary>
    private static string ExpectedUse(Lane lane, string token) => lane.Name switch
    {
        "IntrospectAsync" => token.Length.ToString(System.Globalization.CultureInfo.InvariantCulture),
        "AdminAsync (its token fetch)" => $"bearer-len-{token.Length}-match-true",
        "LogoutAsync" => "logged out",
        _ => token,
    };

    /// <summary>A bearer-shaped token of exactly <paramref name="length"/> ASCII characters (JWT alphabet, no JSON escaping).</summary>
    internal static string UsableToken(int length)
    {
        var sb = new StringBuilder("eyJ", length);
        while (sb.Length < length)
            sb.Append((char)('a' + (sb.Length % 26)));
        return sb.ToString(0, length);
    }
}

/// <summary>
/// Allocation while judging a response body — process-wide counters, so this collection runs alone
/// (<c>DisableParallelization</c>: after every parallel collection, one test at a time).
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class AllocationCollection
{
    public const string Name = "allocation (runs alone)";
}

[Trait("Category", "Unit")]
[Collection(AllocationCollection.Name)]
public sealed class TokenResponseCapAllocationTests
{
    private const int Cap = TokenResponseCapTests.Cap;
    private const int MiB = 1 << 20;
    private readonly ITestOutputHelper _out;

    public TokenResponseCapAllocationTests(ITestOutputHelper output) => _out = output;

    public static IEnumerable<object[]> HugeBodies =>
        from size in new[] { 16 * MiB, 32 * MiB }
        from chunked in new[] { true, false }
        select new object[] { size, chunked };

    /// <summary>A 16–32 MiB body fails, and what judging it allocates does not grow with it: the buffer doubles up to the cap
    /// and the piece that would cross it is refused unstored — measured 2.5 MB chunked for both sizes, and under 0.1 MB with
    /// a Content-Length (refused before the body is read), against 317 MiB allocated for 32 MiB before the fix.
    /// ⚠️ The bound is 8× the cap, not 4×: the counter is process-wide, so it also sees the in-process fake IdP writing the
    /// padding — CI (.NET 10 SDK runner) measured 4,196,504 bytes for 16 MiB chunked, 2,200 bytes over 4×. That run still
    /// drained up to 1 MiB after the refusal; the handler no longer does (<c>DrainAfterRejectionTests</c>), and locally that
    /// changed nothing here (16 MiB chunked: 2,502,680 bytes before, 2,509,856 after). A full read still allocates at least
    /// the body.</summary>
    [Theory]
    [MemberData(nameof(HugeBodies))]
    public async Task A_huge_body_fails_with_bounded_allocation(int size, bool chunked)
    {
        var token = TokenResponseCapTests.UsableToken(600);
        using var idp = TokenResponseCapTests.PaddedIdp(token, size, chunked);
        await using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s" });
        // Warm the path once (JIT, first-use statics) so the measured call is the steady state.
        await Assert.ThrowsAsync<KeycloakTransportException>(() => kc.Auth.ClientCredentialsTokenAsync());

        var before = GC.GetTotalAllocatedBytes(precise: true);
        var ex = await Record.ExceptionAsync(() => kc.Auth.ClientCredentialsTokenAsync());
        var allocated = GC.GetTotalAllocatedBytes(precise: true) - before;

        _out.WriteLine($"{size} bytes {(chunked ? "chunked" : "content-length")}: {ex?.GetType().Name ?? "accepted"} · allocated {allocated}");
        Assert.IsType<KeycloakTransportException>(ex);
        Assert.True(allocated < 8L * Cap, $"judging a {size}-byte body allocated {allocated} bytes — not bounded by the cap");
    }

    /// <summary>A small body allocates in proportion to itself — nothing near the cap is reserved per response.</summary>
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task A_2_KiB_body_allocates_nothing_near_the_cap(bool chunked)
    {
        var token = TokenResponseCapTests.UsableToken(600);
        using var idp = TokenResponseCapTests.PaddedIdp(token, 2048, chunked);
        await using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s" });
        Assert.Equal(token, (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken); // warm-up

        var before = GC.GetTotalAllocatedBytes(precise: true);
        var got = (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken;
        var allocated = GC.GetTotalAllocatedBytes(precise: true) - before;

        _out.WriteLine($"2048 bytes {(chunked ? "chunked" : "content-length")}: allocated {allocated}");
        Assert.Equal(token, got);
        Assert.True(allocated < Cap / 4, $"judging a 2 KiB body allocated {allocated} bytes — a quarter of the cap or more");
    }
}

/// <summary>
/// A minimal HTTP/1.1 server on a raw socket — one request per connection (<c>Connection: close</c>), exact framing, and a
/// padded body written from one reusable buffer of spaces.
/// </summary>
internal sealed class CapIdp : IDisposable
{
    internal sealed record Req(string Method, string Path, string? Authorization, string Body);

    /// <summary>A response: <paramref name="Head"/> followed by JSON whitespace up to <paramref name="TotalBytes"/> (0 = the
    /// head alone).</summary>
    internal sealed record Resp(int Status, byte[] Head, long TotalBytes, bool Chunked)
    {
        public static Resp Json(int status, string body) => new(status, Encoding.UTF8.GetBytes(body), 0, false);
    }

    private static readonly byte[] Spaces = CreateSpaces();
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _cts = new();
    private readonly Func<Req, Resp> _route;
    private readonly Task _loop;

    public CapIdp(Func<Req, Resp> route)
    {
        _route = route;
        _listener.Start();
        Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
        _loop = Task.Run(AcceptLoopAsync);
    }

    public string Url { get; }

    public ConcurrentQueue<Req> Seen { get; } = new();

    private static byte[] CreateSpaces()
    {
        var b = new byte[65536];
        Array.Fill(b, (byte)' ');
        return b;
    }

    private async Task AcceptLoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_cts.Token); }
            catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException) { return; }
            _ = Task.Run(() => ServeAsync(client));
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var req = await ReadRequestAsync(stream);
                Seen.Enqueue(req);
                await WriteAsync(stream, _route(req));
            }
            catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or OperationCanceledException)
            {
                // The client stopped reading — exactly what a cap does.
            }
        }
    }

    private async Task<Req> ReadRequestAsync(NetworkStream stream)
    {
        var buf = new MemoryStream();
        var chunk = new byte[16384];
        int headEnd;
        while ((headEnd = IndexOfHeaderEnd(buf)) < 0)
        {
            var n = await stream.ReadAsync(chunk, _cts.Token);
            if (n == 0) throw new IOException("request ended before its headers");
            buf.Write(chunk, 0, n);
        }
        var head = Encoding.ASCII.GetString(buf.GetBuffer(), 0, headEnd).Split("\r\n");
        var requestLine = head[0].Split(' ');
        var headers = head.Skip(1).Select(l => l.Split(':', 2)).Where(kv => kv.Length == 2)
            .ToDictionary(kv => kv[0].Trim(), kv => kv[1].Trim(), StringComparer.OrdinalIgnoreCase);
        var length = headers.TryGetValue("Content-Length", out var cl) ? int.Parse(cl, System.Globalization.CultureInfo.InvariantCulture) : 0;
        var bodyStart = headEnd + 4;
        while (buf.Length - bodyStart < length)
        {
            var n = await stream.ReadAsync(chunk, _cts.Token);
            if (n == 0) throw new IOException("request ended before its body");
            buf.Write(chunk, 0, n);
        }
        var body = Encoding.UTF8.GetString(buf.GetBuffer(), bodyStart, length);
        return new Req(requestLine[0], requestLine[1].Split('?')[0], headers.GetValueOrDefault("Authorization"), body);
    }

    private static int IndexOfHeaderEnd(MemoryStream buf)
    {
        var b = buf.GetBuffer();
        for (var i = 0; i + 3 < buf.Length; i++)
        {
            if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n')
                return i;
        }
        return -1;
    }

    private async Task WriteAsync(NetworkStream stream, Resp resp)
    {
        var total = Math.Max(resp.TotalBytes, resp.Head.Length);
        var framing = resp.Chunked ? "Transfer-Encoding: chunked" : $"Content-Length: {total}";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(
            $"HTTP/1.1 {resp.Status} X\r\nContent-Type: application/json\r\nConnection: close\r\n{framing}\r\n\r\n"), _cts.Token);
        await WriteBodyPartAsync(stream, resp.Head, resp.Head.Length, resp.Chunked);
        for (var left = total - resp.Head.Length; left > 0; left -= Spaces.Length)
            await WriteBodyPartAsync(stream, Spaces, (int)Math.Min(left, Spaces.Length), resp.Chunked);
        if (resp.Chunked)
            await stream.WriteAsync("0\r\n\r\n"u8.ToArray(), _cts.Token);
    }

    private async Task WriteBodyPartAsync(NetworkStream stream, byte[] data, int count, bool chunked)
    {
        if (count == 0)
            return;
        if (chunked)
            await stream.WriteAsync(Encoding.ASCII.GetBytes($"{count:x}\r\n"), _cts.Token);
        await stream.WriteAsync(data.AsMemory(0, count), _cts.Token);
        if (chunked)
            await stream.WriteAsync("\r\n"u8.ToArray(), _cts.Token);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener.Stop();
        try { _loop.Wait(TimeSpan.FromSeconds(5)); }
        catch (AggregateException) { /* the accept loop ended on the cancellation */ }
        _cts.Dispose();
    }
}
