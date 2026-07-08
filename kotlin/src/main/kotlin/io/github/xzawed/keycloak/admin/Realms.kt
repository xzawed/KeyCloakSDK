package io.github.xzawed.keycloak.admin

import org.keycloak.representations.idm.RealmRepresentation

// Realms.kt — RealmsResource: 공식 admin-client의 org.keycloak.admin.client.resource.RealmsResource를
// 감싸며 모든 호출을 adminCall(AdminClient.kt)로 경계 변환한다(Java RealmsResource 동형).
//
// ⚠️ API 편차(Java와 동일): RealmsResource에는 get(String)/delete(String)가 직접 존재하지 않는다
// (create(RealmRepresentation)만 있고 반환 타입도 void). 개별 렐름 조회/삭제는 realm(name)으로 얻은
// RealmResource의 toRepresentation()/remove()로 위임한다. get()은 대상이 없으면 삼키지 않고
// KeycloakAdminException.NotFound를 그대로 전파한다(UsersResource.get()과 동일한 정책).
public class RealmsResource internal constructor(
    private val delegate: org.keycloak.admin.client.resource.RealmsResource,
) {
    public suspend fun create(representation: RealmRepresentation) {
        adminCall { delegate.create(representation) }
    }

    public suspend fun get(realmName: String): RealmRepresentation = adminCall { delegate.realm(realmName).toRepresentation() }

    public suspend fun delete(realmName: String) {
        adminCall { delegate.realm(realmName).remove() }
    }
}
