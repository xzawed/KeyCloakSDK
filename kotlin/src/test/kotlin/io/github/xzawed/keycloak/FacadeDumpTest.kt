package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.ResponseDefinitionBuilder
import com.github.tomakehurst.wiremock.client.WireMock.aResponse
import com.github.tomakehurst.wiremock.client.WireMock.containing
import com.github.tomakehurst.wiremock.client.WireMock.equalTo
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
import kotlinx.coroutines.test.runTest
import org.keycloak.representations.idm.CredentialRepresentation
import org.keycloak.representations.idm.UserRepresentation
import java.lang.reflect.Modifier
import java.lang.reflect.Proxy
import java.net.ServerSocket
import java.net.URL
import java.nio.file.Files
import java.nio.file.Paths
import java.time.Duration
import java.util.Base64
import java.util.Collections
import java.util.Date
import java.util.IdentityHashMap
import java.util.Optional
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

// 바닥 계약(기본 문자열 표현이 비밀을 찍지 않는다)을 **손으로 고른 값 타입이 아니라 도달 가능한 객체 전부**에
// 건다. `TokensTest`·`ConfigTest` 는 값 타입의 toString 을 하나씩 재는데, 자매 Go·PHP·.NET 에서는 그 밖의
// **파사드**가 새고 있었다(#592·#593·#594). Go `facade_dump_test.go`·PHP `FacadeDumpTest` 와 같은 모양이다.
//
// ⚠️ **새 자리를 스스로 찾는 것이 요점이다**(등록부 `guard-detection-surface-hand-narrowed`). 검사 대상은
// (1) 공개 API 로 만든 뿌리에서 리플렉션으로 **닿는 이 SDK 의 객체 전부**(private 필드, 하위 라이브러리 객체를
// 거쳐야 닿는 것까지)이고, (2) 컴파일된 main 클래스 디렉터리를 훑어 얻은 **선언 타입 전수**가 그 걷기에
// 걸렸는지 대조한다. 선언은 Kotlin 메타데이터 kind=CLASS 로 가른다 — 람다·코루틴 continuation(kind 3)과
// 파일 파사드(kind 2)는 소스의 타입 선언이 아니다. 인스턴스 상태가 없는 타입(인터페이스·companion)은 규칙으로
// 빠지고, 그 밖의 면제는 이유와 함께 [DUMP_EXEMPT] 에 적는다.
//
// 바닥 경로: `toString()` · 문자열 템플릿 `"$obj"`(data class 는 생성자 프로퍼티를 찍는다) · 예외는
// `stackTraceToString()` 까지(로거가 예외를 찍는 기본 경로 — 원인 사슬의 메시지가 실린다).
//
// ⚠️ 하네스 위생(PHP 의 교훈): 테스트 소스에서 온 객체(공급자에 넘긴 fetch 람다 등)는 걷지 않는다 — 그 안으로
// 들어가면 하네스가 쥔 것이 SDK 가 쥔 것처럼 도달로 잡힌다. 카나리아는 인스턴스가 아니라 파일 수준 상수와
// 지역값에 두고, 뿌리를 만드는 함수도 멤버가 아니라 파일 수준이라 람다가 테스트 인스턴스를 붙잡지 않는다.
//
// ⚠️ 한계: 카나리아는 뿌리를 만드는 호출이 흘려 넣은 비밀뿐이다. admin 에는 소비자 주입 TokenProvider 경로가
// 없다(admin 이 토큰을 자체 소유 — 루트 CLAUDE.md §4) — 기본 경로 하나만 잰다. 정적 필드는 걷지 않는다.
// JDK 모듈의 보관 자리는 공개 API 로 여는 것만 열린다(Map·Collection·배열·Throwable 원인·AtomicReference·Optional·
// 동적 프록시 핸들러) — ThreadLocal·Reference·Future 에만 매달린 SDK 객체는 못 본다. 프록시 핸들러를 열자 방문이
// 4887 → 8320 으로 늘었다(admin-client 리소스가 JDK 프록시다 — 독립 레그 Grok 의 지적을 실측으로 확인).

private const val DUMP_PKG = "io.github.xzawed.keycloak."
private const val DUMP_OIDC = "/realms/r/protocol/openid-connect"
private const val DUMP_SECRET = "CANARY-DUMP-CLIENT-SECRET"
private const val DUMP_ACCESS = "CANARY-DUMP-ACCESS-TOKEN"
private const val DUMP_REFRESH = "CANARY-DUMP-REFRESH-TOKEN"
private const val DUMP_GARBAGE = "CANARY-DUMP-GARBAGE-TOKEN"
private const val DUMP_PASSWORD = "CANARY-DUMP-ADMIN-PASSWORD"

// 멈춤 규칙(ClassLoader·Thread 에서 멈추고 JDK 모듈은 공개 API 로만 들어간다)이 새면 그래프 전체를 헤맨다.
private const val DUMP_MAX_VISITS = 1_000_000

// `kotlin.Metadata.kind` — 1 = 소스에 선언된 class/object/interface. 2 = 파일 파사드, 3 = 합성(람다·continuation).
private const val DUMP_KIND_CLASS = 1

/** 걷기에 안 닿아도 되는 선언 타입(패키지 뒤 이름)과 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다. */
private val DUMP_EXEMPT: Map<String, String> = emptyMap()

/**
 * 알려진 누출 — `"뿌리|카나리아"` → 사유. SDK 를 여기서 고치지 않는다: 새 누출은 `UNTRIAGED — reported` 로
 * 적고 보고한다. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
 */
private val DUMP_KNOWN_LEAKS: Map<String, String> = emptyMap()

internal class FacadeDumpTest {
    @Test
    fun `reachable objects do not render secrets on the floor paths`() =
        runTest(timeout = 120.seconds) {
            val server = WireMockServer(wireMockConfig().dynamicPort())
            server.start()
            val closing = mutableListOf<AutoCloseable>()
            try {
                val (roots, canaries) = dumpRoots(server, closing)
                val own = sourceOf(KeycloakConfig::class.java)
                val walker = DumpWalker(canaries, own.toString(), sourceOf(FacadeDumpTest::class.java).toString())
                roots.forEach { (name, obj) -> walker.walk(name, obj) }
                assertTrue(walker.unmeasured.isEmpty(), "걷기가 이 자리를 못 잰다:\n" + walker.unmeasured.joinToString("\n"))

                val unknown = walker.leaks.filterKeys { it !in DUMP_KNOWN_LEAKS }
                assertTrue(unknown.isEmpty(), "기본 표현이 비밀을 찍는다:\n" + unknown.values.flatten().joinToString("\n"))
                val stale = DUMP_KNOWN_LEAKS.keys - walker.leaks.keys
                assertTrue(stale.isEmpty(), "알려진 누출이 더 안 난다 — 고쳐졌으면 DUMP_KNOWN_LEAKS 에서 지워라: $stale")

                val declared = declaredTypes(own, KeycloakConfig::class.java.classLoader)
                assertTrue(declared.size >= 20, "main 클래스에서 선언을 거의 못 찾았다(${declared.size}) — 파생이 공허하다")
                val problems = reconcile(declared, walker.reached)
                assertTrue(problems.isEmpty(), problems.joinToString("\n"))
                val byRule = declared.filter { it.name !in walker.reached && !holdsInstanceState(it) }
                println(
                    "FacadeDumpTest: 뿌리 ${roots.size} · 방문 ${walker.visited} · " +
                        "도달한 선언 타입 ${declared.count { it.name in walker.reached }}/${declared.size} · " +
                        "상태 없음 규칙으로 빠짐 ${byRule.map { it.name.removePrefix(DUMP_PKG) }} · " +
                        "들어가지 않은 하네스 객체 ${walker.harnessSkipped}",
                )
            } finally {
                closing.forEach { it.close() }
                server.stop()
            }
        }
}

private data class DumpRoots(
    val roots: List<Pair<String, Any>>,
    val canaries: Map<String, String>,
)

private fun sourceOf(cls: Class<*>): URL = checkNotNull(cls.protectionDomain?.codeSource?.location) { "$cls 의 코드 출처가 없다" }

private fun json(
    status: Int,
    body: String,
): ResponseDefinitionBuilder = aResponse().withStatus(status).withHeader("Content-Type", "application/json").withBody(body)

private fun signed(
    key: RSAKey,
    issuer: String,
    extra: Map<String, Any> = emptyMap(),
): String {
    val claims =
        JWTClaimsSet
            .Builder()
            .issuer(issuer)
            .audience("c")
            .subject("u1")
            .issueTime(Date())
            .expirationTime(Date(System.currentTimeMillis() + 60_000))
    extra.forEach { (k, v) -> claims.claim(k, v) }
    val jwt = SignedJWT(JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.keyID).build(), claims.build())
    jwt.sign(RSASSASigner(key))
    return jwt.serialize()
}

// 공개 API 로 뿌리를 만들고, 그 과정이 흘려 넣은 비밀 전부를 카나리아로 돌려준다. 파일 수준 함수다 — 멤버로
// 두면 안의 람다가 테스트 인스턴스를 붙잡는다.
private suspend fun dumpRoots(
    server: WireMockServer,
    closing: MutableList<AutoCloseable>,
): DumpRoots {
    val key = RSAKeyGenerator(2048).keyID("k1").generate()
    val issuer = "${server.baseUrl()}/realms/r"
    val config = KeycloakConfig(server.baseUrl(), "r", "c", DUMP_SECRET.toCharArray())
    val kc = KeycloakClient.create(config).also { closing += it }

    // 인가 요청이 먼저다 — id_token 이 그 nonce 를 실어야 exchangeCode 의 강화 검증을 통과한다.
    val ar = kc.auth.createAuthorizationRequest("https://app/cb")
    val idToken = signed(key, issuer, mapOf("nonce" to ar.nonce))
    val rawJwt = signed(key, issuer)
    val basic = Base64.getEncoder().encodeToString("c:$DUMP_SECRET".toByteArray())

    // 가짜 IdP — 경로로 응답을 고른다(호출 순서가 바뀌어도 안 깨진다). admin 의 내장 TokenManager 도 같은
    // 토큰 엔드포인트에서 카나리아 액세스 토큰을 받아 캐시한다.
    server.stubFor(
        post(urlEqualTo("$DUMP_OIDC/token")).willReturn(
            json(
                200,
                """{"access_token":"$DUMP_ACCESS","token_type":"Bearer","expires_in":300,""" +
                    """"refresh_token":"$DUMP_REFRESH","id_token":"$idToken"}""",
            ),
        ),
    )
    server.stubFor(
        post(urlEqualTo("$DUMP_OIDC/token/introspect"))
            .willReturn(json(200, """{"active":true,"username":"svc","client_id":"c","sub":"u1"}""")),
    )
    server.stubFor(get(urlEqualTo("$DUMP_OIDC/certs")).willReturn(json(200, JWKSet(key.toPublicJWK()).toString())))
    server.stubFor(
        post(urlEqualTo("/realms/bad/protocol/openid-connect/token"))
            .willReturn(json(401, """{"error":"invalid_client","error_description":"Invalid client credentials"}""")),
    )
    server.stubFor(get(urlEqualTo("/admin/realms/r/users/missing")).willReturn(json(404, """{"error":"User not found"}""")))
    server.stubFor(post(urlEqualTo("/admin/realms/r/users")).willReturn(json(409, """{"errorMessage":"User exists"}""")))
    server.stubFor(get(urlEqualTo("/admin/realms/r/roles/forbidden")).willReturn(json(403, """{"error":"forbidden"}""")))
    server.stubFor(get(urlEqualTo("/admin/realms/r/groups/boom")).willReturn(json(500, """{"error":"unknown_error"}""")))

    val cc = kc.auth.clientCredentialsToken()
    val exchanged = kc.auth.exchangeCode("code-1", ar.codeVerifier, "https://app/cb", ar.nonce)
    val introspection = kc.auth.introspect(DUMP_ACCESS)
    val validated = kc.auth.validate(rawJwt)
    val provider = ClientCredentialsTokenProvider(fetch = { kc.auth.clientCredentialsToken() })
    val providerToken = provider.accessToken()

    // admin 기본 경로 — 첫 호출이 내장 TokenManager 에 토큰을 캐시한다. 실패 응답이 곧 admin 오류 뿌리다.
    val admin = kc.admin
    val notFound = assertFailsWith<KeycloakAdminException.NotFound> { admin.users().get("missing") }
    val user =
        UserRepresentation().apply {
            username = "dump-user"
            credentials =
                listOf(
                    CredentialRepresentation().apply {
                        type = CredentialRepresentation.PASSWORD
                        value = DUMP_PASSWORD
                    },
                )
        }
    val conflict = assertFailsWith<KeycloakAdminException.Conflict> { admin.users().create(user) }
    val forbidden = assertFailsWith<KeycloakAdminException.Forbidden> { admin.roles().get("forbidden") }
    val other = assertFailsWith<KeycloakAdminException.Other> { admin.groups().get("boom") }

    // ⚠️ 카나리아가 실제로 흘러 들어갔는가 — 안 흘렀으면 아래 누출 검사는 없는 것을 찾으며 통과한다.
    assertContentEquals(DUMP_SECRET.toCharArray(), kc.config.clientSecret, "config 가 카나리아 시크릿을 쥐지 않는다")
    assertEquals(listOf(DUMP_ACCESS, DUMP_REFRESH), listOf(cc.accessToken, cc.refreshToken), "client-credentials TokenSet")
    assertEquals(
        listOf(DUMP_ACCESS, DUMP_REFRESH, idToken),
        listOf(exchanged.accessToken, exchanged.refreshToken, exchanged.idToken),
        "exchangeCode TokenSet",
    )
    assertEquals(DUMP_ACCESS, providerToken, "공급자가 카나리아 액세스 토큰을 캐시하지 않았다")
    assertTrue(ar.codeVerifier.length >= 43, "PKCE verifier 가 비었다")
    assertEquals("u1", validated.subject, "validate 가 서명한 JWT 를 받지 않았다")
    assertEquals("svc", introspection.username, "introspect 응답이 매핑되지 않았다")
    server.verify(postRequestedFor(urlEqualTo("$DUMP_OIDC/token")).withRequestBody(containing("code_verifier=${ar.codeVerifier}")))
    server.verify(postRequestedFor(urlEqualTo("$DUMP_OIDC/token/introspect")).withHeader("Authorization", equalTo("Basic $basic")))
    server.verify(getRequestedFor(urlEqualTo("/admin/realms/r/users/missing")).withHeader("Authorization", equalTo("Bearer $DUMP_ACCESS")))
    server.verify(postRequestedFor(urlEqualTo("/admin/realms/r/users")).withRequestBody(containing(DUMP_PASSWORD)))

    // 오류 타입 — 실제 실패 호출에서 얻는다.
    val bad = KeycloakConfig(server.baseUrl(), "bad", "c", DUMP_SECRET.toCharArray())
    val authError = assertFailsWith<KeycloakAuthException> { AuthClient(bad).clientCredentialsToken() }
    val validationError = assertFailsWith<TokenValidationException> { kc.auth.validate(DUMP_GARBAGE) }
    val downPort = ServerSocket(0).use { it.localPort }
    val down =
        KeycloakConfig(
            "http://127.0.0.1:$downPort",
            "r",
            "c",
            DUMP_SECRET.toCharArray(),
            connectTimeout = Duration.ofSeconds(2),
        )
    val authTransport = assertFailsWith<KeycloakTransportException> { AuthClient(down).introspect(DUMP_ACCESS) }
    val downAdmin = AdminClient(down).also { closing += it }
    val adminTransport = assertFailsWith<KeycloakTransportException> { downAdmin.users().get("missing") }
    val configError = assertFailsWith<KeycloakConfigException> { KeycloakConfig("", "r", "c", DUMP_SECRET.toCharArray()) }

    val roots =
        listOf(
            "KeycloakClient.create" to kc,
            "admin" to admin,
            "users()" to admin.users(),
            "clients()" to admin.clients(),
            "realms()" to admin.realms(),
            "roles()" to admin.roles(),
            "groups()" to admin.groups(),
            "createAuthorizationRequest" to ar,
            "clientCredentialsToken" to cc,
            "exchangeCode" to exchanged,
            "introspect" to introspection,
            "validate" to validated,
            "ClientCredentialsTokenProvider" to provider,
            "auth error" to authError,
            "validation error" to validationError,
            "auth transport error" to authTransport,
            "admin transport error" to adminTransport,
            "config error" to configError,
            "admin 404" to notFound,
            "admin 409" to conflict,
            "admin 403" to forbidden,
            "admin 500" to other,
        )
    val canaries =
        mapOf(
            "SECRET" to DUMP_SECRET,
            "ACCESS" to DUMP_ACCESS,
            "REFRESH" to DUMP_REFRESH,
            "ID" to idToken,
            "GARBAGE" to DUMP_GARBAGE,
            "PASSWORD" to DUMP_PASSWORD,
            "VERIFIER" to ar.codeVerifier,
            "JWT" to rawJwt,
            // introspect 의 Basic 헤더 값 — 시크릿의 인코딩된 형태도 비밀이다(위 verify 가 실제 값임을 보였다).
            "BASIC" to basic,
        )
    return DumpRoots(roots, canaries)
}

// 뿌리에서 닿는 객체 전부를 너비 우선으로 걷는다. SDK 타입(main 클래스 디렉터리에서 온 클래스)은 바닥 경로로
// 그려 카나리아를 찾고, 하위 라이브러리 객체는 그리지 않고 **통과만** 한다 — SDK 객체가 라이브러리 안쪽에만
// 매달려 있을 수 있다(예: JwtValidator → Nimbus 프로세서 사슬 → NoRedirectResourceRetriever).
private class DumpWalker(
    private val canaries: Map<String, String>,
    private val own: String,
    private val harness: String,
) {
    private val seen: MutableSet<Any> = Collections.newSetFromMap(IdentityHashMap())
    private val sources = HashMap<Class<*>, String?>()

    /** 걷기에 걸린 SDK 타입(상위 타입 포함)의 이진 이름. */
    val reached: MutableSet<String> = sortedSetOf()

    /** `"뿌리|카나리아"` → 그 누출을 본 자리들. */
    val leaks: MutableMap<String, MutableList<String>> = sortedMapOf()

    /** 걷기가 못 잰 자리 — 조용히 건너뛰면 걷기가 줄어든 것을 아무도 모른다(Go 는 같은 자리를 Fatal 로 멈춘다). */
    val unmeasured: MutableList<String> = mutableListOf()

    /** 들어가지 않은 하네스 객체의 클래스 — 위생 규칙이 무엇을 막았는지 사람이 대조할 수 있게 남긴다. */
    val harnessSkipped: MutableSet<String> = sortedSetOf()

    var visited: Int = 0
        private set

    fun walk(
        root: String,
        start: Any,
    ) {
        val queue = ArrayDeque<Pair<Any, String>>()
        queue.addLast(start to root)
        while (queue.isNotEmpty()) {
            val (obj, path) = queue.removeFirst()
            if (!seen.add(obj)) continue
            check(++visited <= DUMP_MAX_VISITS) { "걷기가 $DUMP_MAX_VISITS 객체를 넘었다 — 멈춤 규칙이 샜다($path)" }
            val source = sourceOf(obj.javaClass)
            // 하네스 객체는 불투명하다 — 들어가면 하네스가 쥔 것이 SDK 도달로 잡힌다.
            if (source == harness) {
                harnessSkipped += obj.javaClass.name.removePrefix(DUMP_PKG)
                continue
            }
            if (source == own) {
                record(obj.javaClass)
                render(root, obj, path)
            }
            children(obj, path) { v, p -> queue.addLast(v to p) }
        }
    }

    private fun sourceOf(cls: Class<*>): String? =
        if (cls in sources) {
            sources[cls]
        } else {
            cls.protectionDomain
                ?.codeSource
                ?.location
                ?.toString()
                .also { sources[cls] = it }
        }

    private fun record(cls: Class<*>) {
        val todo = ArrayDeque<Class<*>>()
        todo.addLast(cls)
        while (todo.isNotEmpty()) {
            val c = todo.removeFirst()
            if (sourceOf(c) != own || !reached.add(c.name)) continue
            c.superclass?.let { todo.addLast(it) }
            todo.addAll(c.interfaces)
        }
    }

    private fun render(
        root: String,
        obj: Any,
        path: String,
    ) {
        val outs = linkedMapOf("toString()" to obj.toString(), "\"\$obj\"" to "$obj")
        if (obj is Throwable) outs["stackTraceToString()"] = obj.stackTraceToString()
        for ((how, out) in outs) {
            for ((name, value) in canaries) {
                if (value in out) {
                    val type = obj.javaClass.name.removePrefix(DUMP_PKG)
                    leaks.getOrPut("$root|$name") { mutableListOf() } += "$path [$type] $how: 비밀 $name 이 원문으로 찍혔다"
                }
            }
        }
    }

    private fun children(
        obj: Any,
        path: String,
        push: (Any, String) -> Unit,
    ) {
        fun add(
            v: Any?,
            p: String,
        ) {
            if (v != null && !isLeaf(v)) push(v, p)
        }
        // JDK 모듈은 리플렉션으로 열리지 않는다 — 담는 것은 공개 API 로 꺼낸다.
        when (obj) {
            is Array<*> -> obj.forEachIndexed { i, v -> add(v, "$path[$i]") }
            is Map<*, *> ->
                snapshot(path) { obj.entries.toList() }.forEach { (k, v) ->
                    add(k, "$path.key")
                    add(v, "$path.value")
                }
            is Collection<*> -> snapshot(path) { obj.toList() }.forEach { add(it, "$path[]") }
            is Throwable -> {
                add(obj.cause, "$path.cause")
                obj.suppressed.forEach { add(it, "$path.suppressed") }
            }
            is AtomicReference<*> -> add(obj.get(), "$path.get()")
            is Optional<*> -> add(obj.orElse(null), "$path.get()")
        }
        // admin-client 리소스는 JDK 동적 프록시다 — 핸들러는 `Proxy.h`(java.base, 안 열림)에 있어 공개 API 로 꺼낸다.
        if (Proxy.isProxyClass(obj.javaClass)) add(Proxy.getInvocationHandler(obj), "$path.h")
        // 필드 — private 까지, 상위 클래스까지. 이름 없는 모듈(SDK·하위 라이브러리)의 클래스만 열린다.
        var c: Class<*>? = obj.javaClass
        while (c != null && c != Any::class.java) {
            if (!c.module.isNamed) {
                for (f in c.declaredFields) {
                    if (Modifier.isStatic(f.modifiers) || f.type.isPrimitive) continue
                    if (!f.trySetAccessible()) {
                        unmeasured += "$path.${f.name} (${c.name}): 필드를 열 수 없다"
                        continue
                    }
                    add(f.get(obj), "$path.${f.name}")
                }
            }
            c = c.superclass
        }
    }

    private fun <T> snapshot(
        path: String,
        read: () -> List<T>,
    ): List<T> =
        try {
            read()
        } catch (e: RuntimeException) {
            unmeasured += "$path: 컬렉션을 읽을 수 없다($e)"
            emptyList()
        }

    // 멈춤 규칙 — 값(문자열·수)은 그릴 것이 없고, 클래스로더·스레드는 JVM 전체(하네스 포함)로 이어진다.
    private fun isLeaf(v: Any): Boolean =
        v is CharSequence ||
            v is Number ||
            v is Boolean ||
            v is Char ||
            v is Class<*> ||
            v is ClassLoader ||
            v is Thread ||
            v is ThreadGroup ||
            v is Module
}

// main 클래스 디렉터리의 선언 타입 전수 — 손 목록이 아니라 트리에서 파생한다.
private fun declaredTypes(
    own: URL,
    loader: ClassLoader,
): List<Class<*>> {
    val dir = Paths.get(own.toURI())
    check(Files.isDirectory(dir)) { "SDK 클래스가 디렉터리에서 오지 않는다($own) — 선언 파생이 이 모양을 모른다" }
    val files = Files.walk(dir).use { s -> s.filter { it.fileName.toString().endsWith(".class") }.toList() }
    return files
        .map { Class.forName(dir.relativize(it).joinToString(".").removeSuffix(".class"), false, loader) }
        .filter { c -> c.getAnnotation(Metadata::class.java)?.let { it.kind == DUMP_KIND_CLASS } ?: !c.isSynthetic }
        .sortedBy { it.name }
}

// 파생 규칙 — 자기와 상위 클래스 어디에도 인스턴스 필드가 없으면 비밀을 쥘 자리가 없다(인터페이스·companion).
private fun holdsInstanceState(cls: Class<*>): Boolean =
    generateSequence(cls) { it.superclass }
        .takeWhile { it != Any::class.java }
        .any { k -> k.declaredFields.any { !Modifier.isStatic(it.modifiers) } }

private fun reconcile(
    declared: List<Class<*>>,
    reached: Set<String>,
): List<String> {
    val problems = mutableListOf<String>()
    for (cls in declared) {
        val name = cls.name.removePrefix(DUMP_PKG)
        val exempt = DUMP_EXEMPT[name]
        val isReached = cls.name in reached
        if (isReached && exempt != null) {
            problems += "$name: 걷기에 닿는데 면제 표에도 있다 — 면제를 지워라($exempt)"
        } else if (!isReached && exempt == null && holdsInstanceState(cls)) {
            problems += "$name: 공개 API 뿌리에서 닿지 않는 상태 있는 타입이다 — 만드는 경로를 뿌리에 더하거나, 이유와 함께 면제하라"
        }
    }
    val names = declared.map { it.name.removePrefix(DUMP_PKG) }.toSet()
    for (name in DUMP_EXEMPT.keys - names) {
        problems += "$name: 면제 표에 있지만 선언이 없다 — 낡은 면제다"
    }
    return problems
}
