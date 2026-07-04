using System.Linq;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
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
}
