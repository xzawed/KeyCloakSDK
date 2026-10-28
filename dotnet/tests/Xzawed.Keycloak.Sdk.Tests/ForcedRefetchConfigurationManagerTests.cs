using System.Security.Cryptography;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// What <see cref="ForcedRefetchConfigurationManager"/> serves around a refetch. End to end through IdentityModel's handler —
/// the window, the single flight, cancellation, the failure backoff: <see cref="JwksKeyRotationTests"/>.
/// </summary>
[Trait("Category", "Unit")]
public sealed class ForcedRefetchConfigurationManagerTests : IDisposable
{
    private const string Issuer = "http://idp.test/realms/r";
    private readonly RsaSecurityKey _a = new(RSA.Create(2048)) { KeyId = "key-a" };
    private readonly RsaSecurityKey _b = new(RSA.Create(2048)) { KeyId = "key-b" };
    private readonly RsaSecurityKey _c = new(RSA.Create(2048)) { KeyId = "key-c" };
    private readonly RsaSecurityKey _x = new(RSA.Create(2048)) { KeyId = "key-x" };

    public void Dispose()
    {
        _a.Rsa?.Dispose();
        _b.Rsa?.Dispose();
        _c.Rsa?.Dispose();
        _x.Rsa?.Dispose();
    }

    // ── The wrapped manager installs a configuration of its own (C2) while a refetch is in flight — its 12-hour refresh
    // landing then. The refetch result F is served in place of the configuration the refetch was decided against, never
    // in place of C2, which is at least as new. Measured on d64bf7c5, which paired F with the configuration cached when F
    // landed — C2 — (independent review 2026-10-29): (i) accepted the removed key, still 31 s later; (ii) refused the added
    // key, still 29 s later. The order is exact: the refetch waits for a gate, and C2 is served before the gate opens. LKG
    // is off — what is measured is the configuration served as current — and the clock stands still. ──

    /// <summary>(i) C2 dropped a key the refetch still carries: a token under it is refused.</summary>
    [Fact]
    public async Task A_key_the_wrapped_managers_newer_configuration_dropped_is_refused_after_a_refetch_lands()
    {
        var inner = new Cache { Current = Signing(_a, _b) };
        var (v, gate) = ValidatorOver(inner);
        Assert.True(await AcceptsAsync(v, Token(_a)));

        var asking = AcceptsAsync(v, Token(_x)); // key-x is in no set: a refetch is decided against C1 and held
        inner.Current = Signing(_b); // C2: key-a is gone
        Assert.True(await AcceptsAsync(v, Token(_b))); // C2 is served
        gate.SetResult(Signing(_a, _b)); // F: what the IdP served when the refetch was decided
        Assert.False(await asking);

        Assert.False(await AcceptsAsync(v, Token(_a)));
    }

    /// <summary>(ii) C2 added a key the refetch does not carry: a token under it is accepted.</summary>
    [Fact]
    public async Task A_key_the_wrapped_managers_newer_configuration_added_is_accepted_after_a_refetch_lands()
    {
        var inner = new Cache { Current = Signing(_a) };
        var (v, gate) = ValidatorOver(inner);
        Assert.True(await AcceptsAsync(v, Token(_a)));

        var asking = AcceptsAsync(v, Token(_b)); // key-b is not in C1: a refetch is decided against C1 and held
        inner.Current = Signing(_a, _b, _c); // C2: key-c is new
        Assert.True(await AcceptsAsync(v, Token(_c))); // C2 is served
        gate.SetResult(Signing(_a, _b)); // F: what the IdP served when the refetch was decided
        Assert.True(await asking);

        Assert.True(await AcceptsAsync(v, Token(_c)));
    }

    /// <summary>A validator over <paramref name="inner"/> whose one refetch waits for the returned gate; LKG off, clock still.</summary>
    private static (JwtValidator V, TaskCompletionSource<BaseConfiguration> Gate) ValidatorOver(Cache inner)
    {
        var gate = new TaskCompletionSource<BaseConfiguration>(TaskCreationOptions.RunContinuationsAsynchronously);
        var still = new DateTimeOffset(2026, 10, 29, 12, 0, 0, TimeSpan.Zero);
        var mgr = new ForcedRefetchConfigurationManager(inner, () => gate.Task, () => still) { UseLastKnownGoodConfiguration = false };
        var tvp = JwtValidator.BuildParameters(Issuer, new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "c" } });
        tvp.ConfigurationManager = mgr;
        return (new JwtValidator(tvp), gate);
    }

    private static OpenIdConnectConfiguration Signing(params RsaSecurityKey[] keys)
    {
        var configuration = new OpenIdConnectConfiguration { Issuer = Issuer };
        foreach (var key in keys)
            configuration.SigningKeys.Add(key);
        return configuration;
    }

    private static string Token(RsaSecurityKey key) => new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(
        $$"""{"iss":"{{Issuer}}","sub":"s","aud":"c","exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300}}}""",
        new SigningCredentials(key, SecurityAlgorithms.RsaSha256));

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

    /// <summary>A refetched configuration is served in place of the one the refetch was decided against — and gives way as
    /// soon as the wrapped manager installs one of its own, which is newer. The request is never handed to the wrapped manager:
    /// its background refresh would be a second fetch.</summary>
    [Fact]
    public async Task A_refetched_configuration_gives_way_to_the_wrapped_managers_next_one()
    {
        var inner = new Cache();
        var fresh = new OpenIdConnectConfiguration();
        var mgr = new ForcedRefetchConfigurationManager(inner, () => Task.FromResult<BaseConfiguration>(fresh));
        Assert.Same(inner.Current, await mgr.GetBaseConfigurationAsync(CancellationToken.None));

        mgr.RequestRefresh();

        Assert.Same(fresh, await mgr.GetBaseConfigurationAsync(CancellationToken.None));
        inner.Current = new OpenIdConnectConfiguration(); // the wrapped manager's own refresh — its 12-hour one
        Assert.Same(inner.Current, await mgr.GetBaseConfigurationAsync(CancellationToken.None));
    }

    /// <summary>Before any configuration was served there is nothing to supersede — the cold load is the fetch — so a refetch
    /// asked for then is not made, and it spends no window: the first one after a configuration is served still goes out.
    /// (IdentityModel's handler asks only once it holds a configuration; a direct call is what reaches this.)</summary>
    [Fact]
    public async Task A_refetch_asked_for_before_anything_was_served_is_not_made_and_spends_no_window()
    {
        var fetches = 0;
        var inner = new Cache();
        var mgr = new ForcedRefetchConfigurationManager(inner, () =>
        {
            Interlocked.Increment(ref fetches);
            return Task.FromResult<BaseConfiguration>(new OpenIdConnectConfiguration());
        });

        mgr.RequestRefresh();
        Assert.Same(inner.Current, await mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Equal(0, Volatile.Read(ref fetches));

        mgr.RequestRefresh();
        Assert.NotSame(inner.Current, await mgr.GetBaseConfigurationAsync(CancellationToken.None));
        Assert.Equal(1, Volatile.Read(ref fetches));
    }

    private sealed class Cache : BaseConfigurationManager
    {
        public BaseConfiguration Current { get; set; } = new OpenIdConnectConfiguration();

        public override Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel) => Task.FromResult(Current);

        public override void RequestRefresh() =>
            throw new InvalidOperationException("the refetch was handed to the wrapped manager");
    }
}
