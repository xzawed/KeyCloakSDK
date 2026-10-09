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
        // A response refused before its end — a token, introspection or logout body over the 1 MiB cap, a discovery or JWKS
        // document over 51,200 bytes — was read on after the refusal, up to MaxResponseDrainSize (1 MiB by default, for up
        // to 2 s), to reuse the connection: the caps bounded what was kept, not what was read (measured: a 32 MiB chunked
        // token body read 2,097,588 bytes, and a body ending inside that 1 MiB was read whole and its connection reused —
        // DrainAfterRejectionTests). 0 closes the connection instead. A response read to its end is pooled as before: every
        // one the SDK accepts, and every admin response — the typed client and the raw path both buffer the body whole.
        MaxResponseDrainSize = 0,
    };
}
