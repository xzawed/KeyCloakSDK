package io.github.xzawed.keycloak

import java.time.Duration
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class ConfigTest {
    @Test
    fun `blank serverUrl throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "", realm = "r", clientId = "c")
        }
    }

    @Test
    fun `blank realm throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "http://x", realm = "", clientId = "c")
        }
    }

    @Test
    fun `blank clientId throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "")
        }
    }

    @Test
    fun `whitespace-only serverUrl throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "   ", realm = "r", clientId = "c")
        }
    }

    @Test
    fun `serverUrl trailing slash is trimmed`() {
        val config = KeycloakConfig(serverUrl = "http://x/", realm = "r", clientId = "c")
        assertEquals("http://x", config.serverUrl)
    }

    @Test
    fun `serverUrl without trailing slash is unchanged`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals("http://x", config.serverUrl)
    }

    @Test
    fun `toString masks clientSecret and never contains raw secret`() {
        val config =
            KeycloakConfig(
                serverUrl = "http://x",
                realm = "r",
                clientId = "c",
                clientSecret = "super-secret-value".toCharArray(),
            )
        val s = config.toString()
        assertTrue(s.contains("clientSecret=***"))
        assertFalse(s.contains("super-secret-value"))
    }

    @Test
    fun `toString shows serverUrl realm and clientId`() {
        val config = KeycloakConfig(serverUrl = "http://x/", realm = "myrealm", clientId = "myclient")
        val s = config.toString()
        assertTrue(s.contains("serverUrl=http://x"))
        assertTrue(s.contains("realm=myrealm"))
        assertTrue(s.contains("clientId=myclient"))
    }

    @Test
    fun `toString shows empty mask for null clientSecret`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", clientSecret = null)
        val s = config.toString()
        assertTrue(s.contains("clientSecret="))
        assertFalse(s.contains("clientSecret=***"))
    }

    @Test
    fun `clientSecret getter returns a defensive copy on input`() {
        val original = "mysecret".toCharArray()
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", clientSecret = original)
        original[0] = 'X'
        val returned = config.clientSecret
        assertEquals('m', returned!![0])
    }

    @Test
    fun `clientSecret getter returns a defensive copy on output`() {
        val config =
            KeycloakConfig(
                serverUrl = "http://x",
                realm = "r",
                clientId = "c",
                clientSecret = "mysecret".toCharArray(),
            )
        val firstCopy = config.clientSecret
        firstCopy!![0] = 'X'
        val secondCopy = config.clientSecret
        assertEquals('m', secondCopy!![0])
    }

    @Test
    fun `clientSecret defaults to null`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(null, config.clientSecret)
    }

    @Test
    fun `default connectTimeout is 10 seconds`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(Duration.ofSeconds(10), config.connectTimeout)
    }

    @Test
    fun `default readTimeout is 30 seconds`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(Duration.ofSeconds(30), config.readTimeout)
    }

    @Test
    fun `default clockSkew is 30 seconds`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(Duration.ofSeconds(30), config.clockSkew)
    }

    @Test
    fun `default jwksMinRefetch is 30 seconds`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(Duration.ofSeconds(30), config.jwksMinRefetch)
    }

    @Test
    fun `custom jwksMinRefetch is preserved`() {
        val config =
            KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", jwksMinRefetch = Duration.ofSeconds(120))
        assertEquals(Duration.ofSeconds(120), config.jwksMinRefetch)
    }

    @Test
    fun `default scopes is empty list`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertTrue(config.scopes.isEmpty())
    }

    @Test
    fun `expectedAudience defaults to clientId`() {
        // 미설정이면 기존 동작 그대로 — 기대 audience는 clientId다(하위 호환).
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals("c", config.expectedAudience)
    }

    @Test
    fun `custom expectedAudience overrides clientId`() {
        // 기본 realm은 client-credentials 토큰의 aud에 client id를 넣지 않는다 — 리소스 서버 이름 등
        // 실제 발급되는 audience로 재정의할 수 있어야 한다.
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", expectedAudience = "my-api")
        assertEquals("my-api", config.expectedAudience)
    }

    @Test
    fun `default signatureAlgorithms is RS256`() {
        val config = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c")
        assertEquals(listOf("RS256"), config.signatureAlgorithms)
    }

    @Test
    fun `custom signatureAlgorithms are preserved`() {
        val config =
            KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", signatureAlgorithms = listOf("ES256", "RS256"))
        assertEquals(listOf("ES256", "RS256"), config.signatureAlgorithms)
    }

    @Test
    fun `empty signatureAlgorithms throws KeycloakConfigException`() {
        assertFailsWith<KeycloakConfigException> {
            KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", signatureAlgorithms = emptyList())
        }
    }

    @Test
    fun `malformed serverUrl throws KeycloakConfigException without echoing the input`() {
        // 상대 경로·공백·비-http(s)·toURL() 실패는 Nimbus/JDK 예외로 새지 않고, 입력 전체를 되울리지 않는다.
        // 범위 밖 포트는 URI·URL 어느 쪽도 보지 않아 연결 시점에 IAE("port out of range")로 샜다(독립 레그 실측,
        // Java 자매). 밑줄 호스트는 URI 가 포트를 읽지 못하므로 그쪽도 함께 본다.
        val malformed =
            listOf(
                "kc.example.com",
                "http://kc example.com",
                "ftp://kc.example.com",
                "http://::1",
                "http://127.0.0.1:65536",
                "http://kc_server:70000",
            )
        for (serverUrl in malformed) {
            val e =
                assertFailsWith<KeycloakConfigException>(serverUrl) {
                    KeycloakConfig(serverUrl = serverUrl, realm = "r", clientId = "c")
                }
            assertTrue(e.message!!.startsWith("serverUrl must be an absolute http(s) URL: "), e.message)
            assertFalse(e.message!!.contains(serverUrl), e.message)
        }
    }

    @Test
    fun `absolute http and https serverUrl is accepted including underscore host`() {
        // getHost() 가 null 인 언더스코어 호스트도 registry-based authority 로 받는다.
        val accepted =
            listOf(
                "http://keycloak_server:8080",
                "https://kc.example.com/auth",
                "http://127.0.0.1:8080",
                "HTTP://kc.example.com",
                "http://127.0.0.1:65535",
            )
        for (serverUrl in accepted) {
            val config = KeycloakConfig(serverUrl = serverUrl, realm = "r", clientId = "c")
            assertEquals(serverUrl, config.serverUrl)
        }
    }

    @Test
    fun `serverUrl without an authority is rejected`() {
        // "http:foo" 는 스킴이 http 이고 toURL() 도 성공하지만 rawAuthority 가 null 이다.
        val serverUrl = "http:foo"
        val e =
            assertFailsWith<KeycloakConfigException> {
                KeycloakConfig(serverUrl = serverUrl, realm = "r", clientId = "c")
            }
        assertTrue(e.message!!.startsWith("serverUrl must be an absolute http(s) URL: "), e.message)
        assertFalse(e.message!!.contains(serverUrl), e.message)
    }

    @Test
    fun `connectTimeout and readTimeout must be between 1 ms and Int MAX_VALUE`() {
        val rejected =
            listOf(
                Duration.ofMillis(0),
                Duration.ofMillis(-1),
                Duration.ofNanos(1),
                Duration.ofMillis(Int.MAX_VALUE.toLong() + 1),
                Duration.ofSeconds(Long.MAX_VALUE),
            )
        for (timeout in rejected) {
            val connect =
                assertFailsWith<KeycloakConfigException>("connectTimeout $timeout") {
                    KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", connectTimeout = timeout)
                }
            assertTrue(connect.message!!.contains("connectTimeout"), connect.message)
            val read =
                assertFailsWith<KeycloakConfigException>("readTimeout $timeout") {
                    KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", readTimeout = timeout)
                }
            assertTrue(read.message!!.contains("readTimeout"), read.message)
        }
        for (timeout in listOf(Duration.ofMillis(1), Duration.ofMillis(Int.MAX_VALUE.toLong()))) {
            val byConnect =
                KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", connectTimeout = timeout)
            assertEquals(timeout, byConnect.connectTimeout)
            val byRead = KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", readTimeout = timeout)
            assertEquals(timeout, byRead.readTimeout)
        }
    }

    /** 음수는 의미가 없어 자매(go·dotnet·node·python·php)와 Java 처럼 생성 시 거부한다. 0 은 허용한다. */
    @Test
    fun `negative clockSkew or jwksMinRefetch throws KeycloakConfigException`() {
        val skew =
            assertFailsWith<KeycloakConfigException> {
                KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", clockSkew = Duration.ofSeconds(-1))
            }
        assertEquals("clockSkew must be >= 0", skew.message)
        val refetch =
            assertFailsWith<KeycloakConfigException> {
                KeycloakConfig(serverUrl = "http://x", realm = "r", clientId = "c", jwksMinRefetch = Duration.ofSeconds(-1))
            }
        assertEquals("jwksMinRefetch must be >= 0", refetch.message)
        val zero =
            KeycloakConfig(
                serverUrl = "http://x",
                realm = "r",
                clientId = "c",
                clockSkew = Duration.ZERO,
                jwksMinRefetch = Duration.ZERO,
            )
        assertEquals(Duration.ZERO, zero.clockSkew)
        assertEquals(Duration.ZERO, zero.jwksMinRefetch)
    }

    /** 밀리초로 못 나타내는 jwksMinRefetch 는 첫 validate() 의 toMillis() 에서 ArithmeticException 으로 샜다(Java 자매 실측). */
    @Test
    fun `jwksMinRefetch beyond millis throws KeycloakConfigException`() {
        val e =
            assertFailsWith<KeycloakConfigException> {
                KeycloakConfig(
                    serverUrl = "http://x",
                    realm = "r",
                    clientId = "c",
                    jwksMinRefetch = Duration.ofSeconds(Long.MAX_VALUE),
                )
            }
        assertEquals("jwksMinRefetch is too large", e.message)
    }
}
