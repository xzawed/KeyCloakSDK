using System.Net;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Keycloak.AuthServices.Sdk;              // KeycloakHttpClientException
using Keycloak.AuthServices.Sdk.Admin;         // IKeycloakClient
// ⚠️ Alias REQUIRED: inside namespace Xzawed.Keycloak.Admin, the bare name `KeycloakClient` binds to the
// enclosing-namespace facade Xzawed.Keycloak.KeycloakClient (private ctor) — an enclosing-namespace type
// wins over an inner `using`. `new KeycloakClient(http)` would be CS1729. Alias to the library type.
using KcAdminClient = Keycloak.AuthServices.Sdk.Admin.KeycloakClient;

namespace Xzawed.Keycloak.Admin;

/// <summary>Admin REST facade. users/groups/realm-get go through the typed Keycloak.AuthServices client;
/// clients/roles/realm-CRUD use raw REST on the same bearer-authed HttpClient. Lower-library errors are
/// converted to the KeycloakException hierarchy at the boundary.</summary>
public sealed class AdminClient : IAsyncDisposable, IDisposable
{
    private readonly HttpClient _http;          // bearer-authed via BearerHandler; owned
    private readonly IKeycloakClient _typed;     // typed as interface => default interface methods callable
    public string Realm { get; }

    public UsersResource Users { get; }
    public ClientsResource Clients { get; }
    public RealmsResource Realms { get; }
    public RolesResource Roles { get; }
    public GroupsResource Groups { get; }

    private AdminClient(HttpClient http, string realm)
    {
        _http = http;
        _typed = new KcAdminClient(http);        // Keycloak.AuthServices concrete, held as IKeycloakClient
        Realm = realm;
        Users = new UsersResource(this);
        Clients = new ClientsResource(this);
        Realms = new RealmsResource(this);
        Roles = new RolesResource(this);
        Groups = new GroupsResource(this);
    }

    /// <summary>Builds a bearer-authed admin client and authenticates eagerly (client-credentials).
    /// Faults before any network if clientSecret is absent.</summary>
    public static async Task<AdminClient> CreateAsync(KeycloakConfig cfg, ITokenProvider tokenProvider, CancellationToken ct = default)
    {
        if (cfg.ClientSecret is null)
            throw new KeycloakConfigException("clientSecret is required for the admin client (client-credentials).");
        var http = new HttpClient(new BearerHandler(tokenProvider)
        {
            // Shared with the facade HttpClient so pool lifetime / connect timeout / SSRF
            // redirect hardening cannot drift between auth and admin transports.
            InnerHandler = HttpTransport.CreateHandler(cfg),
        })
        {
            BaseAddress = new Uri(cfg.ServerUrl.TrimEnd('/') + "/"),   // must end with '/'
            Timeout = TimeSpan.FromMilliseconds(cfg.ReadTimeoutMs),
        };
        try { await tokenProvider.GetAccessTokenAsync(ct).ConfigureAwait(false); } // authenticate on first admin build (§5.1)
        catch { http.Dispose(); throw; }                                            // don't leak the client on failed warm-up
        return new AdminClient(http, cfg.Realm);
    }

    /// <summary>Escape hatch: the underlying typed admin client (documented hiding-exception).</summary>
    public IKeycloakClient Raw => _typed;

    // ---- boundary helpers ----

    /// <summary>The status of the admin response on the current typed call — set by <see cref="BearerHandler"/>.</summary>
    /// <remarks>The typed client decodes the body itself, an error body too (for its message). When it cannot — invalid
    /// UTF-8, an unpaired surrogate escape — it throws <see cref="JsonException"/>, which carries no status; that escaped
    /// the SDK raw (measured: <c>UndecodableResponseTests</c>). The status lets a 404 whose body is undecodable stay a
    /// <see cref="KeycloakNotFoundException"/>. One box per call, flowing down the call's own async context.</remarks>
    private static readonly AsyncLocal<StrongBox<int>?> TypedCallStatus = new();

    internal static void Observe(HttpStatusCode status)
    {
        if (TypedCallStatus.Value is { } box)
            box.Value = (int)status;
    }

    internal async Task<T> CallTypedAsync<T>(Func<IKeycloakClient, Task<T>> fn)
    {
        var status = TypedCallStatus.Value = new StrongBox<int>();
        try { return await fn(_typed).ConfigureAwait(false); }
        catch (KeycloakHttpClientException ex) { throw KeycloakErrorMapping.MapHttpError(ex.StatusCode, ex.Response?.ErrorDescription ?? ex.HttpResponse ?? ex.Message, ex); }
        catch (JsonException ex) { throw Undecodable(status.Value, ex); }
        catch (Exception ex) when (status.Value != 0 && IsUnsupportedCharset(ex)) { throw Undecodable(status.Value, ErrorCause.WithholdAll(ex)); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException) { throw new KeycloakTransportException("admin request timed out", ex); }
    }

    internal async Task CallTypedAsync(Func<IKeycloakClient, Task> fn)
    {
        var status = TypedCallStatus.Value = new StrongBox<int>();
        try { await fn(_typed).ConfigureAwait(false); }
        catch (KeycloakHttpClientException ex) { throw KeycloakErrorMapping.MapHttpError(ex.StatusCode, ex.Response?.ErrorDescription ?? ex.HttpResponse ?? ex.Message, ex); }
        catch (JsonException ex) { throw Undecodable(status.Value, ex); }
        catch (Exception ex) when (status.Value != 0 && IsUnsupportedCharset(ex)) { throw Undecodable(status.Value, ErrorCause.WithholdAll(ex)); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException) { throw new KeycloakTransportException("admin request timed out", ex); }
    }

    /// <summary>The SDK error for a body the typed client could not decode — malformed JSON, or a charset .NET does not
    /// support — under its own status when that was an error response, as <see cref="GetJsonAsync{T}"/> reports a success
    /// body otherwise; or, for a JSON failure with no response seen, the request body. <see cref="BearerHandler"/> already
    /// turns a body the serializer refuses into that same error where it is written, inside the transport
    /// (<c>UnencodableRequestBodyTests</c>); the arm keeps the answer the same for one that surfaces here instead.</summary>
    private static KeycloakException Undecodable(int status, Exception ex) => status switch
    {
        0 => new KeycloakTransportException(UnencodableBody, ex),
        >= 300 => KeycloakErrorMapping.MapHttpError(status, "admin error response body could not be decoded", ex),
        _ => new KeycloakAdminException(500, UndecodableBody, ex),
    };

    private const string UndecodableBody = "admin response body could not be decoded";

    /// <summary>The message for a request body System.Text.Json would not write — every admin write, typed or raw.</summary>
    internal const string UnencodableBody = "admin request failed: the request body could not be encoded as JSON";

    /// <summary>Whether <paramref name="ex"/> is .NET refusing the charset a response's <c>Content-Type</c> names — the body
    /// was never read. It escaped the admin calls that read a body raw, an unknown name quoted in its chain (measured:
    /// <c>UnsupportedCharsetResponseTests</c>).</summary>
    /// <remarks>An unknown name makes <c>Encoding.GetEncoding</c> throw <see cref="ArgumentException"/>, quoting it, which
    /// <see cref="HttpContent"/>'s string read and System.Net.Http.Json wrap in <see cref="InvalidOperationException"/>;
    /// UTF-7, disabled under every alias, makes it throw <see cref="NotSupportedException"/>, which neither wraps (8.0 and
    /// 10.0 alike). ⚠️ Keyed on that lookup, never on the type or the assembly that throws it: System.Net.Http also throws
    /// <see cref="InvalidOperationException"/> for a state error — a request URI it will not send, a disposed client — and
    /// that is no bad response. ⚠️ On the typed path it also takes a response seen (<see cref="Observe"/>): the token
    /// provider runs inside the same call before one arrives, and a consumer's provider that reads its own HTTP response
    /// throws exactly this.</remarks>
    private static bool IsUnsupportedCharset(Exception ex) => ex switch
    {
        InvalidOperationException { InnerException: ArgumentException lookup } => IsEncodingLookup(lookup),
        NotSupportedException => IsEncodingLookup(ex),
        _ => false,
    };

    /// <summary>Thrown inside CoreLib's <c>System.Text</c> — <c>Encoding.GetEncoding</c> and the name table behind it.</summary>
    private static bool IsEncodingLookup(Exception ex) =>
        ex.TargetSite?.DeclaringType is { Namespace: "System.Text" } type && type.Assembly == typeof(Encoding).Assembly;

    internal async Task<string> CreateReturningIdAsync(Func<IKeycloakClient, Task<HttpResponseMessage>> fn, CancellationToken ct)
    {
        HttpResponseMessage resp;
        try { resp = await fn(_typed).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException) { throw new KeycloakTransportException("admin request timed out", ex); }
        using (resp)
            return await IdFromLocationAsync(resp, ct).ConfigureAwait(false);
    }

    internal async Task<HttpResponseMessage> SendRawAsync(HttpRequestMessage req, CancellationToken ct)
    {
        HttpResponseMessage resp;
        try { resp = await _http.SendAsync(req, ct).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException) { throw new KeycloakTransportException("admin request timed out", ex); }
        if (!resp.IsSuccessStatusCode)
        {
            var error = await ErrorResponseAsync(resp, ct).ConfigureAwait(false);
            resp.Dispose(); // 에러 경로에서 호출자가 소유권을 못 받으므로 여기서 폐기(커넥션 반환)
            throw error;
        }
        return resp;
    }

    /// <summary>The SDK error for an admin error response, its body as the message. A body in a charset .NET does not
    /// support gets the error the typed path gives an error body it cannot decode, under the same status.</summary>
    private static async Task<KeycloakException> ErrorResponseAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        var status = (int)resp.StatusCode;
        try { return KeycloakErrorMapping.MapHttpError(status, await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false)); }
        catch (Exception ex) when (IsUnsupportedCharset(ex)) { return Undecodable(status, ErrorCause.WithholdAll(ex)); }
    }

    internal async Task<T> GetJsonAsync<T>(string relativeUrl, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, relativeUrl);
        using var resp = await SendRawAsync(req, ct).ConfigureAwait(false);
        T? value;
        try { value = await resp.Content.ReadFromJsonAsync<T>(cancellationToken: ct).ConfigureAwait(false); }
        catch (Exception ex) when (IsUnsupportedCharset(ex))
        {
            // Nothing was read; every message in the chain may quote the charset name the response gave.
            throw new KeycloakAdminException(500, UndecodableBody, ErrorCause.WithholdAll(ex));
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException)
        {
            // "could not be decoded", not "was not valid JSON": an unpaired surrogate escape is valid JSON (RFC 8259 §8.2)
            // that System.Text.Json will not decode.
            throw new KeycloakAdminException(500, UndecodableBody, ex);
        }
        return value ?? throw new KeycloakNotFoundException($"empty response body for {relativeUrl}");
    }

    internal async Task<string> CreateRawReturningIdAsync(string relativeUrl, object body, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, relativeUrl) { Content = JsonContent.Create(body) };
        using var resp = await SendRawAsync(req, ct).ConfigureAwait(false);
        return await IdFromLocationAsync(resp, ct).ConfigureAwait(false);
    }

    private async Task<string> IdFromLocationAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        if (!resp.IsSuccessStatusCode)
            throw await ErrorResponseAsync(resp, ct).ConfigureAwait(false);
        var loc = resp.Headers.Location;
        var id = loc is { IsAbsoluteUri: true } ? loc.Segments[^1].TrimEnd('/') : null;
        return string.IsNullOrEmpty(id)
            ? throw new KeycloakAdminException(500, "resource created but no id returned in Location header")
            : id;
    }

    public void Dispose() => _http.Dispose();

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }
}
