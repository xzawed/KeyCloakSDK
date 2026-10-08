using Microsoft.IdentityModel.Tokens;

namespace Xzawed.Keycloak;

/// <summary>
/// Wraps a <see cref="BaseConfigurationManager"/> with the <see cref="FailureBackoff"/> on <b>failed</b> discovery/JWKS
/// fetches — the cold load.
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
/// A throw from the inner manager means no configuration is available at all — when one is cached
/// it is returned without a network round trip — so a throw is exactly the "cold cache and the
/// fetch failed" case the backoff is for. ⚠️ The converse is why this wrapper is not enough on its own: once a
/// configuration is cached, a failed refresh never reaches here. <see cref="BackoffConfigurationRetriever"/> backs those off.
/// </para>
/// </remarks>
internal sealed class BackoffConfigurationManager : BaseConfigurationManager
{
    internal static readonly TimeSpan BackoffBase = FailureBackoff.Base;
    internal static readonly TimeSpan BackoffCap = FailureBackoff.Cap;

    private readonly BaseConfigurationManager _inner;
    private readonly FailureBackoff _backoff;

    /// <param name="inner">The configuration manager whose fetches are being backed off.</param>
    /// <param name="now">Clock seam — tests must be able to cross the window without sleeping.</param>
    /// <param name="jitter">Jitter seam; see <see cref="FailureBackoff"/>.</param>
    internal BackoffConfigurationManager(
        BaseConfigurationManager inner,
        Func<DateTimeOffset>? now = null,
        Func<double>? jitter = null)
    {
        _inner = inner;
        _backoff = new FailureBackoff(now, jitter);
    }

    public override async Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel)
    {
        _backoff.ThrowIfBackingOff();

        try
        {
            var config = await _inner.GetBaseConfigurationAsync(cancel).ConfigureAwait(false);
            _backoff.Succeeded();
            return config;
        }
        catch (Exception e) when (!RefusedByABackoff(e))
        {
            _backoff.Failed();
            throw;
        }
    }

    public override void RequestRefresh() => _inner.RequestRefresh();

    /// <summary>A fetch a backoff refused never reached the IdP, so it is not a failure to count. The manager wraps what
    /// <see cref="BackoffConfigurationRetriever"/> throws once (IDX20803), so its refusal arrives as the inner exception —
    /// counting those would stretch this window on attempts that never happened (twenty queued callers, twenty doublings).
    /// Nothing else on the discovery/JWKS path throws <see cref="KeycloakTransportException"/>.</summary>
    private static bool RefusedByABackoff(Exception e) =>
        e is KeycloakTransportException || e.InnerException is KeycloakTransportException;
}
