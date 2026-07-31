using System.Net.Http.Json;
using System.Text.Json;
using System.Threading.Tasks;
using Keycloak.AuthServices.Sdk.Admin.Models;
using Xunit;
using Xzawed.Keycloak;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests.Integration;

[Collection("keycloak")]
[Trait("Category", "Integration")]
public class E2ETests
{
    private readonly KeycloakFixture _kc;
    public E2ETests(KeycloakFixture kc) => _kc = kc;

    private KeycloakClient NewClient() => KeycloakClient.Create(new KeycloakConfig
    {
        ServerUrl = _kc.BaseUrl,
        Realm = KeycloakFixture.Realm,
        ClientId = KeycloakFixture.ClientId,
        ClientSecret = KeycloakFixture.ClientSecret,
    });

    [Fact]
    public async Task Full_flow()
    {
        await using var client = NewClient();

        // 1) client-credentials + masking
        var token = await client.Auth.ClientCredentialsTokenAsync();
        Assert.False(string.IsNullOrEmpty(token.AccessToken));
        Assert.True(token.ExpiresIn > 0);
        var rendered = token.ToString();
        Assert.Contains("***", rendered);
        Assert.DoesNotContain(token.AccessToken, rendered);

        // 2) validate (multi-aud membership)
        var validated = await client.Auth.ValidateAsync(token.AccessToken);
        Assert.EndsWith($"/realms/{KeycloakFixture.Realm}", validated.Issuer);
        Assert.Contains(KeycloakFixture.ClientId, validated.Audience);
        Assert.False(string.IsNullOrEmpty(validated.Subject));

        // 3) introspect
        var introspection = await client.Auth.IntrospectAsync(token.AccessToken);
        Assert.True(introspection.Active);

        // 4) user CRUD (+ delete-then-NotFound)
        var admin = await client.AdminAsync();
        var userId = await admin.Users.CreateAsync(new UserRepresentation { Username = "bob", Email = "bob@example.com", Enabled = true });
        Assert.False(string.IsNullOrEmpty(userId));
        Assert.Equal("bob", (await admin.Users.GetAsync(userId)).Username);
        Assert.NotEmpty(await admin.Users.SearchAsync("bob"));
        await admin.Users.UpdateAsync(userId, new UserRepresentation { FirstName = "Bob", Enabled = true });
        Assert.Equal("Bob", (await admin.Users.GetAsync(userId)).FirstName);
        await admin.Users.DeleteAsync(userId);
        await Assert.ThrowsAsync<KeycloakNotFoundException>(() => admin.Users.GetAsync(userId));

        // 5) clients (raw)
        var clientUuid = await admin.Clients.CreateAsync(new ClientRepresentation { ClientId = "svc-e2e", Enabled = true });
        Assert.Equal("svc-e2e", (await admin.Clients.GetAsync(clientUuid)).ClientId);
        Assert.NotEmpty(await admin.Clients.FindByClientIdAsync("svc-e2e"));
        await admin.Clients.DeleteAsync(clientUuid);

        // 6) roles (raw, by name)
        await admin.Roles.CreateAsync(new RoleRepresentation { Name = "role-e2e" });
        Assert.Equal("role-e2e", (await admin.Roles.GetAsync("role-e2e")).Name);
        Assert.Contains(await admin.Roles.ListAsync(), r => r.Name == "role-e2e");
        // ⚠️ update: 이 셋(roles.update · realms.update · realms.list)은 예전에 파사드에도 Raw에도 없어
        // 소비자가 도달할 수 없던 연산이다. 단위테스트는 WireMock에 대고 우리가 **무엇을 보내는지**만
        // 잠근다 — 실 Keycloak이 그 PUT/GET을 실제로 받아들이는지는 여기서만 증명된다.
        await admin.Roles.UpdateAsync("role-e2e", new RoleRepresentation { Name = "role-e2e", Description = "renamed-desc" });
        Assert.Equal("renamed-desc", (await admin.Roles.GetAsync("role-e2e")).Description);
        await admin.Roles.DeleteAsync("role-e2e");

        // 7) groups (typed)
        var groupId = await admin.Groups.CreateAsync(new GroupRepresentation { Name = "group-e2e" });
        Assert.Equal("group-e2e", (await admin.Groups.GetAsync(groupId)).Name);
        Assert.Contains(await admin.Groups.ListAsync(), g => g.Name == "group-e2e");
        await admin.Groups.UpdateAsync(groupId, new GroupRepresentation { Name = "group-e2e-renamed" });
        Assert.Equal("group-e2e-renamed", (await admin.Groups.GetAsync(groupId)).Name);
        await admin.Groups.DeleteAsync(groupId);

        // 8) realms: get current (typed, it-client's own realm-management scope) + create/delete throwaway.
        //
        // Real-server finding (confirmed independently with curl against the live container): creating a
        // brand-new realm is a master-realm-only privilege in Keycloak. No per-realm realm-management role
        // grants it — not even the broadest one — because it is not an operation on an existing realm, it
        // is a global bootstrap capability. The it-client token gets a clean HTTP 403 on the create call,
        // while GET on its own realm succeeds. So the throwaway-realm create/delete below runs through a
        // second AdminClient authenticated as the master-realm bootstrap superuser that Testcontainers.
        // Keycloak provisions by default, exercising RealmsResource fully with a properly privileged caller.
        Assert.Equal(KeycloakFixture.Realm, (await admin.Realms.GetAsync(KeycloakFixture.Realm)).Realm);

        using var masterHttp = new HttpClient();
        var masterTokenProvider = new ClientCredentialsTokenProvider(new MasterPasswordTokenSource(masterHttp, _kc.BaseUrl));
        await using var masterAdmin = await AdminClient.CreateAsync(
            new KeycloakConfig { ServerUrl = _kc.BaseUrl, Realm = "master", ClientId = "admin-cli", ClientSecret = "unused" },
            masterTokenProvider);

        await masterAdmin.Realms.CreateAsync(new RealmRepresentation { Realm = "throwaway-e2e", Enabled = true });
        Assert.Equal("throwaway-e2e", (await masterAdmin.Realms.GetAsync("throwaway-e2e")).Realm);
        Assert.Contains(await masterAdmin.Realms.ListAsync(), r => r.Realm == "throwaway-e2e");
        await masterAdmin.Realms.UpdateAsync("throwaway-e2e",
            new RealmRepresentation { Realm = "throwaway-e2e", Enabled = true, DisplayName = "renamed-e2e" });
        Assert.Equal("renamed-e2e", (await masterAdmin.Realms.GetAsync("throwaway-e2e")).DisplayName);
        await masterAdmin.Realms.DeleteAsync("throwaway-e2e");

        // 9) Raw escape hatch
        var raw = admin.Raw;
        Assert.Equal(KeycloakFixture.Realm, (await raw.GetRealmAsync(KeycloakFixture.Realm)).Realm);
    }
}

/// <summary>Resource-owner-password-credentials token source for the master-realm bootstrap admin
/// (username/password against the built-in public `admin-cli` client — the same grant `kcadm.sh` uses).
/// Test-only: needed solely because realm creation/deletion requires master-realm privileges that no
/// realm's own service account can hold (see the note at step 8 in <see cref="E2ETests"/>).</summary>
internal sealed class MasterPasswordTokenSource : ITokenSource
{
    private const string Username = "admin";
    private const string Password = "admin"; // Testcontainers.Keycloak default bootstrap admin credentials

    private readonly HttpClient _http;
    private readonly string _tokenEndpoint;

    public MasterPasswordTokenSource(HttpClient http, string serverUrl)
    {
        _http = http;
        _tokenEndpoint = $"{serverUrl}/realms/master/protocol/openid-connect/token";
    }

    public async Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default)
    {
        var issuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var form = new Dictionary<string, string>
        {
            ["grant_type"] = "password",
            ["client_id"] = "admin-cli",
            ["username"] = Username,
            ["password"] = Password,
        };
        using var resp = await _http.PostAsync(_tokenEndpoint, new FormUrlEncodedContent(form), ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        var json = await resp.Content.ReadFromJsonAsync<JsonElement>(cancellationToken: ct).ConfigureAwait(false);
        var accessToken = json.GetProperty("access_token").GetString()!;
        var expiresIn = json.TryGetProperty("expires_in", out var e) ? e.GetInt64() : 60L;
        return TokenSet.Create(accessToken, "Bearer", expiresIn, refreshToken: null, idToken: null, scope: null, issuedAt);
    }
}
