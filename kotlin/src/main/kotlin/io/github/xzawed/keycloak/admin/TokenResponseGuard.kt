package io.github.xzawed.keycloak.admin

import com.fasterxml.jackson.core.JsonFactory
import com.fasterxml.jackson.core.JsonToken
import com.nimbusds.jose.jwk.source.JWKSourceBuilder
import jakarta.ws.rs.HttpMethod
import jakarta.ws.rs.client.ClientRequestContext
import jakarta.ws.rs.client.ClientResponseContext
import jakarta.ws.rs.client.ClientResponseFilter
import jakarta.ws.rs.core.Response
import jakarta.ws.rs.ext.ReaderInterceptor
import jakarta.ws.rs.ext.ReaderInterceptorContext
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream

/**
 * admin 레인의 토큰 응답 검사(Java `TokenResponseGuard` 동형) — 토큰 엔드포인트의 성공 응답이 **비어 있지 않은 JSON 문자열**
 * `access_token` 을 싣지 않으면 그 응답을 거부한다.
 *
 * 왜 여기인가: admin 은 토큰을 자체 소유하고(§4) keycloak-admin-client 내장 TokenManager 가 토큰 응답을 Jackson 으로
 * `AccessTokenResponse` 에 결합한다. Jackson 의 스칼라 강제변환이 숫자·불리언을 문자열로 바꾸고 빈 문자열은 그대로 둬서,
 * admin API 가 `Bearer 12345`·`Bearer true`·`Bearer ` 로 불렸다(실측 — `AdminTokenResponseTest`). 결합 뒤에는 원래 JSON
 * 타입이 남지 않으므로 결합 **앞**의 바이트를 본다. TokenManager 의 부여·갱신 요청도 [AdminClient.buildTimeoutClient] 의
 * 클라이언트로 나가므로 거기에 등록한다.
 *
 * 범위는 POST · 경로 꼬리 [TOKEN_PATH_SUFFIX] · 2xx 응답뿐이다 — 응답 필터가 정한다. admin 자원 응답의 역직렬화는 건드리지
 * 않는다. 오류 상태는 그대로 넘긴다 — 갱신이 400 이면 TokenManager 가 `BadRequestException` 을 받아 client_credentials 로
 * 다시 부여하는 복구 경로가 있다.
 *
 * ⚠️ **판정은 결합이 읽을 바이트로 한다** — 응답 필터가 보는 원시 엔티티가 아니다. RESTEasy 는 엔티티를 ReaderInterceptor
 * 사슬을 거쳐 결합에 넘기고, 그 사슬이 바이트를 바꿀 수 있다: 소비자가 `resteasy.allowGzip=true` 를 켜면
 * GZIPDecodingInterceptor 가 `Content-Encoding: gzip` 을 푼다. 원시 바이트를 판정하던 때는 gzip 으로 온 쓸 수 있는 토큰을
 * 거부해 admin 이 통째로 멈췄다(실측 — 가드 없이는 성공). 그래서 범위 안의 응답은 이 객체를 **가장 안쪽** ReaderInterceptor
 * 로도 등록해([READ_PRIORITY]) 결합 직전의 스트림을 판정한다. 예외는 하나 — 미디어 타입이 없는 2xx 는 결합이 아예 읽지
 * 않으므로(RESTEasy `ClientInvocation.extractResult` 는 200 이면 ResponseProcessingException 을 던지고 그 밖의 2xx 면 null 을
 * 돌려줘 TokenManager 가 NPE 로 멈춘다 — 그 사슬은 ProcessingException 이 그대로다) 응답 필터에서 원시 바이트로 판정한다.
 *
 * 거부는 상수 메시지의 [IOException] 이다. 응답 필터에서 던지면 RESTEasy 가 `ResponseProcessingException` 으로, 엔티티
 * 읽기에서 던지면 `ProcessingException` 을 거쳐 `ResponseProcessingException` 으로 감싸고(그래서 TokenManager 갱신의
 * `BadRequestException` 복구에도 닿지 않는다 — 실측), 그것이 BearerAuthFilter(요청 필터) 밖으로 나가므로 admin 요청은
 * 보내지지 않고, [adminCall] 이 `KeycloakTransportException` 으로 바꾼다(원인 사슬은 [transportCause] 가 `RedactedCause` 로
 * 간다) — null·객체·배열·누락이 이미 실패하던 타입이다. 메시지는 상수다(응답을 인용하지 않는다).
 *
 * ⚠️ **판정은 본문을 상한([MAX_BODY_BYTES])까지만 읽고 쥔다.** 통째로 읽던 때는 힙보다 큰 2xx 본문이 `OutOfMemoryError` 를
 * 냈다 — RESTEasy 가 감싸 결과는 거부였어도 그 순간 JVM 전체가 메모리를 잃었고, JSON 공백으로 부풀린 **쓸 수 있는** 토큰도
 * 그랬다(가드 없는 결합은 그것을 스트리밍으로 통과시킨다). 상한+1 바이트까지 읽어 넘침을 알아채면 쓸 수 없는 토큰과 같은
 * 거부를 던지고 나머지는 읽지 않는다. 버퍼는 본문 크기와 무관하게 하나다.
 *
 * 검사는 Jackson **스트리밍** 파서다 — 데이터 결합·다형 타입이 없고 자체 ObjectMapper 도 아니다(보안 불변식). 최상위
 * `access_token` 은 **전부** 본다 — 결합은 중복 키의 마지막 값을 쓰므로 첫 값만 보면 `{"access_token":"ok","access_token":1}`
 * 이 통과한다. 통과한 바이트는 그대로 되돌려 결합이 refresh_token·expires_in 을 잃지 않게 한다.
 */
internal class TokenResponseGuard :
    ClientResponseFilter,
    ReaderInterceptor {
    override fun filter(
        request: ClientRequestContext,
        response: ClientResponseContext,
    ) {
        if (request.method != HttpMethod.POST ||
            !request.uri.rawPath.endsWith(TOKEN_PATH_SUFFIX) ||
            response.statusInfo.family != Response.Status.Family.SUCCESSFUL
        ) {
            return
        }
        if (response.mediaType != null) {
            request.setProperty(JUDGE_ENTITY, true) // 결합이 읽는 바이트(해제 뒤)는 aroundReadFrom 이 판정한다
            return
        }
        response.entityStream = usableOrReject(response.entityStream)
    }

    override fun aroundReadFrom(context: ReaderInterceptorContext): Any? {
        if (context.getProperty(JUDGE_ENTITY) != true) return context.proceed()
        context.inputStream = usableOrReject(context.inputStream)
        return context.proceed()
    }

    internal companion object {
        internal const val TOKEN_PATH_SUFFIX = "/protocol/openid-connect/token"

        // ReaderInterceptor 로서의 우선순위 — 오름차순으로 도므로 가장 큰 값이 결합(MessageBodyReader) 바로 앞이다.
        internal const val READ_PRIORITY = Int.MAX_VALUE

        // 응답 필터가 범위 안의 교환에 다는 요청 속성 — ReaderInterceptor 가 이것이 있는 엔티티만 판정한다.
        internal val JUDGE_ENTITY: String = TokenResponseGuard::class.java.name + ".judgeEntity"
        internal const val REJECTED = "token endpoint response carries no usable access_token"

        // 판정이 읽고 쥐는 본문의 상한(바이트) — JWKS 응답 상한 그 자체다(NoRedirectResourceRetriever 가 Nimbus 에 넘기는 상수를
        // 그대로 참조한다 — 두 번째 정의 자리를 만들지 않는다).
        internal const val MAX_BODY_BYTES = JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT
        private const val ACCESS_TOKEN = "access_token"
        private val JSON = JsonFactory()

        // 상한+1 바이트까지만 읽는다(넘침을 알아챌 한 바이트) — 넘치거나 쓸 수 없으면 거부, 통과하면 읽은 바이트를 사본 없이 넘긴다.
        private fun usableOrReject(input: InputStream?): ByteArrayInputStream {
            val buf = ByteArray(MAX_BODY_BYTES + 1)
            val n = input?.readNBytes(buf, 0, buf.size) ?: 0
            if (n > MAX_BODY_BYTES || !carriesUsableAccessToken(buf, n)) throw IOException(REJECTED)
            return ByteArrayInputStream(buf, 0, n)
        }

        // ⚠️ 한 인자 형태를 지우지 말 것 — internal 멤버도 바이트코드에서는 public 이라(이름만 맹글링) CI api-compat(japicmp,
        // 게시된 1.0.4 대비)이 그 삭제를 METHOD_REMOVED 로 막는다(실측).
        internal fun carriesUsableAccessToken(body: ByteArray): Boolean = carriesUsableAccessToken(body, body.size)

        /** `body` 의 앞 `length` 바이트가 최상위 JSON 객체이고 그 `access_token` 이 하나 이상이며 전부 비어 있지 않은 문자열이다. 형식이 틀리면 false. */
        internal fun carriesUsableAccessToken(
            body: ByteArray,
            length: Int,
        ): Boolean {
            try {
                JSON.createParser(body, 0, length).use { p ->
                    if (p.nextToken() != JsonToken.START_OBJECT) return false
                    var found = false
                    while (p.nextToken() == JsonToken.FIELD_NAME) {
                        val accessToken = p.currentName() == ACCESS_TOKEN
                        val value = p.nextToken()
                        when {
                            !accessToken -> p.skipChildren()
                            value != JsonToken.VALUE_STRING || p.textLength == 0 -> return false
                            else -> found = true
                        }
                    }
                    return found
                }
            } catch (malformed: IOException) {
                return false // 파서 메시지는 본문을 인용할 수 있다 — 버리고 거부만 한다
            }
        }
    }
}
