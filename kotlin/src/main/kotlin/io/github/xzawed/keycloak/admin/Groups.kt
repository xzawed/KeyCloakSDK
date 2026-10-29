package io.github.xzawed.keycloak.admin

import org.keycloak.admin.client.CreatedResponseUtil
import org.keycloak.representations.idm.GroupRepresentation

// Groups.kt — GroupsResource: 공식 admin-client의 org.keycloak.admin.client.resource.GroupsResource를
// 감싸며 모든 호출을 adminCall(AdminClient.kt)로 경계 변환한다(Java GroupsResource 동형).
//
// ⚠️ API 편차(Java와 동일): 생성 메서드명은 create가 아니라 add(GroupRepresentation)이고, 단일 그룹
// 접근자는 get이 아니라 group(String)이다(delete도 직접 존재하지 않아 group(id).remove()로 위임).
// get()은 대상이 없으면 삼키지 않고 KeycloakAdminException.NotFound를 그대로 전파한다
// (UsersResource.get()과 동일한 정책).
public class GroupsResource internal constructor(
    private val delegate: org.keycloak.admin.client.resource.GroupsResource,
) {
    /** Creates a group, then extracts the new group's id from the response's Location header and returns it. */
    public suspend fun create(representation: GroupRepresentation): String =
        adminCall {
            val response = delegate.add(representation)
            try {
                CreatedResponseUtil.getCreatedId(response)
            } finally {
                response.close()
            }
        }

    public suspend fun get(id: String): GroupRepresentation = adminCall { delegate.group(id).toRepresentation() }

    public suspend fun list(
        first: Int,
        max: Int,
    ): List<GroupRepresentation> = adminCall { delegate.groups(first, max) }

    /**
     * Updates the group, addressed by id. Giving a new name in representation.name makes it a rename.
     *
     * ⚠️ Do not merge the path (id) and the body (representation) — merging them turns a rename into a silent no-op.
     */
    public suspend fun update(
        id: String,
        representation: GroupRepresentation,
    ) {
        adminCall { delegate.group(id).update(representation) }
    }

    public suspend fun delete(id: String) {
        adminCall { delegate.group(id).remove() }
    }
}
