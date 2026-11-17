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
/// exact issuer, audience membership, required expiry, bounded clock skew, token type, DoS-safe rate-limited JWKS.</summary>
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
    /// how much of a refused document its handler drains to reuse the connection — is this client's own. Its
    /// <see cref="HttpClient.Timeout"/> bounds each whole document, body included, from when the request is sent.
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

    /// <summary>The payload <c>typ</c> values Keycloak gives the tokens that are not access tokens
    /// (<c>org.keycloak.util.TokenUtil</c>): id_token, refresh, offline, back-channel logout and serialized id_token. An
    /// access token is <c>Bearer</c> or <c>DPoP</c>.</summary>
    private static readonly HashSet<string> NotAccessTokenTypes = new(StringComparer.Ordinal)
    {
        "ID", "Refresh", "Offline", "Logout", "Serialized-ID",
    };

    /// <summary>Validates an access token. A token whose payload <c>typ</c> names another kind of Keycloak token — an
    /// id_token (<c>ID</c>), <c>Refresh</c>, <c>Offline</c>, <c>Logout</c> or <c>Serialized-ID</c> — is refused even
    /// when it passes every other check; any other <c>typ</c>, or none, is not looked at.</summary>
    /// <param name="token">The compact JWT.</param>
    /// <param name="ct">Ends the call with <see cref="OperationCanceledException"/>: at once when it is already cancelled
    /// (nothing is fetched), or while validation waits on the IdP. A discovery or JWKS fetch already under way is not
    /// cancelled with it — it completes and fills the cache.</param>
    public Task<ValidatedToken> ValidateAsync(string token, CancellationToken ct = default)
        => ValidateCoreAsync(token, _tvp, RequireAccessToken, ct);

    /// <summary>Validates with every check of <see cref="ValidateAsync"/> except the audience, which must contain
    /// <paramref name="audience"/> instead of the configured one, and the token type. The id_token path — its public entry is
    /// <c>AuthClient.ValidateIdTokenAsync</c>, which the code exchange calls too: an id_token's <c>aud</c> MUST contain the
    /// client id (OIDC Core §2, §3.1.3.7), whatever audience access tokens are held to. In place of the access path's
    /// token-type deny-list it checks the kind — the payload <c>typ</c> must be exactly <c>ID</c>
    /// (<see cref="RequireIdToken"/>) — and then the authorized party (<see cref="RequireAuthorizedParty"/>).</summary>
    internal Task<ValidatedToken> ValidateForAudienceAsync(string token, string audience, CancellationToken ct = default)
        => ValidateCoreAsync(token, ParametersForAudience(audience), jwt =>
        {
            RequireIdToken(jwt);
            RequireAuthorizedParty(jwt, audience);
        }, ct);

    /// <summary>The access path's last check: the payload <c>typ</c>, when it is a string, must not be one of
    /// <see cref="NotAccessTokenTypes"/> (an exact, case-sensitive match). The value is quoted: it is one of those five.</summary>
    private static void RequireAccessToken(JsonWebToken jwt)
    {
        // The payload claim — JsonWebToken.Typ is the JOSE header's. Only a JSON string is compared: a number, an array
        // (even ["ID"]) or an object passes as before (Access_validation_accepts_every_other_typ).
        if (jwt.TryGetPayloadValue<object>("typ", out var typ) && typ is string kind && NotAccessTokenTypes.Contains(kind))
            throw new KeycloakTokenValidationException($"not an access token (typ \"{kind}\")");
    }

    /// <summary>The id_token path's last check — OIDC Core §3.1.3.7 steps 4–5: an id_token with more than one audience
    /// must carry <c>azp</c>, and an <c>azp</c> that is present must be the client id. Not on the access path: an access
    /// token's <c>azp</c> is the client that requested it and legitimately differs from its audience.</summary>
    /// <remarks>IdentityModel reads <c>azp</c> as a string and refuses a token whose <c>azp</c> is another JSON type while
    /// reading it, so a present <c>azp</c> here is a string or JSON null — null is not the client id.</remarks>
    private static void RequireAuthorizedParty(JsonWebToken jwt, string clientId)
    {
        if (jwt.TryGetPayloadValue<object>("azp", out var azp))
        {
            if (azp is not string party || !string.Equals(party, clientId, StringComparison.Ordinal))
                throw new KeycloakTokenValidationException("azp does not match the client id");
        }
        else if (jwt.Audiences.Skip(1).Any())
        {
            throw new KeycloakTokenValidationException("azp is required when aud has more than one value");
        }
    }

    /// <summary>The id_token path's first own check, before <see cref="RequireAuthorizedParty"/> — being an id_token is the
    /// azp rule's premise, so a token that breaks both rules gets this message — and an allow-list: the payload <c>typ</c>
    /// must be exactly the string <c>ID</c> (ordinal). Keycloak types every id_token so; an access token (<c>Bearer</c> —
    /// <c>bearer</c> under a client option) can name the client in both <c>aud</c> and <c>azp</c> and pass every other check
    /// here, which a deny-list of <c>Bearer</c> would miss in lower case. Absent, not a JSON string, or any other string is
    /// refused. The message is constant: the <c>typ</c> is the token's choice and is not echoed (nor is <c>azp</c>).</summary>
    private static void RequireIdToken(JsonWebToken jwt)
    {
        // The payload claim — JsonWebToken.Typ is the JOSE header's. Only a JSON string can match: a number, an array (even
        // ["ID"]), an object or JSON null cannot.
        if (!(jwt.TryGetPayloadValue<object>("typ", out var typ) && typ is string kind && string.Equals(kind, "ID", StringComparison.Ordinal)))
            throw new KeycloakTokenValidationException("not an id_token (typ is not \"ID\")");
    }

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

    /// <param name="token">The compact JWT.</param>
    /// <param name="tvp">The parameters of the path — access or id_token.</param>
    /// <param name="lastCheck">The path's own checks, run once every shared one has passed (<see cref="RequireAccessToken"/>,
    /// or <see cref="RequireIdToken"/> then <see cref="RequireAuthorizedParty"/>).</param>
    /// <param name="ct">See <see cref="ValidateAsync"/>.</param>
    private static async Task<ValidatedToken> ValidateCoreAsync(
        string token, TokenValidationParameters tvp, Action<JsonWebToken> lastCheck, CancellationToken ct)
    {
        // IdentityModel's ValidateTokenAsync takes no token (measured: a cancelled one still validated). Check it first so
        // a cancelled call starts nothing, then stop WAITING when it fires — the work itself runs on: a configuration fetch
        // it began is on CancellationToken.None and still fills the cache, so cancelling never wastes the refetch window.
        ct.ThrowIfCancellationRequested();
        // Length before anything touches the token (MaxJwtBytes). Length counts UTF-16 units; a genuine JWT is ASCII, so
        // units, code points and bytes agree on it.
        if (token is { Length: > MaxJwtBytes })
            throw new KeycloakTokenValidationException($"token exceeds {MaxJwtBytes} bytes");
        // ⚠️ An HS (symmetric) signature is never verified, even when the configuration allows it (registry
        // hs-refusal-rests-on-libraries): this SDK's keys come only from the JWKS, a public document, so the only thing an
        // HMAC secret could be is a published value. IdentityModel refused an allowed HS token only after loading the keys
        // (measured: discovery and the JWKS fetched twice, then IDX10511), so the SDK reads the header alg itself and refuses
        // an HS one that the ValidAlgorithms pin lets through here, before any discovery, JWKS fetch or refetch. An alg the
        // pin refuses keeps IdentityModel's path and wording. Overlaps the oct drop (BackoffConfigurationRetriever).
        if (HeaderAlg(token) is { } alg && alg.StartsWith("HS", StringComparison.Ordinal) && PinAllows(tvp, alg))
            throw new KeycloakTokenValidationException($"algorithm not allowed: {alg} (a JWKS holds public keys only)");
        var result = await ResultAsync(token, tvp).WaitAsync(ct).ConfigureAwait(false);
        // ⚠️ IdentityModel hides PII in its own message but nests a JSON parse error that quotes the decoded header or
        // payload — the constructor scrubs that chain (ErrorCause); the message is taken the same way.
        if (!result.IsValid)
            throw new KeycloakTokenValidationException(result.Exception is { } rex ? ErrorCause.MessageOf(rex) : "invalid token", result.Exception);

        var jwt = (JsonWebToken)result.SecurityToken;
        lastCheck(jwt);
        var claims = result.Claims.ToDictionary(kv => kv.Key, kv => (object?)kv.Value); // matches IntrospectAsync projection; no CS8620
        return new ValidatedToken(
            Subject: jwt.Subject,
            Audience: jwt.Audiences.ToArray(),
            Issuer: jwt.Issuer,
            ExpiresAt: jwt.TryGetPayloadValue<long>("exp", out var exp) ? exp : null,
            IssuedAt: jwt.TryGetPayloadValue<long>("iat", out var iat) ? iat : null,
            Claims: claims);
    }

    /// <summary>The header <c>alg</c> as IdentityModel reads the token, or null when it cannot read it — that verdict stays
    /// IdentityModel's (<see cref="ResultAsync"/> converts it).</summary>
    private static string? HeaderAlg(string token)
    {
        try
        {
            return new JsonWebToken(token).Alg;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Whether the <c>ValidAlgorithms</c> pin lets <paramref name="alg"/> through, as IdentityModel applies it: null
    /// or empty pins nothing, otherwise an ordinal match (measured on 8.23.0).</summary>
    private static bool PinAllows(TokenValidationParameters tvp, string alg)
        => tvp.ValidAlgorithms is not { } pinned || !pinned.Any() || pinned.Contains(alg, StringComparer.Ordinal);

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
