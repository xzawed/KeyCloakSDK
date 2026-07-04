using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class TokensTests
{
    [Fact]
    public void Create_maps_and_computes_absolute_expiry()
    {
        var ts = TokenSet.Create("AT", "Bearer", 300, "RT", "IDT", "openid", issuedAtSeconds: 1_000_000);
        Assert.Equal("AT", ts.AccessToken);
        Assert.Equal("Bearer", ts.TokenType);
        Assert.Equal(300, ts.ExpiresIn);
        Assert.Equal(1_000_300, ts.ExpiresAt);
        Assert.Equal("IDT", ts.IdToken);
        Assert.Equal("openid", ts.Scope);
    }

    [Fact]
    public void Create_defaults_and_unknown_expiry()
    {
        var ts = TokenSet.Create("AT", tokenType: null, expiresIn: 0, refreshToken: null, idToken: null, scope: null, issuedAtSeconds: 1);
        Assert.Equal("Bearer", ts.TokenType);
        Assert.Null(ts.ExpiresAt);
        Assert.Null(ts.RefreshToken);
    }

    [Fact]
    public void Create_rejects_missing_access_token()
        => Assert.Throws<KeycloakAuthException>(() => TokenSet.Create("", "Bearer", 60, null, null, null, 0));

    [Fact]
    public void IsExpired_respects_skew_and_unknown()
    {
        var ts = TokenSet.Create("AT", "Bearer", 300, null, null, null, 1_000_000); // expiresAt=1_000_300
        Assert.False(ts.IsExpired(1_000_000, 30));
        Assert.True(ts.IsExpired(1_000_280, 30)); // 1_000_280+30 >= 1_000_300
        Assert.True(TokenSet.Create("AT", "Bearer", 0, null, null, null, 0).IsExpired(0, 0)); // unknown => expired
    }

    [Fact]
    public void ToString_masks_access_and_refresh()
    {
        var s = TokenSet.Create("SECRETat", "Bearer", 60, "SECRETrt", null, null, 0).ToString();
        Assert.Contains("***", s);
        Assert.DoesNotContain("SECRETat", s);
        Assert.DoesNotContain("SECRETrt", s);
    }

    [Fact]
    public void JsonSerialize_masks_tokens()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(
            TokenSet.Create("SECRETat", "Bearer", 60, "SECRETrt", null, null, 0));
        Assert.Contains("***", json);
        Assert.DoesNotContain("SECRETat", json);
        Assert.DoesNotContain("SECRETrt", json);
    }
}
