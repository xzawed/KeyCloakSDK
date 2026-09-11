using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// JWKS/discovery byte cap. Six sibling SDKs already had one; .NET had none — measured 2026-09-11:
/// <c>HttpDocumentRetriever</c> was built with only <c>RequireHttps</c>, and
/// <c>MaxResponseContentBufferSize</c> appeared nowhere under <c>dotnet/src</c>.
/// </summary>
public class BoundedDocumentRetrieverTests : IDisposable
{
    private readonly WireMockServer _server = WireMockServer.Start();
    private readonly HttpClient _http = new();

    public void Dispose()
    {
        _server.Stop();
        _server.Dispose();
        _http.Dispose();
        GC.SuppressFinalize(this);
    }

    private string Url(string path) => $"{_server.Urls[0]}{path}";

    private BoundedDocumentRetriever Retriever(bool requireHttps = false)
        => new(_http, requireHttps);

    /// <summary>
    /// ⚠️ The oversized body must be <b>well-formed</b>. An earlier sibling test filled it with
    /// junk bytes, so the fetch failed on parsing even with no cap — the rejection proved nothing.
    /// Valid JSON plus padding means a missing cap would <b>succeed</b>, so rejection is evidence.
    /// </summary>
    private static string OversizedButValidJson()
        => "{\"keys\":[],\"padding\":\""
           + new string('x', BoundedDocumentRetriever.MaxBytes + 1)
           + "\"}";

    [Fact]
    public async Task Rejects_body_over_the_cap()
    {
        _server.Given(Request.Create().WithPath("/big").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithBody(OversizedButValidJson()));

        var ex = await Assert.ThrowsAsync<IOException>(
            () => Retriever().GetDocumentAsync(Url("/big"), CancellationToken.None));
        Assert.Contains("exceeds", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>⚠️ Control — without this, "rejects everything" would also pass the test above.</summary>
    [Fact]
    public async Task Accepts_body_under_the_cap()
    {
        const string body = "{\"keys\":[]}";
        _server.Given(Request.Create().WithPath("/small").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithBody(body));

        var doc = await Retriever().GetDocumentAsync(Url("/small"), CancellationToken.None);
        Assert.Equal(body, doc);
    }

    /// <summary>
    /// ⚠️ The cap must apply regardless of status. Targeting only 200 lets an error response carry
    /// the oversized body into memory — php shipped exactly that ordering bug.
    /// </summary>
    [Fact]
    public async Task Rejects_oversized_error_response_too()
    {
        _server.Given(Request.Create().WithPath("/big-500").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(500).WithBody(OversizedButValidJson()));

        var ex = await Assert.ThrowsAsync<IOException>(
            () => Retriever().GetDocumentAsync(Url("/big-500"), CancellationToken.None));
        Assert.Contains("exceeds", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>A non-oversized error still fails, and says so by status rather than by size.</summary>
    [Fact]
    public async Task Non_success_status_fails_with_the_status_not_the_cap()
    {
        _server.Given(Request.Create().WithPath("/404").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(404).WithBody("nope"));

        var ex = await Assert.ThrowsAsync<IOException>(
            () => Retriever().GetDocumentAsync(Url("/404"), CancellationToken.None));
        Assert.Contains("404", ex.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("exceeds", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// <c>RequireHttps</c> is the one option this SDK set on the retriever it replaced — losing it
    /// would silently drop a transport guarantee, so it is pinned here.
    /// </summary>
    [Fact]
    public async Task RequireHttps_rejects_a_plain_http_address()
    {
        await Assert.ThrowsAsync<InvalidOperationException>(
            () => Retriever(requireHttps: true)
                .GetDocumentAsync("http://kc.example.com/certs", CancellationToken.None));
    }

    /// <summary>The value is Nimbus's DEFAULT_HTTP_SIZE_LIMIT; five sibling SDKs use the same number.</summary>
    [Fact]
    public void Cap_matches_the_sibling_languages()
        => Assert.Equal(51200, BoundedDocumentRetriever.MaxBytes);
}
