package io.github.xzawed.keycloak.admin

import com.fasterxml.jackson.core.JsonFactory
import com.fasterxml.jackson.core.JsonToken
import jakarta.ws.rs.HttpMethod
import jakarta.ws.rs.client.ClientRequestContext
import jakarta.ws.rs.client.ClientResponseContext
import jakarta.ws.rs.client.ClientResponseFilter
import jakarta.ws.rs.core.Response
import java.io.ByteArrayInputStream
import java.io.IOException

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
 * 범위는 POST · 경로 꼬리 [TOKEN_PATH_SUFFIX] · 2xx 응답뿐이다. admin 자원 응답의 역직렬화는 건드리지 않는다. 오류 상태는
 * 그대로 넘긴다 — 갱신이 400 이면 TokenManager 가 `BadRequestException` 을 받아 client_credentials 로 다시 부여하는 복구
 * 경로가 있다.
 *
 * 거부는 [IOException] 이다. RESTEasy 는 응답 필터의 예외를 타입과 무관하게 `ResponseProcessingException` 으로 감싸고(그래서
 * TokenManager 갱신의 `BadRequestException` 복구에도 닿지 않는다 — 실측), 그것이 BearerAuthFilter(요청 필터) 밖으로 나가므로
 * admin 요청은 보내지지 않고, [adminCall] 이 `KeycloakTransportException` 으로 바꾼다(원인 사슬은 [transportCause] 가
 * `RedactedCause` 로 간다) — null·객체·배열·누락이 이미 실패하던 타입이다. 메시지는 상수다(응답을 인용하지 않는다).
 *
 * 검사는 Jackson **스트리밍** 파서다 — 데이터 결합·다형 타입이 없고 자체 ObjectMapper 도 아니다(보안 불변식). 최상위
 * `access_token` 은 **전부** 본다 — 결합은 중복 키의 마지막 값을 쓰므로 첫 값만 보면 `{"access_token":"ok","access_token":1}`
 * 이 통과한다. 통과한 바이트는 그대로 되돌려 결합이 refresh_token·expires_in 을 잃지 않게 한다.
 */
internal class TokenResponseGuard : ClientResponseFilter {
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
        val body = response.entityStream?.readAllBytes() ?: ByteArray(0)
        if (!carriesUsableAccessToken(body)) throw IOException("token endpoint response carries no usable access_token")
        response.entityStream = ByteArrayInputStream(body)
    }

    internal companion object {
        internal const val TOKEN_PATH_SUFFIX = "/protocol/openid-connect/token"
        private const val ACCESS_TOKEN = "access_token"
        private val JSON = JsonFactory()

        /** 최상위가 JSON 객체이고 그 `access_token` 이 하나 이상이며 전부 비어 있지 않은 문자열이다. 형식이 틀리면 false. */
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
