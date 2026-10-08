using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.Configuration;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// A configuration past its 12-hour refresh and an IdP that is down: at most one refresh attempt reaches the IdP per
/// failure-backoff window, and the stale keys keep validating meanwhile.
/// </summary>
/// <remarks>
/// <para>Measured before the fix (2026-10-09, IdentityModel 8.23.0, out-of-process probe against a fake IdP): ten
/// validations 300 ms apart, alternating a valid kid and a forged kid, took discovery 1→11 and /certs 1→11. IdentityModel
/// refreshes a stale configuration in the background and moves its next-refresh time only when the refresh succeeds, so
/// after a failure every call starts another refresh. The cold-load backoff (<see cref="BackoffConfigurationManager"/>)
/// never saw those failures: the manager hands back the stale configuration and swallows the refresh error.</para>
/// <para>Staleness without waiting 12 hours: IdentityModel's clock is internal, so the stale configuration is handed in
/// through its public <see cref="IConfigurationEventHandler{T}"/> with a retrieval time 13 hours ago (the 12-hour interval
/// plus at most 36 minutes of IdentityModel's own jitter). Every later fetch goes to the IdP as usual. The backoff clock is
/// the SDK's own seam and stands still unless a test moves it, so "one window" is exact, not a timing guess.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class JwksStaleCacheOutageTests : IDisposable
{
    /// <summary>Where a refresh fails during the outage.</summary>
    public enum Outage
    {
        None,
        Discovery503,
        Certs503,
        /// <summary>A 200 carrying <c>{"keys":[]}</c> — rejected by the configuration validator, so the refresh fails.</summary>
        EmptyKeys,
    }

    private const string Issuer = "http://idp.test/realms/r";
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(10);
    private readonly RsaSecurityKey _k1 = new(RSA.Create(2048)) { KeyId = "k1" };
    private readonly RsaSecurityKey _k2 = new(RSA.Create(2048)) { KeyId = "k2" };
    private readonly RSA _attacker = RSA.Create(2048);
    private readonly Idp _idp;
    private readonly HttpClient _http;
    private readonly FakeClock _clock = new();

    public JwksStaleCacheOutageTests()
    {
        _idp = new Idp(KeySet(_k1));
        _http = new HttpClient(_idp);
    }

    public void Dispose()
    {
        _http.Dispose();
        _k1.Rsa?.Dispose();
        _k2.Rsa?.Dispose();
        _attacker.Dispose();
    }

    [Theory]
    [InlineData(Outage.Discovery503)]
    [InlineData(Outage.Certs503)]
    [InlineData(Outage.EmptyKeys)]
    public async Task Stale_cache_during_an_outage_reaches_the_IdP_once_per_backoff_window(Outage outage)
    {
        var events = await LoadedThirteenHoursAgoAsync();
        var v = Validator(events);
        var valid = Token(_k1, "u1");
        Assert.True(await AcceptsAsync(v, valid)); // the stale configuration is installed and served
        var before = _idp.Discovery; // every attempt starts with discovery
        _idp.Outage = outage;

        // Window 1. The first stale refresh reaches the IdP and fails ...
        await KeepValidatingUntilAsync(v, valid, () => _idp.Discovery > before);
        // ... and with the backoff clock standing still nothing else may reach it — valid and forged kids alike.
        var accepted = 0;
        for (var i = 0; i < 10; i++)
        {
            if (await AcceptsAsync(v, i % 2 == 0 ? valid : Forged(i)))
                accepted++;
            await Task.Delay(20); // room for a background refresh to land — before the fix each validation started one
        }
        Assert.Equal(before + 1, _idp.Discovery);
        Assert.Equal(5, accepted); // acceptance unchanged: every valid kid accepted, every forged kid rejected

        // Window 2 opens once the first has passed (base 0.2 s × jitter 1.0): exactly one more attempt, then quiet again.
        _clock.Advance(BackoffConfigurationManager.BackoffBase);
        await KeepValidatingUntilAsync(v, valid, () => _idp.Discovery > before + 1);
        for (var i = 0; i < 10; i++)
        {
            Assert.True(await AcceptsAsync(v, valid));
            await Task.Delay(20);
        }
        Assert.Equal(before + 2, _idp.Discovery);

        // Recovery. The IdP rotated k2 in while it was down; the first refresh after the window installs it.
        _idp.Outage = Outage.None;
        _idp.Jwks = KeySet(_k1, _k2);
        _clock.Advance(TimeSpan.FromSeconds(1)); // past the second window (0.4 s)
        await KeepValidatingUntilAsync(v, valid, () => events.LatestHas("k2"));
        Assert.True(await AcceptsAsync(v, Token(_k2, "u2")));
        Assert.Equal(before + 3, _idp.Discovery);

        // Fresh again: nothing more reaches the IdP.
        for (var i = 0; i < 5; i++)
            Assert.True(await AcceptsAsync(v, valid));
        await Task.Delay(100);
        Assert.Equal(before + 3, _idp.Discovery);
    }

    /// <summary>Control: the same stale configuration against a healthy IdP refreshes once and is then fresh. Holds with and
    /// without the fix — without it, a fix that blocked refreshing altogether would pass the outage test.</summary>
    [Fact]
    public async Task Control_a_stale_cache_against_a_healthy_IdP_refreshes_once()
    {
        var events = await LoadedThirteenHoursAgoAsync();
        var v = Validator(events);
        var valid = Token(_k1, "u1");
        Assert.True(await AcceptsAsync(v, valid));
        var before = _idp.Discovery;
        _idp.Jwks = KeySet(_k1, _k2);

        await KeepValidatingUntilAsync(v, valid, () => events.LatestHas("k2"));
        for (var i = 0; i < 10; i++)
        {
            Assert.True(await AcceptsAsync(v, valid));
            await Task.Delay(20);
        }

        Assert.Equal(before + 1, _idp.Discovery);
        Assert.True(await AcceptsAsync(v, Token(_k2, "u2")));
    }

    /// <summary>Control: the cold-load backoff is unchanged — no configuration yet, IdP down, one attempt per window.</summary>
    [Theory]
    [InlineData(Outage.Discovery503)]
    [InlineData(Outage.Certs503)]
    [InlineData(Outage.EmptyKeys)]
    public async Task Control_a_cold_cache_during_an_outage_backs_off_as_before(Outage outage)
    {
        _idp.Outage = outage;
        var v = Validator(null);
        var valid = Token(_k1, "u1");

        for (var i = 0; i < 10; i++)
            Assert.False(await AcceptsAsync(v, valid)); // no keys at all: nothing validates
        Assert.Equal(1, _idp.Discovery);

        _clock.Advance(BackoffConfigurationManager.BackoffBase);
        Assert.False(await AcceptsAsync(v, valid));
        Assert.Equal(2, _idp.Discovery);

        _idp.Outage = Outage.None;
        _clock.Advance(TimeSpan.FromSeconds(1));
        Assert.True(await AcceptsAsync(v, valid));
        Assert.Equal(3, _idp.Discovery);
    }

    /// <summary>
    /// Concurrent validations on a cold cache queue behind IdentityModel's first-load lock, all of them past the
    /// manager-level gate before the first failure is recorded. Each queued one used to fetch again in turn.
    /// </summary>
    /// <remarks>The second half pins that the refused ones are not counted as failures: one failure leaves the base
    /// window, twenty would leave the 5 s cap and refuse the retry below.</remarks>
    [Fact]
    public async Task Cold_cache_concurrent_validations_during_an_outage_reach_the_IdP_once()
    {
        _idp.Outage = Outage.Discovery503;
        _idp.Hold();
        var v = Validator(null);
        var valid = Token(_k1, "u1");

        // Each call runs synchronously up to the held IdP (the first) or the first-load lock (the rest).
        var calls = Enumerable.Range(0, 20).Select(_ => AcceptsAsync(v, valid)).ToArray();
        _idp.Release();

        Assert.All(await Task.WhenAll(calls), Assert.False);
        Assert.Equal(1, _idp.Discovery);

        _clock.Advance(BackoffConfigurationManager.BackoffBase);
        Assert.False(await AcceptsAsync(v, valid));
        Assert.Equal(2, _idp.Discovery);
    }

    /// <summary>Control: forged kids against a fresh configuration — the bad-signature refresh documented in
    /// <c>.claude/rules/dotnet.md</c> (one extra fetch, then <c>RefreshInterval</c> holds the rest), healthy or down.</summary>
    [Theory]
    [InlineData(Outage.None)]
    [InlineData(Outage.Certs503)]
    public async Task Control_a_forged_kid_flood_on_a_fresh_cache_behaves_as_before(Outage outage)
    {
        var v = Validator(null);
        var valid = Token(_k1, "u1");
        Assert.True(await AcceptsAsync(v, valid)); // cold load: attempt 1
        _idp.Outage = outage;

        for (var i = 0; i < 10; i++)
        {
            Assert.False(await AcceptsAsync(v, Forged(i)));
            await Task.Delay(20);
        }
        await WaitUntilAsync(() => _idp.Discovery >= 2);
        await Task.Delay(100);

        Assert.Equal(2, _idp.Discovery);
        Assert.True(await AcceptsAsync(v, valid));
    }

    private JwtValidator Validator(IConfigurationEventHandler<OpenIdConnectConfiguration>? events) =>
        new(Issuer, new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "c" } }, _http, _clock.Read, () => 1.0, events);

    /// <summary>The IdP's configuration as fetched now, handed to the manager as if fetched 13 hours ago.</summary>
    private async Task<LoadedLongAgo> LoadedThirteenHoursAgoAsync()
    {
        var config = await OpenIdConnectConfigurationRetriever.GetAsync(
            $"{Issuer}/.well-known/openid-configuration",
            new HttpDocumentRetriever(_http) { RequireHttps = false },
            CancellationToken.None);
        return new LoadedLongAgo(config, DateTimeOffset.UtcNow - TimeSpan.FromHours(13));
    }

    private string Token(RsaSecurityKey key, string sub) => new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(
        $$"""{"iss":"{{Issuer}}","sub":"{{sub}}","aud":"c","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}}""",
        new SigningCredentials(key, SecurityAlgorithms.RsaSha256));

    /// <summary>A well-formed token under a kid the IdP never published.</summary>
    private string Forged(int i) => Token(new RsaSecurityKey(_attacker) { KeyId = $"forged-{i}" }, "attacker");

    private static async Task<bool> AcceptsAsync(JwtValidator v, string token)
    {
        try
        {
            await v.ValidateAsync(token);
            return true;
        }
        catch (KeycloakTokenValidationException)
        {
            return false;
        }
    }

    /// <summary>Background refreshes start from validations and land asynchronously, so keep validating until
    /// <paramref name="done"/> holds — failing the test at the deadline instead of hanging.</summary>
    private static async Task KeepValidatingUntilAsync(JwtValidator v, string token, Func<bool> done)
    {
        var deadline = DateTime.UtcNow + Deadline;
        while (!done())
        {
            Assert.True(DateTime.UtcNow < deadline, "the expected refresh never reached the IdP");
            await AcceptsAsync(v, token);
            await Task.Delay(10);
        }
    }

    private static async Task WaitUntilAsync(Func<bool> done)
    {
        var deadline = DateTime.UtcNow + Deadline;
        while (!done())
        {
            Assert.True(DateTime.UtcNow < deadline, "the expected refresh never reached the IdP");
            await Task.Delay(10);
        }
    }

    private static string KeySet(params RsaSecurityKey[] keys) =>
        $$"""{"keys":[{{string.Join(",", keys.Select(k =>
        {
            var p = k.Rsa!.ExportParameters(false);
            return $$"""{"kty":"RSA","kid":"{{k.KeyId}}","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}""";
        }))}}]}""";

    /// <summary>IdentityModel calls this before every fetch: the first call installs <c>config</c> with the given retrieval
    /// time, every later call lets the fetch go to the IdP. It also hears about every configuration the manager installs.</summary>
    private sealed class LoadedLongAgo(OpenIdConnectConfiguration config, DateTimeOffset retrievedAt)
        : IConfigurationEventHandler<OpenIdConnectConfiguration>
    {
        private int _calls;
        private volatile OpenIdConnectConfiguration? _latest;

        public bool LatestHas(string kid) => _latest?.JsonWebKeySet?.Keys.Any(k => k.Kid == kid) == true;

        public Task<ConfigurationEventHandlerResult<OpenIdConnectConfiguration>> BeforeRetrieveAsync(
            string metadataAddress, CancellationToken cancellationToken = default) =>
            Task.FromResult(Interlocked.Increment(ref _calls) == 1
                ? new ConfigurationEventHandlerResult<OpenIdConnectConfiguration>(config, retrievedAt)
                : ConfigurationEventHandlerResult<OpenIdConnectConfiguration>.NoResult);

        public Task AfterUpdateAsync(
            string metadataAddress, OpenIdConnectConfiguration configuration, CancellationToken cancellationToken = default)
        {
            _latest = configuration;
            return Task.CompletedTask;
        }
    }

    /// <summary>The backoff clock (the SDK's seam). Read from background refreshes, so it is kept in one atomic word.</summary>
    private sealed class FakeClock
    {
        private long _ticks = new DateTimeOffset(2026, 10, 9, 12, 0, 0, TimeSpan.Zero).UtcTicks;

        public DateTimeOffset Read() => new(Interlocked.Read(ref _ticks), TimeSpan.Zero);

        public void Advance(TimeSpan by) => Interlocked.Add(ref _ticks, by.Ticks);
    }

    /// <summary>The IdP, in process: counts discovery and JWKS requests and fails where <see cref="Outage"/> says.</summary>
    private sealed class Idp(string jwks) : HttpMessageHandler
    {
        private int _discovery;
        private int _certs;
        private volatile string _jwks = jwks;
        private volatile Outage _outage = Outage.None;
        private volatile TaskCompletionSource _held = Released();

        public int Discovery => Volatile.Read(ref _discovery);

        public int Certs => Volatile.Read(ref _certs);

        public string Jwks
        {
            set => _jwks = value;
        }

        public Outage Outage
        {
            set => _outage = value;
        }

        /// <summary>Discovery requests wait until <see cref="Release"/>.</summary>
        public void Hold() => _held = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        public void Release() => _held.TrySetResult();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("/.well-known/openid-configuration", StringComparison.Ordinal))
            {
                Interlocked.Increment(ref _discovery);
                await _held.Task;
                return _outage == Outage.Discovery503
                    ? Unavailable()
                    : Json($$"""{"issuer":"{{Issuer}}","jwks_uri":"{{Issuer}}/protocol/openid-connect/certs"}""");
            }

            Interlocked.Increment(ref _certs);
            return _outage switch
            {
                Outage.Certs503 => Unavailable(),
                Outage.EmptyKeys => Json("""{"keys":[]}"""),
                _ => Json(_jwks),
            };
        }

        private static TaskCompletionSource Released()
        {
            var released = new TaskCompletionSource();
            released.SetResult();
            return released;
        }

        private static HttpResponseMessage Json(string body) =>
            new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

        private static HttpResponseMessage Unavailable() =>
            new(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("""{"error":"temporarily_unavailable"}""", Encoding.UTF8, "application/json") };
    }
}
