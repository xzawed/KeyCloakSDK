using System.Threading.Tasks;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;
using Xzawed.Keycloak.Admin;
using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Sdk.Tests;

public class AdminClientTests : IDisposable
{
    private readonly WireMockServer _mock = WireMockServer.Start();

    private sealed class FixedToken : ITokenProvider
    {
        public Task<string> GetAccessTokenAsync(System.Threading.CancellationToken ct = default) => Task.FromResult("test-token");
    }

    private Task<AdminClient> BuildAsync()
    {
        var cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" }.Normalized();
        return AdminClient.CreateAsync(cfg, new FixedToken());
    }

    // ⚠️ Stop()이 아니라 Dispose()다. xUnit은 테스트 메서드마다 클래스를 새로 만들므로 이 파일
    // 하나가 self-host를 여러 개 띄운다. Stop()은 요청 처리만 멈추고 호스트/리스너 스레드는
    // 남겨서, 프로세스 종료가 느려지고 편차가 커진다 — 커버리지 히트 flush가 종료 타이밍에
    // 걸리는 구성에서 이게 플레이크의 가중 요인이 된다. JwtValidatorTests는 처음부터
    // `using var server`로 올바르게 해제하고 있었다.
    public void Dispose() => _mock.Dispose();

    [Fact]
    public async Task Create_without_secret_throws_before_network()
    {
        var cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c" }.Normalized();
        await Assert.ThrowsAsync<KeycloakConfigException>(() => AdminClient.CreateAsync(cfg, new FixedToken()));
    }

    [Fact]
    public async Task Clients_create_parses_location_id()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/clients").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(201)
                 .WithHeader("Location", $"{_mock.Urls[0]}/admin/realms/r/clients/abc-123"));
        var id = await admin.Clients.CreateAsync(new ClientRepresentation { ClientId = "svc" });
        Assert.Equal("abc-123", id);
    }

    [Fact]
    public async Task Clients_get_404_maps_to_NotFound()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/clients/missing").UsingGet())
             .RespondWith(Response.Create().WithStatusCode(404));
        await Assert.ThrowsAsync<KeycloakNotFoundException>(() => admin.Clients.GetAsync("missing"));
    }

    [Fact]
    public async Task Bearer_token_attached_on_raw_calls()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/roles/app-admin").UsingGet()
                 .WithHeader("Authorization", "Bearer test-token"))
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { name = "app-admin" }));
        var role = await admin.Roles.GetAsync("app-admin");
        Assert.Equal("app-admin", role.Name);
    }

    [Fact]
    public async Task Timeout_maps_to_TransportException()
    {
        var cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s", ReadTimeoutMs = 200 }.Normalized();
        await using var admin = await AdminClient.CreateAsync(cfg, new FixedToken());
        _mock.Given(Request.Create().WithPath("/admin/realms/r/roles/slow").UsingGet())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { name = "slow" }).WithDelay(TimeSpan.FromMilliseconds(1500)));
        await Assert.ThrowsAsync<KeycloakTransportException>(() => admin.Roles.GetAsync("slow"));
    }
    // ── 감사 후속: 이 셋은 이전에 파사드에도 `Raw`에도 없어 **소비자가 도달할 방법이 아예 없었다**.
    // `Raw`는 users/groups/realm-read만 커버하는 타입드 클라이언트고, 내부 raw-REST 헬퍼는 internal이라
    // 별도 HttpClient를 손수 만드는 것 말고는 길이 없었다 — 그러면 오류 변환·타임아웃·리다이렉트
    // 하드닝을 전부 잃는다. 아홉 SDK 중 유일하게 도달 불가능했던 갭이다.
    // 각 테스트는 **HTTP 메서드와 경로를 함께** 단언한다 — 경로만 맞추면 PUT을 GET으로 잘못 써도 통과한다.

    [Fact]
    public async Task Roles_update_puts_to_the_named_role()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/roles/app-admin").UsingPut())
             .RespondWith(Response.Create().WithStatusCode(204));

        await admin.Roles.UpdateAsync("app-admin", new RoleRepresentation { Name = "app-admin-renamed" });

        var hit = Assert.Single(_mock.LogEntries, e => e.RequestMessage?.Path == "/admin/realms/r/roles/app-admin");
        Assert.Equal("PUT", hit.RequestMessage!.Method, ignoreCase: true);
    }

    [Fact]
    public async Task Realms_update_puts_to_the_named_realm()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/other").UsingPut())
             .RespondWith(Response.Create().WithStatusCode(204));

        await admin.Realms.UpdateAsync("other", new RealmRepresentation { Realm = "other" });

        var hit = Assert.Single(_mock.LogEntries, e => e.RequestMessage?.Path == "/admin/realms/other");
        Assert.Equal("PUT", hit.RequestMessage!.Method, ignoreCase: true);
    }

    [Fact]
    public async Task Realms_list_gets_the_collection()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms").UsingGet())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new[] { new { realm = "master" }, new { realm = "r" } }));

        var realms = await admin.Realms.ListAsync();

        Assert.Equal(2, realms.Count);
        Assert.Contains(realms, r => r.Realm == "master");
    }

    // ── 성공 상태인데 파사드가 결과로 받을 수 없는 응답. ──

    /// <summary>A raw read answered 200 with the JSON literal <c>null</c> names nothing: <see cref="KeycloakNotFoundException"/>
    /// naming the path, on every raw read — never a null handed back as the resource or the list.</summary>
    [Theory]
    [InlineData("Clients.GetAsync", "/admin/realms/r/clients/c-1", "admin/realms/r/clients/c-1")]
    [InlineData("Clients.FindByClientIdAsync", "/admin/realms/r/clients", "admin/realms/r/clients?clientId=svc")]
    [InlineData("Roles.GetAsync", "/admin/realms/r/roles/app-admin", "admin/realms/r/roles/app-admin")]
    [InlineData("Roles.ListAsync", "/admin/realms/r/roles", "admin/realms/r/roles")]
    [InlineData("Realms.ListAsync", "/admin/realms", "admin/realms")]
    public async Task A_raw_read_answered_with_JSON_null_is_NotFound(string call, string path, string named)
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath(path).UsingGet())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json").WithBody("null"));
        Func<Task> read = call switch
        {
            "Clients.GetAsync" => () => admin.Clients.GetAsync("c-1"),
            "Clients.FindByClientIdAsync" => () => admin.Clients.FindByClientIdAsync("svc"),
            "Roles.GetAsync" => () => admin.Roles.GetAsync("app-admin"),
            "Roles.ListAsync" => () => admin.Roles.ListAsync(),
            "Realms.ListAsync" => () => admin.Realms.ListAsync(),
            _ => throw new ArgumentOutOfRangeException(nameof(call)),
        };

        var missing = await Assert.ThrowsAsync<KeycloakNotFoundException>(read);

        Assert.Equal($"empty response body for {named}", missing.Message);
    }

    /// <summary>The <c>Location</c> a create's 201 carries — <c>{base}</c> is this IdP, <c>{path}</c> the collection the create
    /// posted to — and the id the create returns, or null where it must fail.</summary>
    public static TheoryData<string, string?, string?> CreatedAnswers()
    {
        var data = new TheoryData<string, string?, string?>();
        foreach (var resource in new[] { "clients", "users", "groups" })
        {
            data.Add(resource, null, null);                         // no Location
            data.Add(resource, "{path}/abc-123", null);             // relative — the facade reads only an absolute one
            data.Add(resource, "{base}/", null);                    // absolute, but its path names nothing
            data.Add(resource, "{base}{path}/abc-123/", "abc-123"); // control: the last segment, its trailing slash dropped
        }
        return data;
    }

    /// <summary>A create answered 201 with no id this facade reads from <c>Location</c> — none, a relative one (it is not
    /// resolved: <see cref="Uri.Segments"/> refuses a relative URI), or one whose path names nothing — fails as a 500 on every
    /// create that returns an id (raw: clients · typed: users, groups). Never an empty id, nor a raw exception from the URI.
    /// Control: an absolute <c>Location</c> gives its last segment.</summary>
    [Theory]
    [MemberData(nameof(CreatedAnswers))]
    public async Task A_create_answered_without_a_readable_id_fails_as_a_500(string resource, string? location, string? id)
    {
        await using var admin = await BuildAsync();
        var path = $"/admin/realms/r/{resource}";
        var created = Response.Create().WithStatusCode(201);
        if (location is not null)
        {
            created = created.WithHeader("Location", location
                .Replace("{base}", _mock.Urls[0], StringComparison.Ordinal)
                .Replace("{path}", path, StringComparison.Ordinal));
        }
        _mock.Given(Request.Create().WithPath(path).UsingPost()).RespondWith(created);
        Func<Task<string>> create = resource switch
        {
            "clients" => () => admin.Clients.CreateAsync(new ClientRepresentation { ClientId = "svc" }),
            "users" => () => admin.Users.CreateAsync(new UserRepresentation { Username = "alice" }),
            "groups" => () => admin.Groups.CreateAsync(new GroupRepresentation { Name = "team" }),
            _ => throw new ArgumentOutOfRangeException(nameof(resource)),
        };

        if (id is not null)
        {
            Assert.Equal(id, await create());
            return;
        }
        var refused = await Assert.ThrowsAsync<KeycloakAdminException>(create);
        Assert.Equal(500, refused.StatusCode);
        Assert.Equal("resource created but no id returned in Location header", refused.Message);
    }
}
