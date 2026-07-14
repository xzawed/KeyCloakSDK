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

    public void Dispose() { _mock.Stop(); _http.Dispose(); }

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
}
