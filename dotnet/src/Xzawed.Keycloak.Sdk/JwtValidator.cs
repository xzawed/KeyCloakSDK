using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.Configuration;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace Xzawed.Keycloak;

/// <summary>Options for hardened JWT validation. Defaults pin RS256 and a tight clock skew.</summary>
public sealed class JwtValidatorOptions
{
    public required string Issuer { get; init; }
    public required IReadOnlyList<string> Audiences { get; init; }
    public IReadOnlyList<string> AllowedAlgorithms { get; init; } = new[] { "RS256" };
    public int ClockSkewSeconds { get; init; } = 30;
    public int RefreshIntervalSeconds { get; init; } = 30;
}

/// <summary>Hardened Keycloak access-token validator: algorithm pinning, none/unsigned rejection,
/// exact issuer, audience membership, required expiry, bounded clock skew, DoS-safe rate-limited JWKS.</summary>
public sealed class JwtValidator
{
    private static readonly JsonWebTokenHandler Handler = new() { MapInboundClaims = false };
    private readonly TokenValidationParameters _tvp;

    /// <summary>Production: JWKS via ConfigurationManager (OIDC discovery), rate-limited refresh.</summary>
    /// <param name="issuer">Realm issuer URL; discovery hangs off it.</param>
    /// <param name="opts">Hardened validation options.</param>
    /// <param name="http">The client discovery and the JWKS are fetched with. They are read through a 51,200-byte cap
    /// whatever client is passed; every other limit — timeouts, redirects, <see cref="HttpClient.MaxResponseContentBufferSize"/>
    /// — is this client's own. <c>KeycloakClient.Create</c> passes the client it builds.</param>
    public JwtValidator(string issuer, JwtValidatorOptions opts, HttpClient http)
        : this(issuer, opts, http, null, null) { }

    /// <param name="issuer">Realm issuer URL; discovery hangs off it.</param>
    /// <param name="opts">Hardened validation options.</param>
    /// <param name="http">Shared client (redirect-blocking, SSRF-hardened).</param>
    /// <param name="now">Clock seam (tests only).</param>
    /// <param name="jitter">Jitter seam (tests only).</param>
    /// <param name="configurationEvents">Tests only; <c>null</c> in production. IdentityModel's public hook for handing
    /// the manager a configuration with its retrieval time — the one way to give a test a configuration that is already
    /// past the 12-hour refresh without waiting 12 hours or reflecting on the manager's internal clock.</param>
    internal JwtValidator(
        string issuer,
        JwtValidatorOptions opts,
        HttpClient http,
        Func<DateTimeOffset>? now,
        Func<double>? jitter,
        IConfigurationEventHandler<OpenIdConnectConfiguration>? configurationEvents = null)
    {
        _tvp = BuildParameters(issuer, opts);
        // ⚠️ Not HttpDocumentRetriever: it imposes no byte cap. The shared client's
        // MaxResponseContentBufferSize is the token-response cap (1 MiB, AuthClient.MaxTokenResponseBytes) and
        // does not reach a streamed read; set to 51,200 it would refuse large tokens. BoundedDocumentRetriever
        // caps only discovery and JWKS.
        var docRetriever = new BoundedDocumentRetriever(
            http,
            requireHttps: issuer.StartsWith("https", StringComparison.OrdinalIgnoreCase));
        // A 200 with {"keys":[]} would otherwise replace a good configuration. The handler's
        // last-known-good fallback only hides that until the LKG entry expires (1h) — measured:
        // JwksEmptyKeysetTests.
        var keysRequired = new Microsoft.IdentityModel.Protocols.OpenIdConnect.Configuration.OpenIdConnectConfigurationValidator
        {
            MinimumNumberOfKeys = 1,
        };
        var inner = new ConfigurationManager<OpenIdConnectConfiguration>(
            $"{issuer}/.well-known/openid-configuration",
            // Every fetch passes through here — cold load, stale refresh, bad-signature refresh — so a failed one is
            // backed off here. The manager hides a failed refresh once a configuration is cached.
            new BackoffConfigurationRetriever(new OpenIdConnectConfigurationRetriever(), keysRequired, now, jitter),
            docRetriever,
            keysRequired)
        {
            AutomaticRefreshInterval = TimeSpan.FromHours(12),
            RefreshInterval = TimeSpan.FromSeconds(opts.RefreshIntervalSeconds),
            ConfigurationEventHandler = configurationEvents,
        };
        // RefreshInterval above only caps refreshes once a configuration is cached. A cold cache
        // against a failing IdP reaches it at all — measured 20 validations → 40 requests.
        _tvp.ConfigurationManager = new BackoffConfigurationManager(inner, now, jitter);
    }

    internal JwtValidator(TokenValidationParameters tvp) => _tvp = tvp;

    /// <summary>Base parameters (everything except the key source). Callers add ConfigurationManager or IssuerSigningKey.</summary>
    internal static TokenValidationParameters BuildParameters(string issuer, JwtValidatorOptions opts) => new()
    {
        ValidAlgorithms = opts.AllowedAlgorithms.ToArray(),   // algorithm pin (reject header-chosen alg)
        RequireSignedTokens = true,                            // reject 'none'/unsigned
        RequireExpirationTime = true,                          // exp required
        ValidateLifetime = true,
        ClockSkew = TimeSpan.FromSeconds(opts.ClockSkewSeconds),
        ValidateIssuer = true,
        ValidIssuer = issuer,                                  // exact match
        ValidateAudience = true,
        ValidAudiences = opts.Audiences.ToArray(),             // membership (multi-aud safe)
        ValidateIssuerSigningKey = true,
    };

    /// <summary>Validates an access token.</summary>
    /// <param name="token">The compact JWT.</param>
    /// <param name="ct">Ends the call with <see cref="OperationCanceledException"/>: at once when it is already cancelled
    /// (nothing is fetched), or while validation waits on the IdP. A discovery or JWKS fetch already under way is not
    /// cancelled with it — it completes and fills the cache.</param>
    public Task<ValidatedToken> ValidateAsync(string token, CancellationToken ct = default)
        => ValidateCoreAsync(token, _tvp, ct);

    /// <summary>Validates with every check of <see cref="ValidateAsync"/> except the audience, which must contain
    /// <paramref name="audience"/> instead of the configured one. The id_token path: its <c>aud</c> MUST contain the
    /// client id (OIDC Core §2, §3.1.3.7), whatever audience access tokens are held to.</summary>
    internal Task<ValidatedToken> ValidateForAudienceAsync(string token, string audience, CancellationToken ct = default)
        => ValidateCoreAsync(token, ParametersForAudience(audience), ct);

    /// <summary>A copy of the parameters that differs only in the audience.</summary>
    /// <remarks>⚠️ <c>Clone()</c> keeps the key source by reference, and that is what keeps ONE key store: the copy
    /// holds the same <c>ConfigurationManager</c> (JWKS cache, 30s refresh gate, cold-cache backoff, last-known-good) and
    /// the same <c>IssuerSigningKey</c>. Never build a second validator from the options for this — it would fetch and
    /// cache the JWKS on its own. (The audience list, by contrast, is copied — measured on 8.23.0 — so setting it here
    /// cannot retarget access-token validation.) <c>ValidAudience</c> is cleared because IdentityModel accepts it in
    /// addition to <c>ValidAudiences</c>, and <c>AudienceValidator</c> because IdentityModel consults it INSTEAD of
    /// <c>ValidAudiences</c> — the base parameters' audience policy must not carry over (measured:
    /// <c>Id_token_audience_ignores_the_base_audience_policy</c>).</remarks>
    internal TokenValidationParameters ParametersForAudience(string audience)
    {
        var tvp = _tvp.Clone();
        tvp.ValidateAudience = true;
        tvp.AudienceValidator = null;
        tvp.ValidAudience = null;
        tvp.ValidAudiences = new[] { audience };
        return tvp;
    }

    private static async Task<ValidatedToken> ValidateCoreAsync(string token, TokenValidationParameters tvp, CancellationToken ct)
    {
        // IdentityModel's ValidateTokenAsync takes no token (measured: a cancelled one still validated). Check it first so
        // a cancelled call starts nothing, then stop WAITING when it fires — the work itself runs on: a configuration fetch
        // it began is on CancellationToken.None and still fills the cache, so cancelling never wastes the refetch window.
        ct.ThrowIfCancellationRequested();
        var result = await ResultAsync(token, tvp).WaitAsync(ct).ConfigureAwait(false);
        // ⚠️ IdentityModel hides PII in its own message but nests a JSON parse error that quotes the decoded header or
        // payload — the constructor scrubs that chain (ErrorCause); the message is taken the same way.
        if (!result.IsValid)
            throw new KeycloakTokenValidationException(result.Exception is { } rex ? ErrorCause.MessageOf(rex) : "invalid token", result.Exception);

        var jwt = (JsonWebToken)result.SecurityToken;
        var claims = result.Claims.ToDictionary(kv => kv.Key, kv => (object?)kv.Value); // matches IntrospectAsync projection; no CS8620
        return new ValidatedToken(
            Subject: jwt.Subject,
            Audience: jwt.Audiences.ToArray(),
            Issuer: jwt.Issuer,
            ExpiresAt: jwt.TryGetPayloadValue<long>("exp", out var exp) ? exp : null,
            IssuedAt: jwt.TryGetPayloadValue<long>("iat", out var iat) ? iat : null,
            Claims: claims);
    }

    /// <summary>IdentityModel's verdict, with anything it throws already an SDK error — so the caller's
    /// <see cref="Task.WaitAsync(CancellationToken)"/> is the only source of <see cref="OperationCanceledException"/>.</summary>
    private static async Task<TokenValidationResult> ResultAsync(string token, TokenValidationParameters tvp)
    {
        try
        {
            return await Handler.ValidateTokenAsync(token, tvp).ConfigureAwait(false);
        }
        catch (Exception ex) // malformed token (SecurityTokenMalformedException) still throws from parse
        {
            throw new KeycloakTokenValidationException(ErrorCause.MessageOf(ex), ex);
        }
    }
}
