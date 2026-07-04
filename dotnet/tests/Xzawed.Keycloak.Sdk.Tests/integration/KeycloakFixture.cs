using Testcontainers.Keycloak;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests.Integration;

public sealed class KeycloakFixture : IAsyncLifetime
{
    public const string Realm = "it-realm";
    public const string ClientId = "it-client";
    public const string ClientSecret = "it-secret";

    private readonly KeycloakContainer _container = new KeycloakBuilder("quay.io/keycloak/keycloak:26.6")
        .WithResourceMapping(new FileInfo("testdata/it-realm-realm.json"), "/opt/keycloak/data/import/")
        .WithCommand("--import-realm")
        .Build();

    public string BaseUrl { get; private set; } = string.Empty;

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        BaseUrl = _container.GetBaseAddress().TrimEnd('/'); // strip trailing slash for KeycloakConfig
    }

    public async Task DisposeAsync() => await _container.DisposeAsync();
}

[CollectionDefinition("keycloak")]
public sealed class KeycloakCollection : ICollectionFixture<KeycloakFixture> { }
