namespace Xzawed.Keycloak;

/// <summary>Shared transport handler factory. Both the facade HttpClient and the admin
/// BearerHandler's inner handler are built here so the SSRF hardening below cannot drift
/// between them.</summary>
internal static class HttpTransport
{
    internal static SocketsHttpHandler CreateHandler(KeycloakConfig cfg) => new()
    {
        // PooledConnectionLifetime recycles connections so a long-lived client still picks up
        // DNS changes (the IHttpClientFactory concern).
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        ConnectTimeout = TimeSpan.FromMilliseconds(cfg.ConnectTimeoutMs),
        // SSRF hardening: never follow redirects on back-channel requests. AllowAutoRedirect
        // defaults to TRUE, so an unexpected 3xx from a token/JWKS endpoint would make the SDK
        // fetch an attacker-chosen URL — possibly internal — while carrying our headers.
        // Isomorphic with Rust (redirect::Policy::none()), Ruby and Go (ErrUseLastResponse).
        // The OIDC authorization-code redirect_uri is a browser front-channel concern, unaffected.
        AllowAutoRedirect = false,
    };
}
