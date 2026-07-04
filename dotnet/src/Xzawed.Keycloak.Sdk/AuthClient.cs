using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Duende.IdentityModel;
using Duende.IdentityModel.Client;

namespace Xzawed.Keycloak;

/// <summary>OIDC/OAuth2 facade wrapping Duende.IdentityModel. Also serves as the default
/// client-credentials <c>ITokenSource</c> for the admin facade.</summary>
public sealed class AuthClient : ITokenSource
{
    private readonly KeycloakConfig _cfg;
    private readonly OidcEndpoints _ep;
    private readonly JwtValidator _validator;
    private readonly HttpClient _http;

    public AuthClient(KeycloakConfig cfg, OidcEndpoints ep, JwtValidator validator, HttpClient http)
    {
        _cfg = cfg; _ep = ep; _validator = validator; _http = http;
    }

    /// <summary>Starts a PKCE (S256) authorization-code flow. Synchronous — no network.</summary>
    public AuthorizationRequest CreateAuthorizationRequest(string redirectUri)
    {
        var codeVerifier = CryptoRandom.CreateUniqueId(32, CryptoRandom.OutputFormat.Base64Url);
        var codeChallenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(codeVerifier)));
        var state = CryptoRandom.CreateUniqueId(16, CryptoRandom.OutputFormat.Base64Url);
        var nonce = CryptoRandom.CreateUniqueId(16, CryptoRandom.OutputFormat.Base64Url);
        var scope = _cfg.Scopes.Count > 0 ? string.Join(' ', _cfg.Scopes) : "openid";

        var url = new RequestUrl(_ep.Authorization).CreateAuthorizeUrl(
            clientId: _cfg.ClientId,
            responseType: OidcConstants.ResponseTypes.Code,
            scope: scope,
            redirectUri: redirectUri,
            state: state,
            nonce: nonce,
            codeChallenge: codeChallenge,
            codeChallengeMethod: OidcConstants.CodeChallengeMethods.Sha256);

        return new AuthorizationRequest(url, codeVerifier, state, nonce);
    }

    public async Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default)
    {
        var issuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        TokenResponse resp;
        try
        {
            resp = await _http.RequestClientCredentialsTokenAsync(new ClientCredentialsTokenRequest
            {
                Address = _ep.Token,
                ClientId = _cfg.ClientId,
                ClientSecret = _cfg.ClientSecret,
                Scope = _cfg.Scopes.Count > 0 ? string.Join(' ', _cfg.Scopes) : null,
            }, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)
        {
            throw new KeycloakTransportException("token request timed out", ex);
        }
        return ToTokenSet(resp, "Client credentials grant failed", issuedAt);
    }

    public async Task<TokenSet> ExchangeCodeAsync(string code, string redirectUri, string codeVerifier,
                                                  string? nonce = null, CancellationToken ct = default)
    {
        var issuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        TokenResponse resp;
        try
        {
            resp = await _http.RequestAuthorizationCodeTokenAsync(new AuthorizationCodeTokenRequest
            {
                Address = _ep.Token,
                ClientId = _cfg.ClientId,
                ClientSecret = _cfg.ClientSecret,
                Code = code,
                RedirectUri = redirectUri,
                CodeVerifier = codeVerifier,
            }, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)
        {
            throw new KeycloakTransportException("token request timed out", ex);
        }
        var tokens = ToTokenSet(resp, "Authorization code exchange failed", issuedAt);

        // NONCE: Duende does not auto-validate the id_token (unlike openid-client). Fully validate it
        // (signature/iss/aud/exp via the hardened validator — Keycloak id_token aud == clientId, which
        // the validator is already configured for) and then check the nonce claim. Fails CLOSED when a
        // nonce was supplied (CreateAuthorizationRequest always issues one), matching the Node posture.
        if (nonce is not null && tokens.IdToken is { } idToken)
        {
            ValidatedToken idt;
            try { idt = await _validator.ValidateAsync(idToken, ct).ConfigureAwait(false); }
            catch (KeycloakTokenValidationException ex) { throw new KeycloakAuthException("id_token validation failed", ex); }
            if (!idt.Claims.TryGetValue("nonce", out var n) || n as string != nonce)
                throw new KeycloakAuthException("id_token nonce mismatch");
        }
        return tokens;
    }

    public async Task<TokenSet> RefreshAsync(string refreshToken, CancellationToken ct = default)
    {
        var issuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        TokenResponse resp;
        try
        {
            resp = await _http.RequestRefreshTokenAsync(new RefreshTokenRequest
            {
                Address = _ep.Token,
                ClientId = _cfg.ClientId,
                ClientSecret = _cfg.ClientSecret,
                RefreshToken = refreshToken,
            }, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)
        {
            throw new KeycloakTransportException("token request timed out", ex);
        }
        return ToTokenSet(resp, "Token refresh failed", issuedAt);
    }

    public async Task<IntrospectionResult> IntrospectAsync(string token, CancellationToken ct = default)
    {
        TokenIntrospectionResponse resp;
        try
        {
            resp = await _http.IntrospectTokenAsync(new TokenIntrospectionRequest
            {
                Address = _ep.Introspection,
                ClientId = _cfg.ClientId,
                ClientSecret = _cfg.ClientSecret,
                Token = token,
            }, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)
        {
            throw new KeycloakTransportException("introspection request timed out", ex);
        }
        if (resp.IsError)
            throw new KeycloakAuthException($"Token introspection failed: {resp.Error}", resp.Exception) { OAuthError = OAuthErrorOf(resp.Json, resp.Error) };

        var claims = resp.Claims.GroupBy(c => c.Type)
            .ToDictionary(g => g.Key, g => (object?)(g.Count() == 1 ? g.First().Value : g.Select(c => c.Value).ToArray()));
        return new IntrospectionResult(resp.IsActive, resp.UserName, resp.ClientId, claims);
    }

    public async Task LogoutAsync(string refreshToken, CancellationToken ct = default)
    {
        var form = new Dictionary<string, string>
        {
            ["client_id"] = _cfg.ClientId,
            ["refresh_token"] = refreshToken,
        };
        if (_cfg.ClientSecret is { } secret) form["client_secret"] = secret;

        HttpResponseMessage resp;
        try
        {
            using var content = new FormUrlEncodedContent(form);
            resp = await _http.PostAsync(_ep.EndSession, content, ct).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            throw new KeycloakAuthException($"Logout request error: {ex.Message}", ex);
        }
        catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)
        {
            throw new KeycloakTransportException("logout request timed out", ex);
        }
        using (resp)
        {
            if (!resp.IsSuccessStatusCode)
                throw new KeycloakAuthException($"Logout failed (HTTP {(int)resp.StatusCode})");
        }
    }

    public Task<ValidatedToken> ValidateAsync(string accessToken, CancellationToken ct = default)
        => _validator.ValidateAsync(accessToken, ct);

    private static TokenSet ToTokenSet(TokenResponse resp, string failureMessage, long issuedAtSeconds)
    {
        if (resp.IsError)
            throw new KeycloakAuthException($"{failureMessage}: {resp.Error}", resp.Exception) { OAuthError = OAuthErrorOf(resp.Json, resp.Error) };
        return TokenSet.Create(resp.AccessToken!, resp.TokenType, resp.ExpiresIn,
                               resp.RefreshToken, resp.IdentityToken, resp.Scope, issuedAtSeconds);
    }

    // Keycloak returns 401 for bad client creds => ErrorType=Http (resp.Error = reason phrase),
    // so read the OAuth code from the JSON body. Shared by the token endpoint (TokenResponse) and the
    // introspection endpoint (TokenIntrospectionResponse) — both expose Json/Error via ProtocolResponse.
    private static string? OAuthErrorOf(JsonElement? json, string? fallbackError)
    {
        if (json is JsonElement j && j.ValueKind == JsonValueKind.Object
            && j.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.String)
            return e.GetString();
        return fallbackError;
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
