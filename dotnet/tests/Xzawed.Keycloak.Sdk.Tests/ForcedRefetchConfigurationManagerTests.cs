using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// What <see cref="ForcedRefetchConfigurationManager"/> serves around a refetch. End to end through IdentityModel's handler —
/// the window, the single flight, cancellation, the failure backoff: <see cref="JwksKeyRotationTests"/>.
/// </summary>
[Trait("Category", "Unit")]
public sealed class ForcedRefetchConfigurationManagerTests
{
    /// <summary>A refetched configuration is served in place of the cached one it supersedes — and gives way as soon as the
    /// wrapped manager installs one of its own, which is newer. The request is never handed to the wrapped manager: its
    /// background refresh would be a second fetch.</summary>
    [Fact]
    public async Task A_refetched_configuration_gives_way_to_the_wrapped_managers_next_one()
    {
        var inner = new Cache();
        var fresh = new OpenIdConnectConfiguration();
        var mgr = new ForcedRefetchConfigurationManager(inner, () => Task.FromResult<BaseConfiguration>(fresh));
        Assert.Same(inner.Current, await mgr.GetBaseConfigurationAsync(CancellationToken.None));

        mgr.RequestRefresh();

        Assert.Same(fresh, await mgr.GetBaseConfigurationAsync(CancellationToken.None));
        inner.Current = new OpenIdConnectConfiguration(); // the wrapped manager's own refresh — its 12-hour one
        Assert.Same(inner.Current, await mgr.GetBaseConfigurationAsync(CancellationToken.None));
    }

    /// <summary>Before any configuration was served there is nothing to supersede — the cold load is the fetch — so a refetch
    /// asked for then is not made, and it spends no window: the first one after a configuration is served still goes out.
    /// (IdentityModel's handler asks only once it holds a configuration; a direct call is what reaches this.)</summary>
    [Fact]
    public async Task A_refetch_asked_for_before_anything_was_served_is_not_made_and_spends_no_window()
    {
        var fetches = 0;
        var inner = new Cache();
        var mgr = new ForcedRefetchConfigurationManager(inner, () =>
        {
            Interlocked.Increment(ref fetches);
            return Task.FromResult<BaseConfiguration>(new OpenIdConnectConfiguration());
        });

        mgr.RequestRefresh();
        Assert.Same(inner.Current, await mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Equal(0, Volatile.Read(ref fetches));

        mgr.RequestRefresh();
        Assert.NotSame(inner.Current, await mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Equal(1, Volatile.Read(ref fetches));
    }

    private sealed class Cache : BaseConfigurationManager
    {
        public BaseConfiguration Current { get; set; } = new OpenIdConnectConfiguration();

        public override Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel) => Task.FromResult(Current);

        public override void RequestRefresh() =>
            throw new InvalidOperationException("the refetch was handed to the wrapped manager");
    }
}
