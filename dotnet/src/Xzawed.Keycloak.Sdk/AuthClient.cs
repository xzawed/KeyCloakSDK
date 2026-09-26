using System.Net;
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
        // the validator expects by default; setting KeycloakConfig.ExpectedAudience makes this shared
        // validator demand that value from the id_token too, so map it into the id_token as well)
        // and then check the nonce claim. Fails CLOSED when a nonce was supplied
        // (CreateAuthorizationRequest always issues one), matching the Node posture —
        // a missing id_token must throw, NOT silently skip validation (an attacker could otherwise strip
        // the id_token to bypass the nonce binding).
        if (nonce is not null)
        {
            if (tokens.IdToken is not { } idToken)
                throw new KeycloakAuthException("id_token missing for nonce validation");
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
        catch (InvalidOperationException ex) when (ex.TargetSite?.DeclaringType?.Assembly == typeof(JsonElement).Assembly)
        {
            // ⚠️ Duende 는 응답을 만드는 도중(TokenIntrospectionResponse.InitializeAsync) 본문을 객체로 색인한다 — JSON 루트가
            // 문자열·배열이면 IntrospectTokenAsync 자체가 던져 SDK 타입으로 번역되지 않고 샜다(§4, 실측). 메시지는 JSON 종류뿐이다.
            // 거르는 기준은 던진 어셈블리다 — ex.Source 는 System.Text.Json 의 내부 표식("System.Text.Json.Rethrowable")이라 계약이 아니다(실측).
            throw new KeycloakAuthException("Token introspection failed: response body is not a JSON object", ex);
        }
        ThrowIfError(resp, "Token introspection failed", "introspection transport failure");

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
            // HttpClient.PostAsync는 전송 실패(연결거부/DNS/TLS)에 HttpRequestException을 던진다 — 전송 오류.
            // ⚠️ 형식이 틀린 응답의 오류는 잘못된 헤더 줄을 인용한다 — 그 메시지를 SDK 메시지에 복사하지 않는다(ErrorCause).
            throw new KeycloakTransportException($"Logout request error: {ErrorCause.MessageOf(ex)}", ex);
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
        ThrowIfError(resp, failureMessage, $"{failureMessage} (transport)");
        // ⚠️ **존재 검사는 타입 검사가 아니다 — Duende 는 JSON 값을 강제변환한다.** 실측:
        // `access_token: 12345` → `"12345"`, `{"a":1}` → 그 문자열. 그래서 아래
        // `TokenSet.Create` 의 `IsNullOrEmpty` 검사를 통과하고, 소비자는 쓸 수 없는 토큰을
        // Bearer 로 실어 보내 매번 401 을 받는다. 원본 JSON 의 **종류**를 여기서 본다.
        if (resp.Json is { } body
            && body.TryGetProperty("access_token", out var rawAccessToken)
            && rawAccessToken.ValueKind != JsonValueKind.String)
        {
            throw new KeycloakAuthException($"{failureMessage}: access_token is not a JSON string");
        }
        return TokenSet.Create(resp.AccessToken!, resp.TokenType, resp.ExpiresIn,
                               resp.RefreshToken, resp.IdentityToken, resp.Scope, issuedAtSeconds);
    }

    /// <summary>Converts a Duende error response (token or introspection endpoint) to the SDK error.</summary>
    /// <remarks>⚠️ Beyond the OAuth <c>error</c> code, nothing the server wrote reaches the SDK error — Duende's own
    /// <c>Error</c> is the server's reason phrase for an HTTP error and the raw JSON text of a non-string <c>error</c>
    /// member, and its <c>IsError</c> throws on a JSON root that is not an object (all three measured, with a token
    /// echoed in them: <c>MalformedTokenResponseTests</c>).</remarks>
    private static void ThrowIfError(ProtocolResponse resp, string failureMessage, string transportMessage)
    {
        switch (resp.ErrorType)
        {
            case ResponseErrorType.Exception:
                // 전송 실패(연결거부/DNS/TLS) — 그리고 Duende 가 JSON 으로 못 읽은 본문(처음부터 이 분류다). 전송 실패는
                // KeycloakTransportException 이어야 §4 경계에서 인증 실패와 구분된다. 원인 사슬은 생성자가 정화한다
                // (JSON 파서가 본문을 인용한다 — ErrorCause).
                throw new KeycloakTransportException(transportMessage, resp.Exception);
            case ResponseErrorType.Http:
                // Keycloak 은 잘못된 클라이언트 자격증명에 401 을 준다 — OAuth 코드는 본문에서 읽는다.
                var reason = CanonicalReason(resp.HttpStatusCode);
                throw new KeycloakAuthException($"{failureMessage}: {reason}") { OAuthError = OAuthErrorOf(resp.Json) ?? reason };
        }
        if (resp.Json is { ValueKind: not JsonValueKind.Object })
            throw new KeycloakAuthException($"{failureMessage}: response body is not a JSON object");
        if (resp.IsError)
        {
            var code = OAuthErrorOf(resp.Json);
            throw new KeycloakAuthException($"{failureMessage}: {code ?? "error is not a JSON string"}") { OAuthError = code };
        }
    }

    // Only a JSON string is an OAuth error code — Duende renders any other kind as its raw JSON text.
    private static string? OAuthErrorOf(JsonElement? json) =>
        json is { ValueKind: JsonValueKind.Object } j && j.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.String
            ? e.GetString()
            : null;

    // The standard phrase for the status, never the server's — a reason phrase is wire text the server chooses. Keycloak's
    // are the standard ones (and HTTP/2 has none), so the message is unchanged for it.
    private static string CanonicalReason(HttpStatusCode status)
    {
        using var canonical = new HttpResponseMessage(status);
        return canonical.ReasonPhrase ?? $"HTTP {(int)status}";
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
