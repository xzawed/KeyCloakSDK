package io.github.xzawed.keycloak.admin

import jakarta.ws.rs.WebApplicationException
import org.keycloak.admin.client.CreatedResponseUtil
import org.keycloak.representations.idm.UserRepresentation

// Users.kt — UsersResource: 공식 admin-client의 org.keycloak.admin.client.resource.UsersResource를
// 감싸며 모든 호출을 adminCall(AdminClient.kt)로 경계 변환한다(Java UsersResource 동형). 모델 타입은
// admin-client의 UserRepresentation을 그대로 노출한다(§4 문서화된 은닉성 예외).
//
// get()은 대상이 없으면 삼키지 않고 KeycloakAdminException.NotFound를 그대로 전파한다(Java의
// Optional.of(...) 래핑은 항상 non-empty라 사실상 무의미한 관용이었다 — Kotlin은 값을 직접 반환한다).
public class UsersResource internal constructor(
    private val delegate: org.keycloak.admin.client.resource.UsersResource,
) {
    /** 사용자 생성 후 응답 Location 헤더에서 신규 사용자 id를 추출해 반환한다. */
    public suspend fun create(representation: UserRepresentation): String =
        adminCall {
            val response = delegate.create(representation)
            try {
                CreatedResponseUtil.getCreatedId(response)
            } finally {
                response.close()
            }
        }

    public suspend fun get(id: String): UserRepresentation = adminCall { delegate.get(id).toRepresentation() }

    public suspend fun search(
        username: String,
        first: Int,
        max: Int,
    ): List<UserRepresentation> = adminCall { delegate.search(username, first, max) }

    public suspend fun update(
        id: String,
        representation: UserRepresentation,
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
