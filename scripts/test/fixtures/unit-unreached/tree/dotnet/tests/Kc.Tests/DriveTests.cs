using Xunit;

namespace Kc.Tests;

// The unit drive (no Category trait — the unit run's filter keeps it): never an empty code (Exchange · TokenAsync), never a null for
// Pick, never an empty string through Lengths' lambda, never the exception Guarded's filter takes, never Describe() or LogoutUrl, and
// Describe(int) with a positive depth only.
public sealed class DriveTests
{
    [Fact]
    public async Task Drive()
    {
        var auth = new AuthClient(new Config("http://kc", "demo"));
        Assert.Equal("demo:2", auth.Realm);
        Assert.Equal("ABC", auth.Exchange("abc"));
        Assert.Equal("x", auth.Pick("x"));
        Assert.Equal(new[] { 1, 2 }, auth.Lengths(new[] { "a", "bb" }));
        Assert.Equal("demo:abc", await auth.TokenAsync("abc"));
        Assert.Equal("ok", auth.Guarded(() => "ok"));
        Assert.Throws<InvalidOperationException>(() => auth.Guarded(() => throw new InvalidOperationException("no inner")));
        Assert.Equal("auth+", auth.Describe(1));
        Assert.True(new Config("http://kc", "demo").Valid());
    }
}
