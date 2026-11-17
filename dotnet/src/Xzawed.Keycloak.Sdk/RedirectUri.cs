using System.Diagnostics.CodeAnalysis;

namespace Xzawed.Keycloak;

/// <summary>What <see cref="AuthClient.CreateAuthorizationRequest"/> checks on the caller's redirect URI before it builds
/// anything, in this order, each refusal a <see cref="KeycloakConfigException"/> with a fixed message that quotes no part of
/// the value: R1, an absolute URI (RFC 6749 §3.1.2 — an RFC 3986 scheme followed by <c>:</c>; null is not one); R2, no
/// fragment component (RFC 6749 §3.1.2 — a <c>#</c> anywhere, the empty fragment included); R3, URI text Keycloak accepts
/// (RFC 3986 §2 — no character in U+0000–U+0020 or U+007F–U+00A0, none of <c>" &lt; &gt; \ ^ ` { | }</c>, every
/// <c>%</c> followed by two hex digits, and no unpaired UTF-16 surrogate).</summary>
/// <remarks>
/// <para>It validates and never rewrites: the URL carries the caller's string as given, because the code exchange sends that
/// string verbatim and normalising only one of the two requests makes them disagree (#1133). That is why R3 refuses an
/// unpaired surrogate: Duende's encoder writes it as U+FFFD (measured: <c>…c%EF%BF%BDb</c>), which would rewrite the value.</para>
/// <para>Keycloak refuses every R3 value for every client registration: <c>RedirectUtils.toUri</c> parses the incoming
/// <c>redirect_uri</c> with <c>java.net.URI.create</c>, which throws on each of them (measured on JDK 21; <c>ü</c>, <c>'</c>,
/// <c>[</c>/<c>]</c> in the query and <c>%20</c> pass). R3 is not all of what that parser refuses — the other Unicode space
/// separators (U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000) and <c>[</c>/<c>]</c> outside the query pass
/// R3 and are refused by the server instead (same measurement). Keycloak is more lenient than R1 and R2 — a relative value
/// is resolved against the client's root URL when a registered pattern matches it, and a fragment is only scanned for
/// forbidden parameters — but the SDK follows the RFC. Loops, not a <c>Regex</c>, like <c>BearerToken.Sendable</c>.</para>
/// </remarks>
internal static class RedirectUri
{
    internal const string NotAbsolute = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)";
    internal const string HasFragment = "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)";
    internal const string NotUriText = "invalid redirect_uri: not a valid URI (RFC 3986 §2)";

    // The printable US-ASCII characters RFC 3986 neither reserves nor leaves unreserved (besides '%').
    private const string Excluded = "\"<>\\^`{|}";

    /// <summary>Throws <see cref="KeycloakConfigException"/> unless <paramref name="value"/> passes R1, then R2, then R3.</summary>
    internal static void Require(string? value)
    {
        if (!HasScheme(value))
            throw new KeycloakConfigException(NotAbsolute);
        if (value.Contains('#'))
            throw new KeycloakConfigException(HasFragment);
        if (!IsUriText(value))
            throw new KeycloakConfigException(NotUriText);
    }

    // R1 — ^[A-Za-z][A-Za-z0-9+.-]*:
    private static bool HasScheme([NotNullWhen(true)] string? value)
    {
        if (string.IsNullOrEmpty(value) || !char.IsAsciiLetter(value[0]))
            return false;
        for (var i = 1; i < value.Length; i++)
        {
            var c = value[i];
            if (c == ':')
                return true;
            if (!char.IsAsciiLetterOrDigit(c) && c != '+' && c != '-' && c != '.')
                return false;
        }
        return false;
    }

    // R3 — code points as numbers: an invisible character never sits in this source.
    private static bool IsUriText(string value)
    {
        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            if (c <= 0x20 || (c >= 0x7F && c <= 0xA0) || Excluded.Contains(c))
                return false;
            if (c == '%' && (i + 2 >= value.Length || !char.IsAsciiHexDigit(value[i + 1]) || !char.IsAsciiHexDigit(value[i + 2])))
                return false;
            if (char.IsHighSurrogate(c) && i + 1 < value.Length && char.IsLowSurrogate(value[i + 1]))
                i++;   // a pair is one character — its low half is not unpaired
            else if (char.IsSurrogate(c))
                return false;   // a high surrogate with no low one after it, or a low one with no high one before it
        }
        return true;
    }
}
