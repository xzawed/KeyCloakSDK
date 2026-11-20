package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakAdminException
import io.github.xzawed.keycloak.KeycloakAuthException
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.KeycloakTransportException
import io.mockk.every
import io.mockk.mockk
import jakarta.ws.rs.ProcessingException
import jakarta.ws.rs.WebApplicationException
import jakarta.ws.rs.client.ResponseProcessingException
import jakarta.ws.rs.core.Response
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.keycloak.representations.idm.ClientRepresentation
import org.keycloak.representations.idm.GroupRepresentation
import org.keycloak.representations.idm.UserRepresentation
import java.net.URI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

// AdminBoundaryTest — adminCall(AdminClient.kt)의 경계변환(부록 §auth-admin exactConfig)을 검증한다:
// WebApplicationException(status→404/409/403/그외)·ProcessingException→Transport·CancellationException 재throw.
//
// ⚠️ 실객체만 사용한다(JAX-RS 타입 MockK 금지). jakarta.ws.rs.core.Response는 추상 클래스라 MockK로
// 모킹하면 byte-buddy가 RESTEasy 구현 클래스 그래프를 계측하다 JDK 21에서 무기한 hang한다(실측: 단일
// 테스트도 2.5분 타임아웃). 대신 실 WebApplicationException(message,status)/(message,Response)와 실
// Response.status(...).build()로 구성한다 — RuntimeDelegate 정상 로딩(계측 아님)이라 hang이 없다.
// entity-read '성공' 경로(readEntity가 본문을 반환)만 서버-빌드 Response로는 재현 불가(outbound는
// readEntity가 던짐)라 T10 E2E(실 Keycloak 오류 본문)에 위임한다. safeBody의 message 폴백 분기는 여기서 커버.
internal class AdminBoundaryTest {
    @Test
    fun `404 WebApplicationException maps to NotFound with status and message body`() =
        runTest {
            val e =
                assertFailsWith<KeycloakAdminException.NotFound> {
                    adminCall<Unit> { throw WebApplicationException("missing user", 404) }
                }
            assertEquals(404, e.status)
            assertEquals("missing user", e.keycloakError)
        }

    @Test
    fun `409 WebApplicationException maps to Conflict`() =
        runTest {
            val e =
                assertFailsWith<KeycloakAdminException.Conflict> {
                    adminCall<Unit> { throw WebApplicationException(409) }
                }
            assertEquals(409, e.status)
        }

    @Test
    fun `403 WebApplicationException maps to Forbidden`() =
        runTest {
            val e =
                assertFailsWith<KeycloakAdminException.Forbidden> {
                    adminCall<Unit> { throw WebApplicationException(403) }
                }
            assertEquals(403, e.status)
        }

    @Test
    fun `500 WebApplicationException maps to Other (default branch)`() =
        runTest {
            val e =
                assertFailsWith<KeycloakAdminException.Other> {
                    adminCall<Unit> { throw WebApplicationException("server exploded", 500) }
                }
            assertEquals(500, e.status)
            assertEquals("server exploded", e.keycloakError)
        }

    @Test
    fun `null response falls back to status 0 and message body`() =
        runTest {
            // 실 익명 서브클래스로 response=null을 재현(MockK 불요). WebApplicationException는 non-final.
            val wae =
                object : WebApplicationException("no response message") {
                    override fun getResponse(): Response? = null
                }
            val e =
                assertFailsWith<KeycloakAdminException.Other> {
                    adminCall<Unit> { throw wae }
                }
            assertEquals(0, e.status)
            assertEquals("no response message", e.keycloakError)
        }

    @Test
    fun `missing entity falls back to exception message`() =
        runTest {
            // 실 Response.status(500).build() = entity 없음 → safeBody가 message로 폴백.
            val e =
                assertFailsWith<KeycloakAdminException.Other> {
                    adminCall<Unit> {
                        throw WebApplicationException("no body message", Response.status(500).build())
                    }
                }
            assertEquals("no body message", e.keycloakError)
        }

    @Test
    fun `entity present is read as the keycloak error body`() =
        runTest {
            // 실 outbound Response(status 500 + String entity)는 hasEntity()=true이고 readEntity(String)이
            // 그 문자열을 그대로 반환한다(String↔String) → safeBody가 예외 message가 아니라 실 본문을 취한다.
            // 이로써 entity-read '성공' 경로(실 Keycloak 오류 JSON 본문 추출)를 실객체로 검증한다.
            val response = Response.status(500).entity("realm error body").build()
            val wae = WebApplicationException("ignored message", response)
            val e =
                assertFailsWith<KeycloakAdminException.Other> {
                    adminCall<Unit> { throw wae }
                }
            assertEquals("realm error body", e.keycloakError)
        }

    @Test
    fun `ProcessingException maps to KeycloakTransportException`() =
        runTest {
            val cause = ProcessingException("RESTEASY004655: could not send request")
            val e =
                assertFailsWith<KeycloakTransportException> {
                    adminCall<Unit> { throw cause }
                }
            // ⚠️ assertSame이 아니라 타입+메시지로 검증한다 — kotlinx.coroutines의 스택트레이스 복구가
            // suspend 경계를 넘는 예외를 (동일 정보의) 새 인스턴스로 복사하므로 identity가 보존되지 않는다.
            assertIs<ProcessingException>(e.cause)
            assertEquals("RESTEASY004655: could not send request", e.cause?.message)
        }

    // 응답을 받았으나 읽지 못한 실패(ResponseProcessingException — 사슬 어디에 있든)는 본문을 인용하는 하위 사슬을
    // 가린 사본으로만 단다. 분류(전송)와 SDK 메시지는 그대로다 — 전송 실패의 원본 유지는 위 테스트가 고정한다.
    @Test
    fun `ResponseProcessingException anywhere in the chain is attached only as a redacted copy`() =
        runTest {
            val parse = java.io.IOException("Unrecognized token 'LEAKBODY': was expecting a JSON value")
            val direct = ResponseProcessingException(Response.status(200).build(), parse)
            for (thrown in listOf(direct, ProcessingException(direct))) {
                val e =
                    assertFailsWith<KeycloakTransportException> {
                        adminCall<Unit> { throw thrown }
                    }
                assertEquals("Admin request failed", e.message)
                val printed = e.stackTraceToString()
                assertFalse("LEAKBODY" in printed, printed)
                assertTrue("Caused by: jakarta.ws.rs.client.ResponseProcessingException (message withheld)" in printed, printed)
                assertTrue("Caused by: java.io.IOException (message withheld)" in printed, printed)
            }
        }

    // admin 자기 그랜트의 실패는 타입으로 가른다(등록부 token-response-class-divergent · Java AdminExceptionsTest 동형) — 요청 필터에서 온
    // ProcessingException 아래의 HTTP 오류(토큰 엔드포인트의 오류 상태)와 UnusableTokenResponse(쓸 수 없는 2xx)는 끝까지 온 응답이라
    // 인증 오류이고 메시지는 상태만 싣는다. 같은 메시지의 맨 IOException(상한 초과 꼴)은 전송 실패다 — 메시지는 분류하지 않는다.
    @Test
    fun `admin grant failures are classified by type, not by message`() =
        runTest {
            val tokenError = WebApplicationException("LEAKBODY bad client", 401)
            val auth = assertFailsWith<KeycloakAuthException> { adminCall<Unit> { throw ProcessingException(tokenError) } }
            assertEquals("Admin token request failed: HTTP 401", auth.message)
            assertEquals(null, auth.oauthError, "OAuth 오류 코드는 본문에서 읽지 않는다 — 그 본문은 시크릿을 되울릴 수 있다")
            val printed = auth.stackTraceToString()
            assertFalse("LEAKBODY" in printed, printed)
            assertTrue("Caused by: jakarta.ws.rs.WebApplicationException (message withheld)" in printed, printed)

            val unusable = UnusableTokenResponse(201, TokenResponseGuard.REJECTED, null)
            val wrapped = ResponseProcessingException(Response.status(201).build(), ProcessingException(unusable))
            val rejected = assertFailsWith<KeycloakAuthException> { adminCall<Unit> { throw wrapped } }
            assertEquals("Admin token request failed: HTTP 201 (unusable token response)", rejected.message)

            for (message in listOf(TokenResponseGuard.REJECTED, "token response exceeds 1048576 bytes")) {
                val plain = ProcessingException(java.io.IOException(message))
                val t = assertFailsWith<KeycloakTransportException> { adminCall<Unit> { throw plain } }
                assertEquals("Admin request failed", t.message)
            }
            // 원인 사슬이 순환해도 끝난다(깊이로 끊는다) — 그 안에 판정할 것이 없으면 전송 실패다
            val first = java.io.IOException("a")
            val second = java.io.IOException("b", first)
            first.initCause(second)
            val cyclic = assertFailsWith<KeycloakTransportException> { adminCall<Unit> { throw ProcessingException(first) } }
            assertEquals("Admin request failed", cyclic.message)
        }

    @Test
    fun `CancellationException is rethrown, not wrapped`() =
        runTest {
            assertFailsWith<CancellationException> {
                adminCall<Unit> { throw CancellationException("cancelled") }
            }
        }

    @Test
    fun `successful block returns its value unmodified`() =
        runTest {
            assertEquals("ok", adminCall { "ok" })
        }

    @Test
    fun `UsersResource create extracts id from Location header`() =
        runTest {
            // UsersResource는 인터페이스라 MockK 프록시가 가벼움(추상 클래스 Response 계측 hang과 무관).
            val delegate = mockk<org.keycloak.admin.client.resource.UsersResource>()
            val response = Response.created(URI("http://localhost:8080/admin/realms/test/users/abc-123")).build()
            every { delegate.create(any()) } returns response
            val users = UsersResource(delegate, URI("http://localhost:8080/admin/realms/test/users"))

            val id = users.create(UserRepresentation())

            assertEquals("abc-123", id)
        }

    /**
     * 아홉 SDK 가 같이 쓰는 `Location` 벡터(등록부 admin-create-relative-location) — id 는 201 의 `Location` 을 요청 URL 에 대해 푼
     * (RFC 9110 §10.2.2) 경로의 마지막 조각이고, 그 앞 조각은 보낸 컬렉션이어야 한다. 상대 `Location` 도 읽고, 쿼리 · 조각은 id 가
     * 아니며, 퍼센트 인코딩은 풀지 않는다. 없거나 빈 값, 다른 컬렉션 · id 없는 경로는 id 없음 오류다. users 는 열셋 전부, clients ·
     * groups 는 L1 · L2 · L4 · L7 · L9. Response 는 실객체다(MockK 금지 — 위 머리 주석).
     */
    @Test
    fun `create reads the id from the Location resolved against the request URL`(): Unit =
        runTest {
            val wrong = mutableListOf<String>()
            var cells = 0
            for (coll in listOf("users", "clients", "groups")) {
                val path = "/admin/realms/r/$coll"
                for ((vector, template, want) in LOCATION_VECTORS) {
                    if (coll != "users" && vector.substringBefore(' ') !in listOf("L1", "L2", "L4", "L7", "L9")) continue
                    cells++
                    val location =
                        template
                            ?.replace("{base}", "https://kc.example.com")
                            ?.replace("{path}", path)
                            ?.replace("{coll}", coll)
                            ?.replace("{other}", if (coll == "groups") "users" else "groups")
                    val built = Response.status(201)
                    val response = (if (location == null) built else built.header("Location", location)).build()
                    val got =
                        try {
                            "ok " + createWith(coll, response)
                        } catch (e: KeycloakAdminException) {
                            "${e::class.simpleName}(${e.status}): ${e.keycloakError}"
                        } catch (e: RuntimeException) {
                            "${e::class.qualifiedName}: ${e.message}"
                        }
                    val expected = if (want == null) NO_ID else "ok $want"
                    if (got != expected) wrong += "$coll $vector: $got — want $expected"
                }
            }
            assertEquals(23, cells)
            assertTrue(wrong.isEmpty(), "${wrong.size} cell(s) wrong:\n${wrong.joinToString("\n")}")
        }

    /**
     * 파사드는 create 의 `Location` 을 그 컬렉션의 URL(`{serverUrl}/admin/realms/{realm}/{컬렉션}` — admin-client 의 프록시가 짓는
     * 그대로)에 대해 푼다: 컬렉션 이름으로 시작하는 상대 값은 id 이고, 맨 `u-1` 은 realm 아래라 id 없음 오류다(Java 동형).
     */
    @Test
    fun `facades resolve the create Location against their collection`(): Unit =
        runTest {
            val realm = mockk<org.keycloak.admin.client.resource.RealmResource>()
            val users = mockk<org.keycloak.admin.client.resource.UsersResource>()
            val keycloak = mockk<org.keycloak.admin.client.Keycloak>()
            every { keycloak.realm("r") } returns realm
            every { realm.users() } returns users
            every { users.create(any()) } returnsMany
                listOf(
                    Response.status(201).header("Location", "users/u-1").build(),
                    Response.status(201).header("Location", "u-1").build(),
                )
            val admin = AdminClient(KeycloakConfig("https://kc.example.com/auth", "r", "app"), keycloak)

            assertEquals("u-1", admin.users().create(UserRepresentation()))
            assertFailsWith<KeycloakAdminException.Other> { admin.users().create(UserRepresentation()) }
        }

    /** 풀 수 없는 값(날 공백 — [URI] 가 거부한다)과 경로가 없는 불투명 URI(`mailto:`)도 id 없음 오류다. */
    @Test
    fun `create reads no id from a Location that does not parse or has no path`(): Unit =
        runTest {
            for (location in listOf("https://kc.example.com/admin/realms/r/users/abc 123", "mailto:abc-123")) {
                val response = Response.status(201).header("Location", location).build()
                val e = assertFailsWith<KeycloakAdminException.Other>(location) { createWith("users", response) }
                assertEquals(500, e.status)
                assertEquals(NO_ID.substringAfter(": "), e.keycloakError)
            }
        }

    /** [coll] 의 create 가 [response] 를 받고 돌려준 id — 보낸 URL 은 `https://kc.example.com/admin/realms/r/[coll]`. */
    private suspend fun createWith(
        coll: String,
        response: Response,
    ): String {
        val sentTo = URI("https://kc.example.com/admin/realms/r/$coll")
        return when (coll) {
            "users" -> {
                val delegate = mockk<org.keycloak.admin.client.resource.UsersResource>()
                every { delegate.create(any()) } returns response
                UsersResource(delegate, sentTo).create(UserRepresentation())
            }
            "clients" -> {
                val delegate = mockk<org.keycloak.admin.client.resource.ClientsResource>()
                every { delegate.create(any()) } returns response
                ClientsResource(delegate, sentTo).create(ClientRepresentation())
            }
            else -> {
                val delegate = mockk<org.keycloak.admin.client.resource.GroupsResource>()
                every { delegate.add(any()) } returns response
                GroupsResource(delegate, sentTo).create(GroupRepresentation())
            }
        }
    }

    private companion object {
        /** id 없음 — 응답은 201 이지만 쓸 수 있는 id 가 없다. */
        const val NO_ID = "Other(500): resource created but no id returned in Location header"

        /** (벡터, `Location`(`null` 이면 머리 없음), 돌려줄 id(`null` 이면 [NO_ID])). */
        val LOCATION_VECTORS: List<Triple<String, String?, String?>> =
            listOf(
                Triple("L1 absolute", "{base}{path}/abc-123", "abc-123"),
                Triple("L2 path-absolute", "{path}/abc-123", "abc-123"),
                Triple("L3 relative path", "{coll}/abc-123", "abc-123"),
                Triple("L4 relative", "abc-123", null),
                Triple("L5 another host", "https://internal.example:8443{path}/abc-123", "abc-123"),
                Triple("L6 gateway prefix", "https://gw.example/kc{path}/abc-123", "abc-123"),
                Triple("L7 query and fragment", "{base}{path}/abc-123?x=1#f", "abc-123"),
                Triple("L8 trailing slash", "{base}{path}/abc-123/", "abc-123"),
                Triple("L9 another collection", "../{other}/abc-123", null),
                Triple("L10 root", "/", null),
                Triple("L11 empty value", "", null),
                Triple("L12 absent", null, null),
                Triple("L13 percent-encoded", "{base}{path}/abc%20123", "abc%20123"),
            )
    }
}
