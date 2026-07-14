using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak;

/// <summary>Unified entry point. Auth is built eagerly; the admin facade is built lazily on first
/// AdminAsync, cached, and single-flighted. Dispose (await using / using) releases owned resources.</summary>
public sealed class KeycloakClient : IAsyncDisposable, IDisposable
{
    private readonly KeycloakConfig _config;
    private readonly HttpClient _httpClient;      // owned; used by Auth + JwtValidator
    private readonly SemaphoreSlim _adminGate = new(1, 1);
    private volatile AdminClient? _admin;
    private ITokenProvider? _adminTokenProvider;

    public AuthClient Auth { get; }

    private KeycloakClient(KeycloakConfig config, HttpClient httpClient, AuthClient auth)
    {
        _config = config; _httpClient = httpClient; Auth = auth;
    }

    public static KeycloakClient Create(KeycloakConfig config)
    {
        var cfg = config.Normalized();                 // validates + strips trailing slash
        // Single long-lived HttpClient (idiomatic for a one-server SDK client); PooledConnectionLifetime
        // recycles connections so a captured client still picks up DNS changes (the IHttpClientFactory concern).
        var http = new HttpClient(new SocketsHttpHandler
        {
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            ConnectTimeout = TimeSpan.FromMilliseconds(cfg.ConnectTimeoutMs),
        })
        {
            Timeout = TimeSpan.FromMilliseconds(cfg.ReadTimeoutMs),
        };
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        var validator = new JwtValidator(ep.Issuer,
            new JwtValidatorOptions
            {
                Issuer = ep.Issuer,
                Audiences = new[] { cfg.ClientId },
                AllowedAlgorithms = cfg.SignatureAlgorithms,
                ClockSkewSeconds = cfg.ClockSkewSeconds,
            },
            http);
        var auth = new AuthClient(cfg, ep, validator, http);
        return new KeycloakClient(cfg, http, auth);
    }

    /// <summary>Lazily builds the admin facade (client-credentials). Throws before any network if clientSecret is absent.</summary>
    public async Task<AdminClient> AdminAsync(CancellationToken ct = default)
    {
        if (_config.ClientSecret is null)
            throw new KeycloakConfigException("clientSecret is required to use the admin client.");
        if (_admin is { } cached) return cached;

        await _adminGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_admin is { } fresh) return fresh;      // double-check under gate
            _adminTokenProvider ??= new ClientCredentialsTokenProvider(Auth, _config.ClockSkewSeconds);
            var admin = await AdminClient.CreateAsync(_config, _adminTokenProvider, ct).ConfigureAwait(false); // failure not cached
            _admin = admin;
            return admin;
        }
        finally { _adminGate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        if (_admin is { } admin) await admin.DisposeAsync().ConfigureAwait(false);
        _httpClient.Dispose();
        _adminGate.Dispose();
        GC.SuppressFinalize(this);
    }

    // Sync dispose so a DI container (ServiceProvider.Dispose) — which cannot sync-dispose an
    // async-only-disposable tracked singleton — can release this client without throwing.
    public void Dispose()
    {
        _admin?.Dispose();
        _httpClient.Dispose();
        _adminGate.Dispose();
        GC.SuppressFinalize(this);
    }
}
