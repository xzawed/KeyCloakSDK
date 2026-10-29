using Microsoft.IdentityModel.Tokens;

namespace Xzawed.Keycloak;

/// <summary>
/// Holds the IdentityModel manager that does the cold load, and starts over with a new, cold one once the key set it served
/// has reached its lifetime (<see cref="KeySetLifetime"/>) — so the reload is the cold load itself: the same single flight,
/// the same failure backoff in front of it (<see cref="BackoffConfigurationManager"/>), and a failure that fails the validation.
/// </summary>
/// <remarks>IdentityModel's manager cannot be emptied: once it holds a configuration it serves it, past its own refresh interval
/// while refreshing in the background. A new instance is the only cold one. What is served — and so what has to be young
/// enough — is known above (<see cref="ForcedRefetchConfigurationManager"/>), because a forced refetch can serve a newer set
/// in place of this one's.</remarks>
internal sealed class ColdStartConfigurationManager : BaseConfigurationManager
{
    private readonly Func<BaseConfigurationManager> _create;
    private readonly KeySetLifetime _lifetime;
    private Slot _slot;

    /// <param name="create">A new, cold IdentityModel manager.</param>
    /// <param name="lifetime">How long a served key set may be used.</param>
    internal ColdStartConfigurationManager(Func<BaseConfigurationManager> create, KeySetLifetime lifetime)
    {
        _create = create;
        _lifetime = lifetime;
        _slot = new Slot(create());
    }

    public override async Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel)
    {
        var slot = Volatile.Read(ref _slot);
        var configuration = await slot.Manager.GetBaseConfigurationAsync(cancel).ConfigureAwait(false);
        slot.Served = configuration;
        return configuration;
    }

    /// <summary>Starts over cold if <paramref name="served"/> — what is served while this manager serves
    /// <paramref name="cached"/> — has reached its lifetime, and only if the current manager is still the one that served
    /// <paramref name="cached"/>: callers that saw the same expired set together start over once, and one that saw it late
    /// starts nothing.</summary>
    internal void StartOverIfExpired(BaseConfiguration cached, BaseConfiguration served)
    {
        if (!_lifetime.IsExpired(served))
            return;
        var slot = Volatile.Read(ref _slot);
        if (ReferenceEquals(slot.Served, cached))
            Interlocked.CompareExchange(ref _slot, new Slot(_create()), slot);
    }

    // Not reached from JwtValidator: ForcedRefetchConfigurationManager, at the top, runs the requested refetch itself.
    public override void RequestRefresh() => Volatile.Read(ref _slot).Manager.RequestRefresh();

    private sealed class Slot(BaseConfigurationManager manager)
    {
        private BaseConfiguration? _served;

        internal BaseConfigurationManager Manager { get; } = manager;

        /// <summary>The configuration this manager served last; <c>null</c> until its cold load succeeded.</summary>
        internal BaseConfiguration? Served
        {
            get => Volatile.Read(ref _served);
            set => Volatile.Write(ref _served, value);
        }
    }
}
