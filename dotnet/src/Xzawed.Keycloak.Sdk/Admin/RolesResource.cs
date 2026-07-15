using System.Net.Http.Json;
using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Admin;

/// <summary>Realm roles — raw REST, addressed by NAME (API deviation vs id-addressed users/clients/groups).</summary>
public sealed class RolesResource
{
    private readonly AdminClient _a;
    internal RolesResource(AdminClient a) => _a = a;

    public async Task CreateAsync(RoleRepresentation role, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, $"admin/realms/{_a.Realm}/roles")
        { Content = JsonContent.Create(role) };
        (await _a.SendRawAsync(req, ct).ConfigureAwait(false)).Dispose();
    }

    public Task<RoleRepresentation> GetAsync(string name, CancellationToken ct = default)
        => _a.GetJsonAsync<RoleRepresentation>($"admin/realms/{_a.Realm}/roles/{Uri.EscapeDataString(name)}", ct);

    public async Task<IReadOnlyList<RoleRepresentation>> ListAsync(CancellationToken ct = default)
        => await _a.GetJsonAsync<List<RoleRepresentation>>($"admin/realms/{_a.Realm}/roles", ct).ConfigureAwait(false);

    public async Task DeleteAsync(string name, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, $"admin/realms/{_a.Realm}/roles/{Uri.EscapeDataString(name)}");
        (await _a.SendRawAsync(req, ct).ConfigureAwait(false)).Dispose();
    }
}
