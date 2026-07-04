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
    // token+expiry published as one immutable snapshot so the fast-path read is a single atomic
    // reference read — no tearing of the multi-word DateTimeOffset on weak memory models (ARM64).
    private volatile Cached? _cache;

    private sealed record Cached(string Token, DateTimeOffset ExpiresAt);

    public ClientCredentialsTokenProvider(ITokenSource source, int skewSeconds = 30, TimeProvider? clock = null)
    {
        _source = source;
        _skewSeconds = skewSeconds;
        _clock = clock ?? TimeProvider.System;
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken ct = default)
    {
        if (Fresh(_cache) is { } fast) return fast;                   // fast path, no gate

        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (Fresh(_cache) is { } fresh) return fresh;            // double-check under gate

            var ts = await _source.ClientCredentialsTokenAsync(ct).ConfigureAwait(false); // failure => not cached
            var expiresAt = _clock.GetUtcNow().AddSeconds(Math.Max(0, ts.ExpiresIn - _skewSeconds));
            _cache = new Cached(ts.AccessToken, expiresAt);
            return ts.AccessToken;
        }
        finally { _gate.Release(); }
    }

    private string? Fresh(Cached? c) => c is not null && _clock.GetUtcNow() < c.ExpiresAt ? c.Token : null;
}
