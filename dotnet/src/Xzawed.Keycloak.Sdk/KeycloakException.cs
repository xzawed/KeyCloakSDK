namespace Xzawed.Keycloak;

/// <summary>Base for every error raised by this SDK. Lower-library exceptions are converted at the boundary.</summary>
public class KeycloakException : Exception
{
    public KeycloakException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>Configuration validation failure (missing/blank required value, missing clientSecret for admin).</summary>
public sealed class KeycloakConfigException : KeycloakException
{
    public KeycloakConfigException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>OIDC/OAuth2 flow failure (token endpoint, introspection, logout).</summary>
public sealed class KeycloakAuthException : KeycloakException
{
    /// <summary>OAuth2 error code from the token endpoint body, when available.</summary>
    public string? OAuthError { get; init; }
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
