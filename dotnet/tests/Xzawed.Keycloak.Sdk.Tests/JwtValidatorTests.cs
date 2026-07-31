using System.Linq;
using System.Net.Http;
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

    // Wiring: KeycloakClient.Create feeds the validator through ValidatorOptionsFor, so both branches of
    // ExpectedAudience are exercised on the options the facade actually builds — not on a hand-made copy.
    private static KeycloakConfig ConfigWith(string? expectedAudience) => new()
    {
        ServerUrl = "https://kc.example.com",
        Realm = "it-realm",
        ClientId = "it-client",
        ExpectedAudience = expectedAudience,
    };

    [Fact]
    public async Task Expected_audience_unset_falls_back_to_client_id()
    {
        var v = ValidatorWith(KeycloakClient.ValidatorOptionsFor(ConfigWith(null), Issuer));
        var vt = await v.ValidateAsync(Sign(PayloadJson("\"it-client\""), Key));
        Assert.Contains("it-client", vt.Audience);
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"my-api\""), Key)));
    }

    [Fact]
    public async Task Expected_audience_replaces_client_id_when_set()
    {
        var v = ValidatorWith(KeycloakClient.ValidatorOptionsFor(ConfigWith("my-api"), Issuer));
        var vt = await v.ValidateAsync(Sign(PayloadJson("[\"my-api\",\"account\"]"), Key));
        Assert.Contains("my-api", vt.Audience);
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\""), Key)));
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

    // ── Pre-release audit follow-up: invariants that were implemented but never proven ──

    // Classic HS/RS confusion: the attacker forges an HS256 token using the PUBLIC key material as the
    // HMAC secret. If the validator trusted the header's alg to pick a key, "knows the public key" would
    // become "can mint tokens". The second assertion is the load-bearing one: even when HS256 is (wrongly)
    // allowed, the configured key material is RSA, so there is no symmetric key to verify against.
    [Fact]
    public async Task Hs256_forged_with_rsa_public_key_rejected()
    {
        var publicKeyBytes = Key.Rsa!.ExportSubjectPublicKeyInfo();
        var hmacKey = new SymmetricSecurityKey(publicKeyBytes);
        var handler = new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false };
        var forged = handler.CreateToken(
            PayloadJson("\"it-client\""),
            new SigningCredentials(hmacKey, SecurityAlgorithms.HmacSha256));

        var pinned = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => pinned.ValidateAsync(forged));

        var permissive = ValidatorWith(new JwtValidatorOptions
        {
            Issuer = Issuer,
            Audiences = new[] { "it-client" },
            AllowedAlgorithms = new[] { "RS256", "HS256" },
        });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => permissive.ValidateAsync(forged));
    }

    // A JWKS whose RSA modulus is not valid base64url must surface as the SDK's typed error, never as a raw
    // library/parse exception escaping the facade (§4 boundary contract).
    [Fact]
    public async Task Malformed_jwks_yields_typed_error_not_raw_exception()
    {
        using var server = WireMockServer.Start();
        var issuer = $"{server.Urls[0]}/realms/it-realm";
        StubDiscovery(server, issuer);
        server.Given(Request.Create().WithPath(JwksPath).UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody("""{"keys":[{"kty":"RSA","kid":"test-kid","use":"sig","alg":"RS256","n":"!!!not-base64!!!","e":"AQAB"}]}"""));

        using var http = new HttpClient();
        var v = new JwtValidator(issuer, new JwtValidatorOptions { Issuer = issuer, Audiences = new[] { "it-client" } }, http);

        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", iss: issuer), Key)));
    }

    // DoS-safe JWKS: forged tokens carrying unresolvable kids must not translate 1:1 into JWKS fetches.
    // ⚠️ The control group is what makes this non-vacuous. "Hits are fewer than tokens" would also hold for a
    // validator that simply never refreshes, so we contrast against a fresh validator per token — that path has
    // no shared cache/throttle state and therefore does fetch per token. The gap between the two numbers IS the
    // DoS bound. (RefreshInterval cannot be driven to zero as a control: ConfigurationManager rejects anything
    // below its 1s MinimumRefreshInterval, and a 1s interval inside a sub-second loop is indistinguishable
    // from a long one.)
    [Fact]
    public async Task Jwks_refetch_is_bounded_proven_by_hit_count()
    {
        using var server = WireMockServer.Start();
        var issuer = $"{server.Urls[0]}/realms/it-realm";
        StubDiscovery(server, issuer);
        server.Given(Request.Create().WithPath(JwksPath).UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody($$"""{"keys":[{{JwksKeyJson()}}]}"""));

        const int attempts = 6;
        var shared = await CountJwksHitsAsync(server, issuer, attempts, freshValidatorPerToken: false);
        var perToken = await CountJwksHitsAsync(server, issuer, attempts, freshValidatorPerToken: true);

        Assert.True(shared < attempts,
            $"one validator must not fetch JWKS once per forged token — attempts={attempts} hits={shared}");
        Assert.True(perToken > shared,
            $"control must fetch more often, else this test does not measure the bound — shared={shared} perToken={perToken}");
    }

    private const string JwksPath = "/realms/it-realm/protocol/openid-connect/certs";

    private static void StubDiscovery(WireMockServer server, string issuer)
        => server.Given(Request.Create().WithPath("/realms/it-realm/.well-known/openid-configuration").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody($$"""{"issuer":"{{issuer}}","jwks_uri":"{{issuer}}/protocol/openid-connect/certs"}"""));

    private static string JwksKeyJson()
    {
        var p = Key.Rsa!.ExportParameters(false);
        return $$"""{"kty":"RSA","kid":"served-kid","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}""";
    }

    // Feed `attempts` tokens whose kid cannot be resolved, and count how often JWKS was actually fetched.
    private static async Task<int> CountJwksHitsAsync(WireMockServer server, string issuer, int attempts, bool freshValidatorPerToken)
    {
        using var http = new HttpClient();
        JwtValidator NewValidator() => new(issuer, new JwtValidatorOptions
        {
            Issuer = issuer,
            Audiences = new[] { "it-client" },
        }, http);

        var shared = NewValidator();
        server.ResetLogEntries();
        for (var i = 0; i < attempts; i++)
        {
            var v = freshValidatorPerToken ? NewValidator() : shared;
            var forgedKey = new RsaSecurityKey(RSA.Create(2048)) { KeyId = $"forged-{i}" };
            await Assert.ThrowsAsync<KeycloakTokenValidationException>(
                () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", iss: issuer), forgedKey)));
        }
        return server.LogEntries.Count(e => e.RequestMessage?.Path == JwksPath);
    }
}
