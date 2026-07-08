// QuickStart — client-credentials 토큰 발급 → 강화 JWT 검증 → admin 사용자 생성.
//
// 이 SDK를 소비하는 별도 프로젝트에 넣고 실행하는 문서용 스니펫이다(이 모노레포의 `kotlin/`
// build.gradle.kts는 src/main·src/test·src/integrationTest만 컴파일하며, examples/는 어떤 소스셋에도
// 포함되지 않는다). 실행 전 Keycloak이 필요하다(로컬: `docker run -p 8080:8080
// -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin
// quay.io/keycloak/keycloak:26.6 start-dev`).
//
// 의존성: io.github.xzawed:keycloak-sdk-kotlin:<version> (Maven Central, `kotlin-v*` 태그 릴리스 이후 —
// 현재는 사람 승인 게이트로 미배포 상태다).

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
            // 1) client-credentials 그랜트로 토큰 발급. access token 원문은 절대 로그에 남기지 않는다
            //    (TokenSet.toString()은 accessToken/refreshToken을 "***"로 마스킹한다).
            val token = client.auth.clientCredentialsToken()
            println("token type: ${token.tokenType}, expires at: ${token.expiresAt}")

            // 2) 발급받은 액세스 토큰을 자체 강화 검증(RS256 핀·iss 정확일치·aud 포함검사·exp 필수·클록 스큐).
            val validated = client.auth.validate(token.accessToken)
            println("subject: ${validated.subject}, issuer: ${validated.issuer}")

            // 3) 관리 API — 사용자 생성. 생성된 id는 응답 Location 헤더에서 추출된다.
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
