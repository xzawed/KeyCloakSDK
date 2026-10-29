using System.Net.Http.Headers;
using System.Text.Json;

namespace Xzawed.Keycloak.Admin;

/// <summary>Attaches a fresh bearer token from the token provider on every admin request — under the bearer grammar
/// (<see cref="BearerToken.Sendable"/>) — and settles how much of each response body is read
/// (<see cref="AdminResponseBody"/>).</summary>
internal sealed class BearerHandler : DelegatingHandler
{
    private readonly ITokenProvider _tokenProvider;
    public BearerHandler(ITokenProvider tokenProvider) => _tokenProvider = tokenProvider;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        // Before the token provider runs: an admin request it sends meanwhile is its own, not this write's.
        var unread = AdminResponseBody.TakeUnread();
        string token;
        try
        {
            token = await _tokenProvider.GetAccessTokenAsync(ct).ConfigureAwait(false);
        }
        catch
        {
            // The provider's failure is its own: the call ends in it unchanged, as the warm-up in AdminClient.CreateAsync does.
            AdminClient.ObserveTokenProviderFailure();
            throw;
        }
        // The one bearer grammar, on every admin path — typed, raw REST and Raw — before anything is sent. Left to itself .NET
        // refuses only CR and LF (FormatException): NUL and DEL went out (BearerHeaderCaseTests), and so did SP, HTAB, "="
        // mid-token and an empty token, while a character past ASCII reached Raw as a raw HttpRequestException
        // (BearerTokenGrammarTests).
        var bearer = BearerToken.Sendable(token) ?? throw new KeycloakTransportException(BearerToken.SendRefused);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearer);
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
        return await AdminResponseBody.SettleAsync(response, unread, ct).ConfigureAwait(false);
    }

    /// <summary>An exception System.Text.Json threw — inside the transport that is only ever the request body being written.</summary>
    private static bool IsRefusedBody(Exception ex) =>
        ex is JsonException or NotSupportedException or ArgumentException
        && ex.TargetSite?.DeclaringType?.Assembly == typeof(JsonSerializer).Assembly;
}
