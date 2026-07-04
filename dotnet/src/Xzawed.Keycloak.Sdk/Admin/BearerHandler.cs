using System.Net.Http.Headers;

namespace Xzawed.Keycloak.Admin;

/// <summary>Attaches a fresh bearer token from the token provider on every admin request.</summary>
internal sealed class BearerHandler : DelegatingHandler
{
    private readonly ITokenProvider _tokenProvider;
    public BearerHandler(ITokenProvider tokenProvider) => _tokenProvider = tokenProvider;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _tokenProvider.GetAccessTokenAsync(ct).ConfigureAwait(false));
        return await base.SendAsync(request, ct).ConfigureAwait(false);
    }
}
