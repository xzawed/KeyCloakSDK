using System.Text.Json;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// A consumer <see cref="ITokenProvider"/> that fails inside an admin call ends that call in its own exception, unchanged — as
/// it does when <see cref="AdminClient.CreateAsync"/> warms it up — never relabelled as a request body the SDK could not
/// encode (registry <c>wave4-hardening-dotnet</c> (5)).
/// </summary>
/// <remarks>
/// <para><c>BearerHandler</c> asks the provider for the token before the request exists on the wire, outside the try that
/// turns a body System.Text.Json refuses into "the request body could not be encoded". A provider that deserializes its own
/// token response throws System.Text.Json's <see cref="JsonException"/>, and the typed arms of <c>AdminClient</c> label every
/// <see cref="JsonException"/> seen before a response that way.</para>
/// <para>Measured before the fix (2026-10-29, this file): the typed reads and writes ended in
/// <see cref="KeycloakTransportException"/> "admin request failed: the request body could not be encoded as JSON"; the typed
/// creates and every raw call let the provider's exception through unchanged — as the warm-up does.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class TokenProviderFailureTests : IDisposable
{
    private const string Unencodable = "admin request failed: the request body could not be encoded as JSON";

    private readonly WireMockServer _idp = WireMockServer.Start();

    public void Dispose() => _idp.Dispose();

    private KeycloakConfig Config() => new() { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" };

    [Fact]
    public async Task A_token_provider_failing_inside_an_admin_call_ends_it_in_its_own_exception()
    {
        var provider = new UnparsableTokenProvider(failFrom: 2); // the warm-up gets a token
        using var admin = await AdminClient.CreateAsync(Config(), provider);

        var wrong = new List<string>();
        foreach (var (name, _, _, run) in UnsupportedCharsetResponseTests.Calls)
        {
            var ex = await Record.ExceptionAsync(() => run(admin));
            if (ex is null || !ReferenceEquals(ex, provider.LastThrown))
                wrong.Add($"{name}: {Describe(ex)} — want the provider's own JsonException, unchanged");
        }

        Assert.True(wrong.Count == 0, string.Join("\n", wrong));
        Assert.Equal(UnsupportedCharsetResponseTests.Calls.Length + 1, provider.Calls); // every call asked it, and failed there
        Assert.DoesNotContain(_idp.LogEntries, e => e.RequestMessage?.Path?.StartsWith("/admin/", StringComparison.Ordinal) == true);
    }

    /// <summary>Control: the reference behaviour — the warm-up has always let the provider's failure through unchanged.</summary>
    [Fact]
    public async Task Control_the_warm_up_ends_in_the_providers_own_exception()
    {
        var provider = new UnparsableTokenProvider(failFrom: 1);

        var ex = await Record.ExceptionAsync(() => AdminClient.CreateAsync(Config(), provider));

        Assert.NotNull(provider.LastThrown);
        Assert.Same(provider.LastThrown, ex);
    }

    /// <summary>Control: the label is narrowed, not dropped — a <see cref="JsonException"/> before any response that the
    /// token provider did not throw still reads as a request body that could not be encoded, on both typed arms. (Every
    /// body System.Text.Json refuses in the transport is already caught in <c>BearerHandler</c>:
    /// <c>UnencodableRequestBodyTests</c>.)</summary>
    [Fact]
    public async Task Control_a_json_failure_before_any_response_not_from_the_provider_is_still_a_request_body_failure()
    {
        using var admin = await AdminClient.CreateAsync(Config(), new UnparsableTokenProvider(failFrom: int.MaxValue));

        var read = await Record.ExceptionAsync(() => admin.CallTypedAsync<int>(_ => throw new JsonException("eager write")));
        var write = await Record.ExceptionAsync(() => admin.WriteTypedAsync(_ => throw new JsonException("eager write")));

        Assert.Equal(Unencodable, Assert.IsType<KeycloakTransportException>(read).Message);
        Assert.Equal(Unencodable, Assert.IsType<KeycloakTransportException>(write).Message);
    }

    /// <summary>A provider that fetches its own token and fails to parse the response — System.Text.Json's own exception —
    /// from its <paramref name="failFrom"/>-th call on.</summary>
    private sealed class UnparsableTokenProvider(int failFrom) : ITokenProvider
    {
        private int _calls;

        public int Calls => Volatile.Read(ref _calls);

        public Exception? LastThrown { get; private set; }

        public Task<string> GetAccessTokenAsync(CancellationToken ct = default)
        {
            if (Interlocked.Increment(ref _calls) < failFrom)
                return Task.FromResult("usable-access");
            try
            {
                using var unparsable = JsonDocument.Parse("""{"access_token":""");
            }
            catch (JsonException e)
            {
                LastThrown = e;
                throw;
            }
            throw new InvalidOperationException("the token response parsed — the fixture is broken");
        }
    }

    private static string Describe(Exception? ex) => ex switch
    {
        null => "no exception",
        KeycloakAdminException a => $"{a.GetType().Name}({a.StatusCode}) \"{a.Message}\"",
        _ => $"{ex.GetType().FullName}: \"{ex.Message}\" (inner {ex.InnerException?.GetType().Name ?? "none"})",
    };
}
