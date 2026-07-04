using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Admin;

/// <summary>Realm resource — NOT realm-scoped; the realm name is the argument. get is typed; create/delete are raw.</summary>
public sealed class RealmsResource
{
    private readonly AdminClient _a;
    internal RealmsResource(AdminClient a) => _a = a;

    public async Task CreateAsync(RealmRepresentation realm, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "admin/realms")
        { Content = System.Net.Http.Json.JsonContent.Create(realm) };
        await _a.SendRawAsync(req, ct).ConfigureAwait(false);
    }

    public Task<RealmRepresentation> GetAsync(string realmName, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.GetRealmAsync(realmName, ct));

    public async Task DeleteAsync(string realmName, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, $"admin/realms/{Uri.EscapeDataString(realmName)}");
        await _a.SendRawAsync(req, ct).ConfigureAwait(false);
    }
}
