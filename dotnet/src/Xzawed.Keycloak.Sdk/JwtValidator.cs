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
    public JwtValidator(string issuer, JwtValidatorOptions opts, HttpClient http)
    {
        _tvp = BuildParameters(issuer, opts);
        var docRetriever = new HttpDocumentRetriever(http)
        {
            RequireHttps = issuer.StartsWith("https", StringComparison.OrdinalIgnoreCase),
        };
        _tvp.ConfigurationManager = new ConfigurationManager<OpenIdConnectConfiguration>(
            $"{issuer}/.well-known/openid-configuration",
            new OpenIdConnectConfigurationRetriever(),
            docRetriever)
        {
            AutomaticRefreshInterval = TimeSpan.FromHours(12),
            RefreshInterval = TimeSpan.FromSeconds(opts.RefreshIntervalSeconds),
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

    public async Task<ValidatedToken> ValidateAsync(string token, CancellationToken ct = default)
    {
        TokenValidationResult result;
        try
        {
            result = await Handler.ValidateTokenAsync(token, _tvp).ConfigureAwait(false);
        }
        catch (Exception ex) // malformed token (SecurityTokenMalformedException) still throws from parse
        {
            throw new KeycloakTokenValidationException(ex.Message, ex);
        }
        if (!result.IsValid)
            throw new KeycloakTokenValidationException(result.Exception?.Message ?? "invalid token", result.Exception);

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
