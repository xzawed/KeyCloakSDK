using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class OidcEndpointsTests
{
    [Fact]
    public void Assembles_all_endpoints()
    {
        var e = OidcEndpoints.For("https://kc.example.com/", "myrealm");
        Assert.Equal("https://kc.example.com/realms/myrealm", e.Issuer);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/token", e.Token);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/auth", e.Authorization);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/token/introspect", e.Introspection);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/logout", e.EndSession);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/certs", e.Jwks);
    }
}
