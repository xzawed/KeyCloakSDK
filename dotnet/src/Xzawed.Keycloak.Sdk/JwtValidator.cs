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
    /// <summary>The longest token either validation path accepts — an access token or the id_token of a code exchange.
    /// It is checked before anything else touches the token: before IdentityModel reads it and before discovery or the
    /// JWKS is loaded. 256,000 is IdentityModel's <c>TokenValidationParameters.DefaultMaximumTokenSizeInBytes</c>, which
    /// this lane already enforced without naming it; it is about 3.9 times the longest bearer Keycloak 26.6 accepts with
    /// default settings (65,459 bytes), so no token that server accepts is refused. The SDK checks it itself, with its
    /// own message, and sets the handler's limit to the same value so the two cannot drift apart.</summary>
    /// <remarks>⚠️ A plain decimal literal on purpose — the nine SDKs share this value and a cross-language guard reads
    /// this line.</remarks>
    internal const int MaxJwtBytes = 256000;

    private static readonly JsonWebTokenHandler Handler = new() { MapInboundClaims = false, MaximumTokenSizeInBytes = MaxJwtBytes };
    private readonly TokenValidationParameters _tvp;

    /// <summary>Production: JWKS via OIDC discovery; a key set is used for 300 seconds from the fetch that brought it and
    /// never after — the next validation fetches again and fails if that fetch fails; rate-limited refetch.</summary>
    /// <param name="issuer">Realm issuer URL; discovery hangs off it.</param>
    /// <param name="opts">Hardened validation options.</param>
    /// <param name="http">The client discovery and the JWKS are fetched with. They are read through a 51,200-byte cap
    /// whatever client is passed; every other limit — timeouts, redirects, <see cref="HttpClient.MaxResponseContentBufferSize"/>,
    /// how much of a refused document its handler drains to reuse the connection — is this client's own.
    /// <c>KeycloakClient.Create</c> passes the client it builds.</param>
    public JwtValidator(string issuer, JwtValidatorOptions opts, HttpClient http)
        : this(issuer, opts, http, null, null) { }

    /// <param name="issuer">Realm issuer URL; discovery hangs off it.</param>
    /// <param name="opts">Hardened validation options.</param>
    /// <param name="http">Shared client (redirect-blocking, SSRF-hardened).</param>
    /// <param name="now">Clock seam (tests only): the key set's lifetime, the failure backoff and the refetch window.</param>
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
        // A 200 with {"keys":[]} would otherwise replace a good configuration. The handler's
        // last-known-good fallback only hides that until the LKG entry expires (1h) — measured:
        // JwksEmptyKeysetTests.
        var keysRequired = new Microsoft.IdentityModel.Protocols.OpenIdConnect.Configuration.OpenIdConnectConfigurationValidator
        {
            MinimumNumberOfKeys = 1,
        };
        var metadataAddress = $"{issuer}/.well-known/openid-configuration";
        // A key set is used for KeySetLifetime.JwksMaxAgeSeconds from the fetch that brought it, then never again.
        var lifetime = new KeySetLifetime(now);
        // Every fetch passes through here — cold load, reload, forced refetch — so a failed one is backed off here, and a
        // successful one starts its key set's lifetime here. The manager hides a failed refresh once a configuration is cached.
        var retriever = new BackoffConfigurationRetriever(new OpenIdConnectConfigurationRetriever(), keysRequired, now, jitter, lifetime);
        // The reload once a key set has expired is a cold load — on a new IdentityModel manager, the only cold one.
        var coldStart = new ColdStartConfigurationManager(
            () => new ConfigurationManager<OpenIdConnectConfiguration>(metadataAddress, retriever, docRetriever, keysRequired)
            {
                // Not the lifetime (KeySetLifetime): past this the manager serves what it holds while refreshing in the background.
                // A manager is started over once the key set served is JwksMaxAgeSeconds old, so this only comes due while forced
                // refetches keep serving newer sets over its own.
                AutomaticRefreshInterval = TimeSpan.FromHours(12),
                // Gates no refetch here (RequestRefresh never reaches this manager, see below). Kept for IdentityModel's
                // blocking mode — a host's AppContext switch — which paces a failed refresh with it.
                RefreshInterval = TimeSpan.FromSeconds(opts.RefreshIntervalSeconds),
            },
            lifetime);
        // The refetch a validation asks for — an unresolved kid, a bad signature — runs in the SDK, and that validation
        // waits for it: IdentityModel's manager ran it in the background, after the call that asked had already failed.
        // Its window is the same interval. A cold cache against a failing IdP is backed off separately (BackoffConfigurationManager)
        // — measured 20 validations → 40 requests.
        _tvp.ConfigurationManager = new ForcedRefetchConfigurationManager(
            new BackoffConfigurationManager(coldStart, now, jitter),
            async () => await retriever.GetConfigurationAsync(metadataAddress, docRetriever, CancellationToken.None).ConfigureAwait(false),
            now,
            coldStart)
        {
            RefreshInterval = TimeSpan.FromSeconds(opts.RefreshIntervalSeconds),
            // Off: after a failed fetch the handler falls back to last-known-good, whose lifetime counts from the last token a
            // configuration validated, on the wall clock (an hour by default) — it would serve keys past their lifetime.
            UseLastKnownGoodConfiguration = false,
        };
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
    /// holds the same <c>ConfigurationManager</c> (JWKS cache and its lifetime, 30s refresh gate, cold-cache backoff) and
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
        // Length before anything touches the token (MaxJwtBytes). Length counts UTF-16 units; a genuine JWT is ASCII, so
        // units, code points and bytes agree on it.
        if (token is { Length: > MaxJwtBytes })
            throw new KeycloakTokenValidationException($"token exceeds {MaxJwtBytes} bytes");
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
