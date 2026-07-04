using Keycloak.AuthServices.Sdk.Admin.Models;
using Keycloak.AuthServices.Sdk.Admin.Requests.Users;

namespace Xzawed.Keycloak.Admin;

public sealed class UsersResource
{
    private readonly AdminClient _a;
    internal UsersResource(AdminClient a) => _a = a;

    public Task<string> CreateAsync(UserRepresentation user, CancellationToken ct = default)
        => _a.CreateReturningIdAsync(c => c.CreateUserWithResponseAsync(_a.Realm, user, ct), ct);

    public Task<UserRepresentation> GetAsync(string id, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.GetUserAsync(_a.Realm, id, cancellationToken: ct));   // 404 => NotFound

    public Task<IReadOnlyList<UserRepresentation>> SearchAsync(string? username, int first = 0, int max = 100, CancellationToken ct = default)
        => _a.CallTypedAsync(async c =>
            (IReadOnlyList<UserRepresentation>)(await c.GetUsersAsync(_a.Realm,
                new GetUsersRequestParameters { Username = username, First = first, Max = max }, ct)).ToList());

    public Task UpdateAsync(string id, UserRepresentation user, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.UpdateUserAsync(_a.Realm, id, user, ct));

    public Task DeleteAsync(string id, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.DeleteUserAsync(_a.Realm, id, ct));
}
