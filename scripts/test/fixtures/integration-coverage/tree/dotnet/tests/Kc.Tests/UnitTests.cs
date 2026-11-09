using Xunit;

namespace Kc.Tests;

// 통합 스위트 밖(Trait 없음) — `--filter "Category=Integration"` 이 거르지 않으면 이 클래스가 trx 에 실린다.
// 주석 속 특성은 특성이 아니다: [Trait("Category", "Integration")]
/* 블록 주석도 같다: [Trait("Category", "Integration")] */
public class UnitTests
{
    [Fact]
    public async Task Logout()
    {
        var auth = AuthClient.Build(new Config("http://kc", "demo"));
        await auth.LogoutAsync();
        Assert.Equal("auth+", auth.Describe(1));
    }
}
