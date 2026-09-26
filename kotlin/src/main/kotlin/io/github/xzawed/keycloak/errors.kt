package io.github.xzawed.keycloak

// errors.kt — sealed 계층 전체를 한 패키지/파일에(sealed same-module+package 요건)
public sealed class KeycloakException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

public class KeycloakConfigException(
    m: String,
    c: Throwable? = null,
) : KeycloakException(m, c)

public class KeycloakAuthException(
    m: String,
    public val oauthError: String? = null,
    c: Throwable? = null,
) : KeycloakException(m, c)

public class KeycloakTransportException(
    m: String,
    c: Throwable? = null,
) : KeycloakException(m, c)

public class TokenValidationException(
    m: String,
    c: Throwable? = null,
) : KeycloakException(m, c)

/**
 * 하위 예외 사슬의 사본 — **타입 이름과 스택 프레임만** 옮기고 메시지·필드는 옮기지 않는다.
 *
 * ⚠️ 응답을 읽다 난 하위 예외는 그 응답을 인용한다 — json-smart 는 JSON 아닌 본문의 토큰을 통째로, Jackson 은
 * 앞부분·JSON 문자열 값을, Nimbus 는 token_type 값을 메시지에 싣고, 감싸는 예외는 그 메시지를 되풀이한다. 원본을
 * cause 로 달면 `stackTraceToString()` 의 "Caused by:" 가 그것을 찍었다(`AuthMalformedResponseTest`). 원본 객체는
 * 필드에도 입력을 쥔다(json-smart `unexpectedObject`) — 사본은 필드를 옮기지 않고 하위 타입도 공개 API 로 새지
 * 않는다(§4). 무엇이 어디서 실패했는지는 타입 이름과 프레임으로 그대로 보인다.
 */
internal class RedactedCause private constructor(
    /** 원본 예외의 이진 클래스 이름. */
    internal val originalType: String,
) : Exception() {
    override fun toString(): String = "$originalType (message withheld)"

    internal companion object {
        // 원인 사슬은 순환할 수 있다(`initCause` 는 자기 자신만 막는다) — 깊이로 끊는다.
        private const val MAX_DEPTH = 16

        fun of(t: Throwable): RedactedCause = copy(t, 0)

        private fun copy(
            t: Throwable,
            depth: Int,
        ): RedactedCause {
            val copy = RedactedCause(t.javaClass.name)
            copy.stackTrace = t.stackTrace
            if (depth < MAX_DEPTH) {
                t.cause?.let { copy.initCause(copy(it, depth + 1)) }
                t.suppressed.forEach { copy.addSuppressed(copy(it, depth + 1)) }
            }
            return copy
        }
    }
}

public sealed class KeycloakAdminException(
    public val status: Int,
    public val keycloakError: String?,
    c: Throwable? = null,
) : KeycloakException("Keycloak admin error (HTTP $status)", c) {
    public class NotFound(
        s: Int,
        e: String?,
        c: Throwable? = null,
    ) : KeycloakAdminException(s, e, c)

    public class Conflict(
        s: Int,
        e: String?,
        c: Throwable? = null,
    ) : KeycloakAdminException(s, e, c)

    public class Forbidden(
        s: Int,
        e: String?,
        c: Throwable? = null,
    ) : KeycloakAdminException(s, e, c)

    public class Other(
        s: Int,
        e: String?,
        c: Throwable? = null,
    ) : KeycloakAdminException(s, e, c) // 500 등 필수 리프
}
