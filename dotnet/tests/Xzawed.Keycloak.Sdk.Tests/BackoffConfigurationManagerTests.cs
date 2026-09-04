using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Tests;

/// <summary>
/// Cold cache + failing IdP. <see cref="JwtValidatorOptions.RefreshIntervalSeconds"/> (30s) only
/// caps refreshes once a configuration is cached — while the cache is empty and the fetch keeps
/// failing it is never reached. Measured 2026-09-04: 20 validations produced <b>40</b> outbound
/// requests (two per validation), the same defect as the other six languages.
/// </summary>
public class BackoffConfigurationManagerTests
{
    private sealed class FakeManager : BaseConfigurationManager
    {
        public int Calls;
        public bool Down = true;

        public override Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel)
        {
            Calls++;
            if (Down)
                throw new InvalidOperationException("idp down");
            return Task.FromResult<BaseConfiguration>(new OpenIdConnectConfiguration());
        }

        public override void RequestRefresh() => Refreshes++;

        public int Refreshes;
    }

    private sealed class FakeClock
    {
        public DateTimeOffset Now = new(2026, 9, 4, 12, 0, 0, TimeSpan.Zero);
        public DateTimeOffset Read() => Now;
        public void Advance(TimeSpan by) => Now += by;
    }

    [Fact]
    public async Task ColdCacheFailingIdp_CollapsesToOneFetch()
    {
        var inner = new FakeManager();
        var clock = new FakeClock();
        var mgr = new BackoffConfigurationManager(inner, clock.Read, () => 1.0);

        for (var i = 0; i < 20; i++)
            await Assert.ThrowsAnyAsync<Exception>(
                () => mgr.GetBaseConfigurationAsync(CancellationToken.None));

        Assert.Equal(1, inner.Calls);
    }

    /// <summary>
    /// Control. Do NOT delete: the assertion above also passes for "one failure blocks forever",
    /// which is worse than the defect — the SDK would stay unusable after the IdP recovered.
    /// </summary>
    [Fact]
    public async Task BackoffWindowExpires_AndAllowsARetry()
    {
        var inner = new FakeManager();
        var clock = new FakeClock();
        var mgr = new BackoffConfigurationManager(inner, clock.Read, () => 1.0);

        await Assert.ThrowsAnyAsync<Exception>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Equal(1, inner.Calls);

        // Inside the window: fails immediately without touching the IdP (it never sleeps).
        var blocked = await Assert.ThrowsAsync<KeycloakTransportException>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Contains("backing off", blocked.Message, StringComparison.Ordinal);
        Assert.Equal(1, inner.Calls);

        // Past the window (pushed well beyond the 5s cap) it goes out again.
        clock.Advance(TimeSpan.FromSeconds(10));
        await Assert.ThrowsAnyAsync<Exception>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Equal(2, inner.Calls);
    }

    /// <summary>
    /// Control. Without a reset a long-lived process stays pinned at the 5s cap forever.
    /// </summary>
    [Fact]
    public async Task SuccessResetsTheFailureCounter()
    {
        var inner = new FakeManager();
        var clock = new FakeClock();
        var mgr = new BackoffConfigurationManager(inner, clock.Read, () => 1.0);

        await Assert.ThrowsAnyAsync<Exception>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));

        inner.Down = false;
        clock.Advance(TimeSpan.FromSeconds(10));
        Assert.NotNull(await mgr.GetBaseConfigurationAsync(CancellationToken.None));

        // The counter is back to zero, so the next failure opens the *base* window, not the cap.
        inner.Down = true;
        await Assert.ThrowsAnyAsync<Exception>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
        clock.Advance(BackoffConfigurationManager.BackoffBase);
        await Assert.ThrowsAnyAsync<Exception>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Equal(4, inner.Calls);
    }

    [Fact]
    public async Task DelayGrowsExponentiallyAndIsCapped()
    {
        var inner = new FakeManager();
        var clock = new FakeClock();
        var mgr = new BackoffConfigurationManager(inner, clock.Read, () => 1.0);

        // Eight consecutive failures, each stepped past its own window, must never wait longer
        // than the cap — otherwise a short outage locks validation out for minutes.
        for (var i = 0; i < 8; i++)
        {
            await Assert.ThrowsAnyAsync<Exception>(
                () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
            clock.Advance(BackoffConfigurationManager.BackoffCap);
        }
        Assert.Equal(8, inner.Calls);
    }

    [Fact]
    public void RequestRefreshDelegatesToTheInnerManager()
    {
        var inner = new FakeManager();
        new BackoffConfigurationManager(inner).RequestRefresh();
        Assert.Equal(1, inner.Refreshes);
    }

    /// <summary>The default seams (real clock, real jitter) must open a window too.</summary>
    [Fact]
    public async Task DefaultSeamsOpenAWindow()
    {
        var inner = new FakeManager();
        var mgr = new BackoffConfigurationManager(inner);

        await Assert.ThrowsAnyAsync<Exception>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
        var blocked = await Assert.ThrowsAsync<KeycloakTransportException>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Contains("backing off", blocked.Message, StringComparison.Ordinal);
        Assert.Equal(1, inner.Calls);
    }
}
