using System.Text.Json;
using System.Text.Json.Serialization;

namespace Xzawed.Keycloak;

/// <summary>Token-endpoint response. AccessToken/RefreshToken are masked by ToString.
/// Isomorphic with the Java/Python/Node/Go TokenSet (absolute ExpiresAt in epoch seconds, IsExpired).</summary>
[JsonConverter(typeof(TokenSetJsonConverter))]   // mask access/refresh tokens in JSON/structured logging too
public sealed record TokenSet
{
    public required string AccessToken { get; init; }
    public required string TokenType { get; init; }
    public long ExpiresIn { get; init; }        // relative seconds
    public long? ExpiresAt { get; init; }        // absolute epoch seconds; null if unknown
    public string? RefreshToken { get; init; }
    public string? IdToken { get; init; }
    public string? Scope { get; init; }

    /// <summary>Maps raw token-response values to a TokenSet, computing absolute expiry.</summary>
    public static TokenSet Create(string accessToken, string? tokenType, long expiresIn,
                                  string? refreshToken, string? idToken, string? scope, long issuedAtSeconds)
    {
        if (string.IsNullOrEmpty(accessToken))
            throw new KeycloakAuthException("token response missing access_token");
        return new TokenSet
        {
            AccessToken = accessToken,
            TokenType = string.IsNullOrEmpty(tokenType) ? "Bearer" : tokenType,
            ExpiresIn = expiresIn,
            ExpiresAt = expiresIn > 0 ? issuedAtSeconds + expiresIn : null,
            RefreshToken = refreshToken,
            IdToken = idToken,
            Scope = scope,
        };
    }

    /// <summary>Conservative: an unknown ExpiresAt is treated as expired.</summary>
    public bool IsExpired(long nowSeconds, long skewSeconds) =>
        ExpiresAt is null || nowSeconds + skewSeconds >= ExpiresAt.Value;

    public override string ToString() =>
        $"TokenSet {{ TokenType = {TokenType}, ExpiresIn = {ExpiresIn}, " +
        $"AccessToken = {Masking.Mask(AccessToken)}, RefreshToken = {Masking.Mask(RefreshToken)} }}";
}

/// <summary>Trusted claim set of an access token that passed hardened validation.</summary>
public sealed record ValidatedToken(
    string Subject,
    IReadOnlyList<string> Audience,
    string Issuer,
    long? ExpiresAt,
    long? IssuedAt,
    IReadOnlyDictionary<string, object?> Claims);

/// <summary>RFC 7662 introspection response.</summary>
public sealed record IntrospectionResult(
    bool Active,
    string? Username,
    string? ClientId,
    IReadOnlyDictionary<string, object?> Claims);

/// <summary>Returned by CreateAuthorizationRequest to start a PKCE authorization-code flow.
/// The caller stores CodeVerifier/State/Nonce until the callback (the SDK is stateless).</summary>
public sealed record AuthorizationRequest(string Url, string CodeVerifier, string State, string Nonce);

/// <summary>Masks access/refresh tokens when a TokenSet is JSON-serialized (e.g. Serilog destructuring).</summary>
internal sealed class TokenSetJsonConverter : JsonConverter<TokenSet>
{
    public override TokenSet Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => throw new NotSupportedException("TokenSet is not deserializable from JSON.");

    public override void Write(Utf8JsonWriter writer, TokenSet value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("tokenType", value.TokenType);
        writer.WriteNumber("expiresIn", value.ExpiresIn);
        if (value.ExpiresAt is { } ea) writer.WriteNumber("expiresAt", ea); else writer.WriteNull("expiresAt");
        writer.WriteString("accessToken", Masking.Mask(value.AccessToken));
        writer.WriteString("refreshToken", Masking.Mask(value.RefreshToken));
        writer.WriteEndObject();
    }
}
