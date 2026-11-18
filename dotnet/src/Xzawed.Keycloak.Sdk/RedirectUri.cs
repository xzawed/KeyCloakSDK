using System.Diagnostics.CodeAnalysis;

namespace Xzawed.Keycloak;

/// <summary>What <see cref="AuthClient.CreateAuthorizationRequest"/> checks on the caller's redirect URI before it builds
/// anything, in this order, each refusal a <see cref="KeycloakConfigException"/> with a fixed message that quotes no part of
/// the value: R1, an absolute URI (RFC 6749 §3.1.2 — an RFC 3986 scheme followed by <c>:</c>; null is not one); R2, no
/// fragment component (RFC 6749 §3.1.2 — a <c>#</c> anywhere, the empty fragment included); R3, URI text Keycloak accepts
/// (RFC 3986 §2 — no character in U+0000–U+0020 or U+007F–U+00A0, no Unicode space separator above that (U+1680,
/// U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000), none of <c>" &lt; &gt; \ ^ ` { | }</c>, every <c>%</c> followed by
/// two hex digits, and no unpaired UTF-16 surrogate); R4, with R3's message, a URI shape Keycloak's parser accepts — something
/// after the scheme's <c>:</c>, and, when that part starts with <c>/</c>, no <c>[</c> or <c>]</c> before the first <c>?</c> except
/// one bracketed host in an authority (<c>^([^@\[\]/]*@)?\[[^\[\]/]+\](:[0-9]*)?$</c>, the authority being what follows
/// <c>//</c> up to the next <c>/</c>). An opaque value and the query may hold brackets.</summary>
/// <remarks>
/// <para>It validates and never rewrites: the URL carries the caller's string as given, because the code exchange sends that
/// string verbatim and normalising only one of the two requests makes them disagree (#1133). That is why R3 refuses an
/// unpaired surrogate: Duende's encoder writes it as U+FFFD (measured: <c>…c%EF%BF%BDb</c>), which would rewrite the value.</para>
/// <para>Keycloak refuses every R3 and R4 value for every client registration: <c>RedirectUtils.toUri</c> parses the incoming
/// <c>redirect_uri</c> with <c>java.net.URI.create</c>, which throws on each of them (measured on JDK 21; <c>ü</c>, <c>'</c>,
/// <c>[</c>/<c>]</c> in the query and <c>%20</c> pass; R4's: "Expected scheme-specific part", "Illegal character in path",
/// "… in hostname", "… in user info", "Malformed IPv6 address", JDK 21.0.8). R1–R4 are still not all of what that parser
/// refuses — an empty authority (<c>https://</c> — "Expected authority") and what a bracketed host holds (<c>[zz]</c>) pass
/// and are refused by the server instead. Keycloak is more lenient than R1 and R2 — a relative value
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

    /// <summary>Throws <see cref="KeycloakConfigException"/> unless <paramref name="value"/> passes R1, then R2, then R3, then
    /// R4.</summary>
    internal static void Require(string? value)
    {
        if (!HasScheme(value))
            throw new KeycloakConfigException(NotAbsolute);
        if (value.Contains('#'))
            throw new KeycloakConfigException(HasFragment);
        if (!IsUriText(value))
            throw new KeycloakConfigException(NotUriText);
        if (!HasUriShape(value))
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
            if (c <= 0x20 || (c >= 0x7F && c <= 0xA0) || IsSpaceSeparator(c) || Excluded.Contains(c))
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

    // R4 — (R4a) something after the scheme's ':'; (R4b) when it starts with '/', before the first '?': an authority (after "//",
    // up to the next '/') holds '[' or ']' only as one bracketed host, and the rest (the path) holds neither.
    private static bool HasUriShape(string value)
    {
        var rest = value.AsSpan(value.IndexOf(':') + 1);
        if (rest.IsEmpty)
            return false;
        if (rest[0] != '/')
            return true;   // opaque — brackets allowed
        var query = rest.IndexOf('?');
        if (query >= 0)
            rest = rest[..query];
        if (rest.StartsWith("//", StringComparison.Ordinal))
        {
            var end = rest[2..].IndexOf('/');
            var authority = end < 0 ? rest[2..] : rest.Slice(2, end);
            if (authority.IndexOfAny('[', ']') >= 0 && !IsBracketedHost(authority))
                return false;
            rest = end < 0 ? ReadOnlySpan<char>.Empty : rest[(2 + end)..];
        }
        return rest.IndexOfAny('[', ']') < 0;
    }

    // ^([^@\[\]/]*@)?\[[^\[\]/]+\](:[0-9]*)?$ — the authority holds no '/' (it ends at one).
    private static bool IsBracketedHost(ReadOnlySpan<char> authority)
    {
        var open = authority.IndexOf('[');
        if (open < 0)
            return false;   // a ']' with no '['
        if (open > 0 && (authority[open - 1] != '@' || authority[..(open - 1)].IndexOfAny('@', ']') >= 0))
            return false;   // user information: no '@' or bracket inside, one '@' after it
        var host = authority[(open + 1)..];
        var close = host.IndexOfAny('[', ']');
        if (close <= 0 || host[close] != ']')
            return false;   // one or more characters, none of them a bracket, then ']'
        var port = host[(close + 1)..];
        if (port.IsEmpty)
            return true;
        if (port[0] != ':')
            return false;
        foreach (var c in port[1..])
        {
            if (!char.IsAsciiDigit(c))
                return false;
        }
        return true;
    }

    // The Unicode space separators above U+00A0 that java.net.URI refuses — the set measured on JDK 21.0.8, written out rather
    // than taken from a Unicode category, whose members can move between Unicode versions.
    private static bool IsSpaceSeparator(char c) =>
        c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
}
