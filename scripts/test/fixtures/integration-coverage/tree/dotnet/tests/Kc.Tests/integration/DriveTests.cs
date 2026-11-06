using Kc.Admin;
using Xunit;

namespace Kc.Tests.Integration;

// 구동기 — 두 번째 생성자 · Describe(int) · LogoutAsync · Build · Unused · Later · Lower · NamesAsync · Retries 의 setter · Close ·
// Dispose · Defaults · DeleteAsync 는 일부러 안 부르고 TokenAsync 의 빈 code 갈래를 안 탄다. 특성과 클래스 사이에 다른 특성 ·
// 한정자가 온다(스위트 판정은 그 사이를 건넌다).
[Trait("Category", "Integration")]
[Collection("kc")]
public sealed class DriveTests
{
    [Fact]
    public async Task Drive()
    {
        var auth = new AuthClient(new Config("http://kc", "demo"));
        Assert.Equal("http://kc/realms/demo", auth.Issuer);
        Assert.Equal(3, auth.Retries);
        Assert.Equal("demo:abc", await auth.TokenAsync("abc"));
        Assert.Equal(2, auth.Upper().Length);
        Assert.Equal("demoopenid-demoprofile", auth.Joined("-"));
        Assert.Equal(["xopenid", "xprofile"], auth.Prefixed(" x "));
        Assert.Equal(5, auth.Count(2));
        Assert.Equal("auth", auth.Describe());
        Assert.Equal(3, auth.Items().Sum());
        Assert.Equal(2, await auth.SumAsync());
        Assert.Equal(7, await auth.EchoAsync(7));

        var admin = new Client();
        Assert.Equal("u1", await admin.Users.GetAsync("u1"));
    }
}
