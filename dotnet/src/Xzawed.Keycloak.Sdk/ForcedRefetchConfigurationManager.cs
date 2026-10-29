using System.Runtime.CompilerServices;
using Microsoft.IdentityModel.Tokens;

namespace Xzawed.Keycloak;

/// <summary>
/// Runs the refetch IdentityModel's handler asks for (<see cref="RequestRefresh"/>) when a token fails against the cached
/// configuration in a way a newer one could fix — its key is not there, or its signature or issuer does not match — and
/// hands the result to the validation that asked, inside the same call. The cold load stays with the manager it wraps, and
/// so does the reload once the served key set has reached its lifetime (<see cref="KeySetLifetime"/>): that set is never
/// served again — the wrapped manager starts over cold.
/// </summary>
/// <remarks>
/// <para>⚠️ <b>Why the SDK runs it.</b> IdentityModel's manager starts a requested refresh with <c>Task.Run</c> and returns;
/// the handler then asks for the configuration again and retries only if it gets a different one. It never did, so the
/// first token under a rotated-in key was rejected (IDX10503) and only the next one accepted (measured:
/// <c>JwksKeyRotationTests</c>). The blocking mode IdentityModel offers instead, the AppContext switch
/// <c>Switch.Microsoft.IdentityModel.UpdateConfigAsBlocking</c>, is process-wide — the host's to set, never a library's.</para>
/// <para>The rules (<c>.claude/rules/security.md</c>): one refetch per <see cref="BaseConfigurationManager.RefreshInterval"/>,
/// stamped when it is decided, so a failed one spends the window too; one at a time — a validation that asks while one is
/// in flight waits for that one; on <see cref="CancellationToken.None"/> under the HTTP client's own timeouts, so a caller
/// that cancels stops waiting and the refetch still lands; through the retriever every other fetch uses, so the failure
/// backoff and the empty-key-set check hold. Only a validation that asked waits — one whose key resolves never does.</para>
/// <para>IdentityModel's manager cannot be handed a configuration, so a refetched one is served in place of the configuration
/// the refetch was decided against — and only while that manager still serves that one. Whatever it installs next, while the
/// refetch is still in flight too, is served as it is (measured: <c>ForcedRefetchConfigurationManagerTests</c>).</para>
/// </remarks>
internal sealed class ForcedRefetchConfigurationManager : BaseConfigurationManager
{
    private readonly BaseConfigurationManager _inner;
    private readonly Func<Task<BaseConfiguration>> _fetch;
    private readonly Func<DateTimeOffset> _now;
    private readonly ColdStartConfigurationManager? _coldStart;

    /// <summary>The refetch this validation asked for. The handler calls <see cref="RequestRefresh"/> and then
    /// <see cref="GetBaseConfigurationAsync"/> back to back inside one async method, so what the first sets reaches the
    /// second — and nothing outside that method.</summary>
    private readonly AsyncLocal<Task?> _asked = new();

    // `System.Threading.Lock` is .NET 9+; this library targets net8.0.
    private readonly object _gate = new();
    private DateTimeOffset? _decided;
    private Task? _running;
    private BaseConfiguration? _cached;

    /// <summary>A refetched configuration and the one the refetch was decided against, which it is served in place of —
    /// published whole, never changed.</summary>
    private StrongBox<(BaseConfiguration Over, BaseConfiguration Fresh)>? _served;

    /// <param name="inner">Serves the cached configuration: the cold load, and the reload once a key set has expired.</param>
    /// <param name="fetch">One discovery and JWKS fetch, through the retriever <paramref name="inner"/> uses.</param>
    /// <param name="now">Clock seam — tests must be able to cross the window without waiting for it.</param>
    /// <param name="coldStart">The cold-load manager under <paramref name="inner"/>, started over once the served key set
    /// has expired; <c>null</c> only in tests that do not cross a lifetime.</param>
    internal ForcedRefetchConfigurationManager(
        BaseConfigurationManager inner,
        Func<Task<BaseConfiguration>> fetch,
        Func<DateTimeOffset>? now = null,
        ColdStartConfigurationManager? coldStart = null)
    {
        _inner = inner;
        _fetch = fetch;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _coldStart = coldStart;
    }

    public override async Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel)
    {
        if (_asked.Value is { } refetch)
            await refetch.WaitAsync(cancel).ConfigureAwait(false); // never faults — RefetchAsync catches
        // A key set at its age is never served again — not after a failed reload either: the cold-load manager starts over,
        // and its cold load answers or fails this validation. Judged on what was served last, before the wrapped manager is
        // asked again, so an expired one never gets the chance to refresh in the background instead.
        if (_coldStart is { } coldStart && Volatile.Read(ref _cached) is { } last)
            coldStart.StartOverIfExpired(last, ServedFor(last));
        var cached = await _inner.GetBaseConfigurationAsync(cancel).ConfigureAwait(false);
        Volatile.Write(ref _cached, cached);
        return ServedFor(cached);
    }

    /// <summary>What is served while the wrapped manager serves <paramref name="cached"/>: a refetch decided against it, or it.</summary>
    private BaseConfiguration ServedFor(BaseConfiguration cached) =>
        Volatile.Read(ref _served) is { Value: var served } && ReferenceEquals(served.Over, cached) ? served.Fresh : cached;

    public override void RequestRefresh()
    {
        if (Volatile.Read(ref _cached) is null)
            return; // nothing served yet, so nothing to supersede: the cold load is the fetch, and it spends no window
        TaskCompletionSource? decided = null;
        BaseConfiguration? decidedAgainst = null;
        Task refetch;
        lock (_gate)
        {
            if (_running is null)
            {
                var now = _now();
                if (_decided is { } last && now - last < RefreshInterval)
                    return; // the window is closed and nothing is in flight: the cached configuration answers
                _decided = now;
                // What the refetch will be served in place of. Read now, not when it lands: a configuration the wrapped manager
                // installs meanwhile is at least as new as the refetch, and must not be shadowed by it.
                decidedAgainst = Volatile.Read(ref _cached);
                decided = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _running = decided.Task;
            }
            refetch = _running;
        }
        if (decided is not null)
            _ = Task.Run(() => RefetchAsync(decided, decidedAgainst!), CancellationToken.None); // non-null: checked above
        _asked.Value = refetch;
    }

    private async Task RefetchAsync(TaskCompletionSource done, BaseConfiguration decidedAgainst)
    {
        try
        {
            var fresh = await _fetch().ConfigureAwait(false);
            Volatile.Write(ref _served, new((decidedAgainst, fresh)));
        }
        catch (Exception)
        {
            // Counted by the retriever's failure backoff. The cached configuration keeps answering — until its lifetime ends.
        }
        finally
        {
            lock (_gate)
                _running = null;
            done.SetResult();
        }
    }
}
