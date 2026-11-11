package io.github.xzawed.keycloak

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import java.lang.reflect.Modifier
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.util.Base64
import java.util.concurrent.Executors
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The OAuth `error` code an SDK error carries is a code, never a value the request sent (registry
 * `token-error-code-secret-echo` · `oauth-error-field-echo-unmasked`).
 *
 * The IdP's `error` is response body too. An endpoint (or a proxy) that echoes what the request sent puts the client secret,
 * the refresh token or the introspected token there — and `oauthError` carried any value in the RFC 6749 grammar Nimbus
 * accepts, a Keycloak-style secret and a JWT included (measured on main a7d0fdf3). One rule now ([OAuthErrorCode]):
 * `[a-z_]{1,64}` and overlapping no non-empty secret the request sent — neither contains the other, so a truncated or
 * extended echo is withheld too. The price is pinned below: a secret that is a piece of a registered code (`client`)
 * withholds that code. The admin facade's own grant never carried a code — unchanged.
 */
class OAuthErrorCodeEchoTest {
    private lateinit var server: HttpServer
    private val handlers = Executors.newCachedThreadPool()
    private val sent = mutableListOf<Map<String, String>>()

    @Volatile private var errorJson: (Map<String, String>) -> String = { "\"invalid_request\"" }

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.executor = handlers
        server.createContext("/") { handle(it) }
        server.start()
    }

    @AfterTest
    fun stop() {
        server.stop(0)
        handlers.shutdownNow()
    }

    private fun handle(ex: HttpExchange) {
        val form = HashMap<String, String>()
        val body = ex.requestBody.readAllBytes().toString(Charsets.UTF_8)
        for (pair in body.split('&').filter { it.isNotEmpty() }) {
            val (name, value) = pair.split('=', limit = 2).let { it[0] to it.getOrElse(1) { "" } }
            form[URLDecoder.decode(name, Charsets.UTF_8)] = URLDecoder.decode(value, Charsets.UTF_8)
        }
        val auth = ex.requestHeaders.getFirst("Authorization")
        if (auth != null && auth.startsWith("Basic ")) {
            val pair = Base64.getDecoder().decode(auth.substring(6)).toString(Charsets.UTF_8)
            form["client_secret"] = URLDecoder.decode(pair.substringAfter(':'), Charsets.UTF_8)
        }
        val json =
            synchronized(sent) {
                sent += form
                "{\"error\":${errorJson(form)}}"
            }
        val bytes = json.toByteArray()
        ex.responseHeaders.add("Content-Type", "application/json")
        ex.sendResponseHeaders(400, bytes.size.toLong())
        ex.responseBody.use { it.write(bytes) }
    }

    private fun quoted(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

    /** surface → (secret form fields it sends besides the client secret, call). */
    private val surfaces: Map<String, Pair<List<String>, suspend (KeycloakClient) -> Unit>> =
        linkedMapOf(
            "clientCredentialsToken" to (emptyList<String>() to { kc -> kc.auth.clientCredentialsToken() }),
            "provider" to
                (
                    emptyList<String>() to { kc ->
                        ClientCredentialsTokenProvider(fetch = { kc.auth.clientCredentialsToken() }).accessToken()
                    }
                ),
            "refresh" to (listOf("refresh_token") to { kc -> kc.auth.refresh(REFRESH) }),
            "exchangeCode" to
                (listOf("code", "code_verifier") to { kc -> kc.auth.exchangeCode(CODE, VERIFIER, "https://app.example/cb") }),
            "introspect" to (listOf("token") to { kc -> kc.auth.introspect(TOKEN) }),
        )

    private fun failing(
        surface: String,
        secret: String? = SECRET,
    ): KeycloakAuthException {
        synchronized(sent) { sent.clear() }
        val cfg =
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = "r",
                clientId = "c",
                clientSecret = secret?.toCharArray(),
            )
        return runBlocking {
            KeycloakClient.create(cfg).use { kc ->
                try {
                    surfaces.getValue(surface).second(kc)
                    fail("$surface did not fail")
                } catch (e: KeycloakAuthException) {
                    e
                }
            }
        }
    }

    private fun firstSent(): Map<String, String> =
        synchronized(sent) {
            assertTrue(sent.isNotEmpty(), "no token request reached the IdP")
            sent.first()
        }

    private fun renderings(e: Throwable): List<String> {
        val out = mutableListOf(e.stackTraceToString())
        var x: Throwable? = e
        while (x != null) {
            out += x.toString()
            var c: Class<*>? = x.javaClass
            while (c != null && !c.name.startsWith("java.") && !c.name.startsWith("kotlin.")) {
                for (f in c.declaredFields) {
                    if (Modifier.isStatic(f.modifiers)) continue
                    runCatching {
                        f.isAccessible = true
                        out += f.get(x).toString()
                    }
                }
                c = c.superclass
            }
            x = x.cause
        }
        return out
    }

    private fun assertWithheld(
        label: String,
        e: KeycloakAuthException,
        value: String,
    ) {
        assertNull(e.oauthError, label)
        for (text in renderings(e)) assertFalse(text.contains(value), "$label: a rendering shows $value: $text")
    }

    private val echoForms: Map<String, (String) -> String> =
        mapOf("whole" to { v -> v }, "truncated" to { v -> v.substring(0, 11) }, "extended" to { v -> v + "_x" })

    @Test
    fun anEchoedClientSecretIsNeverCarried() {
        for (surface in surfaces.keys) {
            for ((form, shape) in echoForms) {
                errorJson = { s -> quoted(shape(s["client_secret"].orEmpty())) }
                val e = failing(surface)
                assertEquals(SECRET, firstSent()["client_secret"], surface)
                assertWithheld("$surface · $form", e, shape(SECRET))
            }
        }
    }

    @Test
    fun anEchoedGrantValueIsNeverCarried() {
        for ((surface, entry) in surfaces) {
            for (param in entry.first) {
                for ((form, shape) in echoForms) {
                    errorJson = { s -> quoted(shape(s[param].orEmpty())) }
                    val e = failing(surface)
                    assertWithheld("$surface · $param · $form", e, shape(firstSent().getValue(param)))
                }
            }
        }
    }

    @Test
    fun aPublicClientWithholdsItsEchoedRefreshTokenAndStillGetsACode() {
        errorJson = { s -> quoted(s["refresh_token"].orEmpty()) }
        assertWithheld("public · echo", failing("refresh", secret = null), REFRESH)
        assertTrue(firstSent()["client_secret"].isNullOrEmpty(), "a public client sent a client secret")
        errorJson = { quoted("invalid_grant") }
        assertEquals("invalid_grant", failing("refresh", secret = null).oauthError)
    }

    @Test
    fun aValueThatIsNotACodeIsNeverCarried() {
        val values =
            listOf(
                "Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5",
                "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl",
                "Invalid_client",
                "invalid client",
                "invalid_client2",
                "a".repeat(65),
            )
        for (surface in surfaces.keys) {
            for (value in values) {
                errorJson = { quoted(value) }
                assertWithheld("$surface · $value", failing(surface), value)
            }
        }
    }

    @Test
    fun aCodeThatOverlapsNothingSentIsCarried() {
        for (surface in surfaces.keys) {
            for (code in listOf("invalid_client", "invalid_grant", "slow_down", "a".repeat(64))) {
                errorJson = { quoted(code) }
                assertEquals(code, failing(surface).oauthError, surface)
            }
        }
    }

    @Test
    fun thePriceASecretThatIsAPieceOfTheCodeWithholdsIt() {
        errorJson = { quoted("invalid_client") }
        for (surface in listOf("clientCredentialsToken", "provider")) {
            assertNull(failing(surface, secret = "client").oauthError, surface)
        }
    }

    private companion object {
        const val SECRET = "echoedlowersecret" // code-shaped on purpose: the shape alone cannot withhold it
        const val REFRESH = "echoedlowerrefresh"
        const val TOKEN = "echoedlowerintrospected"
        const val CODE = "echoedlowercode"
        const val VERIFIER = "echoedlowerverifierechoedlowerverifierechoedlower"
    }
}
