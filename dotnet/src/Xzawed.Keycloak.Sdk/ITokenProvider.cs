namespace Xzawed.Keycloak;

/// <summary>Supplies access tokens to the admin facade — the only glue between auth and admin.
/// Consumers may inject a custom implementation.</summary>
/// <remarks>The admin facade sends the token as <c>Authorization: Bearer &lt;token&gt;</c> with SP, HTAB, CR and LF trimmed
/// from both ends; a token that is then not an RFC 6750 <c>b64token</c> fails the call before anything is sent
/// (<see cref="KeycloakTransportException"/>).</remarks>
public interface ITokenProvider
{
    Task<string> GetAccessTokenAsync(CancellationToken ct = default);
}

/// <summary>The bearer grammar every admin request goes out under — the same in all nine SDKs. <c>BearerHandler</c> applies
/// it to every admin request, <see cref="ClientCredentialsTokenProvider"/> to every token before it caches one.</summary>
internal static class BearerToken
{
    /// <summary>The message of an admin request refused for its token. It quotes no part of the token.</summary>
    internal const string SendRefused = "admin request failed: the access token is not a valid RFC 6750 bearer token (b64token)";

    /// <summary>The message of a grant refused for its token. It quotes no part of the token.</summary>
    internal const string GrantRefused = "Client credentials grant failed: access_token is not a valid RFC 6750 bearer token (b64token)";

    private static readonly char[] Trimmed = { ' ', '\t', '\r', '\n' };

    /// <summary>What follows <c>Bearer </c> for <paramref name="token"/>, or null when nothing may be sent: SP, HTAB, CR and LF
    /// are trimmed from both ends — that set and no other, not NBSP, U+3000, VT or FF — and the rest must be an RFC 6750
    /// <c>b64token</c>, <c>1*( ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" ) *"="</c>, ASCII only.</summary>
    /// <remarks>A loop, not a <c>Regex</c>: .NET's <c>$</c> also matches before a final LF.</remarks>
    internal static string? Sendable(string? token)
    {
        var t = token?.Trim(Trimmed);
        if (string.IsNullOrEmpty(t))
            return null;
        var i = 0;
        while (i < t.Length && IsToken68Char(t[i]))
            i++;
        if (i == 0)
            return null;
        while (i < t.Length && t[i] == '=')
            i++;
        return i == t.Length ? t : null;
    }

    private static bool IsToken68Char(char c) =>
        c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-' or '.' or '_' or '~' or '+' or '/';
}

/// <summary>Obtains a fresh token set (e.g. via client-credentials). AuthClient implements this.</summary>
public interface ITokenSource
{
    Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default);
}

/// <summary>Caches a token and refreshes it before expiry, collapsing concurrent callers into one fetch. A token the admin
/// facade could not send (see <see cref="ITokenProvider"/>) fails the call with <see cref="KeycloakAuthException"/> and is
/// not cached; one it can send is cached and returned trimmed.</summary>
public sealed class ClientCredentialsTokenProvider : ITokenProvider
{
    private readonly ITokenSource _source;
    private readonly int _skewSeconds;
    private readonly TimeProvider _clock;
    private readonly SemaphoreSlim _gate = new(1, 1);
    // token+expiry published as one immutable snapshot so the fast-path read is a single atomic
    // reference read — no tearing of the multi-word DateTimeOffset on weak memory models (ARM64).
    private volatile Cached? _cache;

    private sealed record Cached(string Token, DateTimeOffset ExpiresAt)
    {
        // A record's generated ToString() prints every member, so Token would appear in plain text.
        public override string ToString() => $"Cached {{ Token = ***, ExpiresAt = {ExpiresAt:O} }}";
    }

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
            // A token the admin facade could not send fails the grant and is not cached — the next call asks the source
            // again. One it can send is cached as it goes out, trimmed.
            var token = BearerToken.Sendable(ts.AccessToken) ?? throw new KeycloakAuthException(BearerToken.GrantRefused);
            var expiresAt = _clock.GetUtcNow().AddSeconds(Math.Max(0, ts.ExpiresIn - _skewSeconds));
            _cache = new Cached(token, expiresAt);
            return token;
        }
        finally { _gate.Release(); }
    }

    private string? Fresh(Cached? c) => c is not null && _clock.GetUtcNow() < c.ExpiresAt ? c.Token : null;
}
