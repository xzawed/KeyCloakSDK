namespace Xzawed.Keycloak.Admin;

/// <summary>How much of an admin response the SDK reads — registry <c>admin-response-body-unbounded</c>. A facade write's 2xx
/// body, which no call uses, is not read at all; an error body (status 300 and up) at most <see cref="ErrorBodyMaxBytes"/>, on
/// every admin request, the <c>Raw</c> client's included. Any other success body is read whole — a user list is legitimately
/// large (measured: <c>AdminResponseBodyTests</c>).</summary>
/// <remarks>
/// <para>It runs in <see cref="BearerHandler"/>, where a response arrives with its headers alone: <c>HttpClient</c> buffers the
/// body only after the handler returns (the typed client and the raw path both send with <c>ResponseContentRead</c>), so the
/// body the handler leaves is all there is to buffer.</para>
/// <para>A write is marked, not inferred from its request: <c>Raw</c>'s <c>*WithResponseAsync</c> hands a write's response,
/// body and all, to the consumer. The typed client builds its requests itself, so the mark is an <see cref="AsyncLocal{T}"/>
/// set inside the facade call; it reaches the requests of that call alone. ⚠️ A new facade write goes through
/// <c>AdminClient.WriteTypedAsync</c>, <c>WriteRawAsync</c> or a create helper — any other path reads its 2xx body whole.</para>
/// <para>The body a response replaces is disposed: one read to its end gives its connection back to the pool, one cut short
/// closes it (<c>HttpTransport</c> sets <c>MaxResponseDrainSize</c> to 0). Nothing inflates the bytes counted —
/// <c>AutomaticDecompression</c> is off, and no admin request asks for a content-coding.</para>
/// </remarks>
internal static class AdminResponseBody
{
    /// <summary>The most bytes of an admin error body the SDK keeps — the token-response cap.</summary>
    internal const int ErrorBodyMaxBytes = AuthClient.MaxTokenResponseBytes;

    /// <summary>The first buffer for an error body that announces no length; it doubles up to the cap.</summary>
    private const int FirstBuffer = 16 * 1024;

    private static readonly AsyncLocal<bool> WriteUnread = new();

    /// <summary>Marks the admin requests the current facade call sends as ones whose 2xx body it never reads. Call it inside an
    /// async method: the mark ends with that method.</summary>
    internal static void LeaveUnread() => WriteUnread.Value = true;

    /// <summary>The response with as much of its body as the SDK reads: an error body cut at the cap, a marked write's 2xx body
    /// none, any other body untouched.</summary>
    internal static async Task<HttpResponseMessage> SettleAsync(HttpResponseMessage response, CancellationToken ct)
    {
        if ((int)response.StatusCode >= 300)
            Replace(response, await ReadErrorAsync(response, ct).ConfigureAwait(false));
        else if (WriteUnread.Value)
            Replace(response, ArraySegment<byte>.Empty);
        return response;
    }

    /// <summary>At most <see cref="ErrorBodyMaxBytes"/> of the body. One byte more is asked for, so a body of exactly the cap
    /// is read to its end and keeps its connection.</summary>
    private static async Task<ArraySegment<byte>> ReadErrorAsync(HttpResponseMessage response, CancellationToken ct)
    {
        var read = false;
        try
        {
            var body = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            var length = response.Content.Headers.ContentLength;
            var buffer = new byte[length is >= 0 ? (int)Math.Min(length.Value, ErrorBodyMaxBytes) + 1 : FirstBuffer];
            var count = 0;
            while (count <= ErrorBodyMaxBytes)
            {
                if (count == buffer.Length)
                    Array.Resize(ref buffer, (int)Math.Min(2L * buffer.Length, ErrorBodyMaxBytes + 1L));
                var got = await body.ReadAsync(buffer.AsMemory(count), ct).ConfigureAwait(false);
                if (got == 0)
                    break;
                count += got;
            }
            read = true;
            return new ArraySegment<byte>(buffer, 0, Math.Min(count, ErrorBodyMaxBytes));
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            // What HttpContent makes of the same failure when HttpClient buffers a body itself — "admin request failed".
            throw new HttpRequestException("the admin error response body could not be read", e);
        }
        finally
        {
            if (!read)
                response.Dispose();
        }
    }

    /// <summary>Puts <paramref name="kept"/> in place of the response's body, with that body's headers but its length, and
    /// disposes the body it replaces.</summary>
    private static void Replace(HttpResponseMessage response, ArraySegment<byte> kept)
    {
        var original = response.Content;
        var content = new ByteArrayContent(kept.Array!, kept.Offset, kept.Count);
        foreach (var header in original.Headers.NonValidated)
        {
            if (!header.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                content.Headers.TryAddWithoutValidation(header.Key, header.Value);
        }
        response.Content = content;
        original.Dispose();
    }
}
