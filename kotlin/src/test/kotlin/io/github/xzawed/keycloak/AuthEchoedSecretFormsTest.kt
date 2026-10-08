package io.github.xzawed.keycloak

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.Base64
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue

// 되울린 값의 **인코딩된 꼴**(Java `AuthEchoedSecretFormsTest` 동형) — IdP·프록시가 이 요청이 보낸 값(클라이언트 시크릿 · Basic
// 자격 · 본문의 비밀 값)을 error_description 에 되울릴 때, 그 값이 어느 꼴로 오든 SDK 오류(메시지 · toString ·
// stackTraceToString · 원인 메시지)에 남지 않는다. 꼴: 그대로(Nimbus 가 RFC 6749 §5.2 밖의 글자를 지운 뒤) · 폼 인코딩(Basic 의
// 비밀번호 칸이 이 꼴이다 — RFC 6749 §2.3.1) · RFC 3986 퍼센트 인코딩(공백 %20, ~ 그대로) · 두 인코딩의 소문자 16진 · Grok 레그가
// 낸 실제 인코더와 변형(그대로 두는 글자·문자 집합이 다른 것 — Go url.QueryEscape · Python quote · JS encodeURI·escape · ISO-8859-1
// 폼, 공백과 + 가 뒤섞인 것, 한 겹 더 인코딩된 것, %uXXXX) · Basic 자격(base64) · 그것을 푼 userinfo(c:<폼 인코딩된 시크릿>)와 그것을
// 한 번 더 인코딩한 꼴.
//
// ⚠️ 메시지를 **통째로** 대조한다 — 꼴마다 「그 문자열이 없다」만 보면 부분 누출(첫 낱말만 남은 꼴)이 통과한다. 사유 문구
// (Bad credentials:)가 남는 것도 같은 대조가 본다. 인코더는 이 시험이 따로 만든다(SDK 의 것을 빌리면 같은 실수를 함께 한다).
// 공개 API 만 부른다. 네트워크는 루프백만.
private const val EF_CLIENT_ID = "c"
private const val EF_SECRET = "sec ret/+=~0005é"
private const val EF_REFRESH = "rt ref/+=~0007é"
private const val EF_TOKEN = "at tok/+=~0008é"
private const val EF_CODE = "cd code/+=~0009é"

// RFC 7636 §4.1 — 43–128 자, [A-Za-z0-9-._~]. ~ 는 폼 인코딩만 바꾼다.
private const val EF_VERIFIER = "vVERIF~0123456789abcdefghijklmnopqrstuvwxyzAB"
private const val EF_BASIC = "BASIC"
private const val EF_CB = "https://app/cb"

// 인코더 — 알파벳·숫자와 safe 는 그대로, 공백은 + 또는 %20, 나머지 바이트(그 문자 집합)는 %XX.
private class EfEncoder(
    val safe: String,
    val spacePlus: Boolean,
    val lower: Boolean,
    val charset: Charset = StandardCharsets.UTF_8,
) {
    fun apply(v: String): String =
        buildString {
            for (b in v.toByteArray(charset)) {
                val c = b.toInt() and 0xFF
                when {
                    c in 'a'.code..'z'.code || c in 'A'.code..'Z'.code || c in '0'.code..'9'.code || safe.indexOf(c.toChar()) >= 0 ->
                        append(c.toChar())
                    c == ' '.code && spacePlus -> append('+')
                    else -> append(if (lower) "%%%02x".format(c) else "%%%02X".format(c))
                }
            }
        }
}

// 공백·% 를 뺀 ASCII 출력 글자 — nonascii-only 가 그대로 두는 것.
private const val EF_PRINTABLE_ASCII = "!\"#$&'()*+,-./:;<=>?@[\\]^_`{|}~"

// JS escape — 알파벳·숫자와 @*_+-./ 는 그대로, U+00FF 까지는 %XX, 그 위는 %uXXXX.
private fun efJsEscape(v: String): String =
    buildString {
        for (c in v) {
            when {
                c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c in "@*_+-./" -> append(c)
                c.code <= 0xFF -> append("%%%02X".format(c.code))
                else -> append("%%u%04X".format(c.code))
            }
        }
    }

// 꼴 이름 → 인코더. 앞의 넷은 SDK 가 꼴로 늘어놓는 것이고, 나머지는 Grok 레그가 낸 실제 인코더·변형이다(레그 1: 그대로 두는 글자·
// 문자 집합이 다른 것, 레그 2: 공백과 + 가 뒤섞이거나 한 겹 더 인코딩되거나 %uXXXX 인 것).
private val EF_FORM = EfEncoder("*-._", spacePlus = true, lower = false)
private val EF_PCT = EfEncoder("-._~", spacePlus = false, lower = false)
private val EF_QUERY = EfEncoder("-._~", spacePlus = true, lower = false)
private val EF_ENCODERS: Map<String, (String) -> String> =
    linkedMapOf(
        "form" to EF_FORM::apply, // Java URLEncoder · WHATWG
        "form-lower" to EfEncoder("*-._", spacePlus = true, lower = true)::apply, // .NET HttpUtility.UrlEncode
        "pct" to EF_PCT::apply, // RFC 3986 · Uri.EscapeDataString
        "pct-lower" to EfEncoder("-._~", spacePlus = false, lower = true)::apply,
        "query" to EF_QUERY::apply, // Go url.QueryEscape · Python quote_plus
        "path" to EfEncoder("-._~/", spacePlus = false, lower = false)::apply, // Python quote (safe='/')
        "uri" to EfEncoder("-._~!*'();/?:@&=+$,#", spacePlus = false, lower = false)::apply, // JS encodeURI
        "latin1-form" to EfEncoder("*-._", spacePlus = true, lower = false, StandardCharsets.ISO_8859_1)::apply, // URLEncoder ISO-8859-1
        "js-escape" to ::efJsEscape, // JS escape — %E9 · %uXXXX
        "unicode-escape" to { v: String -> v.map { "%%u%04X".format(it.code) }.joinToString("") }, // .NET UrlEncodeUnicode 류
        "nonascii-only" to EfEncoder(EF_PRINTABLE_ASCII, spacePlus = true, lower = false)::apply, // 비 ASCII 만, 공백은 +
        "space-as-2B" to { v: String -> EF_FORM.apply(v).replace("+", "%2B") }, // 폼 뒤 + 를 %2B 로 바꾼 게이트웨이
        "requoted" to { v: String -> EF_PCT.apply(EF_QUERY.apply(v)) }, // quote_plus 된 값을 다시 인코딩
        // UTF-8 을 ISO-8859-1 로 읽고 폼
        "mojibake" to { v: String -> EF_FORM.apply(String(v.toByteArray(StandardCharsets.UTF_8), StandardCharsets.ISO_8859_1)) },
        "json-escape-url" to { v: String -> EF_FORM.apply(efNonAscii(v) { "\\u%04x".format(it.code) }) }, // JSON 유니코드 이스케이프 뒤 폼
        "entity-url" to { v: String -> EF_FORM.apply(efNonAscii(v) { "&#${it.code};" }) }, // &#233; 뒤 폼
        "html-entity" to ::efHtmlEntities, // 알파벳·숫자 밖을 전부 &#NN;
        "xmlcharref" to { v: String -> efNonAscii(v) { "&#${it.code};" } }, // Python encode('ascii','xmlcharrefreplace')
    )

// 비 ASCII 글자만 render 로.
private fun efNonAscii(
    v: String,
    render: (Char) -> String,
): String = v.map { if (it.code < 0x80) it.toString() else render(it) }.joinToString("")

// 알파벳·숫자 밖의 글자를 전부 10진 HTML 숫자 참조로.
private fun efHtmlEntities(v: String): String =
    v
        .codePoints()
        .toArray()
        .joinToString("") { cp -> if (cp < 0x80 && Character.isLetterOrDigit(cp)) String(Character.toChars(cp)) else "&#$cp;" }

private val EF_VARIANTS = listOf("raw") + EF_ENCODERS.keys
private val EF_BASIC_ONLY = listOf("b64", "userinfo", "userinfo-pct")

// RFC 6749 §5.2 — error_description 에 허용되는 글자(%x20-21 / %x23-5B / %x5D-7E).
private fun efLegal(s: String): String = s.filter { it.code in 0x20..0x21 || it.code in 0x23..0x5b || it.code in 0x5d..0x7e }

// 보낸 값이 오류에 실릴 수 있는 꼴 전부 — 이 중 어느 것도 오류의 어느 표현에도 없어야 한다.
private fun efForms(sent: String): Set<String> {
    val received = String(sent.toByteArray(StandardCharsets.UTF_8), StandardCharsets.UTF_8)
    return listOf(sent, received)
        .flatMap { v -> listOf(v, efLegal(v)) + EF_ENCODERS.values.map { encode -> encode(v) } }
        .filter { it.length >= 8 }
        .toSet()
}

// Nimbus ClientSecretBasic 이 싣는 자격 — client id 와 시크릿을 각각 폼 인코딩해 잇고 base64(RFC 6749 §2.3.1).
private fun efCredentialOf(secret: String): String =
    Base64.getEncoder().encodeToString(
        (URLEncoder.encode(EF_CLIENT_ID, StandardCharsets.UTF_8) + ":" + URLEncoder.encode(secret, StandardCharsets.UTF_8))
            .toByteArray(StandardCharsets.UTF_8),
    )

private fun efBasicForms(secret: String): Set<String> {
    val credential = efCredentialOf(secret)
    val userinfo = String(Base64.getDecoder().decode(credential), StandardCharsets.UTF_8)
    return efForms(secret) + credential + userinfo + EF_PCT.apply(userinfo)
}

// 꼴마다 메시지에 남아야 할 꼬리 — 시크릿이 있던 자리만 *** 다(client id 와 인코딩된 : 는 비밀이 아니다).
private fun efMasked(variant: String): String =
    when (variant) {
        "userinfo" -> "$EF_CLIENT_ID:***"
        "userinfo-pct" -> "$EF_CLIENT_ID%3A***"
        else -> "***"
    }

internal class AuthEchoedSecretFormsTest {
    private lateinit var server: HttpServer

    // 되울릴 것 — 폼 파라미터 이름, 또는 BASIC 이면 Basic 자격의 시크릿(서버가 디코딩한 꼴).
    @Volatile private var target = EF_BASIC

    @Volatile private var variant = "raw"

    // 마지막으로 되울린 문자열(서버가 실제로 쓴 꼴).
    @Volatile private var echoed = ""

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/") { answer(it) }
        server.start()
    }

    @AfterTest
    fun stop() {
        server.stop(0)
    }

    // 받은 값을 고른 꼴로 되울리는 IdP — 토큰·introspection·logout 엔드포인트 모두 401 invalid_client.
    private fun answer(ex: HttpExchange) {
        val form =
            ex.requestBody
                .readAllBytes()
                .decodeToString()
                .split("&")
                .filter { it.contains('=') }
                .associate { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), StandardCharsets.UTF_8) }
        val credential =
            ex.requestHeaders
                .getFirst("Authorization")
                ?.substringAfter(' ')
                .orEmpty()
        val userinfo = String(Base64.getDecoder().decode(credential), StandardCharsets.UTF_8)
        val value =
            if (target == EF_BASIC) {
                URLDecoder.decode(userinfo.substringAfter(':'), StandardCharsets.UTF_8)
            } else {
                form[target].orEmpty()
            }
        val text =
            when (variant) {
                "raw" -> value
                "b64" -> credential
                "userinfo" -> userinfo
                "userinfo-pct" -> EF_PCT.apply(userinfo) // 받은 userinfo 를 그대로 한 번 더 인코딩
                else -> EF_ENCODERS.getValue(variant)(value)
            }
        echoed = text
        val body = """{"error":"invalid_client","error_description":"Bad credentials: $text"}""".toByteArray()
        ex.responseHeaders.add("Content-Type", "application/json")
        ex.sendResponseHeaders(401, body.size.toLong())
        ex.responseBody.use { it.write(body) }
    }

    private fun auth(secret: String = EF_SECRET): AuthClient =
        AuthClient(
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = "r",
                clientId = EF_CLIENT_ID,
                clientSecret = secret.toCharArray(),
                readTimeout = Duration.ofSeconds(10),
            ),
        )

    private suspend fun failureOf(block: suspend () -> Unit): Throwable? =
        try {
            block()
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            e
        }

    // 오류 하나 — 메시지를 통째로 대조하고, 로거가 찍는 표현 전부에서 보낸 값의 꼴을 찾는다.
    private fun check(
        label: String,
        thrown: Throwable?,
        expected: String,
        forms: Set<String>,
        wrong: MutableList<String>,
        table: MutableList<String>,
    ) {
        table += "${label.padEnd(46)} echoed=${echoed.padEnd(48)} → ${thrown?.let { "${it.javaClass.simpleName}: ${it.message}" } ?: "성공"}"
        if (thrown !is KeycloakAuthException) {
            wrong += "$label: KeycloakAuthException 이 아니다 — $thrown"
            return
        }
        if (thrown.message != expected) wrong += "$label: 메시지 「${thrown.message}」 ≠ 「$expected」"
        val all =
            buildString {
                append(thrown.toString())
                    .append('\n')
                    .append(thrown.stackTraceToString())
                    .append('\n')
                    .append(thrown.oauthError)
                generateSequence(thrown.cause) { it.cause }.take(16).forEach { append('\n').append(it.message) }
            }
        for (f in forms) {
            if (f in all) wrong += "$label: 오류가 보낸 값의 꼴 「$f」 을 찍었다"
        }
    }

    // 시크릿은 기밀 클라이언트의 모든 레인에서 Basic 으로 나간다 — 꼴마다 · 레인마다 같은 결과여야 한다.
    @Test
    fun `an echoed client secret is masked in every form on every lane`() =
        runTest {
            val lanes =
                linkedMapOf<String, suspend (AuthClient) -> Unit>(
                    "Client credentials failed" to { it.clientCredentialsToken() },
                    "Token refresh failed" to { it.refresh(EF_REFRESH) },
                    "Introspection failed" to { it.introspect(EF_TOKEN) },
                    "Authorization code exchange failed" to { it.exchangeCode(EF_CODE, EF_VERIFIER, EF_CB) },
                    "Logout failed" to { it.logout(EF_REFRESH) },
                )
            val forms = efBasicForms(EF_SECRET)
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            target = EF_BASIC
            for ((prefix, call) in lanes) {
                for (v in EF_VARIANTS + EF_BASIC_ONLY) {
                    variant = v
                    val expected = if (prefix == "Logout failed") "Logout failed (HTTP 401)" else "$prefix: Bad credentials: ${efMasked(v)}"
                    check("$prefix · secret $v", failureOf { call(auth()) }, expected, forms, wrong, table)
                }
            }
            println("[AuthEchoedSecretFormsTest 시크릿]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 본문의 비밀 값(호출자의 refresh·introspect 토큰 · 인가 코드 · verifier)도 같은 꼴로 되울린다.
    @Test
    fun `an echoed grant value is masked in every form`() =
        runTest {
            class Case(
                val label: String,
                val param: String,
                val value: String,
                val prefix: String,
                val call: suspend (AuthClient) -> Unit,
            )
            val cases =
                listOf(
                    Case("refresh · refresh_token", "refresh_token", EF_REFRESH, "Token refresh failed") { it.refresh(EF_REFRESH) },
                    Case("introspect · token", "token", EF_TOKEN, "Introspection failed") { it.introspect(EF_TOKEN) },
                    Case("exchangeCode · code", "code", EF_CODE, "Authorization code exchange failed") {
                        it.exchangeCode(EF_CODE, EF_VERIFIER, EF_CB)
                    },
                    Case("exchangeCode · code_verifier", "code_verifier", EF_VERIFIER, "Authorization code exchange failed") {
                        it.exchangeCode(EF_CODE, EF_VERIFIER, EF_CB)
                    },
                    Case("logout · refresh_token", "refresh_token", EF_REFRESH, "Logout failed") { it.logout(EF_REFRESH) },
                )
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            for (c in cases) {
                target = c.param
                for (v in EF_VARIANTS) {
                    variant = v
                    val expected =
                        if (c.prefix == "Logout failed") "Logout failed (HTTP 401)" else "${c.prefix}: Bad credentials: ***"
                    check("${c.label} $v", failureOf { c.call(auth()) }, expected, efForms(c.value), wrong, table)
                }
            }
            println("[AuthEchoedSecretFormsTest 본문 값]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 짝 없는 서로게이트 — UTF-8 이 그 자리에 ? 를 실어 보내므로 IdP 는 그 꼴을 되울린다(받은 꼴).
    @Test
    fun `an echoed secret in its received form is masked`() =
        runTest {
            val surrogate = "sur ab\uD800cd/+=~0006"
            target = EF_BASIC
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            for (v in EF_VARIANTS) {
                variant = v
                check(
                    "cc · surrogate secret $v",
                    failureOf { auth(surrogate).clientCredentialsToken() },
                    "Client credentials failed: Bad credentials: ***",
                    efBasicForms(surrogate),
                    wrong,
                    table,
                )
            }
            println("[AuthEchoedSecretFormsTest 받은 꼴]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }
}
