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
/// does not resolve the oct key for the token (IDX10503 "kid … did not match any keys"). Since hs-refusal-rests-on-libraries the
/// validator refuses an HS token before loading any key, so these cells stop there and no longer rest on IdentityModel's key
/// resolution. The same three shapes are measured in all nine languages.
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
    /// Pinned — with HS allowed, the classic RS→HS confusion (the RSA public key bytes as the HMAC secret) is still refused —
    /// now by the validator's HS refusal before any key lookup (hs-refusal-rests-on-libraries), so no library update reaches it.
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

    /// <summary>
    /// An HS (symmetric) signature is refused before any key lookup, even when the configuration allows it — pinned (registry
    /// hs-refusal-rests-on-libraries).
    /// </summary>
    /// <remarks>
    /// Verification keys come only from the JWKS, a public document, so the only thing an HMAC secret could be is a published
    /// value. The refusal must not rest on the key store dropping oct keys plus IdentityModel's key/algorithm binding: no request
    /// reaching the fake IdP (no discovery, no JWKS) is the evidence that it comes first. The kid names the RSA key in the set.
    /// The id_token path of a code exchange (<c>ValidateForAudienceAsync</c>) refuses the same way.
    /// </remarks>
    [Theory]
    [InlineData(SecurityAlgorithms.HmacSha256)]
    [InlineData(SecurityAlgorithms.HmacSha384)]
    [InlineData(SecurityAlgorithms.HmacSha512)]
    public async Task Hs_signature_is_refused_before_any_key_lookup_even_when_allowed(string alg)
    {
        var rsa = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        using var server = Idp(out var issuer, $$"""{"keys":[{{RsaJwk(rsa)}}]}""");
        using var http = new HttpClient();
        var validator = new JwtValidator(issuer, new JwtValidatorOptions
        {
            Issuer = issuer,
            Audiences = new[] { "it-client" },
            AllowedAlgorithms = new[] { "RS256", alg },
            RefreshIntervalSeconds = 1,
        }, http);
        var forged = Sign(Payload(issuer, "attacker"), new SymmetricSecurityKey(RandomNumberGenerator.GetBytes(64)) { KeyId = "k1" }, alg);

        foreach (var path in new Func<Task>[]
        {
            () => validator.ValidateAsync(forged),
            () => validator.ValidateForAudienceAsync(forged, "it-client"),
        })
        {
            var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(path);
            var requests = server.LogEntries.Select(e => e.RequestMessage?.Path).ToArray();
            Assert.Multiple(
                () => Assert.Equal($"algorithm not allowed: {alg} (a JWKS holds public keys only)", refused.Message),
                () => Assert.Null(refused.InnerException),
                () => Assert.Empty(requests));
        }
        // Control — the RSA token verifies with the same validator, and the IdP saw that (the zero above is not a dead counter's).
        Assert.Equal("user-1", (await validator.ValidateAsync(Sign(Payload(issuer, "user-1"), rsa, SecurityAlgorithms.RsaSha256))).Subject);
        Assert.NotEmpty(server.LogEntries);
    }

    /// <summary>
    /// An empty or null <c>ValidAlgorithms</c> pins nothing in IdentityModel (measured on 8.23.0) — every algorithm passes it, so an
    /// HS one is refused there as well, before any key lookup.
    /// </summary>
    [Fact]
    public async Task Hs_signature_is_refused_when_the_pin_is_empty_or_null()
    {
        var rsa = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        using var server = Idp(out var issuer, $$"""{"keys":[{{RsaJwk(rsa)}}]}""");
        using var http = new HttpClient();
        var opts = new JwtValidatorOptions { Issuer = issuer, Audiences = new[] { "it-client" }, AllowedAlgorithms = Array.Empty<string>() };
        var noPin = JwtValidator.BuildParameters(issuer, opts);
        noPin.ValidAlgorithms = null;
        noPin.IssuerSigningKey = rsa;
        var forged = Sign(Payload(issuer, "attacker"), new SymmetricSecurityKey(RandomNumberGenerator.GetBytes(32)) { KeyId = "k1" }, SecurityAlgorithms.HmacSha256);

        foreach (var validator in new[] { new JwtValidator(issuer, opts, http), new JwtValidator(noPin) })
        {
            var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => validator.ValidateAsync(forged));
            Assert.Equal("algorithm not allowed: HS256 (a JWKS holds public keys only)", refused.Message);
        }
        Assert.Empty(server.LogEntries.Select(e => e.RequestMessage?.Path));
    }

    /// <summary>A set holding only an oct key has no usable key — refused like an empty set, never installed.</summary>
    [Fact]
    public async Task Only_an_oct_key_has_no_usable_keys()
    {
        var rsa = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        using var server = Idp(out var issuer, """{"keys":[{"kty":"oct","kid":"k1","k":"c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0"}]}""");
        using var http = new HttpClient();
        var validator = HsAllowed(issuer, http);

        var refused = await Record.ExceptionAsync(
            () => validator.ValidateAsync(Sign(Payload(issuer, "user-1"), rsa, SecurityAlgorithms.RsaSha256)));
        Assert.IsAssignableFrom<KeycloakException>(refused);
    }

    /// <summary>
    /// The SDK drops oct keys where every fetch passes (<c>BackoffConfigurationRetriever</c>), so the refusal does not rest on
    /// IdentityModel's process-wide <see cref="JsonWebKeySet.DefaultSkipUnresolvedJsonWebKeys"/> (see the class below).
    /// </summary>
    [Fact]
    public void DropSymmetricKeys_leaves_only_the_asymmetric_keys()
    {
        var rsa = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
        var config = new Microsoft.IdentityModel.Protocols.OpenIdConnect.OpenIdConnectConfiguration
        {
            JsonWebKeySet = new JsonWebKeySet($$"""{"keys":[{"kty":"oct","kid":"hk","k":"c2VjcmV0LXNlY3JldA"},{{RsaJwk(rsa)}}]}"""),
        };
        config.SigningKeys.Add(new SymmetricSecurityKey(new byte[32]) { KeyId = "hk" });
        config.SigningKeys.Add(new JsonWebKey("""{"kty":"oct","kid":"hk2","k":"c2VjcmV0LXNlY3JldA"}"""));
        config.SigningKeys.Add(rsa);

        BackoffConfigurationRetriever.DropSymmetricKeys(config);

        Assert.Equal(new[] { "k1" }, config.JsonWebKeySet.Keys.Select(k => k.Kid));
        Assert.Equal(new[] { "k1" }, config.SigningKeys.Select(k => k.KeyId));
    }

    internal static WireMockServer Idp(out string issuer, string jwks)
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

    internal static JwtValidator HsAllowed(string issuer, HttpClient http) => new(issuer, new JwtValidatorOptions
    {
        Issuer = issuer,
        Audiences = new[] { "it-client" },
        AllowedAlgorithms = new[] { "RS256", "HS256" },
        RefreshIntervalSeconds = 1,
    }, http);

    internal static string RsaJwk(RsaSecurityKey key)
    {
        var p = key.Rsa!.ExportParameters(false);
        return $$"""{"kty":"RSA","kid":"{{key.KeyId}}","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}""";
    }

    internal static string Payload(string issuer, string sub)
        => $$"""{"iss":"{{issuer}}","sub":"{{sub}}","aud":"it-client","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}}""";

    internal static string Sign(string payloadJson, SecurityKey key, string algorithm)
        => new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }
            .CreateToken(payloadJson, new SigningCredentials(key, algorithm));
}

/// <summary>Runs alone — it flips a process-wide IdentityModel static.</summary>
[CollectionDefinition(nameof(GlobalJwksFlagCollection), DisableParallelization = true)]
public class GlobalJwksFlagCollection
{
}

/// <summary>
/// With <see cref="JsonWebKeySet.DefaultSkipUnresolvedJsonWebKeys"/> false — a process-wide static a host application can
/// set — IdentityModel hands the oct key to signature validation, and a token HMAC-signed with the published key verified
/// (measured on the fake IdP: all three shapes). The SDK must refuse it whatever the host set.
/// </summary>
[Collection(nameof(GlobalJwksFlagCollection))]
public class JwksOctKeyGlobalFlagTests
{
    [Fact]
    public async Task Oct_key_is_refused_even_when_the_host_turns_off_skipping_unresolved_keys()
    {
        var saved = JsonWebKeySet.DefaultSkipUnresolvedJsonWebKeys;
        JsonWebKeySet.DefaultSkipUnresolvedJsonWebKeys = false;
        try
        {
            var secret = RandomNumberGenerator.GetBytes(32);
            var rsa = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "k1" };
            var oct = $$"""{"kty":"oct","kid":"hk","alg":"HS256","use":"sig","k":"{{Base64UrlEncoder.Encode(secret)}}"}""";
            using var server = JwksOctKeyTests.Idp(out var issuer, $$"""{"keys":[{{oct}},{{JwksOctKeyTests.RsaJwk(rsa)}}]}""");
            using var http = new HttpClient();
            var validator = JwksOctKeyTests.HsAllowed(issuer, http);

            var forged = JwksOctKeyTests.Sign(JwksOctKeyTests.Payload(issuer, "attacker"),
                new SymmetricSecurityKey(secret) { KeyId = "hk" }, SecurityAlgorithms.HmacSha256);
            await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => validator.ValidateAsync(forged));
            Assert.Equal("user-1", (await validator.ValidateAsync(JwksOctKeyTests.Sign(
                JwksOctKeyTests.Payload(issuer, "user-1"), rsa, SecurityAlgorithms.RsaSha256))).Subject);
        }
        finally
        {
            JsonWebKeySet.DefaultSkipUnresolvedJsonWebKeys = saved;
        }
    }
}
