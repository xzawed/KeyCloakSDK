using System.Net.Http.Headers;

namespace Xzawed.Keycloak;

/// <summary>Makes .NET read a JSON response body as UTF-8 whatever <c>charset</c> its <c>Content-Type</c> names — registry
/// <c>token-response-class-divergent</c>, decision D2.</summary>
/// <remarks>
/// <para>JSON exchanged between systems is UTF-8 (RFC 8259 §8.1) and <c>application/json</c> defines no charset parameter:
/// "adding one really has no effect on compliant recipients" (§11). .NET honours it all the same — <c>ReadAsStringAsync</c> and
/// <c>System.Net.Http.Json</c> look the name up before they read a byte, so an unknown name (or UTF-7, disabled in .NET) failed
/// a body that was valid UTF-8 JSON: a usable token became a <see cref="KeycloakTransportException"/>, and an admin read a 500
/// the server never sent (measured 2026-11-10).</para>
/// <para>The parameter is rewritten to <c>utf-8</c>, not removed: without one, <c>ReadAsStringAsync</c> picks UTF-16 or UTF-32
/// from a byte-order mark. A UTF-8 byte-order mark is dropped either way (RFC 8259 §8.1 lets a parser ignore it).</para>
/// </remarks>
internal static class ResponseCharset
{
    private const string Utf8 = "utf-8";

    /// <summary>For a token or introspection response, whatever media type it is labelled with — the protocol defines it as
    /// JSON, so its label decides nothing about the bytes.</summary>
    internal static void ReadAsUtf8(HttpContentHeaders headers)
    {
        if (headers.ContentType is { CharSet: not null } type)
            type.CharSet = Utf8;
    }

    /// <summary>For an admin response — only when it is labelled JSON (<c>application/json</c> or <c>application/*+json</c>). An
    /// error body of another type becomes the SDK error's message, and its charset is its own; a name .NET cannot decode
    /// there is still the undecodable body <c>AdminClient</c> reports.</summary>
    internal static void ReadJsonAsUtf8(HttpContentHeaders headers)
    {
        if (headers.ContentType is { CharSet: not null, MediaType: { } media } type && IsJson(media))
            type.CharSet = Utf8;
    }

    /// <summary>Whether a body's text, as it was read, is text an SDK error may quote: no U+0000 and no U+FFFD.</summary>
    /// <remarks>Every JSON body is read as UTF-8 (above), so one really encoded in UTF-16 comes out with NULs between its letters,
    /// and one in ISO-8859-1 with U+FFFD — what the decoder puts where bytes it could not decode were — for its letters past
    /// ASCII; admin error messages carried both (measured 2026-11-10). Such a message is withheld as an undecodable body's is. A
    /// U+FFFD the server really sent is withheld too: the text alone cannot tell it from a decoder's.</remarks>
    internal static bool IsQuotable(string? text) => text is null || text.AsSpan().IndexOfAny('\0', '�') < 0;

    private static bool IsJson(string mediaType) =>
        mediaType.Equals("application/json", StringComparison.OrdinalIgnoreCase)
        || (mediaType.StartsWith("application/", StringComparison.OrdinalIgnoreCase)
            && mediaType.EndsWith("+json", StringComparison.OrdinalIgnoreCase));
}
