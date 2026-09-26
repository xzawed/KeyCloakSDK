package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.aResponse
import com.github.tomakehurst.wiremock.client.WireMock.get
import com.github.tomakehurst.wiremock.client.WireMock.getRequestedFor
import com.github.tomakehurst.wiremock.client.WireMock.post
import com.github.tomakehurst.wiremock.client.WireMock.postRequestedFor
import com.github.tomakehurst.wiremock.client.WireMock.urlEqualTo
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import io.github.xzawed.keycloak.admin.AdminClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.Date
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

// 적대적·형식이 틀린 IdP 응답에서 난 SDK 오류가 **응답의 토큰이나 호출자가 보낸 비밀을 찍지 않는다**. 자매
// Node(#603)에서 하위 라이브러리가 형식이 틀린 토큰 응답의 본문·원문 id_token 을 원인(cause)에 싣고 SDK 가 그
// 오류를 그대로 달아 로거가 찍었다. 여기서는 token·introspect 엔드포인트와 말하는 공개 호출 전부(admin 의 내장
// TokenManager 도 같은 토큰 엔드포인트를 친다)를 변형 × 호출로 몰고, 결과 SDK 오류를 로거가 찍는 두 경로 —
// `stackTraceToString()`(모든 "Caused by:" 포함)·`toString()` — 로 그려 카나리아를 전체 또는 앞 10 자로 찾는다.
//
// 수정 전 실측(2026-09-26): 200 + JSON 아닌 본문은 json-smart 가 본문 토큰을 통째로(auth·introspect — 300 자
// 꼬리까지), Jackson 이 앞부분·JSON 문자열 값·expires_in 값을(admin) 인용해 "Caused by:" 로 찍혔고, Nimbus 는
// token_type 값을 인용했다. error_description 에 되울린 호출자의 refresh·introspect 토큰은 SDK 메시지 자체에 실렸다.
//
// `FacadeDumpTest` 의 걷기와 따로 둔 이유: 걷기는 뿌리마다 고정 IdP 이고, 이쪽은 변형마다 IdP 를 바꿔 끼운다.

private const val MAL_OIDC = "/realms/r/protocol/openid-connect"
private const val MAL_TOKEN = "$MAL_OIDC/token"
private const val MAL_INTROSPECT = "$MAL_OIDC/token/introspect"
private const val MAL_ADMIN_USER = "/admin/realms/r/users/u1"
private const val MAL_PREFIX = 10

// 호출자가 SDK 에 넘긴 비밀 — 어떤 오류에도 나오면 안 된다.
private const val MAL_SECRET = "SECRETLEAK-client-secret-0001"

// ⚠️ 폼 인코딩이 바꾸는 글자(`+` `/` `=` `~`)를 일부러 넣는다 — 요청 본문에는 인코딩된 꼴로 실리고, 그 꼴을
// 되울리는 IdP 앞에서 원문만 가리면 샌다(독립 레그 Grok 의 지적을 e7·e8·f10 으로 실측).
private const val MAL_REFRESH_IN = "RTINLEAK-refresh+input/0001="
private const val MAL_INTROSPECT_IN = "INTROLEAK-introspect+input/0001="
private const val MAL_CODE_IN = "CODEINLEAK-auth+code/0001="
private val MAL_VERIFIER_IN = "VERIFLEAK~" + "v".repeat(40)
private val MAL_BASIC = Base64.getEncoder().encodeToString("c:$MAL_SECRET".toByteArray())

private val MAL_INPUTS =
    mapOf(
        "IN_SECRET" to MAL_SECRET,
        "IN_BASIC" to MAL_BASIC,
        "IN_REFRESH" to MAL_REFRESH_IN,
        "IN_INTROSPECT" to MAL_INTROSPECT_IN,
        "IN_CODE" to MAL_CODE_IN,
        "IN_VERIFIER" to MAL_VERIFIER_IN,
        "IN_REFRESH_FORM" to form(MAL_REFRESH_IN),
        "IN_INTROSPECT_FORM" to form(MAL_INTROSPECT_IN),
        "IN_CODE_FORM" to form(MAL_CODE_IN),
        "IN_VERIFIER_FORM" to form(MAL_VERIFIER_IN),
    )

private fun form(v: String): String = URLEncoder.encode(v, StandardCharsets.UTF_8)

/**
 * 알려진 누출 — `"변형|호출|카나리아"` → 사유. ⚠️ 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
 *
 * error_description 은 IdP 가 쓴 문구이고 SDK 는 그것을 메시지에 옮긴다 — Keycloak 이 주는 유일한 사람용 사유다
 * (「Invalid client or Invalid client credentials」). SDK 가 **그 요청에 실어 보낸** 비밀(클라이언트 시크릿·
 * Basic 자격·refresh/introspect 토큰·code·verifier — 원문과 폼 인코딩된 꼴)은 가린다(e2–e4·e7·e8·f6·f10). 보낸
 * 적 없는 값은 사유 문구와 구별할 수 없어 남는다(e1·f9). admin 은 사유를 메시지에 싣지 않는다(본문은 `keycloakError`
 * 필드 — 아래 두 번째 테스트). 폼 인코딩된 오류 본문은 Nimbus 가 읽지 않는다(e9 — 사유가 `null`).
 */
private const val MAL_FOREIGN =
    "IdP-authored error_description forwarded by design; a value the SDK never sent is indistinguishable from prose"

private val MAL_KNOWN_LEAKS: Map<String, String> =
    listOf(MalCall.CLIENT_CREDENTIALS, MalCall.REFRESH, MalCall.EXCHANGE, MalCall.EXCHANGE_NONCE).associate {
        "e1 400 error_description echoes a foreign token|$it|DESC" to MAL_FOREIGN
    } + ("f9 introspect 401 error_description echoes a foreign token|INTROSPECT|DESC" to MAL_FOREIGN)

private enum class MalCall { CLIENT_CREDENTIALS, REFRESH, EXCHANGE, EXCHANGE_NONCE, INTROSPECT, ADMIN }

private val AUTH_TOKEN_CALLS = setOf(MalCall.CLIENT_CREDENTIALS, MalCall.REFRESH, MalCall.EXCHANGE, MalCall.EXCHANGE_NONCE)
private val ALL_TOKEN_CALLS = AUTH_TOKEN_CALLS + MalCall.ADMIN

// admin 의 토큰 단계 실패는 원래부터 전송 오류로 분류된다(RESTEasy 가 ProcessingException 으로 감싼다) — 분류는
// 이 수정의 대상이 아니므로 그대로 고정한다.
private fun expectedType(call: MalCall): Class<out KeycloakException> =
    if (call == MalCall.ADMIN) KeycloakTransportException::class.java else KeycloakAuthException::class.java

private data class MalVariant(
    val id: String,
    val path: String,
    val status: Int,
    val body: String,
    val canaries: Map<String, String>,
    val calls: Set<MalCall>,
    val contentType: String = "application/json",
    val failure: MalFailure = MalFailure.MALFORMED,
)

// 변형이 **어느 단계에서** 호출을 실패시켜야 하는가 — 흐름 대조가 타입만 보면, 무력해진 변형이 다른 이유로 같은
// 타입의 실패를 내도(정상 응답인데 id_token 이 없어 nonce 경로가 실패) 통과한다(변이로 실측).
private enum class MalFailure { MALFORMED, ID_TOKEN, OAUTH_ERROR }

private fun expectedPrefix(
    failure: MalFailure,
    call: MalCall,
): String =
    when {
        call == MalCall.ADMIN -> "Admin request failed"
        failure == MalFailure.ID_TOKEN -> "Authorization code exchange failed: invalid id_token"
        failure == MalFailure.MALFORMED && call == MalCall.INTROSPECT -> "Malformed introspection response"
        failure == MalFailure.MALFORMED -> "Malformed auth response"
        else ->
            when (call) {
                MalCall.CLIENT_CREDENTIALS -> "Client credentials failed: "
                MalCall.REFRESH -> "Token refresh failed: "
                MalCall.INTROSPECT -> "Introspection failed: "
                else -> "Authorization code exchange failed: "
            }
    }

private fun b64(s: String): String = Base64.getUrlEncoder().withoutPadding().encodeToString(s.toByteArray())

private fun signedWith(
    key: RSAKey,
    issuer: String,
    subject: String,
): String {
    val claims =
        JWTClaimsSet
            .Builder()
            .issuer(issuer)
            .audience("c")
            .subject(subject)
            .expirationTime(Date(System.currentTimeMillis() + 60_000))
            .build()
    val jwt = SignedJWT(JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.keyID).build(), claims)
    jwt.sign(RSASSASigner(key))
    return jwt.serialize()
}

private fun obj(vararg members: Pair<String, String>): String = members.joinToString(",", "{", "}") { (k, v) -> "\"$k\":$v" }

private fun q(s: String): String = "\"$s\""

// 정상 모양의 토큰 응답에서 멤버 몇만 바꾼다 — 카나리아 두 토큰은 (덮지 않으면) 항상 실린다.
private fun tokens(
    v: String,
    vararg override: Pair<String, String>,
): String {
    val base =
        linkedMapOf(
            "access_token" to q("${v}ATLEAK-access-0001"),
            "token_type" to q("Bearer"),
            "expires_in" to "300",
            "refresh_token" to q("${v}RTLEAK-refresh-0001"),
        )
    override.forEach { (k, value) -> base[k] = value }
    return obj(*base.toList().toTypedArray())
}

private fun leakedTokens(v: String): Map<String, String> = mapOf("AT" to "${v}ATLEAK-access-0001", "RT" to "${v}RTLEAK-refresh-0001")

private fun variants(
    issuer: String,
    key: RSAKey,
    foreignKey: RSAKey,
): List<MalVariant> {
    val a2Header = "A2HDRLEAK-not-json-header"
    val a2 = "${b64(a2Header)}.${b64("{}")}.${b64("sig")}"
    val a3Payload = "A3PAYLEAK-not-json-payload"
    val a3 = "${b64("""{"alg":"RS256","kid":"k1"}""")}.${b64(a3Payload)}.${b64("sig")}"
    val a4 = signedWith(foreignKey, issuer, "A4SUBLEAK-subject")
    val a5 = signedWith(key, "A5ISSLEAK-issuer", "A5SUBLEAK-subject")
    val d2 = "D2BODYLEAK-long-body-token-" + "x".repeat(300)
    val f2 = "F2BODYLEAK-long-body-token-" + "y".repeat(300)
    val idOnly = setOf(MalCall.EXCHANGE, MalCall.EXCHANGE_NONCE)
    val nonceOnly = setOf(MalCall.EXCHANGE_NONCE)
    val introspect = setOf(MalCall.INTROSPECT)
    return listOf(
        // (a) id_token — 플레인 파서(client-credentials·refresh)는 id_token 을 읽지 않고, admin 은 불투명 문자열로
        // 받는다(측정: 셋 다 성공). 구조가 JWT 인 것(a3–a5)은 nonce 경로의 검증기만 연다.
        MalVariant(
            "a1 id_token is not a JWT",
            MAL_TOKEN,
            200,
            tokens("A1", "id_token" to q("A1IDLEAK-id-token-no-dots")),
            leakedTokens("A1") + ("ID" to "A1IDLEAK-id-token-no-dots"),
            idOnly,
        ),
        MalVariant(
            "a2 id_token header is not JSON",
            MAL_TOKEN,
            200,
            tokens("A2", "id_token" to q(a2)),
            leakedTokens("A2") + mapOf("ID" to a2, "ID_HEADER" to a2Header),
            idOnly,
        ),
        MalVariant(
            "a3 id_token payload is not JSON",
            MAL_TOKEN,
            200,
            tokens("A3", "id_token" to q(a3)),
            leakedTokens("A3") + mapOf("ID" to a3, "ID_PAYLOAD" to a3Payload),
            nonceOnly,
            failure = MalFailure.ID_TOKEN,
        ),
        MalVariant(
            "a4 id_token signed by a foreign key",
            MAL_TOKEN,
            200,
            tokens("A4", "id_token" to q(a4)),
            leakedTokens("A4") + mapOf("ID" to a4, "ID_SUB" to "A4SUBLEAK-subject"),
            nonceOnly,
            failure = MalFailure.ID_TOKEN,
        ),
        MalVariant(
            "a5 id_token iss mismatch",
            MAL_TOKEN,
            200,
            tokens("A5", "id_token" to q(a5)),
            leakedTokens("A5") + mapOf("ID" to a5, "ID_ISS" to "A5ISSLEAK-issuer", "ID_SUB" to "A5SUBLEAK-subject"),
            nonceOnly,
            failure = MalFailure.ID_TOKEN,
        ),
        // (b)(c) 타입이 틀린 멤버 — admin 의 Jackson 은 수를 문자열로 바꿔 받고 token_type 을 안 본다(측정: 성공).
        MalVariant(
            "b access_token is not a string",
            MAL_TOKEN,
            200,
            tokens("B0", "access_token" to "123"),
            mapOf("RT" to "B0RTLEAK-refresh-0001"),
            AUTH_TOKEN_CALLS,
        ),
        MalVariant(
            "c1 expires_in is not a number",
            MAL_TOKEN,
            200,
            tokens("C1", "expires_in" to q("C1EXPLEAK-soon")),
            leakedTokens("C1") + ("EXPIRES_IN" to "C1EXPLEAK-soon"),
            ALL_TOKEN_CALLS,
        ),
        MalVariant(
            "c2 token_type is not a string",
            MAL_TOKEN,
            200,
            tokens("C2", "token_type" to "5"),
            leakedTokens("C2"),
            AUTH_TOKEN_CALLS,
        ),
        MalVariant(
            "c3 token_type is an unknown string",
            MAL_TOKEN,
            200,
            tokens("C3", "token_type" to q("C3TTLEAK-type")),
            leakedTokens("C3") + ("TOKEN_TYPE" to "C3TTLEAK-type"),
            AUTH_TOKEN_CALLS,
        ),
        // (d) 200 인데 JSON 객체가 아니다.
        MalVariant("d1 200 short non-JSON body", MAL_TOKEN, 200, "D1BODYLEAK-short", mapOf("BODY" to "D1BODYLEAK-short"), ALL_TOKEN_CALLS),
        MalVariant("d2 200 long non-JSON body", MAL_TOKEN, 200, d2, mapOf("BODY" to "D2BODYLEAK-long-body-token"), ALL_TOKEN_CALLS),
        MalVariant(
            "d3 200 short non-JSON body as text/plain",
            MAL_TOKEN,
            200,
            "D3BODYLEAK-plain",
            mapOf("BODY" to "D3BODYLEAK-plain"),
            ALL_TOKEN_CALLS,
            contentType = "text/plain",
        ),
        MalVariant(
            "d4 200 JSON string body",
            MAL_TOKEN,
            200,
            q("D4BODYLEAK-json-string"),
            mapOf("BODY" to "D4BODYLEAK-json-string"),
            ALL_TOKEN_CALLS,
        ),
        MalVariant(
            "d5 200 JSON with a truncated tail",
            MAL_TOKEN,
            200,
            """{"access_token":"D5ATLEAK-access-0001","refresh_token":"D5RTLEAK-refresh-0001",""",
            mapOf("AT" to "D5ATLEAK-access-0001", "RT" to "D5RTLEAK-refresh-0001"),
            ALL_TOKEN_CALLS,
        ),
        // (e) 오류 응답.
        MalVariant(
            "e1 400 error_description echoes a foreign token",
            MAL_TOKEN,
            400,
            obj("error" to q("invalid_grant"), "error_description" to q("Token E1DESCLEAK-echoed-0001 is not active")),
            mapOf("DESC" to "E1DESCLEAK-echoed-0001"),
            ALL_TOKEN_CALLS,
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "e2 401 error_description echoes the sent client secret",
            MAL_TOKEN,
            401,
            obj("error" to q("invalid_client"), "error_description" to q("Bad secret $MAL_SECRET / Basic $MAL_BASIC")),
            emptyMap(),
            setOf(MalCall.CLIENT_CREDENTIALS),
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "e3 400 error_description echoes the sent refresh token",
            MAL_TOKEN,
            400,
            obj("error" to q("invalid_grant"), "error_description" to q("Invalid refresh token: $MAL_REFRESH_IN (client $MAL_SECRET)")),
            emptyMap(),
            setOf(MalCall.REFRESH),
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "e4 400 error_description echoes the sent code and verifier",
            MAL_TOKEN,
            400,
            obj("error" to q("invalid_grant"), "error_description" to q("Code $MAL_CODE_IN / verifier $MAL_VERIFIER_IN not valid")),
            emptyMap(),
            idOnly,
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "e5 400 error body carries extra token members",
            MAL_TOKEN,
            400,
            obj(
                "error" to q("invalid_request"),
                "access_token" to q("E5ATLEAK-access-0001"),
                "refresh_token" to q("E5RTLEAK-refresh-0001"),
            ),
            mapOf("AT" to "E5ATLEAK-access-0001", "RT" to "E5RTLEAK-refresh-0001"),
            ALL_TOKEN_CALLS,
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "e6 401 non-JSON error body",
            MAL_TOKEN,
            401,
            "E6BODYLEAK-error-body",
            mapOf("BODY" to "E6BODYLEAK-error-body"),
            ALL_TOKEN_CALLS,
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "e7 400 error_description echoes the sent refresh token form-encoded",
            MAL_TOKEN,
            400,
            obj("error" to q("invalid_grant"), "error_description" to q("Bad body: refresh_token=${form(MAL_REFRESH_IN)}")),
            emptyMap(),
            setOf(MalCall.REFRESH),
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "e8 400 error_description echoes the sent code and verifier form-encoded",
            MAL_TOKEN,
            400,
            obj(
                "error" to q("invalid_grant"),
                "error_description" to q("Bad body: code=${form(MAL_CODE_IN)}&code_verifier=${form(MAL_VERIFIER_IN)}"),
            ),
            emptyMap(),
            idOnly,
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "e9 400 form-encoded error body carries a foreign token",
            MAL_TOKEN,
            400,
            "error=invalid_grant&error_description=E9DESCLEAK-foreign-0001",
            mapOf("DESC" to "E9DESCLEAK-foreign-0001"),
            ALL_TOKEN_CALLS,
            contentType = "application/x-www-form-urlencoded",
            failure = MalFailure.OAUTH_ERROR,
        ),
        // (f) introspect — 같은 모양. username 이 문자열이 아닌 응답은 Nimbus 가 받아들여 실패가 아니다(측정).
        MalVariant(
            "f1 introspect 200 short non-JSON body",
            MAL_INTROSPECT,
            200,
            "F1BODYLEAK-short",
            mapOf("BODY" to "F1BODYLEAK-short"),
            introspect,
        ),
        MalVariant(
            "f2 introspect 200 long non-JSON body",
            MAL_INTROSPECT,
            200,
            f2,
            mapOf("BODY" to "F2BODYLEAK-long-body-token"),
            introspect,
        ),
        MalVariant(
            "f3 introspect active is not a boolean",
            MAL_INTROSPECT,
            200,
            obj("active" to q("F3ACTLEAK-yes"), "username" to q("svc"), "token" to q("F3TOKLEAK-echo-0001")),
            mapOf("ACTIVE" to "F3ACTLEAK-yes", "TOKEN" to "F3TOKLEAK-echo-0001"),
            introspect,
        ),
        MalVariant(
            "f4 introspect active is missing",
            MAL_INTROSPECT,
            200,
            obj("username" to q("svc"), "token" to q("F4TOKLEAK-echo-0001")),
            mapOf("TOKEN" to "F4TOKLEAK-echo-0001"),
            introspect,
        ),
        MalVariant(
            "f5 introspect 200 JSON string body",
            MAL_INTROSPECT,
            200,
            q("F5BODYLEAK-json-string"),
            mapOf("BODY" to "F5BODYLEAK-json-string"),
            introspect,
        ),
        MalVariant(
            "f6 introspect 401 error_description echoes the sent token",
            MAL_INTROSPECT,
            401,
            obj("error" to q("invalid_client"), "error_description" to q("Bad token $MAL_INTROSPECT_IN from $MAL_BASIC")),
            emptyMap(),
            introspect,
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "f7 introspect 401 non-JSON error body",
            MAL_INTROSPECT,
            401,
            "F7BODYLEAK-error-body",
            mapOf("BODY" to "F7BODYLEAK-error-body"),
            introspect,
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "f8 introspect 200 JSON with a truncated tail",
            MAL_INTROSPECT,
            200,
            """{"active":true,"token":"F8TOKLEAK-echo-0001",""",
            mapOf("TOKEN" to "F8TOKLEAK-echo-0001"),
            introspect,
        ),
        MalVariant(
            "f9 introspect 401 error_description echoes a foreign token",
            MAL_INTROSPECT,
            401,
            obj("error" to q("invalid_request"), "error_description" to q("Token F9DESCLEAK-foreign-0001 is not active")),
            mapOf("DESC" to "F9DESCLEAK-foreign-0001"),
            introspect,
            failure = MalFailure.OAUTH_ERROR,
        ),
        MalVariant(
            "f10 introspect 401 error_description echoes the sent token form-encoded",
            MAL_INTROSPECT,
            401,
            obj("error" to q("invalid_request"), "error_description" to q("Bad body: token=${form(MAL_INTROSPECT_IN)}")),
            emptyMap(),
            introspect,
            failure = MalFailure.OAUTH_ERROR,
        ),
    )
}

private suspend fun invoke(
    config: KeycloakConfig,
    call: MalCall,
): Any {
    val auth = AuthClient(config)
    return when (call) {
        MalCall.CLIENT_CREDENTIALS -> auth.clientCredentialsToken()
        MalCall.REFRESH -> auth.refresh(MAL_REFRESH_IN)
        MalCall.EXCHANGE -> auth.exchangeCode(MAL_CODE_IN, MAL_VERIFIER_IN, "https://app/cb")
        MalCall.EXCHANGE_NONCE -> auth.exchangeCode(MAL_CODE_IN, MAL_VERIFIER_IN, "https://app/cb", "n-1")
        MalCall.INTROSPECT -> auth.introspect(MAL_INTROSPECT_IN)
        MalCall.ADMIN -> AdminClient(config).use { it.users().get("u1") }
    }
}

private fun chainOf(t: Throwable): List<Throwable> = generateSequence(t) { it.cause }.take(16).toList()

internal class AuthMalformedResponseTest {
    @Test
    fun `hostile token and introspect responses do not print tokens through SDK errors`() =
        runTest(timeout = 120.seconds) {
            val server = WireMockServer(wireMockConfig().dynamicPort())
            server.start()
            try {
                val issuer = "${server.baseUrl()}/realms/r"
                val key = RSAKeyGenerator(2048).keyID("k1").generate()
                val foreign = RSAKeyGenerator(2048).keyID("k1").generate()
                val report = mutableListOf<String>()
                val flow = mutableListOf<String>()
                val leaks = sortedMapOf<String, MutableList<String>>()
                val failures = mutableMapOf<String, Throwable>()
                for (v in variants(issuer, key, foreign)) {
                    for (call in v.calls) {
                        server.resetAll()
                        server.stubFor(
                            post(urlEqualTo(v.path)).willReturn(
                                aResponse().withStatus(v.status).withHeader("Content-Type", v.contentType).withBody(v.body),
                            ),
                        )
                        server.stubFor(
                            get(urlEqualTo("$MAL_OIDC/certs")).willReturn(
                                aResponse()
                                    .withStatus(200)
                                    .withHeader("Content-Type", "application/json")
                                    .withBody(JWKSet(key.toPublicJWK()).toString()),
                            ),
                        )
                        val config = KeycloakConfig(server.baseUrl(), "r", "c", MAL_SECRET.toCharArray())
                        val outcome =
                            try {
                                invoke(config, call)
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Throwable) {
                                e
                            }
                        val case = "${v.id}|$call"
                        // 흐름 대조 — 변형이 정말 IdP 에 닿아 이 호출을 기대한 SDK 타입으로 실패시켰는가(admin 은 토큰
                        // 단계에서 — 사용자 조회까지 갔으면 변형이 무력했다). 아니면 아래 누출 검사는 빈 것을 찾는다.
                        val reached = server.findAll(postRequestedFor(urlEqualTo(v.path))).size
                        val beyond = server.findAll(getRequestedFor(urlEqualTo(MAL_ADMIN_USER))).size
                        val prefix = expectedPrefix(v.failure, call)
                        val message = (outcome as? Throwable)?.message.orEmpty()
                        if (outcome.javaClass != expectedType(call) || !message.startsWith(prefix) || reached == 0 || beyond > 0) {
                            flow += "$case: 기대 ${expectedType(call).simpleName}('$prefix…') 실패가 아니다" +
                                "(결과 ${outcome.javaClass.simpleName} '$message', IdP 요청 $reached, 그 너머 $beyond)"
                            continue
                        }
                        val error = outcome as Throwable
                        failures[case] = error
                        report += "$case -> " + chainOf(error).joinToString(" <- ") { it.toString() }
                        val outs = linkedMapOf("stackTraceToString()" to error.stackTraceToString(), "toString()" to error.toString())
                        for ((label, value) in v.canaries + MAL_INPUTS) {
                            for ((how, out) in outs) {
                                val hit =
                                    when {
                                        value in out -> "FULL"
                                        value.take(MAL_PREFIX) in out -> "PREFIX$MAL_PREFIX"
                                        else -> null
                                    }
                                if (hit != null) leaks.getOrPut("$case|$label") { mutableListOf() } += "$how $hit"
                            }
                        }
                    }
                }
                println("AuthMalformedResponseTest:\n" + report.joinToString("\n"))
                assertTrue(flow.isEmpty(), "적대 변형이 호출을 기대대로 실패시키지 않았다:\n" + flow.joinToString("\n"))

                val unknown = leaks.filterKeys { it !in MAL_KNOWN_LEAKS }
                assertTrue(unknown.isEmpty(), "SDK 오류가 비밀을 찍는다:\n" + unknown.entries.joinToString("\n") { "${it.key} ${it.value}" })
                val stale = MAL_KNOWN_LEAKS.keys - leaks.keys
                assertTrue(stale.isEmpty(), "알려진 누출이 더 안 난다 — 고쳐졌으면 MAL_KNOWN_LEAKS 에서 지워라: $stale")

                assertDebugInfoKept(failures)
            } finally {
                server.stop()
            }
        }

    // 독립 레그(Grok)의 주장 — admin 호출의 4xx 응답 본문이 오류 표현으로 찍힌다 — 을 잰 것이다. 본문은 공개 필드
    // `keycloakError` 에만 실리고(설계 — 소비자가 서버 사유를 읽는 자리), 기본 표현에는 없다. 내장 TokenManager 의
    // 토큰 단계 4xx(e1·e5·e6·e9 의 ADMIN)는 위 행렬이 잰다.
    @Test
    fun `admin error body stays in keycloakError and out of the print paths`() =
        runTest(timeout = 60.seconds) {
            val server = WireMockServer(wireMockConfig().dynamicPort())
            server.start()
            try {
                fun reply(
                    status: Int,
                    body: String,
                ) = aResponse().withStatus(status).withHeader("Content-Type", "application/json").withBody(body)
                server.stubFor(post(urlEqualTo(MAL_TOKEN)).willReturn(reply(200, tokens("G1"))))
                val body = """{"error":"G1BODYLEAK-admin-error-0001"}"""
                server.stubFor(get(urlEqualTo(MAL_ADMIN_USER)).willReturn(reply(400, body)))
                val e =
                    AdminClient(KeycloakConfig(server.baseUrl(), "r", "c", MAL_SECRET.toCharArray())).use { admin ->
                        assertFailsWith<KeycloakAdminException.Other> { admin.users().get("u1") }
                    }
                // 흐름 대조 — 본문이 정말 SDK 에 닿았다.
                assertEquals(body, e.keycloakError)
                for (out in listOf(e.stackTraceToString(), e.toString())) {
                    listOf("G1BODYLEAK", "G1ATLEAK", "G1RTLEAK", MAL_SECRET.take(MAL_PREFIX)).forEach {
                        assertFalse(it in out, "$it 가 찍혔다:\n$out")
                    }
                }
            } finally {
                server.stop()
            }
        }
}

// 가리는 것이 디버깅 정보까지 지우지 않는다 — SDK 메시지·OAuth 오류 코드·하위 예외의 **타입 이름**은 남는다.
// 그리고 응답을 쥐던 하위 예외 객체는 원인 사슬에 없다(§4 — 하위 타입이 공개 API 로 새지 않는다).
private fun assertDebugInfoKept(failures: Map<String, Throwable>) {
    fun at(case: String): Throwable = checkNotNull(failures[case]) { "$case 가 실패 목록에 없다" }

    val lowerPackages = listOf("com.nimbusds.", "net.minidev.", "com.fasterxml.jackson.")
    val nimbusJson = listOf("com.nimbusds.oauth2.sdk.ParseException", "net.minidev.json.parser.ParseException")
    val kept =
        listOf(
            "d1 200 short non-JSON body|CLIENT_CREDENTIALS" to nimbusJson,
            "f1 introspect 200 short non-JSON body|INTROSPECT" to nimbusJson,
            "c3 token_type is an unknown string|REFRESH" to listOf("com.nimbusds.oauth2.sdk.ParseException"),
            "d1 200 short non-JSON body|ADMIN" to
                listOf("jakarta.ws.rs.client.ResponseProcessingException", "com.fasterxml.jackson.core.JsonParseException"),
            "d4 200 JSON string body|ADMIN" to listOf("com.fasterxml.jackson.databind.exc.MismatchedInputException"),
        )
    for ((case, types) in kept) {
        val e = at(case)
        val printed = e.stackTraceToString()
        types.forEach { assertTrue("Caused by: $it" in printed, "$case: 하위 예외 타입 $it 이 사라졌다:\n$printed") }
        val raw = chainOf(e).drop(1).map { it.javaClass.name }.filter { n -> lowerPackages.any { n.startsWith(it) } }
        assertTrue(raw.isEmpty(), "$case: 응답을 쥔 하위 예외 객체가 원인 사슬에 그대로 달렸다: $raw")
    }
    assertEquals("Malformed auth response", at("d1 200 short non-JSON body|EXCHANGE").message)
    assertEquals("Malformed introspection response", at("f2 introspect 200 long non-JSON body|INTROSPECT").message)
    assertEquals("Admin request failed", at("d2 200 long non-JSON body|ADMIN").message)
    val echoed = at("e3 400 error_description echoes the sent refresh token|REFRESH") as KeycloakAuthException
    assertEquals("Token refresh failed: Invalid refresh token: *** (client ***)", echoed.message)
    assertEquals("invalid_grant", echoed.oauthError)
    val foreign = at("e1 400 error_description echoes a foreign token|CLIENT_CREDENTIALS") as KeycloakAuthException
    assertEquals("Client credentials failed: Token E1DESCLEAK-echoed-0001 is not active", foreign.message)
}
