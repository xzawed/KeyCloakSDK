using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Keycloak.AuthServices.Sdk.Admin.Models;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// After the SDK refuses a response it has not read to the end — a token, introspection or logout body over the 1 MiB cap,
/// a discovery or JWKS document over its 51,200-byte cap — it reads no more of it: the connection is closed, not drained
/// to be reused (registry <c>wave4-hardening-dotnet</c> (3)).
/// </summary>
/// <remarks>
/// <para>Measured before the fix (2026-10-09, .NET 8.0.23, raw-socket IdP, bytes the client read counted with the
/// <c>System.Net.Sockets</c> telemetry): <c>SocketsHttpHandler</c> went on reading a refused response up to
/// <c>MaxResponseDrainSize</c> (1 MiB by default), for up to <c>ResponseDrainTimeout</c> (2 s), to put the connection back
/// in the pool. A 32 MiB chunked token body: 2,097,588 bytes read, the cap plus 1 MiB. A body ending 256 KiB past the cap,
/// and a Content-Length body of the cap + 1, were read to the end and the next request reused the connection; one that
/// stalled past the cap held it 2,012 ms after the call returned. A 32 MiB chunked JWKS: 1,102,257 bytes read; a 1 MiB
/// Content-Length JWKS was read whole. Only a Content-Length beyond what the drain allows went unread (32 MiB: 141 bytes).
/// Admin REST responses are buffered whole before anything judges them — they have no cap — so nothing is left to drain
/// there (32 MiB undecodable body: read whole, before and after).</para>
/// <para>The signal is the fate of the connection that carried the refused response: a drained one is back in the pool
/// and stays open, an undrained one is closed at once. That holds whatever the socket buffers hold. Bytes the server
/// managed to write do not: the buffers absorbed up to 327 KB here, and loopback buffers grow far larger elsewhere.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class DrainAfterRejectionTests
{
    private const int Cap = TokenResponseCapTests.Cap;

    /// <summary><c>BoundedDocumentRetriever.MaxBytes</c>, written independently on purpose.</summary>
    private const int DocumentCap = 51200;

    /// <summary>Past the cap and well inside the 1 MiB a drain would read, and far beyond any read-ahead buffer.</summary>
    private const int Tail = 256 * 1024;

    private static readonly TimeSpan CloseWithin = TimeSpan.FromSeconds(5);

    private static KeycloakClient Facade(KeepAliveIdp idp) =>
        KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s" });

    /// <summary>The body ends inside what a drain reads — chunked, 256 KiB past the cap; Content-Length, the cap + 1 with its
    /// first bytes in the same write as the head — so a drained connection would be reused.</summary>
    [Theory]
    [MemberData(nameof(TokenResponseCapTests.LanesByFraming), MemberType = typeof(TokenResponseCapTests))]
    public async Task A_response_over_the_token_cap_closes_its_connection_instead_of_being_read_to_the_end(string laneName, bool chunked)
    {
        var lane = TokenResponseCapTests.Lanes.Single(l => l.Name == laneName);
        var token = TokenResponseCapTests.UsableToken(600);
        var total = chunked ? Cap + Tail : Cap + 1;
        using var idp = new KeepAliveIdp(req => req.Path == lane.Path
            ? new KeepAliveIdp.Resp(Encoding.UTF8.GetBytes($$"""{"access_token":"{{token}}","token_type":"Bearer","expires_in":300}"""), total, chunked)
            : KeepAliveIdp.Resp.Json("{}"));
        await using var kc = Facade(idp);

        var ex = await Assert.ThrowsAsync<KeycloakTransportException>(() => lane.Run(kc, token));

        Assert.Equal($"{lane.FailurePrefix}: response exceeds a size limit", ex.Message);
        await AssertClosedAsync(idp, lane.Path, chunked);
    }

    public static IEnumerable<object[]> DocumentsByFraming =>
        from document in new[] { "discovery", "jwks" }
        from chunked in new[] { true, false }
        select new object[] { document, chunked };

    /// <summary>Discovery and the JWKS are read as streams through their own cap; the body ends 256 KiB past it.</summary>
    [Theory]
    [MemberData(nameof(DocumentsByFraming))]
    public async Task A_document_over_its_cap_closes_its_connection_instead_of_being_read_to_the_end(string document, bool chunked)
    {
        var big = document == "discovery" ? "/realms/r/.well-known/openid-configuration" : "/realms/r/protocol/openid-connect/certs";
        KeepAliveIdp? self = null;
        using var idp = new KeepAliveIdp(req => req.Path == big
            ? new KeepAliveIdp.Resp(Encoding.UTF8.GetBytes("""{"keys":["""), DocumentCap + Tail, chunked)
            : Documents.Answer(self!, req));
        self = idp;
        await using var kc = Facade(idp);

        var ex = await Record.ExceptionAsync(() => kc.Auth.ValidateAsync(Documents.Sign($"{idp.Url}/realms/r")));

        Assert.IsAssignableFrom<KeycloakException>(ex);
        await AssertClosedAsync(idp, big, chunked);
    }

    /// <summary>The control: a response read to its end still goes back to the pool — every auth lane, discovery, the JWKS
    /// and the admin client keep one connection each across many calls. It holds with or without the drain; a "fix" that
    /// closed every connection would fail it.</summary>
    [Fact]
    public async Task Responses_read_to_their_end_keep_their_connection_for_the_next_call()
    {
        KeepAliveIdp? self = null;
        using var idp = new KeepAliveIdp(req => Documents.Answer(self!, req));
        self = idp;
        await using (var kc = Facade(idp))
        {
            var good = Documents.Sign($"{idp.Url}/realms/r");
            await kc.Auth.ClientCredentialsTokenAsync();
            await kc.Auth.ClientCredentialsTokenAsync();
            await kc.Auth.RefreshAsync("rt");
            await kc.Auth.IntrospectAsync("at");
            await kc.Auth.LogoutAsync("rt");
            Assert.Equal("u1", (await kc.Auth.ValidateAsync(good)).Subject);
            Assert.Equal("u1", (await kc.Auth.ValidateAsync(good)).Subject);
            var admin = await kc.AdminAsync();
            await admin.Realms.ListAsync();
            await admin.Realms.ListAsync();
            await admin.Users.SearchAsync(null);
            Assert.Equal("u-123", await admin.Users.CreateAsync(new UserRepresentation { Username = "bob" }));
            await admin.Users.DeleteAsync("u-123");
            await kc.Auth.ClientCredentialsTokenAsync();
        }

        var byConnection = idp.Seen.GroupBy(r => r.Conn).ToList();
        var shown = string.Join("\n", byConnection.Select(g => $"conn {g.Key}: {string.Join(", ", g.Select(r => $"{r.Method} {r.Path}"))}"));
        Assert.True(byConnection.Count == 2, $"{idp.Seen.Count} requests on {byConnection.Count} connections, want 2 (one per client)\n{shown}");
        Assert.All(byConnection, g => Assert.True(
            g.All(r => r.Path.StartsWith("/admin/", StringComparison.Ordinal)) || g.All(r => r.Path.StartsWith("/realms/", StringComparison.Ordinal)),
            $"a connection carried both auth and admin requests\n{shown}"));
    }

    private static async Task AssertClosedAsync(KeepAliveIdp idp, string path, bool chunked)
    {
        var refused = Assert.Single(idp.Seen, r => r.Path == path);
        var conn = idp.Connections[refused.Conn];
        var closed = await Task.WhenAny(conn.Closed.Task, Task.Delay(CloseWithin)) == conn.Closed.Task;
        Assert.True(closed,
            $"the connection that carried the refused {(chunked ? "chunked" : "Content-Length")} body was still open {CloseWithin.TotalSeconds} s " +
            $"later — the handler read the rest of it ({conn.BodyBytesWritten} body bytes written, {conn.Requests} request(s) on it) to reuse it");
    }

    /// <summary>Discovery, a JWKS with one RSA key, and the small answers the other endpoints give.</summary>
    private static class Documents
    {
        private static readonly RSA Rsa = RSA.Create(2048);
        private static readonly RsaSecurityKey Key = new(Rsa) { KeyId = "k1" };

        public static KeepAliveIdp.Resp Answer(KeepAliveIdp idp, KeepAliveIdp.Req req)
        {
            var issuer = $"{idp.Url}/realms/r";
            var p = Rsa.ExportParameters(false);
            return req switch
            {
                { Path: var x } when x.EndsWith("/.well-known/openid-configuration", StringComparison.Ordinal) =>
                    KeepAliveIdp.Resp.Json($$"""{"issuer":"{{issuer}}","jwks_uri":"{{issuer}}/protocol/openid-connect/certs"}"""),
                { Path: var x } when x.EndsWith("/certs", StringComparison.Ordinal) =>
                    KeepAliveIdp.Resp.Json($$"""{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"k1","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}]}"""),
                { Path: var x } when x.EndsWith("/token/introspect", StringComparison.Ordinal) => KeepAliveIdp.Resp.Json("""{"active":true,"sub":"u1"}"""),
                { Path: var x } when x.EndsWith("/token", StringComparison.Ordinal) =>
                    KeepAliveIdp.Resp.Json("""{"access_token":"eyJ-small","token_type":"Bearer","expires_in":300,"refresh_token":"rt-1"}"""),
                { Path: var x } when x.EndsWith("/logout", StringComparison.Ordinal) => KeepAliveIdp.Resp.Empty(204),
                { Method: "POST", Path: "/admin/realms/r/users" } => KeepAliveIdp.Resp.Empty(201, $"Location: {idp.Url}/admin/realms/r/users/u-123\r\n"),
                { Method: "DELETE" } => KeepAliveIdp.Resp.Empty(204),
                { Path: var x } when x.StartsWith("/admin/realms/r/users", StringComparison.Ordinal) => KeepAliveIdp.Resp.Json("""[{"id":"u1","username":"alice"}]"""),
                _ => KeepAliveIdp.Resp.Json("""[{"realm":"r"}]"""),
            };
        }

        public static string Sign(string issuer) => new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
        {
            Issuer = issuer,
            Audience = "c",
            Expires = DateTime.UtcNow.AddMinutes(5),
            Claims = new Dictionary<string, object> { ["sub"] = "u1" },
            SigningCredentials = new SigningCredentials(Key, SecurityAlgorithms.RsaSha256),
        });
    }
}

/// <summary>
/// A minimal HTTP/1.1 server on a raw socket that keeps every connection open — no <c>Connection: close</c> — and serves
/// request after request on it, reporting when the client closes one. The response head and the first body bytes go out in
/// one write; padding is written from one reusable buffer of spaces.
/// </summary>
internal sealed class KeepAliveIdp : IDisposable
{
    internal sealed record Req(int Conn, string Method, string Path);

    /// <summary><paramref name="Head"/> followed by spaces up to <paramref name="TotalBytes"/> (0 = the head alone).</summary>
    internal sealed record Resp(byte[] Head, long TotalBytes, bool Chunked, int Status = 200, string ExtraHeaders = "")
    {
        public static Resp Json(string body) => new(Encoding.UTF8.GetBytes(body), 0, false);

        public static Resp Empty(int status, string extraHeaders = "") => new(Array.Empty<byte>(), 0, false, status, extraHeaders);
    }

    internal sealed class Connection
    {
        public int Requests;
        public long BodyBytesWritten;
        public readonly TaskCompletionSource Closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private static readonly byte[] Spaces = CreateSpaces();
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _cts = new();
    private readonly ConcurrentBag<TcpClient> _clients = new();
    private readonly Func<Req, Resp> _route;
    private readonly Task _loop;
    private int _next;

    public KeepAliveIdp(Func<Req, Resp> route)
    {
        _route = route;
        _listener.Start();
        Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
        _loop = Task.Run(AcceptLoopAsync, CancellationToken.None);
    }

    public string Url { get; }

    public ConcurrentQueue<Req> Seen { get; } = new();

    public ConcurrentDictionary<int, Connection> Connections { get; } = new();

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
            _clients.Add(client);
            var id = Interlocked.Increment(ref _next);
            var conn = Connections[id] = new Connection();
            // Not the server's token: a connection must always be served, or its Closed signal never completes.
            _ = Task.Run(() => ServeAsync(client, id, conn), CancellationToken.None);
        }
    }

    private async Task ServeAsync(TcpClient client, int id, Connection conn)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var pending = new List<byte>();
                while (await ReadRequestAsync(stream, pending, id) is { } req)
                {
                    Interlocked.Increment(ref conn.Requests);
                    Seen.Enqueue(req);
                    await WriteAsync(stream, _route(req), conn);
                }
            }
            catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or OperationCanceledException)
            {
                // The client closed the connection — while the server was writing, too.
            }
            finally
            {
                conn.Closed.TrySetResult();
            }
        }
    }

    /// <summary>The next request on the connection, or <c>null</c> when the client closed it. A body is read and dropped —
    /// by Content-Length, or chunk by chunk (an admin write's JSON body has no length).</summary>
    private async Task<Req?> ReadRequestAsync(NetworkStream stream, List<byte> pending, int id)
    {
        int headEnd;
        while ((headEnd = IndexOf(pending, "\r\n\r\n"u8)) < 0)
        {
            if (!await FillAsync(stream, pending))
                return null;
        }
        var head = Encoding.ASCII.GetString(pending.GetRange(0, headEnd).ToArray()).Split("\r\n");
        pending.RemoveRange(0, headEnd + 4);
        var headers = head.Skip(1).Select(l => l.Split(':', 2)).Where(kv => kv.Length == 2)
            .ToDictionary(kv => kv[0].Trim(), kv => kv[1].Trim(), StringComparer.OrdinalIgnoreCase);
        if (headers.TryGetValue("Transfer-Encoding", out var te) && te.Contains("chunked", StringComparison.OrdinalIgnoreCase))
            await SkipChunkedBodyAsync(stream, pending);
        else
            await SkipAsync(stream, pending, headers.TryGetValue("Content-Length", out var cl) ? int.Parse(cl, System.Globalization.CultureInfo.InvariantCulture) : 0);
        var requestLine = head[0].Split(' ');
        return new Req(id, requestLine[0], requestLine[1].Split('?')[0]);
    }

    /// <summary>Size line, data, CRLF … up to the zero-size chunk (the SDK sends no trailers).</summary>
    private async Task SkipChunkedBodyAsync(NetworkStream stream, List<byte> pending)
    {
        for (var size = -1; size != 0;)
        {
            int eol;
            while ((eol = IndexOf(pending, "\r\n"u8)) < 0)
                await FillOrThrowAsync(stream, pending);
            size = Convert.ToInt32(Encoding.ASCII.GetString(pending.GetRange(0, eol).ToArray()).Split(';')[0].Trim(), 16);
            pending.RemoveRange(0, eol + 2);
            await SkipAsync(stream, pending, size + 2);
        }
    }

    private async Task SkipAsync(NetworkStream stream, List<byte> pending, int count)
    {
        while (pending.Count < count)
            await FillOrThrowAsync(stream, pending);
        pending.RemoveRange(0, count);
    }

    private async Task<bool> FillAsync(NetworkStream stream, List<byte> pending)
    {
        var chunk = new byte[16384];
        var n = await stream.ReadAsync(chunk, _cts.Token);
        pending.AddRange(chunk.AsSpan(0, n).ToArray());
        return n > 0;
    }

    private async Task FillOrThrowAsync(NetworkStream stream, List<byte> pending)
    {
        if (!await FillAsync(stream, pending))
            throw new IOException("the request ended early");
    }

    private static int IndexOf(List<byte> data, ReadOnlySpan<byte> needle)
    {
        for (var i = 0; i + needle.Length <= data.Count; i++)
        {
            var match = true;
            for (var j = 0; j < needle.Length && match; j++)
                match = data[i + j] == needle[j];
            if (match)
                return i;
        }
        return -1;
    }

    private async Task WriteAsync(NetworkStream stream, Resp resp, Connection conn)
    {
        var total = Math.Max(resp.TotalBytes, resp.Head.Length);
        var framing = resp.Chunked ? "Transfer-Encoding: chunked" : $"Content-Length: {total}";
        var headers = Encoding.ASCII.GetBytes(
            $"HTTP/1.1 {resp.Status} X\r\nContent-Type: application/json\r\n{resp.ExtraHeaders}{framing}\r\n\r\n");
        byte[] first;
        if (resp.Head.Length == 0)
            first = headers;
        else if (resp.Chunked)
            first = [.. headers, .. Encoding.ASCII.GetBytes($"{resp.Head.Length:x}\r\n"), .. resp.Head, .. "\r\n"u8];
        else
            first = [.. headers, .. resp.Head];
        await stream.WriteAsync(first, _cts.Token);
        Interlocked.Add(ref conn.BodyBytesWritten, resp.Head.Length);
        for (var left = total - resp.Head.Length; left > 0;)
        {
            var count = (int)Math.Min(left, Spaces.Length);
            if (resp.Chunked)
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"{count:x}\r\n"), _cts.Token);
            await stream.WriteAsync(Spaces.AsMemory(0, count), _cts.Token);
            if (resp.Chunked)
                await stream.WriteAsync("\r\n"u8.ToArray(), _cts.Token);
            Interlocked.Add(ref conn.BodyBytesWritten, count);
            left -= count;
        }
        if (resp.Chunked)
            await stream.WriteAsync("0\r\n\r\n"u8.ToArray(), _cts.Token);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener.Dispose();
        foreach (var client in _clients)
            client.Dispose();
        try { _loop.Wait(5000, CancellationToken.None); }
        catch (AggregateException) { /* the accept loop ended on the cancellation */ }
        _cts.Dispose();
    }
}
