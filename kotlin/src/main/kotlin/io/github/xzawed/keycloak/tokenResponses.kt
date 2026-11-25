package io.github.xzawed.keycloak

import com.fasterxml.jackson.core.JsonFactory
import com.fasterxml.jackson.core.JsonToken
import com.nimbusds.oauth2.sdk.ErrorObject
import com.nimbusds.oauth2.sdk.ParseException
import com.nimbusds.oauth2.sdk.TokenErrorResponse
import com.nimbusds.oauth2.sdk.TokenIntrospectionErrorResponse
import com.nimbusds.oauth2.sdk.TokenIntrospectionResponse
import com.nimbusds.oauth2.sdk.TokenResponse
import com.nimbusds.oauth2.sdk.http.HTTPResponse
import com.nimbusds.openid.connect.sdk.OIDCTokenResponseParser
import jakarta.ws.rs.core.Response
import org.jboss.resteasy.client.jaxrs.internal.ClientResponse
import java.io.IOException
import java.io.InputStream
import java.util.Base64

// tokenResponses.kt — 성공 상태의 OAuth error(등록부 auth-2xx-error-code-divergent · token-response-residual-divergence A · Java
// `TokenResponses` · `TokenResponseGuard` 동형). 성공 상태의 본문이 JSON 객체이고 그 `error` 가 있고 null 도 "" 도 아니면 — 문자열이
// 아니어도(숫자 · 객체 · 배열 · 불리언) — 그 응답은 **오류 응답**이다: 400 이 같은 본문을 실었을 때와 같은 길로 보낸다(같은 타입 · 같은
// 메시지 꼴 · 같은 코드 판정 [OAuthErrorCode] — 문자열이 아닌 error 는 코드가 아니다). 수정 전에는 그 본문의 나머지를 썼다 —
// access_token 이 있으면 토큰을 돌려주고(공급자는 캐시했다) admin 요청을 보냈고, active 가 참이면 활성으로 읽었다(실측 —
// `TokenResponseClassTest` · 문자열이 아닌 error 는 그 뒤에도 그랬다). null 이거나 비었으면 error 가 없는 것과 같다. admin 가드의 200 이
// 아닌 2xx([refuseUnlessOk])도 여기 있다. ⚠️ auth.kt · admin/ 에 두지 않는 까닭: 그 파일들은 통합 실행으로 재는 경계 파일이고
// (scripts/integration-coverage.json) 이 갈래는 실 Keycloak 이 닿지 않는다 — 여기 두면 단위 게이트(Kover)가 잰다.

// client_credentials · refresh · 코드 교환(oidc — id_token 을 보존하는 파서)의 응답. 성공 상태의 OAuth error 는 오류 응답이다.
internal fun tokenResponse(
    response: HTTPResponse,
    oidc: Boolean,
): TokenResponse =
    when {
        carriesOAuthError(response) -> TokenErrorResponse(ErrorObject.parse(response))
        oidc -> OIDCTokenResponseParser.parse(response)
        else -> TokenResponse.parse(response)
    }

// introspection 의 응답. 성공 상태의 OAuth error 는 오류 응답이다(활성으로 읽지 않는다).
internal fun introspectionResponse(response: HTTPResponse): TokenIntrospectionResponse =
    if (carriesOAuthError(response)) {
        TokenIntrospectionErrorResponse(ErrorObject.parse(response))
    } else {
        TokenIntrospectionResponse.parse(response)
    }

// 성공 상태(200 — Nimbus 가 성공으로 읽는 유일한 상태)의 본문이 JSON 객체이고 그 error 가 있고 null 도 "" 도 아닌가(JSON null 은 파서가
// null 로 둔다). 그 밖의 상태는 Nimbus 가 이미 오류 응답으로 읽는다 — 상태의 수용 범위는 바꾸지 않는다. 본문은 성공 파서가 읽는 그대로
// 읽는다(JSON 이 아닌 Content-Type · JSON 객체가 아닌 본문은 판정하지 않고 성공 파서가 지금처럼 거부한다). ⚠️ Nimbus 의
// `TokenErrorResponse.parse` · `TokenIntrospectionErrorResponse.parse` 는 200 을 거부하므로(ensureStatusCodeNotOK) 위 둘은 그것들이 하는
// 일(ErrorObject.parse — 문자열이 아닌 error 는 코드 없이 둔다)을 직접 한다.
internal fun carriesOAuthError(response: HTTPResponse): Boolean {
    if (response.statusCode != HTTPResponse.SC_OK) return false
    val body =
        try {
            response.bodyAsJSONObject
        } catch (notAJsonObject: ParseException) {
            return false // 성공 파서가 지금처럼 거부한다 — 이 예외의 메시지는 응답을 인용할 수 있어 버린다
        }
    val error = body["error"]
    return error != null && error != ""
}

private val OAUTH_ERROR_JSON = JsonFactory()

// admin 가드([judgedTokenBody])의 판정 — 최상위가 JSON 객체이고 그 error 하나라도 있고 null 도 "" 도 아니다. 문자열이 아니어도(숫자 ·
// 객체 · 배열 · 불리언) 오류를 이름한다(등록부 token-response-residual-divergence A — 예전에는 숫자 · 불리언을 결합이 문자열로 바꿔 받아
// 그 토큰으로 admin 요청을 보냈다). 결합(AccessTokenResponse)은 error 칸을 읽어 두지만 TokenManager 는 그것을 보지 않고 access_token 을
// 썼다. 중복 키는 하나라도 그러면 오류다(access_token 처럼 전부 본다 — 닫는 쪽으로). 실을 코드는 [oauthErrorValue] 가 고른다. 형식이
// 틀리면 false — 그 본문은 가드의 다음 판정이 거부한다. 스트리밍 파서다(결합 · 자체 ObjectMapper 가 없다).
internal fun namesOAuthError(body: ByteArray): Boolean {
    try {
        OAUTH_ERROR_JSON.createParser(body).use { p ->
            if (p.nextToken() != JsonToken.START_OBJECT) return false
            while (p.nextToken() == JsonToken.FIELD_NAME) {
                val error = p.currentName() == "error"
                val value = p.nextToken()
                if (error && value != JsonToken.VALUE_NULL && !(value == JsonToken.VALUE_STRING && p.text.isEmpty())) return true
                p.skipChildren()
            }
            return false
        }
    } catch (malformed: IOException) {
        return false // 파서 메시지는 본문을 인용할 수 있다 — 버린다(가드의 다음 판정이 같은 본문을 거부한다)
    }
}

// 최상위가 JSON 객체이고 그 error 하나라도 비어 있지 않은 JSON 문자열이면 그 값(중복 키는 그 첫 것), 아니면 null — 그 응답이 싣는 OAuth
// 코드의 후보다(성공 상태는 [namesOAuthError] 가 판정한 뒤, 오류 상태는 그대로 — [errorStatusCode]). 형식이 틀리면 null — 그 본문은
// 가드의 다음 판정이 거부한다. 코드로 싣는 것은 [OAuthErrorCode] 가 허락한 것뿐이다. 스트리밍 파서다(결합 · 자체 ObjectMapper 가 없다).
internal fun oauthErrorValue(body: ByteArray): String? {
    try {
        OAUTH_ERROR_JSON.createParser(body).use { p ->
            if (p.nextToken() != JsonToken.START_OBJECT) return null
            while (p.nextToken() == JsonToken.FIELD_NAME) {
                val error = p.currentName() == "error"
                val value = p.nextToken()
                if (error && value == JsonToken.VALUE_STRING && p.text.isNotEmpty()) return p.text
                p.skipChildren()
            }
            return null
        }
    } catch (malformed: IOException) {
        return null // 파서 메시지는 본문을 인용할 수 있다 — 버린다(가드의 다음 판정이 같은 본문을 거부한다)
    }
}

// 폼에 실려 나가는 비밀 매개변수 — auth 레인과 같은 집합이다.
private val ADMIN_SECRET_PARAMS =
    setOf("code", "code_verifier", "refresh_token", "token", "client_secret", "client_assertion", "password")

// admin 그랜트가 보낸 비밀 — Authorization 의 자격(TokenManager 의 BasicAuthFilter 가 client secret 을 싣는 자리 — 그 Basic 을 푼 시크릿도)과
// 폼(그랜트의 엔티티 — MultivaluedMap)의 비밀 매개변수(갱신의 refresh_token · password 그랜트의 password). [OAuthErrorCode] 가 이것과
// 겹치는 error 를 싣지 않는다(Java `TokenResponseGuard.sentValues` 동형). 비밀을 상태로 쥐지 않는다 — 가드가 요청에서 그때 읽는다.
internal fun adminSentValues(
    authorization: String?,
    entity: Any?,
): List<String> {
    val values = mutableListOf<String>()
    if (authorization != null) {
        val credential = authorization.substring(authorization.indexOf(' ') + 1)
        values += credential
        if (authorization.regionMatches(0, "Basic ", 0, 6, ignoreCase = true)) {
            try {
                val pair = String(Base64.getDecoder().decode(credential), Charsets.UTF_8)
                values += pair.substring(pair.indexOf(':') + 1)
            } catch (notBase64: IllegalArgumentException) {
                // 푼 꼴이 없다 — 자격 그대로만 비교한다(그 예외는 값을 인용하지 않지만 쓰지 않는다)
            }
        }
    }
    (entity as? Map<*, *>)?.forEach { (name, sent) ->
        if (name.toString() in ADMIN_SECRET_PARAMS) (sent as? Iterable<*>)?.forEach { if (it is String) values += it }
    }
    return values.filter { it.isNotEmpty() }
}

// admin 그랜트의 오류 상태 본문이 실은 OAuth 코드 — [oauthErrorValue] 의 error 가운데 그 그랜트가 보낸 비밀(sent — [adminSentValues])과
// 겹치지 않는 코드 모양의 값([OAuthErrorCode]), 아니면 null(등록부 oauth-error-code-surface-divergent — 예전에는 그 상태에서 싣지 않았다).
// 가드가 오류 상태를 넘기기 전에 판정해 그 교환의 속성([GRANT_CODE])에 달고, [judgedGrantCode] 가 실패의 응답에서 읽는다(Java
// `TokenResponseGuard.codeOf` 동형).
internal fun errorStatusCode(
    body: ByteArray,
    sent: List<String>,
): String? = OAuthErrorCode.carried(oauthErrorValue(body), sent)

// 가드가 오류 상태의 토큰 응답에 달아 둔 코드([errorStatusCode]) — 그 응답이 가드가 판정한 것이 아니면(손으로 지은 Response) null.
// RESTEasy 는 응답의 속성을 그 교환의 요청 속성과 같은 맵으로 잇는다(ClientInvocation.filterResponse — 가드의 JUDGE_ENTITY 가
// ReaderInterceptor 에 닿는 길과 같다).
internal fun judgedGrantCode(response: Response?): String? = (response as? ClientResponse)?.properties?.get(GRANT_CODE) as? String

// [errorStatusCode] 의 판정을 다는 요청 속성.
internal const val GRANT_CODE = "io.github.xzawed.keycloak.admin.TokenResponseGuard.grantCode"

/**
 * admin 가드([io.github.xzawed.keycloak.admin.TokenResponseGuard])의 200 이 아닌 2xx 토큰 응답 판정 — 토큰 응답의 성공은 200 뿐이다(RFC 6749
 * §5.1, 아홉 언어의 규칙). [status] 가 200 이면 아무것도 하지 않는다(엔티티도 묻지 않는다). 아니면 본문이 쓸 수 있는 토큰이어도 그 상태의
 * 오류 응답처럼 실패한다: 오류 상태와 같이 [read] 로 상한까지만 읽고(넘치면 null — 같은 전송 실패) [release] 로 교환을 놓은 뒤, 그 OAuth
 * 코드를 보낸 비밀([sent])에 대어 판정해 싣는다 — 「Admin token request failed: HTTP <상태>」([OAuthErrorTokenResponse]). 본문은 판정하지
 * 않는다(auth 레인의 Nimbus 도 200 밖은 오류 응답으로 읽는다). [entity] 가 없으면(204) 빈 본문이다. 수정 전에는 201 · 202 · 203 · 206 ·
 * 299 의 토큰을 캐시해 admin 요청을 보냈고 204 는 「(unusable token response)」 였다(실측 — `TokenResponseClassTest`, Java 동형). ⚠️ 가드의
 * 파일이 아니라 여기 있는 까닭은 [judgedTokenBody] 와 같다 — 실 Keycloak 의 토큰 응답은 200 이라 이 갈래에 닿지 않는다.
 */
internal fun refuseUnlessOk(
    status: Int,
    entity: () -> InputStream?,
    read: (InputStream) -> ByteArray?,
    sent: () -> List<String>,
    release: (InputStream?) -> Unit,
) {
    if (status == HTTPResponse.SC_OK) return
    val input = entity()
    val body = if (input == null) ByteArray(0) else read(input)
    release(input)
    if (body == null) throw ResponseTooLargeException("token response")
    throw OAuthErrorTokenResponse(status, errorStatusCode(body, sent()))
}

/**
 * 오류 상태처럼 실패하는 admin 그랜트의 2xx 토큰 응답 — 200 의 본문이 OAuth 오류 응답이거나([namesOAuthError] — 등록부
 * auth-2xx-error-code-divergent) 상태가 200 이 아닌 2xx 다([refuseUnlessOk]). 그 상태와, 그 error 가운데 [OAuthErrorCode] 가 허락한 코드(아니면
 * null)를 싣는다(Java `TokenResponseGuard.OAuthErrorResponse` 동형). [io.github.xzawed.keycloak.admin.grantFailure] 가 같은 본문의 4xx 와
 * 같은 꼴(「Admin token request failed: HTTP <상태>」)로 바꾸고 코드는 [KeycloakAuthException.oauthError] 에 싣는다 — 아홉 언어의 규칙. 그
 * 레인의 4xx 도 같은 코드를 싣는다([errorStatusCode]). 메시지는 상태로만 고른 상수다(응답을 인용하지 않는다).
 */
internal class OAuthErrorTokenResponse(
    val status: Int,
    val code: String?,
) : IOException(
        if (status == HTTPResponse.SC_OK) {
            "token endpoint answered a success status with an OAuth error"
        } else {
            "token endpoint answered a status other than 200"
        },
    )
