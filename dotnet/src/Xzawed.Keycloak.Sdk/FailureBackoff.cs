namespace Xzawed.Keycloak;

/// <summary>
/// The backoff on <b>failed</b> discovery/JWKS fetches: 0.2s doubling to a 5s cap, jitter ×[0.5, 1.0), a success resets
/// it. One schedule wherever the SDK fetches — <see cref="BackoffConfigurationManager"/> applies it to the cold load,
/// <see cref="BackoffConfigurationRetriever"/> to every fetch.
/// </summary>
/// <remarks>
/// <para>
/// Do NOT reuse the 30-second <see cref="JwtValidatorOptions.RefreshIntervalSeconds"/> here. One transient 503 would then
/// mean "no token validates for 30 seconds", which is worse than the defect. Start short, grow exponentially, cap at 5s.
/// </para>
/// <para>
/// This never sleeps: inside the window the call fails immediately without touching the IdP (negative cache). Pacing
/// retries is the caller's job, not a library's. A fetch refused that way never reached the IdP and is not counted.
/// </para>
/// </remarks>
internal sealed class FailureBackoff
{
    internal static readonly TimeSpan Base = TimeSpan.FromMilliseconds(200);
    internal static readonly TimeSpan Cap = TimeSpan.FromSeconds(5);

    private readonly Func<DateTimeOffset> _now;
    private readonly Func<double> _jitter;
    // `System.Threading.Lock` is .NET 9+; this library targets net8.0.
    private readonly object _gate = new();
    private int _failures;
    private DateTimeOffset? _lastFailure;

    /// <param name="now">Clock seam — tests must be able to cross the window without sleeping.</param>
    /// <param name="jitter">Jitter seam; defaults to [0.5, 1.0), which spreads instances that
    /// failed at the same instant so their recovery does not knock the IdP over again.</param>
    internal FailureBackoff(Func<DateTimeOffset>? now = null, Func<double>? jitter = null)
    {
        _now = now ?? (() => DateTimeOffset.UtcNow);
        // Jitter spreads a thundering herd; it is not a secret. It is still derived from the
        // high-resolution clock rather than a PRNG API: calling a weak PRNG inside
        // security-sensitive code is something static analysis rightly flags (measured: sonar
        // S2245, gosec G404). All seven languages use the same idiom.
        _jitter = jitter ?? (() =>
            0.5 + System.Diagnostics.Stopwatch.GetTimestamp() % 1_000_000 / 2_000_000.0);
    }

    /// <summary>Throws <see cref="KeycloakTransportException"/> while the window is open.</summary>
    internal void ThrowIfBackingOff()
    {
        TimeSpan remaining;
        int failures;
        lock (_gate)
        {
            remaining = Remaining(_now());
            failures = _failures;
        }
        if (remaining > TimeSpan.Zero)
            throw new KeycloakTransportException(
                $"JWKS fetch backing off after {failures} consecutive failures " +
                $"(retry in {remaining.TotalSeconds:F2}s)");
    }

    /// <summary>A fetch succeeded. It must reset the counter, or a long-lived process stays pinned at the cap forever.</summary>
    internal void Succeeded()
    {
        lock (_gate)
        {
            _failures = 0;
            _lastFailure = null;
        }
    }

    internal void Failed()
    {
        lock (_gate)
        {
            _failures++;
            _lastFailure = _now();
        }
    }

    /// <summary>How long the caller must wait before another fetch is allowed; zero means "go ahead".</summary>
    private TimeSpan Remaining(DateTimeOffset now)
    {
        if (_lastFailure is not { } last)
            return TimeSpan.Zero;
        var remaining = Delay() - (now - last);
        return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
    }

    private TimeSpan Delay()
    {
        var shift = Math.Min(Math.Max(_failures, 1) - 1, 30);
        var raw = Base * Math.Pow(2, shift);
        return (raw < Cap ? raw : Cap) * _jitter();
    }
}
