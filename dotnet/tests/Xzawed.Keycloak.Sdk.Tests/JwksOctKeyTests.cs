using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// A JWKS symmetric (<c>oct</c>) key is never a verification key — pinned (registry jwks-oct-key-usable-with-hs).
/// </summary>
/// <remarks>
/// The JWKS is a public document, so a symmetric key in it is no secret: with HS256 allowed, seven of the nine SDKs accepted a
/// token HMAC-signed with it (measured; the nine-language table is in the PR body). .NET already refused — Microsoft.IdentityModel
/// does not resolve the oct key for the token (IDX10503 "kid … did not match any keys"). No code change here: these pin that
/// behaviour, so a library update that flips it fails this class. The same three shapes are measured in all nine languages.
/// </remarks>
public class JwksOctKeyTests
{
    private const string Realm = "/realms/it-realm";

    public static TheoryData<string, string, string?> OctShapes => new()
    {
        { "kid-alg", "\"kid\":\"hk\",\"alg\":\"HS256\",\"use\":\"sig\"", "hk" },
        { "no-alg", "\"kid\":\"hk\"", "hk" },
        { "no-kid", "\"alg\":\"HS256\",\"use\":\"sig\"", null },
    };

    [Theory]
    [MemberData(nameof(OctShapes))]
    public async Task Oct_key_is_never_a_verification_key(string name, string members, string? kid)
    {
        var secret = RandomNumberGenerator.GetBytes(32);
        var rsa = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        var oct = $$"""{"kty":"oct","k":"{{Base64UrlEncoder.Encode(secret)}}",{{members}}}""";
        using var server = Idp(out var issuer, $$"""{"keys":[{{oct}},{{RsaJwk(rsa)}}]}""");
        using var http = new HttpClient();
        var validator = HsAllowed(issuer, http);

        var forged = Sign(Payload(issuer, "attacker"), new SymmetricSecurityKey(secret) { KeyId = kid }, SecurityAlgorithms.HmacSha256);
        var refused = await Record.ExceptionAsync(() => validator.ValidateAsync(forged));
        Assert.True(refused is KeycloakTokenValidationException, $"{name}: a token signed with the JWKS oct key was not refused ({refused})");
        // Control — the RSA key in the same set still verifies (dropping oct does not drop the set).
        Assert.Equal("user-1", (await validator.ValidateAsync(Sign(Payload(issuer, "user-1"), rsa, SecurityAlgorithms.RsaSha256))).Subject);
    }

    /// <summary>
    /// Pinned — with HS allowed, the classic RS→HS confusion (the RSA public key bytes as the HMAC secret) is still refused.
    /// "Dropping oct is enough" rests on this, so a library update that changes it fails here.
    /// </summary>
    [Fact]
    public async Task Rsa_public_key_bytes_as_hmac_secret_are_rejected_even_with_hs_allowed()
    {
        var rsa = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        using var server = Idp(out var issuer, $$"""{"keys":[{{RsaJwk(rsa)}}]}""");
        using var http = new HttpClient();
        var validator = HsAllowed(issuer, http);

        foreach (var secret in new[]
        {
            rsa.Rsa!.ExportSubjectPublicKeyInfo(),
            Encoding.ASCII.GetBytes(rsa.Rsa.ExportSubjectPublicKeyInfoPem()),
        })
        {
            var forged = Sign(Payload(issuer, "attacker"), new SymmetricSecurityKey(secret) { KeyId = "k1" }, SecurityAlgorithms.HmacSha256);
            await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => validator.ValidateAsync(forged));
        }
    }

    private static WireMockServer Idp(out string issuer, string jwks)
    {
        var server = WireMockServer.Start();
        issuer = $"{server.Urls[0]}{Realm}";
        server.Given(Request.Create().WithPath($"{Realm}/.well-known/openid-configuration").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody($$"""{"issuer":"{{issuer}}","jwks_uri":"{{issuer}}/protocol/openid-connect/certs"}"""));
        server.Given(Request.Create().WithPath($"{Realm}/protocol/openid-connect/certs").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json").WithBody(jwks));
        return server;
    }

    private static JwtValidator HsAllowed(string issuer, HttpClient http) => new(issuer, new JwtValidatorOptions
    {
        Issuer = issuer,
        Audiences = new[] { "it-client" },
        AllowedAlgorithms = new[] { "RS256", "HS256" },
        RefreshIntervalSeconds = 1,
    }, http);

    private static string RsaJwk(RsaSecurityKey key)
    {
        var p = key.Rsa!.ExportParameters(false);
        return $$"""{"kty":"RSA","kid":"{{key.KeyId}}","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}""";
    }

    private static string Payload(string issuer, string sub)
        => $$"""{"iss":"{{issuer}}","sub":"{{sub}}","aud":"it-client","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}}""";

    private static string Sign(string payloadJson, SecurityKey key, string algorithm)
        => new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }
            .CreateToken(payloadJson, new SigningCredentials(key, algorithm));
}
