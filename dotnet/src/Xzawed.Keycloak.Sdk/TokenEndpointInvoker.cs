using System.Text.Json;
using System.Text.Unicode;
using Duende.IdentityModel.Client;

namespace Xzawed.Keycloak;

/// <summary>What Duende sends every token and introspection request through: the SDK's <see cref="HttpClient"/>, handing back
/// only a response that arrived in full, to be read as UTF-8 — registry <c>token-response-class-divergent</c> (decisions D1
/// and D2).</summary>
/// <remarks>
/// <para><b>Arrived in full.</b> The client buffers a response before <c>SendAsync</c> returns
/// (<see cref="HttpCompletionOption.ResponseContentRead"/>), so a response it hands back arrived whole: a body with a declared
/// length (<c>Content-Length</c> or chunked) cut short, one over the 1,048,576-byte cap and broken framing all make
/// <c>SendAsync</c> throw first, which Duende reports with no <see cref="ProtocolResponse.HttpResponse"/> — a
/// <see cref="KeycloakTransportException"/>. What is refused after that is a <see cref="KeycloakAuthException"/>
/// (<see cref="TokenResponseVerdict"/>). ⚠️ A body with no declared length ends where the server closes the connection
/// (RFC 9112 §6.3), so one cut short cannot be told from a whole one: it is judged as arrived (<c>TokenResponseClassTests</c>,
/// the close-delimited cell). Keycloak always declares the length.</para>
/// <para>That a response arrived is also recorded on the request (<see cref="ResponseArrival"/>), for the failures Duende
/// raises only after this send returned.</para>
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
        ResponseArrival.Record(request, response);
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

/// <summary>Whether a token or introspection request got a response, and its status — recorded by
/// <see cref="TokenEndpointInvoker"/> once the response arrived in full, read by <c>AuthClient</c> when Duende then fails while
/// reading it.</summary>
/// <remarks>Duende sends a clone of the request it is given, and the clone carries the original's
/// <see cref="HttpRequestMessage.Options"/> entries by reference (<c>ProtocolRequest.Clone</c>) — so this object, put there
/// before the call, is what the invoker writes to. A flag set on the clone would never reach the caller.</remarks>
internal sealed class ResponseArrival
{
    private static readonly HttpRequestOptionsKey<ResponseArrival> Key = new("Xzawed.Keycloak.ResponseArrival");

    private ResponseArrival() { }

    /// <summary>The status of the response that arrived; 0 while none has.</summary>
    internal int Status { get; private set; }

    /// <summary>A new record, carried by <paramref name="request"/> to whatever sends it.</summary>
    internal static ResponseArrival On(HttpRequestMessage request)
    {
        var arrival = new ResponseArrival();
        request.Options.Set(Key, arrival);
        return arrival;
    }

    /// <summary>Records that <paramref name="request"/> got <paramref name="response"/>.</summary>
    internal static void Record(HttpRequestMessage request, HttpResponseMessage response)
    {
        if (request.Options.TryGetValue(Key, out var arrival))
            arrival.Status = (int)response.StatusCode;
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

    /// <summary>The SDK error for <paramref name="ex"/>, thrown by Duende while it read a response that arrived — a value in the
    /// body it could not convert — or null when no response arrived or <paramref name="ex"/> is no such failure.</summary>
    /// <remarks>Duende's <c>TokenIntrospectionResponse</c> reads <c>exp</c>, <c>iat</c> and <c>nbf</c> with <c>long.Parse</c> and
    /// <c>DateTimeOffset.FromUnixTimeSeconds</c>, and a JWT response's payload with Base64Url and <c>JsonDocument</c>: a word, a
    /// fraction, a number past <see cref="long"/> or past year 9999, or a payload that is not base64url or not JSON threw
    /// <see cref="FormatException"/>, <see cref="OverflowException"/>, <see cref="ArgumentOutOfRangeException"/> or
    /// <see cref="JsonException"/> out of the SDK raw — the last quoting the payload (review leg, measured 2026-11-10). A
    /// request Duende could not build throws a <see cref="FormatException"/> too (an address it will not parse), so only an
    /// arrived response is converted (<see cref="ResponseArrival"/>). Every message in the chain is withheld; the status is
    /// named.</remarks>
    internal static KeycloakAuthException? Unconverted(Exception ex, ResponseArrival arrival, string failureMessage) =>
        arrival.Status != 0 && ex is FormatException or OverflowException or ArgumentOutOfRangeException or JsonException
            ? new KeycloakAuthException(
                $"{failureMessage}: response body holds a value that could not be converted (HTTP {arrival.Status})", ErrorCause.WithholdAll(ex))
            : null;

    /// <summary>An introspection response's <c>active</c> — REQUIRED and a JSON boolean (RFC 7662 §2.2). A response without
    /// one is broken, not inactive: it fails with <see cref="KeycloakAuthException"/> (decision D3 — Duende read it as
    /// <c>false</c>).</summary>
    internal static bool Active(JsonElement? json) =>
        json is { ValueKind: JsonValueKind.Object } body && body.TryGetProperty("active", out var active)
            && active.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? active.GetBoolean()
            : throw new KeycloakAuthException("Token introspection failed: response has no boolean active");

    /// <summary>Where <paramref name="json"/> holds a string System.Text.Json will not decode — a member name or a string
    /// value, at any depth: the top-level member's name when its value is the one and that name is in <paramref name="named"/>,
    /// an empty string anywhere else, null when every string decodes.</summary>
    /// <remarks>The grammar carries an unpaired UTF-16 surrogate escape (<c>\ud800</c> — RFC 8259 §8.2) and System.Text.Json
    /// parses it, but decoding it throws <see cref="InvalidOperationException"/>: <c>GetString</c> on a value, and
    /// <c>TryGetProperty</c> on every member name it passes — so one such name made Duende's getters throw out of the SDK raw
    /// (measured 2026-11-11, residue premise). The body is unusable as a whole: a value outside the members the SDK reads
    /// reached the caller in four other languages only to be sent back mutated (<c>U+FFFD</c>, <c>?</c>) or to fail as a
    /// transport error. A name returned is the caller's, never the server's.</remarks>
    internal static string? Undecodable(JsonElement? json, ICollection<string> named)
    {
        if (json is not { ValueKind: JsonValueKind.Object } body)
            return json is { } other && !Decodes(other) ? "" : null;
        foreach (var member in body.EnumerateObject())
        {
            if (!TryName(member, out var name))
                return "";
            if (!Decodes(member.Value))
                return named.Contains(name) ? name : "";
        }
        return null;
    }

    private static bool Decodes(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => TryString(value),
        JsonValueKind.Array => value.EnumerateArray().All(Decodes),
        JsonValueKind.Object => value.EnumerateObject().All(m => TryName(m, out _) && Decodes(m.Value)),
        _ => true,
    };

    private static bool TryName(JsonProperty member, out string name)
    {
        try
        {
            name = member.Name;
            return true;
        }
        catch (InvalidOperationException)
        {
            name = "";
            return false;
        }
    }

    private static bool TryString(JsonElement value)
    {
        try
        {
            _ = value.GetString();
            return true;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }
}
