package io.github.xzawed.keycloak

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import java.lang.reflect.Modifier
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URI
import java.net.URLDecoder
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
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
 * withholds that code. The admin facade's own grant takes the same rule — at an error status it carried no code at all
 * before (registry `oauth-error-code-surface-divergent`).
 */
class OAuthErrorCodeEchoTest {
    private lateinit var server: HttpServer
    private val handlers = Executors.newCachedThreadPool()
    private val sent = mutableListOf<Map<String, String>>()

    @Volatile private var errorJson: (Map<String, String>) -> String = { "\"invalid_request\"" }

    @Volatile private var status = 400

    /** When set, the whole answer body instead of `{"error": …}`. */
    @Volatile private var rawBody: String? = null

    /** When set, a `Location` header on the answer. */
    @Volatile private var location: String? = null

    /** Every request as `METHOD /path`, in order — the 3xx cells read which method reached [REDIRECT_TARGET]. */
    private val requests = mutableListOf<String>()

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
        val path = ex.requestURI.path
        synchronized(sent) { requests += "${ex.requestMethod} $path" }
        val form = HashMap<String, String>()
        val body = ex.requestBody.readAllBytes().toString(Charsets.UTF_8)
        if (path == REDIRECT_TARGET) {
            val reached = "{\"error\":\"redirect_target_reached\"}".toByteArray()
            ex.responseHeaders.add("Content-Type", "application/json")
            ex.sendResponseHeaders(400, reached.size.toLong())
            ex.responseBody.use { it.write(reached) }
            return
        }
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
                rawBody ?: "{\"error\":${errorJson(form)}}"
            }
        val bytes = json.toByteArray()
        ex.responseHeaders.add("Content-Type", "application/json")
        location?.let { ex.responseHeaders.add("Location", it) }
        ex.sendResponseHeaders(status, bytes.size.toLong())
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
            "admin" to (emptyList<String>() to { kc -> kc.admin.users().get("u1") }),
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

    /** Every piece and every padding, so each direction of the overlap is pinned. */
    private val echoForms: Map<String, (String) -> String> =
        mapOf(
            "whole" to { v -> v },
            "prefix" to { v -> v.substring(0, 11) },
            "suffix" to { v -> v.substring(v.length - 11) },
            "middle" to { v -> v.substring(2, 11) },
            "extended" to { v -> v + "_x" },
            "prefixed" to { v -> "x_$v" },
            "wrapped" to { v -> "x_${v}_x" },
        )

    /** Keycloak answers a bad client with 401, not 400 — an error status other than 400 takes the same rule. */
    @Test
    fun anEchoOnA401IsNeverCarried() {
        status = 401
        for ((surface, entry) in surfaces) {
            for (param in listOf("client_secret") + entry.first) {
                errorJson = { s -> quoted(s[param].orEmpty()) }
                val e = failing(surface)
                assertWithheld("$surface · 401 · $param", e, firstSent().getValue(param))
            }
        }
    }

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

    /** An IdP or proxy that echoes the secret lowercased — the overlap ignores ASCII case. */
    @Test
    fun aLowercasedEchoOfTheClientSecretIsNeverCarried() {
        val mixed = "EchoMixedCase"
        errorJson = { s -> quoted(s["client_secret"].orEmpty().lowercase()) }
        for (surface in surfaces.keys) {
            val e = failing(surface, secret = mixed)
            assertEquals(mixed, firstSent()["client_secret"], surface)
            assertWithheld("$surface · lowercased", e, "echomixedcase")
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
        for (surface in listOf("clientCredentialsToken", "provider", "admin")) {
            assertNull(failing(surface, secret = "client").oauthError, surface)
        }
    }

    /**
     * The two error statuses the nine languages were measured with (registry `oauth-error-code-surface-divergent`): A is 400
     * `{"error":"invalid_grant"}`, B is 401 `{"error":"invalid_client"}`. Every surface carries the code in `oauthError`, as
     * every one does at 200 (#1184). Before: the admin facade's own grant left it null for both.
     */
    @Test
    fun anErrorStatusCarriesTheCodeOnEverySurface() {
        val wrong = mutableListOf<String>()
        for ((cell, statusAndCode) in mapOf("A" to (400 to "invalid_grant"), "B" to (401 to "invalid_client"))) {
            val (cellStatus, code) = statusAndCode
            status = cellStatus
            errorJson = { quoted(code) }
            for (surface in surfaces.keys) {
                val got = failing(surface).oauthError
                if (got != code) wrong += "$cell · $surface: oauthError $got (want $code)"
            }
        }
        assertTrue(wrong.isEmpty(), "${wrong.size} cells:\n" + wrong.joinToString("\n"))
    }

    // The OAuth `error` at a 3xx and a 5xx (registry node-5xx-oauth-error-code-empty). The contract puts it in the code field
    // "at any status"; that was measured at 400 · 401 (#1199) and the other 2xx (#1207) only. Pinned as the contract reads at
    // 500 · 503 and at 302 (Location on this server — a 3xx is an error status too), which is never followed.

    /** One surface's outcome: `oauthError` (null when not an auth error), one line, and every request seen. */
    private data class Cell(
        val code: String?,
        val line: String,
        val requests: List<String>,
    )

    private fun errorStatusCell(
        surface: String,
        cellStatus: Int,
        body: String,
        cellLocation: String? = null,
    ): Cell {
        synchronized(sent) {
            sent.clear()
            requests.clear()
        }
        status = cellStatus
        rawBody = body
        location = cellLocation
        val cfg =
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = "r",
                clientId = "c",
                clientSecret = SECRET.toCharArray(),
            )
        var code: String? = null
        val outcome =
            runBlocking {
                KeycloakClient.create(cfg).use { kc ->
                    try {
                        surfaces.getValue(surface).second(kc)
                        "success"
                    } catch (e: KeycloakAuthException) {
                        code = e.oauthError
                        "${e.javaClass.simpleName}(${e.message}) code=$code"
                    } catch (e: Exception) {
                        "${e.javaClass.simpleName}(${e.message}) code=-"
                    }
                }
            }
        val seen = synchronized(sent) { requests.toList() }
        return Cell(code, "$cellStatus $surface → $outcome requests=$seen", seen)
    }

    @Test
    fun aServerErrorStatusCarriesTheOAuthErrorOnEverySurface() {
        val table = mutableListOf<String>()
        val wrong = mutableListOf<String>()
        for (s in listOf(500, 503)) {
            for (surface in surfaces.keys) {
                val c = errorStatusCell(surface, s, B5)
                table += c.line
                if (c.code != "temporarily_unavailable") wrong += c.line
            }
        }
        println(table.joinToString("\n"))
        assertTrue(wrong.isEmpty(), "${wrong.size} cells:\n" + wrong.joinToString("\n"))
    }

    /** Controls: the same body at 400 carries it; a 503 whose body names no `error` carries none. */
    @Test
    fun theErrorStatusControlsCarryItAt400AndNoneWithoutOne() {
        val table = mutableListOf<String>()
        val wrong = mutableListOf<String>()
        for (surface in surfaces.keys) {
            val at400 = errorStatusCell(surface, 400, B5)
            val none = errorStatusCell(surface, 503, NO_ERROR)
            table += listOf(at400.line, none.line)
            if (at400.code != "temporarily_unavailable") wrong += at400.line
            if (none.code != null) wrong += none.line
        }
        println(table.joinToString("\n"))
        assertTrue(wrong.isEmpty(), "${wrong.size} cells:\n" + wrong.joinToString("\n"))
    }

    @Test
    fun aRedirectErrorStatusCarriesTheOAuthErrorAndIsNeverFollowed() {
        val table = mutableListOf<String>()
        val wrong = mutableListOf<String>()
        for (surface in surfaces.keys) {
            val c = errorStatusCell(surface, 302, B5, "http://127.0.0.1:${server.address.port}$REDIRECT_TARGET")
            table += c.line
            val followed = c.requests.any { it.endsWith(" $REDIRECT_TARGET") }
            if (followed || c.code != "temporarily_unavailable") wrong += c.line
        }
        println(table.joinToString("\n"))
        assertTrue(wrong.isEmpty(), "${wrong.size} cells:\n" + wrong.joinToString("\n"))
    }

    // ---- Residual divergences (registry token-response-residual-divergence) — the cells' text is the assertion's message,
    // the targets: (A) a 200 whose error is present and neither null nor "" fails like a 400 carrying it — the lane's error
    // class, no code unless a string the echo filter lets through, nothing in the body used (A1–A4 · B2); null and "" still
    // succeed (A5 · A6). (C) a 2xx other than 200 gets the verdict the lane gives a 400 with the same body — class and code;
    // the message may differ only by the status number (C1 ~ C2 · C3 ~ C4). Printed, never asserted: which duplicated error
    // an error status echoes (B1 · B3 · B4 — RFC 8259 §4 leaves it open) and B5 (a 200 whose duplicated error is a code,
    // then "" — a parser differential the registry holds). ----

    private fun ascii(s: String): ByteArray = s.toByteArray(Charsets.US_ASCII)

    /** cell → (status, token-lane body bytes, introspection-lane body bytes) — written as bytes, never through a serializer. */
    private fun residualCells(): Map<String, Triple<Int, ByteArray, ByteArray>> {
        val token = "{\"access_token\":\"AT-ok\",\"token_type\":\"Bearer\",\"expires_in\":300"
        val active = "{\"active\":true,\"username\":\"svc\""
        val cells = linkedMapOf<String, Triple<Int, ByteArray, ByteArray>>()
        cells["A0"] = Triple(200, ascii("$token}"), ascii("$active}"))
        val values = listOf("A1" to "123", "A2" to "{\"a\":1}", "A3" to "[\"x\"]", "A4" to "true", "A5" to "null", "A6" to "\"\"")
        for ((cell, x) in values) {
            cells[cell] = Triple(200, ascii("$token,\"error\":$x}"), ascii("$active,\"error\":$x}"))
        }
        val b1 = ascii("{\"error\":\"invalid_grant\",\"error\":\"temporarily_unavailable\"}")
        cells["B1"] = Triple(400, b1, b1)
        cells["B2"] =
            Triple(
                200,
                ascii("$token,\"error\":\"invalid_grant\",\"error\":\"temporarily_unavailable\"}"),
                ascii("{\"active\":true,\"error\":\"invalid_grant\",\"error\":\"temporarily_unavailable\"}"),
            )
        val b3 = ascii("{\"error\":\"invalid_grant\",\"error\":123}")
        cells["B3"] = Triple(400, b3, b3)
        val b4 = ascii("{\"error\":123,\"error\":\"invalid_grant\"}")
        cells["B4"] = Triple(400, b4, b4)
        cells["B5"] =
            Triple(
                200,
                ascii("$token,\"error\":\"invalid_grant\",\"error\":\"\"}"),
                ascii("{\"active\":true,\"error\":\"invalid_grant\",\"error\":\"\"}"),
            )
        val badUtf8 =
            ascii("{\"error\":\"invalid_grant\",\"error_description\":\"") + byteArrayOf(0xC3.toByte(), 0x28) + ascii("\"}")
        cells["C1"] = Triple(201, badUtf8, badUtf8)
        cells["C2"] = Triple(400, badUtf8, badUtf8)
        val notJson = ascii("not json")
        cells["C3"] = Triple(201, notJson, notJson)
        cells["C4"] = Triple(400, notJson, notJson)
        return cells
    }

    /** Every character outside printable ASCII as a backslash, u, then its code point in uppercase hex in braces; null → null. */
    private fun printable(s: String?): String {
        if (s == null) return "null"
        val out = StringBuilder()
        s.codePoints().forEach { cp ->
            if (cp in 0x20..0x7E) {
                out.appendCodePoint(cp)
            } else {
                out.append("\\u{").append(Integer.toHexString(cp).uppercase()).append('}')
            }
        }
        return out.toString()
    }

    /** The lane's call, returning what it returns — every lane [surfaces] names. */
    private suspend fun callLane(
        lane: String,
        kc: KeycloakClient,
    ): Any =
        when (lane) {
            "clientCredentialsToken" -> kc.auth.clientCredentialsToken()
            "provider" -> ClientCredentialsTokenProvider(fetch = { kc.auth.clientCredentialsToken() }).accessToken()
            "refresh" -> kc.auth.refresh(REFRESH)
            "exchangeCode" -> kc.auth.exchangeCode(CODE, VERIFIER, "https://app.example/cb")
            "introspect" -> kc.auth.introspect(TOKEN)
            "admin" -> kc.admin.users().get("u1")
            else -> throw IllegalArgumentException("no call for lane $lane")
        }

    private fun outcomeOf(t: Throwable): String =
        if (t.javaClass.name.startsWith("io.github.xzawed.keycloak.")) t::class.simpleName.toString() else t.javaClass.name

    /** One lane × cell. Never throws: a failure of any type is the recorded outcome. */
    private fun recordCell(
        lane: String,
        adminAuthorizations: MutableList<String>,
    ): Recorded {
        val cfg =
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = "r",
                clientId = "c",
                clientSecret = SECRET.toCharArray(),
            )
        var result: Any? = null
        var failure: Throwable? = null
        try {
            runBlocking { KeycloakClient.create(cfg).use { kc -> result = callLane(lane, kc) } }
        } catch (t: Throwable) {
            failure = t
        }
        val authorizations = synchronized(adminAuthorizations) { adminAuthorizations.toList() }
        val outcome: String
        val code: String
        val message: String?
        val failed = failure
        if (lane == "admin" && authorizations.isNotEmpty()) {
            val header = authorizations.first()
            outcome = if (header == "Bearer AT-ok") "SUCCESS" else "SENT-WITH-OTHER-AUTHORIZATION"
            code = "-"
            message =
                "admin request sent, Authorization=$header; call=" +
                (if (failed == null) "ok" else outcomeOf(failed) + ": " + failed.message)
        } else if (failed == null) {
            val r = result
            outcome = if (r is TokenSet || r is IntrospectionResult || r is String) "SUCCESS" else "RETURNED-WITHOUT-ADMIN-REQUEST"
            code = "-"
            message =
                when (r) {
                    is TokenSet -> "access_token=${r.accessToken}"
                    is IntrospectionResult -> "active=${r.active}"
                    is String -> "access_token=$r"
                    else -> r.toString()
                }
        } else {
            outcome = outcomeOf(failed)
            code =
                if (failed is KeycloakAuthException) {
                    failed.oauthError?.let { "\"" + printable(it) + "\"" } ?: "null"
                } else {
                    "n/a"
                }
            message = failed.message
        }
        val used = if (lane == "admin") authorizations.isNotEmpty() else failed == null
        return Recorded(listOf(outcome, code, printable(message)), if (used || failed == null) "SUCCESS" else outcomeOf(failed), used)
    }

    /**
     * One lane × cell's outcome — [row] is (outcome, code, message) (the assertions' text), [shown] the outcome class alone and
     * [used] whether anything in the body was used (a token returned, active read, an admin request sent).
     */
    private class Recorded(
        val row: List<String>,
        val shown: String,
        val used: Boolean,
    )

    /** The message with its status number named alike — (C) lets the message differ by it alone. */
    private fun statusBlind(
        message: String,
        status: Int,
    ): String = message.replace("HTTP $status", "HTTP <status>")

    /** Each cell of one lane that misses its target (A · B2 · C) — none means the lane meets them. */
    private fun residualWrong(
        lane: String,
        rows: Map<String, List<String>>,
    ): List<String> {
        val wrong = mutableListOf<String>()
        // (A) the cells a token or introspection lane takes as success — no error, a null one, ""
        for (cell in listOf("A0", "A5", "A6")) {
            if (rows.getValue(cell)[0] != "SUCCESS") wrong += "$lane $cell: ${rows.getValue(cell).joinToString("|")} -- wants SUCCESS"
        }
        // (A) a 200 whose error is a number, an object, an array, a boolean — and (B) a duplicated string one
        for (cell in listOf("A1", "A2", "A3", "A4", "B2")) {
            val (outcome, code) = rows.getValue(cell)
            if (outcome != "KeycloakAuthException" || (cell != "B2" && code != "null")) {
                wrong += "$lane $cell: ${rows.getValue(cell).joinToString("|")} -- wants KeycloakAuthException, no code"
            }
        }
        for ((created, refused) in listOf("C1" to "C2", "C3" to "C4")) {
            val got = rows.getValue(created)
            val want = rows.getValue(refused)
            if (got[0] != want[0] || got[1] != want[1] || statusBlind(got[2], 201) != statusBlind(want[2], 400)) {
                wrong += "$lane $created ${got.joinToString("|")} != $refused ${want.joinToString("|")}"
            }
        }
        return wrong
    }

    /**
     * The bytes a plain client reads for a C cell — the fake's answer on the wire, compared with the cell's bytes (C1/C2 carry
     * 0xC3 0x28 inside a string): null when status and bytes are the cell's, else what differs (never the bytes).
     */
    private fun wireDiffers(
        cell: String,
        status: Int,
        expected: ByteArray,
    ): String? {
        val c =
            URI
                .create("http://127.0.0.1:${server.address.port}/realms/r/protocol/openid-connect/token")
                .toURL()
                .openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.doOutput = true
        c.outputStream.use { it.write(ascii("grant_type=client_credentials")) }
        val got = c.responseCode
        val body = (if (got >= 400) c.errorStream else c.inputStream)?.use { it.readAllBytes() } ?: ByteArray(0)
        c.disconnect()
        val same = body.contentEquals(expected)
        return if (got == status && same) null else "fake $cell: status $got, bytes ${if (same) "equal" else "differ"}"
    }

    /**
     * Registry `token-response-residual-divergence`: every lane × the cells A0–A6 (a 200 whose `error` is not a non-empty
     * string), B1–B5 (a duplicated `error` key) and C1–C4 (a 201 beside a 400 with an invalid-UTF-8 or non-JSON body), after a
     * plain client checks the fake serves the C cells' bytes as written. Holds every lane to the targets above — the admin lane
     * SUCCEEDS only when its request went out with the token.
     */
    @Test
    fun residualDivergenceCellsMeetTheirTargets() {
        val answer = AtomicReference<Pair<Int, ByteArray>>()
        val adminAuthorizations = mutableListOf<String>()
        server.removeContext("/")
        server.createContext("/") { ex ->
            ex.requestBody.readAllBytes()
            val path = ex.requestURI.rawPath
            val (code, bytes) =
                if (ex.requestMethod == "POST" &&
                    (path.endsWith("/protocol/openid-connect/token") || path.endsWith("/protocol/openid-connect/token/introspect"))
                ) {
                    answer.get()
                } else if (ex.requestMethod == "GET" && path == "/admin/realms/r/users/u1") {
                    synchronized(adminAuthorizations) { adminAuthorizations += ex.requestHeaders.getFirst("Authorization") ?: "null" }
                    200 to ascii("{\"id\":\"u1\",\"username\":\"svc\"}")
                } else {
                    404 to ascii("{}")
                }
            ex.responseHeaders.add("Content-Type", "application/json")
            ex.sendResponseHeaders(code, bytes.size.toLong())
            ex.responseBody.use { it.write(bytes) }
        }
        val cells = residualCells()
        val wrong = mutableListOf<String>()
        for (cell in listOf("C1", "C2", "C3", "C4")) {
            val (status, tokenBody, _) = cells.getValue(cell)
            answer.set(status to tokenBody)
            wireDiffers(cell, status, tokenBody)?.let { wrong += it }
        }
        // Only B5 prints — its outcome class and whether anything in the body was used, never a code or a message (the cells'
        // text is the assertion's message alone: CodeQL's clear-text-logging heuristic flags a line built from the OAuth code).
        val b5 = mutableListOf<String>()
        for (lane in surfaces.keys) {
            val rows = linkedMapOf<String, List<String>>()
            for ((cell, c) in cells) {
                answer.set(c.first to (if (lane == "introspect") c.third else c.second))
                synchronized(adminAuthorizations) { adminAuthorizations.clear() }
                val recorded = recordCell(lane, adminAuthorizations)
                rows[cell] = recorded.row
                if (cell == "B5") b5 += "B5|kotlin|$lane|${recorded.shown}|used=${recorded.used}"
            }
            wrong += residualWrong(lane, rows)
        }
        println(b5.joinToString("\n"))
        assertTrue(wrong.isEmpty(), "${wrong.size} cells:\n" + wrong.joinToString("\n"))
    }

    private companion object {
        /** Where the 3xx cells point `Location` (this server, same origin) — a client that follows it shows up in `requests`. */
        const val REDIRECT_TARGET = "/redirect-target"
        const val B5 = "{\"error\":\"temporarily_unavailable\",\"error_description\":\"down\"}"
        const val NO_ERROR = "{\"message\":\"down\"}"

        // Code-shaped on purpose (the shape alone cannot withhold them), and no two share a piece — an echo of one value
        // must be withheld by comparing against THAT value, not a sibling's prefix.
        const val SECRET = "zebrasecretjk"
        const val REFRESH = "yakrefreshvq"
        const val TOKEN = "walrustokenpx"
        const val CODE = "vulturecodeby"
        const val VERIFIER = "ocelotverifierocelotverifierocelotverifierxx"
    }
}
