using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;
using Xunit.Abstractions;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// The discovery document and the JWKS are read whole within the client's timeout, measured from when the request is sent
/// (registry <c>response-read-deadline-divergent</c>, decided 2026-10-29) — on the cold load, and on the refetch a validation
/// asks for.
/// </summary>
/// <remarks>
/// <para>Why: <c>BoundedDocumentRetriever</c> reads after <c>ResponseHeadersRead</c>, so <c>HttpClient.Timeout</c> ends when
/// the headers arrive, and the body had no bound at all — IdentityModel asks for the configuration on
/// <c>CancellationToken.None</c>, and so does the refetch the SDK runs. Measured before the fix (this class on the unchanged
/// retriever — commit message): a document whose last 10 bytes came one every 700 ms was accepted after about 7 s, a stalled
/// one failed only when the server closed the connection (10 s here), and the refetch a validation waited for took as long.</para>
/// <para>Contract: a document still arriving at the deadline fails with what <c>HttpClient.Timeout</c> raises for late headers —
/// <see cref="TaskCanceledException"/> over a <see cref="TimeoutException"/>, no body content — so a validation fails exactly
/// as it does when the headers are late (same exception, same message). The deadline is a cancellation, exact, so the bound is
/// the timeout (1 s) plus 2 s of slack for a machine running other builds; the unchanged code is 4 s or more past it. Controls:
/// headers held past the timeout still fail at the timeout; a document just under the 51,200-byte cap in four pieces 150 ms
/// apart is accepted; a caller's own cancellation stays the caller's; a client without a timeout gets no deadline.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class ResponseReadDeadlineTests
{
    private const int TimeoutMs = 1000;
    private const int GapMs = 700;
    private const int Trickled = 10;
    private const int BoundMs = 3000;
    private const int HealthyGapMs = 150;
    private const int HoldMs = 10_000;

    /// <summary><c>BoundedDocumentRetriever.MaxBytes</c>, written independently on purpose.</summary>
    private const int DocumentCap = 51200;

    /// <summary>Response bytes that must appear in no failure.</summary>
    private const string Marker = "ZdeadlineMARKER0123456789";

    private const string Discovery = "/realms/r/.well-known/openid-configuration";
    private const string Jwks = "/realms/r/protocol/openid-connect/certs";

    private static readonly RsaSecurityKey K1 = new(RSA.Create(2048)) { KeyId = "k1" };
    private static readonly RsaSecurityKey K2 = new(RSA.Create(2048)) { KeyId = "k2" };

    private readonly ITestOutputHelper _out;

    public ResponseReadDeadlineTests(ITestOutputHelper output) => _out = output;

    public static TheoryData<string> Lanes => new() { Discovery, Jwks };

    // ───────────── documents ─────────────

    private static byte[] DiscoveryBody(PacedIdp idp) => Encoding.UTF8.GetBytes(
        $$"""{"issuer":"{{idp.Url}}/realms/r","jwks_uri":"{{idp.Url}}{{Jwks}}","x":"{{Marker}}"}""");

    private static string Jwk(RsaSecurityKey key)
    {
        var p = key.Rsa!.ExportParameters(false);
        return $$"""{"kty":"RSA","use":"sig","alg":"RS256","kid":"{{key.KeyId}}","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}""";
    }

    private static byte[] JwksBody(params RsaSecurityKey[] keys) => Encoding.UTF8.GetBytes(
        $$"""{"keys":[{{string.Join(",", keys.Select(Jwk))}}],"x":"{{Marker}}"}""");

    private static byte[] Body(PacedIdp idp, string lane) => lane == Discovery ? DiscoveryBody(idp) : JwksBody(K1);

    /// <summary><paramref name="body"/> followed by JSON whitespace up to <paramref name="total"/> bytes.</summary>
    private static byte[] Padded(byte[] body, int total)
    {
        var padded = new byte[total];
        Array.Fill(padded, (byte)' ');
        body.CopyTo(padded, 0);
        return padded;
    }

    private static byte[] Head(int length) =>
        Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {length}\r\n\r\n");

    private static PacedIdp.Reply Whole(byte[] body) => new([new(0, [.. Head(body.Length), .. body])]);

    /// <summary>The head and the body at once, but the body's last <see cref="Trickled"/> bytes one every <see cref="GapMs"/>.</summary>
    private static PacedIdp.Reply TrickledBody(byte[] body)
    {
        var pieces = new List<PacedIdp.Piece> { new(0, [.. Head(body.Length), .. body.AsSpan(0, body.Length - Trickled)]) };
        for (var i = body.Length - Trickled; i < body.Length; i++)
            pieces.Add(new(GapMs, [body[i]]));
        return new(pieces);
    }

    /// <summary>The head and the body's first 5 bytes, then silence for <see cref="HoldMs"/> — then the server closes.</summary>
    private static PacedIdp.Reply StalledBody(byte[] body) => new([new(0, [.. Head(body.Length), .. body.AsSpan(0, 5)])], HoldMs);

    /// <summary>Nothing for 3 s, then the whole response — the headers are late.</summary>
    private static PacedIdp.Reply LateHeaders(byte[] body) => new([new(3 * TimeoutMs, [.. Head(body.Length), .. body])]);

    /// <summary>A body just under the cap in four pieces <see cref="HealthyGapMs"/> apart.</summary>
    private static PacedIdp.Reply HealthyBody(byte[] body)
    {
        byte[] all = [.. Head(body.Length), .. body];
        var quarter = all.Length / 4;
        var pieces = new List<PacedIdp.Piece>();
        for (var i = 0; i < 4; i++)
        {
            var from = i * quarter;
            var to = i == 3 ? all.Length : from + quarter;
            pieces.Add(new(i == 0 ? 0 : HealthyGapMs, all[from..to]));
        }
        return new(pieces);
    }

    // ───────────── calls ─────────────

    private sealed record Outcome(object? Result, Exception? Thrown, long Ms)
    {
        public override string ToString() =>
            (Thrown is not null ? $"{Thrown.GetType().Name}: {Thrown.Message}"
                : Result is string { Length: > 64 } document ? $"accepted a {document.Length}-char document" : $"accepted {Result}")
            + $" · {Ms} ms";
    }

    private static async Task<Outcome> TimeAsync(Func<Task<object?>> call)
    {
        var watch = Stopwatch.StartNew();
        try
        {
            var result = await call();
            return new(result, null, watch.ElapsedMilliseconds);
        }
        catch (Exception e)
        {
            return new(null, e, watch.ElapsedMilliseconds);
        }
    }

    private static string Sign(PacedIdp idp, RsaSecurityKey key) => new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
    {
        Issuer = $"{idp.Url}/realms/r",
        Audience = "c",
        Expires = DateTime.UtcNow.AddMinutes(5),
        Claims = new Dictionary<string, object> { ["sub"] = "u1" },
        SigningCredentials = new SigningCredentials(key, SecurityAlgorithms.RsaSha256),
    });

    private static KeycloakClient Facade(PacedIdp idp) =>
        KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s", ReadTimeoutMs = TimeoutMs });

    /// <summary>One cold-cache validation through the public API, with <paramref name="lane"/> answered by <paramref name="shape"/>
    /// and the other document whole.</summary>
    private static async Task<Outcome> ValidateAsync(string lane, Func<byte[], PacedIdp.Reply> shape)
    {
        PacedIdp? self = null;
        using var idp = new PacedIdp((path, _) =>
        {
            var body = Body(self!, path);
            return path == lane ? shape(body) : Whole(body);
        });
        self = idp;
        await using var kc = Facade(idp);
        var token = Sign(idp, K1);
        return await TimeAsync(async () => (await kc.Auth.ValidateAsync(token)).Subject);
    }

    private void Report(string label, Outcome o) => _out.WriteLine($"[ResponseReadDeadlineTests] {label} → {o}");

    // ───────────── the public lane ─────────────

    /// <summary>(1) A trickled document fails at the deadline — as a validation whose headers were late fails (same type, same
    /// message). Before: accepted after about 7 s, both documents.</summary>
    [Theory]
    [MemberData(nameof(Lanes))]
    public async Task A_trickled_document_fails_at_the_deadline(string lane)
    {
        var late = await ValidateAsync(lane, LateHeaders);
        var o = await ValidateAsync(lane, TrickledBody);
        Report($"{lane} trickled", o);
        Report($"{lane} late headers (control)", late);
        var thrown = Assert.IsType<KeycloakTokenValidationException>(o.Thrown);
        Assert.True(o.Ms < BoundMs, $"must fail within {BoundMs} ms — {o}");
        Assert.Equal(Assert.IsType<KeycloakTokenValidationException>(late.Thrown).Message, thrown.Message);
        Assert.DoesNotContain(Marker, thrown.ToString(), StringComparison.Ordinal);
    }

    /// <summary>(1) A stalled document fails at the deadline too — before, it failed only when the server closed the
    /// connection (10 s here; the registry measured 30 s against a 30 s hold).</summary>
    [Theory]
    [MemberData(nameof(Lanes))]
    public async Task A_stalled_document_fails_at_the_deadline(string lane)
    {
        var o = await ValidateAsync(lane, StalledBody);
        Report($"{lane} stalled", o);
        Assert.IsType<KeycloakTokenValidationException>(o.Thrown);
        Assert.True(o.Ms >= TimeoutMs - 100 && o.Ms < BoundMs, $"must fail at about the timeout — {o}");
    }

    /// <summary>Control — headers held past the timeout fail at the timeout (<c>HttpClient.Timeout</c>, unchanged).</summary>
    [Theory]
    [MemberData(nameof(Lanes))]
    public async Task Control_late_headers_still_fail_at_the_client_timeout(string lane)
    {
        var o = await ValidateAsync(lane, LateHeaders);
        Report($"{lane} late headers", o);
        Assert.IsType<KeycloakTokenValidationException>(o.Thrown);
        Assert.True(o.Ms >= TimeoutMs - 100 && o.Ms < BoundMs, $"must fail at about the timeout — {o}");
    }

    /// <summary>Control — a document just under the cap in four pieces inside the deadline is accepted (no false deadline).</summary>
    [Theory]
    [MemberData(nameof(Lanes))]
    public async Task Control_a_healthy_document_just_under_the_cap_is_accepted(string lane)
    {
        var o = await ValidateAsync(lane, body => HealthyBody(Padded(body, DocumentCap - 1)));
        Report($"{lane} healthy", o);
        Assert.Null(o.Thrown);
        Assert.Equal("u1", o.Result);
    }

    /// <summary>(1) The refetch a validation asks for (an unknown kid against a warm cache) is bounded too — it runs on
    /// <c>CancellationToken.None</c> under the SDK's own timeout, and the validation waiting for it fails at the deadline
    /// instead of waiting for the trickle. Before: the validation waited about 7 s and then accepted the rotated-in key.</summary>
    [Fact]
    public async Task A_refetch_a_validation_asks_for_ends_at_the_deadline()
    {
        PacedIdp? self = null;
        using var idp = new PacedIdp((path, hit) => path == Jwks
            ? (hit == 1 ? Whole(JwksBody(K1)) : TrickledBody(JwksBody(K1, K2)))
            : Whole(DiscoveryBody(self!)));
        self = idp;
        await using var kc = Facade(idp);
        Assert.Equal("u1", (await kc.Auth.ValidateAsync(Sign(idp, K1))).Subject); // the cold load: k1 only
        var rotated = Sign(idp, K2);
        var o = await TimeAsync(async () => (await kc.Auth.ValidateAsync(rotated)).Subject);
        Report("refetch trickled", o);
        Assert.IsType<KeycloakTokenValidationException>(o.Thrown);
        Assert.True(o.Ms < BoundMs, $"must fail within {BoundMs} ms — {o}");
        Assert.Equal(2, idp.Hits(Jwks)); // the refetch went out, and only once
    }

    // ───────────── the retriever ─────────────

    private static BoundedDocumentRetriever Retriever(TimeSpan timeout) => new(new HttpClient { Timeout = timeout }, requireHttps: false);

    /// <summary>The deadline raises what <c>HttpClient.Timeout</c> raises for late headers: <see cref="TaskCanceledException"/>
    /// over a <see cref="TimeoutException"/> — callers that convert one convert the other — with no body content.</summary>
    [Fact]
    public async Task The_deadline_raises_what_the_client_timeout_raises()
    {
        using var idp = new PacedIdp((path, _) => path == "/late" ? LateHeaders(JwksBody(K1)) : TrickledBody(JwksBody(K1)));
        var late = await TimeAsync(async () => await Retriever(TimeSpan.FromMilliseconds(TimeoutMs)).GetDocumentAsync($"{idp.Url}/late", CancellationToken.None));
        var o = await TimeAsync(async () => await Retriever(TimeSpan.FromMilliseconds(TimeoutMs)).GetDocumentAsync($"{idp.Url}/trickled", CancellationToken.None));
        Report("retriever trickled", o);
        Report("retriever late headers (control)", late);
        var timeout = Assert.IsType<TaskCanceledException>(late.Thrown);
        Assert.IsType<TimeoutException>(timeout.InnerException);
        var thrown = Assert.IsType<TaskCanceledException>(o.Thrown);
        Assert.IsType<TimeoutException>(thrown.InnerException);
        Assert.True(o.Ms < BoundMs, $"must fail within {BoundMs} ms — {o}");
        Assert.DoesNotContain(Marker, thrown.ToString(), StringComparison.Ordinal);
    }

    /// <summary>A caller's own cancellation during the body read stays the caller's — the <see cref="TaskCanceledException"/> the
    /// read raised before the deadline existed, the caller's token on it, no timeout under it — so it is never mistaken for the
    /// deadline (or the other way round).</summary>
    [Fact]
    public async Task A_callers_cancellation_during_the_body_stays_the_callers()
    {
        using var idp = new PacedIdp((_, _) => StalledBody(JwksBody(K1)));
        using var cts = new CancellationTokenSource(300);
        var o = await TimeAsync(async () => await Retriever(TimeSpan.FromSeconds(30)).GetDocumentAsync($"{idp.Url}{Jwks}", cts.Token));
        Report("retriever caller cancelled", o);
        var cancelled = Assert.IsType<TaskCanceledException>(o.Thrown);
        Assert.Equal(cts.Token, cancelled.CancellationToken);
        Assert.IsNotType<TimeoutException>(cancelled.InnerException);
        Assert.True(o.Ms < BoundMs, $"must end soon after the caller cancelled — {o}");
    }

    /// <summary>A client without a timeout (<see cref="Timeout.InfiniteTimeSpan"/>) gets no deadline — its limits are its own.</summary>
    [Fact]
    public async Task A_client_without_a_timeout_gets_no_deadline()
    {
        using var idp = new PacedIdp((_, _) => HealthyBody(JwksBody(K1)));
        var o = await TimeAsync(async () => await Retriever(Timeout.InfiniteTimeSpan).GetDocumentAsync($"{idp.Url}{Jwks}", CancellationToken.None));
        Report("retriever no timeout", o);
        Assert.Null(o.Thrown);
    }
}

/// <summary>
/// A raw-socket HTTP/1.1 server on kept-alive connections that writes each response as timed pieces — a piece waits its delay,
/// then is written. A reply may end by holding the connection silent for a while, then closing it. Requests are counted by path.
/// </summary>
internal sealed class PacedIdp : IDisposable
{
    internal sealed record Piece(int DelayMs, byte[] Bytes);

    /// <summary>The pieces of one response; with <paramref name="HoldMs"/> above 0 the server then writes nothing for that long
    /// and closes the connection.</summary>
    internal sealed record Reply(IReadOnlyList<Piece> Pieces, int HoldMs = 0);

    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _cts = new();
    private readonly ConcurrentBag<TcpClient> _clients = new();
    private readonly ConcurrentDictionary<string, int> _hits = new();
    private readonly Func<string, int, Reply> _route;
    private readonly Task _loop;

    /// <param name="route">The reply for a path and the how-manyth request for that path it is (from 1).</param>
    public PacedIdp(Func<string, int, Reply> route)
    {
        _route = route;
        _listener.Start();
        Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
        _loop = Task.Run(AcceptLoopAsync, CancellationToken.None);
    }

    public string Url { get; }

    public int Hits(string path) => _hits.TryGetValue(path, out var n) ? n : 0;

    private async Task AcceptLoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_cts.Token); }
            catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException) { return; }
            _clients.Add(client);
            _ = Task.Run(() => ServeAsync(client), CancellationToken.None);
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var pending = new List<byte>();
                while (await ReadPathAsync(stream, pending) is { } path)
                {
                    var reply = _route(path, _hits.AddOrUpdate(path, 1, (_, n) => n + 1));
                    foreach (var piece in reply.Pieces)
                    {
                        if (piece.DelayMs > 0)
                            await Task.Delay(piece.DelayMs, _cts.Token);
                        await stream.WriteAsync(piece.Bytes, _cts.Token);
                        await stream.FlushAsync(_cts.Token);
                    }
                    if (reply.HoldMs > 0)
                    {
                        await Task.Delay(reply.HoldMs, _cts.Token);
                        return; // closes the connection
                    }
                }
            }
            catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or OperationCanceledException)
            {
                // The client left — the normal end once a deadline has cut the response.
            }
        }
    }

    /// <summary>The next request's path (its head read; GET requests carry no body), or <c>null</c> when the client closed.</summary>
    private async Task<string?> ReadPathAsync(NetworkStream stream, List<byte> pending)
    {
        int end;
        while ((end = IndexOfHeadEnd(pending)) < 0)
        {
            var chunk = new byte[4096];
            var n = await stream.ReadAsync(chunk, _cts.Token);
            if (n == 0)
                return null;
            pending.AddRange(chunk.AsSpan(0, n).ToArray());
        }
        var head = Encoding.ASCII.GetString(pending.GetRange(0, end).ToArray());
        pending.RemoveRange(0, end + 4);
        return head.Split("\r\n")[0].Split(' ')[1].Split('?')[0];
    }

    private static int IndexOfHeadEnd(List<byte> data)
    {
        for (var i = 0; i + 3 < data.Count; i++)
        {
            if (data[i] == '\r' && data[i + 1] == '\n' && data[i + 2] == '\r' && data[i + 3] == '\n')
                return i;
        }
        return -1;
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener.Dispose();
        foreach (var client in _clients)
            client.Dispose();
        try { _loop.Wait(5000, CancellationToken.None); }
        catch (AggregateException)
        {
            // the accept loop ended with the listener
        }
        _cts.Dispose();
    }
}
