// QuickStart — issue a client-credentials token → hardened JWT validation → create a user through admin.
//
// A documentation snippet to put into a separate project that consumes this SDK and run there (this monorepo
// compiles it with the unit tests so it follows the API, but never runs it). Keycloak is needed before running it
// (locally: `docker run -p 8080:8080
// -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin
// quay.io/keycloak/keycloak:26.6 start-dev`).
//
// Dependency: io.github.xzawed:keycloak-sdk-kotlin:<version> on Maven Central — the current version is in
// kotlin/README.md.

import io.github.xzawed.keycloak.KeycloakClient
import io.github.xzawed.keycloak.KeycloakConfig
import kotlinx.coroutines.runBlocking
import org.keycloak.representations.idm.UserRepresentation

fun main() =
    runBlocking {
        val config =
            KeycloakConfig(
                serverUrl = System.getenv("KC_SERVER_URL") ?: "http://localhost:8080",
                realm = System.getenv("KC_REALM") ?: "it-realm",
                clientId = System.getenv("KC_CLIENT_ID") ?: "it-client",
                clientSecret = (System.getenv("KC_CLIENT_SECRET") ?: "it-secret").toCharArray(),
            )

        KeycloakClient.create(config).use { client ->
            // 1) Issue a token via the client-credentials grant. The raw access token is never written to a log
            //    (TokenSet.toString() masks accessToken/refreshToken as "***").
            val token = client.auth.clientCredentialsToken()
            println("token type: ${token.tokenType}, expires at: ${token.expiresAt}")

            // 2) Self-hardened validation of the issued access token (RS256 pin, exact iss match, aud containment
            //    check, exp required, clock skew).
            val validated = client.auth.validate(token.accessToken)
            println("subject: ${validated.subject}, issuer: ${validated.issuer}")

            // 3) Admin API — create a user. The created id is extracted from the response's Location header.
            val userId =
                client.admin.users().create(
                    UserRepresentation().apply {
                        username = "demo-user"
                        email = "demo@example.com"
                        isEnabled = true
                    },
                )
            println("created demo-user (id=$userId)")
        }
    }
