package io.github.xzawed.harness

import io.github.xzawed.keycloak.KeycloakClient
import io.github.xzawed.keycloak.KeycloakConfig
import kotlinx.coroutines.runBlocking

// 설치 스모크(quickstart) — 레지스트리에서 설치된 게시 SDK 패키지(io.github.xzawed:keycloak-sdk-kotlin:0.1.0)로
// 실 Keycloak에 대해 client-credentials 토큰을 받아 검증한다. 성공 시 0으로 종료(kotlin-run.sh가 마커 기록).
// 자바 quickstart(harness/install/quickstart/java)와 동형 스모크.
fun main(): Unit =
    runBlocking {
        val config =
            KeycloakConfig(
                serverUrl = env("KC_SERVER_URL", "http://localhost:8080"),
                realm = env("KC_REALM", "it-realm"),
                clientId = env("KC_CLIENT_ID", "it-client"),
                clientSecret = env("KC_CLIENT_SECRET", "it-secret").toCharArray(),
                scopes = listOf("openid"),
            )
        KeycloakClient.create(config).use { kc ->
            val ts = kc.auth.clientCredentialsToken()
            val vt = kc.auth.validate(ts.accessToken)
            println("[quickstart] OK — tokenType=${ts.tokenType} subject=${vt.subject} issuer=${vt.issuer}")
        }
    }

private fun env(k: String, d: String): String = System.getenv(k)?.takeIf { it.isNotEmpty() } ?: d
