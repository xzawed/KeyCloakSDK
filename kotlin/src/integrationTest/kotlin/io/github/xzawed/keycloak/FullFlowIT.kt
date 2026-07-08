package io.github.xzawed.keycloak

import dasniko.testcontainers.keycloak.KeycloakContainer
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.TestInstance
import org.keycloak.representations.idm.ClientRepresentation
import org.keycloak.representations.idm.GroupRepresentation
import org.keycloak.representations.idm.RealmRepresentation
import org.keycloak.representations.idm.RoleRepresentation
import org.keycloak.representations.idm.UserRepresentation
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

// FullFlowIT — 실 Keycloak 26.6(Testcontainers·dasniko) E2E. 8언어 자매 SDK(Go/.NET/Rust/Ruby)의 단일
// 종합 시나리오와 동형: client-credentials → validate(실 JWKS) → introspect → user/client/role/group
// CRUD(+delete 후 NotFound) → realm CRUD(master-admin) → raw() → delete → NotFound. it-realm/it-client/
// it-secret 픽스처는 Java/.NET/Rust/Ruby와 동일 realm JSON을 재사용한다(src/integrationTest/resources).
//
// ⚠️ Kotlin `AdminClient`는 (Java와 동일하게) TokenProvider 주입 생성자를 제공하지 않는다(client.kt의
// 코멘트 참고) — 공개 `AdminClient(config)` 생성자는 항상 config.clientSecret으로 client-credentials
// 그랜트만 수행한다. `POST /admin/realms`(신규 렐름 생성)는 master 렐름 전용 권한이라 it-client 서비스
// 계정으로는 403이 난다(.NET/Rust/Ruby 자매 SDK가 각자 독립적으로 확인한 실서버 동작 — CLAUDE.md 게차
// 참고). 그래서 master-admin 렐름 CRUD 구간만 SDK 파사드를 우회해, dasniko가 기본 제공하는
// `KeycloakContainer.getKeycloakAdminClient()`(master 렐름 bootstrap admin/admin, password 그랜트)로
// 얻은 원본 `org.keycloak.admin.client.Keycloak`을 직접 사용한다 — 이는 `AdminClient.raw()`가 문서화한
// 은닉성 예외(§4)와 같은 탈출구 패턴이며, SDK 소스 자체는 수정하지 않는다(공개 API만 소비).
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
internal class FullFlowIT {
    private lateinit var container: KeycloakContainer

    @BeforeAll
    fun startKeycloak() {
        container = KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/it-realm-realm.json")
        container.start()
    }

    @AfterAll
    fun stopKeycloak() {
        if (this::container.isInitialized) {
            container.stop()
        }
    }

    private fun config(): KeycloakConfig =
        KeycloakConfig(
            serverUrl = container.authServerUrl,
            realm = "it-realm",
            clientId = "it-client",
            clientSecret = "it-secret".toCharArray(),
            scopes = listOf("openid"),
        )

    @Test
    fun `full flow — client-credentials to validate to introspect to admin CRUD to realm CRUD to raw`() =
        runBlocking {
            val suffix = UUID.randomUUID().toString()

            KeycloakClient.create(config()).use { kc ->
                // 1) client-credentials 토큰 발급 + 마스킹 불변식.
                val token = kc.auth.clientCredentialsToken()
                assertTrue(token.accessToken.isNotBlank(), "access token must be non-blank")
                val rendered = token.toString()
                assertTrue(rendered.contains("***"), "TokenSet.toString must mask the access token")
                assertFalse(rendered.contains(token.accessToken), "TokenSet.toString must not leak the raw access token")

                // 2) validate — 실 JWKS로 서명·iss·aud·exp까지 강화 검증한다(다중값 aud, it-client 매퍼 수용).
                val validated = kc.auth.validate(token.accessToken)
                assertTrue(validated.issuer?.endsWith("/realms/it-realm") == true, "unexpected issuer: ${validated.issuer}")
                assertTrue(validated.audience.contains("it-client"), "aud must include it-client: ${validated.audience}")
                assertFalse(validated.subject.isNullOrBlank(), "subject must not be blank")

                // 3) RFC 7662 introspection.
                val introspection = kc.auth.introspect(token.accessToken)
                assertTrue(introspection.active, "introspection must report active=true")

                // 4) user CRUD(+ delete 후 조회 → NotFound).
                val username = "kotlin-it-user-$suffix"
                val userId =
                    kc.admin.users().create(
                        UserRepresentation().apply {
                            this.username = username
                            email = "$username@example.com"
                            isEnabled = true
                        },
                    )
                assertTrue(userId.isNotBlank())
                assertEquals(
                    username,
                    kc.admin
                        .users()
                        .get(userId)
                        .username,
                )
                val found = kc.admin.users().search(username, 0, 10)
                assertTrue(found.any { it.id == userId }, "search must find the created user")
                kc.admin.users().update(userId, UserRepresentation().apply { firstName = "Kotlin" })
                assertEquals(
                    "Kotlin",
                    kc.admin
                        .users()
                        .get(userId)
                        .firstName,
                )
                kc.admin.users().delete(userId)
                assertFailsWith<KeycloakAdminException.NotFound> { kc.admin.users().get(userId) }

                // 5) client CRUD.
                val clientId = "kotlin-it-client-$suffix"
                val clientUuid = kc.admin.clients().create(ClientRepresentation().apply { this.clientId = clientId })
                assertEquals(
                    clientId,
                    kc.admin
                        .clients()
                        .get(clientUuid)
                        .clientId,
                )
                assertTrue(
                    kc.admin
                        .clients()
                        .findByClientId(clientId)
                        .isNotEmpty(),
                )
                kc.admin.clients().delete(clientUuid)

                // 6) role CRUD(name 키).
                val roleName = "kotlin-it-role-$suffix"
                kc.admin.roles().create(RoleRepresentation().apply { name = roleName })
                assertEquals(
                    roleName,
                    kc.admin
                        .roles()
                        .get(roleName)
                        .name,
                )
                assertTrue(
                    kc.admin
                        .roles()
                        .list()
                        .any { it.name == roleName },
                )
                kc.admin.roles().delete(roleName)

                // 7) group CRUD.
                val groupName = "kotlin-it-group-$suffix"
                val groupId = kc.admin.groups().create(GroupRepresentation().apply { name = groupName })
                assertEquals(
                    groupName,
                    kc.admin
                        .groups()
                        .get(groupId)
                        .name,
                )
                assertTrue(
                    kc.admin
                        .groups()
                        .list(0, 20)
                        .any { it.id == groupId },
                )
                kc.admin.groups().delete(groupId)

                // 8) realms().get(현재 렐름) — it-client 자체 realm-management 스코프로 조회 가능.
                assertEquals(
                    "it-realm",
                    kc.admin
                        .realms()
                        .get("it-realm")
                        .realm,
                )

                // 8b) it-client 서비스계정으로 신규 렐름 생성 시도 → 403(master 전용, 실서버 확정 동작).
                assertFailsWith<KeycloakAdminException.Forbidden> {
                    kc.admin.realms().create(
                        RealmRepresentation().apply {
                            realm = "kotlin-it-denied-$suffix"
                            isEnabled = true
                        },
                    )
                }

                // 9) raw() 탈출구.
                assertNotNull(
                    kc.admin
                        .raw()
                        .serverInfo()
                        .info,
                )
            }

            // 10) realm CRUD via master-admin(dasniko 기본 bootstrap admin/admin, password 그랜트) —
            // SDK 파사드가 지원하지 않는 master 전용 권한이라 컨테이너가 제공하는 raw Keycloak을 직접 쓴다.
            val newRealm = "kotlin-it-realm-$suffix"
            container.keycloakAdminClient.use { master ->
                master.realms().create(
                    RealmRepresentation().apply {
                        realm = newRealm
                        isEnabled = true
                    },
                )
                assertEquals(newRealm, master.realm(newRealm).toRepresentation().realm)

                master.realm(newRealm).remove()

                // 11) delete 후 조회 → NotFound(realm CRUD 완주 증명).
                assertFailsWith<jakarta.ws.rs.WebApplicationException> { master.realm(newRealm).toRepresentation() }
            }
        }
}
