package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakAdminException
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakConfigException
import io.github.xzawed.keycloak.KeycloakTransportException
import io.github.xzawed.keycloak.onIo
import jakarta.ws.rs.ProcessingException
import jakarta.ws.rs.WebApplicationException
import jakarta.ws.rs.client.Client
import jakarta.ws.rs.client.ClientBuilder
import kotlinx.coroutines.CancellationException
import org.keycloak.OAuth2Constants
import org.keycloak.admin.client.JacksonProvider
import org.keycloak.admin.client.Keycloak
import org.keycloak.admin.client.KeycloakBuilder
import org.keycloak.admin.client.spi.StreamMessageBodyReader
import java.util.concurrent.TimeUnit

// AdminClient.kt — 관리(admin) API 파사드 진입점. 공식 keycloak-admin-client(Keycloak/KeycloakBuilder)를
// 감싸며 수명주기를 소유한다(AutoCloseable). Java AdminClient(java/keycloak-sdk-admin)와 동형: 기본 생성자는
// KeycloakBuilder 내장 client-credentials 그랜트를 쓴다(내부 TokenManager가 admin 토큰을 자동 획득·갱신) —
// admin은 auth를 직접 알지 못한다(§4). Java도 한때 TokenProvider 기반 생성자를 뒀으나 커스텀 RESTEasy
// ClientRequestFilter가 admin-client 내부 라이브러리와 충돌해 MVP 범위에서 제거한 동일 결정을 상속한다
// (부록 §auth-admin exactConfig — TokenProvider 접착제는 KeycloakClient 파사드 레벨의 시임일 뿐, 이 모듈이
// 실사용하지는 않는다).
public class AdminClient internal constructor(
    private val config: KeycloakConfig,
    private val keycloak: Keycloak,
) : AutoCloseable {
    /**
     * 운영 진입점. `config`의 connect/read 타임아웃을 admin-client의 JAX-RS 클라이언트
     * (`resteasyClient`)에 반드시 주입한다 — 미주입 시 admin 호출이 무한 대기해 호출 스레드를
     * 무한 점유한다(스레드풀 고갈 DoS, 부록 게차 상속).
     */
    public constructor(config: KeycloakConfig) : this(config, buildKeycloak(config))

    /** 파사드가 감싸지 않은 엔드포인트를 위한 탈출구(§4 문서화된 은닉성 예외 — 하위 [Keycloak] 노출). */
    public fun raw(): Keycloak = keycloak

    /** 사용자 CRUD 파사드(Java `UsersResource` 동형). */
    public fun users(): UsersResource = UsersResource(keycloak.realm(config.realm).users())

    /** 클라이언트 CRUD 파사드(Java `ClientsResource` 동형). */
    public fun clients(): ClientsResource = ClientsResource(keycloak.realm(config.realm).clients())

    /** 렐름 조회/생성/삭제 파사드(Java `RealmsResource` 동형 — realm 스코프 없이 최상위 API). */
    public fun realms(): RealmsResource = RealmsResource(keycloak.realms())

    /** 역할(role) CRUD 파사드(Java `RolesResource` 동형). */
    public fun roles(): RolesResource = RolesResource(keycloak.realm(config.realm).roles())

    /** 그룹 CRUD 파사드(Java `GroupsResource` 동형). */
    public fun groups(): GroupsResource = GroupsResource(keycloak.realm(config.realm).groups())

    override fun close() {
        keycloak.close()
    }

    public companion object {
        private fun buildKeycloak(config: KeycloakConfig): Keycloak {
            val secret =
                config.clientSecret
                    ?: throw KeycloakConfigException("clientSecret is required for admin client-credentials")
            return KeycloakBuilder
                .builder()
                .serverUrl(config.serverUrl)
                .realm(config.realm)
                .clientId(config.clientId)
                .clientSecret(String(secret))
                .grantType(OAuth2Constants.CLIENT_CREDENTIALS)
                .resteasyClient(buildTimeoutClient(config))
                .build()
        }

        /**
         * `config`의 connect/read 타임아웃을 admin-client의 JAX-RS 클라이언트에 주입한다.
         *
         * **[JacksonProvider]를 반드시 직접 등록해야 한다.** admin-client는 이 프로바이더를
         * *자기가 만든* 클라이언트에만 등록하므로(`ResteasyClientClassicProvider.newRestEasyClient`
         * → `register(JacksonProvider.class, 100)`), 타임아웃 주입을 위해 우리 클라이언트를
         * `resteasyClient(...)`로 넘기면 그 등록이 유실된다. 함께 잃는 두 설정은
         * `setSerializationInclusion(NON_NULL)`(null 필드 미전송)과
         * `configure(FAIL_ON_UNKNOWN_PROPERTIES, false)`(서버의 미지 필드 무시)다.
         *
         * 유실 시 클라이언트/서버 버전 스큐에서 양방향으로 깨진다 — admin-client가 서버보다 앞선
         * 필드를 가지면(예: 26.0.11 `UserRepresentation.verifiableCredentials`) `null`을 실어
         * 보내 구버전 서버가 400을 내고, 반대로 서버가 우리 모델에 없는 필드를 반환하면 응답
         * 파싱이 깨진다. Java `AdminClient.buildTimeoutClient`와 동형.
         *
         * 기반 빌더는 [ClientBuilder.newBuilder]를 유지한다 —
         * `ResteasyClientClassicProvider.createClientBuilder()`로 바꾸면 커넥션 풀이 기본 50에서
         * 10으로 조용히 줄어든다.
         *
         * `internal` 가시성은 프로바이더 등록 회귀테스트를 위한 시임이다(Java의 패키지 전용 seam과 동형).
         */
        internal fun buildTimeoutClient(config: KeycloakConfig): Client =
            ClientBuilder
                .newBuilder()
                .connectTimeout(config.connectTimeout.toMillis(), TimeUnit.MILLISECONDS)
                .readTimeout(config.readTimeout.toMillis(), TimeUnit.MILLISECONDS)
                .register(JacksonProvider::class.java, 100)
                .register(StreamMessageBodyReader::class.java)
                .build()
    }
}

/**
 * admin-client의 블로킹 호출을 [onIo](jwt.kt의 `runInterruptible` 래퍼 재사용)로 옮기고, 경계
 * 예외를 SDK 타입으로 변환한다(부록 §auth-admin exactConfig). [WebApplicationException]은
 * status(404/409/403/그 외)로 [KeycloakAdminException]의 리프 타입에 매핑하고, [ProcessingException]
 * ("RESTEASY004655" 류 소켓/타임아웃/TLS 실패 — admin-client는 네트워크 실패까지 이 타입으로 감싼다)은
 * [KeycloakTransportException]으로 변환한다. [CancellationException]은 구조적 동시성을 지키기 위해
 * catch 체인 최상단에서 최우선으로 재던진다.
 */
internal suspend fun <T> adminCall(block: () -> T): T =
    try {
        onIo(block)
    } catch (e: CancellationException) {
        throw e
    } catch (e: WebApplicationException) {
        throw translateAdminException(e)
    } catch (e: ProcessingException) {
        throw KeycloakTransportException("Admin request failed", e)
    }

// Java AdminExceptions.translate 동형: status→리프 타입 매핑(부록 §auth-admin exactConfig).
internal fun translateAdminException(e: WebApplicationException): KeycloakAdminException {
    val status = e.response?.status ?: 0
    val body = safeBody(e)
    return when (status) {
        404 -> KeycloakAdminException.NotFound(status, body, e)
        409 -> KeycloakAdminException.Conflict(status, body, e)
        403 -> KeycloakAdminException.Forbidden(status, body, e)
        else -> KeycloakAdminException.Other(status, body, e)
    }
}

// Java AdminExceptions.safeBody 동형: entity가 있으면 본문을, 없거나 읽기 실패하면 예외 message로 폴백한다.
private fun safeBody(e: WebApplicationException): String? =
    try {
        val response = e.response
        if (response != null && response.hasEntity()) response.readEntity(String::class.java) else e.message
    } catch (ex: RuntimeException) {
        e.message
    }
