using System.Linq;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class ConfigTests
{
    static KeycloakConfig Base() => new() { ServerUrl = "https://kc.example.com", Realm = "r", ClientId = "c" };

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Normalized_rejects_blank_required(string blank)
    {
        Assert.Throws<KeycloakConfigException>(() => (Base() with { ServerUrl = blank }).Normalized());
        Assert.Throws<KeycloakConfigException>(() => (Base() with { Realm = blank }).Normalized());
        Assert.Throws<KeycloakConfigException>(() => (Base() with { ClientId = blank }).Normalized());
    }

    [Fact]
    public void Normalized_strips_trailing_slash_and_applies_defaults()
    {
        var c = (Base() with { ServerUrl = "https://kc.example.com/" }).Normalized();
        Assert.Equal("https://kc.example.com", c.ServerUrl);
        Assert.Equal(30, c.ClockSkewSeconds);
        Assert.Equal(10_000, c.ConnectTimeoutMs);
        Assert.Equal(30_000, c.ReadTimeoutMs);
        Assert.Empty(c.Scopes);
        Assert.Equal(new[] { "RS256" }, c.SignatureAlgorithms);
    }

    [Fact]
    public void SignatureAlgorithms_custom_values_are_preserved()
    {
        var c = (Base() with { SignatureAlgorithms = new[] { "ES256", "RS256" } }).Normalized();
        Assert.Equal(new[] { "ES256", "RS256" }, c.SignatureAlgorithms);
    }

    [Fact]
    public void Normalized_rejects_empty_signature_algorithms()
    {
        Assert.Throws<KeycloakConfigException>(
            () => (Base() with { SignatureAlgorithms = System.Array.Empty<string>() }).Normalized());
    }

    [Fact]
    public void ToString_masks_client_secret()
    {
        var c = Base() with { ClientSecret = "supersecret" };
        var s = c.ToString();
        Assert.Contains("***", s);
        Assert.DoesNotContain("supersecret", s);
        Assert.Equal("supersecret", c.ClientSecret); // property access returns real value
    }

    [Fact]
    public void ToString_without_secret_has_no_mask()
    {
        Assert.DoesNotContain("***", Base().ToString());
    }

    [Fact]
    public void JsonSerialize_masks_client_secret()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(Base() with { ClientSecret = "supersecret" });
        Assert.Contains("***", json);
        Assert.DoesNotContain("supersecret", json);
    }

    // Covers the converter's null-secret branch (WriteNull) — Base() has no ClientSecret.
    [Fact]
    public void JsonSerialize_null_secret_writes_null()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(Base());
        Assert.Contains("\"clientSecret\":null", json);
    }

    // Covers the converter's foreach body branch (non-empty Scopes) vs the empty-Scopes skip above.
    [Fact]
    public void JsonSerialize_writes_scopes()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(Base() with { Scopes = new[] { "openid", "profile" } });
        Assert.Contains("openid", json);
        Assert.Contains("profile", json);
    }
}
