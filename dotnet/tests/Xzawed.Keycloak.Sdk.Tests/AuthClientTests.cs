using System.Security.Cryptography;
using System.Threading.Tasks;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class AuthClientTests : IDisposable
{
    private readonly WireMockServer _mock = WireMockServer.Start();
    private readonly HttpClient _http = new();

    private AuthClient Build(out KeycloakConfig cfg)
    {
        cfg = new KeycloakConfig
        {
            ServerUrl = _mock.Urls[0],
            Realm = "r",
            ClientId = "c",
            ClientSecret = "s",
            Scopes = new[] { "openid", "profile" }
        }.Normalized();
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        var validator = new JwtValidator(JwtValidator.BuildParameters(ep.Issuer,
            new JwtValidatorOptions { Issuer = ep.Issuer, Audiences = new[] { "c" } }));
        return new AuthClient(cfg, ep, validator, _http);
    }

    // ⚠️ Stop()이 아니라 Dispose() — 근거는 AdminClientTests.Dispose 주석 참고(호스트/리스너가
    // 남아 프로세스 종료가 느려지고, 그 지연이 커버리지 히트 flush 실패의 가중 요인이 된다).
    public void Dispose() { _mock.Dispose(); _http.Dispose(); }

    // 공백이 섞인 ServerUrl은 첫 토큰 호출의 UriFormatException이 아니라 생성 시점에 거절된다.
    [Fact]
    public void Create_with_space_in_server_url_fails_at_construction()
    {
        const string serverUrl = "http://kc example.com";
        var ex = Assert.Throws<KeycloakConfigException>(() =>
            KeycloakClient.Create(new KeycloakConfig
            {
                ServerUrl = serverUrl,
                Realm = "r",
                ClientId = "c",
                ClientSecret = "s",
            }));
        Assert.StartsWith("ServerUrl must be an absolute http(s) URL", ex.Message);
        Assert.DoesNotContain(serverUrl, ex.Message);
    }

    [Fact]
    public void CreateAuthorizationRequest_builds_s256_url_with_all_params()
    {
        var auth = Build(out _);
        var req = auth.CreateAuthorizationRequest("https://app/callback");
        Assert.Contains("response_type=code", req.Url);
        Assert.Contains("code_challenge_method=S256", req.Url);
        Assert.Contains("code_challenge=", req.Url);
        Assert.Contains("scope=openid%20profile", req.Url);
        Assert.Contains($"state={req.State}", req.Url);
        Assert.Contains($"nonce={req.Nonce}", req.Url);
        Assert.NotEmpty(req.CodeVerifier);
    }

    [Fact]
    public void CreateAuthorizationRequest_values_differ_per_call()
    {
        var auth = Build(out _);
        var a = auth.CreateAuthorizationRequest("https://app/cb");
        var b = auth.CreateAuthorizationRequest("https://app/cb");
        Assert.NotEqual(a.CodeVerifier, b.CodeVerifier);
        Assert.NotEqual(a.State, b.State);
        Assert.NotEqual(a.Nonce, b.Nonce);
    }

    [Fact]
    public async Task ClientCredentialsToken_maps_response()
    {
        var auth = Build(out var cfg);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { access_token = "AT", token_type = "Bearer", expires_in = 300, scope = "openid" }));
        var ts = await auth.ClientCredentialsTokenAsync();
        Assert.Equal("AT", ts.AccessToken);
        Assert.Equal(300, ts.ExpiresIn);
        Assert.NotNull(ts.ExpiresAt);
    }

    /// <summary>
    /// ⚠️ <b>존재 검사는 타입 검사가 아니다.</b> Duende 는 JSON 값을 <b>강제변환</b>한다 —
    /// 실측: <c>access_token: 12345</c> → <c>"12345"</c>, <c>{"a":1}</c> → 그 문자열.
    /// 그래서 SDK 의 <c>string.IsNullOrEmpty</c> 검사를 통과하고, 소비자는 쓸 수 없는 토큰을
    /// Bearer 로 실어 보내 매번 401 을 받는다(조용한 반복 실패).
    /// 아홉 언어 전수 측정에서 다섯이 이 부류였다(java·kotlin·node·go 는 이미 거부).
    /// </summary>
    [Theory]
    [InlineData("12345")]
    [InlineData("null")]
    [InlineData("{\"a\":1}")]
    [InlineData("[1,2]")]
    [InlineData("true")]
    public async Task ClientCredentialsToken_rejects_non_string_access_token(string rawJsonValue)
    {
        var auth = Build(out _);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBody($"{{\"access_token\":{rawJsonValue},\"token_type\":\"Bearer\",\"expires_in\":300}}"));
        await Assert.ThrowsAsync<KeycloakAuthException>(() => auth.ClientCredentialsTokenAsync());
    }

    [Fact]
    public async Task ClientCredentialsToken_error_wrapped()
    {
        var auth = Build(out _);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(401).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { error = "invalid_client", error_description = "bad creds" }));
        var ex = await Assert.ThrowsAsync<KeycloakAuthException>(() => auth.ClientCredentialsTokenAsync());
        Assert.Equal("invalid_client", ex.OAuthError);
    }

    [Fact]
    public async Task ClientCredentialsToken_timeout_wrapped_as_transport_exception()
    {
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithDelay(TimeSpan.FromMilliseconds(1500))
                 .WithBodyAsJson(new { access_token = "AT", token_type = "Bearer", expires_in = 300 }));

        var cfg = new KeycloakConfig
        {
            ServerUrl = _mock.Urls[0],
            Realm = "r",
            ClientId = "c",
            ClientSecret = "s",
            ReadTimeoutMs = 200,
        }.Normalized();
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        var validator = new JwtValidator(JwtValidator.BuildParameters(ep.Issuer,
            new JwtValidatorOptions { Issuer = ep.Issuer, Audiences = new[] { "c" } }));
        // Dedicated short-timeout HttpClient: the shared _http (used by the other tests in this class)
        // has no Timeout set, so a fresh AuthClient/HttpClient pair is needed to exercise the timeout path.
        using var shortHttp = new HttpClient { Timeout = TimeSpan.FromMilliseconds(cfg.ReadTimeoutMs) };
        var auth = new AuthClient(cfg, ep, validator, shortHttp);

        await Assert.ThrowsAsync<KeycloakTransportException>(() => auth.ClientCredentialsTokenAsync());
    }

    [Fact]
    public async Task ClientCredentialsToken_transportFailure_wrapped_as_transport_exception()
    {
        // 연결거부/DNS/TLS는 HttpRequestException으로 나타나고 Duende가 ErrorType=Exception으로 감싼다.
        // 인증 실패(HTTP 401)가 아니라 전송 실패이므로 KeycloakTransportException이어야 한다(§4 경계).
        var cfg = new KeycloakConfig { ServerUrl = "http://kc.example", Realm = "r", ClientId = "c", ClientSecret = "s" }.Normalized();
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        var validator = new JwtValidator(JwtValidator.BuildParameters(ep.Issuer,
            new JwtValidatorOptions { Issuer = ep.Issuer, Audiences = new[] { "c" } }));
        using var http = new HttpClient(new ThrowingHandler(new HttpRequestException("connection refused")));
        var auth = new AuthClient(cfg, ep, validator, http);
        await Assert.ThrowsAsync<KeycloakTransportException>(() => auth.ClientCredentialsTokenAsync());
    }

    private sealed class ThrowingHandler(Exception ex) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => throw ex;
    }

    [Fact]
    public async Task Introspect_maps_active_and_fields()
    {
        var auth = Build(out _);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token/introspect").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { active = true, username = "alice", client_id = "c" }));
        var ir = await auth.IntrospectAsync("some-token");
        Assert.True(ir.Active);
        Assert.Equal("alice", ir.Username);
        Assert.Equal("c", ir.ClientId);
    }

    [Fact]
    public async Task Logout_posts_and_errors_on_non_2xx()
    {
        var auth = Build(out _);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/logout").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(400));
        await Assert.ThrowsAsync<KeycloakAuthException>(() => auth.LogoutAsync("rt"));
    }

    private AuthClient BuildWithKey(out KeycloakConfig cfg, SecurityKey signingKey)
    {
        cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" }.Normalized();
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        var tvp = JwtValidator.BuildParameters(ep.Issuer, new JwtValidatorOptions { Issuer = ep.Issuer, Audiences = new[] { "c" } });
        tvp.IssuerSigningKey = signingKey;
        tvp.ConfigurationManager = null;
        return new AuthClient(cfg, ep, new JwtValidator(tvp), _http);
    }

    private static string SignIdToken(string issuer, string audience, string nonce, SecurityKey key)
    {
        var handler = new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false };
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var payload = $$"""{"iss":"{{issuer}}","sub":"u","aud":"{{audience}}","nonce":"{{nonce}}","exp":{{now + 300}},"iat":{{now}}}""";
        return handler.CreateToken(payload, new SigningCredentials(key, SecurityAlgorithms.RsaSha256));
    }

    private void StubToken(string idToken) =>
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { access_token = "AT", token_type = "Bearer", expires_in = 300, id_token = idToken }));

    [Fact]
    public async Task ExchangeCode_valid_nonce_matches()
    {
        var key = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        var auth = BuildWithKey(out var cfg, key);
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        StubToken(SignIdToken(ep.Issuer, "c", "the-nonce", key));
        var ts = await auth.ExchangeCodeAsync("code", "https://app/cb", "verifier", nonce: "the-nonce");
        Assert.Equal("AT", ts.AccessToken);
    }

    [Fact]
    public async Task ExchangeCode_nonce_mismatch_throws()
    {
        var key = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        var auth = BuildWithKey(out var cfg, key);
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        StubToken(SignIdToken(ep.Issuer, "c", "server-nonce", key));
        await Assert.ThrowsAsync<KeycloakAuthException>(
            () => auth.ExchangeCodeAsync("code", "https://app/cb", "verifier", nonce: "expected-nonce"));
    }

    [Fact]
    public async Task ExchangeCode_untrusted_idtoken_throws()
    {
        var trusted = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        var attacker = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        var auth = BuildWithKey(out var cfg, trusted);
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        StubToken(SignIdToken(ep.Issuer, "c", "n", attacker)); // signed by wrong key => validation fails
        await Assert.ThrowsAsync<KeycloakAuthException>(
            () => auth.ExchangeCodeAsync("code", "https://app/cb", "verifier", nonce: "n"));
    }

    private void StubTokenWithoutIdToken() =>
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { access_token = "AT", token_type = "Bearer", expires_in = 300 }));

    // Fail-closed: a nonce was supplied (CreateAuthorizationRequest always issues one) but the
    // token response carried no id_token — an attacker stripping the id_token must NOT bypass the
    // nonce binding by silently skipping validation.
    [Fact]
    public async Task ExchangeCode_missing_idtoken_with_nonce_throws()
    {
        var key = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        var auth = BuildWithKey(out _, key);
        StubTokenWithoutIdToken();
        await Assert.ThrowsAsync<KeycloakAuthException>(
            () => auth.ExchangeCodeAsync("code", "https://app/cb", "verifier", nonce: "the-nonce"));
    }

    // ── id_token audience under an ExpectedAudience override ──
    // An id_token's aud MUST contain the client_id (OIDC Core §2, §3.1.3.7); ExpectedAudience restricts ACCESS tokens
    // to a resource server. Every validator below takes its options from KeycloakClient.ValidatorOptionsFor — the
    // mapping the facade actually uses — so the override is the real one, not a hand-made audience list.

    private const string Override = "extra-api";
    private const string Nonce = "the-nonce";

    private static RsaSecurityKey NewKey() => new(RSA.Create(2048)) { KeyId = "k1" };

    private KeycloakConfig OverrideConfig(string[]? algorithms = null) => new KeycloakConfig
    {
        ServerUrl = _mock.Urls[0],
        Realm = "r",
        ClientId = "c",
        ClientSecret = "s",
        ExpectedAudience = Override,
        SignatureAlgorithms = algorithms ?? new[] { "RS256" },
    }.Normalized();

    private AuthClient BuildWithOverride(SecurityKey signingKey, out string issuer, string[]? algorithms = null)
    {
        var cfg = OverrideConfig(algorithms);
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        issuer = ep.Issuer;
        var tvp = JwtValidator.BuildParameters(ep.Issuer, KeycloakClient.ValidatorOptionsFor(cfg, ep.Issuer));
        tvp.IssuerSigningKey = signingKey;
        tvp.ConfigurationManager = null;
        return new AuthClient(cfg, ep, new JwtValidator(tvp), _http);
    }

    private static string Claims(string issuer, string audJson, string nonce = Nonce, long? expOffset = 300)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var exp = expOffset is { } offset ? $",\"exp\":{now + offset}" : "";
        return $$"""{"iss":"{{issuer}}","sub":"u","aud":{{audJson}},"nonce":"{{nonce}}","iat":{{now}}{{exp}}}""";
    }

    private static string SignClaims(string payloadJson, SecurityKey? key, string alg = SecurityAlgorithms.RsaSha256)
    {
        var handler = new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false };
        return key is null ? handler.CreateToken(payloadJson) : handler.CreateToken(payloadJson, new SigningCredentials(key, alg));
    }

    private static Task<TokenSet> Exchange(AuthClient auth, string nonce = Nonce) =>
        auth.ExchangeCodeAsync("code", "https://app/cb", "verifier", nonce: nonce);

    /// <summary>A1. Keycloak puts the client id in the id_token's aud whatever the access token's audience mapper
    /// adds (measured on 26.6); with "Add to ID token" on, the override joins it.</summary>
    [Theory]
    [InlineData("\"c\"")]
    [InlineData("[\"c\",\"extra-api\"]")]
    public async Task ExchangeCode_under_expected_audience_override_accepts_an_id_token_for_the_client_id(string audJson)
    {
        var key = NewKey();
        var auth = BuildWithOverride(key, out var issuer);
        StubToken(SignClaims(Claims(issuer, audJson), key));
        var ts = await Exchange(auth);
        Assert.Equal("AT", ts.AccessToken);
    }

    /// <summary>A2. Without the client id the id_token was not issued to this client — the override alone (what the
    /// id_token had to carry before) is refused too.</summary>
    [Theory]
    [InlineData("\"extra-api\"")]
    [InlineData("[\"extra-api\",\"account\"]")]
    [InlineData("\"someone-else\"")]
    public async Task ExchangeCode_under_override_refuses_an_id_token_whose_aud_lacks_the_client_id(string audJson)
    {
        var key = NewKey();
        var auth = BuildWithOverride(key, out var issuer);
        StubToken(SignClaims(Claims(issuer, audJson), key));
        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(() => Exchange(auth));
        Assert.Equal("id_token validation failed", refused.Message);
        var validation = Assert.IsType<KeycloakTokenValidationException>(refused.InnerException);
        Assert.IsType<SecurityTokenInvalidAudienceException>(validation.InnerException);
    }

    /// <summary>A3. The exchange runs FIRST on the same client: the id_token check must not retarget the access
    /// check that shares its validator.</summary>
    [Fact]
    public async Task ValidateAsync_after_an_exchange_still_holds_access_tokens_to_the_override()
    {
        var key = NewKey();
        var auth = BuildWithOverride(key, out var issuer);
        StubToken(SignClaims(Claims(issuer, "\"c\""), key));
        await Exchange(auth);

        var access = await auth.ValidateAsync(SignClaims(Claims(issuer, "[\"extra-api\",\"account\"]"), key));
        Assert.Contains(Override, access.Audience);
        var clientIdOnly = await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => auth.ValidateAsync(SignClaims(Claims(issuer, "\"c\""), key)));
        Assert.IsType<SecurityTokenInvalidAudienceException>(clientIdOnly.InnerException);
    }

    /// <summary>A4. Only the audience changes on the id_token path — every other check stays, each named by the
    /// IdentityModel cause so a row cannot pass on some other failure (aud is the client id in every row).</summary>
    [Theory]
    [InlineData("wrong issuer", typeof(SecurityTokenInvalidIssuerException))]
    [InlineData("RS384 outside the RS256 pin", typeof(SecurityTokenInvalidSignatureException))]
    [InlineData("expired 60s ago, past the 30s skew", typeof(SecurityTokenExpiredException))]
    [InlineData("no exp", typeof(SecurityTokenNoExpirationException))]
    [InlineData("unsigned", typeof(SecurityTokenInvalidSignatureException))]
    [InlineData("signed by another key", typeof(SecurityTokenSignatureKeyNotFoundException))]
    public async Task ExchangeCode_under_override_keeps_every_other_id_token_check(string check, Type cause)
    {
        var key = NewKey();
        var auth = BuildWithOverride(key, out var issuer);
        var idToken = check switch
        {
            "wrong issuer" => SignClaims(Claims("https://evil.example.com/realms/r", "\"c\""), key),
            "RS384 outside the RS256 pin" => SignClaims(Claims(issuer, "\"c\""), key, SecurityAlgorithms.RsaSha384),
            "expired 60s ago, past the 30s skew" => SignClaims(Claims(issuer, "\"c\"", expOffset: -60), key),
            "no exp" => SignClaims(Claims(issuer, "\"c\"", expOffset: null), key),
            "unsigned" => SignClaims(Claims(issuer, "\"c\""), key: null),
            "signed by another key" => SignClaims(Claims(issuer, "\"c\""), new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k2" }),
            _ => throw new ArgumentOutOfRangeException(nameof(check)),
        };
        StubToken(idToken);
        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(() => Exchange(auth));
        Assert.Equal("id_token validation failed", refused.Message);
        var validation = Assert.IsType<KeycloakTokenValidationException>(refused.InnerException);
        Assert.IsType(cause, validation.InnerException);
    }

    /// <summary>A4 (alg pin). Control for the RS384 row: IdentityModel reports a pin violation as a signature failure,
    /// so this shows the same token under the same key passes once the config's pin admits RS384 — the row fails on the
    /// pin, and the pin on the id_token path is the config's.</summary>
    [Fact]
    public async Task ExchangeCode_under_override_takes_the_algorithm_pin_from_the_config()
    {
        var key = NewKey();
        var auth = BuildWithOverride(key, out var issuer, algorithms: new[] { "RS256", "RS384" });
        StubToken(SignClaims(Claims(issuer, "\"c\""), key, SecurityAlgorithms.RsaSha384));
        Assert.Equal("AT", (await Exchange(auth)).AccessToken);
    }

    /// <summary>A4 (skew). The row above shows the skew is not IdentityModel's 5 minutes; this one shows it is not zero.</summary>
    [Fact]
    public async Task ExchangeCode_under_override_accepts_an_id_token_expired_within_the_30s_skew()
    {
        var key = NewKey();
        var auth = BuildWithOverride(key, out var issuer);
        StubToken(SignClaims(Claims(issuer, "\"c\"", expOffset: -10), key));
        Assert.Equal("AT", (await Exchange(auth)).AccessToken);
    }

    /// <summary>A4 (nonce). The nonce comparison is untouched: an id_token that passes every claim check is still
    /// refused by nonce alone.</summary>
    [Fact]
    public async Task ExchangeCode_under_override_still_compares_the_nonce()
    {
        var key = NewKey();
        var auth = BuildWithOverride(key, out var issuer);
        StubToken(SignClaims(Claims(issuer, "\"c\"", nonce: "server-nonce"), key));
        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(() => Exchange(auth, nonce: "expected-nonce"));
        Assert.Equal("id_token nonce mismatch", refused.Message);
        Assert.Null(refused.InnerException);
    }

    // ── A5: one key store. The id_token check must reuse the validator's ConfigurationManager — its JWKS cache,
    // 30s refresh gate, cold-cache backoff and last-known-good — never build a second one. ──

    private const string DiscoveryPath = "/realms/r/.well-known/openid-configuration";
    private const string CertsPath = "/realms/r/protocol/openid-connect/certs";

    private int Hits(string path) => _mock.LogEntries.Count(e => e.RequestMessage?.Path == path);

    private void StubKeyStore(string issuer, RsaSecurityKey key)
    {
        var p = key.Rsa!.ExportParameters(false);
        _mock.Given(Request.Create().WithPath(DiscoveryPath).UsingGet())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBody($$"""{"issuer":"{{issuer}}","jwks_uri":"{{issuer}}/protocol/openid-connect/certs"}"""));
        _mock.Given(Request.Create().WithPath(CertsPath).UsingGet())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBody($$"""{"keys":[{"kty":"RSA","kid":"{{key.KeyId}}","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}]}"""));
    }

    /// <summary>A5 through the facade's own wiring (<c>KeycloakClient.Create</c>): the exchange loads the store once
    /// and access validation reuses it.</summary>
    [Fact]
    public async Task Exchange_then_ValidateAsync_fetch_the_jwks_once_under_the_override()
    {
        var key = NewKey();
        var cfg = OverrideConfig();
        var issuer = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm).Issuer;
        StubKeyStore(issuer, key);
        var idToken = SignClaims(Claims(issuer, "\"c\""), key);
        var accessToken = SignClaims(Claims(issuer, "\"extra-api\""), key);
        StubToken(idToken);

        using (var kc = KeycloakClient.Create(cfg))
        {
            await Exchange(kc.Auth);
            Assert.Equal(1, Hits(CertsPath));
            await kc.Auth.ValidateAsync(accessToken);
            Assert.Equal(1, Hits(CertsPath));
            Assert.Equal(1, Hits(DiscoveryPath));
        }

        // Control: two key stores against the same IdP DO fetch twice — without it the counts above could not see a
        // second store.
        _mock.ResetLogEntries();
        using var http = new HttpClient();
        var opts = KeycloakClient.ValidatorOptionsFor(cfg, issuer);
        await new JwtValidator(issuer, opts, http).ValidateForAudienceAsync(idToken, cfg.ClientId);
        await new JwtValidator(issuer, opts, http).ValidateAsync(accessToken);
        Assert.Equal(2, Hits(CertsPath));
    }

    /// <summary>A5 (refetch gate). .NET refetches on a forged signature (<c>.claude/rules/dotnet.md</c>) — the forged
    /// id_token spends the ONE 30s window, so a forged access token right after it cannot open another.</summary>
    [Fact]
    public async Task Forged_id_token_and_forged_access_token_share_one_refetch_window()
    {
        var key = NewKey();
        var attacker = NewKey(); // same kid, different key: a signature failure, not an unknown kid
        var cfg = OverrideConfig();
        var issuer = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm).Issuer;
        StubKeyStore(issuer, key);
        using var http = new HttpClient();
        var opts = KeycloakClient.ValidatorOptionsFor(cfg, issuer);
        var auth = new AuthClient(cfg, OidcEndpoints.For(cfg.ServerUrl, cfg.Realm), new JwtValidator(issuer, opts, http), http);

        Assert.Contains(Override, (await auth.ValidateAsync(SignClaims(Claims(issuer, "\"extra-api\""), key))).Audience);
        var warm = Hits(CertsPath);
        StubToken(SignClaims(Claims(issuer, "\"c\""), attacker));
        await Assert.ThrowsAsync<KeycloakAuthException>(() => Exchange(auth));
        var afterExchange = await SettledHitsAsync(CertsPath, warm);
        Assert.True(afterExchange > warm, "the forged id_token must reach the store's refetch — else nothing below is shared");

        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => auth.ValidateAsync(SignClaims(Claims(issuer, "\"extra-api\""), attacker)));
        Assert.Equal(afterExchange, await SettledHitsAsync(CertsPath, afterExchange));

        // Control: a second store has a window of its own and does refetch on the same forgery.
        var second = new JwtValidator(issuer, opts, http);
        await second.ValidateAsync(SignClaims(Claims(issuer, "\"extra-api\""), key));
        var secondWarm = Hits(CertsPath);
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => second.ValidateAsync(SignClaims(Claims(issuer, "\"extra-api\""), attacker)));
        Assert.True(await SettledHitsAsync(CertsPath, secondWarm) > secondWarm,
            "control: a separate store must refetch, else this test cannot see one");
    }

    /// <summary>ConfigurationManager may apply a requested refresh off the request thread (JwksEmptyKeysetTests):
    /// wait for the count to move past <paramref name="baseline"/>, then give a late request time to land.</summary>
    private async Task<int> SettledHitsAsync(string path, int baseline)
    {
        var deadline = DateTime.UtcNow.AddSeconds(3);
        while (Hits(path) == baseline && DateTime.UtcNow < deadline)
            await Task.Delay(25);
        await Task.Delay(300);
        return Hits(path);
    }

    /// <summary>A5 (cold-cache backoff). A failing IdP seen by the exchange opens the backoff window that access
    /// validation then honours — no second request reaches the IdP.</summary>
    [Fact]
    public async Task Cold_cache_backoff_opened_by_the_exchange_also_holds_ValidateAsync()
    {
        var cfg = OverrideConfig();
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        _mock.Given(Request.Create().WithPath(DiscoveryPath).UsingGet())
             .RespondWith(Response.Create().WithStatusCode(503));
        var key = NewKey();
        StubToken(SignClaims(Claims(ep.Issuer, "\"c\""), key));
        var accessToken = SignClaims(Claims(ep.Issuer, "\"extra-api\""), key);
        var frozen = new DateTimeOffset(2026, 9, 27, 12, 0, 0, TimeSpan.Zero);
        using var http = new HttpClient();
        var opts = KeycloakClient.ValidatorOptionsFor(cfg, ep.Issuer);
        JwtValidator Store() => new(ep.Issuer, opts, http, () => frozen, () => 1.0);
        var auth = new AuthClient(cfg, ep, Store(), http);

        await Assert.ThrowsAsync<KeycloakAuthException>(() => Exchange(auth));
        var afterExchange = Hits(DiscoveryPath);
        Assert.True(afterExchange > 0, "the exchange must have reached the failing IdP");
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => auth.ValidateAsync(accessToken));
        Assert.Equal(afterExchange, Hits(DiscoveryPath));

        // Control: a second store has no window yet and goes out.
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => Store().ValidateAsync(accessToken));
        Assert.True(Hits(DiscoveryPath) > afterExchange, "control: a separate store must reach the IdP");
    }
}
