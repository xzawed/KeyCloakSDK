package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.createdId
import io.github.xzawed.keycloak.requireEncodableBody
import jakarta.ws.rs.WebApplicationException
import org.keycloak.representations.idm.ClientRepresentation
import java.net.URI

// Clients.kt — ClientsResource: 공식 admin-client의 org.keycloak.admin.client.resource.ClientsResource를
// 감싸며 모든 호출을 adminCall(AdminClient.kt)로 경계 변환한다(Java ClientsResource 동형).
//
// get()은 UsersResource.get()과 동일한 정책을 따른다: 대상이 없으면 KeycloakAdminException.NotFound를
// 그대로 전파한다.
public class ClientsResource internal constructor(
    private val delegate: org.keycloak.admin.client.resource.ClientsResource,
    // create 를 보내는 URL — clients 컬렉션(AdminClient.clients()). null 이면 아래 1.0.9 생성자로 만든 것이다(createdId.kt).
    private val collection: URI?,
) {
    // 1.0.9 의 생성자 그대로 — Kotlin `internal` 이어도 생성자는 이름이 망글되지 않아 바이트코드에서 public 이고, 그래서 게시된
    // API 다(지우면 kotlin-ci 의 japicmp 가 CONSTRUCTOR_REMOVED 로 막는다). 보낸 URL 을 모르므로 create 는 이름 `clients` 로 판정한다.
    internal constructor(delegate: org.keycloak.admin.client.resource.ClientsResource) : this(delegate, null)

    /**
     * Creates a client and returns the new client's id — the one the response's Location header names, resolved against the
     * request URL (the last path segment, in the clients collection). Throws
     * [io.github.xzawed.keycloak.KeycloakAdminException] (500) when it names none.
     */
    public suspend fun create(representation: ClientRepresentation): String {
        requireEncodableBody(representation)
        return adminCall {
            val response = delegate.create(representation)
            try {
                createdId(response, collection, "clients")
            } finally {
                response.close()
            }
        }
    }

    public suspend fun get(id: String): ClientRepresentation = adminCall { delegate.get(id).toRepresentation() }

    public suspend fun findByClientId(clientId: String): List<ClientRepresentation> = adminCall { delegate.findByClientId(clientId) }

    public suspend fun update(
        id: String,
        representation: ClientRepresentation,
    ) {
        requireEncodableBody(representation)
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
