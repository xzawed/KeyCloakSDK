package io.github.xzawed.keycloak.admin

import org.keycloak.representations.idm.RoleRepresentation

// Roles.kt — RolesResource: 공식 admin-client의 org.keycloak.admin.client.resource.RolesResource를
// 감싸며 모든 호출을 adminCall(AdminClient.kt)로 경계 변환한다(Java RolesResource 동형).
//
// ⚠️ API 편차(Java와 동일): 삭제 메서드명은 delete가 아니라 deleteRole(String)이다. get()은 대상이
// 없으면 삼키지 않고 KeycloakAdminException.NotFound를 그대로 전파한다(UsersResource.get()과 동일한 정책).
public class RolesResource internal constructor(
    private val delegate: org.keycloak.admin.client.resource.RolesResource,
) {
    public suspend fun create(representation: RoleRepresentation) {
        adminCall { delegate.create(representation) }
    }

    public suspend fun get(name: String): RoleRepresentation = adminCall { delegate.get(name).toRepresentation() }

    public suspend fun list(): List<RoleRepresentation> = adminCall { delegate.list() }

    public suspend fun delete(name: String) {
        adminCall { delegate.deleteRole(name) }
    }
}
