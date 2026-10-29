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
    /** Creates a client, then extracts the new client's id from the response's Location header and returns it. */
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
     * admin-client's `delegate.delete(id)` is a JAX-RS proxy method that returns a [jakarta.ws.rs.core.Response], so it
     * does not throw even on a 4xx/5xx response (only void-returning methods throw automatically). The status code is
     * checked directly, and on failure a [WebApplicationException] is thrown, which the [adminCall] boundary converts to
     * an SDK exception.
     */
    public suspend fun delete(id: String) {
        adminCall {
            val response = delegate.delete(id)
            try {
                if (response.status >= 400) {
                    // close 전에 버퍼링해야 경계 변환이 Keycloak 에러 본문을 읽을 수 있다(getCreatedId와 동일 관용).
                    response.bufferEntity()
                    throw WebApplicationException(response)
                }
            } finally {
                response.close()
            }
        }
    }
}
