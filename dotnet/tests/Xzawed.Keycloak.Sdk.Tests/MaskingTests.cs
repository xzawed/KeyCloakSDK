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

    // AuthorizationRequest is a positional record, so the compiler generates a ToString that
    // prints EVERY property — including the PKCE CodeVerifier, which is the one value that must
    // never reach a log. The sibling TokenSet in the same file masks; this type did not.
    // The verifier is the proof-of-possession secret for the code exchange: an attacker holding
    // a stolen authorization code plus a logged verifier completes the flow.
    [Fact]
    public void AuthorizationRequest_ToString_masks_code_verifier()
    {
        var req = new Xzawed.Keycloak.AuthorizationRequest(
            Url: "https://kc.example/auth?x=1",
            CodeVerifier: "SECRETverifier",
            State: "st4te",
            Nonce: "n0nce");

        var s = req.ToString();

        Assert.DoesNotContain("SECRETverifier", s);
        Assert.Contains("***", s);
        // 진단 가치는 남긴다 — URL 은 비밀이 아니다.
        Assert.Contains("https://kc.example/auth", s);
    }

    // 같은 계약의 두 번째 축. PHP 의 동일 결함이 정확히 이 경로였다(__toString 만 마스킹하고
    // json_encode 가 원문을 뱉었다). .NET 도 직렬화 경로를 따로 막지 않으면 같은 구멍이 남는다.
    [Fact]
    public void AuthorizationRequest_JsonSerialize_masks_code_verifier()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(
            new Xzawed.Keycloak.AuthorizationRequest(
                Url: "https://kc.example/auth?x=1",
                CodeVerifier: "SECRETverifier",
                State: "st4te",
                Nonce: "n0nce"));

        Assert.DoesNotContain("SECRETverifier", json);
    }
}
