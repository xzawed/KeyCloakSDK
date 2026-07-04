using System.Threading;
using System.Threading.Tasks;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class TokenProviderTests
{
    sealed class CountingSource : ITokenSource
    {
        public int Calls;
        public long ExpiresIn = 300;
        private int _n;
        public Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default)
        {
            Interlocked.Increment(ref Calls);
            var tok = $"tok-{Interlocked.Increment(ref _n)}";
            return Task.FromResult(TokenSet.Create(tok, "Bearer", ExpiresIn, null, null, null, 0));
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
}
