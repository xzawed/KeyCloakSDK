using System.Linq;
using System.Net;
using System.Net.Http;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>Regression for SSRF redirect hardening on the shared SocketsHttpHandler factory.
/// Without a seam, AllowAutoRedirect=false was set inline in two places with zero tests
/// (commit 61f65f8 left this unfinished).</summary>
public class HttpTransportTests
{
    [Fact]
    public async Task CreateHandler_does_not_follow_redirects()
    {
        using var server = WireMockServer.Start();
        var targetUrl = $"{server.Url}/redirect-target";

        server.Given(Request.Create().WithPath("/start").UsingGet())
            .RespondWith(Response.Create()
                .WithStatusCode(302)
                .WithHeader("Location", targetUrl));
        server.Given(Request.Create().WithPath("/redirect-target").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithBody("followed"));

        var cfg = new KeycloakConfig
        {
            ServerUrl = "https://kc.example.com",
            Realm = "r",
            ClientId = "c",
        }.Normalized();

        using var http = new HttpClient(HttpTransport.CreateHandler(cfg));
        using var response = await http.GetAsync($"{server.Url}/start");

        Assert.Equal(HttpStatusCode.Redirect, response.StatusCode);
        Assert.DoesNotContain(server.LogEntries, e => e.RequestMessage?.Path == "/redirect-target");
    }

    [Fact]
    public void CreateHandler_pins_ssrf_and_pool_settings()
    {
        var cfg = new KeycloakConfig
        {
            ServerUrl = "https://kc.example.com",
            Realm = "r",
            ClientId = "c",
            ConnectTimeoutMs = 2500,
        }.Normalized();

        using var handler = HttpTransport.CreateHandler(cfg);

        Assert.False(handler.AllowAutoRedirect);
        Assert.Equal(TimeSpan.FromMilliseconds(cfg.ConnectTimeoutMs), handler.ConnectTimeout);
        Assert.Equal(TimeSpan.FromMinutes(5), handler.PooledConnectionLifetime);
    }
}
