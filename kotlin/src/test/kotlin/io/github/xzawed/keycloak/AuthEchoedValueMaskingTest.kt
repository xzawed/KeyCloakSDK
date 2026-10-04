package io.github.xzawed.keycloak

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.Base64
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue

// 헤더 경우 탐침(물결 4 item 3) — 토큰·시크릿에 RFC 6749 §5.2 의 error_description 문자 집합 밖의 글자(LF·NUL·U+00FF 위의
// 글자)나 짝 없는 서로게이트가 있을 때, 그 값을 되울리는 IdP 앞에서 SDK 오류가 그 값을 찍지 않는다.
//
// 수정 전 실측(2026-10-05, 6f23931): Nimbus `ErrorObject.parse` 가 error_description 에서 §5.2 밖의 글자를 지운 뒤에
// SDK 가 [maskSent] 로 보낸 값을 찾았으므로, 지워진 꼴이 그대로 메시지에 실렸다 — 「Token refresh failed: Bad refresh_token:
// HDRLEAK-rtLFNULWIDE-tail-0002 (rejected)」(introspect 의 토큰, Basic 시크릿도 같다). 짝 없는 서로게이트는 UTF-8 이 그 자리에
// '?' 를 실어 보내므로 IdP 는 '?' 꼴을 되울렸다 — 「… SURLEAK-rt-ab?cd-0004 …」. 공개 API 만 부른다(수정을 되돌린 소스에서도
// 컴파일된다). 네트워크는 루프백만.
private const val EV_OIDC = "/realms/r/protocol/openid-connect"

// RFC 6749 §5.2 — error·error_description 에 허용되는 글자(%x20-21 / %x23-5B / %x5D-7E).
private fun evLegal(c: Char): Boolean = c.code in 0x20..0x21 || c.code in 0x23..0x5b || c.code in 0x5d..0x7e

// 되울린 사본이 SDK 오류에 닿을 수 있는 꼴 — 그대로 · §5.2 밖의 글자를 지운 꼴 · UTF-8 이 '?' 로 바꾼 꼴과 그것을 지운 꼴.
private fun evForms(value: String): Set<String> {
    val wire = String(value.toByteArray(StandardCharsets.UTF_8), StandardCharsets.UTF_8)
    return setOf(value, value.filter(::evLegal), wire, wire.filter(::evLegal)).filter { it.length >= 8 }.toSet()
}

internal class AuthEchoedValueMaskingTest {
    private lateinit var server: HttpServer

    // 되울릴 것 — 폼 파라미터 이름, 또는 BASIC 이면 Basic 자격의 시크릿(서버가 디코딩한 꼴).
    @Volatile private var echo = "refresh_token"

    // 거짓이면 받은 그대로 되울린다 — 폼 디코딩을 하지 않는 IdP·프록시(본문 파라미터 값, Basic 은 base64 만 푼 비밀번호 칸).
    @Volatile private var formDecode = true

    // 마지막으로 되울린 값(서버가 본 꼴).
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

    // 받은 값을 error_description 에 되울리는 IdP — JSON 문자열로 이스케이프한다(LF·NUL 은 \n·\u0000, U+0100 은 UTF-8 그대로).
    private fun answer(ex: HttpExchange) {
        val form =
            ex.requestBody
                .readAllBytes()
                .decodeToString()
                .split("&")
                .filter { it.contains('=') }
                .associate { decode(it.substringBefore('=')) to received(it.substringAfter('=')) }
        val got =
            if (echo == "BASIC") {
                val credentials = ex.requestHeaders.getFirst("Authorization").removePrefix("Basic ")
                received(String(Base64.getDecoder().decode(credentials), StandardCharsets.UTF_8).substringAfter(':'))
            } else {
                form[echo].orEmpty()
            }
        echoed = got
        val body = """{"error":"invalid_grant","error_description":"Bad $echo: ${jsonEscape(got)} (rejected)"}""".toByteArray()
        ex.responseHeaders.add("Content-Type", "application/json")
        ex.sendResponseHeaders(400, body.size.toLong())
        ex.responseBody.use { it.write(body) }
    }

    private fun decode(s: String): String = URLDecoder.decode(s, StandardCharsets.UTF_8)

    private fun received(s: String): String = if (formDecode) decode(s) else s

    private fun jsonEscape(s: String): String =
        buildString {
            for (c in s) {
                when {
                    c == '"' -> append("\\\"")
                    c == '\\' -> append("\\\\")
                    c.code < 0x20 -> append("\\u%04x".format(c.code))
                    else -> append(c)
                }
            }
        }

    private fun auth(secret: String = "s3cr3t-0001"): AuthClient =
        AuthClient(
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = "r",
                clientId = "app",
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

    // 오류 하나를 로거가 찍는 두 경로(toString · stackTraceToString — 원인 사슬 포함)로 그려 보낸 값의 어느 꼴도 없는지 본다.
    // 사유 문구(되울린 앞뒤 산문)는 남아야 한다 — 가리기가 메시지를 통째로 지우는 쪽으로 「통과」하지 않게.
    private fun check(
        label: String,
        thrown: Throwable?,
        sent: String,
        wrong: MutableList<String>,
        table: MutableList<String>,
    ) {
        if (thrown !is KeycloakAuthException) {
            wrong += "$label: IdP 의 거절(KeycloakAuthException)이 아니다 — $thrown"
            return
        }
        val text = thrown.toString() + "\n" + thrown.stackTraceToString()
        table += "${label.padEnd(40)} → ${thrown.message}"
        for (form in evForms(sent)) {
            if (form in text) wrong += "$label: 오류가 보낸 값을 찍었다 — 「${form.map { if (evLegal(it)) it else '·' }.joinToString("")}」"
        }
        if (!thrown.message.orEmpty().contains("(rejected)")) wrong += "$label: 사유 문구를 잃었다 — ${thrown.message}"
    }

    @Test
    fun `an echoed value outside the error_description charset is not quoted`() =
        runTest {
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            val accessToken = "HDRLEAK-at\nLF\u0000NULĀWIDE-tail-0001"
            val refreshToken = "HDRLEAK-rt\nLF\u0000NULĀWIDE-tail-0002"
            val surrogate = "SURLEAK-rt-ab\uD800cd-0004"
            val code = "CODELEAK-été\nx-0005"

            echo = "refresh_token"
            check("refresh(LF·NUL·U+0100)", failureOf { auth().refresh(refreshToken) }, refreshToken, wrong, table)
            check("refresh(짝 없는 서로게이트)", failureOf { auth().refresh(surrogate) }, surrogate, wrong, table)
            echo = "token"
            check("introspect(LF·NUL·U+0100)", failureOf { auth().introspect(accessToken) }, accessToken, wrong, table)
            check("introspect(짝 없는 서로게이트)", failureOf { auth().introspect(surrogate) }, surrogate, wrong, table)
            echo = "code"
            check(
                "exchangeCode(code é·LF)",
                failureOf { auth().exchangeCode(code, "v".repeat(43), "http://localhost/cb") },
                code,
                wrong,
                table,
            )
            echo = "BASIC"
            val secret = "SECLEAK-s3crĀt\nNL-0003"
            check("clientCredentials(시크릿 U+0100·LF)", failureOf { auth(secret).clientCredentialsToken() }, secret, wrong, table)
            val surSecret = "SURLEAK-sec-ab\uD800cd-0006"
            check("clientCredentials(시크릿 서로게이트)", failureOf { auth(surSecret).clientCredentialsToken() }, surSecret, wrong, table)
            println("[AuthEchoedValueMaskingTest]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // 대조 — §5.2 안의 글자만 담은 값은 지금도 가려진다(`AuthMalformedResponseTest` e3·f6 과 같은 모양). 위 시험이 다른 이유로
    // 실패하지 않음을 보인다.
    @Test
    fun `an echoed value inside the charset was already masked`() =
        runTest {
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            echo = "refresh_token"
            val plain = "PLAINLEAK-rt+input/0007="
            check("refresh(§5.2 안)", failureOf { auth().refresh(plain) }, plain, wrong, table)
            println("[AuthEchoedValueMaskingTest 대조]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // check 에 더해, IdP 가 실제로 되울린 꼴(서버가 받은 그대로)도 오류에 없는지 본다. 그 꼴이 보낸 값과 같으면 이 시험은 폼
    // 인코딩된 꼴을 재지 못한 것이다 — 폼 인코딩이 바꾸는 글자를 넣은 값만 쓴다.
    private fun checkWire(
        label: String,
        thrown: Throwable?,
        sent: String,
        wrong: MutableList<String>,
        table: MutableList<String>,
    ) {
        val wire = echoed
        check(label, thrown, sent, wrong, table)
        if (wire.isEmpty() || wire == sent) wrong += "$label: 되울린 꼴이 폼 인코딩된 꼴이 아니다 — 「$wire」"
        val text = thrown?.let { it.toString() + "\n" + it.stackTraceToString() }.orEmpty()
        if (wire in text) wrong += "$label: 오류가 되울린 폼 인코딩 꼴을 찍었다 — 「$wire」"
    }

    // 폼 디코딩 없이 되울리는 IdP 앞 — SDK 는 grant 값을 본문에, 클라이언트 시크릿을 Basic 자격의 비밀번호 칸에
    // application/x-www-form-urlencoded 로 싣는다(RFC 6749 §2.3.1 · Nimbus `ClientSecretBasic` 이 URLEncoder 로 인코딩한다).
    // 수정 전 실측(2026-10-05, 검증 레그 — bdb5687 과 6f23931 이 같다): grant 값의 그 꼴은 가려졌지만(`sentSecrets` 가 입력값에만
    // 폼 인코딩된 꼴을 더했다) 시크릿은 「Client credentials failed: Bad BASIC: sec+ret%2F%2B%3D%7E0005 (rejected)」 로 찍혔다.
    @Test
    fun `an echoed value in its form-encoded wire form is not quoted`() =
        runTest {
            val wrong = mutableListOf<String>()
            val table = mutableListOf<String>()
            formDecode = false
            echo = "BASIC"
            val secrets =
                listOf(
                    "공백·/+=~" to "FORMLEAK sec/+=~0001",
                    "/+=" to "FORMLEAK-s3cr3t/with+plus=0002",
                    "é·공백" to "FORMLEAK-sé c-0003",
                    "짝 없는 서로게이트·공백" to "FORMLEAK-sur\uD800 x-0004",
                )
            for ((label, secret) in secrets) {
                checkWire("clientCredentials(시크릿 $label)", failureOf { auth(secret).clientCredentialsToken() }, secret, wrong, table)
            }
            // 시크릿은 기밀 클라이언트의 다른 레인에서도 Basic 으로 나간다 — 같은 꼴이 되울린다.
            val secret = "FORMLEAK sec/+=~é-0006"
            checkWire("refresh(시크릿 공백·/+=~·é)", failureOf { auth(secret).refresh("rt-0006") }, secret, wrong, table)
            checkWire("introspect(시크릿 공백·/+=~·é)", failureOf { auth(secret).introspect("at-0006") }, secret, wrong, table)
            checkWire(
                "exchangeCode(시크릿 공백·/+=~·é)",
                failureOf { auth(secret).exchangeCode("code-0006", "v".repeat(43), "http://localhost/cb") },
                secret,
                wrong,
                table,
            )
            val value = "FORMLEAK rt/+=~é-0005"
            echo = "refresh_token"
            checkWire("refresh(공백·/+=~·é)", failureOf { auth().refresh(value) }, value, wrong, table)
            echo = "token"
            checkWire("introspect(공백·/+=~·é)", failureOf { auth().introspect(value) }, value, wrong, table)
            echo = "code"
            checkWire(
                "exchangeCode(공백·/+=~·é)",
                failureOf { auth().exchangeCode(value, "v".repeat(43), "http://localhost/cb") },
                value,
                wrong,
                table,
            )
            println("[AuthEchoedValueMaskingTest 폼 인코딩된 꼴]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }
}
