package io.github.xzawed.harness

import com.fasterxml.jackson.databind.ObjectMapper
import io.github.xzawed.keycloak.KeycloakAdminException
import io.github.xzawed.keycloak.KeycloakAuthException
import io.github.xzawed.keycloak.KeycloakClient
import io.github.xzawed.keycloak.KeycloakConfig
import io.github.xzawed.keycloak.TokenValidationException
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.jackson.jackson
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import org.keycloak.representations.idm.ClientRepresentation
import org.keycloak.representations.idm.GroupRepresentation
import org.keycloak.representations.idm.RealmRepresentation
import org.keycloak.representations.idm.RoleRepresentation
import org.keycloak.representations.idm.UserRepresentation
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets
import java.time.Instant

// Kotlin/Ktor 하네스 샘플 앱 — 공통 HTTP 계약(harness/contract/CONTRACT.md)을 Kotlin SDK로 구현한다.
// Java 앱(Spring Boot)과 동형이되 Kotlin 관용: Ktor 라우트 핸들러가 이미 코루틴이라 SDK의 suspend
// 메서드를 runBlocking 없이 직접 호출한다(coroutine-native — SDK 설계와 정합). JSON은 Jackson(SDK가
// 노출하는 org.keycloak.representations.idm.* Java POJO + 동적 Map 양쪽을 다룸).

private fun env(k: String, d: String): String = System.getenv(k)?.takeIf { it.isNotEmpty() } ?: d

private fun enc(s: String): String = URLEncoder.encode(s, StandardCharsets.UTF_8)

private fun expiresIn(expiresAt: Instant?): Long =
    if (expiresAt == null) 0 else maxOf(0, expiresAt.epochSecond - Instant.now().epochSecond)

// 단일 프로세스 데모 하네스 전용 서버측 refresh 토큰 보관(logout/refresh 자동화용, Java 앱 동형).
@Volatile private var lastRefreshToken: String? = null

private val httpClient: HttpClient = HttpClient.newHttpClient()
private val mapper = ObjectMapper()

private suspend fun ApplicationCall.fail(code: Int, msg: String?) =
    respond(HttpStatusCode.fromValue(code), mapOf("error" to (msg ?: "error")))

private suspend fun ApplicationCall.fail(code: Int, e: Throwable) = fail(code, e.message ?: e.toString())

fun main() {
    val config =
        KeycloakConfig(
            serverUrl = env("KC_SERVER_URL", "http://localhost:8080"),
            realm = env("KC_REALM", "it-realm"),
            clientId = env("KC_CLIENT_ID", "it-client"),
            clientSecret = env("KC_CLIENT_SECRET", "it-secret").toCharArray(),
            scopes = listOf("openid"),
        )
    val kc = KeycloakClient.create(config)
    val port = env("APP_PORT", "8090").toInt()
    embeddedServer(Netty, port = port, host = "0.0.0.0") { module(kc, config) }.start(wait = true)
}

fun Application.module(kc: KeycloakClient, config: KeycloakConfig) {
    install(ContentNegotiation) { jackson() }

    routing {
        get("/healthz") { call.respond(mapOf("status" to "ok")) }

        // ---- auth ----
        post("/token") {
            try {
                val ts = kc.auth.clientCredentialsToken()
                call.respond(mapOf("tokenType" to ts.tokenType, "expiresIn" to expiresIn(ts.expiresAt)))
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        post("/validate") {
            val tok = call.receive<Map<String, String>>()["token"]
            if (tok.isNullOrEmpty()) return@post call.fail(400, "token required")
            try {
                val vt = kc.auth.validate(tok)
                call.respond(
                    mapOf(
                        "subject" to vt.subject,
                        "audience" to vt.audience,
                        "issuer" to vt.issuer,
                        "expiresAt" to vt.expiresAt?.epochSecond,
                    ),
                )
            } catch (e: TokenValidationException) {
                call.fail(401, e)
            } catch (e: KeycloakAuthException) {
                call.fail(401, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        post("/introspect") {
            val tok = call.receive<Map<String, String>>()["token"]
            if (tok.isNullOrEmpty()) return@post call.fail(400, "token required")
            try {
                val ir = kc.auth.introspect(tok)
                call.respond(mapOf("active" to ir.active, "username" to ir.username, "clientId" to ir.clientId))
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        // ROPC(password grant)는 SDK 표면에 없다(SDK 표면 불변 원칙) — 앱이 Keycloak 토큰 엔드포인트로
        // 직접 POST한다(8개 자매 앱 동일 패턴). refresh 토큰은 서버측 보관.
        post("/token/password") {
            try {
                val body = call.receive<Map<String, String>>()
                val form =
                    "grant_type=" + enc("password") +
                        "&client_id=" + enc(config.clientId) +
                        "&client_secret=" + enc(String(config.clientSecret!!)) +
                        "&username=" + enc(body["username"]!!) +
                        "&password=" + enc(body["password"]!!)
                val req =
                    HttpRequest.newBuilder()
                        .uri(URI.create("${config.serverUrl}/realms/${config.realm}/protocol/openid-connect/token"))
                        .header("Content-Type", "application/x-www-form-urlencoded")
                        .POST(HttpRequest.BodyPublishers.ofString(form))
                        .build()
                val resp = httpClient.send(req, HttpResponse.BodyHandlers.ofString())
                if (resp.statusCode() !in 200..299) {
                    return@post call.fail(401, "ROPC(password) grant failed: HTTP ${resp.statusCode()}")
                }
                @Suppress("UNCHECKED_CAST")
                val tokenBody = mapper.readValue(resp.body(), Map::class.java) as Map<String, Any?>
                lastRefreshToken = tokenBody["refresh_token"] as String?
                call.respond(
                    mapOf(
                        "tokenType" to tokenBody["token_type"],
                        "expiresIn" to tokenBody["expires_in"],
                        "hasRefresh" to (tokenBody["refresh_token"] != null),
                    ),
                )
            } catch (e: Exception) {
                call.fail(401, e)
            }
        }

        post("/refresh") {
            try {
                val ts = kc.auth.refresh(lastRefreshToken ?: "")
                ts.refreshToken?.let { lastRefreshToken = it }
                call.respond(mapOf("tokenType" to ts.tokenType, "expiresIn" to expiresIn(ts.expiresAt)))
            } catch (e: Exception) {
                call.fail(401, e)
            }
        }

        post("/logout") {
            try {
                kc.auth.logout(lastRefreshToken ?: "")
                call.respond(HttpStatusCode.NoContent)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        get("/authz-url") {
            try {
                val redirectUri =
                    call.request.queryParameters["redirect_uri"]?.takeIf { it.isNotBlank() } ?: "http://x/cb"
                val ar = kc.auth.createAuthorizationRequest(redirectUri)
                call.respond(mapOf("url" to ar.authorizationUrl, "state" to ar.state))
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        // ---- admin: users ----
        post("/admin/users") {
            val body = call.receive<Map<String, String>>()
            val username = body["username"]
            if (username.isNullOrEmpty()) return@post call.fail(400, "username required")
            try {
                val rep =
                    UserRepresentation().apply {
                        this.username = username
                        email = body["email"]
                        isEnabled = true
                    }
                val id = kc.admin.users().create(rep)
                call.respond(HttpStatusCode.Created, mapOf("id" to id))
            } catch (e: KeycloakAdminException.Conflict) {
                call.fail(409, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        get("/admin/users/{id}") {
            try {
                val u = kc.admin.users().get(call.parameters["id"]!!)
                call.respond(mapOf("id" to u.id, "username" to u.username))
            } catch (e: KeycloakAdminException.NotFound) {
                call.fail(404, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        get("/admin/users") {
            try {
                val us = kc.admin.users().search(call.request.queryParameters["username"] ?: "", 0, 20)
                call.respond(us.map { mapOf("id" to it.id, "username" to it.username) })
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        delete("/admin/users/{id}") {
            try {
                kc.admin.users().delete(call.parameters["id"]!!)
                call.respond(HttpStatusCode.NoContent)
            } catch (e: KeycloakAdminException.NotFound) {
                call.fail(404, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        // ---- admin: clients ----
        post("/admin/clients") {
            val body = call.receive<Map<String, String>>()
            try {
                val rep =
                    ClientRepresentation().apply {
                        clientId = body["clientId"]
                        isEnabled = true
                    }
                val id = kc.admin.clients().create(rep)
                call.respond(HttpStatusCode.Created, mapOf("id" to id))
            } catch (e: KeycloakAdminException.Conflict) {
                call.fail(409, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        get("/admin/clients/{id}") {
            try {
                val c = kc.admin.clients().get(call.parameters["id"]!!)
                call.respond(mapOf("id" to c.id, "clientId" to c.clientId))
            } catch (e: KeycloakAdminException.NotFound) {
                call.fail(404, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        delete("/admin/clients/{id}") {
            try {
                kc.admin.clients().delete(call.parameters["id"]!!)
                call.respond(HttpStatusCode.NoContent)
            } catch (e: KeycloakAdminException.NotFound) {
                call.fail(404, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        // ---- admin: roles (realm role — name 키) ----
        post("/admin/roles") {
            val name = call.receive<Map<String, String>>()["name"]
            try {
                kc.admin.roles().create(RoleRepresentation().apply { this.name = name })
                call.respond(HttpStatusCode.Created, mapOf("name" to name))
            } catch (e: KeycloakAdminException.Conflict) {
                call.fail(409, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        get("/admin/roles/{name}") {
            try {
                val r = kc.admin.roles().get(call.parameters["name"]!!)
                call.respond(mapOf("name" to r.name))
            } catch (e: KeycloakAdminException.NotFound) {
                call.fail(404, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        delete("/admin/roles/{name}") {
            try {
                kc.admin.roles().delete(call.parameters["name"]!!)
                call.respond(HttpStatusCode.NoContent)
            } catch (e: KeycloakAdminException.NotFound) {
                call.fail(404, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        // ---- admin: groups ----
        post("/admin/groups") {
            val name = call.receive<Map<String, String>>()["name"]
            try {
                val id = kc.admin.groups().create(GroupRepresentation().apply { this.name = name })
                call.respond(HttpStatusCode.Created, mapOf("id" to id))
            } catch (e: KeycloakAdminException.Conflict) {
                call.fail(409, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        get("/admin/groups/{id}") {
            try {
                val g = kc.admin.groups().get(call.parameters["id"]!!)
                call.respond(mapOf("id" to g.id, "name" to g.name))
            } catch (e: KeycloakAdminException.NotFound) {
                call.fail(404, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        delete("/admin/groups/{id}") {
            try {
                kc.admin.groups().delete(call.parameters["id"]!!)
                call.respond(HttpStatusCode.NoContent)
            } catch (e: KeycloakAdminException.NotFound) {
                call.fail(404, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }

        // ---- admin: realms (master 전용 — 하네스는 realm SA라 항상 403, CONTRACT.md 참고) ----
        post("/admin/realms") {
            val realm = call.receive<Map<String, String>>()["realm"]
            try {
                kc.admin.realms().create(
                    RealmRepresentation().apply {
                        this.realm = realm
                        isEnabled = true
                    },
                )
                call.respond(HttpStatusCode.Created, mapOf("realm" to realm))
            } catch (e: KeycloakAdminException.Forbidden) {
                call.fail(403, e)
            } catch (e: Exception) {
                call.fail(500, e)
            }
        }
    }
}
