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

    // `extra` is appended to the claims as written — `,"typ":"ID"`.
    private static string PayloadJson(string aud, long expOffset = 300, string iss = Issuer, string extra = "")
        => $$"""{"iss":"{{iss}}","sub":"user-1","aud":{{aud}},"exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expOffset}},"iat":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}}{{extra}}}""";

    // 경계 변환(등록부 boundary-exception-conversion-incomplete) — 공개 생성자는 issuer 문자열을 받고 디스커버리 주소를 그 뒤에
    // 붙인다. 쓸 수 없는 주소의 예외(UriFormatException · 상대 주소의 InvalidOperationException)는 첫 검증 때 나고, 검증 경계가
    // SDK 예외로 바꾼다(§4) — 그 변환을 고정한다(Kotlin · Node 는 같은 자리에서 샜다).
    [Theory]
    [InlineData("not a url")]
    [InlineData("relative/realms/r")]
    [InlineData("http://kc:99999/realms/r")]
    [InlineData("http://kc/a b/realms/r")]
    public async Task An_unusable_issuer_address_fails_validation_with_the_sdk_exception(string issuer)
    {
        using var http = new HttpClient();
        var v = new JwtValidator(issuer, new JwtValidatorOptions { Issuer = issuer, Audiences = new[] { "it-client" } }, http);
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", iss: issuer), Key)));
    }

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

    // IdentityModel wraps a JSON parse error under its own PII-hidden message today (MalformedTokenResponseTests a3/a4), so
    // the validator's own message never quotes input. This pins that it stays so if the failure it is handed is the raw
    // quoting exception itself — the seam is a validation delegate, which IdentityModel returns as result.Exception.
    [Fact]
    public async Task Validation_failure_that_quotes_input_is_not_copied_into_the_sdk_message()
    {
        const string canary = "LK-JWT-QUOTE-canary";
        var tvp = JwtValidator.BuildParameters(Issuer, new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        tvp.IssuerSigningKey = Key;
        tvp.ConfigurationManager = null;
        System.Text.Json.JsonException? quoting = null;
        try { System.Text.Json.JsonDocument.Parse($"t{canary}"); }
        catch (System.Text.Json.JsonException e) { quoting = e; }
        Assert.Contains(canary, quoting!.Message); // 대조군 — 진짜 파서 예외는 입력을 인용한다
        tvp.IssuerValidator = (_, _, _) => throw quoting;

        var ex = await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => new JwtValidator(tvp).ValidateAsync(Sign(PayloadJson("\"it-client\""), Key)));

        Assert.IsAssignableFrom<System.Text.Json.JsonException>(ex.InnerException); // 대조군 — 그 예외가 정말 넘어왔다
        Assert.DoesNotContain(canary, ex.Message);
        Assert.DoesNotContain(canary, ex.ToString());
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

    // The id_token path (ValidateForAudienceAsync) holds aud to the audience it is given and nothing else: an audience
    // policy on the base parameters — a delegate, or the check switched off — must not carry over through Clone().
    // IdentityModel consults AudienceValidator INSTEAD of ValidAudiences when one is set (Grok leg; measured here).
    [Theory]
    [InlineData("audience delegate that admits only the access audience")]
    [InlineData("audience check switched off")]
    public async Task Id_token_audience_ignores_the_base_audience_policy(string policy)
    {
        var tvp = JwtValidator.BuildParameters(Issuer, new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "my-api" } });
        tvp.IssuerSigningKey = Key;
        tvp.ConfigurationManager = null;
        if (policy.StartsWith("audience delegate", StringComparison.Ordinal))
            tvp.AudienceValidator = (audiences, _, _) => audiences.Contains("my-api");
        else
            tvp.ValidateAudience = false;
        var v = new JwtValidator(tvp);

        var forClient = await v.ValidateForAudienceAsync(Sign(PayloadJson("\"it-client\""), Key), "it-client");
        Assert.Contains("it-client", forClient.Audience);
        var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateForAudienceAsync(Sign(PayloadJson("\"my-api\""), Key), "it-client"));
        Assert.IsType<SecurityTokenInvalidAudienceException>(refused.InnerException);
    }

    // ── Token type — the access path only. Keycloak writes the kind of token into a payload `typ` claim
    // (org.keycloak.util.TokenUtil): "Bearer" or "DPoP" on an access token, "ID" on an id_token, "Refresh", "Offline",
    // "Logout" on a back-channel logout token, "Serialized-ID". All of them are signed by the realm key and can name this
    // client in aud, so ValidateAsync took an id_token or a logout token for an access token. ──

    [Theory]
    [InlineData("ID")]
    [InlineData("Refresh")]
    [InlineData("Offline")]
    [InlineData("Logout")]
    [InlineData("Serialized-ID")]
    public async Task Access_validation_refuses_a_token_typed_as_another_kind(string typ)
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", extra: $",\"typ\":\"{typ}\""), Key)));
        Assert.Equal($"not an access token (typ \"{typ}\")", refused.Message);
        Assert.Null(refused.InnerException);
    }

    // Everything else is left as it was: no typ, an access token's (Bearer · DPoP · RFC 9068 at+jwt), any other string —
    // the comparison is exact and case-sensitive — and a value that is not a string, even one that holds "ID".
    [Theory]
    [InlineData("")]
    [InlineData(",\"typ\":\"Bearer\"")]
    [InlineData(",\"typ\":\"DPoP\"")]
    [InlineData(",\"typ\":\"at+jwt\"")]
    [InlineData(",\"typ\":\"id\"")]
    [InlineData(",\"typ\":\"ID \"")]
    [InlineData(",\"typ\":\"Custom\"")]
    [InlineData(",\"typ\":42")]
    [InlineData(",\"typ\":true")]
    [InlineData(",\"typ\":null")]
    [InlineData(",\"typ\":[\"ID\"]")]
    [InlineData(",\"typ\":{\"typ\":\"ID\"}")]
    public async Task Access_validation_accepts_every_other_typ(string typClaim)
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var vt = await v.ValidateAsync(Sign(PayloadJson("\"it-client\"", extra: typClaim), Key));
        Assert.Equal("user-1", vt.Subject);
    }

    // An access token's azp is the client that asked for it — a resource server's tokens name other clients — so the
    // access path does not hold it to anything (the id_token path does, below).
    [Fact]
    public async Task Access_validation_does_not_check_azp()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var vt = await v.ValidateAsync(Sign(PayloadJson("[\"it-client\",\"account\"]", extra: ",\"azp\":\"frontend\""), Key));
        Assert.Equal("frontend", vt.Claims["azp"]);
    }

    // ── The id_token path (ValidateForAudienceAsync, the code exchange's): no token-type check — an id_token is typed
    // "ID" — and, after every other check, the authorized party (OIDC Core §3.1.3.7 steps 4–5): several audiences need an
    // azp, and an azp must be the client id. ──

    [Fact]
    public async Task Id_token_path_accepts_a_token_typed_ID()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var idToken = Sign(PayloadJson("\"it-client\"", extra: ",\"typ\":\"ID\",\"azp\":\"it-client\""), Key);
        Assert.Equal("ID", (await v.ValidateForAudienceAsync(idToken, "it-client")).Claims["typ"]);
        // Control: the same token is refused on the access path — by its type alone.
        var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => v.ValidateAsync(idToken));
        Assert.Equal("not an access token (typ \"ID\")", refused.Message);
    }

    [Theory]
    [InlineData("\"it-client\"", "")]
    [InlineData("[\"it-client\"]", "")]
    [InlineData("\"it-client\"", ",\"azp\":\"it-client\"")]
    [InlineData("[\"it-client\",\"account\"]", ",\"azp\":\"it-client\"")]
    public async Task Id_token_path_accepts_the_client_as_authorized_party(string aud, string azp)
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var vt = await v.ValidateForAudienceAsync(Sign(PayloadJson(aud, extra: azp), Key), "it-client");
        Assert.Contains("it-client", vt.Audience);
    }

    [Theory]
    [InlineData("\"it-client\"", ",\"azp\":\"someone-else\"", "azp does not match the client id")]
    [InlineData("\"it-client\"", ",\"azp\":\"It-Client\"", "azp does not match the client id")]
    [InlineData("\"it-client\"", ",\"azp\":null", "azp does not match the client id")]
    [InlineData("[\"it-client\",\"evil\"]", ",\"azp\":\"evil\"", "azp does not match the client id")]
    [InlineData("[\"it-client\",\"evil\"]", "", "azp is required when aud has more than one value")]
    public async Task Id_token_path_refuses_an_authorized_party_other_than_the_client(string aud, string azp, string reason)
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateForAudienceAsync(Sign(PayloadJson(aud, extra: azp), Key), "it-client"));
        Assert.Equal(reason, refused.Message);
        Assert.Null(refused.InnerException);
    }

    // IdentityModel reads azp as a string and refuses the token while reading it when it is another JSON type — on both
    // paths, before any check of the SDK's. Pinned so the id_token path cannot start accepting one.
    [Theory]
    [InlineData(",\"azp\":42")]
    [InlineData(",\"azp\":[\"it-client\"]")]
    public async Task Id_token_path_refuses_an_azp_that_is_not_a_string(string azp)
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var token = Sign(PayloadJson("\"it-client\"", extra: azp), Key);
        var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => v.ValidateForAudienceAsync(token, "it-client"));
        Assert.StartsWith("IDX14101:", refused.Message); // IdentityModel could not read the payload
        refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => v.ValidateAsync(token));
        Assert.StartsWith("IDX14101:", refused.Message); // the access path too — no SDK check is involved
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
    // allowed, the validator refuses an HS token before any key lookup (hs-refusal-rests-on-libraries); the
    // RSA key material would leave no symmetric key to verify against either.
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

    // ⚠️ DOCUMENTED DIVERGENCE — read before "fixing" this test to assert zero.
    //
    // Python/Go/Rust/Ruby/Java hold the stronger invariant "a forged signature never refetches the
    // JWKS". .NET does NOT, and cannot without abandoning ConfigurationManager: on a signature
    // failure Microsoft.IdentityModel calls RequestRefresh() and retries, because that is how it
    // recovers from key rotation. What bounds the damage is RefreshInterval (our default: 30s).
    //
    // So the honest invariant here is the BOUND, not zero: N forged tokens must not produce N
    // fetches. Measured at the time of writing: 6 forged tokens → exactly 1 extra fetch. Asserting
    // zero would be asserting something this SDK does not do; asserting "< N" is what actually
    // protects the IdP and what a regression would break.
    [Fact]
    public async Task Forged_signature_with_known_kid_refetch_is_rate_limited()
    {
        using var server = WireMockServer.Start();
        var issuer = $"{server.Urls[0]}/realms/it-realm";
        StubDiscovery(server, issuer);
        server.Given(Request.Create().WithPath(JwksPath).UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody($$"""{"keys":[{{JwksKeyJson("test-kid")}}]}"""));

        using var http = new HttpClient();
        var v = new JwtValidator(issuer, new JwtValidatorOptions { Issuer = issuer, Audiences = new[] { "it-client" } }, http);

        // Warm up with a genuine token so the JWKS is actually fetched once; without this the
        // "count did not grow" assertion would hold vacuously.
        var vt = await v.ValidateAsync(Sign(PayloadJson("\"it-client\"", iss: issuer), Key));
        Assert.Equal(issuer, vt.Issuer);
        var afterWarmup = server.LogEntries.Count(e => e.RequestMessage?.Path == JwksPath);
        Assert.True(afterWarmup > 0, "warm-up must have fetched the JWKS for this test to mean anything");

        var attacker = new RsaSecurityKey(RSA.Create(2048)) { KeyId = "test-kid" }; // same kid, different key
        const int forgedCount = 6;
        for (var i = 0; i < forgedCount; i++)
        {
            await Assert.ThrowsAsync<KeycloakTokenValidationException>(
                () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", iss: issuer), attacker)));
        }

        var refetches = server.LogEntries.Count(e => e.RequestMessage?.Path == JwksPath) - afterWarmup;
        Assert.True(refetches < forgedCount,
            $"forged signatures must not translate 1:1 into JWKS fetches — {forgedCount} tokens caused {refetches} refetches");
    }

    // ── The inbound length cap (JwtValidator.MaxJwtBytes): T1 pins its message and its place — first, before IdentityModel
    // reads the token and before discovery or the JWKS is loaded — T2 its bound (">", not ">="), T3 that genuine tokens up
    // to it still validate. ──

    // T1. The input is garbage a decoder refuses as malformed, so the cap's own message proves the length was looked at
    // first. The validator is the production one and cold, and its IdP log stays empty — also for a genuine token over the
    // cap: garbage fails before any fetch with or without the cap, so only a token that would validate shows the cap runs
    // before IdentityModel loads discovery and the JWKS (measured: with the check moved after the handler call and the
    // handler's own limit raised, the garbage half still passed and this half did not).
    [Fact]
    public async Task Token_over_the_cap_is_refused_before_decoding_and_before_any_request()
    {
        using var server = WireMockServer.Start();
        var issuer = $"{server.Urls[0]}/realms/it-realm";
        StubDiscovery(server, issuer);
        server.Given(Request.Create().WithPath(JwksPath).UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody($$"""{"keys":[{{JwksKeyJson("test-kid")}}]}"""));
        using var http = new HttpClient();
        var v = new JwtValidator(issuer, new JwtValidatorOptions { Issuer = issuer, Audiences = new[] { "it-client" } }, http);

        var over = new string('a', JwtValidator.MaxJwtBytes - 1) + "..";
        Assert.Equal(JwtValidator.MaxJwtBytes + 1, over.Length);
        var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => v.ValidateAsync(over));
        Assert.Contains("exceeds 256000 bytes", refused.Message);
        var genuineOver = SignPadded(JwtValidator.MaxJwtBytes + 9, issuer);
        Assert.InRange(genuineOver.Length, JwtValidator.MaxJwtBytes + 1, JwtValidator.MaxJwtBytes + 9);
        refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => v.ValidateAsync(genuineOver));
        Assert.Contains("exceeds 256000 bytes", refused.Message);
        Assert.Empty(server.LogEntries); // no discovery, no JWKS

        // Control: the same cold validator does reach the IdP for a token under the cap — the empty log above is the
        // cap's doing, not a validator that never fetches.
        var vt = await v.ValidateAsync(Sign(PayloadJson("\"it-client\"", iss: issuer), Key));
        Assert.Equal(issuer, vt.Issuer);
        Assert.NotEmpty(server.LogEntries);
    }

    // T2. The same garbage at exactly the cap passes the length check and is refused by the decoder instead.
    [Fact]
    public async Task Token_at_the_cap_is_left_to_the_decoder()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var at = new string('a', JwtValidator.MaxJwtBytes - 2) + "..";
        Assert.Equal(JwtValidator.MaxJwtBytes, at.Length);
        var refused = await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => v.ValidateAsync(at));
        Assert.DoesNotContain("exceeds", refused.Message);
    }

    // T3. A genuine token just under the cap validates, and so does one as long as the longest bearer Keycloak 26.6
    // accepts with default settings (65,459 bytes).
    [Theory]
    [InlineData(JwtValidator.MaxJwtBytes)]
    [InlineData(65459)]
    public async Task Genuine_token_up_to_the_cap_validates(int target)
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var token = SignPadded(target);
        Assert.InRange(token.Length, target - 8, target);
        var vt = await v.ValidateAsync(token);
        Assert.Equal("user-1", vt.Subject);
    }

    // A genuine token (Key, valid claims) whose extra "pad" claim makes it between target-8 and target characters long.
    private static string SignPadded(int target, string iss = Issuer)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        for (var pad = 0; ;)
        {
            var token = Sign($$"""{"iss":"{{iss}}","sub":"user-1","aud":"it-client","exp":{{now + 300}},"iat":{{now}},"pad":"{{new string('x', pad)}}"}""", Key);
            if (token.Length > target)
                pad--; // one payload byte is one or two base64url characters, so this cannot step past the window
            else if (token.Length < target - 8)
                pad += (target - token.Length) * 3 / 4; // base64url: four characters per three payload bytes
            else
                return token;
        }
    }

    private const string JwksPath = "/realms/it-realm/protocol/openid-connect/certs";

    private static void StubDiscovery(WireMockServer server, string issuer)
        => server.Given(Request.Create().WithPath("/realms/it-realm/.well-known/openid-configuration").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                .WithBody($$"""{"issuer":"{{issuer}}","jwks_uri":"{{issuer}}/protocol/openid-connect/certs"}"""));

    private static string JwksKeyJson(string kid = "served-kid")
    {
        var p = Key.Rsa!.ExportParameters(false);
        return $$"""{"kty":"RSA","kid":"{{kid}}","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}""";
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
