using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
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
    internal JwtValidator(
        string issuer,
        JwtValidatorOptions opts,
        HttpClient http,
        Func<DateTimeOffset>? now,
        Func<double>? jitter)
    {
        _tvp = BuildParameters(issuer, opts);
        // ⚠️ Not HttpDocumentRetriever: it imposes no byte cap. The shared client's
        // MaxResponseContentBufferSize is the token-response cap (1 MiB, AuthClient.MaxTokenResponseBytes) and
        // does not reach a streamed read; set to 51,200 it would refuse large tokens. BoundedDocumentRetriever
        // caps only discovery and JWKS.
        var docRetriever = new BoundedDocumentRetriever(
            http,
            requireHttps: issuer.StartsWith("https", StringComparison.OrdinalIgnoreCase));
        var inner = new ConfigurationManager<OpenIdConnectConfiguration>(
            $"{issuer}/.well-known/openid-configuration",
            new OpenIdConnectConfigurationRetriever(),
            docRetriever,
            // A 200 with {"keys":[]} would otherwise replace a good configuration. The handler's
            // last-known-good fallback only hides that until the LKG entry expires (1h) — measured:
            // JwksEmptyKeysetTests.
            new Microsoft.IdentityModel.Protocols.OpenIdConnect.Configuration.OpenIdConnectConfigurationValidator
            {
                MinimumNumberOfKeys = 1,
            })
        {
            AutomaticRefreshInterval = TimeSpan.FromHours(12),
            RefreshInterval = TimeSpan.FromSeconds(opts.RefreshIntervalSeconds),
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

    public Task<ValidatedToken> ValidateAsync(string token, CancellationToken ct = default)
        => ValidateCoreAsync(token, _tvp);

    /// <summary>Validates with every check of <see cref="ValidateAsync"/> except the audience, which must contain
    /// <paramref name="audience"/> instead of the configured one. The id_token path: its <c>aud</c> MUST contain the
    /// client id (OIDC Core §2, §3.1.3.7), whatever audience access tokens are held to.</summary>
    internal Task<ValidatedToken> ValidateForAudienceAsync(string token, string audience, CancellationToken ct = default)
        => ValidateCoreAsync(token, ParametersForAudience(audience));

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

    private static async Task<ValidatedToken> ValidateCoreAsync(string token, TokenValidationParameters tvp)
    {
        TokenValidationResult result;
        try
        {
            result = await Handler.ValidateTokenAsync(token, tvp).ConfigureAwait(false);
        }
        catch (Exception ex) // malformed token (SecurityTokenMalformedException) still throws from parse
        {
            throw new KeycloakTokenValidationException(ErrorCause.MessageOf(ex), ex);
        }
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
}
