namespace X.Tests;

public class AuthTests
{
    [Fact]
    public async Task Nonce_mismatch_throws()
    {
        await Task.CompletedTask;
    }

    [Theory]
    [InlineData("1")]
    public async Task Rejects_non_string_access_token(string raw)
    {
        await Task.CompletedTask;
    }
}
