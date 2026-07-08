package io.github.xzawed.keycloak

import io.github.xzawed.keycloak.admin.AdminClient
import io.mockk.mockk
import io.mockk.verify
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

// ClientTest — KeycloakClient 파사드의 lazy/close 계약을 검증한다: auth 즉시 생성·admin 지연 생성·
// close()가 미접근 admin을 강제로 실현시키지 않음(핵심 불변식)·admin 접근이 lazy를 실현함·close()가
// auth와(실현됐다면) admin 둘 다 정리함. 실 `AdminClient(config)`는 KeycloakBuilder로 실 JAX-RS 클라이언트를
// 만들므로 여기서는 절대 실현하지 않는다(대신 `error(...)` 던지는 lazy 또는 MockK로 대체) — 오직
// "admin이 실제로 접근됐는가"만 검증하고 admin 자체의 행동은 T8(AdminBoundaryTest)이 이미 커버한다.
internal class ClientTest {
    private fun config() =
        KeycloakConfig(
            serverUrl = "http://localhost:8080",
            realm = "r",
            clientId = "app",
            clientSecret = "secret".toCharArray(),
        )

    @Test
    fun `create eagerly builds auth and leaves admin uninitialized`() {
        val client = KeycloakClient.create(config())

        assertNotNull(client.auth)
        assertFalse(client.isAdminInitialized())
    }

    @Test
    fun `close without ever accessing admin does not initialize it`() {
        // 실 create()를 쓴다 — admin lazy 블록이 실현되면 AdminClient(config)가 실 KeycloakBuilder.build()를
        // 트리거하므로, 이 테스트가 GREEN이라는 사실 자체가 "close()가 admin을 강제생성하지 않는다"는
        // 핵심 불변식의 증거다(실현됐다면 네트워크 없는 단위테스트가 느려지거나 실패했을 것).
        val client = KeycloakClient.create(config())

        client.close()

        assertFalse(client.isAdminInitialized())
    }

    @Test
    fun `close invokes auth close`() {
        val auth = mockk<AuthClient>(relaxed = true)
        val client =
            KeycloakClient(
                config(),
                auth,
                lazy { error("admin must not be realized when it was never accessed") },
            )

        client.close()

        verify(exactly = 1) { auth.close() }
    }

    @Test
    fun `accessing admin realizes the lazy exactly once`() {
        val adminMock = mockk<AdminClient>(relaxed = true)
        val client = KeycloakClient(config(), AuthClient(config()), lazy { adminMock })

        val first = client.admin
        val second = client.admin

        assertTrue(client.isAdminInitialized())
        assertSame(adminMock, first)
        assertSame(adminMock, second)
    }

    @Test
    fun `close after accessing admin closes both auth and admin`() {
        val auth = mockk<AuthClient>(relaxed = true)
        val adminMock = mockk<AdminClient>(relaxed = true)
        val client = KeycloakClient(config(), auth, lazy { adminMock })

        client.admin
        client.close()

        verify(exactly = 1) { auth.close() }
        verify(exactly = 1) { adminMock.close() }
    }

    @Test
    fun `use block auto-closes without initializing admin`() {
        val client = KeycloakClient.create(config())

        client.use { c -> assertNotNull(c.auth) }

        assertFalse(client.isAdminInitialized())
    }
}
