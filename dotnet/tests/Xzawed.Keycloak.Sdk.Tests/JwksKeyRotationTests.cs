using System.Diagnostics;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;
using Xunit.Abstractions;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// The IdP rotates a signing key in: the first token under it validates in the same call, at the cost of one refetch — and a
/// stream of unknown kids still costs at most one refetch per window (registry <c>wave4-hardening-dotnet</c> (1)).
/// </summary>
/// <remarks>
/// <para>Measured before the fix (2026-10-29, IdentityModel 8.23.0): the first test here failed on the first token under the
/// rotated-in key — IDX10503 (<c>SecurityTokenSignatureKeyNotFoundException</c>) — and a scratch probe through the public
/// constructor saw the next one, 300 ms later, accepted with no further request. On an unresolved kid IdentityModel's
/// handler calls <c>RequestRefresh</c>, then retries only if <c>GetBaseConfigurationAsync</c> hands back a different
/// configuration — and its manager runs the requested refresh in the background (<c>Task.Run</c>), so the call that asked
/// for it still saw the old keys.</para>
/// <para>The IdP is in process and counts its requests. The refetch window and the failure backoff both run on the SDK's
/// clock seam, which stands still unless a test moves it, so "one per window" is exact, not a timing guess. A refetch is a
/// discovery request and a JWKS request, as every IdentityModel fetch is.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class JwksKeyRotationTests : IDisposable
{
    private const string Issuer = "http://idp.test/realms/r";
    private static readonly TimeSpan Hang = TimeSpan.FromSeconds(10);

    /// <summary>How long a validation that must not wait on a held refetch may take before the test calls it waiting. The gate
    /// stays shut until after it, so a validation that did wait never finishes inside any bound — this one only has to be far
    /// above a validation's own cost (measured 2026-10-29: 0.8–4.7 ms in thirty runs).</summary>
    private static readonly TimeSpan NoWait = TimeSpan.FromSeconds(2);
    private static readonly JwtValidatorOptions Options = new() { Issuer = Issuer, Audiences = new[] { "c" } };

    /// <summary>The forced-refetch window — the options' default, not a number of this file's own.</summary>
    private static readonly TimeSpan Window = TimeSpan.FromSeconds(Options.RefreshIntervalSeconds);

    private readonly RsaSecurityKey _a = new(RSA.Create(2048)) { KeyId = "key-a" };
    private readonly RsaSecurityKey _b = new(RSA.Create(2048)) { KeyId = "key-b" };
    private readonly RSA _attacker = RSA.Create(2048);
    private readonly Idp _idp;
    private readonly HttpClient _http;
    private readonly FakeClock _clock = new();
    private readonly ITestOutputHelper _out;

    public JwksKeyRotationTests(ITestOutputHelper output)
    {
        _out = output;
        _idp = new Idp(KeySet(_a));
        _http = new HttpClient(_idp);
    }

    public void Dispose()
    {
        _idp.ReleaseCerts();
        _http.Dispose();
        _a.Rsa?.Dispose();
        _b.Rsa?.Dispose();
        _attacker.Dispose();
    }

    [Fact]
    public async Task The_first_token_under_a_rotated_in_key_validates_in_the_same_call()
    {
        var v = Validator();
        Assert.Equal("before", (await v.ValidateAsync(Token(_a, "before"))).Subject);
        Assert.Equal((1, 1), (_idp.Discovery, _idp.Certs)); // the cold load
        _idp.Jwks = KeySet(_a, _b);

        var first = await Record.ExceptionAsync(() => v.ValidateAsync(Token(_b, "first")));

        Assert.True(first is null,
            $"the first token under the rotated-in key was rejected: {first?.GetType().Name} <- {first?.InnerException?.GetType().Name}: {first?.Message}");
        Assert.Equal((2, 2), (_idp.Discovery, _idp.Certs)); // one refetch, inside that call
        Assert.Equal("next", (await v.ValidateAsync(Token(_b, "next"))).Subject);
        Assert.Equal("old", (await v.ValidateAsync(Token(_a, "old"))).Subject);
        Assert.Equal((2, 2), (_idp.Discovery, _idp.Certs)); // and nothing more
    }

    /// <summary>Unknown kids cost one refetch per window however many arrive — the window is the options' interval, its
    /// boundary included — and the cached keys keep validating throughout.</summary>
    [Fact]
    public async Task A_stream_of_unknown_kids_refetches_at_most_once_per_window()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "warm")));
        Assert.Equal(1, _idp.Certs);

        await RejectsUnknownKidsAsync(v, 20);
        Assert.Equal(2, _idp.Certs); // the first unknown kid refetched; the other nineteen did not

        _clock.Advance(Window - TimeSpan.FromTicks(1));
        await RejectsUnknownKidsAsync(v, 20);
        Assert.Equal(2, _idp.Certs); // one tick short of the window: still closed

        _clock.Advance(TimeSpan.FromTicks(1));
        await RejectsUnknownKidsAsync(v, 20);
        Assert.Equal(3, _idp.Certs); // the window has passed: exactly one more

        Assert.True(await AcceptsAsync(v, Token(_a, "still")));
        Assert.Equal(3, _idp.Certs);
    }

    /// <summary>Validations that meet the rotated-in key while its refetch is still at the IdP wait for that refetch instead
    /// of failing or starting another. Each call runs synchronously up to the held JWKS request, so none of them has
    /// finished when the IdP answers.</summary>
    [Fact]
    public async Task Concurrent_first_tokens_under_a_rotated_in_key_share_one_refetch()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "warm")));
        _idp.Jwks = KeySet(_a, _b);
        _idp.HoldCerts();

        var first = v.ValidateAsync(Token(_b, "u0"));
        await _idp.CertsArrived.WaitAsync(Hang); // the refetch the first one asked for is at the IdP
        var rest = Enumerable.Range(1, 9).Select(i => v.ValidateAsync(Token(_b, $"u{i}"))).ToArray();
        Assert.DoesNotContain(rest.Prepend(first), t => t.IsCompleted);
        _idp.ReleaseCerts();

        var subjects = (await Task.WhenAll(rest.Prepend(first)).WaitAsync(Hang)).Select(t => t.Subject);
        Assert.Equal(Enumerable.Range(0, 10).Select(i => $"u{i}"), subjects);
        Assert.Equal(2, _idp.Certs);
    }

    /// <summary>Only a validation that asked for the refetch waits for it: a token whose key resolves is answered from the
    /// cache while the refetch is still at the IdP, so a stream of unknown kids cannot hold the others up.</summary>
    [Fact]
    public async Task A_token_whose_key_resolves_does_not_wait_for_a_refetch_in_flight()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "warm")));
        _idp.Jwks = KeySet(_a, _b);
        _idp.HoldCerts();

        var waiting = v.ValidateAsync(Token(_b, "waits"));
        await _idp.CertsArrived.WaitAsync(Hang);
        Assert.Equal("known", (await v.ValidateAsync(Token(_a, "known")).WaitAsync(Hang)).Subject);
        Assert.False(waiting.IsCompleted); // the one that asked is still waiting on the held refetch

        _idp.ReleaseCerts();
        Assert.Equal("waits", (await waiting.WaitAsync(Hang)).Subject);
    }

    // ── What a validation that asked for a refetch leaves behind on its caller's async flow: nothing. The wait is carried by an
    // AsyncLocal that RequestRefresh sets inside IdentityModel's own async method, whose end discards it (independent review
    // claimed it outlives that method and reaches the next validation, 2026-10-29). Each test calls the first validation
    // directly in the test method — through no helper whose own async boundary would hide a leak — while the JWKS gate holds
    // the refetch it asked for, then validates a token whose key is cached: that one must finish with the gate still shut. The
    // bound only turns a leak into a failure instead of a hang. ──

    /// <summary>(A) The first validation is cancelled while its refetch is held; the next one in the same method does not wait.</summary>
    /// <remarks>Cancelled once its refetch is at the IdP, not on a timer: a 100 ms timer armed before the token was signed
    /// fired before the call began in one run in four — the first signature with a fresh <c>RSA.Create(2048)</c> key generates
    /// it, measured 41–341 ms here — so no refetch was ever asked for and the test timed out waiting for one.</remarks>
    [Fact]
    public async Task A_cancelled_validation_leaves_no_wait_behind_for_the_next_one_in_the_same_method()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "warm")));
        var unknown = UnknownKid();
        _idp.HoldCerts();
        using var cts = new CancellationTokenSource();

        var first = v.ValidateAsync(unknown, cts.Token);
        await _idp.CertsArrived.WaitAsync(Hang);
        cts.Cancel();
        var cancelled = false;
        try
        {
            await first;
        }
        catch (OperationCanceledException)
        {
            cancelled = true;
        }
        Assert.True(cancelled, "the first validation must end cancelled while its refetch is held");

        await ValidatesWithTheRefetchStillHeldAsync(v, () => v.ValidateAsync(Token(_a, "next")));
    }

    /// <summary>(B) The same, with the next validation started by <see cref="Task.Run(Func{Task})"/> after the first returned.</summary>
    [Fact]
    public async Task A_cancelled_validation_leaves_no_wait_behind_for_a_Task_Run_started_after_it()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "warm")));
        var unknown = UnknownKid();
        _idp.HoldCerts();
        using var cts = new CancellationTokenSource();

        var first = v.ValidateAsync(unknown, cts.Token);
        await _idp.CertsArrived.WaitAsync(Hang);
        cts.Cancel();
        var cancelled = false;
        try
        {
            await first;
        }
        catch (OperationCanceledException)
        {
            cancelled = true;
        }
        Assert.True(cancelled, "the first validation must end cancelled while its refetch is held");

        await ValidatesWithTheRefetchStillHeldAsync(v, () => Task.Run(() => v.ValidateAsync(Token(_a, "next"))));
    }

    /// <summary>(C) The first validation is still waiting on its held refetch — not cancelled — when the next one runs in the
    /// same method; the refetch is released only after the next one has finished.</summary>
    [Fact]
    public async Task A_pending_validation_leaves_no_wait_behind_for_the_next_one_in_the_same_method()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "warm")));
        _idp.HoldCerts();

        var pending = v.ValidateAsync(UnknownKid());
        await _idp.CertsArrived.WaitAsync(Hang);

        await ValidatesWithTheRefetchStillHeldAsync(v, () => v.ValidateAsync(Token(_a, "next")));
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => pending.WaitAsync(Hang)); // its kid is in no key set
        Assert.Equal(2, _idp.Certs);
    }

    /// <summary>Runs <paramref name="next"/> — a token whose key is cached — with the JWKS gate still shut: it validates, the
    /// gate is still shut when it has, and no second refetch was decided (the cold load and the held one: two). Then opens
    /// the gate.</summary>
    private async Task ValidatesWithTheRefetchStillHeldAsync(JwtValidator v, Func<Task<ValidatedToken>> next)
    {
        var watch = Stopwatch.StartNew();
        var outcome = await Record.ExceptionAsync(async () => Assert.Equal("next", (await next().WaitAsync(NoWait)).Subject));
        watch.Stop();
        _out.WriteLine($"next validation: {watch.Elapsed.TotalMilliseconds:F1} ms, refetch held: {!_idp.CertsReleased}");
        Assert.True(outcome is null, $"the next validation waited on the held refetch or failed: {outcome?.GetType().Name}: {outcome?.Message}");
        Assert.False(_idp.CertsReleased);
        Assert.Equal(2, _idp.Certs);
        _idp.ReleaseCerts();
        Assert.Equal("after", (await v.ValidateAsync(Token(_a, "after")).WaitAsync(Hang)).Subject);
        Assert.Equal(2, _idp.Certs);
    }

    /// <summary>A refetch that fails spends the window as one that succeeds would (<c>.claude/rules/security.md</c>), and
    /// the cached keys keep validating meanwhile. The rotated-in key is picked up by the first refetch the next window
    /// allows.</summary>
    [Fact]
    public async Task A_failed_refetch_spends_the_window_and_the_cached_keys_keep_validating()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "warm")));
        _idp.Jwks = KeySet(_a, _b);
        _idp.CertsDown = true;

        Assert.False(await AcceptsAsync(v, Token(_b, "during")));
        Assert.Equal(2, _idp.Certs);
        Assert.True(await AcceptsAsync(v, Token(_a, "cached")));

        _idp.CertsDown = false;
        _clock.Advance(FailureBackoff.Cap); // past any failure backoff, still inside the window
        Assert.False(await AcceptsAsync(v, Token(_b, "same window")));
        Assert.Equal(2, _idp.Certs);

        _clock.Advance(Window);
        Assert.True(await AcceptsAsync(v, Token(_b, "next window")));
        Assert.Equal(3, _idp.Certs);
    }

    /// <summary>Cancelling a validation that waits on a rotation refetch ends the wait; the refetch it started runs on and
    /// lands, and its window is not handed back — the next token under the new key validates without another request.</summary>
    [Fact]
    public async Task Cancelling_during_a_rotation_refetch_ends_the_wait_and_the_refetch_still_lands()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "warm")));
        _idp.Jwks = KeySet(_a, _b);
        _idp.HoldCerts();
        using var cts = new CancellationTokenSource();

        var call = v.ValidateAsync(Token(_b, "cancelled"), cts.Token);
        await _idp.CertsArrived.WaitAsync(Hang);
        cts.Cancel();
        var ended = await Record.ExceptionAsync(() => call.WaitAsync(Hang));
        Assert.IsAssignableFrom<OperationCanceledException>(ended);

        _idp.ReleaseCerts();
        Assert.Equal("after", (await v.ValidateAsync(Token(_b, "after")).WaitAsync(Hang)).Subject);
        Assert.Equal(2, _idp.Certs);
    }

    /// <summary>Last-known-good is off: the IdP swaps A out for B, and once the refetch B's first token asked for has replaced
    /// the key set, a token under the removed key is refused — as in the other eight SDKs. IdentityModel's LKG lifetime runs
    /// from the last token a configuration validated, on the wall clock (an hour by default), so it cannot honour the key
    /// set's 300-second lifetime: it would serve A after any failed reload (<c>JwksStaleCacheOutageTests</c> T3).</summary>
    /// <remarks>Flipped from "a token under the removed key still validates through the last-known-good configuration".</remarks>
    [Fact]
    public async Task A_token_under_a_removed_key_is_refused_once_a_refetch_replaced_the_key_set()
    {
        var v = Validator();
        Assert.True(await AcceptsAsync(v, Token(_a, "a")));
        _idp.Jwks = KeySet(_b);
        Assert.True(await AcceptsAsync(v, Token(_b, "b"))); // its unknown kid refetches in the call

        Assert.False(await AcceptsAsync(v, Token(_a, "removed")));
        Assert.False(ManagerOf(v).UseLastKnownGoodConfiguration);
        Assert.Equal(2, _idp.Certs);
    }

    private JwtValidator Validator() => new(Issuer, Options, _http, _clock.Read, () => 1.0);

    private static BaseConfigurationManager ManagerOf(JwtValidator v) =>
        ((TokenValidationParameters)typeof(JwtValidator).GetField("_tvp", BindingFlags.NonPublic | BindingFlags.Instance)!
            .GetValue(v)!).ConfigurationManager!;

    private string Token(RsaSecurityKey key, string sub) => new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(
        $$"""{"iss":"{{Issuer}}","sub":"{{sub}}","aud":"c","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}}""",
        new SigningCredentials(key, SecurityAlgorithms.RsaSha256));

    /// <summary>A well-formed token under a random kid the IdP never published.</summary>
    private string UnknownKid() => Token(new RsaSecurityKey(_attacker) { KeyId = Guid.NewGuid().ToString("N") }, "attacker");

    /// <summary>Well-formed tokens under random kids the IdP never published; each one is refused.</summary>
    private async Task RejectsUnknownKidsAsync(JwtValidator v, int count)
    {
        for (var i = 0; i < count; i++)
            Assert.False(await AcceptsAsync(v, UnknownKid()));
    }

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

    private static string KeySet(params RsaSecurityKey[] keys) =>
        $$"""{"keys":[{{string.Join(",", keys.Select(k =>
        {
            var p = k.Rsa!.ExportParameters(false);
            return $$"""{"kty":"RSA","kid":"{{k.KeyId}}","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}""";
        }))}}]}""";

    /// <summary>The SDK's clock seam. Read from more than one thread, so it is kept in one atomic word.</summary>
    private sealed class FakeClock
    {
        private long _ticks = new DateTimeOffset(2026, 10, 28, 12, 0, 0, TimeSpan.Zero).UtcTicks;

        public DateTimeOffset Read() => new(Interlocked.Read(ref _ticks), TimeSpan.Zero);

        public void Advance(TimeSpan by) => Interlocked.Add(ref _ticks, by.Ticks);
    }

    /// <summary>The IdP, in process: counts discovery and JWKS requests, can hold JWKS requests, and can fail them.</summary>
    private sealed class Idp(string jwks) : HttpMessageHandler
    {
        private int _discovery;
        private int _certs;
        private volatile string _jwks = jwks;
        private volatile bool _certsDown;
        private volatile TaskCompletionSource _held = Completed();
        private volatile TaskCompletionSource _arrived = Completed();

        public int Discovery => Volatile.Read(ref _discovery);

        public int Certs => Volatile.Read(ref _certs);

        public string Jwks
        {
            set => _jwks = value;
        }

        public bool CertsDown
        {
            set => _certsDown = value;
        }

        /// <summary>Completes when a JWKS request arrives after <see cref="HoldCerts"/>.</summary>
        public Task CertsArrived => _arrived.Task;

        /// <summary>Whether held JWKS requests may go on (always, until <see cref="HoldCerts"/>).</summary>
        public bool CertsReleased => _held.Task.IsCompleted;

        /// <summary>JWKS requests wait until <see cref="ReleaseCerts"/>.</summary>
        public void HoldCerts()
        {
            _arrived = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _held = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        public void ReleaseCerts() => _held.TrySetResult();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("/.well-known/openid-configuration", StringComparison.Ordinal))
            {
                Interlocked.Increment(ref _discovery);
                return Json($$"""{"issuer":"{{Issuer}}","jwks_uri":"{{Issuer}}/protocol/openid-connect/certs"}""");
            }

            Interlocked.Increment(ref _certs);
            _arrived.TrySetResult();
            await _held.Task;
            return _certsDown
                ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("{}", Encoding.UTF8, "application/json") }
                : Json(_jwks);
        }

        private static TaskCompletionSource Completed()
        {
            var done = new TaskCompletionSource();
            done.SetResult();
            return done;
        }

        private static HttpResponseMessage Json(string body) =>
            new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    }
}
