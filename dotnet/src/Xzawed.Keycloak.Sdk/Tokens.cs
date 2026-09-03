using System.Text.Json;
using System.Text.Json.Serialization;

namespace Xzawed.Keycloak;

/// <summary>Token-endpoint response. AccessToken/RefreshToken are masked by ToString.
/// Isomorphic with the Java/Python/Node/Go TokenSet (absolute ExpiresAt in epoch seconds, IsExpired).</summary>
[JsonConverter(typeof(TokenSetJsonConverter))]   // masks access/refresh tokens in ToString() and System.Text.Json serialization.
                                                 // NOTE: reflection-based destructuring loggers (Serilog {@}) read raw
                                                 // properties and bypass this — do not @-destructure TokenSet.
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
/// The caller stores CodeVerifier/State/Nonce until the callback (the SDK is stateless).
/// CodeVerifier is masked by ToString and by System.Text.Json — it is the proof-of-possession
/// secret for the code exchange, so a stolen code plus a logged verifier completes the flow.
/// ⚠️ Being a positional record, the compiler-generated ToString would otherwise print every
/// property; the override below is what prevents that. Url/State/Nonce stay visible, matching
/// Rust's Debug impl (only code_verifier is masked there too).</summary>
[JsonConverter(typeof(AuthorizationRequestJsonConverter))]
public sealed record AuthorizationRequest(string Url, string CodeVerifier, string State, string Nonce)
{
    public override string ToString() =>
        $"AuthorizationRequest {{ Url = {Url}, State = {State}, Nonce = {Nonce}, " +
        $"CodeVerifier = {Masking.Mask(CodeVerifier)} }}";
}

/// <summary>Masks the PKCE verifier when an AuthorizationRequest is JSON-serialized.
/// NOTE: same caveat as TokenSet — reflection-based destructuring loggers (Serilog {@}) read raw
/// properties and bypass this converter; do not @-destructure AuthorizationRequest.</summary>
internal sealed class AuthorizationRequestJsonConverter : JsonConverter<AuthorizationRequest>
{
    public override AuthorizationRequest Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => throw new NotSupportedException("AuthorizationRequest is not deserializable from JSON.");

    public override void Write(Utf8JsonWriter writer, AuthorizationRequest value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("url", value.Url);
        writer.WriteString("state", value.State);
        writer.WriteString("nonce", value.Nonce);
        writer.WriteString("codeVerifier", Masking.Mask(value.CodeVerifier));
        writer.WriteEndObject();
    }
}

/// <summary>Masks access/refresh tokens when a TokenSet is JSON-serialized via System.Text.Json.
/// NOTE: reflection-based destructuring loggers (Serilog {@}) read raw properties and bypass this
/// converter entirely — do not @-destructure TokenSet.</summary>
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
