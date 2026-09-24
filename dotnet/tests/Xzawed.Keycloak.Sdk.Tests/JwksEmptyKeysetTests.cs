using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// 200 + {"keys":[]} must not replace a JWKS configuration that already holds good keys (the
/// .NET half of #520).
/// </summary>
/// <remarks>
/// Measured 2026-09-24 before the fix: after the empty 200 the live configuration held 0 keys, and
/// the good k1 token still passed only because the handler fell back to the last-known-good
/// configuration — with LKG off it failed with IDX10500. LKG entries expire (1h by default), so the
/// fallback hides the poisoning rather than preventing it. ⚠️ That is why this test turns LKG off:
/// with LKG on, it passes whether or not the cache was overwritten.
/// </remarks>
public class JwksEmptyKeysetTests
{
    private const string JwksPath = "/realms/it-realm/protocol/openid-connect/certs";
    private static readonly RsaSecurityKey Key = new(RSA.Create(2048)) { KeyId = "k1" };

    [Fact]
    public async Task Empty_200_does_not_poison_good_cache()
    {
        using var server = WireMockServer.Start();
        var issuer = $"{server.Urls[0]}/realms/it-realm";
        var jwksBody = JwksKeySet(Key, "k1");
        server.Given(Request.Create().WithPath("/realms/it-realm/.well-known/openid-configuration").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody($$"""{"issuer":"{{issuer}}","jwks_uri":"{{issuer}}/protocol/openid-connect/certs"}"""));
        server.Given(Request.Create().WithPath(JwksPath).UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody(_ => jwksBody));

        using var http = new HttpClient();
        // 1s is the ConfigurationManager floor (IDX10107 rejects 0).
        var validator = new JwtValidator(issuer, new JwtValidatorOptions
        {
            Issuer = issuer,
            Audiences = new[] { "it-client" },
            RefreshIntervalSeconds = 1,
        }, http);
        var tvp = (TokenValidationParameters)typeof(JwtValidator)
            .GetField("_tvp", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(validator)!;
        tvp.ValidateWithLKG = false;
        tvp.ConfigurationManager!.UseLastKnownGoodConfiguration = false;

        var good = Sign(Payload(issuer, "user-1"), Key);
        Assert.Equal("user-1", (await validator.ValidateAsync(good)).Subject);
        var before = JwksHits(server);

        await Task.Delay(TimeSpan.FromMilliseconds(1100)); // let the refresh gate elapse
        jwksBody = """{"keys":[]}""";
        var unknown = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k2" };
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => validator.ValidateAsync(Sign(Payload(issuer, "user-1"), unknown)));
        await WaitForHitAsync(server, before);
        Assert.True(JwksHits(server) > before,
            "no refetch after the unknown kid — the empty set was never seen, so nothing is proven");
        await Task.Delay(300); // ConfigurationManager may apply the refresh off the request thread

        Assert.Equal("user-1", (await validator.ValidateAsync(good)).Subject);
        Assert.Equal("user-2", (await validator.ValidateAsync(Sign(Payload(issuer, "user-2"), Key))).Subject);
    }

    private static async Task WaitForHitAsync(WireMockServer server, int baseline)
    {
        var deadline = DateTime.UtcNow.AddSeconds(3);
        while (JwksHits(server) == baseline && DateTime.UtcNow < deadline)
            await Task.Delay(25);
    }

    private static int JwksHits(WireMockServer server)
        => server.LogEntries.Count(e => e.RequestMessage?.Path == JwksPath);

    private static string JwksKeySet(RsaSecurityKey key, string kid)
    {
        var p = key.Rsa!.ExportParameters(false);
        return $$"""{"keys":[{"kty":"RSA","kid":"{{kid}}","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}]}""";
    }

    private static string Payload(string issuer, string sub)
        => $$"""{"iss":"{{issuer}}","sub":"{{sub}}","aud":"it-client","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}}""";

    private static string Sign(string payloadJson, SecurityKey key)
        => new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }
            .CreateToken(payloadJson, new SigningCredentials(key, SecurityAlgorithms.RsaSha256));
}
