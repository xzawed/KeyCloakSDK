using System.Linq;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class KeycloakClientTests
{
    [Fact]
    public void Create_validates_and_builds_auth_eagerly()
    {
        var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = "https://kc.example.com/", Realm = "r", ClientId = "c" });
        Assert.NotNull(kc.Auth);
    }

    [Fact]
    public void Create_rejects_missing_required()
        => Assert.Throws<KeycloakConfigException>(
            () => KeycloakClient.Create(new KeycloakConfig { ServerUrl = "", Realm = "r", ClientId = "c" }));

    [Fact]
    public async Task AdminAsync_without_secret_throws_config()
    {
        await using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = "https://kc.example.com", Realm = "r", ClientId = "c" });
        await Assert.ThrowsAsync<KeycloakConfigException>(() => kc.AdminAsync());
    }

    [Fact]
    public void AddKeycloak_registers_singleton_client()
    {
        var services = new ServiceCollection();
        services.AddKeycloak(new KeycloakConfig { ServerUrl = "https://kc.example.com", Realm = "r", ClientId = "c" });
        using var sp = services.BuildServiceProvider();
        var kc = sp.GetRequiredService<KeycloakClient>();
        Assert.NotNull(kc.Auth);
        Assert.Same(kc, sp.GetRequiredService<KeycloakClient>()); // singleton
    }

    [Fact]
    public async Task AdminAsync_single_flight_and_caches()
    {
        using var mock = WireMock.Server.WireMockServer.Start();
        mock.Given(WireMock.RequestBuilders.Request.Create()
                .WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
            .RespondWith(WireMock.ResponseBuilders.Response.Create().WithStatusCode(200)
                .WithHeader("Content-Type", "application/json")
                .WithBodyAsJson(new { access_token = "AT", token_type = "Bearer", expires_in = 300 })
                .WithDelay(TimeSpan.FromMilliseconds(50)));
        await using var kc = KeycloakClient.Create(new KeycloakConfig
        { ServerUrl = mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" });

        var admins = await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => kc.AdminAsync()));

        Assert.All(admins, a => Assert.Same(admins[0], a));
        var tokenReqs = mock.LogEntries.Count(e => e.RequestMessage?.Path == "/realms/r/protocol/openid-connect/token");
        Assert.Equal(1, tokenReqs);
    }

    /// <summary>Once built, the facade is handed back before the build gate, with no request — a call whose token is already
    /// cancelled still gets it, and the token endpoint saw only the build. Control: on a client not built yet the same call
    /// stops at that gate (its wait refuses the cancelled token), so the call above never reached it.</summary>
    [Fact]
    public async Task AdminAsync_hands_back_the_built_facade_without_the_gate_or_a_request()
    {
        using var mock = WireMock.Server.WireMockServer.Start();
        mock.Given(WireMock.RequestBuilders.Request.Create()
                .WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
            .RespondWith(WireMock.ResponseBuilders.Response.Create().WithStatusCode(200)
                .WithHeader("Content-Type", "application/json")
                .WithBodyAsJson(new { access_token = "AT", token_type = "Bearer", expires_in = 300 }));
        var config = new KeycloakConfig { ServerUrl = mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" };
        int TokenRequests() => mock.LogEntries.Count(e => e.RequestMessage?.Path == "/realms/r/protocol/openid-connect/token");
        var cancelled = new CancellationToken(canceled: true);

        await using var kc = KeycloakClient.Create(config);
        var built = await kc.AdminAsync();
        Assert.Same(built, await kc.AdminAsync(cancelled));
        Assert.Equal(1, TokenRequests());

        await using var cold = KeycloakClient.Create(config);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cold.AdminAsync(cancelled));
        Assert.Equal(1, TokenRequests());
    }

    // ── A success status whose body carries an OAuth error (registry auth-2xx-error-code-divergent): the admin facade's own
    // grant fails with that error, no admin request goes out — with B2's token or any — and nothing is cached: once the
    // endpoint answers properly, the next build asks it again and the admin request carries the new token. ──

    private const string TokenPath = "/realms/r/protocol/openid-connect/token";
    private const string UserPath = "/admin/realms/r/users/u1";
    private const string TokenB1 = """{"error":"invalid_grant","error_description":"d"}""";
    private const string TokenB2 = """{"error":"invalid_grant","access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl","token_type":"Bearer","expires_in":300}""";
    private const string NextAccessToken = "next-access-token";

    [Theory]
    [InlineData(TokenB1)]
    [InlineData(TokenB2)]
    public async Task AdminAsync_SuccessStatusOAuthError_fails_and_sends_no_admin_request(string body)
    {
        using var idp = WireMockServer.Start();
        Answer(idp, body);
        await using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "zebrasecretjk" });

        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(async () => await (await kc.AdminAsync()).Users.GetAsync("u1"));
        Assert.Equal("invalid_grant", refused.OAuthError);
        Assert.Equal("Client credentials grant failed: invalid_grant", refused.Message);
        Assert.DoesNotContain(idp.LogEntries, e => e.RequestMessage?.Path?.StartsWith("/admin/", StringComparison.Ordinal) == true);

        Answer(idp, $$"""{"access_token":"{{NextAccessToken}}","token_type":"Bearer","expires_in":300}""");
        var user = await (await kc.AdminAsync()).Users.GetAsync("u1");
        Assert.Equal("alice", user.Username);
        var sent = Assert.Single(idp.LogEntries, e => e.RequestMessage?.Path?.StartsWith("/admin/", StringComparison.Ordinal) == true);
        Assert.Equal($"Bearer {NextAccessToken}", Assert.Single(sent.RequestMessage!.Headers!["Authorization"]));
        Assert.Equal(2, idp.LogEntries.Count(e => e.RequestMessage?.Path == TokenPath));
    }

    /// <summary>The token endpoint answers 200 with <paramref name="tokenBody"/>, the user read answers with a user; whatever
    /// they answered before is gone.</summary>
    private static void Answer(WireMockServer idp, string tokenBody)
    {
        idp.ResetMappings();
        idp.Given(Request.Create().WithPath(TokenPath).UsingPost())
           .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json").WithBody(tokenBody));
        idp.Given(Request.Create().WithPath(UserPath).UsingGet())
           .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
               .WithBody("""{"id":"u1","username":"alice"}"""));
    }
}
