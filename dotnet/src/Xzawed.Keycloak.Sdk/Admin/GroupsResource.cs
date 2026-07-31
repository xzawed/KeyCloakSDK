using Keycloak.AuthServices.Sdk.Admin.Models;
using Keycloak.AuthServices.Sdk.Admin.Requests.Groups;

namespace Xzawed.Keycloak.Admin;

public sealed class GroupsResource
{
    private readonly AdminClient _a;
    internal GroupsResource(AdminClient a) => _a = a;

    public Task<string> CreateAsync(GroupRepresentation group, CancellationToken ct = default)
        => _a.CreateReturningIdAsync(c => c.CreateGroupWithResponseAsync(_a.Realm, group, ct), ct);

    public Task<GroupRepresentation> GetAsync(string id, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.GetGroupAsync(_a.Realm, id, ct));

    public Task<IReadOnlyList<GroupRepresentation>> ListAsync(int first = 0, int max = 100, CancellationToken ct = default)
        => _a.CallTypedAsync(async c =>
            (IReadOnlyList<GroupRepresentation>)(await c.GetGroupsAsync(_a.Realm,
                new GetGroupsRequestParameters { First = first, Max = max }, ct)).ToList());

    /// <summary>Update a group. Uses the typed client, which does cover this one.</summary>
    public Task UpdateAsync(string id, GroupRepresentation group, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.UpdateGroupAsync(_a.Realm, id, group, ct));

    public Task DeleteAsync(string id, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.DeleteGroupAsync(_a.Realm, id, ct));
}
