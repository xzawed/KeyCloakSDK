using System.Text.Json;

namespace Xzawed.Keycloak;

/// <summary>
/// Keeps response input out of an SDK error's <see cref="Exception.InnerException"/> chain and message.
/// </summary>
/// <remarks>
/// ⚠️ Some lower exceptions quote what they failed to parse, and <c>exception.ToString()</c> — what every logger prints —
/// walks the whole chain. Measured (2026-09-26, <c>MalformedTokenResponseTests</c>): <c>System.Text.Json</c> quotes a body
/// that starts like a literal (<c>t</c>/<c>f</c>/<c>n</c>) up to the first JSON delimiter, so a form-encoded token response
/// was printed whole, live access token included; IdentityModel hides PII in its own message but nests that same exception
/// under it for an id_token whose header or payload is not JSON; <c>SocketsHttpHandler</c> quotes an invalid header line or
/// name (a chunk-size line in hex); <c>Encoding.GetEncoding</c> quotes an unknown <c>charset</c> when the body is read.
/// <para>When such an exception is anywhere in a chain, the chain is replaced by copies: <see cref="JsonException"/>,
/// <see cref="HttpRequestException"/> and <see cref="HttpIOException"/> keep their type (with the JSON position or the
/// <see cref="HttpRequestError"/>) under a fixed message; any other one becomes a <see cref="SanitizedException"/> carrying
/// its type name, message and stack trace. A chain without one is attached unchanged. <see cref="WithholdAll"/> is for a
/// chain raised while reading a response that did arrive — there any message may quote it, so none is kept.</para>
/// <para>Every copy carries <c>Data["Xzawed.Keycloak.Sanitized"] = true</c>; a copy, and an SDK error, inside a chain is
/// kept as-is — it was scrubbed when it was built.</para>
/// </remarks>
internal static class ErrorCause
{
    internal const string SanitizedKey = "Xzawed.Keycloak.Sanitized";
    private const int MaxDepth = 16;

    /// <summary>The inner exception to attach to an SDK error (called by the <see cref="KeycloakException"/> constructor).</summary>
    internal static Exception? Scrub(Exception? cause)
    {
        if (cause is null || IsClean(cause))
            return cause;
        var quoted = QuotedMessages(cause);
        return quoted.Count == 0 ? cause : Copy(cause, quoted, 0);
    }

    /// <summary>A copy of <paramref name="cause"/> with every message withheld — for an exception raised while reading a
    /// response that did arrive, where the library that failed may quote any part of it.</summary>
    internal static Exception WithholdAll(Exception cause) => IsClean(cause) ? cause : Copy(cause, null, 0);

    /// <summary><paramref name="e"/>'s message for use inside an SDK message — a stand-in when it quotes response input.</summary>
    internal static string MessageOf(Exception e)
    {
        if (IsClean(e))
            return e.Message;
        var quoted = QuotedMessages(e);
        return quoted.Count == 0 ? e.Message : SafeMessage(e, quoted);
    }

    private static bool IsClean(Exception e) => e is KeycloakException || e.Data.Contains(SanitizedKey);

    // The measured quoting families. HttpRequestError.InvalidResponse is what SocketsHttpHandler tags every
    // malformed-response error with — the ones that quote and the ones that do not.
    private static bool QuotesInput(Exception e) => e is JsonException
        or HttpRequestException { HttpRequestError: HttpRequestError.InvalidResponse }
        or HttpIOException { HttpRequestError: HttpRequestError.InvalidResponse };

    private static List<string> QuotedMessages(Exception e)
    {
        var quoted = new List<string>();
        Exception? x = e;
        for (var depth = 0; x is not null && !IsClean(x) && depth < MaxDepth; x = x.InnerException, depth++)
        {
            if (QuotesInput(x))
                quoted.Add(x.Message);
        }
        return quoted;
    }

    // quoted: messages of the quoting exceptions in the chain; null withholds every message.
    private static string SafeMessage(Exception e, List<string>? quoted)
    {
        if (e is JsonException j)
            return $"invalid JSON (input withheld). LineNumber: {j.LineNumber} | BytePositionInLine: {j.BytePositionInLine}.";
        if (QuotesInput(e))
            return "invalid HTTP response (input withheld)";
        if (quoted is null)
            return "message withheld: raised while reading the response";
        // A lower error that repeats a quoting inner message in its own (as Logout once did) quotes it too.
        return quoted.Exists(q => q.Length > 0 && e.Message.Contains(q, StringComparison.Ordinal))
            ? "message withheld: it repeats response input a lower library quoted"
            : e.Message;
    }

    private static Exception Copy(Exception e, List<string>? quoted, int depth)
    {
        var inner = e.InnerException switch
        {
            null => null,
            var i when IsClean(i) => i,
            var i when depth + 1 < MaxDepth => Copy(i, quoted, depth + 1),
            _ => null,
        };
        var message = SafeMessage(e, quoted);
        Exception copy = e switch
        {
            JsonException j => new JsonException(message, null, j.LineNumber, j.BytePositionInLine, inner),
            HttpRequestException h => new HttpRequestException(h.HttpRequestError, message, inner, h.StatusCode),
            HttpIOException io => new HttpIOException(io.HttpRequestError, message, inner),
            _ => new SanitizedException(e, message, inner),
        };
        copy.Data[SanitizedKey] = true;
        return copy;
    }
}

/// <summary>
/// Stand-in for a lower-library exception in an SDK error's chain that had to be copied (see <see cref="ErrorCause"/>):
/// its type name, a message that quotes no response input, and its stack trace text — never its fields.
/// </summary>
internal sealed class SanitizedException : Exception
{
    private readonly string? _stackTrace;

    internal SanitizedException(Exception original, string message, Exception? inner)
        : base($"{original.GetType().FullName}: {message}", inner)
        => _stackTrace = original.StackTrace;

    public override string? StackTrace => _stackTrace;
}
