package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakAdminException
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakConfigException
import io.github.xzawed.keycloak.KeycloakTransportException
import io.github.xzawed.keycloak.RESPONSE_MAX_HEADER_COUNT
import io.github.xzawed.keycloak.RESPONSE_MAX_LINE_LENGTH
import io.github.xzawed.keycloak.RedactedCause
import io.github.xzawed.keycloak.onIo
import jakarta.ws.rs.Priorities
import jakarta.ws.rs.ProcessingException
import jakarta.ws.rs.WebApplicationException
import jakarta.ws.rs.client.Client
import jakarta.ws.rs.client.ClientBuilder
import jakarta.ws.rs.client.ClientResponseFilter
import jakarta.ws.rs.client.ResponseProcessingException
import jakarta.ws.rs.ext.ReaderInterceptor
import kotlinx.coroutines.CancellationException
import org.apache.http.HttpException
import org.apache.http.HttpHost
import org.apache.http.MalformedChunkCodingException
import org.apache.http.client.config.RequestConfig
import org.apache.http.client.methods.HttpRequestBase
import org.apache.http.client.protocol.HttpClientContext
import org.apache.http.config.ConnectionConfig
import org.apache.http.config.MessageConstraints
import org.apache.http.conn.HttpClientConnectionManager
import org.apache.http.impl.conn.PoolingHttpClientConnectionManager
import org.apache.http.protocol.HttpContext
import org.jboss.resteasy.client.jaxrs.ClientHttpEngine
import org.jboss.resteasy.client.jaxrs.ResteasyClientBuilder
import org.jboss.resteasy.client.jaxrs.engines.HttpContextProvider
import org.jboss.resteasy.client.jaxrs.internal.ClientInvocation
import org.keycloak.OAuth2Constants
import org.keycloak.admin.client.JacksonProvider
import org.keycloak.admin.client.Keycloak
import org.keycloak.admin.client.KeycloakBuilder
import org.keycloak.admin.client.spi.StreamMessageBodyReader
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext

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
         *
         * [TokenResponseGuard]도 등록한다 — 내장 TokenManager 의 토큰 요청도 이 클라이언트로 나가고, 그 응답의
         * 숫자·불리언·빈 문자열 `access_token` 을 Jackson 이 문자열로 받아 admin API 를 그 값의 Bearer 로 불렀다. 응답 필터
         * (범위)와 **가장 안쪽** ReaderInterceptor(판정 — 결합이 읽는 바이트, gzip 해제 뒤) 두 계약으로 건다.
         *
         * 엔진은 RESTEasy 가 짓던 그대로 짓고([BoundedEngineBuilder] — 빌더의 타임아웃·풀 크기 50 을 읽는다) 연결 구성에 응답 틀의
         * 한도만 더한다(줄 [RESPONSE_MAX_LINE_LENGTH] · 헤더 [RESPONSE_MAX_HEADER_COUNT] — auth 레인과 같은 값). HttpCore 의 기본은
         * 한도가 없어(-1) 짧은 청크 본문 뒤 4 KiB 트레일러 줄 32 MiB 를 담았다 — 토큰 수락 · 호출 하나 74 MB(실측
         * `AdminResponseFramingTest`). Java `AdminClient.buildTimeoutClient` 와 동형.
         */
        internal fun buildTimeoutClient(config: KeycloakConfig): Client {
            val builder =
                ClientBuilder
                    .newBuilder()
                    .connectTimeout(config.connectTimeout.toMillis(), TimeUnit.MILLISECONDS)
                    .readTimeout(config.readTimeout.toMillis(), TimeUnit.MILLISECONDS) as ResteasyClientBuilder
            builder.httpEngine(BoundedEngineBuilder().resteasyClientBuilder(builder).build())
            return builder
                .register(JacksonProvider::class.java, 100)
                .register(StreamMessageBodyReader::class.java)
                .register(
                    TokenResponseGuard(),
                    mapOf<Class<*>, Int>(
                        ClientResponseFilter::class.java to Priorities.USER,
                        ReaderInterceptor::class.java to TokenResponseGuard.READ_PRIORITY,
                    ),
                ).build()
        }
    }
}

/**
 * RESTEasy 의 기본 엔진 빌더 그대로에 응답 틀의 한도만 더한다([AdminClient.buildTimeoutClient]). 그 클래스는 RESTEasy 6.2 에서 제거 예정으로
 * 표시돼 있지만 RESTEasy 자신이 기본 엔진을 그것으로 짓는다 — 제거되면 여기가 컴파일되지 않아 다시 볼 자리를 알린다. 지은 엔진은
 * [AdminEngine] 이 감싼다 — 교환마다 읽지 않고 끊을 손잡이를 달아, 가드가 거부한 응답의 나머지를 HttpCore 가 비우지 않게 한다.
 */
@Suppress("DEPRECATION")
private class BoundedEngineBuilder : org.jboss.resteasy.client.jaxrs.engines.ClientHttpEngineBuilder43() {
    override fun createEngine(
        cm: HttpClientConnectionManager?,
        rcBuilder: RequestConfig.Builder?,
        defaultProxy: HttpHost?,
        responseBufferSize: Int,
        verifier: HostnameVerifier?,
        theContext: SSLContext?,
    ): ClientHttpEngine {
        // 풀 크기가 0 보다 크면 RESTEasy 는 풀을 짓는다(기본 50) — 다른 것이 오면 여기서 터져 조용히 한도를 잃지 않는다
        (cm as PoolingHttpClientConnectionManager).defaultConnectionConfig = ADMIN_BOUNDED_HEAD
        // RESTEasy 는 ApacheHttpClient43Engine 을 짓는다 — 다른 것이 오면 여기서 터져 조용히 끊기를 잃지 않는다
        val built = super.createEngine(cm, rcBuilder, defaultProxy, responseBufferSize, verifier, theContext)
        return AdminEngine(built as org.jboss.resteasy.client.jaxrs.engines.ApacheHttpClient43Engine)
    }
}

/**
 * admin 레인의 RESTEasy 엔진(Java `AdminEngine` 동형) — RESTEasy 가 지은 엔진([owner] — 타임아웃·풀·응답 틀의 한도)의 HttpClient 를 그대로
 * 쓰고, 교환마다 그 교환을 **읽지 않고 끊을** 손잡이([Exchange])를 요청 속성 [EXCHANGE] 에 단다. 응답 필터와 ReaderInterceptor 가 같은
 * 속성을 본다([TokenResponseGuard] 가 거부할 때 쓴다).
 *
 * 왜: 거부한 응답의 스트림을 닫으면 HttpCore 의 닫기(`ContentLengthInputStream`·`ChunkedInputStream.close`)가 나머지를 EOF 까지 비운다 —
 * 거부한 64 MiB 본문을 서버가 끝까지 썼고, 1 바이트 청크면 할당이 비운 양을 따라 자랐고, 멈춘 서버 앞에서 거부가 읽기 타임아웃을
 * 기다렸다(실측 `AdminRejectedResponseCutTest`). auth 레인([io.github.xzawed.keycloak.BoundedTransport] 의 cut)과 같은 규칙으로 바꾼다:
 * EOF 까지 읽은 본문만 연결을 풀로 돌려주고, 그 밖의 끝은 읽기 타임아웃을 0 으로 둔 채 요청을 중단한다 — HttpClient 가 연결을
 * SO_LINGER 0 으로 닫고 풀에서 뺀다(`ConnectionHolder.abortConnection`). auth 의 운송 객체를 부르지 않는다 — 그 객체를 건드리면 admin 만
 * 쓰는 소비자에게도 auth 의 프로세스 풀이 지어진다.
 *
 * ⚠️ 엔진을 새로 짓지 않는다 — [owner] 의 HttpClient 를 넘겨받고 설정 넷(응답 버퍼 · 검증기 · TLS 근원 · 리다이렉트)을 옮긴다. HttpClient
 * 를 닫는 것은 [owner] 의 몫이다([close]). 손잡이가 쥘 문맥은 RESTEasy 가 교환마다 묻는 `HttpContextProvider`(이 엔진 자신 —
 * [getContext])로 건넨다 — [loadHttpMethod] 가 만든 것을 같은 스레드의 바로 다음 물음(`invoke` 안, `httpClient.execute` 직전)이 가져간다.
 */
@Suppress("DEPRECATION")
internal class AdminEngine(
    private val owner: org.jboss.resteasy.client.jaxrs.engines.ApacheHttpClient43Engine,
) : org.jboss.resteasy.client.jaxrs.engines.ApacheHttpClient43Engine(owner.httpClient, false),
    HttpContextProvider {
    init {
        responseBufferSize = owner.responseBufferSize
        hostnameVerifier = owner.hostnameVerifier
        sslContext = owner.sslContext
        isFollowRedirects = owner.isFollowRedirects
        // 람다를 두지 않는다 — 그 숨은 클래스는 이름으로 적재되지 않아 파사드를 걷는 시험(HostilePathMatrixTest)이 실패했다(Java 실측)
        httpContextProvider = this
    }

    override fun loadHttpMethod(
        request: ClientInvocation,
        httpMethod: HttpRequestBase,
    ) {
        super.loadHttpMethod(request, httpMethod)
        val context = HttpClientContext.create()
        request.mutableProperties[EXCHANGE] = Exchange(httpMethod, context)
        NEXT_CONTEXT.set(context)
    }

    // [loadHttpMethod] 가 둔 문맥을 가져가고 지운다 — RESTEasy 가 같은 교환에서 곧바로 묻는다.
    override fun getContext(): HttpContext? {
        val context = NEXT_CONTEXT.get()
        NEXT_CONTEXT.remove()
        return context
    }

    override fun close() {
        try {
            super.close()
        } finally {
            owner.close()
        }
    }

    /** 교환 하나의 끊기 손잡이 — 그 요청과, 실행이 연결을 적는 문맥. */
    internal class Exchange(
        private val request: HttpRequestBase,
        private val context: HttpClientContext,
    ) {
        /**
         * 읽지 않고 끊는다 — 연결의 읽기 타임아웃을 0 으로 두고(JSSE 는 TLS 1.3 을 닫을 때 받은 바이트가 없으면 읽기 타임아웃만큼 한 번 더
         * 읽어 기다린다 — 타임아웃이 0 이면 읽지 않는다) 요청을 중단한다. 본문을 EOF 까지 읽어 이미 풀로 돌아간 연결은 건드리지 않는다 —
         * 그 대리자는 떨어져 나갔고(읽기 타임아웃 설정이 실패한다) 중단은 아무것도 하지 않는다(풀의 연결은 다른 교환의 것이다).
         */
        fun cut() {
            val connection = context.connection
            if (connection != null) {
                try {
                    connection.socketTimeout = 0
                } catch (returned: RuntimeException) {
                    // 이미 풀로 돌아갔다 — 이 교환의 것이 아니다
                }
            }
            request.abort()
        }
    }

    internal companion object {
        /** 교환의 끊기 손잡이([Exchange])를 담는 요청 속성. */
        internal val EXCHANGE: String = AdminEngine::class.java.name + ".exchange"
        private val NEXT_CONTEXT = ThreadLocal<HttpClientContext>()
    }
}

/** 응답 머리 줄·헤더 수(트레일러 포함)의 한도 — auth 레인과 같은 값. */
private val ADMIN_BOUNDED_HEAD: ConnectionConfig =
    ConnectionConfig
        .custom()
        .setMessageConstraints(
            MessageConstraints
                .custom()
                .setMaxLineLength(RESPONSE_MAX_LINE_LENGTH)
                .setMaxHeaderCount(RESPONSE_MAX_HEADER_COUNT)
                .build(),
        ).build()

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
        throw KeycloakTransportException("Admin request failed", transportCause(e))
    }

// ⚠️ [ResponseProcessingException] 은 응답을 **받았으나** 읽지 못했다는 JAX-RS 의 표시다 — 그 아래 Jackson 예외가
// 본문을 인용한다(「Unrecognized token '<본문>'」·JSON 문자열 값·expires_in 값). 내장 TokenManager 가 형식이
// 틀린 토큰 응답을 받으면 여기로 온다(`AuthMalformedResponseTest`). 그 사슬은 [RedactedCause] 로 갈아 끼우고,
// 응답이 없는 전송 실패(연결 거부·타임아웃·TLS)는 진단에 필요한 메시지를 그대로 둔다.
// ⚠️ 이 아래의 [WebApplicationException] 도 같다 — 메시지가 아니라 쥔 Response 가 응답을 낸다. 내장 TokenManager 가 BearerAuthFilter
// 안에서 토큰 엔드포인트의 오류를 받으면 RESTEasy 는 그 본문을 bufferEntity 한 Response 를 NotAuthorizedException 등에 쥐여
// ProcessingException 으로 감싸고, 그 Response 는 close() 뒤에도 readEntity(String) 가 본문을 그대로 돌려준다(버퍼된 엔티티는 닫힘 검사를
// 건너뛴다 — 닫기로는 막지 못한다, 실측). 그 본문은 그 요청의 Basic 시크릿을 되울릴 수 있다(`AdminTokenEchoTest`). 자원 오류는 여기로
// 오지 않는다 — [translateAdminException] 이 받아 본문을 keycloakError 로 싣는다(그대로).
// ⚠️ RESTEasy 의 HttpCore 틀 오류도 응답의 줄을 싣는다 — 「Invalid header: <줄>」·「Status line contains invalid status code: <줄>」(머리 —
// ProtocolException, 곧 HttpException)·「Bad chunk header: <줄>」(본문 — MalformedChunkCodingException, 미디어 타입 없는 2xx 를 닫을 때).
// 실측 `AdminResponseFramingTest`. HttpCore 의 ParseException 은 늘 ProtocolException 안에 실려 와 따로 적지 않는다(Java 의 변이: 그 이름을
// 빼도 시험이 통과했다). auth 레인은 운송이 먼저 상수 메시지로 바꾼다(BoundedTransport.shield).
internal fun transportCause(e: ProcessingException): Throwable =
    if (generateSequence<Throwable>(e) { it.cause }.take(16).any { quotesResponse(it) }) RedactedCause.of(e) else e

private fun quotesResponse(t: Throwable): Boolean =
    t is ResponseProcessingException || t is WebApplicationException || t is HttpException || t is MalformedChunkCodingException

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
