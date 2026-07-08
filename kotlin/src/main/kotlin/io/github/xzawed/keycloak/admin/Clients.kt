package io.github.xzawed.keycloak.admin

import jakarta.ws.rs.WebApplicationException
import org.keycloak.admin.client.CreatedResponseUtil
import org.keycloak.representations.idm.ClientRepresentation

// Clients.kt — ClientsResource: 공식 admin-client의 org.keycloak.admin.client.resource.ClientsResource를
// 감싸며 모든 호출을 adminCall(AdminClient.kt)로 경계 변환한다(Java ClientsResource 동형).
//
// get()은 UsersResource.get()과 동일한 정책을 따른다: 대상이 없으면 KeycloakAdminException.NotFound를
// 그대로 전파한다.
public class ClientsResource internal constructor(
    private val delegate: org.keycloak.admin.client.resource.ClientsResource,
) {
    /** 클라이언트 생성 후 응답 Location 헤더에서 신규 클라이언트 id를 추출해 반환한다. */
    public suspend fun create(representation: ClientRepresentation): String =
        adminCall {
            val response = delegate.create(representation)
            try {
                CreatedResponseUtil.getCreatedId(response)
            } finally {
                response.close()
            }
        }

    public suspend fun get(id: String): ClientRepresentation = adminCall { delegate.get(id).toRepresentation() }

    public suspend fun findByClientId(clientId: String): List<ClientRepresentation> = adminCall { delegate.findByClientId(clientId) }

    public suspend fun update(
        id: String,
        representation: ClientRepresentation,
    ) {
        adminCall { delegate.get(id).update(representation) }
    }

    /**
     * admin-client의 `delegate.delete(id)`는 [jakarta.ws.rs.core.Response]를 반환하는 JAX-RS 프록시
     * 메서드라 4xx/5xx 응답에서도 예외를 던지지 않는다(void 반환 메서드만 자동 throw한다). 상태 코드를
     * 직접 검사해 실패 시 [WebApplicationException]을 던져 [adminCall] 경계에서 SDK 예외로 변환한다.
     */
    public suspend fun delete(id: String) {
        adminCall {
            val response = delegate.delete(id)
            try {
                if (response.status >= 400) {
                    throw WebApplicationException(response)
                }
            } finally {
                response.close()
            }
        }
    }
}
