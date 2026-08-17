package io.github.xzawed.keycloak.admin

import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.test.runTest
import org.keycloak.representations.idm.GroupRepresentation
import org.keycloak.representations.idm.RealmRepresentation
import org.keycloak.representations.idm.RoleRepresentation
import kotlin.test.Test
import kotlin.test.assertEquals

// AdminResourceDelegationTest — list/update 위임이 **경로와 body를 분리**하는지 고정한다.
//
// 왜 이 어서션인가: Keycloak의 rename은 `PUT /{현재주소}` + body에 새 이름이다. 경로 인자를 body의
// 이름으로 덮어쓰면 rename이 **조용한 no-op**이 되는데 종료코드로는 구분되지 않는다(Go에서 실제로
// 걸린 함정 — gocloak은 경로를 body에서 만들어 이 분리 자체가 불가능했다).
//
// ⚠️ 여기서 모킹하는 것은 전부 **인터페이스**다(RealmsResource·RealmResource·RolesResource 등).
// JAX-RS 추상 클래스(Response·WebApplicationException)를 MockK로 모킹하면 JDK 21에서 무기한
// hang한다 — 그 경계는 AdminBoundaryTest가 실객체로 다룬다.
internal class AdminResourceDelegationTest {
    @Test
    fun `realms list delegates to findAll`() =
        runTest {
            val delegate = mockk<org.keycloak.admin.client.resource.RealmsResource>()
            every { delegate.findAll() } returns listOf(RealmRepresentation())

            assertEquals(1, RealmsResource(delegate).list().size)
            verify { delegate.findAll() }
        }

    @Test
    fun `realms update addresses by current name and passes body through`() =
        runTest {
            val delegate = mockk<org.keycloak.admin.client.resource.RealmsResource>()
            val realm = mockk<org.keycloak.admin.client.resource.RealmResource>(relaxed = true)
            every { delegate.realm("r1") } returns realm
            val rep = RealmRepresentation().apply { this.realm = "r1-renamed" }

            RealmsResource(delegate).update("r1", rep)

            verify { delegate.realm("r1") }
            verify { realm.update(rep) }
        }

    @Test
    fun `roles update addresses by current name and passes body through`() =
        runTest {
            val delegate = mockk<org.keycloak.admin.client.resource.RolesResource>()
            val role = mockk<org.keycloak.admin.client.resource.RoleResource>(relaxed = true)
            every { delegate.get("r1") } returns role
            val rep = RoleRepresentation().apply { name = "r1-renamed" }

            RolesResource(delegate).update("r1", rep)

            verify { delegate.get("r1") }
            verify { role.update(rep) }
        }

    @Test
    fun `groups update addresses by id and passes body through`() =
        runTest {
            val delegate = mockk<org.keycloak.admin.client.resource.GroupsResource>()
            val group = mockk<org.keycloak.admin.client.resource.GroupResource>(relaxed = true)
            every { delegate.group("g-1") } returns group
            val rep = GroupRepresentation().apply { name = "team-renamed" }

            GroupsResource(delegate).update("g-1", rep)

            verify { delegate.group("g-1") }
            verify { group.update(rep) }
        }
}
