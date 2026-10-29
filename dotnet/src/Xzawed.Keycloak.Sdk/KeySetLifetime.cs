using System.Diagnostics;
using System.Runtime.CompilerServices;
using Microsoft.IdentityModel.Tokens;

namespace Xzawed.Keycloak;

/// <summary>
/// How long a key set may be used: <see cref="JwksMaxAgeSeconds"/> from the moment the fetch that brought it completed. Past
/// that it is never served again — the next validation starts over cold (<see cref="ColdStartConfigurationManager"/>), in the
/// same call, and fails if that fetch fails. A forced refetch brings a key set of its own, so it restarts the lifetime.
/// </summary>
/// <remarks>
/// <para>⚠️ <b>IdentityModel's <c>AutomaticRefreshInterval</c> is not this lifetime.</b> Past that interval its
/// <c>ConfigurationManager</c> hands back the configuration it holds and refreshes in the background, and a failed refresh is
/// only logged — so the stale keys kept validating through an outage (measured 2026-10-09: 5/5). Its clock is the wall clock,
/// plus up to 5% jitter.</para>
/// <para>Every fetch is stamped where it completes — <see cref="BackoffConfigurationRetriever"/>, which every fetch passes
/// through. The clock is monotonic unless a test hands in its own.</para>
/// </remarks>
internal sealed class KeySetLifetime
{
    /// <summary>The nine SDKs share this value (decision 2026-10-29).</summary>
    /// <remarks>⚠️ A plain decimal literal on purpose — a cross-language guard reads this line.</remarks>
    internal const int JwksMaxAgeSeconds = 300;

    private static readonly TimeSpan MaxAge = TimeSpan.FromSeconds(JwksMaxAgeSeconds);
    private static readonly long Origin = Stopwatch.GetTimestamp();

    private readonly Func<DateTimeOffset> _now;
    private readonly ConditionalWeakTable<BaseConfiguration, StrongBox<DateTimeOffset>> _fetchedAt = new();

    /// <param name="now">Clock seam (tests only); monotonic by default.</param>
    internal KeySetLifetime(Func<DateTimeOffset>? now = null) => _now = now ?? Monotonic;

    /// <summary>The fetch that brought <paramref name="configuration"/> has just completed: its lifetime starts now.</summary>
    internal void Fetched(BaseConfiguration configuration) =>
        _fetchedAt.AddOrUpdate(configuration, new StrongBox<DateTimeOffset>(_now()));

    /// <summary>Whether <paramref name="configuration"/> has reached its age. One that no fetch here stamped — none does in
    /// production — is aged from the first time it is asked about, never treated as fresh for good.</summary>
    internal bool IsExpired(BaseConfiguration configuration) =>
        _now() - _fetchedAt.GetValue(configuration, _ => new StrongBox<DateTimeOffset>(_now())).Value >= MaxAge;

    private static DateTimeOffset Monotonic() => DateTimeOffset.UnixEpoch + Stopwatch.GetElapsedTime(Origin);
}
