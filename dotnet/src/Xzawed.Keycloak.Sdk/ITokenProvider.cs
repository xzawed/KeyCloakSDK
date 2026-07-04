namespace Xzawed.Keycloak;

/// <summary>Supplies access tokens to the admin facade — the only glue between auth and admin.
/// Consumers may inject a custom implementation.</summary>
public interface ITokenProvider
{
    Task<string> GetAccessTokenAsync(CancellationToken ct = default);
}

/// <summary>Obtains a fresh token set (e.g. via client-credentials). AuthClient implements this.</summary>
public interface ITokenSource
{
    Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default);
}

/// <summary>Caches a token and refreshes it before expiry, collapsing concurrent callers into one fetch.</summary>
public sealed class ClientCredentialsTokenProvider : ITokenProvider
{
    private readonly ITokenSource _source;
    private readonly int _skewSeconds;
    private readonly TimeProvider _clock;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _token;
    private DateTimeOffset _expiresAt = DateTimeOffset.MinValue;

    public ClientCredentialsTokenProvider(ITokenSource source, int skewSeconds = 30, TimeProvider? clock = null)
    {
        _source = source;
        _skewSeconds = skewSeconds;
        _clock = clock ?? TimeProvider.System;
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken ct = default)
    {
        if (!IsExpired() && _token is { } cached) return cached;      // fast path, no gate

        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!IsExpired() && _token is { } fresh) return fresh;    // double-check under gate

            var ts = await _source.ClientCredentialsTokenAsync(ct).ConfigureAwait(false); // failure => not cached
            _token = ts.AccessToken;
            _expiresAt = _clock.GetUtcNow().AddSeconds(Math.Max(0, ts.ExpiresIn - _skewSeconds));
            return ts.AccessToken;
        }
        finally { _gate.Release(); }
    }

    private bool IsExpired() => _clock.GetUtcNow() >= _expiresAt;
}
