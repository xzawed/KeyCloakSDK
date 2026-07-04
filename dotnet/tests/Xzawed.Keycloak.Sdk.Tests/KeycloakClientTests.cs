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
}
