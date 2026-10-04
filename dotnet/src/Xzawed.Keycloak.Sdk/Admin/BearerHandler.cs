using System.Net.Http.Headers;

namespace Xzawed.Keycloak.Admin;

/// <summary>Attaches a fresh bearer token from the token provider on every admin request.</summary>
internal sealed class BearerHandler : DelegatingHandler
{
    private readonly ITokenProvider _tokenProvider;
    public BearerHandler(ITokenProvider tokenProvider) => _tokenProvider = tokenProvider;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var token = await _tokenProvider.GetAccessTokenAsync(ct).ConfigureAwait(false);
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
        var response = await base.SendAsync(request, ct).ConfigureAwait(false);
        AdminClient.Observe(response.StatusCode);
        return response;
    }
}
