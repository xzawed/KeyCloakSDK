using System.Threading.Tasks;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;
using Xzawed.Keycloak.Admin;
using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Sdk.Tests;

public class AdminClientTests : IDisposable
{
    private readonly WireMockServer _mock = WireMockServer.Start();

    private sealed class FixedToken : ITokenProvider
    {
        public Task<string> GetAccessTokenAsync(System.Threading.CancellationToken ct = default) => Task.FromResult("test-token");
    }

    private Task<AdminClient> BuildAsync()
    {
        var cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" }.Normalized();
        return AdminClient.CreateAsync(cfg, new FixedToken());
    }

    public void Dispose() => _mock.Stop();

    [Fact]
    public async Task Create_without_secret_throws_before_network()
    {
        var cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c" }.Normalized();
        await Assert.ThrowsAsync<KeycloakConfigException>(() => AdminClient.CreateAsync(cfg, new FixedToken()));
    }

    [Fact]
    public async Task Clients_create_parses_location_id()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/clients").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(201)
                 .WithHeader("Location", $"{_mock.Urls[0]}/admin/realms/r/clients/abc-123"));
        var id = await admin.Clients.CreateAsync(new ClientRepresentation { ClientId = "svc" });
        Assert.Equal("abc-123", id);
    }

    [Fact]
    public async Task Clients_get_404_maps_to_NotFound()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/clients/missing").UsingGet())
             .RespondWith(Response.Create().WithStatusCode(404));
        await Assert.ThrowsAsync<KeycloakNotFoundException>(() => admin.Clients.GetAsync("missing"));
    }

    [Fact]
    public async Task Bearer_token_attached_on_raw_calls()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/roles/app-admin").UsingGet()
                 .WithHeader("Authorization", "Bearer test-token"))
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { name = "app-admin" }));
        var role = await admin.Roles.GetAsync("app-admin");
        Assert.Equal("app-admin", role.Name);
    }

    [Fact]
    public async Task Timeout_maps_to_TransportException()
    {
        var cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s", ReadTimeoutMs = 200 }.Normalized();
        await using var admin = await AdminClient.CreateAsync(cfg, new FixedToken());
        _mock.Given(Request.Create().WithPath("/admin/realms/r/roles/slow").UsingGet())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { name = "slow" }).WithDelay(TimeSpan.FromMilliseconds(1500)));
        await Assert.ThrowsAsync<KeycloakTransportException>(() => admin.Roles.GetAsync("slow"));
    }
}
