package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.aResponse
import com.github.tomakehurst.wiremock.client.WireMock.get
import com.github.tomakehurst.wiremock.client.WireMock.getRequestedFor
import com.github.tomakehurst.wiremock.client.WireMock.urlPathEqualTo
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import kotlinx.coroutines.test.runTest
import java.time.Duration
import java.util.Date
import kotlin.test.Test
import kotlin.test.assertTrue

// 콜드 캐시 + IdP 장애에서 JWKS 조회가 유계인가 — Java `JwksColdCacheOutageTest` 와 동형.
//
// ⚠️ 워밍 캐시 rate-limit 테스트가 볼 수 없는 축이다. 30초 게이트는 캐시가 찬 뒤 미해결 kid
// 폭주를 막고, 캐시가 **빈 채 fetch 가 계속 실패**하면 그 게이트에 닿기 전이다. 나머지 일곱
// 언어는 정확히 거기서 무유계였다(20 검증 → IdP 요청 20).
//
// 실측 2026-09-06: Kotlin 은 **이미 유계**다 — Nimbus 의 RateLimitedJWKSetSource 가 실패한
// 조회에도 창을 적용해 20회 검증이 요청 2건에 그친다. **고칠 것이 없다.**
//
// ⚠️ 무게는 상한 단언이 아니라 **대조군**에 있다. rate-limit 을 0 으로 풀면 같은 프로브가 20 을
// 본다 — 없으면 「2」가 게이트 덕인지 프로브가 못 재는 것인지 갈리지 않는다.
//
// ⚠️ **상한 단언만으로는 하드닝 삭제를 못 잡는다**(Java 쪽에서 변이로 실측). `.rateLimited(...)` 를
// 지우면 JWKSourceBuilder 의 **기본** rate-limit(30초)이 대신 걸려 상한은 그대로 2다. 그때 무너지는
// 것은 대조군이다 — interval 0 이 20 → 2 로 떨어져 「설정 노브가 죽었다」를 가리킨다.
// **대조군 레그를 지우면 이 테스트는 하드닝 삭제에 침묵한다.**
internal class JwksColdCacheOutageTest {
    private val certsPath = "/realms/r/protocol/openid-connect/certs"

    // 창당 상한. Nimbus 는 창을 열 때 한 건을 이미 크레딧한다 — `.claude/rules/security.md`.
    private val windowCeiling = 2
    private val attempts = 20

    private fun rsaKey(kid: String = "k1"): RSAKey = RSAKeyGenerator(2048).keyID(kid).generate()

    private fun signed(
        key: RSAKey,
        iss: String,
        kid: String,
    ): String {
        val jwt =
            SignedJWT(
                JWSHeader.Builder(JWSAlgorithm.RS256).keyID(kid).build(),
                JWTClaimsSet
                    .Builder()
                    .issuer(iss)
                    .audience("app")
                    .expirationTime(Date(System.currentTimeMillis() + 60_000))
                    .build(),
            )
        jwt.sign(RSASSASigner(key))
        return jwt.serialize()
    }

    private suspend fun run(
        server: WireMockServer,
        signing: RSAKey,
        minRefetch: Duration?,
    ): Int {
        val config =
            if (minRefetch == null) {
                KeycloakConfig(serverUrl = server.baseUrl(), realm = "r", clientId = "app")
            } else {
                KeycloakConfig(
                    serverUrl = server.baseUrl(),
                    realm = "r",
                    clientId = "app",
                    jwksMinRefetch = minRefetch,
                )
            }
        val endpoints = OidcEndpoints.forRealm(config)
        val validator = JwtValidator.forRealm(endpoints, config, "app")
        repeat(attempts) { i ->
            // 미해결 kid 는 항상 거부된다 — 세는 것은 거부 여부가 아니라 IdP 요청 수다.
            runCatching { validator.validate(signed(signing, endpoints.issuer, "unknown-$i")) }
        }
        return server.findAll(getRequestedFor(urlPathEqualTo(certsPath))).size
    }

    @Test
    fun `cold cache during an IdP outage is bounded`() =
        runTest {
            val signing = rsaKey()

            val down = WireMockServer(wireMockConfig().dynamicPort())
            down.start()
            val coldFailing =
                try {
                    down.stubFor(get(urlPathEqualTo(certsPath)).willReturn(aResponse().withStatus(503)))
                    run(down, signing, null)
                } finally {
                    down.stop()
                }

            val ok = WireMockServer(wireMockConfig().dynamicPort())
            ok.start()
            val warmOk =
                try {
                    ok.stubFor(
                        get(urlPathEqualTo(certsPath)).willReturn(
                            aResponse()
                                .withHeader("Content-Type", "application/json")
                                .withBody(JWKSet(signing.toPublicJWK()).toString()),
                        ),
                    )
                    run(ok, signing, null)
                } finally {
                    ok.stop()
                }

            // 대조군(알려진 양성) — 게이트를 풀면 같은 프로브가 폭주를 본다.
            val ungated = WireMockServer(wireMockConfig().dynamicPort())
            ungated.start()
            val coldUngated =
                try {
                    ungated.stubFor(get(urlPathEqualTo(certsPath)).willReturn(aResponse().withStatus(503)))
                    run(ungated, signing, Duration.ZERO)
                } finally {
                    ungated.stop()
                }

            assertTrue(
                coldUngated >= attempts / 2,
                "대조군이 폭주를 못 보면 이 테스트는 공허하다 — rate-limit 0 에서 실제=$coldUngated",
            )
            assertTrue(
                coldFailing <= windowCeiling,
                "콜드 캐시 + IdP 503 에서 ${attempts}회 검증이 요청 ${windowCeiling}건을 넘으면 안 된다 — 실제=$coldFailing",
            )
            assertTrue(
                warmOk <= windowCeiling,
                "정상 IdP + 미해결 kid 폭주도 같은 상한이다 — 실제=$warmOk",
            )
        }
}
