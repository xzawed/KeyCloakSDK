using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using Keycloak.AuthServices.Sdk.Admin.Models;
using Xunit;
using Xunit.Abstractions;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// The admin facade reads no more of a response than it uses — registry <c>admin-response-body-unbounded</c>. A facade
/// write's 2xx body, which no call reads, is not read at all; an error body (status 300 and up) is read up to 1,048,576
/// bytes and cut there, on every admin call, the <c>Raw</c> client's included. A success body a call does use is read
/// whole, as before.
/// </summary>
/// <remarks>
/// <para>Measured before the fix (2026-10-26, .NET 8.0.23, this file's raw-socket server, one run): every facade write read
/// its 64 MiB 2xx body to the end — the server wrote all 67,108,864 bytes and the connection stayed open (38–183 ms); behind a
/// 201 whose body stalled, the write waited out the 4 s read timeout and failed with "admin request timed out" (4,003–4,020
/// ms), its <c>Location</c> already in hand; a 404 or 300 with a 64 MiB body put all of it in the exception message
/// (67,108,864 characters), the <c>Raw</c> client handed all 67,108,864 bytes over, and one such call allocated 201–337 MB.
/// After (five runs): the server wrote at most 131,074 bytes of a write's body before its connection was closed, a stalled
/// write returned in 1–20 ms, the error message is the first 1,048,576 bytes (the server wrote at most 1,703,966), and the
/// call allocates 4.3–7.5 MB.</para>
/// <para>The signal is the connection's fate — closed while the server was still writing — as in
/// <c>DrainAfterRejectionTests</c>; how much the server managed to write depends on the socket buffers.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class AdminResponseBodyTests
{
    internal const int Cap = TokenResponseCapTests.Cap;

    /// <summary>A body no socket buffer holds whole.</summary>
    internal const long Huge = 64L << 20;

    /// <summary>The read timeout the stalled-body tests run under — the rescan's (registry, 2026-10-25).</summary>
    private const int StallTimeoutMs = 4000;

    private const string ErrorHead = """{"error":"HTTP 404 Not Found"}""";

    private static readonly TimeSpan CloseWithin = TimeSpan.FromSeconds(5);

    private readonly ITestOutputHelper _out;

    public AdminResponseBodyTests(ITestOutputHelper output) => _out = output;

    internal sealed class Fixed : ITokenProvider
    {
        public Task<string> GetAccessTokenAsync(CancellationToken ct = default) => Task.FromResult("t");
    }

    internal static Task<AdminClient> AdminAsync(KeepAliveIdp idp, int readTimeoutMs = 30_000) => AdminClient.CreateAsync(
        new KeycloakConfig { ServerUrl = idp.Url, Realm = "r", ClientId = "c", ClientSecret = "s", ReadTimeoutMs = readTimeoutMs }.Normalized(),
        new Fixed());

    /// <summary>One facade write: its request, whether it hands back the id from <c>Location</c>, and the call.</summary>
    internal sealed record Write(string Name, string Method, string Path, bool ReturnsId, Func<AdminClient, Task<string?>> Run);

    internal static readonly Write[] Writes =
    {
        new("typed Users.CreateAsync", "POST", "/admin/realms/r/users", true, async a => await a.Users.CreateAsync(new UserRepresentation { Username = "u" })),
        new("typed Users.UpdateAsync", "PUT", "/admin/realms/r/users/u1", false, async a => { await a.Users.UpdateAsync("u1", new UserRepresentation { Username = "u" }); return null; }),
        new("typed Users.DeleteAsync", "DELETE", "/admin/realms/r/users/u1", false, async a => { await a.Users.DeleteAsync("u1"); return null; }),
        new("typed Groups.CreateAsync", "POST", "/admin/realms/r/groups", true, async a => await a.Groups.CreateAsync(new GroupRepresentation { Name = "g" })),
        new("typed Groups.UpdateAsync", "PUT", "/admin/realms/r/groups/g1", false, async a => { await a.Groups.UpdateAsync("g1", new GroupRepresentation { Name = "g" }); return null; }),
        new("typed Groups.DeleteAsync", "DELETE", "/admin/realms/r/groups/g1", false, async a => { await a.Groups.DeleteAsync("g1"); return null; }),
        new("raw Clients.CreateAsync", "POST", "/admin/realms/r/clients", true, async a => await a.Clients.CreateAsync(new ClientRepresentation { ClientId = "c" })),
        new("raw Clients.UpdateAsync", "PUT", "/admin/realms/r/clients/c1", false, async a => { await a.Clients.UpdateAsync("c1", new ClientRepresentation { ClientId = "c" }); return null; }),
        new("raw Clients.DeleteAsync", "DELETE", "/admin/realms/r/clients/c1", false, async a => { await a.Clients.DeleteAsync("c1"); return null; }),
        new("raw Roles.CreateAsync", "POST", "/admin/realms/r/roles", false, async a => { await a.Roles.CreateAsync(new RoleRepresentation { Name = "n" }); return null; }),
        new("raw Roles.UpdateAsync", "PUT", "/admin/realms/r/roles/n", false, async a => { await a.Roles.UpdateAsync("n", new RoleRepresentation { Name = "n" }); return null; }),
        new("raw Roles.DeleteAsync", "DELETE", "/admin/realms/r/roles/n", false, async a => { await a.Roles.DeleteAsync("n"); return null; }),
        new("raw Realms.CreateAsync", "POST", "/admin/realms", false, async a => { await a.Realms.CreateAsync(new RealmRepresentation { Realm = "x" }); return null; }),
        new("raw Realms.UpdateAsync", "PUT", "/admin/realms/x", false, async a => { await a.Realms.UpdateAsync("x", new RealmRepresentation { Realm = "x" }); return null; }),
        new("raw Realms.DeleteAsync", "DELETE", "/admin/realms/x", false, async a => { await a.Realms.DeleteAsync("x"); return null; }),
    };

    public static IEnumerable<object[]> WriteNames => Writes.Select(w => new object[] { w.Name });

    public static IEnumerable<object[]> WritesByFraming =>
        from w in Writes
        from chunked in new[] { true, false }
        select new object[] { w.Name, chunked };

    /// <summary>Calls whose error body ends in the SDK error: typed and raw reads, a typed and a raw write, and a typed
    /// create — each reads an error body on its own path.</summary>
    internal static readonly (string Name, Func<AdminClient, Task> Run)[] ErrorCalls =
    {
        ("typed Users.GetAsync", a => a.Users.GetAsync("u1")),
        ("typed Users.UpdateAsync", a => a.Users.UpdateAsync("u1", new UserRepresentation { Username = "u" })),
        ("typed Users.CreateAsync", a => a.Users.CreateAsync(new UserRepresentation { Username = "u" })),
        ("raw Clients.GetAsync", a => a.Clients.GetAsync("c1")),
        ("raw Clients.UpdateAsync", a => a.Clients.UpdateAsync("c1", new ClientRepresentation { ClientId = "c" })),
    };

    public static IEnumerable<object[]> ErrorCallNames => ErrorCalls.Select(c => new object[] { c.Name });

    public static IEnumerable<object[]> ErrorRows =>
        from call in ErrorCalls
        from status in new[] { 404, 300 }
        from chunked in new[] { true, false }
        select new object[] { call.Name, status, chunked };

    /// <summary>The answer to a facade write: a create's 201 with <c>Location</c>, otherwise 200, and a body of
    /// <paramref name="total"/> bytes nobody reads.</summary>
    private static KeepAliveIdp.Resp Unread(Write w, long total, bool chunked, long stopAfter = -1) =>
        new("{}"u8.ToArray(), total, chunked, Status: w.Method == "POST" ? 201 : 200,
            ExtraHeaders: w.Method == "POST" ? $"Location: http://keycloak.test{w.Path}/new-id\r\n" : "", StopAfter: stopAfter);

    /// <summary>An error answer: <see cref="ErrorHead"/> padded with spaces to <paramref name="total"/> bytes.</summary>
    internal static KeepAliveIdp.Resp Error(int status, long total, bool chunked, long stopAfter = -1, bool closeAtStop = false) =>
        new(Encoding.ASCII.GetBytes(ErrorHead), total, chunked, Status: status, StopAfter: stopAfter, CloseAtStop: closeAtStop);

    /// <summary>The message an error body of <paramref name="total"/> bytes gives once cut at the cap.</summary>
    private static string CutMessage(int status, long total)
    {
        var body = ErrorHead + new string(' ', (int)Math.Min(total, Cap) - ErrorHead.Length);
        return status == 404 ? body : $"HTTP {status}: {body}";
    }

    private static KeepAliveIdp.Connection ConnectionOf(KeepAliveIdp idp) => idp.Connections[Assert.Single(idp.Seen).Conn];

    private static async Task<bool> ClosedWithinAsync(KeepAliveIdp.Connection conn) =>
        await Task.WhenAny(conn.Closed.Task, Task.Delay(CloseWithin)) == conn.Closed.Task;

    /// <summary>A write's 2xx body is not read: the call returns what it always did, and the connection that carried the
    /// body is closed while the server is still writing it — 64 MiB, more than any socket buffer holds.</summary>
    [Theory]
    [MemberData(nameof(WritesByFraming))]
    public async Task A_writes_2xx_body_is_not_read(string name, bool chunked)
    {
        var w = Writes.Single(x => x.Name == name);
        using var idp = new KeepAliveIdp(_ => Unread(w, Huge, chunked));
        await using var admin = await AdminAsync(idp);

        var watch = Stopwatch.StartNew();
        var got = await w.Run(admin);
        var elapsed = watch.ElapsedMilliseconds;
        var conn = ConnectionOf(idp);
        var closed = await ClosedWithinAsync(conn);

        _out.WriteLine($"{name} {(chunked ? "chunked" : "content-length")}: {elapsed} ms · server wrote {conn.BodyBytesWritten} body bytes · closed {closed}");
        Assert.Equal(w.ReturnsId ? "new-id" : null, got);
        Assert.True(closed, $"the connection was still open {CloseWithin.TotalSeconds} s after {name} returned — the body was read ({conn.BodyBytesWritten} bytes written)");
        Assert.True(conn.BodyBytesWritten < Huge, $"the server wrote the whole {Huge}-byte body");
    }

    /// <summary>A 2xx body that stalls after its first bytes does not hold the write — it returns at once.</summary>
    [Theory]
    [MemberData(nameof(WriteNames))]
    public async Task A_write_returns_without_waiting_for_a_stalled_2xx_body(string name)
    {
        var w = Writes.Single(x => x.Name == name);
        using var idp = new KeepAliveIdp(_ => Unread(w, Cap, chunked: false, stopAfter: 2));
        await using var admin = await AdminAsync(idp, StallTimeoutMs);

        var watch = Stopwatch.StartNew();
        string? got = null;
        var ex = await Record.ExceptionAsync(async () => got = await w.Run(admin));
        var elapsed = watch.ElapsedMilliseconds;

        _out.WriteLine($"{name}: {elapsed} ms · {(ex is null ? $"returned {got ?? "(void)"}" : $"{ex.GetType().Name}: {ex.Message}")}");
        Assert.Null(ex);
        Assert.Equal(w.ReturnsId ? "new-id" : null, got);
        Assert.True(await ClosedWithinAsync(ConnectionOf(idp)), $"{name} left the stalled connection open");
    }

    /// <summary>An error body is cut at the cap: the error keeps its class and status, its message carries the first
    /// 1,048,576 bytes, and the connection is closed instead of the rest being read.</summary>
    [Theory]
    [MemberData(nameof(ErrorRows))]
    public async Task An_error_body_is_cut_at_the_cap(string name, int status, bool chunked)
    {
        var run = ErrorCalls.Single(c => c.Name == name).Run;
        using var idp = new KeepAliveIdp(_ => Error(status, Huge, chunked));
        await using var admin = await AdminAsync(idp);

        var watch = Stopwatch.StartNew();
        var ex = await Record.ExceptionAsync(() => run(admin));
        var elapsed = watch.ElapsedMilliseconds;
        var conn = ConnectionOf(idp);
        var closed = await ClosedWithinAsync(conn);

        _out.WriteLine($"{name} {status} {(chunked ? "chunked" : "content-length")}: {elapsed} ms · {ex?.GetType().Name} · message {ex?.Message.Length} chars · server wrote {conn.BodyBytesWritten} body bytes · closed {closed}");
        var adminEx = Assert.IsAssignableFrom<KeycloakAdminException>(ex);
        Assert.Equal(status == 404 ? typeof(KeycloakNotFoundException) : typeof(KeycloakAdminException), ex!.GetType());
        Assert.Equal(status, adminEx.StatusCode);
        Assert.True(ex.Message == CutMessage(status, Huge), $"message of {ex.Message.Length} chars, want {CutMessage(status, Huge).Length}");
        Assert.True(closed, $"the connection was still open {CloseWithin.TotalSeconds} s later — the rest of the error body was read");
        Assert.True(conn.BodyBytesWritten < Huge, $"the server wrote the whole {Huge}-byte error body");
    }

    public static IEnumerable<object[]> SplitRows =>
        from call in ErrorCalls
        from status in new[] { 404, 300 }
        select new object[] { call.Name, status };

    /// <summary>A cut that splits the error JSON keeps the class and status. The typed client's own error reading
    /// (<c>Users.GetAsync</c>, <c>Users.UpdateAsync</c>) parses what is left and fails, so the SDK reports an undecodable error
    /// body under that status; every other path keeps the cut text as the message.</summary>
    [Theory]
    [MemberData(nameof(SplitRows))]
    public async Task A_cut_that_splits_the_error_json_keeps_its_class_and_status(string name, int status)
    {
        var run = ErrorCalls.Single(c => c.Name == name).Run;
        var body = Encoding.ASCII.GetBytes("{\"error\":\"" + new string('x', 2 * Cap) + "\"}");
        using var idp = new KeepAliveIdp(_ => new KeepAliveIdp.Resp(body, 0, Chunked: false, Status: status));
        await using var admin = await AdminAsync(idp);

        var ex = await Record.ExceptionAsync(() => run(admin));

        var adminEx = Assert.IsAssignableFrom<KeycloakAdminException>(ex);
        Assert.Equal(status == 404 ? typeof(KeycloakNotFoundException) : typeof(KeycloakAdminException), ex!.GetType());
        Assert.Equal(status, adminEx.StatusCode);
        var parsedByTheTypedClient = name is "typed Users.GetAsync" or "typed Users.UpdateAsync";
        var message = parsedByTheTypedClient ? "admin error response body could not be decoded" : Encoding.ASCII.GetString(body, 0, Cap);
        Assert.True(ex.Message == (status == 404 ? message : $"HTTP {status}: {message}"),
            $"message of {ex.Message.Length} chars starting {ex.Message[..Math.Min(40, ex.Message.Length)]}");
    }

    /// <summary>An error body of exactly the cap is kept whole and read to its end, so its connection serves the next call.</summary>
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task An_error_body_of_exactly_the_cap_is_kept_whole_and_its_connection_reused(bool chunked)
    {
        using var idp = new KeepAliveIdp(_ => Error(404, Cap, chunked));
        await using var admin = await AdminAsync(idp);

        foreach (var (name, run) in ErrorCalls)
        {
            var ex = await Assert.ThrowsAsync<KeycloakNotFoundException>(() => run(admin));
            Assert.True(ex.Message == CutMessage(404, Cap), $"{name}: message of {ex.Message.Length} chars, want {Cap}");
        }

        Assert.Equal(ErrorCalls.Length, idp.Seen.Count);
        Assert.True(idp.Connections.Count == 1, $"{ErrorCalls.Length} calls on {idp.Connections.Count} connections, want 1");
    }

    /// <summary>An error body that goes past the cap and then stalls is cut without waiting for the rest.</summary>
    [Theory]
    [MemberData(nameof(ErrorCallNames))]
    public async Task An_error_body_past_the_cap_is_cut_without_waiting_for_the_rest(string name)
    {
        var run = ErrorCalls.Single(c => c.Name == name).Run;
        using var idp = new KeepAliveIdp(_ => Error(404, 2L * Cap, chunked: false, stopAfter: Cap + 1));
        await using var admin = await AdminAsync(idp, StallTimeoutMs);

        var watch = Stopwatch.StartNew();
        var ex = await Record.ExceptionAsync(() => run(admin));
        var elapsed = watch.ElapsedMilliseconds;

        _out.WriteLine($"{name}: {elapsed} ms · {ex?.GetType().Name}: message {ex?.Message.Length} chars");
        Assert.IsType<KeycloakNotFoundException>(ex);
        Assert.True(ex!.Message == CutMessage(404, Cap), $"message of {ex.Message.Length} chars, want {Cap}");
    }

    /// <summary>An error body the server cuts short is the SDK's transport error, as it was when <c>HttpClient</c> read it.</summary>
    [Theory]
    [MemberData(nameof(ErrorCallNames))]
    public async Task An_error_body_the_server_cuts_short_is_a_transport_error(string name)
    {
        var run = ErrorCalls.Single(c => c.Name == name).Run;
        using var idp = new KeepAliveIdp(_ => Error(404, 1000, chunked: false, stopAfter: 10, closeAtStop: true));
        await using var admin = await AdminAsync(idp);

        var ex = await Assert.ThrowsAsync<KeycloakTransportException>(() => run(admin));

        Assert.Equal("admin request failed", ex.Message);
        Assert.IsAssignableFrom<HttpRequestException>(ex.InnerException);
    }

    /// <summary>The read timeout still ends an error body that stalls inside the cap — the SDK's own timeout error.</summary>
    [Theory]
    [MemberData(nameof(ErrorCallNames))]
    public async Task An_error_body_that_stalls_inside_the_cap_ends_at_the_read_timeout(string name)
    {
        var run = ErrorCalls.Single(c => c.Name == name).Run;
        using var idp = new KeepAliveIdp(_ => Error(404, 2L * Cap, chunked: false, stopAfter: 100));
        await using var admin = await AdminAsync(idp, readTimeoutMs: 1000);

        var ex = await Assert.ThrowsAsync<KeycloakTransportException>(() => run(admin));

        Assert.Equal("admin request timed out", ex.Message);
    }

    /// <summary>The caller's token ends an error body that stalls inside the cap — long before the read timeout.</summary>
    [Fact]
    public async Task The_callers_token_ends_an_error_body_that_stalls()
    {
        using var idp = new KeepAliveIdp(_ => Error(404, 2L * Cap, chunked: false, stopAfter: 100));
        await using var admin = await AdminAsync(idp);
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));

        var watch = Stopwatch.StartNew();
        var ex = await Record.ExceptionAsync(() => admin.Clients.GetAsync("c1", cts.Token));

        Assert.IsAssignableFrom<OperationCanceledException>(ex);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), $"took {watch.ElapsedMilliseconds} ms");
    }

    /// <summary>The <c>Raw</c> client's write hands its response to the consumer, body and all — only the facade's own
    /// writes leave theirs unread, and that does not reach a call that follows one.</summary>
    [Fact]
    public async Task Raw_writes_keep_their_2xx_bodies()
    {
        const long size = 2L * Cap;
        using var idp = new KeepAliveIdp(req => new KeepAliveIdp.Resp("""{"id":"raw"}"""u8.ToArray(), size, Chunked: false,
            Status: req.Method == "POST" ? 201 : 200, ExtraHeaders: $"Location: http://keycloak.test{req.Path}/new-id\r\n"));
        await using var admin = await AdminAsync(idp);

        Assert.Equal("new-id", await admin.Users.CreateAsync(new UserRepresentation { Username = "u" }));
        using var created = await admin.Raw.CreateUserWithResponseAsync("r", new UserRepresentation { Username = "u" });
        await admin.Users.UpdateAsync("u1", new UserRepresentation { Username = "u" });
        using var updated = await admin.Raw.UpdateUserWithResponseAsync("r", "u1", new UserRepresentation { Username = "u" });

        Assert.Equal(size, (await created.Content.ReadAsByteArrayAsync()).Length);
        Assert.Equal(size, (await updated.Content.ReadAsByteArrayAsync()).Length);
    }

    /// <summary>The <c>Raw</c> client's error body is cut at the cap too — and its headers say what is left: the length of
    /// the cut body, the media type the server gave.</summary>
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task A_raw_error_body_is_cut_at_the_cap(bool chunked)
    {
        using var idp = new KeepAliveIdp(_ => Error(404, Huge, chunked));
        await using var admin = await AdminAsync(idp);

        using var resp = await admin.Raw.GetUserWithResponseAsync("r", "u1");

        Assert.Equal(404, (int)resp.StatusCode);
        Assert.Equal(Cap, resp.Content.Headers.ContentLength);
        Assert.Equal("application/json", resp.Content.Headers.ContentType?.MediaType);
        Assert.Equal(Cap, (await resp.Content.ReadAsByteArrayAsync()).Length);
        Assert.True(await ClosedWithinAsync(ConnectionOf(idp)));
    }

    /// <summary>A success body a call uses is read whole, past the cap — typed and raw.</summary>
    [Fact]
    public async Task A_success_body_a_call_uses_is_read_whole()
    {
        var list = new StringBuilder("[");
        for (var i = 0; list.Length <= Cap + 4096; i++)
            list.Append(i == 0 ? "" : ",").Append($$"""{"id":"{{i:D12}}","username":"user-{{i:D12}}","clientId":"client-{{i:D12}}"}""");
        var body = list.Append(']').ToString();
        using var idp = new KeepAliveIdp(_ => KeepAliveIdp.Resp.Json(body));
        await using var admin = await AdminAsync(idp);

        Assert.True(Encoding.UTF8.GetByteCount(body) > Cap, "the body must be past the cap for this test to mean anything");
        Assert.Equal(body.Count(c => c == '{'), (await admin.Users.SearchAsync(null)).Count);
        Assert.Equal(body.Count(c => c == '{'), (await admin.Clients.FindByClientIdAsync("c")).Count);
    }

    /// <summary>A write whose response has already ended — 201 with no body, 204 — leaves its connection for the next call.</summary>
    [Fact]
    public async Task Writes_whose_response_has_ended_keep_their_connection()
    {
        using var idp = new KeepAliveIdp(req => req.Method == "POST"
            ? KeepAliveIdp.Resp.Empty(201, $"Location: http://keycloak.test{req.Path}/new-id\r\n")
            : KeepAliveIdp.Resp.Empty(204));
        await using var admin = await AdminAsync(idp);

        foreach (var w in Writes)
            Assert.Equal(w.ReturnsId ? "new-id" : null, await w.Run(admin));

        Assert.Equal(Writes.Length, idp.Seen.Count);
        Assert.True(idp.Connections.Count == 1, $"{Writes.Length} writes on {idp.Connections.Count} connections, want 1");
    }

    /// <summary>Nothing inflates an admin body: the SDK asks for no content-coding, and a gzip error body sent anyway — 64 MiB
    /// once inflated — stays the bytes that arrived.</summary>
    [Fact]
    public async Task An_admin_body_is_never_inflated()
    {
        var gzip = Gzip(Huge);
        using var idp = new KeepAliveIdp(_ => new KeepAliveIdp.Resp(gzip, 0, Chunked: false, Status: 404, ExtraHeaders: "Content-Encoding: gzip\r\n"));
        await using var admin = await AdminAsync(idp);

        using var resp = await admin.Raw.GetUserWithResponseAsync("r", "u1");
        var ex = await Assert.ThrowsAsync<KeycloakNotFoundException>(() => admin.Clients.GetAsync("c1"));

        Assert.Equal(gzip, await resp.Content.ReadAsByteArrayAsync());
        Assert.True(ex.Message.Length <= gzip.Length, $"message of {ex.Message.Length} chars from a {gzip.Length}-byte body");
        Assert.All(idp.Seen, r => Assert.False(r.Headers.ContainsKey("Accept-Encoding"), $"{r.Method} {r.Path} asked for Accept-Encoding: {r.Headers.GetValueOrDefault("Accept-Encoding")}"));
    }

    internal static byte[] Gzip(long spaces)
    {
        using var packed = new MemoryStream();
        using (var gz = new GZipStream(packed, CompressionLevel.SmallestSize, leaveOpen: true))
        {
            var block = new byte[65536];
            Array.Fill(block, (byte)' ');
            for (var left = spaces; left > 0; left -= block.Length)
                gz.Write(block, 0, (int)Math.Min(block.Length, left));
        }
        return packed.ToArray();
    }
}

/// <summary>
/// What reading a 64 MiB admin error body allocates — process-wide counters, so this runs alone
/// (<see cref="AllocationCollection"/>).
/// </summary>
[Trait("Category", "Unit")]
[Collection(AllocationCollection.Name)]
public sealed class AdminResponseBodyAllocationTests
{
    private readonly ITestOutputHelper _out;

    public AdminResponseBodyAllocationTests(ITestOutputHelper output) => _out = output;

    public static IEnumerable<object[]> Rows =>
        from call in new[] { "typed Users.GetAsync", "raw Clients.GetAsync" }
        from chunked in new[] { true, false }
        select new object[] { call, chunked };

    /// <summary>A 64 MiB error body costs what its first 1,048,576 bytes cost, not what the whole does.</summary>
    [Theory]
    [MemberData(nameof(Rows))]
    public async Task A_64_MiB_error_body_allocates_in_proportion_to_the_cap(string name, bool chunked)
    {
        var run = AdminResponseBodyTests.ErrorCalls.Single(c => c.Name == name).Run;
        using var idp = new KeepAliveIdp(_ => AdminResponseBodyTests.Error(404, AdminResponseBodyTests.Huge, chunked));
        await using var admin = await AdminResponseBodyTests.AdminAsync(idp);
        await Assert.ThrowsAsync<KeycloakNotFoundException>(() => run(admin)); // warm the path: JIT, first-use statics

        var before = GC.GetTotalAllocatedBytes(precise: true);
        var ex = await Record.ExceptionAsync(() => run(admin));
        var allocated = GC.GetTotalAllocatedBytes(precise: true) - before;

        _out.WriteLine($"{name} {(chunked ? "chunked" : "content-length")}: {ex?.GetType().Name} · allocated {allocated}");
        Assert.IsType<KeycloakNotFoundException>(ex);
        Assert.True(allocated < 16L * AdminResponseBodyTests.Cap, $"reading a {AdminResponseBodyTests.Huge}-byte error body allocated {allocated} bytes");
    }
}
