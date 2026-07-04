using System.Net.Http.Json;
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
        var http = new HttpClient(new BearerHandler(tokenProvider) { InnerHandler = new HttpClientHandler() })
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
    internal async Task<T> CallTypedAsync<T>(Func<IKeycloakClient, Task<T>> fn)
    {
        try { return await fn(_typed).ConfigureAwait(false); }
        catch (KeycloakHttpClientException ex) { throw KeycloakErrorMapping.MapHttpError(ex.StatusCode, ex.Response?.ErrorDescription ?? ex.HttpResponse ?? ex.Message, ex); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
    }

    internal async Task CallTypedAsync(Func<IKeycloakClient, Task> fn)
    {
        try { await fn(_typed).ConfigureAwait(false); }
        catch (KeycloakHttpClientException ex) { throw KeycloakErrorMapping.MapHttpError(ex.StatusCode, ex.Response?.ErrorDescription ?? ex.HttpResponse ?? ex.Message, ex); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
    }

    internal async Task<string> CreateReturningIdAsync(Func<IKeycloakClient, Task<HttpResponseMessage>> fn, CancellationToken ct)
    {
        HttpResponseMessage resp;
        try { resp = await fn(_typed).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        return await IdFromLocationAsync(resp, ct).ConfigureAwait(false);
    }

    internal async Task<HttpResponseMessage> SendRawAsync(HttpRequestMessage req, CancellationToken ct)
    {
        HttpResponseMessage resp;
        try { resp = await _http.SendAsync(req, ct).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        if (!resp.IsSuccessStatusCode)
            throw KeycloakErrorMapping.MapHttpError((int)resp.StatusCode, await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
        return resp;
    }

    internal async Task<T> GetJsonAsync<T>(string relativeUrl, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, relativeUrl);
        var resp = await SendRawAsync(req, ct).ConfigureAwait(false);
        var value = await resp.Content.ReadFromJsonAsync<T>(cancellationToken: ct).ConfigureAwait(false);
        return value ?? throw new KeycloakNotFoundException($"empty response body for {relativeUrl}");
    }

    internal async Task<string> CreateRawReturningIdAsync(string relativeUrl, object body, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, relativeUrl) { Content = JsonContent.Create(body) };
        var resp = await SendRawAsync(req, ct).ConfigureAwait(false);
        return await IdFromLocationAsync(resp, ct).ConfigureAwait(false);
    }

    private async Task<string> IdFromLocationAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        if (!resp.IsSuccessStatusCode)
            throw KeycloakErrorMapping.MapHttpError((int)resp.StatusCode, await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
        var id = resp.Headers.Location?.Segments[^1]?.TrimEnd('/');
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
