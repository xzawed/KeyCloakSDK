using Xunit;

namespace Kc.Tests.Integration;

// The integration suite — the unit run's filter (Category!=Integration) leaves it out, so LogoutUrl stays unreached in the unit
// data. A unit run whose results hold this class is not unit-only (integrity failure).
[Trait("Category", "Integration")]
public sealed class DriveIT
{
    [Fact]
    public void Logout() => Assert.StartsWith("https://kc/logout", new AuthClient(new Config("http://kc", "demo")).LogoutUrl("x"));
}
