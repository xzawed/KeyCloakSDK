using System.Text.Json;
using System.Text.Unicode;
using Duende.IdentityModel.Client;

namespace Xzawed.Keycloak;

/// <summary>What Duende sends every token and introspection request through: the SDK's <see cref="HttpClient"/>, handing back
/// only a response that arrived in full, to be read as UTF-8 — registry <c>token-response-class-divergent</c> (decisions D1
/// and D2).</summary>
/// <remarks>
/// <para><b>Arrived in full.</b> The client buffers a response before <c>SendAsync</c> returns
/// (<see cref="HttpCompletionOption.ResponseContentRead"/>), so a response it hands back arrived whole: a body cut short, one
/// over the 1,048,576-byte cap and broken framing all make <c>SendAsync</c> throw first, which Duende reports with no
/// <see cref="ProtocolResponse.HttpResponse"/> — a <see cref="KeycloakTransportException"/>. What is refused after that is
/// a <see cref="KeycloakAuthException"/> (<see cref="TokenResponseVerdict"/>).</para>
/// <para><b>D1 — a 2xx body is UTF-8</b> (RFC 8259 §8.1), checked on its raw bytes. Duende reads the body with
/// <see cref="HttpContent.ReadAsStringAsync()"/>, which turns a sequence that is not UTF-8 into U+FFFD without an error: the
/// grants returned an access token, and introspection claims, the IdP never sent (measured 2026-11-10). An error status is
/// judged by its status, so its body is not checked.</para>
/// <para><b>D2 — the body is read as UTF-8 whatever <c>charset</c> the <c>Content-Type</c> names</b>: these responses are JSON
/// (RFC 6749 §5.1, RFC 7662 §2.2), and a charset parameter has no effect on JSON (RFC 8259 §11). .NET honoured it — an unknown
/// name failed the read, and a usable token labelled <c>charset=x-no-such-charset</c> was a
/// <see cref="KeycloakTransportException"/> (measured 2026-11-10).</para>
/// <para>It replaces <see cref="HttpMessageInvoker.SendAsync"/> rather than wrapping a handler: the base's send logs a request
/// no <see cref="HttpClient"/> has sent yet to System.Net.Http's telemetry, and the client then logs it again — every token
/// request counted twice (measured on the first cut: <c>TokenResponseClassTests</c>).</para>
/// </remarks>
internal sealed class TokenEndpointInvoker : HttpMessageInvoker
{
    private readonly HttpClient _http;

    /// <param name="http">The client the request goes out on — it applies the timeout and the response cap.</param>
    internal TokenEndpointInvoker(HttpClient http) : base(Unused.Handler, disposeHandler: false) => _http = http;

    public override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        try
        {
            if (response.IsSuccessStatusCode
                && !Utf8.IsValid(await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false)))
            {
                throw new TokenResponseNotUtf8Exception();
            }
            ResponseCharset.ReadAsUtf8(response.Content.Headers);
            return response;
        }
        catch
        {
            response.Dispose();
            throw;
        }
    }

    /// <summary>The handler the base requires. Nothing calls it: <see cref="SendAsync"/> replaces the base's one path to it, and
    /// Duende sends through that path alone.</summary>
    private sealed class Unused : HttpMessageHandler
    {
        internal static readonly Unused Handler = new();

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new NotSupportedException("token requests go out through the SDK's HttpClient");
    }
}

/// <summary>Thrown inside Duende's send for a 2xx token or introspection body that is not UTF-8. Duende keeps it as the
/// response's <see cref="ProtocolResponse.Exception"/>, and <see cref="TokenResponseVerdict.Unread"/> turns it into a
/// <see cref="KeycloakAuthException"/>. It carries nothing from the body.</summary>
internal sealed class TokenResponseNotUtf8Exception : Exception
{
    public TokenResponseNotUtf8Exception() : base("token response is not valid UTF-8") { }
}

/// <summary>The verdicts on a token or introspection response that need more than its status.</summary>
internal static class TokenResponseVerdict
{
    /// <summary>The SDK error for a response Duende reports as an exception. One that arrived in full (it has an
    /// <see cref="ProtocolResponse.HttpResponse"/> — see <see cref="TokenEndpointInvoker"/>) but could not be used is a
    /// <see cref="KeycloakAuthException"/>: a body that is not UTF-8, or one Duende could not parse as JSON. One that did not
    /// arrive is a <see cref="KeycloakTransportException"/>.</summary>
    /// <remarks>The parse failure's chain is attached with every message withheld — <c>System.Text.Json</c> quotes the body it
    /// failed on (<see cref="ErrorCause"/>). The status is named in the message; the body never is.</remarks>
    internal static KeycloakException Unread(ProtocolResponse response, string failureMessage, string transportMessage) => response switch
    {
        { Exception: TokenResponseNotUtf8Exception } => new KeycloakAuthException($"{failureMessage}: response is not valid UTF-8"),
        { HttpResponse: { } arrived, Exception: { } unread } => new KeycloakAuthException(
            $"{failureMessage}: response body could not be parsed as JSON (HTTP {(int)arrived.StatusCode})", ErrorCause.WithholdAll(unread)),
        _ => new KeycloakTransportException(transportMessage, response.Exception),
    };

    /// <summary>An introspection response's <c>active</c> — REQUIRED and a JSON boolean (RFC 7662 §2.2). A response without
    /// one is broken, not inactive: it fails with <see cref="KeycloakAuthException"/> (decision D3 — Duende read it as
    /// <c>false</c>).</summary>
    internal static bool Active(JsonElement? json) =>
        json is { ValueKind: JsonValueKind.Object } body && body.TryGetProperty("active", out var active)
            && active.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? active.GetBoolean()
            : throw new KeycloakAuthException("Token introspection failed: response has no boolean active");
}
