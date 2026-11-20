using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class TokenProviderTests
{
    sealed class CountingSource : ITokenSource
    {
        public int Calls;
        public long ExpiresIn = 300;
        public int DelayMs = 20;   // hold the flight so concurrent callers pile up on the gate
        public string? FixedToken; // when set, every fetch returns this exact access token
        private int _n;
        public async Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default)
        {
            Interlocked.Increment(ref Calls);
            if (DelayMs > 0) await Task.Delay(DelayMs, ct).ConfigureAwait(false);
            var tok = FixedToken ?? $"tok-{Interlocked.Increment(ref _n)}";
            return TokenSet.Create(tok, "Bearer", ExpiresIn, null, null, null, 0);
        }
    }

    [Fact]
    public async Task Caches_before_expiry_source_called_once()
    {
        var src = new CountingSource();
        var p = new ClientCredentialsTokenProvider(src, skewSeconds: 0);
        var a = await p.GetAccessTokenAsync();
        var b = await p.GetAccessTokenAsync();
        Assert.Equal(a, b);
        Assert.Equal(1, src.Calls);
    }

    [Fact]
    public async Task Concurrent_calls_single_flight()
    {
        var src = new CountingSource();
        var p = new ClientCredentialsTokenProvider(src, skewSeconds: 0);
        var results = await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => p.GetAccessTokenAsync()));
        Assert.All(results, r => Assert.Equal(results[0], r));
        Assert.Equal(1, src.Calls);
    }

    [Fact]
    public async Task Expired_token_refetched()
    {
        var src = new CountingSource { ExpiresIn = 0 };
        var p = new ClientCredentialsTokenProvider(src, skewSeconds: 0);
        var a = await p.GetAccessTokenAsync();
        var b = await p.GetAccessTokenAsync();
        Assert.NotEqual(a, b);
        Assert.Equal(2, src.Calls);
    }

    // Covers the non-null side of `clock ?? TimeProvider.System` (ctor injects the caller's clock).
    [Fact]
    public async Task Explicit_clock_injected_and_used()
    {
        var src = new CountingSource();
        var p = new ClientCredentialsTokenProvider(src, skewSeconds: 0, clock: TimeProvider.System);
        var a = await p.GetAccessTokenAsync();
        var b = await p.GetAccessTokenAsync();
        Assert.Equal(a, b);
        Assert.Equal(1, src.Calls); // injected clock still drives the fresh-cache path
    }

    [Fact]
    public async Task CachedSnapshotToStringDoesNotLeakToken()
    {
        var src = new CountingSource { FixedToken = "CANARY-DOTNET-CACHED-AT" };
        var p = new ClientCredentialsTokenProvider(src, skewSeconds: 0);
        await p.GetAccessTokenAsync();

        var field = typeof(ClientCredentialsTokenProvider).GetField("_cache", BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.NotNull(field);
        var cached = field.GetValue(p);
        Assert.NotNull(cached);
        var result = cached.ToString();
        Assert.DoesNotContain("CANARY-DOTNET-CACHED-AT", result);
        Assert.Contains("***", result);
    }

    // ── A success status whose body carries an OAuth error (registry auth-2xx-error-code-divergent): the provider fails with
    // the grant's error and caches nothing — the next call asks the token endpoint again. ──

    private const string TokenPath = "/realms/r/protocol/openid-connect/token";
    private const string TokenB1 = """{"error":"invalid_grant","error_description":"d"}""";
    private const string TokenB2 = """{"error":"invalid_grant","access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl","token_type":"Bearer","expires_in":300}""";
    private const string NextAccessToken = "next-access-token";

    [Theory]
    [InlineData(TokenB1)]
    [InlineData(TokenB2)]
    public async Task SuccessStatusOAuthError_fails_the_provider_and_caches_nothing(string body)
    {
        using var idp = WireMockServer.Start();
        AnswerToken(idp, body);
        using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "zebrasecretjk" });
        var provider = new ClientCredentialsTokenProvider(kc.Auth);

        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(() => provider.GetAccessTokenAsync());
        Assert.Equal("invalid_grant", refused.OAuthError);
        Assert.Equal("Client credentials grant failed: invalid_grant", refused.Message);

        AnswerToken(idp, $$"""{"access_token":"{{NextAccessToken}}","token_type":"Bearer","expires_in":300}""");
        Assert.Equal(NextAccessToken, await provider.GetAccessTokenAsync());
        Assert.Equal(2, idp.LogEntries.Count(e => e.RequestMessage?.Path == TokenPath));
    }

    /// <summary>The token endpoint answers 200 with <paramref name="body"/>; whatever it answered before is gone.</summary>
    private static void AnswerToken(WireMockServer idp, string body)
    {
        idp.ResetMappings();
        idp.Given(Request.Create().WithPath(TokenPath).UsingPost())
           .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json").WithBody(body));
    }
}
