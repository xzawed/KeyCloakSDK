package io.github.xzawed.keycloak

import dasniko.testcontainers.keycloak.KeycloakContainer
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.TestInstance
import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.net.URI
import java.util.logging.Handler
import java.util.logging.Level
import java.util.logging.LogManager
import java.util.logging.LogRecord
import java.util.logging.Logger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// 인가 코드 교환 E2E — 실제 Keycloak 이 발급한 코드·id_token 으로. python 파일럿
// (`python/tests/integration/test_code_exchange_it.py`)의 모양을 옮긴다.
//
// `exchangeCode` 의 nonce 대조와 id_token 서명 검증은 지금까지 WireMock 이 내민 토큰으로만 돌았다. 여기서는
// [browserLogin] 으로 실제 로그인해 받은 코드를 교환하고, **서버가 서명한** 토큰에 대고 거부 경로까지 돈다.
// Kotlin 은 네트워크 메서드가 전부 suspend 라 변형이 하나다(python 의 sync·aio 에 해당하는 짝이 없다).
// 컨테이너는 FullFlowIT 와 따로 띄운다 — 그쪽은 realm 표시 이름을 바꾸고, 여기서는 세션을 끝낸다.
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
internal class CodeExchangeIT {
    private lateinit var container: KeycloakContainer

    // `sub` 와 대조할 **독립 원천**(admin API)에서 읽은 alice 의 id.
    private lateinit var aliceId: String

    @BeforeAll
    fun startKeycloak(): Unit =
        runBlocking {
            container = KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/it-realm-realm.json")
            container.start()
            val admin =
                KeycloakConfig(
                    serverUrl = container.authServerUrl,
                    realm = "it-realm",
                    clientId = "it-client",
                    clientSecret = "it-secret".toCharArray(),
                )
            KeycloakClient.create(admin).use { kc ->
                val matches =
                    kc.admin
                        .users()
                        .search(ALICE_USERNAME, 0, 10)
                        .filter { it.username == ALICE_USERNAME }
                aliceId = assertNotNull(matches.singleOrNull()?.id, "alice must exist exactly once: $matches")
            }
        }

    @AfterAll
    fun stopKeycloak() {
        if (this::container.isInitialized) {
            container.stop()
        }
    }

    private fun webConfig(
        clientId: String = "it-web",
        algorithms: List<String> = listOf("RS256"),
        scopes: List<String> = emptyList(),
        expectedAudience: String? = null,
    ): KeycloakConfig =
        KeycloakConfig(
            serverUrl = container.authServerUrl,
            realm = "it-realm",
            clientId = clientId,
            clientSecret = WEB_CLIENT_SECRETS.getValue(clientId).toCharArray(),
            scopes = scopes,
            expectedAudience = expectedAudience,
            signatureAlgorithms = algorithms,
        )

    private suspend fun login(kc: KeycloakClient): Pair<AuthorizationRequest, String> {
        val request = kc.auth.createAuthorizationRequest(REDIRECT_URI)
        return request to browserLogin(request, REDIRECT_URI, ALICE_USERNAME, ALICE_PASSWORD)
    }

    /**
     * 교환이 SDK 에서 거부되는지 — 그리고 두 가지를 함께 본다(둘 다 독립 레그 Grok 의 지적, 실측으로 채택).
     *
     * 1. 거부는 서버가 코드를 **쓴 뒤**다 — 같은 코드를 nonce 없이 다시 내면 `invalid_grant` 다. SDK 가 요청도 않고
     *    거부했다면(클라이언트 이름으로 지름길을 낸 구현 등) 그 코드는 살아 있어 두 번째 교환이 성공한다. 이것이 없을 때
     *    `exchangeCode` 첫 줄에 「hs256 클라이언트면 invalid id_token」을 심어도 전부 초록이었다.
     * 2. 오류의 문자열·디버그 꼴·원인 사슬에 코드·verifier·시크릿·JWT 모양 문자열이 없다 — nonce 불일치 예외에
     *    id_token 을 원인으로 실어도 단위·통합 어디서도 안 걸렸다.
     */
    private suspend fun refusedExchange(
        kc: KeycloakClient,
        request: AuthorizationRequest,
        code: String,
        expectedNonce: String,
    ): KeycloakAuthException {
        val refused =
            assertFailsWith<KeycloakAuthException> {
                kc.auth.exchangeCode(code, request.codeVerifier, REDIRECT_URI, expectedNonce = expectedNonce)
            }
        assertNoSecrets(errorForms(refused), listOf(code, request.codeVerifier, WEB_CLIENT_SECRETS.getValue(kc.config.clientId)))
        val spent =
            assertFailsWith<KeycloakAuthException>("the refusal must come after the server spent the code") {
                kc.auth.exchangeCode(code, request.codeVerifier, REDIRECT_URI)
            }
        assertEquals("invalid_grant", spent.oauthError)
        return refused
    }

    @Test
    fun `exchangeCode binds tokens to the nonce and the user, then refresh, introspect and logout`(): Unit =
        runBlocking {
            KeycloakClient.create(webConfig()).use { kc ->
                val (request, code) = login(kc)
                val tokens = kc.auth.exchangeCode(code, request.codeVerifier, REDIRECT_URI, expectedNonce = request.nonce)
                assertTrue(tokens.accessToken.isNotBlank())
                val refreshToken = assertNotNull(tokens.refreshToken)
                val idToken = assertNotNull(tokens.idToken)
                val idClaims = kc.auth.validate(idToken).claims
                assertEquals(request.nonce, idClaims["nonce"])
                assertEquals(aliceId, idClaims["sub"])

                // refresh: 새 접근 토큰을 준다 — 같은 사용자의 활성 토큰이다.
                val refreshed = kc.auth.refresh(refreshToken)
                assertTrue(refreshed.accessToken.isNotBlank())
                assertNotEquals(tokens.accessToken, refreshed.accessToken)
                val rotated = assertNotNull(refreshed.refreshToken)
                val active = kc.auth.introspect(refreshed.accessToken)
                assertTrue(active.active, "a freshly refreshed access token must introspect active")
                assertEquals(ALICE_USERNAME, active.username)

                // logout: 세션을 끝낸다 — 그 refresh token 은 더는 갱신되지 않고 접근 토큰은 비활성이 된다.
                kc.auth.logout(rotated)
                val ended = assertFailsWith<KeycloakAuthException> { kc.auth.refresh(rotated) }
                assertEquals("invalid_grant", ended.oauthError)
                assertFalse(kc.auth.introspect(refreshed.accessToken).active, "logout must deactivate the access token")
            }
        }

    @Test
    fun `exchangeCode refuses a nonce the server did not sign`(): Unit =
        runBlocking {
            KeycloakClient.create(webConfig()).use { kc ->
                val (request, code) = login(kc)
                val refused = refusedExchange(kc, request, code, expectedNonce = "x${request.nonce}")
                assertEquals("Authorization code exchange failed: unexpected nonce", refused.message)
                assertNull(refused.oauthError, "the SDK refused it, not the server")
            }
        }

    /** nonce 를 빼고 인가받은 코드 — 서버는 nonce 없는 id_token 을 낸다. 부재도 거부다. */
    @Test
    fun `exchangeCode refuses an id_token that carries no nonce`(): Unit =
        runBlocking {
            KeycloakClient.create(webConfig()).use { kc ->
                val request = stripNonce(kc.auth.createAuthorizationRequest(REDIRECT_URI))
                // 전제: 서버가 정말 nonce 없이 서명한다(아니면 아래는 부재가 아니라 불일치를 잰다).
                val unchecked =
                    kc.auth.exchangeCode(
                        browserLogin(request, REDIRECT_URI, ALICE_USERNAME, ALICE_PASSWORD),
                        request.codeVerifier,
                        REDIRECT_URI,
                    )
                val uncheckedIdToken = assertNotNull(unchecked.idToken)
                assertFalse("nonce" in kc.auth.validate(uncheckedIdToken).claims, "premise: the server signed no nonce")

                val code = browserLogin(request, REDIRECT_URI, ALICE_USERNAME, ALICE_PASSWORD)
                val refused = refusedExchange(kc, request, code, expectedNonce = request.nonce)
                assertEquals("Authorization code exchange failed: unexpected nonce", refused.message)
            }
        }

    /**
     * `openid` 없는 인가 요청(SDK 의 플레인 OAuth2 분기) — 서버는 id_token 을 내지 않는다. nonce 를 기대했다면
     * 부재가 곧 거부다(무검증 통과가 아니라).
     */
    @Test
    fun `exchangeCode refuses a nonce check when the server issued no id_token`(): Unit =
        runBlocking {
            KeycloakClient.create(webConfig(scopes = listOf("profile"))).use { kc ->
                val request = kc.auth.createAuthorizationRequest(REDIRECT_URI)
                val scope = parseQuery(URI.create(request.authorizationUrl).rawQuery)["scope"]
                assertEquals(listOf("profile"), scope, "premise: the authorization request asks for no openid scope")
                // 전제: 서버가 정말 id_token 을 내지 않는다(아니면 아래는 부재가 아니라 다른 것을 잰다).
                val unchecked =
                    kc.auth.exchangeCode(
                        browserLogin(request, REDIRECT_URI, ALICE_USERNAME, ALICE_PASSWORD),
                        request.codeVerifier,
                        REDIRECT_URI,
                    )
                assertNull(unchecked.idToken, "premise: no id_token without the openid scope")

                val code = browserLogin(request, REDIRECT_URI, ALICE_USERNAME, ALICE_PASSWORD)
                val refused = refusedExchange(kc, request, code, expectedNonce = request.nonce)
                assertEquals("Authorization code exchange failed: missing id_token for nonce validation", refused.message)
            }
        }

    /** id_token 의 `aud` 도 교환 경로에서 강제된다 — 기대 audience 를 다른 값으로 두면 서버가 서명한 정상 토큰도 거부. */
    @Test
    fun `exchangeCode refuses an id_token issued to another audience`(): Unit =
        runBlocking {
            KeycloakClient.create(webConfig(expectedAudience = "not-it-web")).use { kc ->
                val (request, code) = login(kc)
                val refused = refusedExchange(kc, request, code, expectedNonce = request.nonce)
                assertEquals("Authorization code exchange failed: invalid id_token", refused.message)
                assertIs<TokenValidationException>(refused.cause)
            }
        }

    @Test
    fun `reused code is refused without leaking it`(): Unit =
        runBlocking {
            KeycloakClient.create(webConfig()).use { kc ->
                val (request, code) = login(kc)
                // 로그인 자체의 기록(콜백 URL 에 코드가 실린다)은 SDK 의 누출이 아니다 — 여기서부터 잰다.
                val captured =
                    captureOutput {
                        val tokens = kc.auth.exchangeCode(code, request.codeVerifier, REDIRECT_URI, expectedNonce = request.nonce)
                        val reused =
                            assertFailsWith<KeycloakAuthException> {
                                kc.auth.exchangeCode(code, request.codeVerifier, REDIRECT_URI, expectedNonce = request.nonce)
                            }
                        tokens to reused
                    }
                val (tokens, reused) = captured.value
                assertEquals("invalid_grant", reused.oauthError)
                // 문자열·디버그 꼴 전부(errorForms) + JUL 전 로거(ALL) · stdout/stderr.
                assertNoSecrets(
                    errorForms(reused) + captured.printed,
                    listOf(
                        code,
                        request.codeVerifier,
                        WEB_CLIENT_SECRETS.getValue("it-web"),
                        tokens.accessToken,
                        tokens.refreshToken,
                        tokens.idToken,
                    ),
                )
            }
        }

    // `it-web-hs256` 의 id_token 은 realm 의 HMAC 키로 서명된다 — 대칭키는 JWKS 에 없다.
    // ⚠️ 두 변형은 공개 API 로 구별되지 않는다: 알고리즘 핀(RS256 만)과 「핀을 열었지만 키가 없다」가 Nimbus 에서
    // 같은 키 선택 단계의 같은 거부(`JWSVerificationKeySelector` 가 빈 목록)로 끝나 SDK 는 둘 다
    // `TokenValidationException` 원인의 "invalid id_token" 으로 답한다(python 은 `TokenSignatureError` 와
    // `TokenKeyError` 로 갈린다). 원인 사슬의 Nimbus 문구까지 같다(실측: 둘 다 "Signed JWT rejected: Another
    // algorithm expected, or no matching key(s) found"). 그래서 둘 다 돌리되 같은 것을 단언한다.
    @Test
    fun `id_token signed by a key outside the JWKS is refused under the RS256 pin`(): Unit =
        assertHs256Refused(listOf("RS256")) { it.nonce }

    @Test
    fun `id_token signed by a key outside the JWKS is refused even with HS256 allowed`(): Unit =
        assertHs256Refused(listOf("RS256", "HS256")) { it.nonce }

    /**
     * 서명을 **먼저** 본다 — nonce 까지 틀린 HS256 id_token 은 「unexpected nonce」가 아니라 「invalid id_token」이다.
     * 검증 전 페이로드의 nonce 를 먼저 대조하는 구현(Grok 레그 #3)은 다른 테스트 전부를 통과했다.
     */
    @Test
    fun `id_token outside the JWKS is refused before its nonce is compared`(): Unit = assertHs256Refused(listOf("RS256")) { "x${it.nonce}" }

    private fun assertHs256Refused(
        algorithms: List<String>,
        expectedNonce: (AuthorizationRequest) -> String,
    ): Unit =
        runBlocking {
            KeycloakClient.create(webConfig("it-web-hs256", algorithms)).use { kc ->
                val (request, code) = login(kc)
                val refused = refusedExchange(kc, request, code, expectedNonce(request))
                assertEquals("Authorization code exchange failed: invalid id_token", refused.message)
                assertIs<TokenValidationException>(refused.cause)
            }
        }

    private companion object {
        // 인가 코드 흐름용 — realm JSON 의 `it-web`(RS256)·`it-web-hs256`(id_token 을 HS256 서명)과 짝.
        // ⚠️ `it-web` 의 audience 매퍼는 introspect 용이다 — `aud` 가 없는 접근 토큰을 Keycloak 26.6 은
        // 발급한 그 클라이언트가 물어도 `{"active": false}` 로 답한다(python 파일럿 실측).
        const val REDIRECT_URI = "http://localhost/it-callback"
        const val ALICE_USERNAME = "alice"
        const val ALICE_PASSWORD = "alice-password"
        val WEB_CLIENT_SECRETS = mapOf("it-web" to "it-web-secret", "it-web-hs256" to "it-web-hs256-secret")
    }
}

/** 인가 URL 에서 `nonce` 만 뺀다 — 서버가 nonce 클레임 **없는** id_token 을 서명하게 한다. */
internal fun stripNonce(request: AuthorizationRequest): AuthorizationRequest {
    val url = URI.create(request.authorizationUrl)
    val params = url.rawQuery.split('&')
    val kept = params.filterNot { it.substringBefore('=') == "nonce" }
    // 뺄 것이 정확히 하나 있었어야 한다 — 없었다면 아래 테스트는 부재가 아니라 아무것도 재지 않는다.
    assertEquals(params.size - 1, kept.size, "the authorization URL must carry exactly one nonce: $url")
    return request.copy(authorizationUrl = "${url.scheme}://${url.rawAuthority}${url.rawPath}?${kept.joinToString("&")}")
}

// JWT 컴팩트 직렬화의 앞 두 조각 — 헤더·페이로드가 `{"` 로 시작하니 base64url 은 둘 다 `eyJ` 다. 값을 모르는
// id_token(거부돼 호출자에게 돌아오지 않은 것)이 새는지를 이 모양으로 잰다.
private val JWT_SHAPE = Regex("""eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*""")

/** 오류의 문자열·디버그 꼴 전부 — message · toString · 원인 사슬 전체("Caused by:"·"Suppressed:" 까지) · 사슬의 각 고리. */
internal fun errorForms(error: Throwable): List<String> =
    buildList {
        add(error.message.orEmpty())
        add(error.toString())
        add(error.stackTraceToString())
        generateSequence(error.cause) { it.cause }.forEach { add(it.toString()) }
    }

internal fun assertNoSecrets(
    forms: List<String>,
    secrets: List<String?>,
) {
    for (value in secrets) {
        val secret = assertNotNull(value)
        assertTrue(secret.isNotEmpty())
        for (form in forms) {
            assertFalse(secret in form, "a secret leaked into: ${form.take(300)}")
        }
    }
    for (form in forms) {
        assertNull(JWT_SHAPE.find(form), "a JWT-shaped value leaked into: ${form.take(300)}")
    }
}

internal class Captured<T>(
    val value: T,
    val printed: String,
)

/**
 * [block] 동안 stdout·stderr 와 JUL 의 모든 로거(ALL 수준)를 모은다. SDK 는 로거를 쓰지 않지만, 하위
 * 라이브러리(Nimbus·JDK `HttpURLConnection`)가 쓰는 JUL 은 소비자가 켤 수 있는 표면이다.
 */
internal suspend fun <T> captureOutput(block: suspend () -> T): Captured<T> {
    val buffer = ByteArrayOutputStream()
    val sink = PrintStream(buffer, true, Charsets.UTF_8)
    val records = StringBuilder()
    val handler =
        object : Handler() {
            override fun publish(record: LogRecord) {
                synchronized(records) {
                    records.append(record.loggerName).append(' ').append(record.message)
                    record.parameters?.forEach { records.append(' ').append(it) }
                    record.thrown?.let { records.append(' ').append(it.stackTraceToString()) }
                    records.append('\n')
                }
            }

            override fun flush() = Unit

            override fun close() = Unit
        }.apply { level = Level.ALL }
    val root = LogManager.getLogManager().getLogger("")
    val rootLevel = root.level
    val loud = listOf("sun.net.www.protocol.http.HttpURLConnection", "com.nimbusds").map { Logger.getLogger(it) }
    val loudLevels = loud.map { it.level }
    val out = System.out
    val err = System.err
    root.addHandler(handler)
    root.level = Level.ALL
    loud.forEach { it.level = Level.ALL }
    System.setOut(sink)
    System.setErr(sink)
    try {
        val value = block()
        return Captured(value, buffer.toString(Charsets.UTF_8) + synchronized(records) { records.toString() })
    } finally {
        System.setOut(out)
        System.setErr(err)
        root.removeHandler(handler)
        root.level = rootLevel
        loud.zip(loudLevels).forEach { (logger, level) -> logger.level = level }
    }
}
