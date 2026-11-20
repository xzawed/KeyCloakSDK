using DotNet.Testcontainers.Builders;
using Testcontainers.Keycloak;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests.Integration;

public sealed class KeycloakFixture : IAsyncLifetime
{
    public const string Realm = "it-realm";
    public const string ClientId = "it-client";
    public const string ClientSecret = "it-secret";

    // Testcontainers 4.17.0 이 (FileInfo, string) 오버로드를 폐기했다(CS0618 — 여기서는 경고가 오류다).
    // 아래 호출은 그 오버로드의 본문 그대로다: FilePath.Of(source.FullName) · DirectoryPath.Of(target).
    private readonly KeycloakContainer _container = new KeycloakBuilder("quay.io/keycloak/keycloak:26.6")
        .WithResourceMapping(FilePath.Of(Path.GetFullPath("testdata/it-realm-realm.json")), DirectoryPath.Of("/opt/keycloak/data/import/"))
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
