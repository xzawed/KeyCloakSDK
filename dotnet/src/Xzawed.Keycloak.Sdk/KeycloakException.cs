namespace Xzawed.Keycloak;

/// <summary>Base for every error raised by this SDK. Lower-library exceptions are converted at the boundary; an inner
/// exception chain that quotes response input is attached as a copy without that input.</summary>
public class KeycloakException : Exception
{
    // One choke point for every wrap site (auth · jwt · admin) — see ErrorCause.
    public KeycloakException(string message, Exception? innerException = null) : base(message, ErrorCause.Scrub(innerException)) { }
}

/// <summary>Configuration validation failure (missing/blank required value, missing clientSecret for admin).</summary>
public sealed class KeycloakConfigException : KeycloakException
{
    public KeycloakConfigException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>OIDC/OAuth2 flow failure (token endpoint, introspection, logout).</summary>
public sealed class KeycloakAuthException : KeycloakException
{
    /// <summary>OAuth2 <c>error</c> code from a token or introspection response — only a value shaped like a code
    /// (<c>[a-z_]{1,64}</c>) that overlaps no secret the request sent, passed on unchanged; any other value is no code. When
    /// such a request fails with an HTTP status other than 400 and no code, this holds the status's standard reason phrase.</summary>
    /// <remarks>⚠️ Deprecated: that reason-phrase fallback is removed in the next major version, and from then on this is
    /// null whenever no code was carried. Code that compares it with one of those phrases (<c>"Unauthorized"</c>,
    /// <c>"Service Unavailable"</c>, <c>"HTTP 520"</c>) will then stop matching silently, with no compiler error — branch on
    /// <see cref="StatusCode"/> instead.</remarks>
    public string? OAuthError { get; init; }

    /// <summary>The HTTP status of the response that made the call fail: set whenever the token, introspection or logout
    /// endpoint's answer is what failed it, at any status. ⚠️ A value below 400 still means the call failed after that
    /// status — a 2xx other than 200 (logout: other than 204), or a 200 whose body could not be used: not UTF-8, not a JSON
    /// object, no usable <c>access_token</c> or <c>active</c>, an <c>error</c> member, and so on. Null when no response
    /// decided the failure: the id_token checks <see cref="AuthClient.ExchangeCodeAsync"/> runs on a token response it
    /// accepted (id_token missing, invalid or with another nonce), a token <see cref="ClientCredentialsTokenProvider"/>
    /// refuses before any admin request is sent, and <see cref="TokenSet.Create(string, string?, long, string?, string?, string?, long)"/>
    /// called by your own code. Never 0.</summary>
    public int? StatusCode { get; init; }

    public KeycloakAuthException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>JWT hardened-validation failure (signature/algorithm/issuer/audience/expiry).</summary>
public sealed class KeycloakTokenValidationException : KeycloakException
{
    public KeycloakTokenValidationException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>Admin REST failure carrying the HTTP status.</summary>
public class KeycloakAdminException : KeycloakException
{
    public int StatusCode { get; }
    public KeycloakAdminException(int statusCode, string message, Exception? innerException = null)
        : base(message, innerException) => StatusCode = statusCode;
}

public sealed class KeycloakNotFoundException : KeycloakAdminException
{
    public KeycloakNotFoundException(string message, Exception? innerException = null) : base(404, message, innerException) { }
}

public sealed class KeycloakConflictException : KeycloakAdminException
{
    public KeycloakConflictException(string message, Exception? innerException = null) : base(409, message, innerException) { }
}

public sealed class KeycloakForbiddenException : KeycloakAdminException
{
    public KeycloakForbiddenException(string message, Exception? innerException = null) : base(403, message, innerException) { }
}

/// <summary>Network/transport failure (connect/DNS/TLS/timeout) — no HTTP response received.</summary>
public sealed class KeycloakTransportException : KeycloakException
{
    public KeycloakTransportException(string message, Exception? innerException = null) : base(message, innerException) { }
}

internal static class KeycloakErrorMapping
{
    public static KeycloakException MapHttpError(int status, string message, Exception? cause = null) => status switch
    {
        404 => new KeycloakNotFoundException(message, cause),
        409 => new KeycloakConflictException(message, cause),
        403 => new KeycloakForbiddenException(message, cause),
        _ => new KeycloakAdminException(status, $"HTTP {status}: {message}", cause),
    };
}
