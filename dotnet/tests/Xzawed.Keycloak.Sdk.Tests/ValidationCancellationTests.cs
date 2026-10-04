using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// Validation honours its <see cref="CancellationToken"/> — <see cref="OperationCanceledException"/>, as .NET expects.
/// </summary>
/// <remarks>
/// <para>Measured before the fix (2026-10-05, cold cache, JWKS slowed to 2 s): <c>ValidateAsync(token, ct)</c> dropped the
/// token — "cold, CancelAfter 300 ms: ACCEPTED sub=u1 | call_ms=2117 token_cancelled=True" and "cold, already cancelled:
/// ACCEPTED sub=u1 | call_ms=2004 token_cancelled=True". <c>ValidateForAudienceAsync</c> (the id_token check inside
/// <c>ExchangeCodeAsync</c>) dropped it the same way. IdentityModel's <c>ValidateTokenAsync</c> takes no token at all.</para>
/// <para>What cancellation must not do is waste the JWKS refetch window — it cannot: IdentityModel runs the refetch as a
/// detached task on <c>CancellationToken.None</c> (measured: it reached the IdP after an already-cancelled call returned).
/// Cancelling stops the caller's wait; a fetch already started still lands in the cache.</para>
/// <para>No wall clock decides these tests: the IdP is an in-process handler that holds discovery until the test releases
/// it, and the cancellation is issued after the request has arrived. The 10-second bound only turns a hang into a
/// failure.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class ValidationCancellationTests : IDisposable
{
    private const string Issuer = "http://idp.test/realms/r";
    private static readonly TimeSpan Hang = TimeSpan.FromSeconds(10);
    private readonly RsaSecurityKey _key = new(RSA.Create(2048)) { KeyId = "k1" };
    private readonly Idp _idp;
    private readonly HttpClient _http;

    public ValidationCancellationTests()
    {
        _idp = new Idp(_key);
        _http = new HttpClient(_idp);
    }

    public void Dispose()
    {
        _idp.Release();
        _http.Dispose();
        _key.Rsa?.Dispose();
    }

    private JwtValidator Validator() =>
        new(Issuer, new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "c" } }, _http);

    private AuthClient Auth()
    {
        var cfg = new KeycloakConfig { ServerUrl = "http://idp.test", Realm = "r", ClientId = "c", ClientSecret = "s" }.Normalized();
        return new AuthClient(cfg, OidcEndpoints.For(cfg.ServerUrl, cfg.Realm), Validator(), _http);
    }

    private string Token(string extra = "") => new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(
        $$"""{"iss":"{{Issuer}}","sub":"u1","aud":"c","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}{{extra}}}""",
        new SigningCredentials(_key, SecurityAlgorithms.RsaSha256));

    /// <summary>An already-cancelled token ends the call before IdentityModel runs — no discovery, no JWKS, so the call
    /// cannot start a refetch (or stamp the refetch window) for a caller that has gone.</summary>
    [Fact]
    public async Task An_already_cancelled_token_ends_validation_before_any_request()
    {
        _idp.Release(); // nothing is held: without the fix the validation would simply succeed
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Validator().ValidateAsync(Token(), cts.Token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Auth().ValidateAsync(Token(), cts.Token));

        Assert.Equal(0, _idp.Requests);
    }

    /// <summary>A token cancelled while validation waits on the IdP ends the wait.</summary>
    [Fact]
    public async Task Cancelling_while_validation_waits_on_the_IdP_ends_it()
    {
        using var cts = new CancellationTokenSource();
        var call = Validator().ValidateAsync(Token(), cts.Token);
        await _idp.DiscoveryArrived.WaitAsync(Hang);

        cts.Cancel();

        var ex = await Ended(call);
        Assert.IsAssignableFrom<OperationCanceledException>(ex);
        Assert.Equal(cts.Token, ((OperationCanceledException)ex).CancellationToken);
    }

    /// <summary>The id_token check inside the code exchange honours the token too (<c>ValidateForAudienceAsync</c>).</summary>
    [Fact]
    public async Task Cancelling_during_the_id_token_check_ends_ExchangeCodeAsync()
    {
        _idp.IdToken = Token(""","nonce":"n1" """);
        using var cts = new CancellationTokenSource();
        var call = Auth().ExchangeCodeAsync("code", "https://app/cb", new string('v', 43), "n1", cts.Token);
        await _idp.DiscoveryArrived.WaitAsync(Hang);

        cts.Cancel();

        Assert.IsAssignableFrom<OperationCanceledException>(await Ended(call));
        Assert.Equal(1, _idp.TokenRequests); // the grant itself went through; the cancellation landed in the id_token check
    }

    /// <summary>Without cancellation the same validation still succeeds once the IdP answers — the control.</summary>
    [Fact]
    public async Task Control_an_uncancelled_validation_completes_when_the_IdP_answers()
    {
        using var cts = new CancellationTokenSource();
        var call = Validator().ValidateAsync(Token(), cts.Token);
        await _idp.DiscoveryArrived.WaitAsync(Hang);

        _idp.Release();

        Assert.Equal("u1", (await call.WaitAsync(Hang)).Subject);
    }

    /// <summary>The exception the call ended with — failing the test if it is still running after <see cref="Hang"/>.</summary>
    private static async Task<Exception> Ended(Task call)
    {
        var finished = await Task.WhenAny(call, Task.Delay(Hang));
        Assert.True(finished == call, "validation did not end after its token was cancelled — it waits for the IdP regardless");
        var ex = await Record.ExceptionAsync(() => call);
        Assert.NotNull(ex);
        return ex!;
    }

    /// <summary>The IdP: discovery waits for <see cref="Release"/>; JWKS and the token endpoint answer at once.</summary>
    private sealed class Idp : HttpMessageHandler
    {
        private readonly TaskCompletionSource _release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _discoveryArrived = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly string _jwks;
        private int _requests;
        private int _tokenRequests;

        public Idp(RsaSecurityKey key)
        {
            var p = key.Rsa!.ExportParameters(false);
            _jwks = $$"""{"keys":[{"kty":"RSA","kid":"k1","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}]}""";
        }

        public string? IdToken { get; set; }

        public int Requests => Volatile.Read(ref _requests);

        public int TokenRequests => Volatile.Read(ref _tokenRequests);

        public Task DiscoveryArrived => _discoveryArrived.Task;

        public void Release() => _release.TrySetResult();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref _requests);
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("/.well-known/openid-configuration", StringComparison.Ordinal))
            {
                _discoveryArrived.TrySetResult();
                await _release.Task;
                return Json($$"""{"issuer":"{{Issuer}}","jwks_uri":"{{Issuer}}/protocol/openid-connect/certs"}""");
            }
            if (path.EndsWith("/certs", StringComparison.Ordinal))
                return Json(_jwks);
            Interlocked.Increment(ref _tokenRequests);
            return Json($$"""{"access_token":"at","token_type":"Bearer","expires_in":300,"id_token":"{{IdToken}}"}""");
        }

        private static HttpResponseMessage Json(string body) =>
            new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    }
}
