using System.Net.Http.Json;
using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Admin;

/// <summary>Clients resource — raw REST (no typed client in Keycloak.AuthServices). id = internal UUID.</summary>
public sealed class ClientsResource
{
    private readonly AdminClient _a;
    internal ClientsResource(AdminClient a) => _a = a;

    /// <summary>Creates a client and returns its internal id (UUID) — the one the answer's <c>Location</c> names,
    /// resolved against the request URL (the last path segment, in the clients collection). Throws
    /// <see cref="KeycloakAdminException"/> (500) when it names none.</summary>
    public Task<string> CreateAsync(ClientRepresentation client, CancellationToken ct = default)
        => _a.CreateRawReturningIdAsync($"admin/realms/{_a.Realm}/clients", client, ct);

    public Task<ClientRepresentation> GetAsync(string id, CancellationToken ct = default)
        => _a.GetJsonAsync<ClientRepresentation>($"admin/realms/{_a.Realm}/clients/{id}", ct);

    public async Task<IReadOnlyList<ClientRepresentation>> FindByClientIdAsync(string clientId, CancellationToken ct = default)
        => await _a.GetJsonAsync<List<ClientRepresentation>>(
            $"admin/realms/{_a.Realm}/clients?clientId={Uri.EscapeDataString(clientId)}", ct).ConfigureAwait(false);

    public async Task UpdateAsync(string id, ClientRepresentation client, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Put, $"admin/realms/{_a.Realm}/clients/{id}")
        { Content = JsonContent.Create(client) };
        await _a.WriteRawAsync(req, ct).ConfigureAwait(false);
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, $"admin/realms/{_a.Realm}/clients/{id}");
        await _a.WriteRawAsync(req, ct).ConfigureAwait(false);
    }
}
