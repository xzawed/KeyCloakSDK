package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakAdminException
import io.github.xzawed.keycloak.KeycloakConfig
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Timeout
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.EnumSource
import org.junit.jupiter.params.provider.MethodSource
import org.keycloak.representations.idm.ClientRepresentation
import org.keycloak.representations.idm.GroupRepresentation
import org.keycloak.representations.idm.RealmRepresentation
import org.keycloak.representations.idm.RoleRepresentation
import org.keycloak.representations.idm.UserRepresentation
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

// 파사드 호출에 Location 없는 3xx(300 · 302 · 399)가 그 호출의 성공 본문 모양인 JSON 을 싣고 와도 성공이 아니다 — 25 호출(다섯 자원 ×
// create · get · 목록 · update · delete, 통합 admin 표면 시험과 같은 25) 모두 admin 예외에 그 상태를 싣는다. 분류는 4xx 와 같다(상태가
// 403 · 404 · 409 가 아니면 KeycloakAdminException.Other)이고 본문도 4xx 처럼 keycloakError 로 싣는다. 반환값 · 빈 목록 · id 는 실패이고,
// 전송 · 해석 예외도 실패다(등록부 go-admin-3xx-read-as-success 의 부류 재스캔 · Java AdminRedirectStatusTest 와 같은 표).
//
// 수정 전(실측 2026-11-13, main 3ff48b96 · Windows · JDK 21.0.8 · 루프백): 세 상태 모두 25 중 13 만 통과했다. update 다섯 · delete 다섯 ·
// realms · roles 의 create 열둘은 Unit 으로 돌아왔다(Java 와 같은 열둘 — void 를 돌려주는 프록시의 추출기는 400 이상만 던지고, users ·
// clients 의 delete 는 Response 의 400 이상만 본다) — 서버는 칸마다 그 호출의 요청 하나를 받았다.
//
// 대조: 같은 표 · 같은 본문의 404 는 25 호출 모두 KeycloakAdminException.NotFound(404)다 — 표의 배선(호출마다 그 요청 하나가 서버에
// 닿는다)과 「4xx 가 받는 분류」를 같은 하네스로 보인다. 칸마다 서버가 받은 admin 요청이 그 호출의 메서드 · 경로 하나인지도 본다.
//
// 토큰 엔드포인트의 3xx 는 이 규칙 밖이다 — 토큰 레인이 가르고 그 상한이 본문을 끊는다(`a token endpoint redirect is left to the token lane`).
//
// 공개 API(생성자 · 파사드)와 로컬 루프백만 쓴다(Docker 불필요). 토큰 엔드포인트는 (그 갈래 밖에서) 쓸 수 있는 토큰을 낸다.
private const val ARS_REALM = "r"
private const val ARS_TOKEN_PATH = "/realms/$ARS_REALM/protocol/openid-connect/token"
private val ARS_TOKEN = """{"access_token":"good","token_type":"Bearer","expires_in":300}""".toByteArray(Charsets.UTF_8)
private const val ARS_USER = """{"id":"x","username":"alice"}"""
private const val ARS_CLIENT = """{"id":"x","clientId":"app"}"""
private const val ARS_REALM_REP = """{"id":"r","realm":"r"}"""
private const val ARS_ROLE = """{"id":"x","name":"role"}"""
private const val ARS_GROUP = """{"id":"x","name":"group"}"""
private const val ARS_USERS = "/admin/realms/$ARS_REALM/users"
private const val ARS_CLIENTS = "/admin/realms/$ARS_REALM/clients"
private const val ARS_REALMS = "/admin/realms"
private const val ARS_ROLES = "/admin/realms/$ARS_REALM/roles"
private const val ARS_GROUPS = "/admin/realms/$ARS_REALM/groups"

// 계약의 세 상태 — 300 · 302(Location 없음) · 399. 어느 것도 Location 을 싣지 않는다.
private val ARS_REDIRECTS = intArrayOf(300, 302, 399)

// 토큰 엔드포인트 3xx 갈래의 본문 길이 — 토큰 레인의 상한(1 MiB)을 한참 넘는다.
private const val ARS_HUGE = 64L shl 20

// 끊긴 교환에서 서버가 써도 되는 본문 — 상한 + 소켓 버퍼를 넉넉히 넘는 16 MiB(`AdminRejectedResponseCutTest` 와 같은 한도).
private const val ARS_WRITTEN_BOUND = 16L shl 20

private fun arsList(element: String): String = "[$element]"

private fun arsUser(): UserRepresentation = UserRepresentation().apply { username = "alice" }

private fun arsClient(): ClientRepresentation = ClientRepresentation().apply { clientId = "app" }

private fun arsRealm(): RealmRepresentation = RealmRepresentation().apply { realm = "r" }

private fun arsRole(): RoleRepresentation = RoleRepresentation().apply { name = "role" }

private fun arsGroup(): GroupRepresentation = GroupRepresentation().apply { name = "group" }

// 파사드 25 호출 — 서버가 받아야 할 「메서드 경로」(질의 뺌)와, 성공이었다면 그 호출이 받았을 모양의 JSON 본문.
internal enum class ArsOp(
    method: String,
    path: String,
    val body: String,
    val call: suspend (AdminClient) -> Any?,
) {
    USERS_CREATE("POST", ARS_USERS, ARS_USER, { it.users().create(arsUser()) }),
    USERS_GET("GET", "$ARS_USERS/x", ARS_USER, { it.users().get("x") }),
    USERS_SEARCH("GET", ARS_USERS, arsList(ARS_USER), { it.users().search("alice", 0, 10) }),
    USERS_UPDATE("PUT", "$ARS_USERS/x", ARS_USER, { it.users().update("x", arsUser()) }),
    USERS_DELETE("DELETE", "$ARS_USERS/x", ARS_USER, { it.users().delete("x") }),
    CLIENTS_CREATE("POST", ARS_CLIENTS, ARS_CLIENT, { it.clients().create(arsClient()) }),
    CLIENTS_GET("GET", "$ARS_CLIENTS/x", ARS_CLIENT, { it.clients().get("x") }),
    CLIENTS_FIND("GET", ARS_CLIENTS, arsList(ARS_CLIENT), { it.clients().findByClientId("app") }),
    CLIENTS_UPDATE("PUT", "$ARS_CLIENTS/x", ARS_CLIENT, { it.clients().update("x", arsClient()) }),
    CLIENTS_DELETE("DELETE", "$ARS_CLIENTS/x", ARS_CLIENT, { it.clients().delete("x") }),
    REALMS_CREATE("POST", ARS_REALMS, ARS_REALM_REP, { it.realms().create(arsRealm()) }),
    REALMS_GET("GET", "$ARS_REALMS/r", ARS_REALM_REP, { it.realms().get("r") }),
    REALMS_LIST("GET", ARS_REALMS, arsList(ARS_REALM_REP), { it.realms().list() }),
    REALMS_UPDATE("PUT", "$ARS_REALMS/r", ARS_REALM_REP, { it.realms().update("r", arsRealm()) }),
    REALMS_DELETE("DELETE", "$ARS_REALMS/r", ARS_REALM_REP, { it.realms().delete("r") }),
    ROLES_CREATE("POST", ARS_ROLES, ARS_ROLE, { it.roles().create(arsRole()) }),
    ROLES_GET("GET", "$ARS_ROLES/role", ARS_ROLE, { it.roles().get("role") }),
    ROLES_LIST("GET", ARS_ROLES, arsList(ARS_ROLE), { it.roles().list() }),
    ROLES_UPDATE("PUT", "$ARS_ROLES/role", ARS_ROLE, { it.roles().update("role", arsRole()) }),
    ROLES_DELETE("DELETE", "$ARS_ROLES/role", ARS_ROLE, { it.roles().delete("role") }),
    GROUPS_CREATE("POST", ARS_GROUPS, ARS_GROUP, { it.groups().create(arsGroup()) }),
    GROUPS_GET("GET", "$ARS_GROUPS/x", ARS_GROUP, { it.groups().get("x") }),
    GROUPS_LIST("GET", ARS_GROUPS, arsList(ARS_GROUP), { it.groups().list(0, 10) }),
    GROUPS_UPDATE("PUT", "$ARS_GROUPS/x", ARS_GROUP, { it.groups().update("x", arsGroup()) }),
    GROUPS_DELETE("DELETE", "$ARS_GROUPS/x", ARS_GROUP, { it.groups().delete("x") }),
    ;

    val request: String = "$method $path"
}

internal class AdminRedirectStatusTest {
    // 75 칸 — 칸마다 그 상태를 실은 admin 예외(분류는 「그 밖」 = Other)여야 하고, 서버는 그 호출의 요청 하나를 받았어야 한다.
    @ParameterizedTest(name = "{0} {1}")
    @MethodSource("cells")
    @Timeout(30)
    fun `a locationless redirect is an admin error carrying its status`(
        op: ArsOp,
        status: Int,
    ) {
        ArsRawServer(status, op.body).use { server ->
            val thrown = arsRun(server, op)
            val row = arsRow(op, status, thrown, server)
            println("[AdminRedirectStatusTest] $row")
            val e = assertIs<KeycloakAdminException.Other>(thrown, row)
            assertEquals(status, e.status, row)
            assertEquals(op.body, e.keycloakError, "본문은 4xx 처럼 keycloakError 로 — $row")
            assertEquals(listOf(op.request), server.adminRequests, row)
        }
    }

    // 대조 — 같은 표 · 같은 본문의 404: 25 호출 모두 KeycloakAdminException.NotFound(404)이고 그 호출의 요청 하나가 서버에 닿는다.
    @ParameterizedTest
    @EnumSource(ArsOp::class)
    @Timeout(30)
    fun `control - a not found is the NotFound leaf on every call`(op: ArsOp) {
        ArsRawServer(404, op.body).use { server ->
            val thrown = arsRun(server, op)
            val row = arsRow(op, 404, thrown, server)
            val e = assertIs<KeycloakAdminException.NotFound>(thrown, row)
            assertEquals(404, e.status, row)
            assertEquals(listOf(op.request), server.adminRequests, row)
        }
    }

    // 토큰 엔드포인트의 3xx 는 이 규칙의 것이 아니다 — 엔진은 토큰 응답 본문에 상한을 걸지 않으므로(그 레인의 상한은 TokenResponseGuard 가
    // 건다) 이 규칙이 그것을 버퍼에 담으면 끝까지 읽는다. 파사드 호출 안의 토큰 부여가 64 MiB 본문의 302 를 받으면 호출은 admin 예외가
    // 아니고(토큰 레인이 가른다) admin 요청은 나가지 않으며 서버는 ARS_WRITTEN_BOUND 를 넘어 쓰지 못한다. 규칙에서 토큰 엔드포인트를 빼는
    // 조건을 지우면 서버가 64 MiB 를 다 쓴다.
    @Test
    @Timeout(60)
    fun `a token endpoint redirect is left to the token lane`() {
        ArsRawServer(200, ARS_USER, 302, ARS_HUGE).use { server ->
            val thrown = arsRun(server, ArsOp.USERS_GET)
            val finished = server.tokenReplied.await(30, TimeUnit.SECONDS)
            val row =
                arsRow(ArsOp.USERS_GET, 302, thrown, server) + " · token endpoint wrote ${server.tokenWritten.get()} B" +
                    if (finished) "" else " (still writing)"
            println("[AdminRedirectStatusTest] $row")
            assertFalse(thrown is ArsReturned || thrown is KeycloakAdminException, row)
            assertEquals(emptyList(), server.adminRequests, row)
            assertTrue(finished && server.tokenWritten.get() <= ARS_WRITTEN_BOUND, "토큰 레인의 상한을 넘어 읽었다 — $row")
        }
    }

    companion object {
        @JvmStatic
        fun cells(): List<Arguments> = ArsOp.entries.flatMap { op -> ARS_REDIRECTS.map { Arguments.of(op, it) } }
    }
}

// 호출이 오류 없이 돌아왔다 — 그 값이 메시지다(칸의 기록과 단언 실패에 「returned …」로 보인다).
private class ArsReturned(
    result: Any?,
) : Throwable("returned $result", null, false, false)

// 호출 하나 — 던진 것을 돌려준다. 오류 없이 돌아오면 돌려준 값을 담은 표시를 던진 것 대신 돌려준다(단언이 그 값을 보인다).
private fun arsRun(
    server: ArsRawServer,
    op: ArsOp,
): Throwable =
    try {
        AdminClient(arsConfig(server.port)).use { admin -> ArsReturned(runBlocking { op.call(admin) }) }
    } catch (t: Throwable) {
        t
    }

private fun arsRow(
    op: ArsOp,
    status: Int,
    thrown: Throwable,
    server: ArsRawServer,
): String {
    val what =
        if (thrown is ArsReturned) {
            thrown.message
        } else {
            val carried = if (thrown is KeycloakAdminException) "(status ${thrown.status})" else ""
            "${thrown.javaClass.name}$carried: ${thrown.message}"
        }
    return "$op $status → $what · admin requests ${server.adminRequests}"
}

private fun arsConfig(port: Int): KeycloakConfig =
    KeycloakConfig(
        serverUrl = "http://127.0.0.1:$port",
        realm = ARS_REALM,
        clientId = "app",
        clientSecret = "s3cr3t".toCharArray(),
        connectTimeout = Duration.ofSeconds(5),
        readTimeout = Duration.ofSeconds(5),
    )

private fun arsLatin1(s: String): ByteArray = s.toByteArray(Charsets.ISO_8859_1)

private fun arsReason(status: Int): String =
    when (status) {
        300 -> "Multiple Choices"
        302 -> "Found"
        404 -> "Not Found"
        else -> "Unassigned"
    }

// 원시 HTTP/1.1 서버(연결 하나에 요청 여럿) — 토큰 엔드포인트는 쓸 수 있는 토큰을, /admin/ 아래는 고른 상태와 JSON 본문을(Location
// 없이) 내고 그 요청의 「메서드 경로」(질의 뺌)를 적는다. 그 밖은 빈 404 다. 토큰 엔드포인트의 상태가 200 이 아니면 그 상태와 tokenSize
// 바이트의 본문(토큰 뒤 공백)을 내고 쓴 바이트를 센다.
private class ArsRawServer(
    status: Int,
    body: String,
    private val tokenStatus: Int = 200,
    private val tokenSize: Long = 0,
) : AutoCloseable {
    private val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val adminReply: ByteArray
    val adminRequests: MutableList<String> = CopyOnWriteArrayList()
    val tokenWritten = AtomicLong()

    // 200 이 아닌 토큰 응답의 쓰기가 끝났다(성공 · 실패).
    val tokenReplied = CountDownLatch(1)

    init {
        val b = body.toByteArray(Charsets.UTF_8)
        adminReply =
            arsLatin1(
                "HTTP/1.1 $status ${arsReason(status)}\r\nContent-Type: application/json\r\nContent-Length: ${b.size}\r\n\r\n",
            ) + b
        Thread(::serve, "admin-3xx-server").apply { isDaemon = true }.start()
    }

    val port: Int get() = socket.localPort

    private fun serve() {
        while (!socket.isClosed) {
            val s =
                try {
                    socket.accept()
                } catch (closed: IOException) {
                    return
                }
            Thread({ exchanges(s) }, "admin-3xx-connection").apply { isDaemon = true }.start()
        }
    }

    private fun exchanges(s: Socket) {
        try {
            s.use {
                s.soTimeout = 20_000
                val input = BufferedInputStream(s.getInputStream())
                val out = s.getOutputStream()
                var request = request(input)
                while (request != null) {
                    answer(request, out)
                    request = request(input)
                }
            }
        } catch (clientLeft: IOException) {
            // 클라이언트가 끊었다 — 읽지 않은 본문의 연결은 SDK 가 끊는다
        }
    }

    private fun answer(
        request: String,
        out: OutputStream,
    ) {
        val path = request.substring(request.indexOf(' ') + 1)
        when {
            path == ARS_TOKEN_PATH && tokenStatus != 200 -> {
                try {
                    out.write(
                        arsLatin1(
                            "HTTP/1.1 $tokenStatus ${arsReason(tokenStatus)}\r\nContent-Type: application/json\r\n" +
                                "Content-Length: $tokenSize\r\n\r\n",
                        ),
                    )
                    out.write(ARS_TOKEN)
                    tokenWritten.addAndGet(ARS_TOKEN.size.toLong())
                    val slab = ByteArray(64 * 1024) { ' '.code.toByte() }
                    var left = tokenSize - ARS_TOKEN.size
                    while (left > 0) {
                        val k = minOf(left, slab.size.toLong()).toInt()
                        out.write(slab, 0, k)
                        tokenWritten.addAndGet(k.toLong())
                        left -= k
                    }
                } finally {
                    tokenReplied.countDown()
                }
            }
            path == ARS_TOKEN_PATH -> {
                out.write(arsLatin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${ARS_TOKEN.size}\r\n\r\n"))
                out.write(ARS_TOKEN)
            }
            path.startsWith("/admin/") -> {
                adminRequests.add(request)
                out.write(adminReply)
            }
            else -> out.write(arsLatin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))
        }
        out.flush()
    }

    // 요청 하나(머리와 본문 — Content-Length 또는 chunked)를 읽고 「메서드 경로」(질의 뺌)를 돌려준다 — 연결이 끝났으면 null.
    private fun request(input: InputStream): String? {
        val head = ByteArrayOutputStream()
        var last4 = 0
        var b = input.read()
        while (b != -1) {
            head.write(b)
            last4 = (last4 shl 8) or b
            if (last4 == 0x0d0a0d0a) {
                val lines = head.toString(Charsets.ISO_8859_1).split("\r\n")
                for (line in lines) {
                    if (line.regionMatches(0, "Content-Length:", 0, 15, ignoreCase = true)) {
                        input.readNBytes(line.substring(15).trim().toInt())
                    } else if (line.regionMatches(0, "Transfer-Encoding:", 0, 18, ignoreCase = true) &&
                        line.substring(18).trim().equals("chunked", ignoreCase = true)
                    ) {
                        skipChunked(input)
                    }
                }
                val first = lines[0].split(" ")
                return first[0] + " " + first[1].substringBefore('?')
            }
            b = input.read()
        }
        return null
    }

    private fun skipChunked(input: InputStream) {
        var size = chunkSize(input)
        while (size > 0) {
            input.readNBytes(size + 2) // 청크와 그 뒤의 CRLF
            size = chunkSize(input)
        }
        var trailer = line(input)
        while (trailer != null && trailer.isNotEmpty()) {
            trailer = line(input) // 트레일러 — 빈 줄까지
        }
    }

    private fun chunkSize(input: InputStream): Int {
        val line = line(input) ?: return 0
        return line.substringBefore(';').trim().toInt(16)
    }

    private fun line(input: InputStream): String? {
        val buf = ByteArrayOutputStream()
        var b = input.read()
        while (b != -1) {
            if (b == '\n'.code) return buf.toString(Charsets.ISO_8859_1).trimEnd()
            buf.write(b)
            b = input.read()
        }
        return null
    }

    override fun close() {
        socket.close()
    }
}
