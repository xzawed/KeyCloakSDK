package io.github.xzawed.keycloak

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** [OAuthErrorCode.carried] — 모양(`[a-z_]{1,64}`)과 보낸 비밀과의 겹침. 실제 레인은 `OAuthErrorCodeEchoTest`. */
class OAuthErrorCodeTest {
    @Test
    fun keepsOnlyACodeShapedValue() {
        for (code in listOf("invalid_grant", "slow_down", "a", "a".repeat(64), "_")) {
            assertEquals(code, OAuthErrorCode.carried(code, emptyList()), code)
        }
        val notCodes =
            listOf(
                null,
                "",
                "a".repeat(65),
                "Invalid_grant",
                "invalid grant",
                "invalid_grant\n",
                "invalid_grant2",
                "Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5",
                "eyJhbGciOiJIUzI1NiJ9.e30.sig",
                "invalid_granté",
            )
        for (notCode in notCodes) {
            assertNull(OAuthErrorCode.carried(notCode, emptyList()), notCode.toString())
        }
    }

    @Test
    fun withholdsAValueThatOverlapsASecretTheRequestSent() {
        assertEquals("invalid_grant", OAuthErrorCode.carried("invalid_grant", listOf("s3cret-Value")))
        assertNull(OAuthErrorCode.carried("mysecret", listOf("mysecret")))
        assertNull(OAuthErrorCode.carried("mysecret_x", listOf("mysecret")), "extended echo")
        assertNull(OAuthErrorCode.carried("mysec", listOf("mysecret")), "truncated echo")
        assertNull(OAuthErrorCode.carried("secret", listOf("mysecret")), "a suffix piece, not only a prefix")
        assertNull(OAuthErrorCode.carried("yse", listOf("mysecret")), "a middle piece")
        assertNull(OAuthErrorCode.carried("x_mysecret", listOf("mysecret")), "the secret behind a prefix")
        assertNull(OAuthErrorCode.carried("fresh", listOf("zzz", "myrefresh")), "a piece of a later value")
        assertNull(OAuthErrorCode.carried("mysecret", listOf(null, "", "other", "mysecret")))
        assertEquals(
            "invalid_grant",
            OAuthErrorCode.carried("invalid_grant", listOf(null, "")),
            "an absent or empty secret is not compared",
        )
        assertNull(OAuthErrorCode.carried("invalid_client", listOf("client")), "the price: a piece of the code withholds it")
    }

    @ParameterizedTest(name = "{0}: {2}")
    @MethodSource("sharedRows")
    fun theOverlapIgnoresAsciiCase(
        row: String,
        sent: List<String>,
        value: String,
        expected: String?,
    ) {
        assertEquals(expected, OAuthErrorCode.carried(value, sent), row)
    }

    companion object {
        /**
         * The rows all nine languages share: the overlap ignores ASCII case (an IdP or proxy that echoes the secret
         * lowercased), and the shape is exactly `[a-z_]{1,64}`.
         */
        @JvmStatic
        fun sharedRows(): List<Arguments> {
            // V5: U+212A KELVIN SIGN, then "ey" — built from the code point. The fold is ASCII so the nine agree; a
            // secret's non-ASCII letter is compared as itself.
            val kelvinEy = String(Character.toChars(0x212A)) + "ey"
            return listOf(
                Arguments.of("V1 a lowercased echo", listOf("MySecret"), "mysecret", null),
                Arguments.of("V2 a truncated lowercased echo", listOf("MySecret"), "mysec", null),
                Arguments.of("V3 an extended lowercased echo", listOf("MySecret"), "invalid_mysecret_x", null),
                Arguments.of("V4 control", listOf("MySecret"), "invalid_grant", "invalid_grant"),
                Arguments.of("V5 the fold is ASCII only", listOf(kelvinEy), "key", "key"),
                Arguments.of("V6 the shape", emptyList<String>(), "invalid__grant", "invalid__grant"),
                Arguments.of("V6 the shape", emptyList<String>(), "_", "_"),
            )
        }
    }
}
