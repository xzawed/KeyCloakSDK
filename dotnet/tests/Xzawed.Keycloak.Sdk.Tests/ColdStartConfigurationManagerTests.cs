using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// When <see cref="ColdStartConfigurationManager"/> starts over with a new, cold manager. End to end through the validator
/// (the reload is the cold load, the backoff in front of it, LKG off): <see cref="JwksStaleCacheOutageTests"/>.
/// </summary>
[Trait("Category", "Unit")]
public sealed class ColdStartConfigurationManagerTests
{
    private static readonly TimeSpan MaxAge = TimeSpan.FromSeconds(KeySetLifetime.JwksMaxAgeSeconds);

    private readonly FakeClock _clock = new();
    private readonly List<Manager> _created = new();
    private readonly KeySetLifetime _lifetime;
    private readonly ColdStartConfigurationManager _coldStart;

    public ColdStartConfigurationManagerTests()
    {
        _lifetime = new KeySetLifetime(_clock.Read);
        _coldStart = new ColdStartConfigurationManager(
            () =>
            {
                var manager = new Manager();
                _created.Add(manager);
                return manager;
            },
            _lifetime);
    }

    private Task<BaseConfiguration> GetAsync() => _coldStart.GetBaseConfigurationAsync(CancellationToken.None);

    [Fact]
    public async Task One_tick_before_its_lifetime_the_key_set_keeps_its_manager()
    {
        var c1 = await GetAsync();
        _lifetime.Fetched(c1);
        _clock.Advance(MaxAge - TimeSpan.FromTicks(1));

        _coldStart.StartOverIfExpired(c1, c1);

        Assert.Same(c1, await GetAsync());
        Assert.Single(_created);
    }

    /// <summary>At its lifetime the next configuration comes from a new manager — once, however many callers saw the set.</summary>
    [Fact]
    public async Task At_its_lifetime_the_next_configuration_comes_from_one_new_manager()
    {
        var c1 = await GetAsync();
        _lifetime.Fetched(c1);
        _clock.Advance(MaxAge);

        _coldStart.StartOverIfExpired(c1, c1);
        _coldStart.StartOverIfExpired(c1, c1);

        Assert.NotSame(c1, await GetAsync());
        Assert.Equal(2, _created.Count);
    }

    /// <summary>What is checked is what was served: a set refetched over the cached one keeps the manager while it is young,
    /// whatever the cached one's age.</summary>
    [Fact]
    public async Task A_young_set_served_over_an_expired_cached_one_keeps_the_manager()
    {
        var cached = await GetAsync();
        _lifetime.Fetched(cached);
        _clock.Advance(TimeSpan.FromSeconds(100));
        var refetched = new OpenIdConnectConfiguration();
        _lifetime.Fetched(refetched);
        _clock.Advance(MaxAge - TimeSpan.FromSeconds(1)); // the cached set is past its lifetime, the refetched one is not

        _coldStart.StartOverIfExpired(cached, refetched);

        Assert.Same(cached, await GetAsync());
        Assert.Single(_created);
    }

    /// <summary>A caller that saw a set the current manager never served starts nothing — the manager already started over.</summary>
    [Fact]
    public async Task A_caller_that_saw_an_older_set_starts_nothing()
    {
        var c1 = await GetAsync();
        _lifetime.Fetched(c1);
        _clock.Advance(MaxAge);
        _coldStart.StartOverIfExpired(c1, c1);
        var c2 = await GetAsync();
        _lifetime.Fetched(c2);

        _coldStart.StartOverIfExpired(c1, c1);

        Assert.Same(c2, await GetAsync());
        Assert.Equal(2, _created.Count);
    }

    /// <summary>A configuration no fetch stamped is aged from the first time it is asked about — never fresh for good.</summary>
    [Fact]
    public async Task An_unstamped_configuration_is_aged_from_when_it_was_first_asked_about()
    {
        var c1 = await GetAsync();
        _coldStart.StartOverIfExpired(c1, c1);
        Assert.Same(c1, await GetAsync());

        _clock.Advance(MaxAge);
        _coldStart.StartOverIfExpired(c1, c1);
        Assert.NotSame(c1, await GetAsync());
    }

    [Fact]
    public void RequestRefresh_reaches_the_current_manager()
    {
        _coldStart.RequestRefresh();
        Assert.Equal(1, _created[0].Refreshes);
    }

    /// <summary>IdentityModel's manager as far as this layer can tell: the same configuration on every call.</summary>
    private sealed class Manager : BaseConfigurationManager
    {
        private readonly OpenIdConnectConfiguration _configuration = new();

        public int Refreshes { get; private set; }

        public override Task<BaseConfiguration> GetBaseConfigurationAsync(CancellationToken cancel) =>
            Task.FromResult<BaseConfiguration>(_configuration);

        public override void RequestRefresh() => Refreshes++;
    }

    private sealed class FakeClock
    {
        private DateTimeOffset _now = new(2026, 10, 29, 12, 0, 0, TimeSpan.Zero);

        public DateTimeOffset Read() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
