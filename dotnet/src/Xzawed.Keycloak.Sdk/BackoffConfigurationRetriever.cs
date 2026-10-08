using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.Configuration;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;

namespace Xzawed.Keycloak;

/// <summary>
/// Applies the <see cref="FailureBackoff"/> to every discovery/JWKS fetch the configuration manager makes: the cold load,
/// the background refresh of a stale configuration, and the refresh a bad signature requests.
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
/// Inside the window the fetch is refused without touching the IdP. The manager treats that like any failed refresh: it
/// keeps serving the stale configuration, so tokens it can verify keep validating.
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

    /// <param name="inner">The retriever that actually fetches.</param>
    /// <param name="validator">The check the manager applies before installing a configuration.</param>
    /// <param name="now">Clock seam (tests only).</param>
    /// <param name="jitter">Jitter seam (tests only).</param>
    internal BackoffConfigurationRetriever(
        IConfigurationRetriever<OpenIdConnectConfiguration> inner,
        IConfigurationValidator<OpenIdConnectConfiguration> validator,
        Func<DateTimeOffset>? now = null,
        Func<double>? jitter = null)
    {
        _inner = inner;
        _validator = validator;
        _backoff = new FailureBackoff(now, jitter);
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

        _backoff.Succeeded();
        return config;
    }
}
