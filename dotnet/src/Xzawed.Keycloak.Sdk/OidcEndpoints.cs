namespace Xzawed.Keycloak;

/// <summary>Keycloak OIDC endpoints assembled from convention — no network round-trip.</summary>
public sealed record OidcEndpoints(
    string Issuer, string Token, string Authorization, string Introspection, string EndSession, string Jwks)
{
    public static OidcEndpoints For(string serverUrl, string realm)
    {
        var issuer = $"{serverUrl.TrimEnd('/')}/realms/{realm}";
        var b = $"{issuer}/protocol/openid-connect";
        return new OidcEndpoints(issuer, $"{b}/token", $"{b}/auth", $"{b}/token/introspect", $"{b}/logout", $"{b}/certs");
    }
}
