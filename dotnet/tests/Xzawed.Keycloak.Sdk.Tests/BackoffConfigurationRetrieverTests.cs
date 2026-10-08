using System.Security.Cryptography;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.Configuration;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// What <see cref="BackoffConfigurationRetriever"/> counts as a failed fetch. The schedule itself (base, doubling, cap,
/// reset) is <see cref="FailureBackoff"/>'s and is pinned by <c>BackoffConfigurationManagerTests</c>; end to end through
/// IdentityModel's manager: <see cref="JwksStaleCacheOutageTests"/>.
/// </summary>
[Trait("Category", "Unit")]
public sealed class BackoffConfigurationRetrieverTests
{
    private const string Discovery = "http://idp.test/realms/r/.well-known/openid-configuration";

    private readonly Documents _idp = new();
    private readonly FakeClock _clock = new();
    private readonly BackoffConfigurationRetriever _retriever;

    public BackoffConfigurationRetrieverTests() =>
        _retriever = new BackoffConfigurationRetriever(
            new OpenIdConnectConfigurationRetriever(),
            new Microsoft.IdentityModel.Protocols.OpenIdConnect.Configuration.OpenIdConnectConfigurationValidator { MinimumNumberOfKeys = 1 },
            _clock.Read,
            () => 1.0);

    private Task<OpenIdConnectConfiguration> FetchAsync() => _retriever.GetConfigurationAsync(Discovery, _idp, CancellationToken.None);

    /// <summary>Inside the window a fetch is refused without touching the IdP — and a refusal is not a failure: had the ten
    /// refusals counted, the window would have reached the 5 s cap and the fetch after the base window would be refused.</summary>
    [Fact]
    public async Task A_failed_fetch_refuses_the_next_ones_without_touching_the_IdP_and_does_not_count_them()
    {
        _idp.Down = true;
        await Assert.ThrowsAsync<IOException>(FetchAsync);
        Assert.Equal(1, _idp.Requests);

        for (var i = 0; i < 10; i++)
        {
            var refused = await Assert.ThrowsAsync<KeycloakTransportException>(FetchAsync);
            Assert.Contains("backing off after 1 consecutive failures", refused.Message, StringComparison.Ordinal);
        }
        Assert.Equal(1, _idp.Requests);

        _clock.Advance(FailureBackoff.Base);
        await Assert.ThrowsAsync<IOException>(FetchAsync);
        Assert.Equal(2, _idp.Requests);
    }

    /// <summary>A 200 with no keys is a failed fetch: the manager would refuse to install it and fetch again next call.</summary>
    [Fact]
    public async Task A_configuration_the_validator_rejects_is_a_failed_fetch()
    {
        _idp.Jwks = """{"keys":[]}""";
        var rejected = await Assert.ThrowsAsync<InvalidConfigurationException>(FetchAsync);
        Assert.Contains("IDX21817", rejected.Message, StringComparison.Ordinal);
        Assert.Equal(2, _idp.Requests); // discovery + JWKS

        await Assert.ThrowsAsync<KeycloakTransportException>(FetchAsync);
        Assert.Equal(2, _idp.Requests);
    }

    /// <summary>A success resets the counter: after three failures (window 0.8 s) and a recovery, the next failure opens the
    /// base window again.</summary>
    [Fact]
    public async Task A_success_resets_the_counter()
    {
        _idp.Down = true;
        for (var i = 0; i < 3; i++)
        {
            await Assert.ThrowsAsync<IOException>(FetchAsync);
            _clock.Advance(FailureBackoff.Cap);
        }

        _idp.Down = false;
        Assert.NotEmpty((await FetchAsync()).SigningKeys);

        _idp.Down = true;
        await Assert.ThrowsAsync<IOException>(FetchAsync);
        _clock.Advance(FailureBackoff.Base);
        var before = _idp.Requests;
        await Assert.ThrowsAsync<IOException>(FetchAsync);
        Assert.Equal(before + 1, _idp.Requests);
    }

    /// <summary>
    /// The cold-load gate (<see cref="BackoffConfigurationManager"/>) sits in front of this one. A fetch this one refused
    /// reaches it wrapped once by IdentityModel's manager (IDX20803) — or bare, from a nested gate. It never reached the IdP,
    /// so it must not count: callers queued behind the first load would otherwise push the cold window to the cap after a
    /// single real failure.
    /// </summary>
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task The_cold_load_gate_does_not_count_a_refusal(bool wrappedByTheManager)
    {
        var refusal = new KeycloakTransportException("JWKS fetch backing off after 1 consecutive failures (retry in 0.20s)");
        var inner = new ThrowingManager(wrappedByTheManager ? new InvalidOperationException("IDX20803", refusal) : refusal);
        var gate = new BackoffConfigurationManager(inner, _clock.Read, () => 1.0);

        for (var i = 0; i < 5; i++)
            await Assert.ThrowsAnyAsync<Exception>(() => gate.GetBaseConfigurationAsync(CancellationToken.None));

        Assert.Equal(5, inner.Calls); // no window opened, so every call went through
    }

    /// <summary>Control for the theory above: a real failure, wrapped the same way, is counted.</summary>
    [Fact]
    public async Task The_cold_load_gate_counts_a_real_failure_wrapped_by_the_manager()
    {
        var inner = new ThrowingManager(new InvalidOperationException("IDX20803", new IOException("HTTP 503")));
        var gate = new BackoffConfigurationManager(inner, _clock.Read, () => 1.0);

        for (var i = 0; i < 5; i++)
            await Assert.ThrowsAnyAsync<Exception>(() => gate.GetBaseConfigurationAsync(CancellationToken.None));

        Assert.Equal(1, inner.Calls);
    }

    /// <summary>Discovery and a JWKS, served from memory.</summary>
    private sealed class Documents : IDocumentRetriever
    {
        private static readonly RsaSecurityKey Key = new(RSA.Create(2048)) { KeyId = "k1" };
        private int _requests;

        public bool Down { get; set; }

        public string Jwks { get; set; } = KeySet();

        public int Requests => Volatile.Read(ref _requests);

        public Task<string> GetDocumentAsync(string address, CancellationToken cancel)
        {
            Interlocked.Increment(ref _requests);
            if (Down)
                throw new IOException($"Unable to fetch '{address}': HTTP 503.");
            return Task.FromResult(address == Discovery
                ? """{"issuer":"http://idp.test/realms/r","jwks_uri":"http://idp.test/realms/r/protocol/openid-connect/certs"}"""
                : Jwks);
        }

        private static string KeySet()
        {
            var p = Key.Rsa!.ExportParameters(false);
            return $$"""{"keys":[{"kty":"RSA","kid":"k1","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}]}""";
        }
    }

    private sealed class ThrowingManager(Exception failure) : BaseConfigurationManager
    {
        public int Calls;

        public override Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel)
        {
            Calls++;
            throw failure;
        }

        public override void RequestRefresh()
        {
        }
    }

    private sealed class FakeClock
    {
        private DateTimeOffset _now = new(2026, 10, 9, 12, 0, 0, TimeSpan.Zero);

        public DateTimeOffset Read() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
