package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import jakarta.ws.rs.ProcessingException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.Base64
import java.util.Locale
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue

// 아홉 언어 공통 bearer 규칙의 정본 표(Java `BearerTokenGrammarTest` 동형 — 등록부 bearer-token-grammar-divergent, 2026-10-29 판정).
// admin 요청의 `Authorization: Bearer <토큰>` 은 토큰의 앞뒤에서 SP·HTAB·CR·LF **만** 떼고 남은 것이 비어 있지 않은 RFC 6750
// b64token(`[A-Za-z0-9\-._~+/]+=*`, ASCII)일 때만 나간다. 아니면 요청을 하나도 보내지 않고 그 레인의 기존 오류다.
//
// ⚠️ Kotlin 은 규칙의 **받는 자리 갈래**다 — admin 요청의 헤더는 keycloak-admin-client 의 BearerAuthFilter 가
// TokenManager.getAccessTokenString()(토큰 응답을 Jackson 이 결합한 값)으로 직접 단다. SDK 가 토큰을 만나는 곳은 결합 앞의 토큰 응답
// 바이트(TokenResponseGuard)뿐이고, TokenManager 에는 토큰을 넣는 setter 가 없다(소비자가 토큰을 주입할 길이 없다 — 주 생성자는
// internal). 그래서 다듬을 필요가 있는 토큰(lf·crlf·lead-tab)은 받을 때 거부한다 — 표의 그 세 행이 REJECT 다.
//
// 표는 세 길로 돈다: (a) 파사드 users().get · (b) 탈출구 raw() — 같은 BearerAuthFilter 를 지난다 · (c) 받는 자리 — 각 길의 두 번째
// 호출이 거부한 토큰을 캐시하지 않았음을(토큰 엔드포인트가 다시 불린다), 보낸 토큰은 캐시했음을 보이고, TokenManager 의 갱신
// (refresh_token 그랜트)이 받은 토큰도 같은 판정을 받는다. 서버는 받은 Authorization 바이트를 그대로 남기는 날 소켓이다 — com.sun
// HttpServer 는 값을 다듬는다(HTAB 을 공백으로 읽는다).
private const val BTG_REALM = "r"
private const val BTG_TOKEN_PATH = "/realms/$BTG_REALM/protocol/openid-connect/token"
private const val BTG_LOGOUT_PATH = "/realms/$BTG_REALM/protocol/openid-connect/logout"
private const val BTG_USER_PATH = "/admin/realms/$BTG_REALM/users/x"
private const val BTG_USER = """{"id":"x","username":"alice"}"""

// 갱신 길의 첫 응답 — expires_in 1 < TokenManager 최소 유효기간(30s) 이라 다음 호출이 refresh_token 으로 갱신한다.
private const val BTG_REFRESHABLE =
    """{"access_token":"AT-1","token_type":"Bearer","expires_in":1,"refresh_token":"RT-1","refresh_expires_in":300}"""

// 행의 기대 — 그대로 보낸다 · 다듬어 보낸다(Kotlin 은 받는 자리 갈래라 거부) · 거부한다.
private enum class BtgWant { AS_IS, TRIMMED, REJECT }

// 정본 표의 한 행 — marker 는 거부 오류의 메시지가 싣지 말아야 할 그 행의 글자(없으면 null).
private class BtgRow(
    val id: String,
    val token: String,
    val want: BtgWant,
    val marker: String?,
)

// 진짜 세 조각 JWS(HS256) — 시험마다 새 키로 서명한다(소스에 키를 두지 않는다).
private fun btgJws(): String {
    val b64 = Base64.getUrlEncoder().withoutPadding()
    val head = b64.encodeToString("""{"alg":"HS256","typ":"JWT"}""".toByteArray())
    val claims = b64.encodeToString("""{"sub":"bearer-grammar","iat":1767225600}""".toByteArray())
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(KeyGenerator.getInstance("HmacSHA256").generateKey())
    val signature = b64.encodeToString(mac.doFinal("$head.$claims".toByteArray(Charsets.US_ASCII)))
    return "$head.$claims.$signature"
}

// 정본 표(스펙의 스무 행) + UTF-16 문자열 언어의 추가 행(짝 없는 서로게이트). 글자는 이스케이프로 적는다.
private fun btgRows(): List<BtgRow> =
    listOf(
        BtgRow("plain", "abc.DEF-ghi_jkl~mno+pqr/stu", BtgWant.AS_IS, null),
        BtgRow("pad", "abc==", BtgWant.AS_IS, null),
        BtgRow("jwt", btgJws(), BtgWant.AS_IS, null),
        BtgRow("lf", "abc\n", BtgWant.TRIMMED, "abc"),
        BtgRow("crlf", "abc\r\n", BtgWant.TRIMMED, "abc"),
        BtgRow("lead-tab", " \tabc\t ", BtgWant.TRIMMED, "abc"),
        BtgRow("inner-sp", "a bc", BtgWant.REJECT, "bc"),
        BtgRow("inner-tab", "a\tbc", BtgWant.REJECT, "bc"),
        BtgRow("inner-crlf", "a\r\nX-Evil: 1", BtgWant.REJECT, "X-Evil"),
        BtgRow("mid-pad", "a=bc", BtgWant.REJECT, "=bc"),
        BtgRow("empty", "", BtgWant.REJECT, null),
        BtgRow("blank", " \t\r\n", BtgWant.REJECT, null),
        BtgRow("latin1", "abcé", BtgWant.REJECT, "abc"),
        BtgRow("above-ff", "abcĀ", BtgWant.REJECT, "abc"),
        BtgRow("c1", "abc\u0085", BtgWant.REJECT, "abc"),
        BtgRow("nul", "abc\u0000", BtgWant.REJECT, "abc"),
        BtgRow("del", "abc\u007f", BtgWant.REJECT, "abc"),
        BtgRow("nbsp", "abc" + Char(0x00A0), BtgWant.REJECT, "abc"),
        BtgRow("ideographic", Char(0x3000) + "abc", BtgWant.REJECT, "abc"),
        BtgRow("vt", "abc\u000b", BtgWant.REJECT, "abc"),
        BtgRow("lone-surrogate", "abc\ud800", BtgWant.REJECT, "abc"),
    )

// 토큰 응답 — 문자열은 ASCII 밖·제어 문자·따옴표·역슬래시를 \uXXXX 로 싣는다(짝 없는 서로게이트도 그대로 결합된다).
private fun btgTokenBody(token: String): String = "{\"access_token\":${btgJson(token)},\"token_type\":\"Bearer\",\"expires_in\":300}"

private fun btgJson(s: String): String =
    buildString {
        append('"')
        for (c in s) {
            if (c < ' ' || c > '~' || c == '"' || c == '\\') append("\\u%04x".format(c.code)) else append(c)
        }
        append('"')
    }

// 표에 찍을 수 있게 — 제어 문자·DEL·ASCII 밖은 \uXXXX 로.
private fun btgPrintable(s: String): String =
    buildString {
        for (c in s) if (c < ' ' || c > '~') append("\\u%04X".format(c.code)) else append(c)
    }

// 오류 사슬(원인·suppressed)의 메시지 어디에 marker 가 있는가.
private fun btgQuotes(
    t: Throwable,
    marker: String,
): Boolean {
    val todo = mutableListOf(t)
    var i = 0
    while (i < todo.size && i < 64) {
        val c = todo[i++]
        if (marker in c.message.toString()) return true
        c.cause?.let { todo += it }
        todo += c.suppressed
    }
    return false
}

internal class BearerTokenGrammarTest {
    private lateinit var wire: BtgWire

    @BeforeTest
    fun start() {
        wire = BtgWire()
    }

    @AfterTest
    fun stop() {
        wire.close()
    }

    private fun admin(): AdminClient =
        AdminClient(
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${wire.port}",
                realm = BTG_REALM,
                clientId = "app",
                clientSecret = "s3cr3t".toCharArray(),
                connectTimeout = Duration.ofSeconds(5),
                readTimeout = Duration.ofSeconds(5),
            ),
        )

    @Test
    fun `the canonical table through the facade, raw and both grants`() =
        runTest {
            val table = mutableListOf<String>()
            val wrong = mutableListOf<String>()
            for (row in btgRows()) {
                // Kotlin 은 받는 자리 갈래다 — 다듬을 필요가 있는 토큰은 받을 때 거부한다(파일 머리 주석).
                val sent = row.want == BtgWant.AS_IS
                val header = "Bearer ${row.token}"
                val twoGrants = listOf("client_credentials", "client_credentials")
                // (a) 파사드 — 두 번 부른다: 보낸 토큰은 캐시되고(그랜트 1) 거부한 토큰은 캐시되지 않는다(그랜트 2).
                wire.reset(btgTokenBody(row.token))
                val facade = twice { admin -> admin.users().get("x") }
                table += line(row, "facade", facade)
                judge(row, "facade", facade, sent, wrong) { it is KeycloakTransportException && it.message == "Admin request failed" }
                expect(row, "facade", wire.admin(), if (sent) listOf(header, header) else listOf(), wrong)
                expect(row, "facade 그랜트", wire.grants(), if (sent) listOf("client_credentials") else twoGrants, wrong)
                // (b) raw() — 같은 BearerAuthFilter 를 지난다. 거부는 하위 라이브러리의 ProcessingException 그대로다(§4(b) 탈출구).
                wire.reset(btgTokenBody(row.token))
                val raw =
                    twice { admin ->
                        admin
                            .raw()
                            .realm(BTG_REALM)
                            .users()
                            .get("x")
                            .toRepresentation()
                    }
                table += line(row, "raw", raw)
                judge(row, "raw", raw, sent, wrong) { it is ProcessingException }
                expect(row, "raw", wire.admin(), if (sent) listOf(header, header) else listOf(), wrong)
                expect(row, "raw 그랜트", wire.grants(), if (sent) listOf("client_credentials") else twoGrants, wrong)
                // (c) 갱신 그랜트 — 첫 호출은 AT-1 로 나가고, 두 번째 호출의 갱신이 그 행의 토큰을 받는다.
                wire.reset(BTG_REFRESHABLE, btgTokenBody(row.token))
                val refresh = twice { admin -> admin.users().get("x") }
                table += line(row, "refresh", refresh)
                if (refresh[0] != null) wrong += "${row.id} refresh: 첫 호출(AT-1)은 성공해야 한다 — ${refresh[0]}"
                judge(row, "refresh", refresh.subList(1, 2), sent, wrong) {
                    it is KeycloakTransportException && it.message == "Admin request failed"
                }
                expect(row, "refresh", wire.admin(), if (sent) listOf("Bearer AT-1", header) else listOf("Bearer AT-1"), wrong)
                expect(row, "refresh 그랜트", wire.grants(), listOf("client_credentials", "refresh_token"), wrong)
            }
            println("[BearerTokenGrammarTest]\n  " + table.joinToString("\n  "))
            assertTrue(wrong.isEmpty(), "${wrong.size} 건:\n" + wrong.joinToString("\n"))
        }

    // admin 하나로 같은 호출을 두 번 낸다 — 결과(성공이면 null, 실패면 그 예외)를 차례로(취소는 그대로 던진다).
    private suspend fun twice(call: suspend (AdminClient) -> Unit): List<Throwable?> =
        admin().use { admin ->
            List(2) {
                try {
                    call(admin)
                    null
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    e
                }
            }
        }

    // 보낸 행이면 실패가 없어야 하고, 거부 행이면 기존 오류이고 그 행의 글자를 메시지 사슬 어디에도 싣지 않는다.
    private fun judge(
        row: BtgRow,
        route: String,
        outcomes: List<Throwable?>,
        sent: Boolean,
        wrong: MutableList<String>,
        existing: (Throwable) -> Boolean,
    ) {
        for (t in outcomes) {
            when {
                sent -> if (t != null) wrong += "${row.id} $route: 보내야 한다 — $t"
                t == null || !existing(t) -> wrong += "${row.id} $route: 기존 오류가 아니다 — ${t?.javaClass?.name ?: "성공"}"
                row.marker != null && btgQuotes(t, row.marker) -> wrong += "${row.id} $route: 오류 메시지가 토큰(${row.marker})을 실었다"
            }
        }
    }

    private fun expect(
        row: BtgRow,
        what: String,
        got: List<String?>,
        want: List<String>,
        wrong: MutableList<String>,
    ) {
        if (got != want) wrong += "${row.id} $what: ${btgPrintable(got.toString())} — 기대 ${btgPrintable(want.toString())}"
    }

    private fun line(
        row: BtgRow,
        route: String,
        outcomes: List<Throwable?>,
    ): String {
        val shown = outcomes.map { it?.javaClass?.simpleName ?: "성공" }
        return "%-15s %-8s → %s · grants %s · admin %s".format(row.id, route, shown, wire.grants(), btgPrintable(wire.admin().toString()))
    }
}

// 받은 바이트를 그대로 남기는 가짜 Keycloak — 토큰 엔드포인트(차례로 낼 본문, 마지막 것은 계속) · admin GET(받은 Authorization 값의
// 바이트를 남긴다 — 콜론 뒤 공백 하나만 뗀다) · logout(204). 응답마다 연결을 닫는다.
private class BtgWire : AutoCloseable {
    private val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val lock = Any()
    private val replies = ArrayDeque<String>()
    private val grants = mutableListOf<String>()
    private val admin = mutableListOf<String?>()

    val port: Int get() = socket.localPort

    init {
        thread(isDaemon = true, name = "bearer-grammar-wire") { serve() }
    }

    fun reset(vararg tokenBodies: String) =
        synchronized(lock) {
            replies.clear()
            replies.addAll(tokenBodies)
            grants.clear()
            admin.clear()
        }

    fun grants(): List<String> = synchronized(lock) { grants.toList() }

    // admin 요청이 실은 Authorization 값 — 받은 바이트를 ISO-8859-1 로 한 글자씩 옮긴 것(바이트 그대로).
    fun admin(): List<String?> = synchronized(lock) { admin.toList() }

    private fun serve() {
        while (!socket.isClosed) {
            val s =
                try {
                    socket.accept()
                } catch (closed: IOException) {
                    return
                }
            thread(isDaemon = true, name = "bearer-grammar-exchange") { answer(s) }
        }
    }

    private fun answer(s: Socket) {
        try {
            s.use {
                s.soTimeout = 10_000
                val input = BufferedInputStream(s.getInputStream())
                var path: String? = null
                var authorization: String? = null
                var length = 0
                var line = crlfLine(input)
                while (!line.isNullOrEmpty()) {
                    if (path == null) {
                        path = line.split(" ").getOrElse(1) { "" }
                    } else {
                        val colon = line.indexOf(':')
                        if (colon > 0) {
                            val name = line.substring(0, colon).lowercase(Locale.ROOT)
                            val value = line.substring(colon + 1)
                            if (name == "content-length") length = value.trim().toInt()
                            if (name == "authorization") authorization = value.removePrefix(" ")
                        }
                    }
                    line = crlfLine(input)
                }
                if (path == null) return
                val body = String(input.readNBytes(length), Charsets.ISO_8859_1)
                val out = s.getOutputStream()
                when (path) {
                    BTG_TOKEN_PATH -> {
                        val reply =
                            synchronized(lock) {
                                grants += grantType(body)
                                if (replies.size > 1) replies.removeFirst() else replies.first()
                            }
                        respond(out, "200 OK", reply)
                    }
                    BTG_USER_PATH -> {
                        synchronized(lock) { admin += authorization }
                        respond(out, "200 OK", BTG_USER)
                    }
                    BTG_LOGOUT_PATH -> respond(out, "204 No Content", null)
                    else -> respond(out, "404 Not Found", """{"error":"not found"}""")
                }
            }
        } catch (clientWentAway: IOException) {
            // 클라이언트가 연결을 끊었다
        }
    }

    private fun grantType(form: String): String =
        form.split("&").firstOrNull { it.startsWith("grant_type=") }?.removePrefix("grant_type=") ?: "?"

    private fun respond(
        out: OutputStream,
        status: String,
        json: String?,
    ) {
        val body = json?.toByteArray() ?: ByteArray(0)
        val type = if (json == null) "" else "Content-Type: application/json\r\nContent-Length: ${body.size}\r\n"
        out.write("HTTP/1.1 $status\r\n${type}Connection: close\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
        out.write(body)
        out.flush()
    }

    // CRLF 로 끝나는 한 줄(줄 끝 제외) — 바이트를 ISO-8859-1 로 옮긴다. 홀로 선 CR·LF 는 줄의 일부로 남긴다. 끝이면 null.
    private fun crlfLine(input: InputStream): String? {
        val line = ByteArrayOutputStream()
        var prev = -1
        var c = input.read()
        while (c >= 0) {
            if (prev == '\r'.code && c == '\n'.code) {
                val bytes = line.toByteArray()
                return String(bytes, 0, bytes.size - 1, Charsets.ISO_8859_1)
            }
            line.write(c)
            prev = c
            c = input.read()
        }
        return if (line.size() == 0) null else line.toString(Charsets.ISO_8859_1)
    }

    override fun close() = socket.close()
}
