package io.github.xzawed.keycloak.admin

import com.fasterxml.jackson.databind.node.JsonNodeFactory
import com.sun.net.httpserver.HttpServer
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import kotlinx.coroutines.runBlocking
import org.keycloak.representations.idm.ClientPolicyExecutorRepresentation
import org.keycloak.representations.idm.ClientProfileRepresentation
import org.keycloak.representations.idm.ClientProfilesRepresentation
import org.keycloak.representations.idm.GroupRepresentation
import org.keycloak.representations.idm.RealmRepresentation
import org.keycloak.representations.idm.UserProfileAttributeMetadata
import org.keycloak.representations.idm.UserProfileMetadata
import org.keycloak.representations.idm.UserRepresentation
import java.math.BigDecimal
import java.net.InetAddress
import java.net.InetSocketAddress
import java.time.Duration
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private const val AUB_REALM = "r"
private const val AUB_UNENCODABLE = "admin request failed: the request body could not be encoded as JSON"
private val AUB_TOKEN = """{"access_token":"good","token_type":"Bearer","expires_in":300}""".toByteArray()

/**
 * admin 쓰기 본문이 JSON 으로 그대로 실리지 못하면 요청 전에 [KeycloakTransportException] 이고 문구는 아홉 언어 공통이다(등록부
 * admin-unencodable-body-residuals, Java `AdminUnencodableBodyTest` 동형). admin-client 의 Jackson 은 자유 형식 칸(Map<String, Any> ·
 * JsonNode)의 NaN · ±Infinity 를 던지지 않고 **문자열** "NaN" · "Infinity" 로 써 호출자가 보내지 않은 값이 나갔다. 다섯 표현에 double ·
 * float 필드는 없고(javap) 수를 쥘 수 있는 칸은 자유 형식 칸이다 — 사용자 프로필 메타데이터의 annotations · validators(realm 의 users
 * 로도 닿는다)와 realm 의 client profile · policy(JsonNode). 쓸 수 없는 표현(순환)도 같은 계약이다. 짝 없는 서로게이트는 Jackson 이
 * `\uD800` 이스케이프로 그대로 싣는다 — 받는다(대조군).
 *
 * 서버는 JDK HttpServer 로 받은 토큰 요청 · admin 요청(메서드 · 경로 · 본문)을 적는다. admin 클라이언트는 토큰을 첫 요청에서 받으므로
 * 새 클라이언트의 거부된 쓰기는 요청이 0 이다.
 */
internal class AdminUnencodableBodyTest {
    private lateinit var server: HttpServer
    private val tokenRequests = CopyOnWriteArrayList<String>()

    // 받은 admin 요청 — 「메서드 경로 본문」.
    private val adminRequests = CopyOnWriteArrayList<String>()

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/") { ex ->
            val body = ex.requestBody.readAllBytes().decodeToString()
            val path = ex.requestURI.path
            if (path.endsWith("/protocol/openid-connect/token")) {
                tokenRequests += path
                ex.responseHeaders.add("Content-Type", "application/json")
                ex.sendResponseHeaders(200, AUB_TOKEN.size.toLong())
                ex.responseBody.write(AUB_TOKEN)
            } else {
                adminRequests += "${ex.requestMethod} $path $body"
                if (ex.requestMethod == "POST") {
                    ex.responseHeaders.add("Location", "http://127.0.0.1$path/new-id")
                    ex.sendResponseHeaders(201, -1)
                } else {
                    ex.sendResponseHeaders(204, -1)
                }
            }
            ex.close()
        }
        server.start()
    }

    @AfterTest
    fun stop() {
        server.stop(0)
    }

    private fun admin(): AdminClient =
        AdminClient(
            KeycloakConfig(
                serverUrl = "http://127.0.0.1:${server.address.port}",
                realm = AUB_REALM,
                clientId = "app",
                clientSecret = "s3cr3t".toCharArray(),
                connectTimeout = Duration.ofSeconds(5),
                readTimeout = Duration.ofSeconds(5),
            ),
        )

    // 사용자 프로필 메타데이터 하나 — annotations 와 validators 둘 다 자유 형식 칸이다.
    private fun userWith(
        annotations: Map<String, Any?>,
        validators: Map<String, Map<String, Any?>>,
    ): UserRepresentation =
        UserRepresentation().apply {
            username = "alice"
            userProfileMetadata =
                UserProfileMetadata(
                    listOf(UserProfileAttributeMetadata("a", "A", false, false, null, annotations, validators, false, null)),
                    listOf(),
                )
        }

    // realm 의 client profile 하나 — 실행기 설정은 JsonNode 다(setParsedClientProfiles 가 convertValue 로 JsonNode 를 만든다).
    private fun profilesWith(value: Any): ClientProfilesRepresentation {
        val configuration = JsonNodeFactory.instance.objectNode()
        if (value is Float) configuration.put("n", value) else configuration.put("n", value as Double)
        val executor =
            ClientPolicyExecutorRepresentation().apply {
                executorProviderId = "x"
                this.configuration = configuration
            }
        val profile =
            ClientProfileRepresentation().apply {
                name = "p"
                executors = listOf(executor)
            }
        return ClientProfilesRepresentation().apply { profiles = listOf(profile) }
    }

    private fun write(
        name: String,
        block: suspend (AdminClient) -> Unit,
    ): Pair<String, suspend (AdminClient) -> Unit> = name to block

    // 수를 쥐는 쓰기 다섯 — 자리가 서로 다르다(annotations · validators 안 · 목록 안 · realm 의 사용자 안 · JsonNode 안).
    private fun writes(value: Any): List<Pair<String, suspend (AdminClient) -> Unit>> =
        listOf(
            write("users.create annotations") { a -> a.users().create(userWith(mapOf("n" to value), mapOf())) },
            write("users.update validators") { a -> a.users().update("x", userWith(mapOf(), mapOf("length" to mapOf("max" to value)))) },
            write("realms.create users[].annotations list") { a ->
                a.realms().create(
                    RealmRepresentation().apply {
                        realm = "r2"
                        users = listOf(userWith(mapOf("n" to listOf(1, value)), mapOf()))
                    },
                )
            },
            write("realms.update users[].validators") { a ->
                a.realms().update(
                    "r2",
                    RealmRepresentation().apply { users = listOf(userWith(mapOf(), mapOf("length" to mapOf("min" to value)))) },
                )
            },
            write("realms.update clientProfiles JsonNode") { a ->
                a.realms().update("r2", RealmRepresentation().apply { parsedClientProfiles = profilesWith(value) })
            },
        )

    private fun outcome(write: suspend (AdminClient) -> Unit): Throwable? =
        try {
            admin().use { runBlocking { write(it) } }
            null
        } catch (t: Throwable) {
            t
        }

    @Test
    fun `a non-finite number is refused before any request`() {
        val wrong = mutableListOf<String>()
        for (value in listOf<Any>(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Float.NaN, Float.NEGATIVE_INFINITY)) {
            for ((name, write) in writes(value)) {
                tokenRequests.clear()
                adminRequests.clear()
                val thrown = outcome(write)
                val refused = thrown is KeycloakTransportException && thrown.message == AUB_UNENCODABLE
                if (!refused || adminRequests.isNotEmpty() || tokenRequests.isNotEmpty()) {
                    wrong += "$name $value → ${thrown?.let { "${it.javaClass.simpleName}: ${it.message}" } ?: "returned"} · " +
                        "token requests ${tokenRequests.size} · admin requests $adminRequests"
                }
            }
        }
        assertEquals(listOf(), wrong, wrong.joinToString("\n"))
    }

    /** 순환 — Jackson 이 쓸 수 없는 표현도 같은 계약이다(토큰 · admin 요청 0). */
    @Test
    fun `a body Jackson cannot write is refused before any request`() {
        val group = GroupRepresentation().apply { name = "g" }
        group.subGroups = listOf(group)
        val thrown = outcome { it.groups().create(group) }
        assertEquals(
            "${KeycloakTransportException::class.java.name}: $AUB_UNENCODABLE",
            thrown?.let { "${it.javaClass.name}: ${it.message}" },
        )
        assertEquals(listOf(), adminRequests)
        assertEquals(listOf(), tokenRequests)
    }

    /**
     * 대조군 — 그대로 실리는 값은 그대로 나간다: 유한한 수 · double 을 넘는 BigDecimal(JSON 수로 그대로 — 거부하지 않는다) · 짝 없는
     * 서로게이트(Jackson 이 `\uD800` 로 이스케이프한다).
     */
    @Test
    fun `what JSON carries faithfully goes out`() {
        val user = userWith(mapOf("n" to listOf(1.5, Double.MAX_VALUE, BigDecimal("1e400"))), mapOf())
        user.username = "x\ud800"
        admin().use { runBlocking { it.users().update("x", user) } }
        assertEquals(1, adminRequests.size, adminRequests.toString())
        val sent = adminRequests[0]
        assertTrue(sent.startsWith("PUT /admin/realms/r/users/x "), sent)
        assertTrue(sent.contains("\"username\":\"x\\uD800\""), sent)
        assertTrue(sent.contains("\"annotations\":{\"n\":[1.5,1.7976931348623157E308,1E+400]}"), sent)
    }
}
