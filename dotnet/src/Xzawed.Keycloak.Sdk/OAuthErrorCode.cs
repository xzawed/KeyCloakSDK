namespace Xzawed.Keycloak;

/// <summary>What <see cref="KeycloakAuthException.OAuthError"/> and the auth lanes' messages carry of the IdP's
/// <c>error</c>: a value of <c>[a-z_]{1,64}</c> — every registered OAuth and Keycloak code has that shape — that overlaps no
/// non-empty secret the request sent (neither contains the other, ASCII case ignored).</summary>
/// <remarks>⚠️ <c>error</c> is response body too: an endpoint that echoes what it got puts the client secret, the refresh
/// token or the introspected token there. The lanes used to take the RFC 6749 §5.2 grammar (<c>1*NQSCHAR</c>, #710), which a
/// Keycloak-style secret and a JWT are — measured on main a7d0fdf3, they reached <c>Message</c>, <c>ToString()</c> and
/// <c>OAuthError</c> — and a lowercase-only secret has the code shape itself (<c>OAuthErrorCodeEchoTests</c>). The overlap
/// withholds a truncated or extended echo too; its price is a secret that is a piece of a registered code
/// (<c>client</c>) withholding that code. An absent or empty secret is not compared — the empty string is a piece of every
/// code.</remarks>
internal static class OAuthErrorCode
{
    internal static string? Carried(string? value, IReadOnlyList<string?> sent)
    {
        if (value is not { Length: >= 1 and <= 64 } || !value.All(c => c is >= 'a' and <= 'z' or '_'))
            return null;
        foreach (var secret in sent)
        {
            if (string.IsNullOrEmpty(secret))
                continue;
            var folded = AsciiLower(secret);
            if (value.Contains(folded, StringComparison.Ordinal) || folded.Contains(value, StringComparison.Ordinal))
                return null;
        }
        return value;
    }

    /// <summary>A–Z → a–z, every other char as it is, so the nine languages agree — a Unicode lowercase maps U+212A KELVIN
    /// SIGN to <c>k</c>.</summary>
    private static string AsciiLower(string s) => string.Create(s.Length, s, static (chars, source) =>
    {
        for (var i = 0; i < source.Length; i++)
            chars[i] = source[i] is >= 'A' and <= 'Z' ? (char)(source[i] + ('a' - 'A')) : source[i];
    });
}
