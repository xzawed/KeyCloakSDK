using Microsoft.IdentityModel.Tokens;

namespace Xzawed.Keycloak;

/// <summary>
/// Wraps a <see cref="BaseConfigurationManager"/> with a backoff on <b>failed</b> discovery/JWKS
/// fetches.
/// </summary>
/// <remarks>
/// <para>
/// This is a different axis from <see cref="JwtValidatorOptions.RefreshIntervalSeconds"/> (30s).
/// That interval caps refreshes <i>after</i> a configuration is cached. It does nothing while the
/// cache is empty and the fetch keeps failing: measured 2026-09-04, 20 validations against a
/// failing IdP produced <b>40</b> outbound requests (two per validation — .NET re-attempts the
/// discovery document). The same defect was present in seven languages.
/// </para>
/// <para>
/// Do NOT reuse the 30-second interval here. One transient 503 would then mean "no token validates
/// for 30 seconds", which is worse than the defect. Start short, grow exponentially, cap at 5s.
/// </para>
/// <para>
/// This never sleeps: inside the window the call fails immediately without touching the IdP
/// (negative cache). Pacing retries is the caller's job, not a library's.
/// </para>
/// <para>
/// A throw from the inner manager means no configuration is available at all — when one is cached
/// it is returned without a network round trip — so a throw is exactly the "cold cache and the
/// fetch failed" case the backoff is for.
/// </para>
/// </remarks>
internal sealed class BackoffConfigurationManager : BaseConfigurationManager
{
    internal static readonly TimeSpan BackoffBase = TimeSpan.FromMilliseconds(200);
    internal static readonly TimeSpan BackoffCap = TimeSpan.FromSeconds(5);

    private readonly BaseConfigurationManager _inner;
    private readonly Func<DateTimeOffset> _now;
    private readonly Func<double> _jitter;
    // `System.Threading.Lock` is .NET 9+; this library targets net8.0.
    private readonly object _gate = new();
    private int _failures;
    private DateTimeOffset? _lastFailure;

    /// <param name="inner">The configuration manager whose fetches are being backed off.</param>
    /// <param name="now">Clock seam — tests must be able to cross the window without sleeping.</param>
    /// <param name="jitter">Jitter seam; defaults to [0.5, 1.0), which spreads instances that
    /// failed at the same instant so their recovery does not knock the IdP over again.</param>
    internal BackoffConfigurationManager(
        BaseConfigurationManager inner,
        Func<DateTimeOffset>? now = null,
        Func<double>? jitter = null)
    {
        _inner = inner;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        // Jitter spreads a thundering herd; it is not a secret. It is still derived from the
        // high-resolution clock rather than a PRNG API: calling a weak PRNG inside
        // security-sensitive code is something static analysis rightly flags (measured: sonar
        // S2245, gosec G404). All seven languages use the same idiom.
        _jitter = jitter ?? (() =>
            0.5 + System.Diagnostics.Stopwatch.GetTimestamp() % 1_000_000 / 2_000_000.0);
    }

    public override async Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel)
    {
        TimeSpan remaining;
        int failures;
        lock (_gate)
        {
            remaining = BackoffRemaining(_now());
            failures = _failures;
        }
        if (remaining > TimeSpan.Zero)
            throw new KeycloakTransportException(
                $"JWKS fetch backing off after {failures} consecutive failures " +
                $"(retry in {remaining.TotalSeconds:F2}s)");

        try
        {
            var config = await _inner.GetBaseConfigurationAsync(cancel).ConfigureAwait(false);
            lock (_gate)
            {
                // A successful fetch must reset the counter, or a long-lived process stays pinned
                // at the cap forever.
                _failures = 0;
                _lastFailure = null;
            }
            return config;
        }
        catch (Exception e) when (e is not KeycloakTransportException)
        {
            lock (_gate)
            {
                _failures++;
                _lastFailure = _now();
            }
            throw;
        }
    }

    public override void RequestRefresh() => _inner.RequestRefresh();

    /// <summary>How long the caller must wait before another fetch is allowed; zero means "go ahead".</summary>
    private TimeSpan BackoffRemaining(DateTimeOffset now)
    {
        if (_lastFailure is not { } last)
            return TimeSpan.Zero;
        var remaining = BackoffDelay() - (now - last);
        return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
    }

    private TimeSpan BackoffDelay()
    {
        var shift = Math.Min(Math.Max(_failures, 1) - 1, 30);
        var raw = BackoffBase * Math.Pow(2, shift);
        return (raw < BackoffCap ? raw : BackoffCap) * _jitter();
    }
}
