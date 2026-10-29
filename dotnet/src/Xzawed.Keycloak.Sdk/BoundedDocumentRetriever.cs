using Microsoft.IdentityModel.Protocols;

namespace Xzawed.Keycloak;

/// <summary>
/// Fetches the OIDC discovery document and the JWKS with a hard byte cap, aborting the read the
/// moment the body exceeds it.
/// </summary>
/// <remarks>
/// <para>
/// Six sibling SDKs cap the JWKS body at 51200 bytes — the value is not ours, it is Nimbus's
/// <c>JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT</c>, which go, rust, php, ruby and node follow.
/// Without a cap a compromised or misbehaving identity provider can exhaust the client's memory
/// through the validation path, which is reachable by any unauthenticated caller holding a token.
/// </para>
/// <para>
/// ⚠️ <b>Measured 2026-09-11:</b> nothing on the .NET side imposed a bound.
/// <c>HttpDocumentRetriever</c> was constructed with only <c>RequireHttps</c> set, and
/// <c>MaxResponseContentBufferSize</c> appeared <b>nowhere</b> under <c>dotnet/src</c>.
/// <c>HttpClient.Timeout</c> is a time bound, not a byte bound. Whether
/// <c>Microsoft.IdentityModel</c> bounds the body internally is <b>unmeasured</b> — it ships as a
/// compiled package — so this type does not rely on it either way. (Since 2026-10-05 the shared client
/// carries <c>MaxResponseContentBufferSize</c> = 1 MiB, the token-response cap; it bounds buffered reads
/// only, so it never reaches this streamed one.)
/// </para>
/// <para>
/// ⚠️ <b>Why not <c>MaxResponseContentBufferSize</c> on the shared client:</b> the
/// <see cref="HttpClient"/> passed here is owned by <c>KeycloakClient</c> and shared with
/// <c>AuthClient</c>, so that property would also bound token, refresh, introspection and logout
/// responses. A Keycloak access token carrying many roles or groups is a legitimately large body
/// and must not be capped by a JWKS defence. This retriever bounds <b>only</b> the documents the
/// <c>ConfigurationManager</c> fetches — discovery and JWKS — while still using the shared,
/// redirect-hardened client.
/// </para>
/// <para>
/// ⚠️ The cap is applied <b>regardless of status code</b>. Targeting only 200 lets an error
/// response carry the oversized body straight into memory — php had exactly that ordering bug.
/// And the read is streamed: judging by <c>Content-Length</c> alone misses a response that omits
/// the header or lies about it.
/// </para>
/// <para>
/// ⚠️ <b>The whole document within the client's timeout, from when the request is sent.</b> With
/// <c>ResponseHeadersRead</c>, <c>HttpClient.Timeout</c> ends when the headers arrive, and the body had no bound at all:
/// IdentityModel asks on <c>CancellationToken.None</c>, and so does the SDK's own refetch (measured: a document trickled
/// over 7 s was accepted, a stalled one held until the server closed — <c>ResponseReadDeadlineTests</c>). The body read
/// takes the rest of a <c>CancelAfter(HttpClient.Timeout)</c> armed as the request is sent, and its expiry raises what that
/// timeout raises for late headers (<see cref="TaskCanceledException"/> over a <see cref="TimeoutException"/>). The deadline
/// is the fetch's own: a caller's token is linked into it, never the reverse, so a refetch on
/// <see cref="CancellationToken.None"/> still runs to completion under the SDK's timeout whatever its caller cancels
/// (<c>.claude/rules/security.md</c>). A client without a timeout gets no deadline.
/// </para>
/// </remarks>
internal sealed class BoundedDocumentRetriever : IDocumentRetriever
{
    /// <summary>Nimbus <c>DEFAULT_HTTP_SIZE_LIMIT</c>; go, rust, php, ruby and node use the same number.</summary>
    internal const int MaxBytes = 51200;

    private readonly HttpClient _http;
    private readonly bool _requireHttps;

    internal BoundedDocumentRetriever(HttpClient http, bool requireHttps)
    {
        _http = http;
        _requireHttps = requireHttps;
    }

    public async Task<string> GetDocumentAsync(string address, CancellationToken cancel)
    {
        if (string.IsNullOrWhiteSpace(address))
        {
            throw new ArgumentNullException(nameof(address));
        }

        // Mirrors HttpDocumentRetriever.RequireHttps, the only option this SDK ever set on it.
        if (_requireHttps && !address.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"The address '{address}' must use HTTPS (RequireHttps is on for this issuer).");
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, address);
        // The deadline: the client's own timeout, armed as the request is sent and carried into the body read (below).
        var timeout = _http.Timeout;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        if (timeout != Timeout.InfiniteTimeSpan)
        {
            deadline.CancelAfter(timeout);
        }

        // ResponseHeadersRead is load-bearing: the default buffers the whole body before returning,
        // which is precisely what the cap exists to prevent. The headers are under HttpClient.Timeout, as before.
        using var response = await _http
            .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel)
            .ConfigureAwait(false);

        string body;
        try
        {
            body = await ReadBoundedAsync(response, deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException e)
        {
            // The caller's own cancellation stays the caller's: the type the read raised before the deadline existed, the
            // caller's token on it, no timeout under it.
            if (cancel.IsCancellationRequested)
            {
                throw new TaskCanceledException(e.Message, e, cancel);
            }

            // The deadline: what HttpClient.Timeout raises for late headers, so whoever converts one converts the other.
            throw new TaskCanceledException(
                $"The request was canceled: the response was not fully read within the configured HttpClient.Timeout of {timeout.TotalSeconds} seconds.",
                new TimeoutException("The response body was still arriving when the client's timeout elapsed."));
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new IOException(
                $"Unable to fetch '{address}': HTTP {(int)response.StatusCode}.");
        }

        return body;
    }

    private static async Task<string> ReadBoundedAsync(
        HttpResponseMessage response, CancellationToken cancel)
    {
        using var stream = await response.Content.ReadAsStreamAsync(cancel).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int read;
        while ((read = await stream.ReadAsync(chunk, cancel).ConfigureAwait(false)) > 0)
        {
            buffer.Write(chunk, 0, read);
            if (buffer.Length > MaxBytes)
            {
                throw new IOException($"Document exceeds {MaxBytes} bytes.");
            }
        }

        return System.Text.Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length);
    }
}
