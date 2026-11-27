// measurement only — not for merge (task n3 · registry admin-created-id-non-ascii-location).
//
// What id does the admin create (users) return when the 201's Location carries a byte that is not visible ASCII? A raw
// TCP server (not WireMock — Kestrel will not write such a header) answers the token grant with a token and the create
// with 201 + `Location: http://127.0.0.1:<port>/admin/realms/it-realm/users/<id bytes>` for three id byte strings:
// `abc` (control), `ab` 0xE9 `cd` (Latin-1 obs-text), `ab` 0xC3 0xA9 `cd` (UTF-8 for U+00E9). Per case it prints the bytes a
// raw socket read off the wire (WIRE), what .NET's HttpClient makes of the header (CLIENT), and what the SDK returns (ID).
//
// Run: N3_OUT=<file> dotnet test -f net10.0 --filter "FullyQualifiedName~ZzN3LocationMeasure"
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Keycloak.AuthServices.Sdk.Admin.Models;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public sealed class ZzN3LocationMeasure : IDisposable
{
    private const string Realm = "it-realm";
    private const string UsersPath = "/admin/realms/" + Realm + "/users";

    private static readonly (string Name, byte[] Id)[] Cases =
    {
        ("ascii-control", Encoding.ASCII.GetBytes("abc")),
        ("latin1-0xE9", new byte[] { (byte)'a', (byte)'b', 0xE9, (byte)'c', (byte)'d' }),
        ("utf8-0xC3A9", new byte[] { (byte)'a', (byte)'b', 0xC3, 0xA9, (byte)'c', (byte)'d' }),
    };

    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly List<string> _seen = new();
    private readonly object _lock = new();
    private byte[] _location = Array.Empty<byte>();

    public ZzN3LocationMeasure()
    {
        _listener.Start();
        _ = Task.Run(Serve);
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
        _stop.Dispose();
    }

    private int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;
    private string Base => $"http://127.0.0.1:{Port}";

    private async Task Serve()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient conn;
            try { conn = await _listener.AcceptTcpClientAsync(_stop.Token); }
            catch (Exception) { return; }
            _ = Task.Run(() => Handle(conn));
        }
    }

    /// <summary>One request per connection: read the head and a Content-Length body, answer, close.</summary>
    private async Task Handle(TcpClient conn)
    {
        using (conn)
        {
            var stream = conn.GetStream();
            var buf = new List<byte>();
            var chunk = new byte[4096];
            int headEnd;
            while ((headEnd = IndexOf(buf, "\r\n\r\n"u8.ToArray())) < 0)
            {
                var n = await stream.ReadAsync(chunk);
                if (n == 0) return;
                buf.AddRange(chunk.AsSpan(0, n).ToArray());
            }
            var head = Encoding.Latin1.GetString(buf.ToArray(), 0, headEnd);
            var lines = head.Split("\r\n");
            var parts = lines[0].Split(' ');
            var method = parts[0];
            var path = parts.Length > 1 ? parts[1] : "";
            var length = 0;
            var chunked = false;
            foreach (var line in lines.Skip(1))
            {
                var colon = line.IndexOf(':', StringComparison.Ordinal);
                if (colon < 0) continue;
                var name = line[..colon].Trim();
                var value = line[(colon + 1)..].Trim();
                if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) length = int.Parse(value, System.Globalization.CultureInfo.InvariantCulture);
                if (name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase) && value.Contains("chunked", StringComparison.OrdinalIgnoreCase)) chunked = true;
            }
            var body = buf.Count - (headEnd + 4);
            if (chunked)
            {
                while (IndexOf(buf, "0\r\n\r\n"u8.ToArray()) < 0)
                {
                    var n = await stream.ReadAsync(chunk);
                    if (n == 0) break;
                    buf.AddRange(chunk.AsSpan(0, n).ToArray());
                }
            }
            else
            {
                while (body < length)
                {
                    var n = await stream.ReadAsync(chunk);
                    if (n == 0) break;
                    body += n;
                }
            }
            lock (_lock) _seen.Add($"{method} {path}");
            byte[] answer;
            if (path.EndsWith("/protocol/openid-connect/token", StringComparison.Ordinal))
            {
                var json = """{"access_token":"at-n3","token_type":"Bearer","expires_in":300}""";
                answer = Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {json.Length}\r\nConnection: close\r\n\r\n{json}");
            }
            else if (method == "POST" && path.TrimEnd('/') == UsersPath)
            {
                answer = Concat(Encoding.ASCII.GetBytes("HTTP/1.1 201 Created\r\nLocation: "), _location,
                    Encoding.ASCII.GetBytes("\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
            }
            else
            {
                answer = Encoding.ASCII.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            }
            await stream.WriteAsync(answer);
            await stream.FlushAsync();
        }
    }

    private static int IndexOf(List<byte> hay, byte[] needle)
    {
        for (var i = 0; i + needle.Length <= hay.Count; i++)
        {
            var hit = true;
            for (var j = 0; j < needle.Length && hit; j++) hit = hay[i + j] == needle[j];
            if (hit) return i;
        }
        return -1;
    }

    private static byte[] Concat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();

    private static string Hex(byte[] b) => string.Join(" ", b.Select(x => x.ToString("X2", System.Globalization.CultureInfo.InvariantCulture)));

    /// <summary>A string with every char outside printable ASCII escaped, then its code points.</summary>
    private static string Show(string? s)
    {
        if (s is null) return "null";
        var sb = new StringBuilder("\"");
        foreach (var c in s) sb.Append(c is >= ' ' and < (char)0x7F ? c.ToString() : $"\\u{(int)c:X4}");
        sb.Append("\" cps=[").Append(string.Join(",", s.EnumerateRunes().Select(r => $"U+{r.Value:X4}"))).Append(']');
        return sb.ToString();
    }

    private static string? Tail(string? s) => s is null ? null : s[(s.LastIndexOf('/') + 1)..];

    /// <summary>The Location value bytes as a raw socket reads them off the wire.</summary>
    private async Task<string> WireProbe()
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, Port);
        var s = tcp.GetStream();
        await s.WriteAsync(Encoding.ASCII.GetBytes($"POST {UsersPath} HTTP/1.1\r\nHost: 127.0.0.1:{Port}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
        using var ms = new MemoryStream();
        await s.CopyToAsync(ms);
        var raw = ms.ToArray();
        var marker = Encoding.ASCII.GetBytes("\r\nLocation: ");
        var at = IndexOf(raw.ToList(), marker);
        if (at < 0) return "no Location";
        var start = at + marker.Length;
        var end = start;
        while (end < raw.Length && raw[end] != '\r') end++;
        return Hex(raw[start..end]);
    }

    /// <summary>What .NET's HttpClient (no redirects) decodes the header to — the view CreatedId gets.</summary>
    private async Task<string> ClientView()
    {
        using var http = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false });
        try
        {
            using var resp = await http.PostAsync(Base + UsersPath, new StringContent(""));
            var raw = resp.Headers.TryGetValues("Location", out var v) ? string.Join(",", v) : null;
            var typed = resp.Headers.Location;
            return $"status={(int)resp.StatusCode}|TryGetValues.after_last_slash={Show(Tail(raw))}|Headers.Location.OriginalString.after_last_slash={Show(Tail(typed?.OriginalString))}|Headers.Location.AbsolutePath.after_last_slash={Show(Tail(typed is { IsAbsoluteUri: true } ? typed.AbsolutePath : null))}";
        }
        catch (Exception e)
        {
            return $"threw {e.GetType().Name}: {e.Message.Replace('\n', ' ')}";
        }
    }

    private static string Err(Exception e)
    {
        var status = e is KeycloakAdminException a ? $" status={a.StatusCode}" : "";
        var inner = e.InnerException is { } i ? $" inner={i.GetType().Name}: {i.Message}" : "";
        return $"Err({e.GetType().Name}: {e.Message}{status}{inner})".Replace('|', '/').Replace('\r', ' ').Replace('\n', ' ');
    }

    [Fact]
    public async Task Measure()
    {
        var path = Environment.GetEnvironmentVariable("N3_OUT");
        Assert.False(string.IsNullOrEmpty(path), "set N3_OUT to the output file");
        var output = new List<string>
        {
            $"ENV|runtime={RuntimeInformation.FrameworkDescription}|sdk=Xzawed.Keycloak.Sdk (worktree)|create=AdminClient.Users.CreateAsync",
            "HEADER|sdk|lane|case|field|value",
        };
        var cfg = new KeycloakConfig { ServerUrl = Base, Realm = Realm, ClientId = "it-client", ClientSecret = "dummy-secret" }.Normalized();
        foreach (var (name, id) in Cases)
        {
            _location = Concat(Encoding.ASCII.GetBytes($"{Base}{UsersPath}/"), id);
            var probe = await WireProbe();
            output.Add($"WIRE|dotnet|-|{name}|location=<base>/admin/realms/it-realm/users/+[{Hex(id)}]|raw_socket_read_equals_sent={probe == Hex(_location)}|id_bytes_on_wire={(probe.EndsWith(Hex(id), StringComparison.Ordinal) ? Hex(id) : probe)}");
            output.Add($"CLIENT|dotnet|HttpClient(SocketsHttpHandler)|{name}|{(await ClientView()).Replace(Base, "<base>", StringComparison.Ordinal)}");
            lock (_lock) _seen.Clear();
            string result;
            try
            {
                await using var client = KeycloakClient.Create(cfg);
                var admin = await client.AdminAsync();
                result = $"Ok({Show(await admin.Users.CreateAsync(new UserRepresentation { Username = "n3-user" }))})";
            }
            catch (Exception e)
            {
                result = Err(e);
            }
            string seen;
            lock (_lock) seen = string.Join(",", _seen);
            output.Add($"ID|dotnet|AdminClient.Users.CreateAsync|{name}|{result}|requests={seen}");
        }
        await File.WriteAllLinesAsync(path!, output);
    }
}
