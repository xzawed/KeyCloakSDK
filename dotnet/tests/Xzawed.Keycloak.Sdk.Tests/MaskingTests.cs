using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

public class MaskingTests
{
    [Theory]
    [InlineData("supersecret")]
    [InlineData("")]
    [InlineData(null)]
    public void Mask_is_always_opaque(string? input)
    {
        var masked = Xzawed.Keycloak.Masking.Mask(input);
        Assert.Equal("***", masked);
        Assert.DoesNotContain("secret", masked);
    }
}
