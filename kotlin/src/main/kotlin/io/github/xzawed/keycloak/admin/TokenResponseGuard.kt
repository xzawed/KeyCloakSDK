package io.github.xzawed.keycloak.admin

import com.fasterxml.jackson.core.JsonFactory
import com.fasterxml.jackson.core.JsonToken
import io.github.xzawed.keycloak.ResponseTooLargeException
import io.github.xzawed.keycloak.TOKEN_RESPONSE_MAX_BYTES
import io.github.xzawed.keycloak.readWithinCap
import jakarta.ws.rs.HttpMethod
import jakarta.ws.rs.client.ClientRequestContext
import jakarta.ws.rs.client.ClientResponseContext
import jakarta.ws.rs.client.ClientResponseFilter
import jakarta.ws.rs.core.Response
import jakarta.ws.rs.ext.ReaderInterceptor
import jakarta.ws.rs.ext.ReaderInterceptorContext
import java.io.ByteArrayInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream

/**
 * admin 레인의 토큰 응답 검사(Java `TokenResponseGuard` 동형) — 토큰 엔드포인트의 성공 응답이 **HTTP 필드 값이 실을 수 있는 비어 있지
 * 않은 JSON 문자열** `access_token` 을 싣지 않으면([fieldValueSafe]) 그 응답을 거부한다.
 *
 * 왜 여기인가: admin 은 토큰을 자체 소유하고(§4) keycloak-admin-client 내장 TokenManager 가 토큰 응답을 Jackson 으로
 * `AccessTokenResponse` 에 결합한다. Jackson 의 스칼라 강제변환이 숫자·불리언을 문자열로 바꾸고 빈 문자열은 그대로 둬서,
 * admin API 가 `Bearer 12345`·`Bearer true`·`Bearer ` 로 불렸다(실측 — `AdminTokenResponseTest`). 결합 뒤에는 원래 JSON
 * 타입이 남지 않으므로 결합 **앞**의 바이트를 본다. TokenManager 의 부여·갱신 요청도 [AdminClient.buildTimeoutClient] 의
 * 클라이언트로 나가므로 거기에 등록한다.
 *
 * 판정의 범위는 POST · 경로 꼬리 [TOKEN_PATH_SUFFIX] · 2xx 응답뿐이다 — 응답 필터가 정한다. admin 자원 응답의 역직렬화는
 * 건드리지 않는다. 오류 상태는 판정하지 않고 넘긴다 — 갱신이 400 이면 TokenManager 가 `BadRequestException` 을 받아 client_credentials 로
 * 다시 부여하는 복구 경로가 있다. ⚠️ 다만 그 본문(과 admin 이 닫힐 때 TokenManager 가 보내는 logout 의 오류 본문 —
 * [LOGOUT_PATH_SUFFIX])은 상한([TOKEN_RESPONSE_MAX_BYTES])까지만 읽어 바이트 그대로 넘긴다 — RESTEasy 가 예외에 담으려고 오류
 * 본문을 **통째로** 버퍼에 읽기 때문이다(`ClientInvocation.extractResult` · void 추출기의 `bufferEntity`, 실측: 400 + 32 MiB 에
 * admin 호출 하나가 154–210 MiB, close() 가 101 MiB). 넘치면 [ResponseTooLargeException] 으로 거부한다 — 아래의 거부와 같은
 * 길로 `KeycloakTransportException` 이 되고(복구 경로에는 닿지 않는다), close() 의 logout 실패는 admin-client 가 삼킨다.
 * 오류 본문의 상한은 원시 바이트로 잰다 — 그 버퍼링은 ReaderInterceptor(gzip 해제)를 거치지 않는다.
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
 * ⚠️ **판정은 본문을 상한([TOKEN_RESPONSE_MAX_BYTES] — auth 레인과 같은 상수)까지만 읽고 쥔다.** 통째로 읽던 때는 힙보다 큰
 * 2xx 본문이 `OutOfMemoryError` 를 냈다 — RESTEasy 가 감싸 결과는 거부였어도 그 순간 JVM 전체가 메모리를 잃었고, JSON 공백으로
 * 부풀린 **쓸 수 있는** 토큰도 그랬다(가드 없는 결합은 그것을 스트리밍으로 통과시킨다). [readWithinCap] 으로 상한+1 바이트까지
 * 읽어 넘침을 알아채면 나머지는 읽지 않고 그 연결을 끊은 뒤(`release` — [AdminEngine]) 쓸 수 없는 토큰과 같은 거부를 던진다. 그
 * 읽기(JDK 17·21 의 `InputStream.readNBytes` 기본 구현 — RESTEasy·HttpCore 의 스트림은 재정의하지 않는다)는 남은 길이 너머를 요청하지
 * 않고 **읽은 만큼만** 할당한다. ⚠️ 끊지 않고 닫기만 하면 HttpCore 가 나머지를 EOF 까지 비운다 — 받는 바이트에 상한이 없었고, 1 바이트
 * 청크면 청크 머리마다 문자열을 만들어 할당이 비운 양을 따라 자랐다(실측 `AdminRejectedResponseCutTest`).
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
        if (request.method != HttpMethod.POST) return
        val path = request.uri.rawPath
        val token = path.endsWith(TOKEN_PATH_SUFFIX)
        if (!token && !path.endsWith(LOGOUT_PATH_SUFFIX)) return
        val exchange = request.getProperty(AdminEngine.EXCHANGE)
        if (response.statusInfo.family != Response.Status.Family.SUCCESSFUL) {
            // 오류·리다이렉트는 판정하지 않는다(TokenManager 의 몫) — RESTEasy 가 통째로 버퍼에 읽는 그 본문을 상한까지만 넘긴다.
            val raw = response.entityStream ?: return // 엔티티가 없으면 그대로 — 빈 스트림을 지어내면 hasEntity 가 바뀐다
            response.entityStream = withinCapOrReject(raw, if (token) "token response" else "logout response", exchange)
            return
        }
        if (!token) return // 2xx logout 은 RESTEasy 의 void 추출기가 읽지 않고 닫는다
        if (response.mediaType != null) {
            request.setProperty(JUDGE_ENTITY, true) // 결합이 읽는 바이트(해제 뒤)는 aroundReadFrom 이 판정한다
            return
        }
        response.entityStream = usableOrReject(response.entityStream, exchange)
    }

    override fun aroundReadFrom(context: ReaderInterceptorContext): Any? {
        if (context.getProperty(JUDGE_ENTITY) != true) return context.proceed()
        context.inputStream = usableOrReject(context.inputStream, context.getProperty(AdminEngine.EXCHANGE))
        return context.proceed()
    }

    internal companion object {
        internal const val TOKEN_PATH_SUFFIX = "/protocol/openid-connect/token"

        // admin 이 닫힐 때 내장 TokenManager 가 refresh_token 을 보내는 곳(Keycloak.close → TokenManager.logout) — 오류 본문의 상한만.
        internal const val LOGOUT_PATH_SUFFIX = "/protocol/openid-connect/logout"

        // ReaderInterceptor 로서의 우선순위 — 오름차순으로 도므로 가장 큰 값이 결합(MessageBodyReader) 바로 앞이다.
        internal const val READ_PRIORITY = Int.MAX_VALUE

        // 응답 필터가 범위 안의 교환에 다는 요청 속성 — ReaderInterceptor 가 이것이 있는 엔티티만 판정한다.
        internal val JUDGE_ENTITY: String = TokenResponseGuard::class.java.name + ".judgeEntity"
        internal const val REJECTED = "token endpoint response carries no usable access_token"

        // 판정이 읽고 쥐는 본문의 상한은 [TOKEN_RESPONSE_MAX_BYTES](auth 레인과 같은 상수, 근거는 그 선언에) — 여기 다시 적지 않는다.
        private const val ACCESS_TOKEN = "access_token"
        private val JSON = JsonFactory()

        // 상한+1 바이트까지만 읽는다(넘침을 알아챌 한 바이트) — 넘치거나 쓸 수 없으면 거부, 통과하면 읽은 바이트를 그대로 넘긴다.
        private fun usableOrReject(
            input: InputStream?,
            exchange: Any?,
        ): ByteArrayInputStream {
            val body = if (input == null) ByteArray(0) else capPlusOne(input)
            if (body == null || !carriesUsableAccessToken(body)) {
                release(input, exchange)
                throw IOException(REJECTED)
            }
            return ByteArrayInputStream(body)
        }

        // 오류 본문 — 판정하지 않고 상한까지만 읽어 바이트 그대로 넘긴다. 넘치면 연결을 끊고 상한을 말하는 예외로 거부한다.
        private fun withinCapOrReject(
            input: InputStream,
            what: String,
            exchange: Any?,
        ): ByteArrayInputStream {
            val body = capPlusOne(input)
            if (body == null) {
                release(input, exchange)
                throw ResponseTooLargeException(what)
            }
            return ByteArrayInputStream(body)
        }

        // [readWithinCap] — 다만 길이 0 의 읽기는 스트림에 넘기지 않는다([NoEmptyReads]).
        private fun capPlusOne(input: InputStream): ByteArray? = readWithinCap(NoEmptyReads(input))

        // 거부하기 전에 그 교환을 놓는다 — 엔진이 단 손잡이([AdminEngine.EXCHANGE])로 연결을 **읽지 않고** 끊은 뒤 스트림을 닫는다(Java
        // 동형). 끊지 않고 닫으면 HttpCore 의 닫기가 나머지를 EOF 까지 비웠다(거부한 64 MiB 를 서버가 끝까지 썼다 — 실측
        // AdminRejectedResponseCutTest). 끊은 뒤의 닫기는 소켓에 닿지 못하고(이미 닫혔다) 버퍼에 남은 것만 지나간다. EOF 까지 읽고 거부한
        // 응답의 연결은 이미 풀로 돌아갔고 끊기는 그것을 건드리지 않는다. 손잡이가 없으면(다른 엔진) 닫기만 한다.
        private fun release(
            input: InputStream?,
            exchange: Any?,
        ) {
            (exchange as? AdminEngine.Exchange)?.cut()
            closeQuietly(input)
        }

        // 거부하기 전에 스트림을 닫고, 닫기의 실패는 버린다(Java 동형). ⚠️ 응답 필터가 던지면 RESTEasy(ClientInvocation.invoke)가
        // 응답을 try/catch 없이 닫는다 — 그 닫기가 실패하면(끊긴 연결에서 나머지를 읽으려다 · 끊지 못한 연결에서 청크 크기 줄 오류·잘린
        // 본문·읽기 타임아웃) 그 ProcessingException 이 이 거부를 대신해 RedactedCause 로 걸러지지 않은 채 나갔고, 청크 크기 줄 오류는
        // 응답 바이트를 메시지에 실었다(실측 — AdminTokenResponseTest). 여기서 먼저 닫으면 뒤의 닫기는 아무것도 하지 않는다
        // (BufferedInputStream·EofSensorInputStream 모두 두 번째 닫기가 no-op).
        private fun closeQuietly(input: InputStream?) {
            try {
                input?.close()
            } catch (releaseFault: IOException) {
                // 버린다 — 결과는 거부다(메시지는 응답 바이트를 인용할 수 있다)
            }
        }

        /**
         * 최상위가 JSON 객체이고 그 `access_token` 이 하나 이상이며 전부 HTTP 필드 값이 실을 수 있는([fieldValueSafe]) 비어 있지 않은
         * 문자열이다. 형식이 틀리면 false.
         */
        internal fun carriesUsableAccessToken(body: ByteArray): Boolean {
            try {
                JSON.createParser(body).use { p ->
                    if (p.nextToken() != JsonToken.START_OBJECT) return false
                    var found = false
                    while (p.nextToken() == JsonToken.FIELD_NAME) {
                        val accessToken = p.currentName() == ACCESS_TOKEN
                        val value = p.nextToken()
                        when {
                            !accessToken -> p.skipChildren()
                            value != JsonToken.VALUE_STRING || p.textLength == 0 || !fieldValueSafe(p.text) -> return false
                            else -> found = true
                        }
                    }
                    return found
                }
            } catch (malformed: IOException) {
                return false // 파서 메시지는 본문을 인용할 수 있다 — 버리고 거부만 한다
            }
        }

        /**
         * HTTP 필드 값이 실을 수 있는 문자열인가(Java 동형) — RFC 9110 §5.5 가 필드 값에서 빼는 CR·LF·NUL·HTAB 밖의 C0 와 DEL 이 없다.
         * 그런 access_token 은 쓸 수 없는 토큰이다 — 캐시되지 않고(다음 호출이 다시 부여한다) admin 요청은 나가지 않는다. 수정 전
         * HttpCore 는 그 Bearer 를 조용히 고쳐 보냈다(CR·LF·VT·FF → 공백 · 그 밖의 C0·DEL → `?` — `BasicLineFormatter`·`ByteArrayBuffer`,
         * 실측 `AdminTokenResponseTest`). TokenManager 의 토큰은 모두 이 응답에서 오므로(부여·갱신 — 다른 길로 넣는 setter 가 없다) 보낼
         * 때 다시 보지 않는다. ⚠️ HTAB·SP·ASCII 밖(HttpCore 가 U+0100 위와 C1 을 `?` 로 보낸다)은 여기서 판정하지 않는다 — 아홉 언어가
         * 함께 정할 일이다(등록부 `bearer-token-grammar-divergent`).
         */
        internal fun fieldValueSafe(value: String): Boolean = value.none { (it < ' ' && it != '\t') || it == '\u007f' }
    }
}

/**
 * 길이 0 의 읽기는 감싼 스트림에 넘기지 않고 0 이다. JDK 의 `readNBytes` 는 다 채운 뒤 길이 0 으로 한 번 더 묻고, HttpCore 의 버퍼는 비었을
 * 때 그것도 소켓에서 기다린다 — 상한+1 바이트 뒤 멈춘 서버 앞에서 거부가 읽기 타임아웃을 기다렸다(실측 `AdminRejectedResponseCutTest` —
 * auth 레인의 `BoundedTransport` 본문 스트림과 같은 처방). 판정이 본문을 읽는 동안만 산다.
 */
private class NoEmptyReads(
    input: InputStream,
) : FilterInputStream(input) {
    override fun read(
        b: ByteArray,
        off: Int,
        len: Int,
    ): Int = if (len == 0) 0 else super.read(b, off, len)
}
