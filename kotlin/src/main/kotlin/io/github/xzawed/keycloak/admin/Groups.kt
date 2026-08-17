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
    /** 그룹 생성 후 응답 Location 헤더에서 신규 그룹 id를 추출해 반환한다. */
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
     * id로 주소를 잡아 그룹을 갱신한다. representation.name에 새 이름을 주면 rename이다.
     *
     * ⚠️ 경로(id)와 body(representation)를 합치지 말 것 — 합치면 rename이 조용한 no-op이 된다.
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
