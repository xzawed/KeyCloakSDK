using System.Security.Cryptography;
using System.Threading.Tasks;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class JwtValidatorTests
{
    private const string Issuer = "https://kc.example.com/realms/it-realm";
    private static readonly RsaSecurityKey Key = new(RSA.Create(2048)) { KeyId = "test-kid" };

    private static string Sign(string payloadJson, SecurityKey? key = null)
    {
        // ⚠️ SetDefaultTimesOnTokenCreation defaults TRUE and would auto-inject exp/iat/nbf,
        // invalidating the Missing_exp test. Disable it so the payload is emitted verbatim.
        var handler = new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false };
        if (key is null) return handler.CreateToken(payloadJson); // unsigned => alg none
        var creds = new SigningCredentials(key, SecurityAlgorithms.RsaSha256);
        return handler.CreateToken(payloadJson, creds);
    }

    private static JwtValidator ValidatorWith(JwtValidatorOptions opts)
    {
        var tvp = JwtValidator.BuildParameters(Issuer, opts);
        tvp.IssuerSigningKey = Key;           // static key instead of ConfigurationManager (no network)
        tvp.ConfigurationManager = null;
        return new JwtValidator(tvp);          // internal test ctor
    }

    private static string PayloadJson(string aud, long expOffset = 300, string iss = Issuer)
        => $$"""{"iss":"{{iss}}","sub":"user-1","aud":{{aud}},"exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expOffset}},"iat":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}}}""";

    [Fact]
    public async Task Valid_RS256_returns_claims()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var vt = await v.ValidateAsync(Sign(PayloadJson("\"it-client\""), Key));
        Assert.Equal("user-1", vt.Subject);
        Assert.Contains("it-client", vt.Audience);
        Assert.Equal(Issuer, vt.Issuer);
        Assert.True(vt.ExpiresAt > vt.IssuedAt);
    }

    [Fact]
    public async Task Multi_aud_membership_passes()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var vt = await v.ValidateAsync(Sign(PayloadJson("[\"it-client\",\"realm-management\"]"), Key));
        Assert.Contains("it-client", vt.Audience);
    }

    [Fact]
    public async Task Aud_not_member_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"other-client\""), Key)));
    }

    [Fact]
    public async Task Wrong_issuer_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", iss: "https://evil.example.com/realms/x"), Key)));
    }

    [Fact]
    public async Task Expired_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" }, ClockSkewSeconds = 0 });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", expOffset: -300), Key)));
    }

    [Fact]
    public async Task Missing_exp_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var noExp = $$"""{"iss":"{{Issuer}}","sub":"u","aud":"it-client","iat":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}}}""";
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => v.ValidateAsync(Sign(noExp, Key)));
    }

    // Covers the false side of `IssuedAt = TryGetPayloadValue<long>("iat", ...) ? iat : null`
    // — a valid token that carries exp but omits iat.
    [Fact]
    public async Task Missing_iat_yields_null_issued_at()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var noIat = $$"""{"iss":"{{Issuer}}","sub":"u","aud":"it-client","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}}""";
        var vt = await v.ValidateAsync(Sign(noIat, Key));
        Assert.NotNull(vt.ExpiresAt);
        Assert.Null(vt.IssuedAt);
    }

    [Fact]
    public async Task Unsigned_none_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\""), key: null))); // alg none
    }

    [Fact]
    public async Task Algorithm_pin_violation_rejected()
    {
        // token signed RS256, but validator pins ES256 only
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" }, AllowedAlgorithms = new[] { "ES256" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\""), Key)));
    }

    // Covers the PRODUCTION ctor (ConfigurationManager/HttpDocumentRetriever wiring) + §6 TLS/JWKS regression guard.
    // ConfigurationManager is lazy, so construction performs NO network call (parity with Node's "forJwksUri constructs lazily").
    [Theory]
    [InlineData("https://kc.example.com/realms/it-realm")]
    [InlineData("http://localhost:8080/realms/it-realm")]
    public void Production_ctor_builds_without_network(string issuer)
    {
        using var http = new HttpClient();
        var opts = new JwtValidatorOptions { Issuer = issuer, Audiences = new[] { "it-client" }, RefreshIntervalSeconds = 15 };
        var validator = new JwtValidator(issuer, opts, http); // no exception, no network (lazy ConfigurationManager)
        Assert.NotNull(validator);
    }
}
