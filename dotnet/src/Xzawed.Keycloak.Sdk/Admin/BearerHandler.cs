using System.Net.Http.Headers;
using System.Text.Json;

namespace Xzawed.Keycloak.Admin;

/// <summary>Attaches a fresh bearer token from the token provider on every admin request.</summary>
internal sealed class BearerHandler : DelegatingHandler
{
    private readonly ITokenProvider _tokenProvider;
    public BearerHandler(ITokenProvider tokenProvider) => _tokenProvider = tokenProvider;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var token = await _tokenProvider.GetAccessTokenAsync(ct).ConfigureAwait(false);
        // Of the control characters, .NET refuses only CR and LF (below). NUL, DEL and the other C0 controls went out on the
        // wire as they came, and only the server stopped them — Keycloak 26.6 answers each with 400 (measured: BearerHeaderCaseTests).
        if (HoldsUnsendableControl(token))
            throw new KeycloakTransportException(UnsendableControlMessage);
        try
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }
        catch (FormatException ex)
        {
            // .NET refuses a CR or LF in a header value right here, before anything is sent — it escaped every admin call
            // raw (measured: BearerHeaderCaseTests). Its message quotes no part of the token. A character past ASCII is
            // refused later, by the transport, as HttpRequestException — already "admin request failed".
            throw new KeycloakTransportException("admin request failed: the access token holds a CR or LF, which an HTTP header cannot carry", ex);
        }
        HttpResponseMessage response;
        try
        {
            response = await base.SendAsync(request, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (IsRefusedBody(ex))
        {
            // Every admin write's body — typed client or raw REST — is serialized here, lazily, inside the transport, and
            // what System.Text.Json refuses to write (a cycle, NaN, a System.Type…) escaped every write raw as its own
            // exception (measured: UnencodableRequestBodyTests). No response was seen.
            throw new KeycloakTransportException(AdminClient.UnencodableBody, ex);
        }
        AdminClient.Observe(response.StatusCode);
        return response;
    }

    private const string UnsendableControlMessage =
        "admin request failed: the access token holds a NUL, DEL or other control character, which an HTTP header cannot carry";

    /// <summary>Whether <paramref name="token"/> holds a character RFC 9110 §5.5 keeps out of a field value — a C0 control
    /// other than HTAB, or DEL — besides CR and LF, which <see cref="AuthenticationHeaderValue"/> refuses itself. HTAB (and
    /// SP) may travel in a field value; Keycloak reads them as part of the token and answers 401.</summary>
    private static bool HoldsUnsendableControl(string token)
    {
        // AsSpan, not the string: a consumer provider that returns null gets an empty span, and its request goes out with a
        // bare "Bearer" as it did before this check (BearerHeaderCaseTests).
        foreach (var c in token.AsSpan())
        {
            if (c is (< ' ' and not '\t' and not '\r' and not '\n') or '\u007F')
                return true;
        }
        return false;
    }

    /// <summary>An exception System.Text.Json threw — inside the transport that is only ever the request body being written.</summary>
    private static bool IsRefusedBody(Exception ex) =>
        ex is JsonException or NotSupportedException or ArgumentException
        && ex.TargetSite?.DeclaringType?.Assembly == typeof(JsonSerializer).Assembly;
}
