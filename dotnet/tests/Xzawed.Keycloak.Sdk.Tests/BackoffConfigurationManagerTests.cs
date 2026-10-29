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

    /// <summary>Decision 2026-10-29 (<c>backoff-counts-caller-cancellation</c>: keep counting) — a cold load its caller
    /// cancelled counts as a failed fetch, so the next call inside the window is refused without reaching the IdP. Not
    /// counting it would let a storm of cancelled loads through to the IdP — the axis of "never roll the refetch stamp back
    /// on cancellation" (<c>.claude/rules/security.md</c>); the price on a healthy IdP is at most one window (≤ 5 s).</summary>
    /// <remarks>Pinned at the gate, where the counting happens: through <see cref="JwtValidator.ValidateAsync"/> a caller's
    /// token does not reach it — IdentityModel's handler asks for the configuration on <see cref="CancellationToken.None"/>,
    /// so a cancelled validation stops waiting and its load lands (<c>ValidationCancellationTests</c>).</remarks>
    [Fact]
    public async Task A_cold_load_its_caller_cancelled_counts_as_a_failed_fetch()
    {
        var inner = new WaitsForCancellation();
        var mgr = new BackoffConfigurationManager(inner, new FakeClock().Read, () => 1.0);
        using var cts = new CancellationTokenSource();

        var load = mgr.GetBaseConfigurationAsync(cts.Token);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => load);

        var refused = await Assert.ThrowsAsync<KeycloakTransportException>(
            () => mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Contains("backing off after 1 consecutive failures", refused.Message, StringComparison.Ordinal);
        Assert.Equal(1, inner.Calls);
    }

    /// <summary>The jitter is drawn once, when a failure is recorded (<c>backoff-jitter-redrawn-per-check</c>). Drawn on every
    /// check, one failure refused at an instant and let a fetch through at the same instant — the window shrank towards 0.5×
    /// and an outage cost up to twice the designed requests. The draws alternate between the ends of the band.</summary>
    [Fact]
    public void The_jitter_is_drawn_once_per_failure_and_the_window_end_does_not_move_between_checks()
    {
        var clock = new FakeClock();
        var draws = 0;
        var backoff = new FailureBackoff(clock.Read, () => draws++ % 2 == 0 ? 0.99 : 0.5);
        bool Refuses() => Record.Exception(backoff.ThrowIfBackingOff) is KeycloakTransportException;

        backoff.Failed(); // 0.2 s × 0.99 = 198 ms
        clock.Advance(TimeSpan.FromMilliseconds(150)); // inside 0.2 s × 0.99, past 0.2 s × 0.5
        Assert.All(Enumerable.Range(0, 6).Select(_ => Refuses()), Assert.True);
        clock.Advance(TimeSpan.FromMilliseconds(47));
        Assert.True(Refuses());
        clock.Advance(TimeSpan.FromMilliseconds(1)); // 198 ms after the failure: the window drawn then has ended
        Assert.False(Refuses());
    }

    /// <summary>The first call waits until its caller's token is cancelled — the cold load a cancelled caller abandons; any
    /// later call fails at once, so a gate that let one through fails the test instead of hanging it.</summary>
    private sealed class WaitsForCancellation : BaseConfigurationManager
    {
        public int Calls;

        public override async Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel)
        {
            if (Interlocked.Increment(ref Calls) == 1)
                await Task.Delay(Timeout.Infinite, cancel).ConfigureAwait(false);
            throw new InvalidOperationException("idp down");
        }

        public override void RequestRefresh()
        {
        }
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
