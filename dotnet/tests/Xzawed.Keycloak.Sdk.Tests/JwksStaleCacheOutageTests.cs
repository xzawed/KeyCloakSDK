using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// A key set is used for 300 seconds from the fetch that brought it (decision 2026-10-29, nine languages): past that the
/// cache is a cold cache — the next validation fetches in the same call, through the same single flight and failure
/// backoff, and fails if that fetch fails. No stale fallback, not even during an outage. T1–T4 of the change.
/// </summary>
/// <remarks>
/// <para>Before (IdentityModel 8.23.0, measured 2026-10-09): a configuration past its 12-hour refresh kept validating
/// during an outage — 5/5 valid kids accepted — because IdentityModel's manager hands back the stale configuration and
/// refreshes it in the background; last-known-good would have accepted it for another hour after a failed fetch.</para>
/// <para>The SDK's clock seam drives the lifetime, the failure backoff and the forced-refetch window, and stands still
/// unless a test moves it, so "301 seconds" and "one window" are exact, not timing guesses. Every fetch is a discovery
/// request and a JWKS request.</para>
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

    /// <summary>T1. Healthy IdP: 299 seconds after the load a known kid validates with no fetch; at 301 seconds that
    /// validation itself fetches exactly once and succeeds — not in the background, after it has answered.</summary>
    [Fact]
    public async Task T1_a_known_kid_needs_no_fetch_at_299_seconds_and_exactly_one_in_the_call_at_301()
    {
        var v = Validator();
        var valid = Token(_k1, "u1");
        Assert.True(await AcceptsAsync(v, valid)); // the load — t0
        Assert.Equal((1, 1), (_idp.Discovery, _idp.Certs));

        _clock.Advance(TimeSpan.FromSeconds(299));
        Assert.True(await AcceptsAsync(v, valid));
        Assert.Equal((1, 1), (_idp.Discovery, _idp.Certs));

        _clock.Advance(TimeSpan.FromSeconds(2)); // t0 + 301
        Assert.True(await AcceptsAsync(v, valid));
        Assert.Equal((2, 2), (_idp.Discovery, _idp.Certs)); // read as soon as the call returned: the fetch was in it
        Assert.True(await AcceptsAsync(v, valid));
        Assert.Equal((2, 2), (_idp.Discovery, _idp.Certs));
    }

    /// <summary>T2. An outage once the key set has expired: a known kid is refused after exactly one attempt; inside the
    /// failure backoff nothing reaches the IdP — valid and forged kids alike; once the IdP is back and the window has passed,
    /// the next validation fetches once and succeeds.</summary>
    /// <remarks>Flipped from "the stale keys keep validating" (10 validations, 5 valid kids accepted): keys older than
    /// 300 seconds are never used again, even during an outage.</remarks>
    [Theory]
    [InlineData(Outage.Discovery503)]
    [InlineData(Outage.Certs503)]
    [InlineData(Outage.EmptyKeys)]
    public async Task T2_an_outage_after_the_lifetime_is_refused_one_attempt_per_window_and_recovers(Outage outage)
    {
        var v = Validator();
        var valid = Token(_k1, "u1");
        Assert.True(await AcceptsAsync(v, valid)); // t0
        _idp.Outage = outage;
        _clock.Advance(TimeSpan.FromSeconds(301));

        // Window 1: the first validation after the lifetime makes the one attempt, and is refused ...
        Assert.False(await AcceptsAsync(v, valid));
        Assert.Equal(2, _idp.Discovery); // every attempt starts with discovery
        // ... and with the backoff clock standing still nothing else reaches the IdP.
        var accepted = 0;
        for (var i = 0; i < 10; i++)
        {
            if (await AcceptsAsync(v, i % 2 == 0 ? valid : Forged(i)))
                accepted++;
        }
        Assert.Equal(2, _idp.Discovery);
        Assert.Equal(0, accepted);

        // Window 2 opens once the first has passed (base 0.2 s × jitter 1.0): exactly one more attempt, refused too.
        _clock.Advance(BackoffConfigurationManager.BackoffBase);
        Assert.False(await AcceptsAsync(v, valid));
        Assert.False(await AcceptsAsync(v, valid));
        Assert.Equal(3, _idp.Discovery);

        // Recovery. The IdP rotated k2 in while it was down; the first fetch after the window brings it in.
        _idp.Outage = Outage.None;
        _idp.Jwks = KeySet(_k1, _k2);
        _clock.Advance(TimeSpan.FromSeconds(1)); // past the second window (0.4 s)
        Assert.True(await AcceptsAsync(v, Token(_k2, "u2")));
        Assert.Equal(4, _idp.Discovery);
        for (var i = 0; i < 5; i++)
            Assert.True(await AcceptsAsync(v, valid));
        Assert.Equal(4, _idp.Discovery);
    }

    /// <summary>T3. The IdP withdrew a key: at 301 seconds a token under it is refused after the refetch — the forced one its
    /// unknown kid asks for included, and with no last-known-good fallback to the key set that held it — while a token under
    /// the remaining key validates.</summary>
    [Fact]
    public async Task T3_a_withdrawn_key_is_refused_at_301_seconds_after_the_refetch_and_the_other_validates()
    {
        _idp.Jwks = KeySet(_k1, _k2);
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_k1, "u1"))); // t0 — both keys
        _idp.Jwks = KeySet(_k2); // k1 withdrawn
        _clock.Advance(TimeSpan.FromSeconds(301));

        Assert.False(await AcceptsAsync(v, Token(_k1, "u1")));
        Assert.Equal(3, _idp.Discovery); // the reload, then the refetch its unknown kid asked for
        Assert.True(await AcceptsAsync(v, Token(_k2, "u2")));
        Assert.Equal(3, _idp.Discovery);
    }

    /// <summary>T4. A successful forced refetch replaces the key set and restarts its lifetime: after one at 100 seconds,
    /// nothing is fetched at 350, and the next fetch comes 301 seconds after the refetch.</summary>
    [Fact]
    public async Task T4_a_forced_refetch_restarts_the_lifetime()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_k1, "u1"))); // t0
        _idp.Jwks = KeySet(_k1, _k2); // k2 rotated in
        _clock.Advance(TimeSpan.FromSeconds(100));
        Assert.True(await AcceptsAsync(v, Token(_k2, "u2"))); // unknown kid: a forced refetch, in the call
        Assert.Equal(2, _idp.Discovery);

        _clock.Advance(TimeSpan.FromSeconds(250)); // t0 + 350 — 250 seconds after the refetch
        Assert.True(await AcceptsAsync(v, Token(_k1, "u1")));
        Assert.True(await AcceptsAsync(v, Token(_k2, "u2")));
        Assert.Equal(2, _idp.Discovery);

        _clock.Advance(TimeSpan.FromSeconds(51)); // 301 seconds after the refetch
        Assert.True(await AcceptsAsync(v, Token(_k2, "u2")));
        Assert.Equal(3, _idp.Discovery);
    }

    /// <summary>Validations that meet an expired key set together share one reload, as on a cold cache: each call runs
    /// synchronously up to the held discovery request (the first) or the cold-load lock (the rest).</summary>
    [Fact]
    public async Task Concurrent_validations_after_the_lifetime_share_one_reload()
    {
        var v = Validator();
        var valid = Token(_k1, "u1");
        Assert.True(await AcceptsAsync(v, valid)); // t0
        _clock.Advance(TimeSpan.FromSeconds(301));
        _idp.Hold();

        var calls = Enumerable.Range(0, 20).Select(_ => AcceptsAsync(v, valid)).ToArray();
        _idp.Release();

        Assert.All(await Task.WhenAll(calls), Assert.True);
        Assert.Equal((2, 2), (_idp.Discovery, _idp.Certs));
    }

    /// <summary>Control: the cold-load backoff is unchanged — no configuration yet, IdP down, one attempt per window.</summary>
    [Theory]
    [InlineData(Outage.Discovery503)]
    [InlineData(Outage.Certs503)]
    [InlineData(Outage.EmptyKeys)]
    public async Task Control_a_cold_cache_during_an_outage_backs_off_as_before(Outage outage)
    {
        _idp.Outage = outage;
        var v = Validator();
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
        var v = Validator();
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
        var v = Validator();
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

    private JwtValidator Validator() =>
        new(Issuer, new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "c" } }, _http, _clock.Read, () => 1.0);

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

    /// <summary>The SDK's clock seam — lifetime, backoff and refetch window. Read from more than one thread, so it is kept in
    /// one atomic word.</summary>
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
