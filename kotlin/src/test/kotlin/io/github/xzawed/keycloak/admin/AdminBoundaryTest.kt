package io.github.xzawed.keycloak.admin

import io.github.xzawed.keycloak.KeycloakAdminException
import io.github.xzawed.keycloak.KeycloakTransportException
import io.mockk.every
import io.mockk.mockk
import jakarta.ws.rs.ProcessingException
import jakarta.ws.rs.WebApplicationException
import jakarta.ws.rs.core.Response
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.keycloak.representations.idm.UserRepresentation
import java.net.URI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs

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
            val users = UsersResource(delegate)

            val id = users.create(UserRepresentation())

            assertEquals("abc-123", id)
        }
}
