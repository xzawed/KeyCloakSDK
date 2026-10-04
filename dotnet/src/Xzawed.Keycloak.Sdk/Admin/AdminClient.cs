using System.Net;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
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
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException) { throw new KeycloakTransportException("admin request timed out", ex); }
    }

    internal async Task CallTypedAsync(Func<IKeycloakClient, Task> fn)
    {
        var status = TypedCallStatus.Value = new StrongBox<int>();
        try { await fn(_typed).ConfigureAwait(false); }
        catch (KeycloakHttpClientException ex) { throw KeycloakErrorMapping.MapHttpError(ex.StatusCode, ex.Response?.ErrorDescription ?? ex.HttpResponse ?? ex.Message, ex); }
        catch (JsonException ex) { throw Undecodable(status.Value, ex); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException) { throw new KeycloakTransportException("admin request timed out", ex); }
    }

    /// <summary>The SDK error for a JSON failure inside the typed client: a body it could not decode — under its own status
    /// when that was an error response, as <see cref="GetJsonAsync{T}"/> reports a success body otherwise — or, with no
    /// response seen, a request body it could not encode (a representation that contains itself, measured).</summary>
    private static KeycloakException Undecodable(int status, JsonException ex) => status switch
    {
        0 => new KeycloakTransportException("admin request failed: the request body could not be encoded as JSON", ex),
        >= 300 => KeycloakErrorMapping.MapHttpError(status, "admin error response body could not be decoded", ex),
        _ => new KeycloakAdminException(500, UndecodableBody, ex),
    };

    private const string UndecodableBody = "admin response body could not be decoded";

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
            var status = (int)resp.StatusCode;
            var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            resp.Dispose(); // 에러 경로에서 호출자가 소유권을 못 받으므로 여기서 폐기(커넥션 반환)
            throw KeycloakErrorMapping.MapHttpError(status, body);
        }
        return resp;
    }

    internal async Task<T> GetJsonAsync<T>(string relativeUrl, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, relativeUrl);
        using var resp = await SendRawAsync(req, ct).ConfigureAwait(false);
        T? value;
        try { value = await resp.Content.ReadFromJsonAsync<T>(cancellationToken: ct).ConfigureAwait(false); }
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
            throw KeycloakErrorMapping.MapHttpError((int)resp.StatusCode, await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
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
