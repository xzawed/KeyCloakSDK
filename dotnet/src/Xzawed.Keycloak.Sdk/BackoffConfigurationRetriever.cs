using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.Configuration;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;

namespace Xzawed.Keycloak;

/// <summary>
/// Applies the <see cref="FailureBackoff"/> to every discovery/JWKS fetch: the cold load and the background refresh of a stale
/// configuration (IdentityModel's manager), and the refetch an unresolved key or a bad signature asks for
/// (<see cref="ForcedRefetchConfigurationManager"/>).
/// </summary>
/// <remarks>
/// <para>
/// ⚠️ <b>Why <see cref="BackoffConfigurationManager"/> alone is not enough.</b> Once a configuration is cached the manager
/// never throws: past its 12-hour refresh it hands back the stale configuration and refreshes in the background, and a
/// failed refresh is only logged. IdentityModel moves its next-refresh time only when a refresh succeeds (8.23.0), so
/// after one failure every validation started another refresh — measured 2026-10-09: ten validations against a down IdP,
/// ten more discovery and JWKS fetches. This retriever is the one place every fetch passes through, whichever path
/// started it.
/// </para>
/// <para>
/// Inside the window the fetch is refused without touching the IdP — and refused like any failed fetch: the configuration
/// already served keeps answering only until its lifetime ends (<see cref="KeySetLifetime"/>); after that, nothing does.
/// Every fetch that succeeds is stamped here, where it completes — the lifetime starts then.
/// </para>
/// <para>
/// A configuration the validator rejects — a 200 with <c>{"keys":[]}</c> — is a failed fetch too: the manager runs the
/// same check, refuses to install it and would refresh again on the next call.
/// </para>
/// </remarks>
internal sealed class BackoffConfigurationRetriever : IConfigurationRetriever<OpenIdConnectConfiguration>
{
    private readonly IConfigurationRetriever<OpenIdConnectConfiguration> _inner;
    private readonly IConfigurationValidator<OpenIdConnectConfiguration> _validator;
    private readonly FailureBackoff _backoff;
    private readonly KeySetLifetime? _lifetime;

    /// <param name="inner">The retriever that actually fetches.</param>
    /// <param name="validator">The check the manager applies before installing a configuration.</param>
    /// <param name="now">Clock seam (tests only).</param>
    /// <param name="jitter">Jitter seam (tests only).</param>
    /// <param name="lifetime">Where a fetched key set's lifetime starts; <c>null</c> only in tests that do not need it.</param>
    internal BackoffConfigurationRetriever(
        IConfigurationRetriever<OpenIdConnectConfiguration> inner,
        IConfigurationValidator<OpenIdConnectConfiguration> validator,
        Func<DateTimeOffset>? now = null,
        Func<double>? jitter = null,
        KeySetLifetime? lifetime = null)
    {
        _inner = inner;
        _validator = validator;
        _backoff = new FailureBackoff(now, jitter);
        _lifetime = lifetime;
    }

    public async Task<OpenIdConnectConfiguration> GetConfigurationAsync(
        string address, IDocumentRetriever retriever, CancellationToken cancel)
    {
        _backoff.ThrowIfBackingOff();

        OpenIdConnectConfiguration config;
        try
        {
            config = await _inner.GetConfigurationAsync(address, retriever, cancel).ConfigureAwait(false);
            var verdict = _validator.Validate(config);
            if (!verdict.Succeeded)
                throw new InvalidConfigurationException(verdict.ErrorMessage);
        }
        catch
        {
            _backoff.Failed();
            throw;
        }

        _lifetime?.Fetched(config);
        _backoff.Succeeded();
        return config;
    }
}
